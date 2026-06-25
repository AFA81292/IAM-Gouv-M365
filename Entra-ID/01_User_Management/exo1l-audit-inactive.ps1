# ========================================================================================
# Exercice 1l : Entra ID — Audit des comptes inactifs
# ========================================================================================
# Concept : Un compte inactif est un compte membre (userType = "Member") dont le
# propriétaire ne s'est plus connecté depuis X jours — ou n'a jamais connecté.
# Ces comptes représentent une surface d'attaque : un attaquant qui compromet
# un compte dormant peut opérer longtemps sans déclencher d'alerte comportementale.
#
# Ce script catégorise les comptes membres en 4 niveaux d'inactivité :
#   - Jamais connectés                  → compte créé, jamais utilisé
#   - Inactifs depuis > 30 jours        → premier seuil d'alerte
#   - Inactifs depuis > 90 jours        → seuil standard de revue
#   - Inactifs depuis > 180 jours       → candidats à la désactivation/suppression
#
# Delta pédagogique vs exercice 1k (audit invités) :
#   1k → focus sur les comptes GUEST (externes), avec analyse du statut d'invitation
#   1l → focus sur les comptes MEMBER (internes), avec segmentation par seuil d'inactivité
#        et distinction inactif / jamais connecté / désactivé
#
# Delta pédagogique vs exercice 1j (audit global) :
#   1j → inventaire exhaustif tous types confondus — vue de surface
#   1l → drill-down inactivité membres uniquement, avec 4 seuils et export par segment
#
# Ce que fait ce script :
#   1. Reset total de session
#   2. Récupère tous les comptes membres actifs du tenant
#   3. Construit la vue normalisée avec calcul d'inactivité
#   4. Segmente par seuil (jamais connectés, 30j, 90j, 180j)
#   5. Affiche chaque segment
#   6. Affiche un résumé chiffré
#   7. Exporte les résultats en CSV horodatés
#   8. Ferme proprement toutes les sessions
#
# Note : ce script est en lecture seule — aucune modification du tenant.
#
# Fichiers CSV générés :
#   Inactive_NeverConnected_YYYYMMDD_HHmmss.csv  → jamais connectés
#   Inactive_30d_YYYYMMDD_HHmmss.csv             → inactifs > 30 jours
#   Inactive_90d_YYYYMMDD_HHmmss.csv             → inactifs > 90 jours
#   Inactive_180d_YYYYMMDD_HHmmss.csv            → inactifs > 180 jours
#   Inactive_Overview_YYYYMMDD_HHmmss.csv        → tous les membres, vue complète
#
# Prérequis licence : aucune licence P1/P2 requise pour la lecture.
# La propriété SignInActivity nécessite le rôle Reports Reader, Security Reader
# ou Global Admin sur le compte connecté.
#
# Module requis : Microsoft.Graph.Users
# Connexion     : Connect-MgGraph
# ========================================================================================

# --- OUVERTURE — RESET DE SESSION TOTAL ---
# User.Read.All     : lire tous les comptes membres du tenant
# AuditLog.Read.All : accéder à la propriété SignInActivity (dernière connexion)
#
# REX : même piège que l'exo 1k — SignInActivity doit être demandée explicitement
# via -Property. Sans AuditLog.Read.All, elle revient null pour tous les utilisateurs
# et classerait tout le monde comme "jamais connecté".
$Scopes = @(
    "User.Read.All",
    "AuditLog.Read.All"
)

Disconnect-MgGraph -ErrorAction SilentlyContinue
Connect-MgGraph -Scopes $Scopes -NoWelcome

# ========================================================================================
# ÉTAPE 1 : Définition des seuils d'inactivité
# ========================================================================================
Write-Host "1. Définition des seuils d'inactivité..." -ForegroundColor Cyan

