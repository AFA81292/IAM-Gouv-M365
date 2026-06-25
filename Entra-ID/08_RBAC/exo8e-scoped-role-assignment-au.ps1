# ========================================================================================
# Exercice 8e : Entra ID — RBAC — Assignation d'un rôle scopé à une Administrative Unit
# ========================================================================================
# Concept : Une assignation scopée à une AU limite l'autorité d'un admin au périmètre
# de cette AU uniquement — il ne peut pas agir sur les objets hors périmètre.
# C'est le mécanisme de délégation granulaire d'Entra ID.
#
# Cas d'usage typiques en mission :
#   → IT local d'un pays/région : User Administrator scopé à l'AU "France"
#   → Helpdesk d'une BU : Password Administrator scopé à l'AU "BU Finance"
#   → Auditeur externe : Authentication Administrator scopé à l'AU "Projet X"
#
# Différence clé vs assignation tenant-wide (exo 8b) :
#
#   TYPE D'ASSIGNATION  | DirectoryScopeId               | Portée réelle
#   --------------------|--------------------------------|---------------------------------------
#   Tenant-wide (8b)    | "/"                            | Tous les objets du tenant
#   Scopée AU (8e)      | "/administrativeUnits/{au-id}" | Uniquement les membres de l'AU ← ICI
#
# Rôles supportés pour le scope AU (liste partielle) :
#   "User Administrator"             → créer/modifier/supprimer les users de l'AU
#   "Helpdesk Administrator"         → reset MFA et password des users de l'AU
#   "Password Administrator"         → réinitialiser le password uniquement
#   "Authentication Administrator"   → gérer les méthodes d'auth des users de l'AU
#   "Groups Administrator"           → gérer les groupes membres de l'AU
#   "License Administrator"          → attribuer des licences aux users de l'AU
#
# IMPORTANT — rôles NON scopables à une AU :
#   Global Administrator, Security Administrator, Exchange Administrator...
#   Ces rôles sont "tenant-wide only" par design Microsoft — le scope AU est ignoré.
#   Tenter de les assigner scopés retourne une erreur Graph.
#
# Ce que fait ce script :
#   1. Reset total de session
#   2. Résout le rôle built-in par nom
#   3. Résout l'utilisateur cible par UPN
#   4. Résout l'AU cible par nom
#   5. Vérifie qu'aucune assignation identique n'existe déjà
#   6. Crée l'assignation scopée à l'AU
#   7. Vérifie depuis la source de vérité
#   8. Affiche un résumé
#   9. Ferme proprement toutes les sessions
#
# Delta pédagogique vs exercice 8b (rôle built-in tenant-wide) :
#   8b → assignation tenant-wide "/" + 3 modes (permanent / PIM éligible / PIM time-bound)
#   8e → assignation scopée AU "/administrativeUnits/{id}" + mode permanent direct
#        (le scope AU et PIM peuvent se combiner — hors périmètre de cet exo de dev)
#
# Delta pédagogique vs exercice 2a (AU statique + délégation) :
#   2a → création de l'AU + peuplement + assignation scopée en une passe (workflow complet)
#   8e → focus RBAC pur : l'AU existe déjà, on y assigne un rôle scopé
#        Idéal pour illustrer la cmdlet et le DirectoryScopeId en isolation
#
# Module requis : Microsoft.Graph.Identity.Governance, Microsoft.Graph.Users,
#                 Microsoft.Graph.Identity.DirectoryManagement
# Connexion     : Connect-MgGraph
# ========================================================================================

# --- OUVERTURE — RESET DE SESSION TOTAL ---
# RoleManagement.ReadWrite.Directory : créer des assignations de rôles Entra
# AdministrativeUnit.Read.All        : lire les AUs pour résoudre le nom en ID
# User.Read.All                      : résoudre l'UPN cible en ObjectId
#
# -ContextScope Process : requis pour bypasser le cache WAM sur ce scope d'écriture.
# Sans ce paramètre — 403 systématique. Voir note WAM chapitre 05_Conditional_Access.
$Scopes = @(
    "RoleManagement.ReadWrite.Directory",
    "AdministrativeUnit.Read.All",
    "User.Read.All"
)

