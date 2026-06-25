# ========================================================================================
# Exercice 1i : Entra ID — Retrait de licence d'un utilisateur
# ========================================================================================
# Concept : Le retrait de licence libère un seat M365 et coupe l'accès aux services
# associés (Exchange, Teams, SharePoint...). C'est une étape clé de l'offboarding —
# à effectuer après la désactivation (exo 1e) et avant la suppression (exo 1h).
#
# Pourquoi retirer les licences avant de supprimer ?
#   - La suppression d'un compte ne libère pas automatiquement les licences
#     sur certaines configurations tenant — retrait explicite recommandé.
#   - Permet de réattribuer le seat immédiatement à un autre utilisateur.
#   - Traçabilité : le retrait apparaît dans les logs d'audit Entra séparément
#     de la suppression du compte.
#
# Cycle de vie complet d'un offboarding (ordre recommandé) :
#   1. Désactivation du compte          (exo 1e)
#   2. Révocation des sessions actives  (variante exo 1e)
#   3. Retrait des licences             (exo 1i, ce script)
#   4. Suppression du compte            (exo 1h)
#
# Ce que fait ce script :
#   1. Reset total de session
#   2. Vérifie l'existence du compte dans Entra
#   3. Récupère et affiche les licences actuellement attribuées
#   4. Retire toutes les licences via Set-MgUserLicense
#   5. Confirme le retrait par relecture
#   6. Ferme proprement toutes les sessions
#
# Pourquoi Set-MgUserLicense et pas Remove-MgUserLicense ?
#   Il n'existe pas de Remove-MgUserLicense dans le module Graph.
#   Set-MgUserLicense gère à la fois l'ajout et le retrait en un seul appel :
#   -AddLicenses @()          → aucune licence à ajouter
#   -RemoveLicenses @("sku")  → liste des SkuId à retirer
#   C'est le même endpoint API que l'attribution (exo 1c) — sens inverse.
#
# Module requis : Microsoft.Graph.Users
# Connexion     : Connect-MgGraph
# ========================================================================================

# --- OUVERTURE — RESET DE SESSION TOTAL ---
# User.ReadWrite.All    : modifier les licences d'un utilisateur
# Directory.ReadWrite.All : requis par Set-MgUserLicense pour accéder aux SKUs tenant
# -ContextScope Process : bypasse le cache WAM — voir REX exercices 5b/5c.
$Scopes = @(
    "User.ReadWrite.All",
    "Directory.ReadWrite.All"
)

Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
Connect-MgGraph -Scopes $Scopes -ContextScope Process -NoWelcome

# ========================================================================================
# ÉTAPE 1 : Définition des variables
# ========================================================================================
Write-Host "1. Définition des variables..." -ForegroundColor Cyan

# UPN du compte dont on retire les licences.
# En production : récupéré depuis un ticket RH ou un pipeline d'offboarding.
$TargetUPN = "LynneR@0n4mg.onmicrosoft.com"

Write-Host "-> Compte cible : $TargetUPN`n" -ForegroundColor Green

# ========================================================================================
# ÉTAPE 2 : Vérification de l'existence du compte
# ========================================================================================
Write-Host "2. Vérification du compte dans Entra..." -ForegroundColor Cyan

try {
    $UserObject = Get-MgUser -UserId $TargetUPN `
        -Property Id, DisplayName, UserPrincipalName, AssignedLicenses `
        -ErrorAction Stop
}
catch {
    Write-Host "-> Erreur : compte '$TargetUPN' introuvable dans Entra." -ForegroundColor Red
    Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
    return
}

Write-Host "-> Compte trouvé : $($UserObject.DisplayName) ($($UserObject.UserPrincipalName))`n" -ForegroundColor Green

# ========================================================================================
# ÉTAPE 3 : Récupération et affichage des licences attribuées
# ========================================================================================
Write-Host "3. Licences actuellement attribuées..." -ForegroundColor Cyan

# Get-MgUserLicenseDetail retourne les licences avec leur SkuPartNumber lisible
# (ex : "ENTERPRISEPREMIUM") contrairement à AssignedLicenses qui ne retourne
# que le SkuId (GUID) — moins exploitable visuellement.
$CurrentLicenses = Get-MgUserLicenseDetail -UserId $UserObject.Id

if ($CurrentLicenses.Count -eq 0) {
    Write-Host "-> [SKIP] Aucune licence attribuée — aucune action nécessaire." -ForegroundColor Yellow
    Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
    return
}

Write-Host "-> $($CurrentLicenses.Count) licence(s) trouvée(s) :" -ForegroundColor Green
$CurrentLicenses | Select-Object SkuId, SkuPartNumber | Format-Table -AutoSize

# ========================================================================================
# ÉTAPE 4 : Retrait de toutes les licences
# ========================================================================================
Write-Host "4. Retrait des licences..." -ForegroundColor Cyan

# On construit la liste des SkuId à retirer depuis les licences lues à l'étape 3.
# AssignedLicenses.SkuId = GUID de la licence — c'est ce que Set-MgUserLicense attend
# dans -RemoveLicenses. Le SkuPartNumber (nom lisible) n'est pas accepté ici.
$SkuIdsToRemove = $UserObject.AssignedLicenses | Select-Object -ExpandProperty SkuId

