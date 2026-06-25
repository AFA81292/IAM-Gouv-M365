# ========================================================================================
# Exercice 8c : Entra ID — RBAC — Désassignation d'un rôle
# ========================================================================================
# Concept : Retirer un rôle Entra est l'opération miroir de l'assignation (exo 8b).
# Elle intervient lors d'un offboarding, d'un changement de poste, d'une révocation
# suite à audit, ou d'une expiration manuelle avant terme.
# Comme pour l'assignation, le mode de suppression dépend du mode d'assignation initial —
# on ne supprime pas une assignation PIM éligible avec la même cmdlet qu'une permanente.
#
# Ce script couvre les 3 modes de suppression en miroir de l'exo 8b :
#
#   MODE                        | Cmdlet de suppression                                          | Cmdlet de vérification
#   ----------------------------|----------------------------------------------------------------|------------------------------------------
#   1. Permanente directe       | Remove-MgRoleManagementDirectoryRoleAssignment                 | Get-MgRoleManagementDirectoryRoleAssignment
#   2. PIM éligible             | New-MgRoleManagementDirectoryRoleEligibilityScheduleRequest    | Get-MgRoleManagementDirectoryRoleEligibilitySchedule
#   3. PIM active time-bound    | New-MgRoleManagementDirectoryRoleAssignmentScheduleRequest     | Get-MgRoleManagementDirectoryRoleAssignmentSchedule
#
# Note importante sur les modes PIM (2 et 3) :
#   La suppression PIM ne se fait PAS via une cmdlet Remove-Mg* directe.
#   Elle passe par une nouvelle Request avec Action "adminRemove" —
#   c'est le même endpoint que la création, mais avec une action différente.
#   C'est contre-intuitif mais cohérent avec le modèle Graph PIM : tout passe
#   par des "requests" auditables, y compris les suppressions.
#
# Ce que fait ce script :
#   1. Reset total de session
#   2. Résout le rôle par nom
#   3. Résout l'utilisateur cible par UPN
#   4. Recherche l'assignation existante à supprimer
#   5. Supprime l'assignation selon le mode détecté/choisi
#   6. Vérifie la suppression depuis la source de vérité
#   7. Affiche un résumé
#   8. Ferme proprement toutes les sessions
#
# Delta pédagogique vs exercice 8b (assignation) :
#   8b → création — 3 modes d'assignation, mode PIM éligible par défaut
#   8c → suppression — même structure modulaire, même logique de détection par mode,
#        pendant logique strict pour compléter le cycle de vie d'une assignation RBAC
#
# Module requis : Microsoft.Graph.Identity.Governance, Microsoft.Graph.Users
# Connexion     : Connect-MgGraph
# ========================================================================================

# --- OUVERTURE — RESET DE SESSION TOTAL ---
# RoleManagement.ReadWrite.Directory : supprimer des assignations de rôles Entra (tous modes)
# User.Read.All                      : résoudre l'UPN cible en ObjectId
#
# -ContextScope Process : requis pour bypasser le cache WAM sur ce scope.
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

$RoleName       = "Helpdesk Administrator"
$TargetUPN      = "geralt@0n4mg.onmicrosoft.com"
$DirectoryScope = "/"

# ---- MODE DE SUPPRESSION ----
# Doit correspondre au mode utilisé lors de l'assignation (exo 8b).
# Supprimer une assignation PIM éligible avec le mode "Permanent" échouera
# silencieusement — l'assignation n'est pas trouvée dans le bon endpoint.
#
# $RemovalMode = "Permanent"      # MODE 1 — suppression assignation permanente directe
$RemovalMode = "PimEligible"      # MODE 2 — révocation éligibilité PIM ← DÉFAUT (miroir 8b)
# $RemovalMode = "PimTimeBound"   # MODE 3 — révocation assignation active time-bound

# Justification — obligatoire pour les modes PIM sur certains tenants.
# Bonne pratique : toujours renseigner pour la traçabilité audit.
$RemovalJustification = "Révocation de rôle via script RBAC — exo 8c"

