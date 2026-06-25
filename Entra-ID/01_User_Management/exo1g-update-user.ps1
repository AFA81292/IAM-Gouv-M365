# ========================================================================================
# Exercice 1g : Entra ID — Modification d'attributs d'un utilisateur
# ========================================================================================
# Concept : Mettre à jour les attributs d'un utilisateur existant — opération courante
# en mission IAM lors d'un changement de poste, de département, de manager ou de pays.
# Les attributs Entra sont la source de vérité pour les règles dynamiques (groupes,
# Administrative Units) — un attribut mal renseigné peut exclure un utilisateur
# d'un groupe ou d'une AU sans que personne ne s'en rende compte.
#
# Ce que fait ce script :
#   1. Reset total de session
#   2. Vérifie l'existence du compte dans Entra
#   3. Affiche les attributs actuels avant modification
#   4. Met à jour Department, JobTitle et UsageLocation via Update-MgUser
#   5. Met à jour le Manager via Set-MgUserManagerByRef (API séparée)
#   6. Confirme les modifications par relecture
#   7. Ferme proprement toutes les sessions
#
# Pourquoi le Manager est une API séparée ?
#   Le manager n'est pas un attribut scalaire (string, bool) — c'est une relation
#   OData vers un autre objet utilisateur. Graph expose cette relation via un endpoint
#   dédié (/users/{id}/manager/$ref) qui requiert une cmdlet distincte :
#   Set-MgUserManagerByRef au lieu de Update-MgUser.
#
# Attributs couverts dans cet exercice :
#   - Department      : département (source de vérité pour les groupes dynamiques)
#   - JobTitle        : intitulé de poste
#   - UsageLocation   : code pays ISO 3166-1 alpha-2 (FR, US, GB...) — obligatoire
#                       avant toute attribution de licence M365 (exo 1c)
#   - Manager         : relation OData vers l'objet utilisateur du manager
#
# Attributs disponibles non couverts (variantes commentées) :
#   - City, Country, OfficeLocation, PostalCode, State, StreetAddress
#   - MobilePhone, BusinessPhones
#   - CompanyName, EmployeeId, EmployeeType
#   - DisplayName, GivenName, Surname (modification du nom affiché)
#
# Module requis : Microsoft.Graph.Users
# Connexion     : Connect-MgGraph
# ========================================================================================

# --- OUVERTURE — RESET DE SESSION TOTAL ---
# User.ReadWrite.All : modifier les attributs d'un objet utilisateur
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

# UPN du compte à modifier.
$TargetUPN = "shepard@0n4mg.onmicrosoft.com"

# Nouvelles valeurs à appliquer.
# En production : récupérées depuis un ticket RH, un CSV de mutation, ou un SIRH.
$NewDepartment    = "N7-SpecOps"
$NewJobTitle      = "Commander"
$NewUsageLocation = "FR"
$NewManagerUPN    = "anderson@0n4mg.onmicrosoft.com"

Write-Host "-> Compte cible   : $TargetUPN" -ForegroundColor Green
Write-Host "-> Département    : $NewDepartment" -ForegroundColor Green
Write-Host "-> Intitulé poste : $NewJobTitle" -ForegroundColor Green
Write-Host "-> UsageLocation  : $NewUsageLocation" -ForegroundColor Green
Write-Host "-> Manager        : $NewManagerUPN`n" -ForegroundColor Green

# ========================================================================================
# ÉTAPE 2 : Vérification de l'existence du compte
# ========================================================================================
Write-Host "2. Vérification du compte dans Entra..." -ForegroundColor Cyan

try {
    $UserObject = Get-MgUser -UserId $TargetUPN `
        -Property Id, DisplayName, UserPrincipalName, Department, JobTitle, UsageLocation `
        -ErrorAction Stop
}
catch {
    Write-Host "-> Erreur : compte '$TargetUPN' introuvable dans Entra." -ForegroundColor Red
    Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
    return
}

Write-Host "-> Compte trouvé : $($UserObject.DisplayName) ($($UserObject.UserPrincipalName))`n" -ForegroundColor Green

