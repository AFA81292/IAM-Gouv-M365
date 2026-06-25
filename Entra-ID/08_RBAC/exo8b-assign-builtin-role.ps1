# ========================================================================================
# Exercice 8b : Entra ID — RBAC — Assignation d'un rôle built-in
# ========================================================================================
# Concept : Assigner un rôle Entra built-in est l'opération RBAC la plus fréquente
# en mission IAM — onboarding d'un admin helpdesk, délégation d'un Security Reader
# à un auditeur externe, provisioning d'un User Administrator pour un IT local.
# Cette opération crée une assignation permanente tenant-wide (hors PIM).
# Pour une assignation temporaire ou avec activation sur demande → exos 6b/6c (PIM).
#
# Ce script couvre le cycle complet d'une assignation :
#   - Résolution du rôle par nom (pas de GUID à mémoriser)
#   - Vérification de l'assignation existante avant création (idempotence)
#   - Création de l'assignation via New-MgRoleManagementDirectoryRoleAssignment
#   - Vérification post-assignation depuis la source de vérité
#
# Delta pédagogique vs exercice 8c (désassignation) :
#   8b → création d'une assignation — opération d'onboarding / délégation
#   8c → suppression d'une assignation — pendant logique, offboarding / révocation
#
# Delta pédagogique vs exercices 6b/6c (PIM) :
#   6b/6c → assignation via PIM : éligible sur demande ou active time-bound
#            traçabilité complète, justification obligatoire, expiration automatique
#   8b    → assignation directe permanente : accès immédiat sans activation,
#            sans expiration — réservé aux comptes de service ou break-glass
#            En production, préférer PIM pour tous les rôles sensibles.
#
# Ce que fait ce script :
#   1. Reset total de session
#   2. Résout le rôle built-in par son nom lisible
#   3. Résout l'utilisateur cible par UPN
#   4. Vérifie qu'aucune assignation identique n'existe déjà
#   5. Crée l'assignation de rôle
#   6. Vérifie l'assignation depuis la source de vérité
#   7. Affiche un résumé
#   8. Ferme proprement toutes les sessions
#
# Module requis : Microsoft.Graph.Identity.Governance, Microsoft.Graph.Users
# Connexion     : Connect-MgGraph
# ========================================================================================

# --- OUVERTURE — RESET DE SESSION TOTAL ---
# RoleManagement.ReadWrite.Directory : créer des assignations de rôles Entra
# User.Read.All                      : résoudre l'UPN cible en ObjectId
#
# -ContextScope Process : requis pour bypasser le cache WAM sur ce scope.
# Sans ce paramètre — 403 systématique sur New-MgRoleManagementDirectoryRoleAssignment.
# Voir note WAM chapitre 05_Conditional_Access — même mécanisme, même solution.
$Scopes = @(
    "RoleManagement.ReadWrite.Directory",
    "User.Read.All"
)

Disconnect-MgGraph -ErrorAction SilentlyContinue
Connect-MgGraph -Scopes $Scopes -ContextScope Process -NoWelcome

# ========================================================================================
# ÉTAPE 1 : Définition des variables
# ========================================================================================
Write-Host "1. Définition des variables..." -ForegroundColor Cyan

# Rôle à assigner — nom lisible, résolu en GUID à l'étape suivante.
# Exemples de rôles built-in courants en mission IAM :
#   "Helpdesk Administrator"       → reset MFA, réinitialisation password users non-admin
#   "User Administrator"           → créer/modifier/supprimer users et groupes
#   "Security Reader"              → lecture Defender, Purview, CA — idéal auditeur externe
#   "Security Administrator"       → modifier les politiques sécurité (CA, MFA, Defender)
#   "Reports Reader"               → accès aux rapports d'utilisation et de connexion
#   "Guest Inviter"                → inviter des utilisateurs externes (B2B)
#   "Application Administrator"    → gérer les app registrations et enterprise apps
#   "Cloud Device Administrator"   → gérer les devices Entra (BitLocker, désactivation)
$RoleName   = "Helpdesk Administrator"

# Utilisateur cible — UPN complet.
# Sur un tenant de dev, remplacer par un UPN existant.
$TargetUPN  = "geralt@0n4mg.onmicrosoft.com"

# Périmètre de l'assignation.
# "/" = tenant-wide (toute l'organisation) — valeur standard pour une assignation directe.
# Pour une assignation scopée à une AU → exo 8e.
# Pour une assignation scopée à une ressource Azure → hors périmètre (module Az, RBAC Azure).
$DirectoryScope = "/"