Write-Host "-> Rôle cible   : $RoleName" -ForegroundColor Green
Write-Host "-> Utilisateur  : $TargetUPN" -ForegroundColor Green
Write-Host "-> Périmètre    : $DirectoryScope (tenant-wide)" -ForegroundColor Green
Write-Host "-> Mode         : $RemovalMode`n" -ForegroundColor Green

# ========================================================================================
# ÉTAPE 2 : Résolution du rôle par nom
# ========================================================================================
Write-Host "2. Résolution du rôle '$RoleName'..." -ForegroundColor Cyan

$RoleDef = Get-MgRoleManagementDirectoryRoleDefinition -All |
    Where-Object { $_.DisplayName -eq $RoleName } |
    Select-Object -First 1

if (-not $RoleDef) {
    Write-Host "-> ERREUR : rôle '$RoleName' introuvable." -ForegroundColor Red
    Disconnect-MgGraph -ErrorAction SilentlyContinue
    return
}

Write-Host "-> Rôle trouvé : $($RoleDef.DisplayName) [ID : $($RoleDef.Id)]`n" -ForegroundColor Green

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
# ÉTAPE 4 : Recherche de l'assignation existante
# ========================================================================================
Write-Host "4. Recherche de l'assignation à supprimer..." -ForegroundColor Cyan

# On cherche dans l'endpoint correspondant au mode — même logique que l'étape 4 de l'exo 8b.
# Si l'assignation n'existe pas dans l'endpoint attendu, on sort proprement
# plutôt que de tenter une suppression qui échouerait avec un message cryptique.
$TargetAssignment = $null

if ($RemovalMode -eq "Permanent") {
    $TargetAssignment = Get-MgRoleManagementDirectoryRoleAssignment -All |
        Where-Object {
            $_.PrincipalId      -eq $TargetUser.Id -and
            $_.RoleDefinitionId -eq $RoleDef.Id    -and
            $_.DirectoryScopeId -eq $DirectoryScope
        } | Select-Object -First 1
}
elseif ($RemovalMode -eq "PimEligible") {
    $TargetAssignment = Get-MgRoleManagementDirectoryRoleEligibilitySchedule -All |
        Where-Object {
            $_.PrincipalId      -eq $TargetUser.Id -and
            $_.RoleDefinitionId -eq $RoleDef.Id    -and
            $_.DirectoryScopeId -eq $DirectoryScope
        } | Select-Object -First 1
}
elseif ($RemovalMode -eq "PimTimeBound") {
    $TargetAssignment = Get-MgRoleManagementDirectoryRoleAssignmentSchedule -All |
        Where-Object {
            $_.PrincipalId      -eq $TargetUser.Id -and
            $_.RoleDefinitionId -eq $RoleDef.Id    -and
            $_.DirectoryScopeId -eq $DirectoryScope
        } | Select-Object -First 1
}

if (-not $TargetAssignment) {
    Write-Host "-> ATTENTION : aucune assignation '$RoleName' trouvée pour '$TargetUPN' en mode '$RemovalMode'." -ForegroundColor Yellow
    Write-Host "   Vérifier le mode de suppression — il doit correspondre au mode d'assignation initial." -ForegroundColor Yellow
    Write-Host "   Audit complet des assignations : exo 8d / exo 6a (PIM)." -ForegroundColor Yellow
    Disconnect-MgGraph -ErrorAction SilentlyContinue
    return
}

Write-Host "-> Assignation trouvée [ID : $($TargetAssignment.Id)]" -ForegroundColor Green
Write-Host "   PrincipalId      : $($TargetAssignment.PrincipalId)" -ForegroundColor Gray
Write-Host "   RoleDefinitionId : $($TargetAssignment.RoleDefinitionId)" -ForegroundColor Gray
Write-Host "   DirectoryScopeId : $($TargetAssignment.DirectoryScopeId)`n" -ForegroundColor Gray

# ========================================================================================
# ÉTAPE 5 : Suppression selon le mode
# ========================================================================================
Write-Host "5. Suppression de l'assignation (mode : $RemovalMode)..." -ForegroundColor Cyan

