# ========================================================================================
# Exercice 1f : Entra ID — Réactivation d'un compte utilisateur
# ========================================================================================
# Concept : La réactivation est le pendant logique de l'exo 1e — elle restaure l'accès
# au tenant d'un compte précédemment désactivé. Le compte n'a jamais été supprimé :
# ses licences, ses groupes, ses données (mailbox, OneDrive) sont intacts.
#
# Cas d'usage typiques :
#   - Erreur d'offboarding (mauvais compte désactivé)
#   - Retour d'un collaborateur après congé longue durée
#   - Réintégration après période de suspension disciplinaire
#   - Test de procédure offboarding/onboarding en environnement de dev
#
# Ce que fait ce script :
#   1. Reset total de session
#   2. Vérifie l'existence du compte dans Entra
#   3. Vérifie que le compte n'est pas déjà actif
#   4. Réactive le compte via Update-MgUser -BodyParameter @{ accountEnabled = $true }
#   5. Confirme la réactivation par relecture
#   6. Ferme proprement toutes les sessions
#
# Delta pédagogique vs exo 1e (désactivation) :
#   1e : AccountEnabled = $false → accès bloqué
#   1f : AccountEnabled = $true  → accès restauré
#   La logique du script est identique — seule la valeur booléenne change.
#   Les deux scripts ensemble illustrent le cycle de vie complet d'un compte.
#
# Note : la réactivation ne restaure pas les sessions révoquées via
# Revoke-MgUserSignInSession — l'utilisateur devra simplement se reconnecter.
# Les licences, groupes et données sont intacts — aucune action supplémentaire requise
# sauf si des licences ont été retirées manuellement pendant la désactivation (exo 1i).
#
# Module requis : Microsoft.Graph.Users
# Connexion     : Connect-MgGraph
# ========================================================================================

# --- OUVERTURE — RESET DE SESSION TOTAL ---
# User.ReadWrite.All : modifier AccountEnabled sur un objet utilisateur
# -ContextScope Process : bypasse le cache WAM — voir REX exercices 5b/5c.
$Scopes = @(
    "User.ReadWrite.All"
)

Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
Connect-MgGraph -Scopes $Scopes -ContextScope Process -NoWelcome

# ========================================================================================
# ÉTAPE 1 : Définition des variables
# ========================================================================================
Write-Host "1. Définition des variables..." -ForegroundColor Cyan

# UPN du compte à réactiver.
# En production : récupéré depuis un ticket RH, une demande de réintégration,
# ou un pipeline de onboarding automatisé.
$TargetUPN = "shepard@0n4mg.onmicrosoft.com"

Write-Host "-> Compte cible : $TargetUPN`n" -ForegroundColor Green

# ========================================================================================
# ÉTAPE 2 : Vérification de l'existence du compte
# ========================================================================================
Write-Host "2. Vérification du compte dans Entra..." -ForegroundColor Cyan

# -ErrorAction Stop : force la remontée dans le bloc Catch si l'UPN est introuvable.
# Un compte supprimé (exo 1h) n'est plus accessible via Get-MgUser — il faut passer
# par Get-MgDirectoryDeletedItemAsUser pour les comptes en corbeille.
try {
    $UserObject = Get-MgUser -UserId $TargetUPN `
        -Property Id, DisplayName, UserPrincipalName, AccountEnabled `
        -ErrorAction Stop
}
catch {
    Write-Host "-> Erreur : compte '$TargetUPN' introuvable dans Entra." -ForegroundColor Red
    Write-Host "   Si le compte a été supprimé, il est peut-être en corbeille (récupérable 30j)." -ForegroundColor Yellow
    Write-Host "   Vérifier via : Get-MgDirectoryDeletedItemAsUser -All" -ForegroundColor Yellow
    Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
    return
}

Write-Host "-> Compte trouvé : $($UserObject.DisplayName) ($($UserObject.UserPrincipalName))" -ForegroundColor Green
Write-Host "-> État actuel   : AccountEnabled = $($UserObject.AccountEnabled)`n" -ForegroundColor Green

# ========================================================================================
# ÉTAPE 3 : Vérification de l'état actuel
# ========================================================================================
Write-Host "3. Vérification de l'état actuel..." -ForegroundColor Cyan

# Inutile de réactiver un compte déjà actif — l'API Graph accepterait l'opération
# sans erreur, mais le log de traitement serait trompeur ("réactivé" alors qu'il l'était déjà).
if ($UserObject.AccountEnabled -eq $true) {
    Write-Host "-> [SKIP] Compte déjà actif — aucune action nécessaire." -ForegroundColor Yellow
    Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
    return
}

