# ========================================================================================
# Exercice 8b : Entra ID — RBAC — Assignation d'un rôle built-in
# ========================================================================================
# Concept : Assigner un rôle Entra built-in est l'opération RBAC la plus fréquente
# en mission IAM — onboarding d'un admin helpdesk, délégation d'un Security Reader
# à un auditeur externe, provisioning d'un User Administrator pour un IT local.
#
# Il existe 4 modes d'assignation distincts — ce script couvre les 3 premiers,
# le 4e (scopé AU) est dédié à l'exo 8e :
#
#   MODE                        | Cmdlet principale                                        | Expiration | Activation requise
#   ----------------------------|----------------------------------------------------------|------------|-------------------
#   1. Permanente directe       | New-MgRoleManagementDirectoryRoleAssignment              | Non        | Non — accès immédiat
#   2. PIM éligible             | New-MgRoleManagementDirectoryRoleEligibilitySchedule     | Oui        | Oui — sur demande
#   3. PIM active time-bound    | New-MgRoleManagementDirectoryRoleAssignmentScheduleRequest| Oui        | Non — accès immédiat
#   4. Scopée à une AU          | New-MgRoleManagementDirectoryRoleAssignment (scopeId AU) | Non        | Non — voir exo 8e
#
# Bonne pratique production :
#   → MODE 2 (PIM éligible) pour tous les rôles sensibles — c'est le MODE PAR DÉFAUT ici.
#   → MODE 3 (PIM active time-bound) pour les accès temporaires urgents (astreinte, incident).
#   → MODE 1 (permanente) réservé aux comptes break-glass et comptes de service uniquement.
#
# Ce que fait ce script (mode par défaut : PIM éligible) :
#   1. Reset total de session
#   2. Résout le rôle built-in par son nom lisible
#   3. Résout l'utilisateur cible par UPN
#   4. Vérifie qu'aucune assignation identique n'existe déjà
#   5. Crée l'assignation selon le mode choisi
#   6. Vérifie l'assignation depuis la source de vérité
#   7. Affiche un résumé
#   8. Ferme proprement toutes les sessions
#
# Delta pédagogique vs exercices 6b/6c (PIM chapitre dédié) :
#   6b → PIM éligible           : couverture complète du flux PIM (paramètres, audit, REX)
#   6c → PIM active time-bound  : idem, focus time-bound
#   8b → les 3 modes côte à côte dans un contexte RBAC — antiscèche comparative,
#        mode PIM éligible activé par défaut, variantes commentées en place
#
# Module requis : Microsoft.Graph.Identity.Governance, Microsoft.Graph.Users
# Connexion     : Connect-MgGraph
# ========================================================================================

# --- OUVERTURE — RESET DE SESSION TOTAL ---
# RoleManagement.ReadWrite.Directory : créer des assignations de rôles Entra (tous modes)
# User.Read.All                      : résoudre l'UPN cible en ObjectId
#
# -ContextScope Process : requis pour bypasser le cache WAM sur ce scope.
# Sans ce paramètre — 403 systématique sur toutes les cmdlets d'écriture RBAC.
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
$TargetUPN  = "geralt@0n4mg.onmicrosoft.com"

# Périmètre de l'assignation.
# "/" = tenant-wide (toute l'organisation) — valeur standard pour une assignation directe.
# Pour une assignation scopée à une AU → exo 8e.
$DirectoryScope = "/"

# ---- MODE D'ASSIGNATION ----
# Décommenter le mode voulu — un seul actif à la fois.
# MODE 2 (PIM éligible) est activé par défaut — bonne pratique production.
#
# $AssignmentMode = "Permanent"      # MODE 1 — permanente directe, hors PIM
$AssignmentMode = "PimEligible"      # MODE 2 — PIM éligible, activation sur demande ← DÉFAUT
# $AssignmentMode = "PimTimeBound"   # MODE 3 — PIM active time-bound, accès immédiat + expiration

# Durée de l'assignation PIM (modes 2 et 3).
# Ignorée en mode Permanent.
# Valeurs courantes :
#   30  → accès court terme (audit, prestataire ponctuel)
#   90  → durée standard mission (recommandation Microsoft)
#   180 → long terme (poste permanent mais révisable semestriellement)
$PimDurationDays = 90

Write-Host "-> Rôle cible   : $RoleName" -ForegroundColor Green
Write-Host "-> Utilisateur  : $TargetUPN" -ForegroundColor Green
Write-Host "-> Périmètre    : $DirectoryScope (tenant-wide)" -ForegroundColor Green
Write-Host "-> Mode         : $AssignmentMode" -ForegroundColor Green
if ($AssignmentMode -ne "Permanent") {
    Write-Host "-> Durée PIM    : $PimDurationDays jours`n" -ForegroundColor Green
} else {
    Write-Host ""
}

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
    Disconnect-MgGraph -ErrorAction SilentlyContinue
    return
}