Disconnect-MgGraph -ErrorAction SilentlyContinue
Connect-MgGraph -Scopes $Scopes -ContextScope Process -NoWelcome

# ========================================================================================
# ÉTAPE 1 : Définition des variables
# ========================================================================================
Write-Host "1. Définition des variables..." -ForegroundColor Cyan

# Rôle à assigner — doit être scopable à une AU (voir liste en en-tête).
# Exemples de rôles courants pour délégation AU :
#   "Helpdesk Administrator"       → reset MFA + password sur les users de l'AU
#   "User Administrator"           → CRUD complet sur les users membres de l'AU
#   "Password Administrator"       → reset password uniquement (moins large que Helpdesk)
#   "Authentication Administrator" → gérer les méthodes d'auth (MFA, SSPR) de l'AU
#   "License Administrator"        → attribuer/retirer des licences aux users de l'AU
$RoleName = "Helpdesk Administrator"

# Utilisateur à qui on délègue le rôle.
$TargetUPN = "geralt@0n4mg.onmicrosoft.com"

# Nom de l'AU cible — résolu en ID à l'étape 4.
# L'AU doit exister avant l'exécution de ce script.
# Pour créer une AU statique → exo 2a | AU dynamique → exo 2b
$AUName = "Kaer-Morhen-Staff"

Write-Host "-> Rôle cible   : $RoleName" -ForegroundColor Green
Write-Host "-> Utilisateur  : $TargetUPN" -ForegroundColor Green
Write-Host "-> AU cible     : $AUName`n" -ForegroundColor Green

# ========================================================================================
# ÉTAPE 2 : Résolution du rôle built-in par nom
# ========================================================================================
Write-Host "2. Résolution du rôle '$RoleName'..." -ForegroundColor Cyan

# Variante avec filtre OData côté API (plus efficace sur grands tenants) :
#   $RoleDef = Get-MgRoleManagementDirectoryRoleDefinition `
#       -Filter "DisplayName eq '$RoleName'" -ErrorAction SilentlyContinue
$RoleDef = Get-MgRoleManagementDirectoryRoleDefinition -All |
    Where-Object { $_.DisplayName -eq $RoleName } |
    Select-Object -First 1

if (-not $RoleDef) {
    Write-Host "-> ERREUR : rôle '$RoleName' introuvable." -ForegroundColor Red
    Write-Host "   Lister les rôles disponibles : Get-MgRoleManagementDirectoryRoleDefinition -All | Select-Object DisplayName" -ForegroundColor Yellow
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
    Disconnect-MgGraph -ErrorAction SilentlyContinue
    return
}

Write-Host "-> Utilisateur trouvé : $($TargetUser.DisplayName) [ID : $($TargetUser.Id)]`n" -ForegroundColor Green

# ========================================================================================
# ÉTAPE 4 : Résolution de l'AU cible par nom
# ========================================================================================
Write-Host "4. Résolution de l'AU '$AUName'..." -ForegroundColor Cyan

# On résout l'AU par DisplayName pour éviter de coder le GUID en dur.
# Le GUID d'une AU est propre à chaque tenant — contrairement aux rôles built-in
# dont les GUIDs sont stables entre tenants Microsoft.
#
# Variante avec filtre OData côté API :
#   $TargetAU = Get-MgDirectoryAdministrativeUnit `
#       -Filter "DisplayName eq '$AUName'" -ErrorAction SilentlyContinue |
#       Select-Object -First 1
$TargetAU = Get-MgDirectoryAdministrativeUnit -All |
    Where-Object { $_.DisplayName -eq $AUName } |
    Select-Object -First 1

if (-not $TargetAU) {
    Write-Host "-> ERREUR : AU '$AUName' introuvable dans le tenant." -ForegroundColor Red
    Write-Host "   Lister les AUs disponibles : Get-MgDirectoryAdministrativeUnit -All | Select-Object DisplayName, Id" -ForegroundColor Yellow
    Disconnect-MgGraph -ErrorAction SilentlyContinue
    return
}