# ========================================================================================
# ÉTAPE 3 : Affichage des attributs actuels
# ========================================================================================
Write-Host "3. Attributs actuels avant modification :" -ForegroundColor Cyan

# On lit le manager séparément — c'est une relation OData, pas un attribut scalaire.
# Get-MgUserManager retourne l'objet manager complet ; on en extrait le DisplayName.
$CurrentManager = Get-MgUserManager -UserId $UserObject.Id -ErrorAction SilentlyContinue

[PSCustomObject]@{
    Department    = $UserObject.Department
    JobTitle      = $UserObject.JobTitle
    UsageLocation = $UserObject.UsageLocation
    Manager       = if ($CurrentManager) { $CurrentManager.AdditionalProperties["displayName"] } else { "Non défini" }
} | Format-List

# ========================================================================================
# ÉTAPE 4 : Mise à jour des attributs scalaires
# ========================================================================================
Write-Host "4. Mise à jour des attributs (Department, JobTitle, UsageLocation)..." -ForegroundColor Cyan

try {
    # Update-MgUser accepte les attributs scalaires directement en paramètres nommés.
    # Pas besoin de -BodyParameter ici — contrairement à AccountEnabled (booléen),
    # les attributs string sont correctement gérés par les paramètres directs du module Graph.
    # On regroupe toutes les modifications en un seul appel API pour limiter les requêtes.
    Update-MgUser -UserId $UserObject.Id `
        -Department    $NewDepartment `
        -JobTitle      $NewJobTitle `
        -UsageLocation $NewUsageLocation `
        -ErrorAction Stop

    Write-Host "-> Attributs mis à jour." -ForegroundColor Green
}
catch {
    Write-Host "-> Erreur lors de la mise à jour des attributs : $_" -ForegroundColor Red
    Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
    return
}

# --- VARIANTE : Attributs supplémentaires disponibles ---
# Ces attributs peuvent être ajoutés au bloc Update-MgUser ci-dessus selon le besoin.
# Ils suivent tous le même pattern — paramètre nommé directement sur Update-MgUser.
#
# Update-MgUser -UserId $UserObject.Id `
#     -City            "Paris" `
#     -Country         "France" `
#     -OfficeLocation  "Tour Eiffel - Bureau 42" `
#     -PostalCode      "75007" `
#     -MobilePhone     "+33 6 00 00 00 00" `
#     -CompanyName     "Cerberus Corp" `
#     -EmployeeId      "EMP-12345" `
#     -DisplayName     "John Shepard (N7)" `
#     -GivenName       "John" `
#     -Surname         "Shepard"
#
# Note DisplayName : modifier le DisplayName en PowerShell ne modifie pas
# automatiquement le GivenName et le Surname — les trois sont des attributs indépendants.
# En production, les modifier ensemble garantit la cohérence dans les annuaires.

# ========================================================================================
# ÉTAPE 5 : Mise à jour du manager
# ========================================================================================
Write-Host "`n5. Mise à jour du manager ($NewManagerUPN)..." -ForegroundColor Cyan

try {
    # Résolution de l'UPN du manager en ObjectId — Set-MgUserManagerByRef requiert l'Id,
    # pas l'UPN. L'API Graph ne résout pas les UPN directement sur les endpoints de relation.
    $ManagerObject = Get-MgUser -UserId $NewManagerUPN -ErrorAction Stop

    # Syntaxe OData imposée par l'API Graph pour les liaisons par référence (@odata.id).
    # Le manager est une relation vers un objet utilisateur — on passe l'URL complète
    # de l'objet cible. Même pattern que New-MgGroupOwnerByRef (exo 3a/3b).
    $ManagerRef = @{
        "@odata.id" = "https://graph.microsoft.com/v1.0/users/$($ManagerObject.Id)"
    }

    Set-MgUserManagerByRef -UserId $UserObject.Id -BodyParameter $ManagerRef -ErrorAction Stop
    Write-Host "-> Manager mis à jour : $($ManagerObject.DisplayName)" -ForegroundColor Green
}
catch {
    Write-Host "-> Erreur lors de la mise à jour du manager : $_" -ForegroundColor Red
}