# Trois seuils cumulatifs — un compte inactif 180j est aussi inactif 90j et 30j.
# Les CSV sont distincts pour permettre des actions graduées :
#   > 30j  → alerte / notification manager
#   > 90j  → revue d'accès obligatoire
#   > 180j → désactivation recommandée (exo 1e), suppression possible (exo 1h)
#
# Variante : un seul seuil configurable (approche exo 1k)
#   $InactivityThresholdDays = 90
#   $Cutoff = (Get-Date).AddDays(-$InactivityThresholdDays)
# Ici on préfère 3 seuils distincts pour produire un rapport gradué.
$Cutoff30  = (Get-Date).AddDays(-30)
$Cutoff90  = (Get-Date).AddDays(-90)
$Cutoff180 = (Get-Date).AddDays(-180)

Write-Host "-> Seuil 30j  : avant le $($Cutoff30.ToString('dd/MM/yyyy'))" -ForegroundColor Green
Write-Host "-> Seuil 90j  : avant le $($Cutoff90.ToString('dd/MM/yyyy'))" -ForegroundColor Green
Write-Host "-> Seuil 180j : avant le $($Cutoff180.ToString('dd/MM/yyyy'))`n" -ForegroundColor Green

# ========================================================================================
# ÉTAPE 2 : Récupération des comptes membres actifs
# ========================================================================================
Write-Host "2. Récupération des comptes membres actifs..." -ForegroundColor Cyan

# Filtre OData : userType eq 'Member' — exclut les invités (traités en 1k).
# accountEnabled eq true — on cible les comptes actifs uniquement.
# Un compte désactivé ne peut pas se connecter — l'inactivité est mécanique,
# pas comportementale. Les inclure fausserait le rapport.
#
# Variante : inclure les comptes désactivés pour un audit exhaustif
#   Retirer "and accountEnabled eq true" du filtre
#   Ajouter AccountEnabled comme colonne dans le rapport
#   Utile pour détecter des comptes désactivés mais non supprimés depuis longtemps
$AllMembers = Get-MgUser -All `
    -Filter "userType eq 'Member' and accountEnabled eq true" `
    -Property "Id, DisplayName, UserPrincipalName, Department, JobTitle,
               CreatedDateTime, AccountEnabled, SignInActivity" `
    -ErrorAction Stop

Write-Host "-> $($AllMembers.Count) compte(s) membre(s) actif(s) récupéré(s).`n" -ForegroundColor Green

if ($AllMembers.Count -eq 0) {
    Write-Host "Aucun membre actif à analyser. Fin du script." -ForegroundColor Yellow
    Disconnect-MgGraph -ErrorAction SilentlyContinue
    return
}

# ========================================================================================
# ÉTAPE 3 : Construction de la vue normalisée
# ========================================================================================
Write-Host "3. Construction de la vue normalisée..." -ForegroundColor Cyan

$MemberRows = foreach ($Member in $AllMembers) {

    $LastSignIn = $Member.SignInActivity.LastSignInDateTime

    # Calcul du nombre de jours depuis la dernière connexion interactive.
    # $null = jamais connecté — on retourne $null pour le distinguer explicitement
    # de "0 jours" (connecté aujourd'hui).
    $DaysSinceSignIn = if ($LastSignIn) {
        [int]((Get-Date) - [datetime]$LastSignIn).TotalDays
    } else { $null }

    # Catégorisation en une seule passe — évite de recalculer dans chaque étape.
    # Ordre des conditions : du plus ancien au plus récent pour que le label
    # reflète le seuil le plus sévère atteint.
    #
    # "JamaisConnecté" : aucune trace dans les logs — compte créé mais jamais utilisé.
    # "> 180j"         : inactif très long terme — candidat à la désactivation.
    # "> 90j"          : inactif standard — à soumettre à une revue d'accès.
    # "> 30j"          : inactif court terme — à surveiller.
    # "Actif"          : connexion dans les 30 derniers jours.
    $Category = if ($null -eq $DaysSinceSignIn)         { "JamaisConnecté" }
                elseif ($DaysSinceSignIn -gt 180)        { ">180j" }
                elseif ($DaysSinceSignIn -gt 90)         { ">90j" }
                elseif ($DaysSinceSignIn -gt 30)         { ">30j" }
                else                                     { "Actif" }

    [PSCustomObject]@{
        DisplayName                  = $Member.DisplayName
        UPN                          = $Member.UserPrincipalName
        Department                   = $Member.Department
        JobTitle                     = $Member.JobTitle
        CreatedDateTime              = $Member.CreatedDateTime
        LastSignInDateTime           = $LastSignIn
        # LastNonInteractiveSignIn : utile pour détecter les comptes "dormants côté humain"
        # mais actifs côté applicatif (refresh tokens, sync AAD Connect, etc.)
        # Non inclus dans les filtres d'inactivité — on cible la connexion humaine.
        LastNonInteractiveSignIn     = $Member.SignInActivity.LastNonInteractiveSignInDateTime
        DaysSinceLastSignIn          = $DaysSinceSignIn
        Category                     = $Category
        Id                           = $Member.Id
    }
}