Write-Host "-> AU trouvée : $($TargetAU.DisplayName) [ID : $($TargetAU.Id)]" -ForegroundColor Green
Write-Host "   Type       : $($TargetAU.MembershipType)" -ForegroundColor Gray

# Construction du DirectoryScopeId — format imposé par Graph pour les assignations AU.
# Format : "/administrativeUnits/{au-id}"
# Différent de l'assignation tenant-wide qui utilise simplement "/".
$DirectoryScopeId = "/administrativeUnits/$($TargetAU.Id)"
Write-Host "   ScopeId    : $DirectoryScopeId`n" -ForegroundColor Gray

# ========================================================================================
# ÉTAPE 5 : Vérification d'une assignation existante (idempotence)
# ========================================================================================
Write-Host "5. Vérification d'une assignation existante..." -ForegroundColor Cyan

# DÉCOUVERTE TECHNIQUE : les assignations scopées à une AU sont stockées dans le même
# endpoint que les assignations tenant-wide (/roleManagement/directory/roleAssignments).
# La distinction se fait uniquement sur DirectoryScopeId :
#   "/"                               → tenant-wide
#   "/administrativeUnits/{au-id}"    → scopée à l'AU
# Un utilisateur peut avoir le même rôle en tenant-wide ET scopé à une AU simultanément
# — ce sont deux objets distincts dans Graph. L'idempotence doit vérifier le ScopeId exact.
$Existing = Get-MgRoleManagementDirectoryRoleAssignment -All |
    Where-Object {
        $_.PrincipalId      -eq $TargetUser.Id     -and
        $_.RoleDefinitionId -eq $RoleDef.Id        -and
        $_.DirectoryScopeId -eq $DirectoryScopeId
    } | Select-Object -First 1

if ($Existing) {
    Write-Host "-> ATTENTION : assignation identique déjà existante sur cette AU." -ForegroundColor Yellow
    Write-Host "   ID : $($Existing.Id)" -ForegroundColor Yellow
    Write-Host "   Aucune action effectuée — fin du script.`n" -ForegroundColor Yellow
    Disconnect-MgGraph -ErrorAction SilentlyContinue
    return
}

Write-Host "-> Aucune assignation existante sur cette AU — création possible.`n" -ForegroundColor Green

# ========================================================================================
# ÉTAPE 6 : Création de l'assignation scopée à l'AU
# ========================================================================================
Write-Host "6. Création de l'assignation scopée à l'AU..." -ForegroundColor Cyan

# New-MgRoleManagementDirectoryRoleAssignment est la même cmdlet que pour une assignation
# tenant-wide (exo 8b MODE 1). La seule différence : DirectoryScopeId pointe vers l'AU
# au lieu de "/". Le scope change tout — les droits sont limités aux membres de l'AU.
#
# IMPORTANT : ce script utilise l'assignation directe permanente (hors PIM).
# Combiner scope AU + PIM éligible est techniquement possible via
# New-MgRoleManagementDirectoryRoleEligibilityScheduleRequest avec le même DirectoryScopeId.
# Non couvert ici pour rester dans le périmètre d'un exercice de dev lisible.
# En production → toujours préférer PIM éligible, même pour les assignations AU.
$AssignmentParams = @{
    PrincipalId      = $TargetUser.Id
    RoleDefinitionId = $RoleDef.Id
    DirectoryScopeId = $DirectoryScopeId
}

try {
    $NewAssignment = New-MgRoleManagementDirectoryRoleAssignment `
        -BodyParameter $AssignmentParams -ErrorAction Stop
    Write-Host "-> Assignation scopée créée [ID : $($NewAssignment.Id)]" -ForegroundColor Green
    Write-Host "   $($TargetUser.DisplayName) est '$RoleName' sur l'AU '$AUName' uniquement.`n" -ForegroundColor Green
}
catch {
    Write-Host "-> ERREUR : $_" -ForegroundColor Red
    Write-Host "   Si le message mentionne 'roleTemplateId' ou 'scope' : ce rôle n'est pas scopable à une AU." -ForegroundColor Yellow
    Write-Host "   Rôles non scopables : Global Admin, Security Admin, Exchange Admin..." -ForegroundColor Yellow
    Disconnect-MgGraph -ErrorAction SilentlyContinue
    return
}

