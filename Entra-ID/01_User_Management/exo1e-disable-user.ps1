# ========================================================================================
# Exercice 1e : Entra ID — Désactivation d'un compte utilisateur
# ========================================================================================
# Concept : La désactivation est la première étape d'un offboarding — elle coupe
# immédiatement l'accès au tenant sans supprimer le compte ni ses données.
# Le compte reste visible dans Entra, ses licences restent attribuées, ses groupes
# restent intacts. Seule la connexion est bloquée.
#
# Pourquoi désactiver avant de supprimer ?
#   - Permet une période d'observation avant suppression définitive
#   - Conserve les données de l'utilisateur (mailbox, OneDrive) accessibles aux admins
#   - Permet une réactivation rapide en cas d'erreur (exo 1f)
#   - Bonne pratique RH : attendre la fin du préavis avant suppression
#
# Ce que fait ce script :
#   1. Reset total de session
#   2. Vérifie l'existence du compte dans Entra
#   3. Vérifie que le compte n'est pas déjà désactivé
#   4. Désactive le compte via Update-MgUser -BodyParameter @{ accountEnabled = $false }
#   5. Confirme la désactivation par relecture
#   6. Ferme proprement toutes les sessions
#
# Note : AccountEnabled $false = connexion immédiatement bloquée.
# Les tokens actifs (sessions ouvertes) ne sont pas révoqués automatiquement —
# pour une révocation immédiate des sessions en cours, voir la variante commentée
# à l'étape 4 (Revoke-MgUserSignInSession).
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

# UPN du compte à désactiver.
# En production : récupéré depuis un ticket RH, un CSV d'offboarding, ou un pipeline automatisé.
$TargetUPN = "shepard@0n4mg.onmicrosoft.com"

Write-Host "-> Compte cible : $TargetUPN`n" -ForegroundColor Green

# ========================================================================================
# ÉTAPE 2 : Vérification de l'existence du compte
# ========================================================================================
Write-Host "2. Vérification du compte dans Entra..." -ForegroundColor Cyan

# -ErrorAction Stop : force la remontée dans le bloc Catch si l'UPN est introuvable.
# Sans Stop, Get-MgUser retourne $null silencieusement et le script continue
# avec une variable vide — provoquant une erreur cryptique à l'étape suivante.
try {
    $UserObject = Get-MgUser -UserId $TargetUPN `
        -Property Id, DisplayName, UserPrincipalName, AccountEnabled `
        -ErrorAction Stop
}
catch {
    Write-Host "-> Erreur : compte '$TargetUPN' introuvable dans Entra." -ForegroundColor Red
    Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
    return
}

Write-Host "-> Compte trouvé : $($UserObject.DisplayName) ($($UserObject.UserPrincipalName))" -ForegroundColor Green
Write-Host "-> État actuel   : AccountEnabled = $($UserObject.AccountEnabled)`n" -ForegroundColor Green

# ========================================================================================
# ÉTAPE 3 : Vérification de l'état actuel
# ========================================================================================
Write-Host "3. Vérification de l'état actuel..." -ForegroundColor Cyan

# Inutile de désactiver un compte déjà désactivé — l'API Graph accepterait l'opération
# sans erreur, mais le log de traitement serait trompeur ("désactivé" alors qu'il l'était déjà).
if ($UserObject.AccountEnabled -eq $false) {
    Write-Host "-> [SKIP] Compte déjà désactivé — aucune action nécessaire." -ForegroundColor Yellow
    Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
    return
}

Write-Host "-> Compte actif — désactivation en cours...`n" -ForegroundColor Green

# ========================================================================================
# ÉTAPE 4 : Désactivation du compte
# ========================================================================================
Write-Host "4. Désactivation du compte..." -ForegroundColor Cyan

try {
    # -BodyParameter avec hashtable : syntaxe obligatoire sur les versions récentes du
    # module Graph (>= 2.x) pour les propriétés booléennes comme AccountEnabled.
    # Update-MgUser -AccountEnabled $false lève "A positional parameter cannot be found
    # that accepts argument 'False'" — le paramètre direct n'est plus accepté.
    # -BodyParameter passe la valeur directement à l'API REST Graph en JSON — contournement
    # stable et documenté, identique au pattern -BodyParameter de New-MgGroup (exo 3c).
    Update-MgUser -UserId $UserObject.Id -BodyParameter @{ accountEnabled = $false } -ErrorAction Stop
    Write-Host "-> Désactivation appliquée." -ForegroundColor Green
}
catch {
    Write-Host "-> Erreur lors de la désactivation : $_" -ForegroundColor Red
    Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
    return
}

