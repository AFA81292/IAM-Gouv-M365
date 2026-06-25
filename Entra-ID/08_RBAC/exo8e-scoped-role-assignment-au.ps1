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
# Ce script couvre les 3 modes d'assignation, identiques à 8b — seul le DirectoryScopeId change :
#
#   MODE                        | Cmdlet principale                                             | Expiration | Activation requise
#   ----------------------------|---------------------------------------------------------------|------------|-------------------
#   1. Permanente directe       | New-MgRoleManagementDirectoryRoleAssignment                   | Non        | Non — accès immédiat
#   2. PIM éligible             | New-MgRoleManagementDirectoryRoleEligibilityScheduleRequest   | Oui        | Oui — sur demande
#   3. PIM active time-bound    | New-MgRoleManagementDirectoryRoleAssignmentScheduleRequest    | Oui        | Non — accès immédiat
#
# Bonne pratique production :
#   → MODE 2 (PIM éligible) pour tous les rôles sensibles — MODE PAR DÉFAUT ici.
#   → MODE 3 (PIM active time-bound) pour les accès temporaires urgents (astreinte, incident).
#   → MODE 1 (permanente) réservé aux comptes break-glass et comptes de service uniquement.
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
#   4. Résout l'AU cible par nom → construit le DirectoryScopeId
#   5. Vérifie qu'aucune assignation identique n'existe déjà
#   6. Crée l'assignation selon le mode choisi
#   7. Vérifie depuis la source de vérité
#   8. Affiche un résumé
#   9. Ferme proprement toutes les sessions
#
# Delta pédagogique vs exercice 8b (rôle built-in tenant-wide) :
#   8b → DirectoryScopeId = "/"                            → portée tenant entier
#   8e → DirectoryScopeId = "/administrativeUnits/{au-id}" → portée AU uniquement
#   Les 3 modes sont identiques — seul le scope change. Antisèche combinée AU + PIM.
#
# Delta pédagogique vs exercice 2a (AU statique + délégation) :
#   2a → création de l'AU + peuplement + assignation scopée en une passe (workflow complet)
#   8e → focus RBAC pur : l'AU existe déjà, on y assigne un rôle scopé (tous modes)
#
# Module requis : Microsoft.Graph.Identity.Governance, Microsoft.Graph.Users,
#                 Microsoft.Graph.Identity.DirectoryManagement
# Connexion     : Connect-MgGraph
# ========================================================================================

# --- OUVERTURE — RESET DE SESSION TOTAL ---
# RoleManagement.ReadWrite.Directory : créer des assignations de rôles Entra (tous modes)
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
$RoleName = "Helpdesk Administrator"

# Utilisateur à qui on délègue le rôle.
$TargetUPN = "geralt@0n4mg.onmicrosoft.com"

# Nom de l'AU cible — résolu en ID à l'étape 4.
# L'AU doit exister avant l'exécution de ce script (statique ou dynamique — indifférent).
# Pour créer une AU → exo 2a (statique) ou exo 2b (dynamique).
$AUName = "AU-MagicOps"

# ---- MODE D'ASSIGNATION ----
# Décommenter le mode voulu — un seul actif à la fois.
# MODE 2 (PIM éligible) est activé par défaut — bonne pratique production.
#
# $AssignmentMode = "Permanent"      # MODE 1 — permanente directe, hors PIM
$AssignmentMode = "PimEligible"      # MODE 2 — PIM éligible, activation sur demande ← DÉFAUT
# $AssignmentMode = "PimTimeBound"   # MODE 3 — PIM active time-bound, accès immédiat + expiration

# Durée de l'assignation PIM (modes 2 et 3). Ignorée en mode Permanent.
# Valeurs courantes :
#   30  → accès court terme (audit, prestataire ponctuel)
#   90  → durée standard mission (recommandation Microsoft)
#   180 → long terme (poste permanent mais révisable semestriellement)
$PimDurationDays = 90

Write-Host "-> Rôle cible   : $RoleName" -ForegroundColor Green
Write-Host "-> Utilisateur  : $TargetUPN" -ForegroundColor Green
Write-Host "-> AU cible     : $AUName" -ForegroundColor Green
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