Write-Host "-> Utilisateur trouvé : $($TargetUser.DisplayName) [ID : $($TargetUser.Id)]`n" -ForegroundColor Green

# ========================================================================================
# ÉTAPE 4 : Vérification d'une assignation existante (idempotence)
# ========================================================================================
Write-Host "4. Vérification d'une assignation existante..." -ForegroundColor Cyan

# On vérifie selon le mode — une assignation permanente et une assignation PIM éligible
# sont deux objets distincts dans Graph, stockés dans des endpoints différents.
# Un utilisateur peut théoriquement avoir les deux en même temps — ce qu'on veut éviter.
#
# Endpoint permanent  : /roleManagement/directory/roleAssignments
# Endpoint PIM éligible : /roleManagement/directory/roleEligibilitySchedules
# Endpoint PIM active   : /roleManagement/directory/roleAssignmentSchedules

$AlreadyExists = $false

if ($AssignmentMode -eq "Permanent") {
    $Existing = Get-MgRoleManagementDirectoryRoleAssignment -All |
        Where-Object {
            $_.PrincipalId      -eq $TargetUser.Id -and
            $_.RoleDefinitionId -eq $RoleDef.Id    -and
            $_.DirectoryScopeId -eq $DirectoryScope
        } | Select-Object -First 1
    if ($Existing) { $AlreadyExists = $true }
}
elseif ($AssignmentMode -eq "PimEligible") {
    $Existing = Get-MgRoleManagementDirectoryRoleEligibilitySchedule -All |
        Where-Object {
            $_.PrincipalId      -eq $TargetUser.Id -and
            $_.RoleDefinitionId -eq $RoleDef.Id    -and
            $_.DirectoryScopeId -eq $DirectoryScope
        } | Select-Object -First 1
    if ($Existing) { $AlreadyExists = $true }
}
elseif ($AssignmentMode -eq "PimTimeBound") {
    $Existing = Get-MgRoleManagementDirectoryRoleAssignmentSchedule -All |
        Where-Object {
            $_.PrincipalId      -eq $TargetUser.Id -and
            $_.RoleDefinitionId -eq $RoleDef.Id    -and
            $_.DirectoryScopeId -eq $DirectoryScope
        } | Select-Object -First 1
    if ($Existing) { $AlreadyExists = $true }
}

if ($AlreadyExists) {
    Write-Host "-> ATTENTION : assignation identique déjà existante (mode : $AssignmentMode)." -ForegroundColor Yellow
    Write-Host "   ID : $($Existing.Id)" -ForegroundColor Yellow
    Write-Host "   Aucune action effectuée — fin du script.`n" -ForegroundColor Yellow
    Disconnect-MgGraph -ErrorAction SilentlyContinue
    return
}

Write-Host "-> Aucune assignation existante — création possible.`n" -ForegroundColor Green

# ========================================================================================
# ÉTAPE 5 : Création de l'assignation selon le mode choisi
# ========================================================================================
Write-Host "5. Création de l'assignation (mode : $AssignmentMode)..." -ForegroundColor Cyan

$NewAssignment = $null

# ------------------------------------------------------------------------------------
# MODE 1 : Permanente directe (hors PIM)
# ------------------------------------------------------------------------------------
# New-MgRoleManagementDirectoryRoleAssignment crée une assignation permanente directe.
# Pas d'expiration, pas de workflow, pas de justification — accès immédiat.
# Réservé aux comptes break-glass et comptes de service en production.
# Pour tous les autres cas → MODE 2 ou MODE 3.
if ($AssignmentMode -eq "Permanent") {

    $AssignmentParams = @{
        PrincipalId      = $TargetUser.Id
        RoleDefinitionId = $RoleDef.Id
        DirectoryScopeId = $DirectoryScope
    }

    try {
        $NewAssignment = New-MgRoleManagementDirectoryRoleAssignment `
            -BodyParameter $AssignmentParams -ErrorAction Stop
        Write-Host "-> Assignation permanente créée [ID : $($NewAssignment.Id)]`n" -ForegroundColor Green
    }
    catch {
        Write-Host "-> ERREUR : $_" -ForegroundColor Red
        Disconnect-MgGraph -ErrorAction SilentlyContinue
        return
    }
}