Write-Host "-> Compte désactivé — réactivation en cours...`n" -ForegroundColor Green

# ========================================================================================
# ÉTAPE 4 : Réactivation du compte
# ========================================================================================
Write-Host "4. Réactivation du compte..." -ForegroundColor Cyan

try {
    # Même pattern -BodyParameter que l'exo 1e — seul $true remplace $false.
    # Rappel : Update-MgUser -AccountEnabled $true lève une erreur de paramètre
    # positionnel sur les versions récentes du module Graph (>= 2.x).
    # -BodyParameter passe la valeur directement à l'API REST Graph en JSON.
    Update-MgUser -UserId $UserObject.Id -BodyParameter @{ accountEnabled = $true } -ErrorAction Stop
    Write-Host "-> Réactivation appliquée." -ForegroundColor Green
}
catch {
    Write-Host "-> Erreur lors de la réactivation : $_" -ForegroundColor Red
    Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
    return
}

# --- VARIANTE : Réactivation en masse depuis un CSV ---
# À utiliser à la place du bloc try/catch ci-dessus pour traiter une liste d'utilisateurs
# (retour de congé collectif, correction d'une désactivation en masse erronée).
# Le CSV doit contenir une colonne UserPrincipalName.
#
# $UsersToEnable = Import-Csv -Path "D:\reactivation.csv" -Delimiter ","
# foreach ($User in $UsersToEnable) {
#     try {
#         $Obj = Get-MgUser -UserId $User.UserPrincipalName -ErrorAction Stop
#         if ($Obj.AccountEnabled -eq $false) {
#             Update-MgUser -UserId $Obj.Id -BodyParameter @{ accountEnabled = $true } -ErrorAction Stop
#             Write-Host "[SUCCESS] $($User.UserPrincipalName) réactivé." -ForegroundColor Green
#         } else {
#             Write-Host "[SKIP]    $($User.UserPrincipalName) déjà actif." -ForegroundColor Yellow
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

# On relit l'objet depuis l'API pour confirmer que la modification a bien été persistée.
# Ne pas se fier à la variable $UserObject en mémoire — elle reflète l'état avant modification.
$Verification = Get-MgUser -UserId $UserObject.Id `
    -Property Id, DisplayName, UserPrincipalName, AccountEnabled

Write-Host "-> État après réactivation :" -ForegroundColor Green
[PSCustomObject]@{
    DisplayName     = $Verification.DisplayName
    UPN             = $Verification.UserPrincipalName
    AccountEnabled  = $Verification.AccountEnabled
    StatutOpération = if ($Verification.AccountEnabled -eq $true) { "RÉACTIVÉ ✓" } else { "ÉCHEC ✗" }
} | Format-List

# --- VARIANTE : Export d'audit horodaté ---
# À ajouter après la relecture pour traçabilité RH/SSI.
# Utile pour journaliser toutes les réactivations dans un fichier de log centralisé.
# -Append permet d'accumuler plusieurs réactivations dans le même fichier.
#
# $AuditRow = [PSCustomObject]@{
#     Date        = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
#     UPN         = $TargetUPN
#     DisplayName = $UserObject.DisplayName
#     ÉtatAvant   = "Disabled"
#     ÉtatAprès   = "Enabled"
#     EffectuéPar = (Get-MgContext).Account
# }
# $AuditRow | Export-Csv -Path "D:\Exports\Reactivation_Audit.csv" -Encoding UTF8 -NoTypeInformation -Append

# ========================================================================================
# RÉSUMÉ
# ========================================================================================
Write-Host "=== RÉSUMÉ ===" -ForegroundColor Magenta
[PSCustomObject]@{
    CompteTraité   = $TargetUPN
    ÉtatAvant      = "AccountEnabled = False"
    ÉtatAprès      = "AccountEnabled = True"
    LicencesGroupes = "Intacts — aucune action supplémentaire requise"
    PointAttention = "Vérifier que les licences n'ont pas été retirées manuellement pendant la désactivation (exo 1i)"
    ÉtapeSuivante  = "Informer l'utilisateur — il peut se reconnecter immédiatement"
} | Format-List

Write-Host "=== FIN ===" -ForegroundColor Green

# ========================================================================================
# NETTOYAGE MÉMOIRE
# ========================================================================================
Remove-Variable Scopes, TargetUPN, UserObject, Verification `
    -ErrorAction SilentlyContinue

# ========================================================================================
# FERMETURE — RESET DE SESSION TOTAL
# ========================================================================================
Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
Write-Host "Session MgGraph fermée proprement." -ForegroundColor Magenta
