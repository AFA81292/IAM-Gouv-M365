# ========================================================================================
# Exercice 1j : Entra ID — Audit des identités
# ========================================================================================
# Concept : L'audit des identités est le point de départ de toute mission IAM.
# Avant de toucher quoi que ce soit sur un tenant, on inventorie l'existant :
# combien de comptes, quels types, lesquels sont actifs, lesquels sont désactivés,
# quelle proportion d'invités. Ce script produit une photographie complète du tenant
# à un instant T, exportée en CSV pour analyse ou transmission au RSSI.
#
# Ce que fait ce script :
#   1. Reset total de session
#   2. Récupère tous les comptes du tenant (membres + invités)
#   3. Classe chaque compte : type, état, présence de licence
#   4. Affiche les chiffres clés par catégorie
#   5. Exporte le rapport complet en CSV horodaté
#   6. Ferme proprement toutes les sessions
#
# Colonnes exportées dans le CSV :
#   DisplayName, UPN, UserType, AccountEnabled, Department, JobTitle,
#   UsageLocation, LicencesCount, CreatedDateTime
#
# Colonnes disponibles non exportées (variantes commentées) :
#   Id                  : ObjectId Entra (GUID) — utile pour les scripts de suivi
#   SignInActivity      : dernière connexion (nécessite AuditLog.Read.All — voir exo 1l)
#   OnPremisesSyncEnabled : compte hybride synchronisé depuis AD on-prem
#   ExternalUserState   : état d'acceptation de l'invitation (invités uniquement)
#
# Cas d'usage réel :
#   Première semaine en mission — état des lieux rapide du tenant avant toute action.
#   Le CSV est le livrable de base pour un comité de gouvernance ou un audit SSI.
#
# Module requis : Microsoft.Graph.Users
# Connexion     : Connect-MgGraph
# ========================================================================================

# --- OUVERTURE — RESET DE SESSION TOTAL ---
# User.Read.All : lecture seule sur tous les comptes du tenant
# Directory.Read.All : accès aux licences attribuées (AssignedLicenses)
# Pas de -ContextScope Process : scopes lecture seule, pas de blocage WAM.
$Scopes = @(
    "User.Read.All",
    "Directory.Read.All"
)

Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
Connect-MgGraph -Scopes $Scopes -NoWelcome

# ========================================================================================
# ÉTAPE 1 : Définition des variables
# ========================================================================================
Write-Host "1. Définition des variables..." -ForegroundColor Cyan

# EN LABO / Local :
$ExportPath = "D:\Documents\ScriptsPowerShell\Exports\"
# EN PRODUCTION :
# $ExportPath = "$PSScriptRoot\Exports\"

$Timestamp = Get-Date -Format "yyyyMMdd_HHmmss"

New-Item -ItemType Directory -Force -Path $ExportPath | Out-Null
Write-Host "-> Dossier export : $ExportPath" -ForegroundColor Green
Write-Host "-> Horodatage     : $Timestamp`n" -ForegroundColor Green

# ========================================================================================
# ÉTAPE 2 : Récupération de tous les comptes
# ========================================================================================
Write-Host "2. Récupération de tous les comptes du tenant..." -ForegroundColor Cyan

# -All : pagination automatique — récupère tous les objets sans limite.
# Sans -All, Graph retourne 100 objets maximum par défaut (page size).
# -Property : on ne récupère que les colonnes nécessaires — évite de charger
# des dizaines d'attributs inutiles et accélère la requête sur les grands tenants.
$AllUsers = Get-MgUser -All `
    -Property Id, DisplayName, UserPrincipalName, UserType, AccountEnabled,
              Department, JobTitle, UsageLocation, AssignedLicenses, CreatedDateTime

Write-Host "-> $($AllUsers.Count) compte(s) récupéré(s).`n" -ForegroundColor Green

# ========================================================================================
# ÉTAPE 3 : Classification et construction du rapport
# ========================================================================================
Write-Host "3. Classification des comptes..." -ForegroundColor Cyan

$Report = @()