# --- VARIANTE : Désactivation en masse depuis un CSV ---
# À utiliser à la place du bloc try/catch ci-dessus pour traiter une liste d'utilisateurs
# (restructuration, fin de projet). Le CSV doit contenir une colonne UserPrincipalName.
#
# $UsersToDisable = Import-Csv -Path "D:\offboarding.csv" -Delimiter ","
# foreach ($User in $UsersToDisable) {
#     try {
#         $Obj = Get-MgUser -UserId $User.UserPrincipalName -ErrorAction Stop
#         if ($Obj.AccountEnabled -eq $true) {
#             Update-MgUser -UserId $Obj.Id -BodyParameter @{ accountEnabled = $false } -ErrorAction Stop
#             Write-Host "[SUCCESS] $($User.UserPrincipalName) désactivé." -ForegroundColor Green
#         } else {
#             Write-Host "[SKIP]    $($User.UserPrincipalName) déjà désactivé." -ForegroundColor Yellow
#         }
#     }
#     catch {
#         Write-Host "[ERROR]   $($User.UserPrincipalName) — $_" -ForegroundColor Red
#     }
# }

# --- VARIANTE : Révocation immédiate des sessions actives ---
# À ajouter après Update-MgUser dans un contexte de sécurité (incident, départ conflictuel).
# Par défaut, désactiver un compte ne déconnecte pas les sessions déjà ouvertes —
# un utilisateur connecté à Teams ou SharePoint peut continuer à travailler
# jusqu'à l'expiration naturelle de son token (1h pour les access tokens).
#
# Revoke-MgUserSignInSession -UserId $UserObject.Id
#
# Résultat : tous les refresh tokens sont invalidés — l'utilisateur est déconnecté
# de toutes les apps M365 dès la prochaine tentative de rafraîchissement de token.

# ========================================================================================
# ÉTAPE 5 : Confirmation par relecture
# ========================================================================================
Write-Host "`n5. Confirmation par relecture..." -ForegroundColor Cyan

# On relit l'objet depuis l'API pour confirmer que la modification a bien été persistée.
# Ne pas se fier à la variable $UserObject en mémoire — elle reflète l'état avant modification.
$Verification = Get-MgUser -UserId $UserObject.Id `
    -Property Id, DisplayName, UserPrincipalName, AccountEnabled

Write-Host "-> État après désactivation :" -ForegroundColor Green
[PSCustomObject]@{
    DisplayName     = $Verification.DisplayName
    UPN             = $Verification.UserPrincipalName
    AccountEnabled  = $Verification.AccountEnabled
    StatutOpération = if ($Verification.AccountEnabled -eq $false) { "DÉSACTIVÉ ✓" } else { "ÉCHEC ✗" }
} | Format-List

# --- VARIANTE : Export d'audit horodaté ---
# À ajouter après la relecture pour traçabilité RH/SSI.
# -Append permet d'accumuler plusieurs désactivations dans le même fichier de log.
#
# $AuditRow = [PSCustomObject]@{
#     Date        = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
#     UPN         = $TargetUPN
#     DisplayName = $UserObject.DisplayName
#     ÉtatAvant   = "Enabled"
#     ÉtatAprès   = "Disabled"
#     EffectuéPar = (Get-MgContext).Account
# }
# $AuditRow | Export-Csv -Path "D:\Exports\Offboarding_Audit.csv" -Encoding UTF8 -NoTypeInformation -Append

# ========================================================================================
# RÉSUMÉ
# ========================================================================================
Write-Host "=== RÉSUMÉ ===" -ForegroundColor Magenta
[PSCustomObject]@{
    CompteTraité    = $TargetUPN
    ÉtatAvant       = "AccountEnabled = True"
    ÉtatAprès       = "AccountEnabled = False"
    SessionsActives = "Non révoquées (voir variante Revoke-MgUserSignInSession à l'étape 4)"
    ÉtapeSuivante   = "Retrait des licences (exo 1i) / Suppression (exo 1h) / Réactivation si erreur (exo 1f)"
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