# Variante avec filtre OData côté API (plus efficace sur grands tenants) :
#   $RoleDef = Get-MgRoleManagementDirectoryRoleDefinition `
#       -Filter "DisplayName eq '$RoleName'" -ErrorAction SilentlyContinue
$RoleDef = Get-MgRoleManagementDirectoryRoleDefinition -All |
    Where-Object { $_.DisplayName -eq $RoleName } |
    Select-Object -First 1

if (-not $RoleDef) {
    Write-Host "-> ERREUR : rôle '$RoleName' introuvable." -ForegroundColor Red
    Write-Host "   Lister les rôles : Get-MgRoleManagementDirectoryRoleDefinition -All | Select-Object DisplayName" -ForegroundColor Yellow
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
# ÉTAPE 4 : Résolution de l'AU cible → construction du DirectoryScopeId
# ========================================================================================
Write-Host "4. Résolution de l'AU '$AUName'..." -ForegroundColor Cyan

# On résout l'AU par DisplayName pour éviter de coder le GUID en dur.
# Le GUID d'une AU est propre à chaque tenant — contrairement aux rôles built-in
# dont les GUIDs sont stables entre tenants Microsoft.
#
# Le type de l'AU (statique ou dynamique) est indifférent pour une assignation RBAC.
# Ce qui compte : l'AU existe et son ID est récupérable.
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
    Write-Host "   Lister les AUs : Get-MgDirectoryAdministrativeUnit -All | Select-Object DisplayName, Id" -ForegroundColor Yellow
    Disconnect-MgGraph -ErrorAction SilentlyContinue
    return
}

Write-Host "-> AU trouvée : $($TargetAU.DisplayName) [ID : $($TargetAU.Id)]" -ForegroundColor Green
Write-Host "   Type       : $($TargetAU.MembershipType)" -ForegroundColor Gray

# Construction du DirectoryScopeId — format imposé par Graph pour les assignations AU.
# C'est la seule différence structurelle avec une assignation tenant-wide (exo 8b).
# Format : "/administrativeUnits/{au-id}"  vs  "/" pour tenant-wide.
$DirectoryScopeId = "/administrativeUnits/$($TargetAU.Id)"
Write-Host "   ScopeId    : $DirectoryScopeId`n" -ForegroundColor Gray

# ========================================================================================
# ÉTAPE 5 : Vérification d'une assignation existante (idempotence)
# ========================================================================================
Write-Host "5. Vérification d'une assignation existante..." -ForegroundColor Cyan

# DÉCOUVERTE TECHNIQUE : les assignations scopées AU et tenant-wide coexistent
# dans les mêmes endpoints Graph. La distinction se fait sur DirectoryScopeId.
# Un utilisateur peut avoir le même rôle en tenant-wide ET scopé à une AU simultanément
# — deux objets distincts. L'idempotence doit vérifier le ScopeId exact.
$AlreadyExists = $false

if ($AssignmentMode -eq "Permanent") {
    $Existing = Get-MgRoleManagementDirectoryRoleAssignment -All |
        Where-Object {
            $_.PrincipalId      -eq $TargetUser.Id    -and
            $_.RoleDefinitionId -eq $RoleDef.Id       -and
            $_.DirectoryScopeId -eq $DirectoryScopeId
        } | Select-Object -First 1
    if ($Existing) { $AlreadyExists = $true }
}
elseif ($AssignmentMode -eq "PimEligible") {
    $Existing = Get-MgRoleManagementDirectoryRoleEligibilitySchedule -All |
        Where-Object {
            $_.PrincipalId      -eq $TargetUser.Id    -and
            $_.RoleDefinitionId -eq $RoleDef.Id       -and
            $_.DirectoryScopeId -eq $DirectoryScopeId
        } | Select-Object -First 1
    if ($Existing) { $AlreadyExists = $true }
}
elseif ($AssignmentMode -eq "PimTimeBound") {
    $Existing = Get-MgRoleManagementDirectoryRoleAssignmentSchedule -All |
        Where-Object {
            $_.PrincipalId      -eq $TargetUser.Id    -and
            $_.RoleDefinitionId -eq $RoleDef.Id       -and
            $_.DirectoryScopeId -eq $DirectoryScopeId
        } | Select-Object -First 1
    if ($Existing) { $AlreadyExists = $true }
}