Write-Host "-> Vue normalisée construite ($($MemberRows.Count) lignes).`n" -ForegroundColor Green

# ========================================================================================
# ÉTAPE 4 : Affichage par segment
# ========================================================================================

# --- Segment 1 : Jamais connectés ---
Write-Host "4. Segmentation par seuil d'inactivité..." -ForegroundColor Cyan
Write-Host "`n=== JAMAIS CONNECTÉS ===" -ForegroundColor Red
Write-Host "Compte créé, aucune connexion enregistrée :`n" -ForegroundColor Gray

$NeverConnected = $MemberRows | Where-Object { $_.Category -eq "JamaisConnecté" }

if ($NeverConnected.Count -gt 0) {
    $NeverConnected |
        Sort-Object CreatedDateTime |
        Select-Object DisplayName, UPN, Department, JobTitle, CreatedDateTime |
        Format-Table -AutoSize
} else {
    Write-Host "-> Aucun compte sans connexion.`n" -ForegroundColor Green
}

# --- Segment 2 : Inactifs > 180 jours ---
Write-Host "`n=== INACTIFS > 180 JOURS ===" -ForegroundColor Red
Write-Host "Candidats prioritaires à la désactivation :`n" -ForegroundColor Gray

# On exclut les jamais-connectés de ce segment — ils ont leur propre CSV.
# Inclure les ">90j" ici aussi les ferait apparaître dans deux CSV distincts,
# ce qui peut prêter à confusion dans un rapport.
$Inactive180 = $MemberRows | Where-Object { $_.Category -eq ">180j" }

if ($Inactive180.Count -gt 0) {
    $Inactive180 |
        Sort-Object DaysSinceLastSignIn -Descending |
        Select-Object DisplayName, UPN, Department, DaysSinceLastSignIn, LastSignInDateTime |
        Format-Table -AutoSize
} else {
    Write-Host "-> Aucun compte inactif depuis plus de 180 jours.`n" -ForegroundColor Green
}

# --- Segment 3 : Inactifs > 90 jours ---
Write-Host "`n=== INACTIFS > 90 JOURS ===" -ForegroundColor Yellow
Write-Host "Candidats à la revue d'accès (hors > 180j) :`n" -ForegroundColor Gray

$Inactive90 = $MemberRows | Where-Object { $_.Category -eq ">90j" }

if ($Inactive90.Count -gt 0) {
    $Inactive90 |
        Sort-Object DaysSinceLastSignIn -Descending |
        Select-Object DisplayName, UPN, Department, DaysSinceLastSignIn, LastSignInDateTime |
        Format-Table -AutoSize
} else {
    Write-Host "-> Aucun compte dans ce segment.`n" -ForegroundColor Green
}

# --- Segment 4 : Inactifs > 30 jours ---
Write-Host "`n=== INACTIFS > 30 JOURS ===" -ForegroundColor Yellow
Write-Host "Premier seuil d'alerte (hors > 90j et > 180j) :`n" -ForegroundColor Gray

