# ========================================================================================
# Exercice 1h : Entra ID — Suppression d'un compte utilisateur
# ========================================================================================
# Concept : La suppression est la dernière étape d'un offboarding — elle retire le compte
# du tenant de manière logique. "Logique" signifie que le compte n'est pas immédiatement
# effacé : il est déplacé dans la corbeille Entra et y reste récupérable pendant 30 jours.
# Passé ce délai, la suppression devient définitive et irréversible.
#
# Cycle de vie complet d'un offboarding (ordre recommandé) :
#   1. Désactivation du compte          (exo 1e) — accès bloqué immédiatement
#   2. Révocation des sessions actives  (variante exo 1e) — déconnexion immédiate
#   3. Retrait des licences             (exo 1i) — libération des seats
#   4. Suppression du compte            (exo 1h, ce script) — corbeille 30 jours
#   5. Suppression définitive           (variante ce script) — si nécessaire avant 30j
#
# Ce que fait ce script :
#   1. Reset total de session
#   2. Vérifie l'existence du compte dans Entra
#   3. Affiche un résumé du compte avant suppression
#   4. Supprime le compte (suppression logique → corbeille Entra)
#   5. Confirme la suppression en vérifiant la présence en corbeille
#   6. Ferme proprement toutes les sessions
#
# Note : Remove-MgUser ne demande pas de confirmation — le script affiche
# un résumé du compte à l'étape 3 pour laisser le temps de vérifier avant
# d'exécuter la suppression. En production, ajouter une confirmation manuelle
# (voir variante à l'étape 4).
#
# Module requis : Microsoft.Graph.Users
# Connexion     : Connect-MgGraph
# ========================================================================================

# --- OUVERTURE — RESET DE SESSION TOTAL ---
# User.ReadWrite.All : supprimer un objet utilisateur
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

# UPN du compte à supprimer.
# En production : récupéré depuis un ticket RH validé, jamais saisi manuellement
# sans double vérification — une suppression est difficile à annuler après 30 jours.
$TargetUPN = "bobjones@0n4mg.onmicrosoft.com"

Write-Host "-> Compte cible : $TargetUPN`n" -ForegroundColor Green

# ========================================================================================
# ÉTAPE 2 : Vérification de l'existence du compte
# ========================================================================================
Write-Host "2. Vérification du compte dans Entra..." -ForegroundColor Cyan

try {
    # On récupère les attributs clés pour le résumé de l'étape 3
    # avant que le compte ne disparaisse du répertoire actif.
    $UserObject = Get-MgUser -UserId $TargetUPN `
        -Property Id, DisplayName, UserPrincipalName, AccountEnabled, Department,
                  JobTitle, AssignedLicenses `
        -ErrorAction Stop
}
catch {
    Write-Host "-> Erreur : compte '$TargetUPN' introuvable dans Entra." -ForegroundColor Red
    Write-Host "   Le compte est peut-être déjà en corbeille." -ForegroundColor Yellow
    Write-Host "   Vérifier via : Get-MgDirectoryDeletedItemAsUser -All" -ForegroundColor Yellow
    Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
    return
}

Write-Host "-> Compte trouvé : $($UserObject.DisplayName) ($($UserObject.UserPrincipalName))`n" -ForegroundColor Green

# ========================================================================================
# ÉTAPE 3 : Résumé du compte avant suppression
# ========================================================================================
Write-Host "3. Résumé du compte avant suppression :" -ForegroundColor Cyan

# Afficher un résumé complet avant toute action destructive.
# En production, ce résumé est la dernière chance de détecter une erreur
# (mauvais compte, licences encore attribuées, compte encore actif).
[PSCustomObject]@{
    DisplayName      = $UserObject.DisplayName
    UPN              = $UserObject.UserPrincipalName
    AccountEnabled   = $UserObject.AccountEnabled
    Department       = $UserObject.Department
    JobTitle         = $UserObject.JobTitle
    LicencesAttrib   = $UserObject.AssignedLicenses.Count
    PointAttention   = if ($UserObject.AccountEnabled -eq $true) {
                           "ATTENTION : compte encore actif — désactiver d'abord (exo 1e)"
                       } elseif ($UserObject.AssignedLicenses.Count -gt 0) {
                           "ATTENTION : $($UserObject.AssignedLicenses.Count) licence(s) encore attribuée(s) — retirer d'abord (exo 1i)"
                       } else {
                           "OK — compte désactivé et sans licence"
                       }
} | Format-List

# ========================================================================================
# ÉTAPE 4 : Suppression du compte
# ========================================================================================
Write-Host "4. Suppression du compte..." -ForegroundColor Cyan

try {
    # Remove-MgUser effectue une suppression logique — le compte est déplacé
    # dans la corbeille Entra (Deleted Users) et y reste 30 jours.
    # Pendant ces 30 jours : le compte est invisible dans Get-MgUser -All,
    # mais récupérable via Get-MgDirectoryDeletedItemAsUser + Restore-MgDirectoryDeletedItem.
    # Après 30 jours : suppression définitive automatique et irréversible.
    Remove-MgUser -UserId $UserObject.Id -ErrorAction Stop
    Write-Host "-> Compte supprimé (logique) — en corbeille Entra pour 30 jours." -ForegroundColor Green
}
catch {
    Write-Host "-> Erreur lors de la suppression : $_" -ForegroundColor Red
    Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
    return
}