if ($AlreadyExists) {
    Write-Host "-> ATTENTION : assignation identique déjà existante sur cette AU (mode : $AssignmentMode)." -ForegroundColor Yellow
    Write-Host "   ID : $($Existing.Id)" -ForegroundColor Yellow
    Write-Host "   Aucune action effectuée — fin du script.`n" -ForegroundColor Yellow
    Disconnect-MgGraph -ErrorAction SilentlyContinue
    return
}

Write-Host "-> Aucune assignation existante sur cette AU — création possible.`n" -ForegroundColor Green

# ========================================================================================
# ÉTAPE 6 : Création de l'assignation selon le mode choisi
# ========================================================================================
Write-Host "6. Création de l'assignation (mode : $AssignmentMode)..." -ForegroundColor Cyan

$NewAssignment = $null

# ------------------------------------------------------------------------------------
# MODE 1 : Permanente directe (hors PIM)
# ------------------------------------------------------------------------------------
# New-MgRoleManagementDirectoryRoleAssignment — identique à 8b MODE 1.
# Seul DirectoryScopeId change : pointe vers l'AU au lieu de "/".
# Accès immédiat, pas d'expiration. Réservé aux comptes de service uniquement en prod.
if ($AssignmentMode -eq "Permanent") {

    $AssignmentParams = @{
        PrincipalId      = $TargetUser.Id
        RoleDefinitionId = $RoleDef.Id
        DirectoryScopeId = $DirectoryScopeId   # "/administrativeUnits/{id}" ← différence vs 8b
    }

    try {
        $NewAssignment = New-MgRoleManagementDirectoryRoleAssignment `
            -BodyParameter $AssignmentParams -ErrorAction Stop
        Write-Host "-> Assignation permanente scopée AU créée [ID : $($NewAssignment.Id)]`n" -ForegroundColor Green
    }
    catch {
        Write-Host "-> ERREUR : $_" -ForegroundColor Red
        Write-Host "   Si le message mentionne 'roleTemplateId' ou 'scope' : ce rôle n'est pas scopable à une AU." -ForegroundColor Yellow
        Write-Host "   Rôles non scopables : Global Admin, Security Admin, Exchange Admin..." -ForegroundColor Yellow
        Disconnect-MgGraph -ErrorAction SilentlyContinue
        return
    }
}

# ------------------------------------------------------------------------------------
# MODE 2 : PIM éligible ← MODE PAR DÉFAUT
# ------------------------------------------------------------------------------------
# New-MgRoleManagementDirectoryRoleEligibilityScheduleRequest — identique à 8b MODE 2.
# L'utilisateur est ÉLIGIBLE au rôle sur l'AU — il doit l'activer manuellement via PIM.
# Traçabilité complète, justification obligatoire, durée d'activation limitée.
#
# DirectoryScopeId "/administrativeUnits/{id}" ← seule différence structurelle vs 8b.
# Tous les paramètres PIM (ScheduleInfo, Action, Justification) sont identiques.
#
# ScheduleInfo :
#   StartDateTime : date de début de l'éligibilité (maintenant)
#   Expiration.Type     : "AfterDuration" → durée relative | "AfterDateTime" → date fixe
#                         "noExpiration"  → permanent (à éviter en prod)
#   Expiration.Duration : ISO 8601 — "P90D" = 90 jours, "P1Y" = 1 an, "PT8H" = 8 heures
elseif ($AssignmentMode -eq "PimEligible") {

    $StartDateTime = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    $PimDuration   = "P$($PimDurationDays)D"

    $EligibilityParams = @{
        PrincipalId      = $TargetUser.Id
        RoleDefinitionId = $RoleDef.Id
        DirectoryScopeId = $DirectoryScopeId   # "/administrativeUnits/{id}" ← différence vs 8b
        Action           = "adminAssign"
        ScheduleInfo     = @{
            StartDateTime = $StartDateTime
            Expiration    = @{
                Type     = "AfterDuration"
                Duration = $PimDuration
            }
        }
        Justification    = "Assignation éligible PIM scopée AU via script RBAC — exo 8e"
    }

    try {
        $NewAssignment = New-MgRoleManagementDirectoryRoleEligibilityScheduleRequest `
            -BodyParameter $EligibilityParams -ErrorAction Stop
        Write-Host "-> Assignation PIM éligible scopée AU créée [ID : $($NewAssignment.Id)]" -ForegroundColor Green
        Write-Host "   Durée éligibilité : $PimDurationDays jours (expire le $((Get-Date).AddDays($PimDurationDays).ToString('dd/MM/yyyy')))" -ForegroundColor Green
        Write-Host "   Périmètre         : $($TargetAU.DisplayName) uniquement" -ForegroundColor Green
        Write-Host "   L'utilisateur doit activer le rôle manuellement via Entra ou PIM.`n" -ForegroundColor Yellow
    }
    catch {
        Write-Host "-> ERREUR : $_" -ForegroundColor Red
        Write-Host "   Si le message mentionne 'roleTemplateId' ou 'scope' : ce rôle n'est pas scopable à une AU." -ForegroundColor Yellow
        Disconnect-MgGraph -ErrorAction SilentlyContinue
        return
    }
}