$Inactive30 = $MemberRows | Where-Object { $_.Category -eq ">30j" }

if ($Inactive30.Count -gt 0) {
    $Inactive30 |
        Sort-Object DaysSinceLastSignIn -Descending |
        Select-Object DisplayName, UPN, Department, DaysSinceLastSignIn, LastSignInDateTime |
        Format-Table -AutoSize
} else {
    Write-Host "-> Aucun compte dans ce segment.`n" -ForegroundColor Green
}

# ========================================================================================
# ÉTAPE 5 : Vue d'ensemble — tous les membres
# ========================================================================================
Write-Host "5. Vue d'ensemble complète..." -ForegroundColor Cyan
Write-Host "`n=== VUE D'ENSEMBLE — TOUS LES MEMBRES ACTIFS ===" -ForegroundColor Cyan
Write-Host "Triés par catégorie d'inactivité :`n" -ForegroundColor Gray

# Ordre d'affichage : du plus préoccupant au moins préoccupant.
# On force l'ordre des catégories via un index numérique — Sort-Object sur string
# trierait alphabétiquement (">180j" avant ">30j") ce qui n'est pas l'ordre voulu.
$CategoryOrder = @{
    "JamaisConnecté" = 0
    ">180j"          = 1
    ">90j"           = 2
    ">30j"           = 3
    "Actif"          = 4
}

$MemberRows |
    Sort-Object { $CategoryOrder[$_.Category] }, DaysSinceLastSignIn -Descending |
    Select-Object DisplayName, UPN, Department, Category,
                  DaysSinceLastSignIn, LastSignInDateTime |
    Format-Table -AutoSize

# ========================================================================================
# ÉTAPE 6 : Résumé chiffré
# ========================================================================================
Write-Host "`n=== RÉSUMÉ ===" -ForegroundColor Magenta

$ActiveCount = ($MemberRows | Where-Object { $_.Category -eq "Actif" }).Count

[PSCustomObject]@{
    TotalMembresActifs  = $AllMembers.Count
    JamaisConnectés     = $NeverConnected.Count
    "Inactifs_>_180j"   = $Inactive180.Count
    "Inactifs_>_90j"    = $Inactive90.Count
    "Inactifs_>_30j"    = $Inactive30.Count
    ActifsRécemment     = $ActiveCount
    Scope               = "User.Read.All + AuditLog.Read.All (lecture seule)"
    NoteAudit           = "Comptes désactivés exclus du périmètre — filtre accountEnabled eq true"
} | Format-List

Write-Host "=== FIN DE L'AUDIT INACTIVITÉ ===" -ForegroundColor Green

# ========================================================================================
# EXPORT CSV
# ========================================================================================
Write-Host "Export CSV en cours..." -ForegroundColor Cyan

# EN LABO / Local :
$ExportPath = "D:\Documents\ScriptsPowerShell\Exports\"
# EN PRODUCTION :
# $ExportPath = "$PSScriptRoot\Exports\"

New-Item -ItemType Directory -Force -Path $ExportPath | Out-Null
$Timestamp = Get-Date -Format "yyyyMMdd_HHmmss"