# --- VARIANTE : Confirmation manuelle avant suppression ---
# En production, ajouter une demande de confirmation explicite avant Remove-MgUser
# pour éviter toute suppression accidentelle — particulièrement utile en script interactif.
#
# $Confirmation = Read-Host "Confirmer la suppression de '$TargetUPN' ? (oui/non)"
# if ($Confirmation -ne "oui") {
#     Write-Host "-> Suppression annulée." -ForegroundColor Yellow
#     Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
#     return
# }
# Remove-MgUser -UserId $UserObject.Id -ErrorAction Stop

# --- VARIANTE : Suppression définitive immédiate ---
# Si le compte doit être purgé immédiatement sans attendre les 30 jours
# (ex : compte test, données sensibles, contrainte RGPD) :
# Étape 1 — supprimer logiquement avec Remove-MgUser (ci-dessus)
# Étape 2 — purger définitivement depuis la corbeille :
#
# Remove-MgDirectoryDeletedItem -DirectoryObjectId $UserObject.Id
#
# ATTENTION : cette opération est irréversible — aucune restauration possible.
# Le compte, sa mailbox et ses données OneDrive sont définitivement perdus.

# --- VARIANTE : Suppression en masse depuis un CSV ---
# Pour supprimer une liste d'utilisateurs (fin de projet, nettoyage de tenant).
# Le CSV doit contenir une colonne UserPrincipalName.
# Recommandation : désactiver d'abord en masse (exo 1e), attendre validation RH,
# puis supprimer — ne jamais enchaîner désactivation + suppression en une seule passe.
#
# $UsersToDelete = Import-Csv -Path "D:\offboarding_final.csv" -Delimiter ","
# foreach ($User in $UsersToDelete) {
#     try {
#         $Obj = Get-MgUser -UserId $User.UserPrincipalName -ErrorAction Stop
#         Remove-MgUser -UserId $Obj.Id -ErrorAction Stop
#         Write-Host "[SUCCESS] $($User.UserPrincipalName) supprimé." -ForegroundColor Green
#     }
#     catch {
#         Write-Host "[ERROR]   $($User.UserPrincipalName) — $_" -ForegroundColor Red
#     }
# }

# ========================================================================================
# ÉTAPE 5 : Confirmation — vérification en corbeille
# ========================================================================================
Write-Host "`n5. Vérification en corbeille..." -ForegroundColor Cyan

# Après Remove-MgUser, le compte disparaît de Get-MgUser -All mais apparaît dans
# Get-MgDirectoryDeletedItemAsUser. On vérifie sa présence en corbeille pour confirmer
# que la suppression logique a bien été effectuée.
Start-Sleep -Seconds 30

$DeletedUser = Get-MgDirectoryDeletedItemAsUser -All |
    Where-Object { $_.Id -eq $UserObject.Id }

if ($DeletedUser) {
    Write-Host "-> Compte confirmé en corbeille :" -ForegroundColor Green
    [PSCustomObject]@{
        DisplayName = $DeletedUser.DisplayName
        UPN         = $DeletedUser.UserPrincipalName
        Id          = $DeletedUser.Id
        Statut      = "EN CORBEILLE — récupérable 30 jours via Restore-MgDirectoryDeletedItem"
    } | Format-List
} else {
    Write-Host "-> ATTENTION : compte non trouvé en corbeille — vérifier manuellement dans Entra Admin Center." -ForegroundColor Yellow
}

# --- VARIANTE : Restauration depuis la corbeille ---
# Si la suppression était une erreur, restaurer le compte pendant la fenêtre de 30 jours :
#
# Restore-MgDirectoryDeletedItem -DirectoryObjectId $UserObject.Id
#
# Après restauration : le compte redevient visible dans Get-MgUser -All,
# avec ses attributs intacts. Les licences retirées avant suppression ne sont
# PAS restaurées automatiquement — les réattribuer manuellement (exo 1c).

# ========================================================================================
# RÉSUMÉ
# ========================================================================================
Write-Host "=== RÉSUMÉ ===" -ForegroundColor Magenta
[PSCustomObject]@{
    CompteSuppr      = $TargetUPN
    TypeSuppression  = "Logique (corbeille Entra)"
    RécupérableJusqu = (Get-Date).AddDays(30).ToString("yyyy-MM-dd")
    CmdRestoration   = "Restore-MgDirectoryDeletedItem -DirectoryObjectId '$($UserObject.Id)'"
    SuppDéfinitive   = "Automatique après 30 jours, ou manuelle via Remove-MgDirectoryDeletedItem"
} | Format-List

Write-Host "=== FIN ===" -ForegroundColor Green

# ========================================================================================
# NETTOYAGE MÉMOIRE
# ========================================================================================
Remove-Variable Scopes, TargetUPN, UserObject, DeletedUser `
    -ErrorAction SilentlyContinue

# ========================================================================================
# FERMETURE — RESET DE SESSION TOTAL
# ========================================================================================
Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
Write-Host "Session MgGraph fermée proprement." -ForegroundColor Magenta