# --- VARIANTE : Supprimer le manager ---
# Pour retirer le manager d'un utilisateur (départ du manager, réorg sans remplaçant) :
#
# Remove-MgUserManagerByRef -UserId $UserObject.Id
#
# Après suppression, Get-MgUserManager retourne $null — le champ Manager
# apparaît vide dans Entra Admin Center et dans Outlook/Teams.

# ========================================================================================
# ÉTAPE 6 : Confirmation par relecture
# ========================================================================================
Write-Host "`n6. Confirmation par relecture..." -ForegroundColor Cyan

# On relit l'objet depuis l'API pour confirmer que les modifications ont bien été persistées.
# Ne pas se fier aux variables en mémoire — elles reflètent l'état avant modification.
$Verification = Get-MgUser -UserId $UserObject.Id `
    -Property Id, DisplayName, UserPrincipalName, Department, JobTitle, UsageLocation

$VerifManager = Get-MgUserManager -UserId $UserObject.Id -ErrorAction SilentlyContinue

Write-Host "-> Attributs après modification :" -ForegroundColor Green
[PSCustomObject]@{
    DisplayName   = $Verification.DisplayName
    UPN           = $Verification.UserPrincipalName
    Department    = $Verification.Department
    JobTitle      = $Verification.JobTitle
    UsageLocation = $Verification.UsageLocation
    Manager       = if ($VerifManager) { $VerifManager.AdditionalProperties["displayName"] } else { "Non défini" }
} | Format-List

# --- VARIANTE : Export d'audit horodaté ---
# À ajouter après la relecture pour traçabilité RH/SSI lors d'une mutation.
# Capture l'état avant et après pour chaque attribut modifié.
#
# $AuditRow = [PSCustomObject]@{
#     Date              = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
#     UPN               = $TargetUPN
#     DisplayName       = $UserObject.DisplayName
#     DeptAvant         = $UserObject.Department
#     DeptAprès         = $NewDepartment
#     JobTitleAvant     = $UserObject.JobTitle
#     JobTitleAprès     = $NewJobTitle
#     UsageLocAvant     = $UserObject.UsageLocation
#     UsageLocAprès     = $NewUsageLocation
#     ManagerAvant      = if ($CurrentManager) { $CurrentManager.AdditionalProperties["displayName"] } else { "Non défini" }
#     ManagerAprès      = $NewManagerUPN
#     EffectuéPar       = (Get-MgContext).Account
# }
# $AuditRow | Export-Csv -Path "D:\Exports\AttributeUpdate_Audit.csv" -Encoding UTF8 -NoTypeInformation -Append

# ========================================================================================
# RÉSUMÉ
# ========================================================================================
Write-Host "=== RÉSUMÉ ===" -ForegroundColor Magenta
[PSCustomObject]@{
    CompteModifié  = $TargetUPN
    Department     = "$($UserObject.Department) → $NewDepartment"
    JobTitle       = "$($UserObject.JobTitle) → $NewJobTitle"
    UsageLocation  = "$($UserObject.UsageLocation) → $NewUsageLocation"
    Manager        = "$(if ($CurrentManager) { $CurrentManager.AdditionalProperties['displayName'] } else { 'Non défini' }) → $NewManagerUPN"
    PointAttention = "Si Department a changé, vérifier l'impact sur les groupes et AUs dynamiques"
} | Format-List

Write-Host "=== FIN ===" -ForegroundColor Green

# ========================================================================================
# NETTOYAGE MÉMOIRE
# ========================================================================================
Remove-Variable Scopes, TargetUPN, NewDepartment, NewJobTitle, NewUsageLocation,
               NewManagerUPN, UserObject, CurrentManager, ManagerObject, ManagerRef,
               Verification, VerifManager `
               -ErrorAction SilentlyContinue

# ========================================================================================
# FERMETURE — RESET DE SESSION TOTAL
# ========================================================================================
Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
Write-Host "Session MgGraph fermée proprement." -ForegroundColor Magenta