# --- CSV 1 : Vue d'ensemble ---
# Colonnes exportées : DisplayName, UPN, Department, JobTitle, CreatedDateTime,
#                      LastSignInDateTime, LastNonInteractiveSignIn,
#                      DaysSinceLastSignIn, Category, Id
# Colonnes disponibles non exportées :
#   $Member.AccountEnabled     : toujours $true ici (filtre appliqué à la récupération)
#   $Member.AssignedLicenses   : licences du compte — utile pour croiser avec l'inactivité
#                                (licence payante sur compte inactif = gaspillage)
#   $Member.OnPremisesSyncEnabled : compte synchronisé depuis AD on-prem ou cloud-only
#                                    un compte on-prem inactif doit être désactivé dans AD,
#                                    pas dans Entra (la synchro écraserait le changement)
$MemberRows |
    Sort-Object { $CategoryOrder[$_.Category] }, DaysSinceLastSignIn -Descending |
    Export-Csv -Path "$ExportPath\Inactive_Overview_$Timestamp.csv" `
               -Encoding UTF8 -NoTypeInformation
Write-Host "-> Vue d'ensemble : $($MemberRows.Count) ligne(s) — Inactive_Overview_$Timestamp.csv" -ForegroundColor Green

# --- CSV 2 : Jamais connectés ---
if ($NeverConnected.Count -gt 0) {
    $NeverConnected |
        Sort-Object CreatedDateTime |
        Export-Csv -Path "$ExportPath\Inactive_NeverConnected_$Timestamp.csv" `
                   -Encoding UTF8 -NoTypeInformation
    Write-Host "-> Jamais connectés : $($NeverConnected.Count) ligne(s) — Inactive_NeverConnected_$Timestamp.csv" -ForegroundColor Green
} else {
    Write-Host "-> Jamais connectés : aucune donnée à exporter." -ForegroundColor Yellow
}

# --- CSV 3 : Inactifs > 180 jours ---
# Livrable principal pour une campagne de désactivation — exo 1e en suite logique.
if ($Inactive180.Count -gt 0) {
    $Inactive180 |
        Sort-Object DaysSinceLastSignIn -Descending |
        Export-Csv -Path "$ExportPath\Inactive_180d_$Timestamp.csv" `
                   -Encoding UTF8 -NoTypeInformation
    Write-Host "-> Inactifs > 180j : $($Inactive180.Count) ligne(s) — Inactive_180d_$Timestamp.csv" -ForegroundColor Green
} else {
    Write-Host "-> Inactifs > 180j : aucune donnée à exporter." -ForegroundColor Yellow
}

# --- CSV 4 : Inactifs > 90 jours ---
if ($Inactive90.Count -gt 0) {
    $Inactive90 |
        Sort-Object DaysSinceLastSignIn -Descending |
        Export-Csv -Path "$ExportPath\Inactive_90d_$Timestamp.csv" `
                   -Encoding UTF8 -NoTypeInformation
    Write-Host "-> Inactifs > 90j : $($Inactive90.Count) ligne(s) — Inactive_90d_$Timestamp.csv" -ForegroundColor Green
} else {
    Write-Host "-> Inactifs > 90j : aucune donnée à exporter." -ForegroundColor Yellow
}

# --- CSV 5 : Inactifs > 30 jours ---
if ($Inactive30.Count -gt 0) {
    $Inactive30 |
        Sort-Object DaysSinceLastSignIn -Descending |
        Export-Csv -Path "$ExportPath\Inactive_30d_$Timestamp.csv" `
                   -Encoding UTF8 -NoTypeInformation
    Write-Host "-> Inactifs > 30j : $($Inactive30.Count) ligne(s) — Inactive_30d_$Timestamp.csv" -ForegroundColor Green
} else {
    Write-Host "-> Inactifs > 30j : aucune donnée à exporter." -ForegroundColor Yellow
}

Write-Host "-> Export terminé dans : $ExportPath`n" -ForegroundColor Green

# ========================================================================================
# NETTOYAGE MÉMOIRE
# ========================================================================================
Remove-Variable Scopes, Cutoff30, Cutoff90, Cutoff180,
                AllMembers, MemberRows, Member, LastSignIn, DaysSinceSignIn, Category,
                NeverConnected, Inactive180, Inactive90, Inactive30, ActiveCount,
                CategoryOrder, ExportPath, Timestamp `
                -ErrorAction SilentlyContinue

# ========================================================================================
# FERMETURE — RESET DE SESSION TOTAL
# ========================================================================================
Disconnect-MgGraph -ErrorAction SilentlyContinue
Write-Host "Session MgGraph fermée proprement." -ForegroundColor Magenta