# ------------------------------------------------------------------------------------
# MODE 1 : Suppression permanente directe
# ------------------------------------------------------------------------------------
# Remove-MgRoleManagementDirectoryRoleAssignment prend l'ID de l'assignation.
# Suppression immédiate, irréversible — pas de corbeille pour les assignations RBAC.
# Pour recréer l'assignation après suppression → exo 8b.
if ($RemovalMode -eq "Permanent") {
    try {
        Remove-MgRoleManagementDirectoryRoleAssignment `
            -UnifiedRoleAssignmentId $TargetAssignment.Id -ErrorAction Stop
        Write-Host "-> Assignation permanente supprimée.`n" -ForegroundColor Green
    }
    catch {
        Write-Host "-> ERREUR : $_" -ForegroundColor Red
        Disconnect-MgGraph -ErrorAction SilentlyContinue
        return
    }
}

# ------------------------------------------------------------------------------------
# MODE 2 : Révocation PIM éligible ← MODE PAR DÉFAUT
# ------------------------------------------------------------------------------------
# La suppression d'une éligibilité PIM passe par une nouvelle Request "adminRemove"
# sur le même endpoint que la création (New-MgRoleManagementDirectoryRoleEligibilityScheduleRequest).
# Il n'existe pas de Remove-MgRoleManagementDirectoryRoleEligibilitySchedule directe
# en version stable du module Graph — la Request est le seul chemin supporté.
#
# Action "adminRemove" : révocation administrative de l'éligibilité.
# L'utilisateur ne pourra plus activer ce rôle via PIM une fois la request traitée.
# Les activations en cours ne sont PAS révoquées automatiquement — si l'utilisateur
# a une session active avec ce rôle, elle reste valide jusqu'à son expiration naturelle.
# Pour révoquer une session active → MODE 3 avec "adminRemove" sur l'assignation active.
elseif ($RemovalMode -eq "PimEligible") {

    $RemoveEligibilityParams = @{
        PrincipalId      = $TargetUser.Id
        RoleDefinitionId = $RoleDef.Id
        DirectoryScopeId = $DirectoryScope
        Action           = "adminRemove"
        # ScheduleInfo non requis pour une suppression — Graph ignore ce champ
        # quand Action = "adminRemove". On ne le passe pas pour éviter toute confusion.
        Justification    = $RemovalJustification
    }

    try {
        $RemovalRequest = New-MgRoleManagementDirectoryRoleEligibilityScheduleRequest `
            -BodyParameter $RemoveEligibilityParams -ErrorAction Stop
        Write-Host "-> Request de révocation PIM éligible soumise [ID : $($RemovalRequest.Id)]" -ForegroundColor Green
        Write-Host "   Statut initial : $($RemovalRequest.Status)" -ForegroundColor Gray
        Write-Host "   Note : les activations en cours restent valides jusqu'à leur expiration.`n" -ForegroundColor Yellow
    }
    catch {
        Write-Host "-> ERREUR : $_" -ForegroundColor Red
        Disconnect-MgGraph -ErrorAction SilentlyContinue
        return
    }
}

# ------------------------------------------------------------------------------------
# MODE 3 : Révocation PIM active time-bound
# ------------------------------------------------------------------------------------
# Même logique que MODE 2 — Request "adminRemove" sur l'endpoint des assignations actives.
# Révoque l'accès immédiatement, même si la durée d'assignation n'est pas écoulée.
#
# Cas d'usage : révocation d'urgence suite à incident de sécurité,
# départ anticipé d'un prestataire, erreur d'assignation à corriger.
#
# Variante : pour révoquer TOUTES les assignations actives d'un utilisateur sur un rôle
# (utile en cas de compromission) — boucler sur Get-MgRoleManagementDirectoryRoleAssignmentSchedule
# filtré par PrincipalId et soumettre une Request "adminRemove" pour chacune.
elseif ($RemovalMode -eq "PimTimeBound") {

    $RemoveTimeBoundParams = @{
        PrincipalId      = $TargetUser.Id
        RoleDefinitionId = $RoleDef.Id
        DirectoryScopeId = $DirectoryScope
        Action           = "adminRemove"
        Justification    = $RemovalJustification
    }

    try {
        $RemovalRequest = New-MgRoleManagementDirectoryRoleAssignmentScheduleRequest `
            -BodyParameter $RemoveTimeBoundParams -ErrorAction Stop
        Write-Host "-> Request de révocation PIM active soumise [ID : $($RemovalRequest.Id)]" -ForegroundColor Green
        Write-Host "   Statut initial : $($RemovalRequest.Status)" -ForegroundColor Gray
        Write-Host "   Accès révoqué immédiatement.`n" -ForegroundColor Green
    }
    catch {
        Write-Host "-> ERREUR : $_" -ForegroundColor Red
        Disconnect-MgGraph -ErrorAction SilentlyContinue
        return
    }
}