# ------------------------------------------------------------------------------------
# MODE 2 : PIM éligible ← MODE PAR DÉFAUT
# ------------------------------------------------------------------------------------
# New-MgRoleManagementDirectoryRoleEligibilitySchedule rend l'utilisateur ÉLIGIBLE
# au rôle via PIM. Il ne dispose pas du rôle tant qu'il ne l'active pas manuellement
# depuis Entra (portail ou PowerShell) avec justification obligatoire.
#
# C'est le mode recommandé pour tous les rôles sensibles en production :
#   → Traçabilité complète dans les logs PIM
#   → Justification métier obligatoire à chaque activation
#   → Durée d'activation limitée (configurable dans la PIM Policy du rôle)
#   → Expiration automatique de l'éligibilité (ici : $PimDurationDays)
#
# ScheduleInfo structure :
#   StartDateTime : date de début de l'éligibilité (maintenant)
#   Expiration    :
#     Type        : "AfterDuration" → expiration relative à StartDateTime
#                   "AfterDateTime" → expiration à une date fixe
#                   "noExpiration"  → éligibilité permanente (à éviter en prod)
#     Duration    : format ISO 8601 — "P90D" = 90 jours, "P1Y" = 1 an, "PT8H" = 8 heures
elseif ($AssignmentMode -eq "PimEligible") {

    $StartDateTime = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    $PimDuration   = "P$($PimDurationDays)D"   # ISO 8601 — P90D = 90 jours

    $EligibilityParams = @{
        PrincipalId      = $TargetUser.Id
        RoleDefinitionId = $RoleDef.Id
        DirectoryScopeId = $DirectoryScope
        # Action "adminAssign" : assignation administrative directe (hors demande utilisateur).
        # Valeur standard pour un admin qui assigne un rôle éligible à un autre utilisateur.
        Action           = "adminAssign"
        ScheduleInfo     = @{
            StartDateTime = $StartDateTime
            Expiration    = @{
                Type     = "AfterDuration"
                Duration = $PimDuration
            }
        }
        # Justification : obligatoire selon la PIM Policy du rôle sur certains tenants.
        # Bonne pratique : toujours renseigner même si non obligatoire — traçabilité audit.
        Justification    = "Assignation éligible PIM via script RBAC — exo 8b"
    }

    try {
        $NewAssignment = New-MgRoleManagementDirectoryRoleEligibilityScheduleRequest `
            -BodyParameter $EligibilityParams -ErrorAction Stop
        Write-Host "-> Assignation PIM éligible créée [ID : $($NewAssignment.Id)]" -ForegroundColor Green
        Write-Host "   Durée éligibilité : $PimDurationDays jours (expire le $((Get-Date).AddDays($PimDurationDays).ToString('dd/MM/yyyy')))" -ForegroundColor Green
        Write-Host "   L'utilisateur doit activer le rôle manuellement via Entra ou PIM.`n" -ForegroundColor Yellow
    }
    catch {
        Write-Host "-> ERREUR : $_" -ForegroundColor Red
        Disconnect-MgGraph -ErrorAction SilentlyContinue
        return
    }
}

# ------------------------------------------------------------------------------------
# MODE 3 : PIM active time-bound
# ------------------------------------------------------------------------------------
# New-MgRoleManagementDirectoryRoleAssignmentScheduleRequest crée une assignation
# ACTIVE avec expiration automatique — accès immédiat, pas d'activation requise,
# mais durée limitée.
#
# Cas d'usage : accès d'urgence (incident, astreinte), prestataire ponctuel,
# accès de transition pendant un onboarding.
#
# Différence clé vs MODE 2 :
#   MODE 2 (éligible) : l'utilisateur PEUT activer le rôle quand il en a besoin
#   MODE 3 (active)   : l'utilisateur A le rôle immédiatement, jusqu'à expiration
#
# Action "adminAssign" : même logique que MODE 2 — assignation admin directe.
# Autres valeurs possibles de Action :
#   "selfActivate"   → utilisateur qui active sa propre éligibilité PIM
#   "selfDeactivate" → utilisateur qui désactive son rôle actif
#   "adminRemove"    → admin qui révoque une assignation active
elseif ($AssignmentMode -eq "PimTimeBound") {

    $StartDateTime = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    $PimDuration   = "P$($PimDurationDays)D"

    $TimeBoundParams = @{
        PrincipalId      = $TargetUser.Id
        RoleDefinitionId = $RoleDef.Id
        DirectoryScopeId = $DirectoryScope
        Action           = "adminAssign"
        ScheduleInfo     = @{
            StartDateTime = $StartDateTime
            Expiration    = @{
                Type     = "AfterDuration"
                Duration = $PimDuration
            }
        }
        Justification    = "Assignation active time-bound PIM via script RBAC — exo 8b"
        # IsValidationOnly : $true = simulation sans création réelle (dry-run).
        # Utile pour valider les paramètres avant exécution en production.
        # IsValidationOnly = $true
    }

    try {
        $NewAssignment = New-MgRoleManagementDirectoryRoleAssignmentScheduleRequest `
            -BodyParameter $TimeBoundParams -ErrorAction Stop
        Write-Host "-> Assignation PIM active time-bound créée [ID : $($NewAssignment.Id)]" -ForegroundColor Green
        Write-Host "   Durée : $PimDurationDays jours (expire le $((Get-Date).AddDays($PimDurationDays).ToString('dd/MM/yyyy')))" -ForegroundColor Green
        Write-Host "   Accès immédiat — aucune activation requise.`n" -ForegroundColor Green
    }
    catch {
        Write-Host "-> ERREUR : $_" -ForegroundColor Red
        Disconnect-MgGraph -ErrorAction SilentlyContinue
        return
    }
}