try {
    # -AddLicenses @()         : aucune licence à ajouter (tableau vide obligatoire)
    # -RemoveLicenses $SkuIds  : liste des GUIDs à retirer
    # Les deux paramètres sont obligatoires même si l'un des tableaux est vide —
    # l'API Graph retourne une erreur si l'un est absent.
    Set-MgUserLicense -UserId $UserObject.Id `
        -AddLicenses @() `
        -RemoveLicenses $SkuIdsToRemove `
        -ErrorAction Stop

    Write-Host "-> $($SkuIdsToRemove.Count) licence(s) retirée(s)." -ForegroundColor Green
}
catch {
    Write-Host "-> Erreur lors du retrait des licences : $_" -ForegroundColor Red
    Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
    return
}

# --- VARIANTE : Retirer une seule licence spécifique ---
# Pour retirer uniquement une licence précise plutôt que toutes les licences,
# récupérer le SkuId de la licence cible et le passer seul dans -RemoveLicenses.
# Utile quand un utilisateur a plusieurs licences et qu'on n'en retire qu'une
# (ex : retirer Teams sans toucher à Exchange).
#
# $TargetSku = Get-MgSubscribedSku | Where-Object { $_.SkuPartNumber -eq "TEAMS_ESSENTIALS" }
# Set-MgUserLicense -UserId $UserObject.Id -AddLicenses @() -RemoveLicenses @($TargetSku.SkuId)

# --- VARIANTE : Retrait en masse depuis un CSV ---
# Pour retirer toutes les licences d'une liste d'utilisateurs (offboarding collectif).
# Le CSV doit contenir une colonne UserPrincipalName.
#
# $UsersToProcess = Import-Csv -Path "D:\offboarding.csv" -Delimiter ","
# foreach ($User in $UsersToProcess) {
#     try {
#         $Obj = Get-MgUser -UserId $User.UserPrincipalName -Property Id, AssignedLicenses -ErrorAction Stop
#         if ($Obj.AssignedLicenses.Count -gt 0) {
#             $Skus = $Obj.AssignedLicenses | Select-Object -ExpandProperty SkuId
#             Set-MgUserLicense -UserId $Obj.Id -AddLicenses @() -RemoveLicenses $Skus -ErrorAction Stop
#             Write-Host "[SUCCESS] $($User.UserPrincipalName) — $($Skus.Count) licence(s) retirée(s)." -ForegroundColor Green
#         } else {
#             Write-Host "[SKIP]    $($User.UserPrincipalName) — aucune licence." -ForegroundColor Yellow
#         }
#     }
#     catch {
#         Write-Host "[ERROR]   $($User.UserPrincipalName) — $_" -ForegroundColor Red
#     }
# }

# ========================================================================================
# ÉTAPE 5 : Confirmation par relecture
# ========================================================================================
Write-Host "`n5. Confirmation par relecture..." -ForegroundColor Cyan

# On relit les licences depuis l'API pour confirmer que le retrait a bien été persisté.
# Ne pas se fier à $CurrentLicenses en mémoire — elle reflète l'état avant modification.
$VerifLicenses = Get-MgUserLicenseDetail -UserId $UserObject.Id

if ($VerifLicenses.Count -eq 0) {
    Write-Host "-> Aucune licence attribuée — retrait confirmé ✓" -ForegroundColor Green
} else {
    Write-Host "-> ATTENTION : $($VerifLicenses.Count) licence(s) encore présente(s) :" -ForegroundColor Yellow
    $VerifLicenses | Select-Object SkuId, SkuPartNumber | Format-Table -AutoSize
}

# --- VARIANTE : Export d'audit horodaté ---
# À ajouter après la relecture pour traçabilité RH/SSI.
# Capture la liste des licences retirées avec leur SkuPartNumber lisible.
#
# $AuditRows = $CurrentLicenses | ForEach-Object {
#     [PSCustomObject]@{
#         Date        = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
#         UPN         = $TargetUPN
#         DisplayName = $UserObject.DisplayName
#         SkuId       = $_.SkuId
#         Licence     = $_.SkuPartNumber
#         Action      = "Retrait"
#         EffectuéPar = (Get-MgContext).Account
#     }
# }
# $AuditRows | Export-Csv -Path "D:\Exports\LicenceRetrait_Audit.csv" -Encoding UTF8 -NoTypeInformation -Append

# ========================================================================================
# RÉSUMÉ
# ========================================================================================
Write-Host "=== RÉSUMÉ ===" -ForegroundColor Magenta
[PSCustomObject]@{
    CompteTraité    = $TargetUPN
    LicencesRetirées = ($CurrentLicenses | Select-Object -ExpandProperty SkuPartNumber) -join ", "
    LicencesRestantes = $VerifLicenses.Count
    SeatsLibérés    = "Disponibles immédiatement pour réattribution"
    ÉtapeSuivante   = "Suppression du compte (exo 1h)"
} | Format-List

Write-Host "=== FIN ===" -ForegroundColor Green

# ========================================================================================
# NETTOYAGE MÉMOIRE
# ========================================================================================
Remove-Variable Scopes, TargetUPN, UserObject, CurrentLicenses, SkuIdsToRemove,
               VerifLicenses `
               -ErrorAction SilentlyContinue

# ========================================================================================
# FERMETURE — RESET DE SESSION TOTAL
# ========================================================================================
Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
Write-Host "Session MgGraph fermée proprement." -ForegroundColor Magenta