# ------------------------------------------------------------------------------------
# MODE 3 : PIM active time-bound
# ------------------------------------------------------------------------------------
# New-MgRoleManagementDirectoryRoleAssignmentScheduleRequest — identique à 8b MODE 3.
# Accès IMMÉDIAT avec expiration automatique — pas d'activation requise.
# Cas d'usage : accès d'urgence (incident, astreinte), prestataire ponctuel sur l'AU.
#
# DirectoryScopeId "/administrativeUnits/{id}" ← seule différence structurelle vs 8b.
#
# IsValidationOnly = $true → dry-run : valide les paramètres sans créer l'assignation.
# Utile pour tester la combinaison rôle + AU avant exécution réelle en production.
elseif ($AssignmentMode -eq "PimTimeBound") {

    $StartDateTime = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    $PimDuration   = "P$($PimDurationDays)D"

    $TimeBoundParams = @{
        PrincipalId      = $TargetUser.Id
        RoleDefinitionId = $RoleDef.Id
        DirectoryScopeId = $DirectoryScopeId   # "/administrativeUnits/{id}" ← différence vs 8b
        Action           = "adminAssign"
        ScheduleInfo     = @{
            StartDateTime = $StartDateTime
            Expiration    = @{
                Type     = "AfterDuration"
                Duration = $PimDuration
            }
        }
        Justification    = "Assignation active time-bound PIM scopée AU via script RBAC — exo 8e"
        # IsValidationOnly = $true   # dry-run — valide sans créer
    }

    try {
        $NewAssignment = New-MgRoleManagementDirectoryRoleAssignmentScheduleRequest `
            -BodyParameter $TimeBoundParams -ErrorAction Stop
        Write-Host "-> Assignation PIM active time-bound scopée AU créée [ID : $($NewAssignment.Id)]" -ForegroundColor Green
        Write-Host "   Durée     : $PimDurationDays jours (expire le $((Get-Date).AddDays($PimDurationDays).ToString('dd/MM/yyyy')))" -ForegroundColor Green
        Write-Host "   Périmètre : $($TargetAU.DisplayName) uniquement" -ForegroundColor Green
        Write-Host "   Accès immédiat — aucune activation requise.`n" -ForegroundColor Green
    }
    catch {
        Write-Host "-> ERREUR : $_" -ForegroundColor Red
        Write-Host "   Si le message mentionne 'roleTemplateId' ou 'scope' : ce rôle n'est pas scopable à une AU." -ForegroundColor Yellow
        Disconnect-MgGraph -ErrorAction SilentlyContinue
        return
    }
}

# ========================================================================================
# ÉTAPE 7 : Vérification post-assignation depuis la source de vérité
# ========================================================================================
Write-Host "7. Vérification post-assignation..." -ForegroundColor Cyan

# REX : la propagation Graph post-création n'est pas instantanée.
# 30 secondes couvrent la latence backend standard.
Start-Sleep -Seconds 30