Write-Host "-> Rôle cible   : $RoleName" -ForegroundColor Green
Write-Host "-> Utilisateur  : $TargetUPN" -ForegroundColor Green
Write-Host "-> Périmètre    : $DirectoryScope (tenant-wide)`n" -ForegroundColor Green

# ========================================================================================
# ÉTAPE 2 : Résolution du rôle built-in par nom
# ========================================================================================
Write-Host "2. Résolution du rôle '$RoleName'..." -ForegroundColor Cyan

# On résout le rôle par DisplayName pour éviter de manipuler des GUIDs.
# Les GUIDs des rôles built-in sont stables entre tenants Microsoft,
# mais les nommer explicitement rend le script lisible et maintenable.
#
# Variante avec filtre OData côté API (plus efficace sur grands tenants) :
#   $RoleDef = Get-MgRoleManagementDirectoryRoleDefinition `
#       -Filter "DisplayName eq '$RoleName'" -ErrorAction SilentlyContinue
# On utilise -All + Where-Object ici pour la clarté pédagogique — même résultat.
$RoleDef = Get-MgRoleManagementDirectoryRoleDefinition -All |
    Where-Object { $_.DisplayName -eq $RoleName } |
    Select-Object -First 1

if (-not $RoleDef) {
    Write-Host "-> ERREUR : rôle '$RoleName' introuvable dans le tenant." -ForegroundColor Red
    Write-Host "   Vérifier le nom exact via : Get-MgRoleManagementDirectoryRoleDefinition -All | Select-Object DisplayName" -ForegroundColor Yellow
    Disconnect-MgGraph -ErrorAction SilentlyContinue
    return
}

Write-Host "-> Rôle trouvé : $($RoleDef.DisplayName) [ID : $($RoleDef.Id)]" -ForegroundColor Green
Write-Host "   IsBuiltIn   : $($RoleDef.IsBuiltIn)" -ForegroundColor Gray
Write-Host "   Description : $($RoleDef.Description)`n" -ForegroundColor Gray

# ========================================================================================
# ÉTAPE 3 : Résolution de l'utilisateur cible
# ========================================================================================
Write-Host "3. Résolution de l'utilisateur '$TargetUPN'..." -ForegroundColor Cyan

$TargetUser = Get-MgUser -UserId $TargetUPN -ErrorAction SilentlyContinue

if (-not $TargetUser) {
    Write-Host "-> ERREUR : utilisateur '$TargetUPN' introuvable." -ForegroundColor Red
    Write-Host "   Vérifier l'UPN via : Get-MgUser -All | Select-Object UserPrincipalName" -ForegroundColor Yellow
    Disconnect-MgGraph -ErrorAction SilentlyContinue
    return
}

Write-Host "-> Utilisateur trouvé : $($TargetUser.DisplayName) [ID : $($TargetUser.Id)]`n" -ForegroundColor Green

# ========================================================================================
# ÉTAPE 4 : Vérification d'une assignation existante (idempotence)
# ========================================================================================
Write-Host "4. Vérification d'une assignation existante..." -ForegroundColor Cyan

# On vérifie avant de créer — Graph retournerait une erreur si l'assignation existe déjà,
# mais le message d'erreur natif est peu lisible. On préfère un contrôle explicite
# avec un message clair et une sortie propre.
#
# Filtre OData : on cible la combinaison exacte PrincipalId + RoleDefinitionId + DirectoryScopeId.
# Sans le filtre DirectoryScopeId, on pourrait manquer une assignation scopée à une AU
# et créer un doublon tenant-wide.
$ExistingAssignment = Get-MgRoleManagementDirectoryRoleAssignment -All |
    Where-Object {
        $_.PrincipalId       -eq $TargetUser.Id -and
        $_.RoleDefinitionId  -eq $RoleDef.Id    -and
        $_.DirectoryScopeId  -eq $DirectoryScope
    } | Select-Object -First 1

if ($ExistingAssignment) {
    Write-Host "-> ATTENTION : $($TargetUser.DisplayName) possède déjà le rôle '$RoleName' sur '$DirectoryScope'." -ForegroundColor Yellow
    Write-Host "   ID assignation existante : $($ExistingAssignment.Id)" -ForegroundColor Yellow
    Write-Host "   Aucune action effectuée — fin du script.`n" -ForegroundColor Yellow
    Disconnect-MgGraph -ErrorAction SilentlyContinue
    return
}

Write-Host "-> Aucune assignation existante — création possible.`n" -ForegroundColor Green