foreach ($User in $AllUsers) {
    $Row = [PSCustomObject]@{
        DisplayName    = $User.DisplayName
        UPN            = $User.UserPrincipalName
        # UserType : "Member" = compte interne, "Guest" = compte invité externe (B2B)
        UserType       = $User.UserType
        # AccountEnabled : $true = actif, $false = désactivé
        AccountEnabled = $User.AccountEnabled
        Department     = $User.Department
        JobTitle       = $User.JobTitle
        UsageLocation  = $User.UsageLocation
        # AssignedLicenses.Count : 0 = sans licence, >0 = nombre de licences attribuées
        LicencesCount  = $User.AssignedLicenses.Count
        CreatedDateTime = $User.CreatedDateTime
    }
    $Report += $Row
}

Write-Host "-> Rapport construit : $($Report.Count) ligne(s).`n" -ForegroundColor Green

# --- VARIANTE : Ajouter l'Id Entra (ObjectId) au rapport ---
# Utile pour les scripts de suivi qui ont besoin du GUID plutôt que de l'UPN.
# Ajouter dans le bloc [PSCustomObject] ci-dessus :
#
# Id = $User.Id

# --- VARIANTE : Ajouter le statut hybride (sync AD on-prem) ---
# OnPremisesSyncEnabled = $true si le compte est synchronisé depuis un AD on-prem.
# $null ou $false = compte cloud-only.
# Ajouter dans le bloc [PSCustomObject] ci-dessus :
#
# Hybride = if ($User.OnPremisesSyncEnabled) { "On-Prem Sync" } else { "Cloud Only" }

# ========================================================================================
# ÉTAPE 4 : Affichage des chiffres clés
# ========================================================================================
Write-Host "4. Chiffres clés du tenant..." -ForegroundColor Cyan

# Comptages par catégorie — Where-Object filtre la collection en mémoire,
# pas d'appels API supplémentaires.
$TotalUsers    = $Report.Count
$Members       = ($Report | Where-Object { $_.UserType -eq "Member" }).Count
$Guests        = ($Report | Where-Object { $_.UserType -eq "Guest" }).Count
$ActiveUsers   = ($Report | Where-Object { $_.AccountEnabled -eq $true }).Count
$DisabledUsers = ($Report | Where-Object { $_.AccountEnabled -eq $false }).Count
$Licensed      = ($Report | Where-Object { $_.LicencesCount -gt 0 }).Count
$Unlicensed    = ($Report | Where-Object { $_.LicencesCount -eq 0 }).Count

Write-Host "`n=== CHIFFRES CLÉS ===" -ForegroundColor Magenta
[PSCustomObject]@{
    TotalComptes      = $TotalUsers
    Membres           = $Members
    Invités           = $Guests
    ComptesActifs     = $ActiveUsers
    ComptesDesactivés = $DisabledUsers
    AvecLicence       = $Licensed
    SansLicence       = $Unlicensed
} | Format-List

# Sous-répartition : membres actifs vs désactivés
Write-Host "=== RÉPARTITION MEMBRES ===" -ForegroundColor Cyan
$Report | Where-Object { $_.UserType -eq "Member" } |
    Group-Object AccountEnabled |
    Select-Object @{N="AccountEnabled"; E={$_.Name}}, Count |
    Format-Table -AutoSize

# Sous-répartition : invités actifs vs désactivés
Write-Host "=== RÉPARTITION INVITÉS ===" -ForegroundColor Cyan
$Report | Where-Object { $_.UserType -eq "Guest" } |
    Group-Object AccountEnabled |
    Select-Object @{N="AccountEnabled"; E={$_.Name}}, Count |
    Format-Table -AutoSize

# --- VARIANTE : Répartition par département ---
# Pour voir la distribution des comptes par département (utile sur les grands tenants).
# Exclut les comptes sans département renseigné.
#
# $Report | Where-Object { $_.Department } |
#     Group-Object Department |
#     Sort-Object Count -Descending |
#     Select-Object Name, Count |
#     Format-Table -AutoSize

# ========================================================================================
# ÉTAPE 5 : Export CSV
# ========================================================================================
Write-Host "`n5. Export CSV..." -ForegroundColor Cyan