# ========================================================================================
# ÉTAPE 6 : Vérification post-suppression depuis la source de vérité
# ========================================================================================
Write-Host "6. Vérification post-suppression..." -ForegroundColor Cyan

# REX : la propagation Graph post-suppression n'est pas instantanée.
# On attend 15 secondes avant de relire — même logique que l'exo 8b post-création.
Start-Sleep -Seconds 15

$CheckGone = $null

if ($RemovalMode -eq "Permanent") {
    $CheckGone = Get-MgRoleManagementDirectoryRoleAssignment -All |
        Where-Object {
            $_.PrincipalId      -eq $TargetUser.Id -and
            $_.RoleDefinitionId -eq $RoleDef.Id    -and
            $_.DirectoryScopeId -eq $DirectoryScope
        } | Select-Object -First 1
}
elseif ($RemovalMode -eq "PimEligible") {
    $CheckGone = Get-MgRoleManagementDirectoryRoleEligibilitySchedule -All |
        Where-Object {
            $_.PrincipalId      -eq $TargetUser.Id -and
            $_.RoleDefinitionId -eq $RoleDef.Id    -and
            $_.DirectoryScopeId -eq $DirectoryScope
        } | Select-Object -First 1
}
elseif ($RemovalMode -eq "PimTimeBound") {
    $CheckGone = Get-MgRoleManagementDirectoryRoleAssignmentSchedule -All |
        Where-Object {
            $_.PrincipalId      -eq $TargetUser.Id -and
            $_.RoleDefinitionId -eq $RoleDef.Id    -and
            $_.DirectoryScopeId -eq $DirectoryScope
        } | Select-Object -First 1
}

# On veut que $CheckGone soit null — l'assignation ne doit plus exister.
if (-not $CheckGone) {
    Write-Host "-> Suppression confirmée — assignation absente de la source de vérité.`n" -ForegroundColor Green
} else {
    Write-Host "-> ATTENTION : assignation encore présente après suppression." -ForegroundColor Red
    Write-Host "   ID encore visible : $($CheckGone.Id)" -ForegroundColor Red
    Write-Host "   La propagation peut prendre quelques minutes — relancer l'exo 8d pour confirmer." -ForegroundColor Yellow
}

# ========================================================================================
# ÉTAPE 7 : Résumé
# ========================================================================================
Write-Host "=== RÉSUMÉ ===" -ForegroundColor Magenta
[PSCustomObject]@{
    Opération          = "Désassignation de rôle"
    Utilisateur        = $TargetUser.DisplayName
    UPN                = $TargetUser.UserPrincipalName
    Rôle               = $RoleDef.DisplayName
    Mode               = $RemovalMode
    AssignationSupprimée = $TargetAssignment.Id
    SuppressionConfirmée = (-not $CheckGone)
    NoteProduction     = switch ($RemovalMode) {
        "Permanent"    { "Suppression immédiate et irréversible — pas de corbeille RBAC" }
        "PimEligible"  { "Éligibilité révoquée — activations en cours non affectées" }
        "PimTimeBound" { "Accès actif révoqué immédiatement" }
    }
} | Format-List

# ========================================================================================
# NETTOYAGE MÉMOIRE
# ========================================================================================
Remove-Variable Scopes, RoleName, TargetUPN, DirectoryScope,
                RemovalMode, RemovalJustification, RoleDef, TargetUser,
                TargetAssignment, RemoveEligibilityParams, RemoveTimeBoundParams,
                RemovalRequest, CheckGone `
                -ErrorAction SilentlyContinue

# ========================================================================================
# FERMETURE — RESET DE SESSION TOTAL
# ========================================================================================
Disconnect-MgGraph -ErrorAction SilentlyContinue
Write-Host "Session MgGraph fermée proprement." -ForegroundColor Magenta