# ========================================================================================
# ÉTAPE 5 : Création de l'assignation de rôle
# ========================================================================================
Write-Host "5. Création de l'assignation de rôle..." -ForegroundColor Cyan

# New-MgRoleManagementDirectoryRoleAssignment crée une assignation permanente directe.
# Paramètres obligatoires :
#   PrincipalId      : ObjectId de l'utilisateur (ou groupe, ou SP) qui reçoit le rôle
#   RoleDefinitionId : Id de la définition de rôle (built-in ou custom)
#   DirectoryScopeId : périmètre — "/" pour tenant-wide, "/administrativeUnits/{id}" pour AU
#
# Note : cette cmdlet crée une assignation de type "Assigned" permanent.
# Elle N'EST PAS équivalente à une activation PIM — pas de justification, pas d'expiration,
# pas de workflow d'approbation. Pour un rôle sensible en production → exo 6b (PIM éligible).
$AssignmentParams = @{
    PrincipalId      = $TargetUser.Id
    RoleDefinitionId = $RoleDef.Id
    DirectoryScopeId = $DirectoryScope
}

try {
    $NewAssignment = New-MgRoleManagementDirectoryRoleAssignment `
        -BodyParameter $AssignmentParams -ErrorAction Stop
    Write-Host "-> Assignation créée [ID : $($NewAssignment.Id)]`n" -ForegroundColor Green
}
catch {
    Write-Host "-> ERREUR lors de la création de l'assignation : $_" -ForegroundColor Red
    Disconnect-MgGraph -ErrorAction SilentlyContinue
    return
}

# ========================================================================================
# ÉTAPE 6 : Vérification post-assignation depuis la source de vérité
# ========================================================================================
Write-Host "6. Vérification post-assignation..." -ForegroundColor Cyan

# REX : la propagation Graph post-création n'est pas instantanée.
# On attend 15 secondes avant de relire — évite un faux négatif immédiat.
# En production, sur un tenant à forte charge, augmenter à 30 secondes.
Start-Sleep -Seconds 30

$CheckAssignment = Get-MgRoleManagementDirectoryRoleAssignment -All |
    Where-Object {
        $_.PrincipalId       -eq $TargetUser.Id -and
        $_.RoleDefinitionId  -eq $RoleDef.Id    -and
        $_.DirectoryScopeId  -eq $DirectoryScope
    } | Select-Object -First 1

if ($CheckAssignment) {
    Write-Host "-> Assignation confirmée depuis la source de vérité :" -ForegroundColor Green
    [PSCustomObject]@{
        AssignationId    = $CheckAssignment.Id
        Utilisateur      = $TargetUser.DisplayName
        UPN              = $TargetUser.UserPrincipalName
        PrincipalId      = $CheckAssignment.PrincipalId
        Rôle             = $RoleDef.DisplayName
        RoleDefinitionId = $CheckAssignment.RoleDefinitionId
        Périmètre        = $CheckAssignment.DirectoryScopeId
    } | Format-List
} else {
    Write-Host "-> ATTENTION : assignation non trouvée lors de la vérification." -ForegroundColor Red
    Write-Host "   La propagation peut prendre jusqu'à quelques minutes — relancer l'exo 8d pour confirmer." -ForegroundColor Yellow
}

# ========================================================================================
# ÉTAPE 7 : Résumé
# ========================================================================================
Write-Host "=== RÉSUMÉ ===" -ForegroundColor Magenta
[PSCustomObject]@{
    Opération        = "Assignation de rôle built-in"
    Utilisateur      = $TargetUser.DisplayName
    UPN              = $TargetUser.UserPrincipalName
    Rôle             = $RoleDef.DisplayName
    TypeAssignation  = "Permanente (hors PIM)"
    Périmètre        = "$DirectoryScope (tenant-wide)"
    AssignationId    = if ($CheckAssignment) { $CheckAssignment.Id } else { $NewAssignment.Id }
    NoteProduction   = "Préférer PIM (exo 6b) pour les rôles sensibles en production"
} | Format-List

# ========================================================================================
# NETTOYAGE MÉMOIRE
# ========================================================================================
Remove-Variable Scopes, RoleName, TargetUPN, DirectoryScope,
                RoleDef, TargetUser, ExistingAssignment,
                AssignmentParams, NewAssignment, CheckAssignment `
                -ErrorAction SilentlyContinue

# ========================================================================================
# FERMETURE — RESET DE SESSION TOTAL
# ========================================================================================
Disconnect-MgGraph -ErrorAction SilentlyContinue
Write-Host "Session MgGraph fermée proprement." -ForegroundColor Magenta