$CheckAssignment = $null

if ($AssignmentMode -eq "Permanent") {
    $CheckAssignment = Get-MgRoleManagementDirectoryRoleAssignment -All |
        Where-Object {
            $_.PrincipalId      -eq $TargetUser.Id    -and
            $_.RoleDefinitionId -eq $RoleDef.Id       -and
            $_.DirectoryScopeId -eq $DirectoryScopeId
        } | Select-Object -First 1
}
elseif ($AssignmentMode -eq "PimEligible") {
    $CheckAssignment = Get-MgRoleManagementDirectoryRoleEligibilitySchedule -All |
        Where-Object {
            $_.PrincipalId      -eq $TargetUser.Id    -and
            $_.RoleDefinitionId -eq $RoleDef.Id       -and
            $_.DirectoryScopeId -eq $DirectoryScopeId
        } | Select-Object -First 1
}
elseif ($AssignmentMode -eq "PimTimeBound") {
    $CheckAssignment = Get-MgRoleManagementDirectoryRoleAssignmentSchedule -All |
        Where-Object {
            $_.PrincipalId      -eq $TargetUser.Id    -and
            $_.RoleDefinitionId -eq $RoleDef.Id       -and
            $_.DirectoryScopeId -eq $DirectoryScopeId
        } | Select-Object -First 1
}

# Variante : vérification via l'endpoint AU dédié (retourne les rôles scopés à une AU spécifique).
# Get-MgDirectoryAdministrativeUnitScopedRoleMember -AdministrativeUnitId $TargetAU.Id |
#     Where-Object { $_.RoleMemberInfo.Id -eq $TargetUser.Id }
# Avantage : périmètre naturellement limité à l'AU, plus rapide sur grands tenants.
# Inconvénient : ne retourne pas le RoleDefinitionId directement — résolution en deux passes.
# Fonctionne uniquement pour le MODE 1 (permanent) — les assignations PIM n'y apparaissent pas.

if ($CheckAssignment) {
    Write-Host "-> Assignation confirmée depuis la source de vérité :" -ForegroundColor Green
    [PSCustomObject]@{
        AssignationId    = $CheckAssignment.Id
        Utilisateur      = $TargetUser.DisplayName
        UPN              = $TargetUser.UserPrincipalName
        Rôle             = $RoleDef.DisplayName
        Mode             = $AssignmentMode
        PérimètreType    = "Administrative Unit"
        PérimètreNom     = $TargetAU.DisplayName
        DirectoryScopeId = $CheckAssignment.DirectoryScopeId
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
    Mode             = $AssignmentMode
    DuréePIM         = if ($AssignmentMode -ne "Permanent") { "$PimDurationDays jours" } else { "N/A" }
    AssignationId    = if ($CheckAssignment) { $CheckAssignment.Id } else { $NewAssignment.Id }
    NoteProduction   = switch ($AssignmentMode) {
        "Permanent"    { "ATTENTION : permanente hors PIM — réserver aux comptes break-glass/service" }
        "PimEligible"  { "Bonne pratique — activation sur demande, traçabilité PIM, périmètre AU" }
        "PimTimeBound" { "OK pour accès urgent sur l'AU — vérifier l'expiration en exo 6a" }
    }
    LienExos         = "2a/2b (création AU) → 8e (délégation scopée) → 8c (révocation)"
} | Format-List

# ========================================================================================
# NETTOYAGE MÉMOIRE
# ========================================================================================
Remove-Variable Scopes, RoleName, TargetUPN, AUName, AssignmentMode, PimDurationDays,
                RoleDef, TargetUser, TargetAU, DirectoryScopeId, AlreadyExists, Existing,
                AssignmentParams, EligibilityParams, TimeBoundParams,
                NewAssignment, CheckAssignment, StartDateTime, PimDuration `
                -ErrorAction SilentlyContinue

# ========================================================================================
# FERMETURE — RESET DE SESSION TOTAL
# ========================================================================================
Disconnect-MgGraph -ErrorAction SilentlyContinue
Write-Host "Session MgGraph fermée proprement." -ForegroundColor Magenta