# --- CSV 1 : Rapport complet toutes identités ---
# Toutes les colonnes, tous les comptes — rapport exhaustif.
$CsvAll = "$ExportPath\Identity_Audit_All_$Timestamp.csv"
$Report | Export-Csv -Path $CsvAll -Encoding UTF8 -NoTypeInformation
Write-Host "-> Toutes identités : $($Report.Count) ligne(s) — Identity_Audit_All_$Timestamp.csv" -ForegroundColor Green

# --- CSV 2 : Comptes désactivés uniquement ---
# Sous-ensemble des comptes avec AccountEnabled = False.
# Livrable utile pour identifier les comptes à nettoyer ou à supprimer (exo 1h).
$DisabledReport = $Report | Where-Object { $_.AccountEnabled -eq $false }
if ($DisabledReport.Count -gt 0) {
    $CsvDisabled = "$ExportPath\Identity_Audit_Disabled_$Timestamp.csv"
    $DisabledReport | Export-Csv -Path $CsvDisabled -Encoding UTF8 -NoTypeInformation
    Write-Host "-> Comptes désactivés : $($DisabledReport.Count) ligne(s) — Identity_Audit_Disabled_$Timestamp.csv" -ForegroundColor Green
} else {
    Write-Host "-> Comptes désactivés : aucun compte désactivé trouvé." -ForegroundColor Yellow
}

# --- CSV 3 : Comptes sans licence ---
# Sous-ensemble des comptes avec LicencesCount = 0.
# Livrable utile pour identifier les comptes fantômes ou les erreurs de provisioning.
$UnlicensedReport = $Report | Where-Object { $_.LicencesCount -eq 0 }
if ($UnlicensedReport.Count -gt 0) {
    $CsvUnlicensed = "$ExportPath\Identity_Audit_Unlicensed_$Timestamp.csv"
    $UnlicensedReport | Export-Csv -Path $CsvUnlicensed -Encoding UTF8 -NoTypeInformation
    Write-Host "-> Sans licence : $($UnlicensedReport.Count) ligne(s) — Identity_Audit_Unlicensed_$Timestamp.csv" -ForegroundColor Green
} else {
    Write-Host "-> Sans licence : tous les comptes ont une licence." -ForegroundColor Yellow
}

# --- VARIANTE : CSV invités uniquement ---
# Pour un rapport focalisé sur les accès externes — complément de l'exo 1k.
#
# $GuestReport = $Report | Where-Object { $_.UserType -eq "Guest" }
# $GuestReport | Export-Csv -Path "$ExportPath\Identity_Audit_Guests_$Timestamp.csv" -Encoding UTF8 -NoTypeInformation

Write-Host "-> Export terminé dans : $ExportPath`n" -ForegroundColor Green

# ========================================================================================
# RÉSUMÉ
# ========================================================================================
Write-Host "=== RÉSUMÉ ===" -ForegroundColor Magenta
[PSCustomObject]@{
    TotalComptes       = $TotalUsers
    Membres            = $Members
    Invités            = $Guests
    ComptesActifs      = $ActiveUsers
    ComptesDesactivés  = $DisabledUsers
    AvecLicence        = $Licensed
    SansLicence        = $Unlicensed
    FichiersExportés   = "Identity_Audit_All / Disabled / Unlicensed — $Timestamp"
    DossierExport      = $ExportPath
} | Format-List

Write-Host "=== FIN DE L'AUDIT DES IDENTITÉS ===" -ForegroundColor Green

# ========================================================================================
# NETTOYAGE MÉMOIRE
# ========================================================================================
Remove-Variable Scopes, ExportPath, Timestamp, AllUsers, Report, Row,
               TotalUsers, Members, Guests, ActiveUsers, DisabledUsers,
               Licensed, Unlicensed, DisabledReport, UnlicensedReport,
               CsvAll, CsvDisabled, CsvUnlicensed `
               -ErrorAction SilentlyContinue

# ========================================================================================
# FERMETURE — RESET DE SESSION TOTAL
# ========================================================================================
Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
Write-Host "Session MgGraph fermée proprement." -ForegroundColor Magenta