# ========================================================================================
# ÉTAPE 6 : Vérification post-assignation depuis la source de vérité
# ========================================================================================
Write-Host "6. Vérification post-assignation..." -ForegroundColor Cyan

# REX : la propagation Graph post-création n'est pas instantanée.
# 15 secondes couvrent la latence backend standard.
Start-Sleep -Seconds 30

$CheckAssignment = $null

if ($AssignmentMode -eq "Permanent") {
    $CheckAssignment = Get-MgRoleManagementDirectoryRoleAssignment -All |
        Where-Object {
            $_.PrincipalId      -eq $TargetUser.Id -and
            $_.RoleDefinitionId -eq $RoleDef.Id    -and
            $_.DirectoryScopeId -eq $DirectoryScope
        } | Select-Object -First 1
}
elseif ($AssignmentMode -eq "PimEligible") {
    $CheckAssignment = Get-MgRoleManagementDirectoryRoleEligibilitySchedule -All |
        Where-Object {
            $_.PrincipalId      -eq $TargetUser.Id -and
            $_.RoleDefinitionId -eq $RoleDef.Id    -and
            $_.DirectoryScopeId -eq $DirectoryScope
        } | Select-Object -First 1
}
elseif ($AssignmentMode -eq "PimTimeBound") {
    $CheckAssignment = Get-MgRoleManagementDirectoryRoleAssignmentSchedule -All |
        Where-Object {
            $_.PrincipalId      -eq $TargetUser.Id -and
            $_.RoleDefinitionId -eq $RoleDef.Id    -and
            $_.DirectoryScopeId -eq $DirectoryScope
        } | Select-Object -First 1
}

if ($CheckAssignment) {
    Write-Host "-> Assignation confirmée depuis la source de vérité :" -ForegroundColor Green
    [PSCustomObject]@{
        AssignationId    = $CheckAssignment.Id
        Utilisateur      = $TargetUser.DisplayName
        UPN              = $TargetUser.UserPrincipalName
        Rôle             = $RoleDef.DisplayName
        Mode             = $AssignmentMode
        Périmètre        = $CheckAssignment.DirectoryScopeId
        Expiration       = if ($CheckAssignment.ScheduleInfo.Expiration.EndDateTime) {
                               $CheckAssignment.ScheduleInfo.Expiration.EndDateTime
                           } elseif ($AssignmentMode -eq "Permanent") {
                               "Permanente (aucune expiration)"
                           } else { "En cours de propagation" }
    } | Format-List
} else {
    Write-Host "-> ATTENTION : assignation non trouvée lors de la vérification." -ForegroundColor Red
    Write-Host "   Relancer l'exo 8d pour confirmer après quelques minutes." -ForegroundColor Yellow
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
    Mode             = $AssignmentMode
    Périmètre        = "$DirectoryScope (tenant-wide)"
    DuréePIM         = if ($AssignmentMode -ne "Permanent") { "$PimDurationDays jours" } else { "N/A" }
    AssignationId    = if ($CheckAssignment) { $CheckAssignment.Id } else { $NewAssignment.Id }
    NoteProduction   = switch ($AssignmentMode) {
        "Permanent"    { "ATTENTION : permanente hors PIM — réserver aux comptes break-glass/service" }
        "PimEligible"  { "Bonne pratique — l'utilisateur active sur demande avec justification" }
        "PimTimeBound" { "OK pour accès urgent/transitoire — vérifier l'expiration en exo 6a" }
    }
} | Format-List

# ========================================================================================
# NETTOYAGE MÉMOIRE
# ========================================================================================
Remove-Variable Scopes, RoleName, TargetUPN, DirectoryScope,
                AssignmentMode, PimDurationDays, RoleDef, TargetUser,
                AlreadyExists, Existing, AssignmentParams, EligibilityParams,
                TimeBoundParams, NewAssignment, CheckAssignment,
                StartDateTime, PimDuration `
                -ErrorAction SilentlyContinue

# ========================================================================================
# FERMETURE — RESET DE SESSION TOTAL
# ========================================================================================
Disconnect-MgGraph -ErrorAction SilentlyContinue
Write-Host "Session MgGraph fermée proprement." -ForegroundColor Magenta