# ========================================================================================
# ÉTAPE 7 : Vérification post-assignation depuis la source de vérité
# ========================================================================================
Write-Host "7. Vérification post-assignation..." -ForegroundColor Cyan

# REX : la propagation Graph post-création n'est pas instantanée.
# 30 secondes couvrent la latence backend standard.
Start-Sleep -Seconds 30

# Vérification via l'endpoint des assignations standards —
# même endpoint que l'étape 5, on relit la source de vérité après propagation.
$CheckAssignment = Get-MgRoleManagementDirectoryRoleAssignment -All |
    Where-Object {
        $_.PrincipalId      -eq $TargetUser.Id     -and
        $_.RoleDefinitionId -eq $RoleDef.Id        -and
        $_.DirectoryScopeId -eq $DirectoryScopeId
    } | Select-Object -First 1

# Variante : vérification via l'endpoint AU dédié (retourne les rôles scopés à une AU spécifique)
# Get-MgDirectoryAdministrativeUnitScopedRoleMember -AdministrativeUnitId $TargetAU.Id |
#     Where-Object { $_.RoleMemberInfo.Id -eq $TargetUser.Id }
# Avantage : périmètre naturellement limité à l'AU, résultat plus rapide sur grands tenants.
# Inconvénient : ne retourne pas le RoleDefinitionId directement — résolution en deux passes.

if ($CheckAssignment) {
    Write-Host "-> Assignation confirmée depuis la source de vérité :" -ForegroundColor Green
    [PSCustomObject]@{
        AssignationId    = $CheckAssignment.Id
        Utilisateur      = $TargetUser.DisplayName
        UPN              = $TargetUser.UserPrincipalName
        Rôle             = $RoleDef.DisplayName
        PérimètreType    = "Administrative Unit"
        PérimètreNom     = $TargetAU.DisplayName
        DirectoryScopeId = $CheckAssignment.DirectoryScopeId
    } | Format-List
} else {
    Write-Host "-> ATTENTION : assignation non trouvée lors de la vérification." -ForegroundColor Red
    Write-Host "   Relancer l'exo 8d pour confirmer après quelques minutes." -ForegroundColor Yellow
}

# ========================================================================================
# ÉTAPE 8 : Résumé
# ========================================================================================
Write-Host "=== RÉSUMÉ ===" -ForegroundColor Magenta
[PSCustomObject]@{
    Opération        = "Assignation de rôle scopée à une AU"
    Utilisateur      = $TargetUser.DisplayName
    UPN              = $TargetUser.UserPrincipalName
    Rôle             = $RoleDef.DisplayName
    AU               = $TargetAU.DisplayName
    DirectoryScopeId = $DirectoryScopeId
    AssignationId    = if ($CheckAssignment) { $CheckAssignment.Id } else { $NewAssignment.Id }
    NoteProduction   = "Combiner avec PIM éligible en prod — voir exo 6b pour le workflow PIM"
    LienExos         = "2a (création AU) → 8e (délégation scopée) → 8c (révocation)"
} | Format-List

# ========================================================================================
# NETTOYAGE MÉMOIRE
# ========================================================================================
Remove-Variable Scopes, RoleName, TargetUPN, AUName,
                RoleDef, TargetUser, TargetAU, DirectoryScopeId,
                Existing, AssignmentParams, NewAssignment, CheckAssignment `
                -ErrorAction SilentlyContinue

# ========================================================================================
# FERMETURE — RESET DE SESSION TOTAL
# ========================================================================================
Disconnect-MgGraph -ErrorAction SilentlyContinue
Write-Host "Session MgGraph fermée proprement." -ForegroundColor Magenta
