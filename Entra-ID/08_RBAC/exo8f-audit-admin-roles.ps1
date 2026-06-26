# ========================================================================================
# Exercice 8f : Entra ID — RBAC — Audit des rôles administratifs
# ========================================================================================
# Concept : Savoir qui détient quels droits d'administration sur le tenant est le point
# de départ de tout audit IAM. Ce script produit l'inventaire exhaustif des assignations
# de rôles Entra sous 9 angles complémentaires.
#
# En mission réelle : décommenter les blocs marqués [PROD] et commenter les blocs [DEV].
# Les détections break glass et conventions de nommage sont à adapter au client.
#
# Ce script couvre 9 axes d'analyse → 9 CSV :
#   1. RBAC_Permanentes          : assignations directes hors PIM (users)
#   2. RBAC_PIM_Actives          : assignations PIM actuellement activées
#   3. RBAC_PIM_Eligibles        : éligibles PIM non encore activés
#   4. RBAC_Groupes_Membres      : membres effectifs via assignation groupe → rôle
#   5. RBAC_ServicePrincipals    : Service Principals détenteurs de rôles Entra
#   6. RBAC_Custom               : rôles custom + leurs assignations
#   7. RBAC_Roles_Sans_Assignation : rôles built-in sans aucun détenteur actif
#   8. RBAC_Expiration_Imminente : assignations PIM expirant dans 30 jours
#   9. RBAC_BreakGlass           : comptes break glass détectés + dernière connexion
#
# Delta pédagogique vs exercice 6d (PIM — audit permanents à risque) :
#   6d → focus sécurité PIM : permanents sans expiration, signalement CRITIQUE
#   8f → inventaire RBAC exhaustif : tous les types, tous les principals, tous les états
#
# Delta pédagogique vs exercice 9d (Tenant Security Snapshot) :
#   9d → une passe globale multi-domaines (identités, licences, CA, MFA, RBAC...)
#   8f → focus RBAC exclusif, granularité maximale — les CSV 8f alimentent le snapshot 9d
#
# Note : ce script est en lecture seule — aucune modification du tenant.
#
# Module requis : Microsoft.Graph.Identity.Governance, Microsoft.Graph.Users,
#                 Microsoft.Graph.Identity.DirectoryManagement,
#                 Microsoft.Graph.Groups
# Connexion     : Connect-MgGraph
# ========================================================================================

# --- OUVERTURE — RESET DE SESSION TOTAL ---
# RoleManagement.Read.Directory : lire rôles et assignations Entra (tous endpoints)
# User.Read.All                 : résoudre PrincipalId users + SignInActivity break glass
# Group.Read.All                : résoudre PrincipalId groupes + énumérer leurs membres
# Application.Read.All          : résoudre PrincipalId Service Principals
# AdministrativeUnit.Read.All   : résoudre DirectoryScopeId AU en noms lisibles
# AuditLog.Read.All             : SignInActivity pour détection break glass inactifs
#
# Pas de -ContextScope Process requis : lecture seule, aucun scope d'écriture.
$Scopes = @(
    "RoleManagement.Read.Directory",
    "User.Read.All",
    "Group.Read.All",
    "Application.Read.All",
    "AdministrativeUnit.Read.All",
    "AuditLog.Read.All"
)

Disconnect-MgGraph -ErrorAction SilentlyContinue
Connect-MgGraph -Scopes $Scopes -NoWelcome

# ========================================================================================
# ÉTAPE 1 : Chargement en cache de toutes les données sources
# ========================================================================================
Write-Host "1. Chargement des données sources en cache..." -ForegroundColor Cyan

# DÉCOUVERTE TECHNIQUE : charger toutes les collections en mémoire avant les boucles
# de résolution évite N appels Graph individuels par itération.
# Sur un tenant de prod avec 500+ assignations et 300+ rôles, la différence
# entre "lookup mémoire" et "appel Graph par itération" peut être de plusieurs minutes.
# Pattern à systématiser sur tous les scripts d'audit avec boucles de résolution.

$AllRoleDefinitions  = Get-MgRoleManagementDirectoryRoleDefinition -All
$AllAssignments      = Get-MgRoleManagementDirectoryRoleAssignment -All
$AllSchedules        = Get-MgRoleManagementDirectoryRoleAssignmentSchedule -All
$AllEligibilities    = Get-MgRoleManagementDirectoryRoleEligibilitySchedule -All
$AllAUs              = Get-MgDirectoryAdministrativeUnit -All
$AllUsers            = Get-MgUser -All -Property "Id,DisplayName,UserPrincipalName,AccountEnabled,SignInActivity,Department,UserType"
$AllGroups           = Get-MgGroup -All -Property "Id,DisplayName,GroupTypes,SecurityEnabled"
$AllServicePrincipals = Get-MgServicePrincipal -All -Property "Id,DisplayName,AppId,AppOwnerOrganizationId"

Write-Host "-> Rôles          : $($AllRoleDefinitions.Count)" -ForegroundColor Green
Write-Host "-> Assignations   : $($AllAssignments.Count)" -ForegroundColor Green
Write-Host "-> Schedules PIM  : $($AllSchedules.Count)" -ForegroundColor Green
Write-Host "-> Éligibles PIM  : $($AllEligibilities.Count)" -ForegroundColor Green
Write-Host "-> AUs            : $($AllAUs.Count)" -ForegroundColor Green
Write-Host "-> Users          : $($AllUsers.Count)" -ForegroundColor Green
Write-Host "-> Groupes        : $($AllGroups.Count)" -ForegroundColor Green
Write-Host "-> SPs            : $($AllServicePrincipals.Count)`n" -ForegroundColor Green

# Listes de référence réutilisées dans toutes les étapes suivantes
$SensitiveRoleNames = @(
    "Global Administrator",
    "Privileged Role Administrator",
    "Security Administrator",
    "User Administrator",
    "Exchange Administrator",
    "SharePoint Administrator",
    "Application Administrator",
    "Cloud Application Administrator"
)

# Conventions de nommage break glass — à adapter selon le client en mission.
# [DEV] Patterns génériques pour tenant de dev :
$BreakGlassPatterns = @("breakglass", "emergency", "urgence", "bg-", "brk")
# [PROD] Remplacer par la convention du client, ex :
# $BreakGlassPatterns = @("BG-", "EMRG-", "SVC-URGENCE")

# Helper : résolution du DirectoryScopeId en label lisible
function Resolve-ScopeLabel {
    param($ScopeId, $AUCache)
    if ($ScopeId -eq "/") { return "Tenant-wide" }
    $AUId     = $ScopeId -replace "/administrativeUnits/", ""
    $MatchedAU = $AUCache | Where-Object { $_.Id -eq $AUId } | Select-Object -First 1
    if ($MatchedAU) { return "AU : $($MatchedAU.DisplayName)" } else { return "AU : $AUId" }
}

# Helper : résolution du type de principal (User / Group / ServicePrincipal / Inconnu)
function Resolve-PrincipalType {
    param($PrincipalId, $UserCache, $GroupCache, $SPCache)
    if ($UserCache  | Where-Object { $_.Id -eq $PrincipalId }) { return "User" }
    if ($GroupCache | Where-Object { $_.Id -eq $PrincipalId }) { return "Group" }
    if ($SPCache    | Where-Object { $_.Id -eq $PrincipalId }) { return "ServicePrincipal" }
    return "Inconnu"
}

# ========================================================================================
# ÉTAPE 2 : CSV 1 — Assignations permanentes directes (hors PIM)
# ========================================================================================
Write-Host "2. Audit des assignations permanentes (hors PIM)..." -ForegroundColor Cyan

# Une assignation permanente directe = un utilisateur qui détient un rôle Entra
# sans passer par le flux PIM (pas de justification, pas d'expiration, pas de traçabilité).
# Source : Get-MgRoleManagementDirectoryRoleAssignment — endpoint des assignations directes.
#
# Croisement avec Get-MgRoleManagementDirectoryRoleAssignmentSchedule pour isoler
# les "Assigned" permanents vs les "Activated" (activation PIM en cours) :
#   AssignmentType "Assigned"  → assignation directe permanente ← on veut ceux-là
#   AssignmentType "Activated" → activation PIM time-bound en cours → CSV 2
#
# En mission : tout "Assigned" permanent sur un rôle sensible est un point de remédiation.
# Bonne pratique : convertir en PIM éligible (exo 6b) sauf comptes break glass.
$PermanentRows = @()

foreach ($Assignment in $AllAssignments) {
    # On croise avec les schedules PIM pour détecter le type d'assignation.
    # Si l'assignation est dans les schedules avec AssignmentType "Activated" → c'est du PIM actif.
    # Si elle n'y est pas, ou AssignmentType "Assigned" → c'est une assignation directe permanente.
    $Schedule = $AllSchedules | Where-Object { $_.Id -eq $Assignment.Id } | Select-Object -First 1
    if ($Schedule -and $Schedule.AssignmentType -eq "Activated") { continue }

    $PrincipalType = Resolve-PrincipalType $Assignment.PrincipalId $AllUsers $AllGroups $AllServicePrincipals
    if ($PrincipalType -ne "User") { continue }   # Groupes → CSV 4 | SPs → CSV 5

    $User    = $AllUsers | Where-Object { $_.Id -eq $Assignment.PrincipalId } | Select-Object -First 1
    $RoleDef = $AllRoleDefinitions | Where-Object { $_.Id -eq $Assignment.RoleDefinitionId } | Select-Object -First 1
    $Scope   = Resolve-ScopeLabel $Assignment.DirectoryScopeId $AllAUs

    $PermanentRows += [PSCustomObject]@{
        Utilisateur      = if ($User) { $User.DisplayName }      else { $Assignment.PrincipalId }
        UPN              = if ($User) { $User.UserPrincipalName } else { "Non résolu" }
        Role             = if ($RoleDef) { $RoleDef.DisplayName } else { $Assignment.RoleDefinitionId }
        TypeRole         = if ($RoleDef) { if ($RoleDef.IsBuiltIn) { "Built-in" } else { "Custom" } } else { "Inconnu" }
        Sensible         = if ($SensitiveRoleNames -contains $RoleDef.DisplayName) { "SENSIBLE" } else { "" }
        Perimetre        = $Scope
        DirectoryScopeId = $Assignment.DirectoryScopeId
        CompteActif      = if ($User) { $User.AccountEnabled } else { "" }
        AssignationId    = $Assignment.Id
        # Colonnes disponibles non exportées :
        #   $User.Department             : département de l'utilisateur
        #   $User.UserType               : Member ou Guest
        #   $RoleDef.Description         : description complète du rôle
        #   $Assignment.CreatedDateTime  : date de création de l'assignation
    }
}

Write-Host "-> $($PermanentRows.Count) assignation(s) permanente(s) directe(s) (users uniquement).`n" -ForegroundColor $(
    if (($PermanentRows | Where-Object { $_.Sensible -eq "SENSIBLE" }).Count -gt 0) { "Yellow" } else { "Green" }
)

# ========================================================================================
# ÉTAPE 3 : CSV 2 — Assignations PIM actuellement activées
# ========================================================================================
Write-Host "3. Audit des assignations PIM actives..." -ForegroundColor Cyan

# Une assignation PIM active = un utilisateur qui a activé son éligibilité PIM
# et dispose du rôle en ce moment, pour une durée limitée.
# Source : Get-MgRoleManagementDirectoryRoleAssignmentSchedule filtré sur AssignmentType "Activated".
#
# Ces assignations sont temporaires par nature — elles expirent automatiquement.
# En mission : utile pour savoir qui dispose de droits élevés RIGHT NOW.
# Croiser avec CSV 8 (expiration imminente) pour les suivis proactifs.
$PIMActiveRows = @()

foreach ($Schedule in $AllSchedules) {
    if ($Schedule.AssignmentType -ne "Activated") { continue }

    $PrincipalType = Resolve-PrincipalType $Schedule.PrincipalId $AllUsers $AllGroups $AllServicePrincipals
    $User    = $AllUsers | Where-Object { $_.Id -eq $Schedule.PrincipalId } | Select-Object -First 1
    $RoleDef = $AllRoleDefinitions | Where-Object { $_.Id -eq $Schedule.RoleDefinitionId } | Select-Object -First 1
    $Scope   = Resolve-ScopeLabel $Schedule.DirectoryScopeId $AllAUs

    $PIMActiveRows += [PSCustomObject]@{
        Utilisateur      = if ($User) { $User.DisplayName }      else { $Schedule.PrincipalId }
        UPN              = if ($User) { $User.UserPrincipalName } else { "Non résolu" }
        TypePrincipal    = $PrincipalType
        Role             = if ($RoleDef) { $RoleDef.DisplayName } else { $Schedule.RoleDefinitionId }
        Sensible         = if ($SensitiveRoleNames -contains $RoleDef.DisplayName) { "SENSIBLE" } else { "" }
        Perimetre        = $Scope
        DirectoryScopeId = $Schedule.DirectoryScopeId
        Statut           = $Schedule.Status
        Expiration       = if ($Schedule.ScheduleInfo.Expiration.EndDateTime) {
                               $Schedule.ScheduleInfo.Expiration.EndDateTime
                           } else { "Aucune" }
        AssignationId    = $Schedule.Id
        # Colonnes disponibles non exportées :
        #   $Schedule.StartDateTime              : date/heure d'activation
        #   $Schedule.ScheduleInfo.Expiration.Duration : durée ISO 8601
        #   $User.Department                     : département
    }
}

Write-Host "-> $($PIMActiveRows.Count) assignation(s) PIM active(s) en ce moment.`n" -ForegroundColor Green

# ========================================================================================
# ÉTAPE 4 : CSV 3 — Éligibilités PIM non activées
# ========================================================================================
Write-Host "4. Audit des éligibilités PIM (non activées)..." -ForegroundColor Cyan

# Une éligibilité PIM = un utilisateur qui PEUT activer le rôle sur demande,
# mais qui ne le détient pas en ce moment.
# Source : Get-MgRoleManagementDirectoryRoleEligibilitySchedule — endpoint distinct
# de Get-MgRoleManagementDirectoryRoleAssignment.
#
# DÉCOUVERTE TECHNIQUE : les éligibles n'apparaissent PAS dans Get-MgRoleManagementDirectoryRoleAssignment.
# C'est l'erreur classique en audit RBAC : ne regarder que les assignations actives
# et manquer tous les utilisateurs éligibles — qui peuvent activer le rôle à tout moment.
# Un audit complet doit couvrir les deux endpoints.
$PIMEligibleRows = @()

foreach ($Eligibility in $AllEligibilities) {
    $PrincipalType = Resolve-PrincipalType $Eligibility.PrincipalId $AllUsers $AllGroups $AllServicePrincipals
    $User    = $AllUsers | Where-Object { $_.Id -eq $Eligibility.PrincipalId } | Select-Object -First 1
    $RoleDef = $AllRoleDefinitions | Where-Object { $_.Id -eq $Eligibility.RoleDefinitionId } | Select-Object -First 1
    $Scope   = Resolve-ScopeLabel $Eligibility.DirectoryScopeId $AllAUs

    $PIMEligibleRows += [PSCustomObject]@{
        Utilisateur      = if ($User) { $User.DisplayName }      else { $Eligibility.PrincipalId }
        UPN              = if ($User) { $User.UserPrincipalName } else { "Non résolu" }
        TypePrincipal    = $PrincipalType
        Role             = if ($RoleDef) { $RoleDef.DisplayName } else { $Eligibility.RoleDefinitionId }
        Sensible         = if ($SensitiveRoleNames -contains $RoleDef.DisplayName) { "SENSIBLE" } else { "" }
        Perimetre        = $Scope
        DirectoryScopeId = $Eligibility.DirectoryScopeId
        Statut           = $Eligibility.Status
        DebutEligibilite = $Eligibility.ScheduleInfo.StartDateTime
        FinEligibilite   = if ($Eligibility.ScheduleInfo.Expiration.EndDateTime) {
                               $Eligibility.ScheduleInfo.Expiration.EndDateTime
                           } else { "Permanente" }
        EligibiliteId    = $Eligibility.Id
        # Colonnes disponibles non exportées :
        #   $Eligibility.ScheduleInfo.Expiration.Duration : durée ISO 8601
        #   $User.Department                              : département
        #   $User.AccountEnabled                          : compte actif
    }
}

Write-Host "-> $($PIMEligibleRows.Count) éligibilité(s) PIM (non activées).`n" -ForegroundColor Green

# ========================================================================================
# ÉTAPE 5 : CSV 4 — Membres effectifs via assignation groupe → rôle
# ========================================================================================
Write-Host "5. Audit des assignations via groupes..." -ForegroundColor Cyan

# Un groupe peut être assigné directement à un rôle Entra (feature "group-based role assignment").
# Tous les membres du groupe héritent du rôle sans apparaître individuellement
# dans Get-MgRoleManagementDirectoryRoleAssignment.
# C'est un vecteur d'élévation de privilèges discret : ajouter un user au groupe
# lui donne le rôle sans créer d'assignation de rôle visible directement.
#
# Ce CSV énumère les membres effectifs de chaque groupe assigné à un rôle :
# vue "qui a réellement le rôle via groupe" — essentielle pour un audit complet.
$GroupRoleRows = @()

# On filtre les assignations dont le PrincipalId est un groupe
$GroupAssignments = $AllAssignments | Where-Object {
    $PrincipalType = Resolve-PrincipalType $_.PrincipalId $AllUsers $AllGroups $AllServicePrincipals
    $PrincipalType -eq "Group"
}

foreach ($Assignment in $GroupAssignments) {
    $Group   = $AllGroups | Where-Object { $_.Id -eq $Assignment.PrincipalId } | Select-Object -First 1
    $RoleDef = $AllRoleDefinitions | Where-Object { $_.Id -eq $Assignment.RoleDefinitionId } | Select-Object -First 1
    $Scope   = Resolve-ScopeLabel $Assignment.DirectoryScopeId $AllAUs

    # Énumération des membres du groupe — un appel Graph par groupe assigné à un rôle.
    # Sur grands tenants : limiter aux groupes de rôles (souvent peu nombreux) est acceptable.
    $Members = Get-MgGroupMember -GroupId $Assignment.PrincipalId -All -ErrorAction SilentlyContinue

    if ($Members) {
        foreach ($Member in $Members) {
            $MemberUser = $AllUsers | Where-Object { $_.Id -eq $Member.Id } | Select-Object -First 1

            $GroupRoleRows += [PSCustomObject]@{
                NomGroupe        = if ($Group) { $Group.DisplayName } else { $Assignment.PrincipalId }
                GroupeId         = $Assignment.PrincipalId
                MembreDisplayName = if ($MemberUser) { $MemberUser.DisplayName }      else { $Member.Id }
                MembreUPN        = if ($MemberUser) { $MemberUser.UserPrincipalName } else { "Non résolu" }
                Role             = if ($RoleDef) { $RoleDef.DisplayName } else { $Assignment.RoleDefinitionId }
                Sensible         = if ($SensitiveRoleNames -contains $RoleDef.DisplayName) { "SENSIBLE" } else { "" }
                Perimetre        = $Scope
                DirectoryScopeId = $Assignment.DirectoryScopeId
                CompteActif      = if ($MemberUser) { $MemberUser.AccountEnabled } else { "" }
                # Colonnes disponibles non exportées :
                #   $Group.GroupTypes        : type de groupe (Unified, DynamicMembership...)
                #   $Group.SecurityEnabled   : groupe de sécurité ou non
                #   $MemberUser.Department   : département du membre
                #   $Assignment.Id           : ID de l'assignation groupe → rôle
            }
        }
    } else {
        # Groupe assigné à un rôle mais sans membres — cas à signaler
        $GroupRoleRows += [PSCustomObject]@{
            NomGroupe         = if ($Group) { $Group.DisplayName } else { $Assignment.PrincipalId }
            GroupeId          = $Assignment.PrincipalId
            MembreDisplayName = "GROUPE VIDE"
            MembreUPN         = ""
            Role              = if ($RoleDef) { $RoleDef.DisplayName } else { $Assignment.RoleDefinitionId }
            Sensible          = if ($SensitiveRoleNames -contains $RoleDef.DisplayName) { "SENSIBLE" } else { "" }
            Perimetre         = $Scope
            DirectoryScopeId  = $Assignment.DirectoryScopeId
            CompteActif       = ""
        }
    }
}

Write-Host "-> $($GroupAssignments.Count) groupe(s) assigné(s) à des rôles." -ForegroundColor Green
Write-Host "-> $($GroupRoleRows.Count) ligne(s) membres effectifs via groupes.`n" -ForegroundColor Green

# ========================================================================================
# ÉTAPE 6 : CSV 5 — Service Principals détenteurs de rôles Entra
# ========================================================================================
Write-Host "6. Audit des Service Principals avec rôles Entra..." -ForegroundColor Cyan

# Un Service Principal (app) peut détenir un rôle Entra directement.
# Exemple : une app d'automatisation avec "User Administrator" pour provisionner des comptes.
# C'est un vecteur d'attaque documenté : compromettre l'app = obtenir le rôle Entra.
# En mission : tout SP avec un rôle sensible est un point d'attention prioritaire.
#
# Distinction SP Microsoft vs SP tiers :
#   AppOwnerOrganizationId == "f8cdef31-a31e-4b4a-93e4-5f571e91255a" → Microsoft
#   Autre GUID → app tierce ou développement interne → risque plus élevé
$SPRoleRows = @()

$SPAssignments = $AllAssignments | Where-Object {
    $PrincipalType = Resolve-PrincipalType $_.PrincipalId $AllUsers $AllGroups $AllServicePrincipals
    $PrincipalType -eq "ServicePrincipal"
}

foreach ($Assignment in $SPAssignments) {
    $SP      = $AllServicePrincipals | Where-Object { $_.Id -eq $Assignment.PrincipalId } | Select-Object -First 1
    $RoleDef = $AllRoleDefinitions | Where-Object { $_.Id -eq $Assignment.RoleDefinitionId } | Select-Object -First 1
    $Scope   = Resolve-ScopeLabel $Assignment.DirectoryScopeId $AllAUs

    $SPRoleRows += [PSCustomObject]@{
        NomApp           = if ($SP) { $SP.DisplayName } else { $Assignment.PrincipalId }
        AppId            = if ($SP) { $SP.AppId }       else { "" }
        Editeur          = if ($SP -and $SP.AppOwnerOrganizationId -eq "f8cdef31-a31e-4b4a-93e4-5f571e91255a") {
                               "Microsoft"
                           } elseif ($SP) { "Tiers / Interne" } else { "Inconnu" }
        Role             = if ($RoleDef) { $RoleDef.DisplayName } else { $Assignment.RoleDefinitionId }
        Sensible         = if ($SensitiveRoleNames -contains $RoleDef.DisplayName) { "SENSIBLE" } else { "" }
        Perimetre        = $Scope
        DirectoryScopeId = $Assignment.DirectoryScopeId
        AssignationId    = $Assignment.Id
        # Colonnes disponibles non exportées :
        #   $SP.AppOwnerOrganizationId : GUID de l'éditeur
        #   $SP.CreatedDateTime        : date de création du SP
        #   $RoleDef.Description       : description du rôle
        #   $Assignment.CreatedDateTime : date de l'assignation
    }
}

Write-Host "-> $($SPRoleRows.Count) Service Principal(aux) avec rôle(s) Entra.`n" -ForegroundColor $(
    if (($SPRoleRows | Where-Object { $_.Sensible -eq "SENSIBLE" }).Count -gt 0) { "Yellow" } else { "Green" }
)

# ========================================================================================
# ÉTAPE 7 : CSV 6 — Rôles custom et leurs assignations
# ========================================================================================
Write-Host "7. Audit des rôles custom..." -ForegroundColor Cyan

# Les rôles custom sont créés par les admins du tenant pour un least privilege plus fin.
# Leur présence indique une maturité IAM — leur absence aussi (tout le monde sur des
# rôles built-in trop larges = manque de granularité, voir exo 8a).
# En mission : inventorier les rôles custom avant d'en créer de nouveaux évite les doublons.
$CustomRoleRows = @()
$CustomRoleDefs = $AllRoleDefinitions | Where-Object { $_.IsBuiltIn -eq $false }

foreach ($CustomRole in $CustomRoleDefs) {
    $Assignments = $AllAssignments | Where-Object { $_.RoleDefinitionId -eq $CustomRole.Id }

    if ($Assignments.Count -gt 0) {
        foreach ($Assignment in $Assignments) {
            $User  = $AllUsers | Where-Object { $_.Id -eq $Assignment.PrincipalId } | Select-Object -First 1
            $Scope = Resolve-ScopeLabel $Assignment.DirectoryScopeId $AllAUs

            $CustomRoleRows += [PSCustomObject]@{
                NomRole          = $CustomRole.DisplayName
                RoleDefinitionId = $CustomRole.Id
                Description      = $CustomRole.Description
                Utilisateur      = if ($User) { $User.DisplayName }      else { $Assignment.PrincipalId }
                UPN              = if ($User) { $User.UserPrincipalName } else { "Non résolu (groupe ou SP)" }
                Perimetre        = $Scope
                DirectoryScopeId = $Assignment.DirectoryScopeId
                # Colonnes disponibles non exportées :
                #   $CustomRole.RolePermissions : liste des actions autorisées
                #   $CustomRole.IsEnabled       : rôle actif ou désactivé
                #   $CustomRole.CreatedDateTime : date de création du rôle
                #   $Assignment.Id              : ID de l'assignation
            }
        }
    } else {
        # Rôle custom sans aucune assignation — créé mais inutilisé
        $CustomRoleRows += [PSCustomObject]@{
            NomRole          = $CustomRole.DisplayName
            RoleDefinitionId = $CustomRole.Id
            Description      = $CustomRole.Description
            Utilisateur      = "AUCUNE ASSIGNATION"
            UPN              = ""
            Perimetre        = ""
            DirectoryScopeId = ""
        }
    }
}

Write-Host "-> $($CustomRoleDefs.Count) rôle(s) custom — $($CustomRoleRows.Count) ligne(s) d'assignation.`n" -ForegroundColor Green

# ========================================================================================
# ÉTAPE 8 : CSV 7 — Rôles built-in sans aucun détenteur actif
# ========================================================================================
Write-Host "8. Audit des rôles built-in sans détenteur..." -ForegroundColor Cyan

# Un rôle built-in sans assignation active NI éligibilité PIM peut indiquer :
#   → Bonne pratique : le rôle n'est pas nécessaire sur ce tenant (normal)
#   → Problème : le rôle devrait être couvert mais l'assignation a été supprimée par erreur
#     Ex : "Global Administrator" sans aucun détenteur = tenant potentiellement orphelin
#
# En mission : croiser ce CSV avec le contexte client. Sur un tenant de dev, la plupart
# des rôles built-in seront vides — c'est attendu. Sur un tenant de prod, un rôle
# fonctionnel sans détenteur (ex : "Exchange Administrator" sans assignation alors que
# Exchange est utilisé) est un signal d'alerte à investiguer.
$NoAssignmentRows = @()
$BuiltInRoleDefs  = $AllRoleDefinitions | Where-Object { $_.IsBuiltIn -eq $true }

foreach ($RoleDef in $BuiltInRoleDefs) {
    $HasActive   = $AllAssignments   | Where-Object { $_.RoleDefinitionId -eq $RoleDef.Id }
    $HasEligible = $AllEligibilities | Where-Object { $_.RoleDefinitionId -eq $RoleDef.Id }

    if ($HasActive.Count -eq 0 -and $HasEligible.Count -eq 0) {
        $NoAssignmentRows += [PSCustomObject]@{
            NomRole          = $RoleDef.DisplayName
            RoleDefinitionId = $RoleDef.Id
            Description      = $RoleDef.Description
            Sensible         = if ($SensitiveRoleNames -contains $RoleDef.DisplayName) { "SENSIBLE" } else { "" }
            NbActives        = 0
            NbEligibles      = 0
            # Colonnes disponibles non exportées :
            #   $RoleDef.RolePermissions : actions couvertes par le rôle
            #   $RoleDef.IsEnabled       : rôle activé dans le tenant
        }
    }
}

Write-Host "-> $($NoAssignmentRows.Count) rôle(s) built-in sans aucun détenteur actif ni éligible.`n" -ForegroundColor Green

# ========================================================================================
# ÉTAPE 9 : CSV 8 — Assignations PIM expirant dans 30 jours
# ========================================================================================
Write-Host "9. Audit des assignations PIM à expiration imminente..." -ForegroundColor Cyan

# Identifier proactivement les assignations qui vont expirer permet d'éviter
# des coupures d'accès non anticipées en production.
# En mission : livrable hebdomadaire à transmettre aux équipes IAM pour renouvellement.
# Seuil de 30 jours — ajustable selon la politique du client.
$ExpirationThreshold = (Get-Date).AddDays(30)
$ExpirationRows = @()

# Contrôle sur les schedules PIM actifs
foreach ($Schedule in $AllSchedules) {
    $EndDate = $Schedule.ScheduleInfo.Expiration.EndDateTime
    if ($null -eq $EndDate -or $EndDate -gt $ExpirationThreshold) { continue }

    $User    = $AllUsers | Where-Object { $_.Id -eq $Schedule.PrincipalId } | Select-Object -First 1
    $RoleDef = $AllRoleDefinitions | Where-Object { $_.Id -eq $Schedule.RoleDefinitionId } | Select-Object -First 1
    $Scope   = Resolve-ScopeLabel $Schedule.DirectoryScopeId $AllAUs

    $ExpirationRows += [PSCustomObject]@{
        TypeAssignation  = "PIM Active"
        Utilisateur      = if ($User) { $User.DisplayName }      else { $Schedule.PrincipalId }
        UPN              = if ($User) { $User.UserPrincipalName } else { "Non résolu" }
        Role             = if ($RoleDef) { $RoleDef.DisplayName } else { $Schedule.RoleDefinitionId }
        Sensible         = if ($SensitiveRoleNames -contains $RoleDef.DisplayName) { "SENSIBLE" } else { "" }
        Perimetre        = $Scope
        Expiration       = $EndDate
        JoursRestants    = [math]::Round(($EndDate - (Get-Date)).TotalDays)
        AssignationId    = $Schedule.Id
    }
}

# Contrôle sur les éligibilités PIM
foreach ($Eligibility in $AllEligibilities) {
    $EndDate = $Eligibility.ScheduleInfo.Expiration.EndDateTime
    if ($null -eq $EndDate -or $EndDate -gt $ExpirationThreshold) { continue }

    $User    = $AllUsers | Where-Object { $_.Id -eq $Eligibility.PrincipalId } | Select-Object -First 1
    $RoleDef = $AllRoleDefinitions | Where-Object { $_.Id -eq $Eligibility.RoleDefinitionId } | Select-Object -First 1
    $Scope   = Resolve-ScopeLabel $Eligibility.DirectoryScopeId $AllAUs

    $ExpirationRows += [PSCustomObject]@{
        TypeAssignation  = "PIM Eligible"
        Utilisateur      = if ($User) { $User.DisplayName }      else { $Eligibility.PrincipalId }
        UPN              = if ($User) { $User.UserPrincipalName } else { "Non résolu" }
        Role             = if ($RoleDef) { $RoleDef.DisplayName } else { $Eligibility.RoleDefinitionId }
        Sensible         = if ($SensitiveRoleNames -contains $RoleDef.DisplayName) { "SENSIBLE" } else { "" }
        Perimetre        = $Scope
        Expiration       = $EndDate
        JoursRestants    = [math]::Round(($EndDate - (Get-Date)).TotalDays)
        AssignationId    = $Eligibility.Id
        # Colonnes disponibles non exportées :
        #   $Eligibility.ScheduleInfo.Expiration.Duration : durée ISO 8601
    }
}

$ExpirationRows = $ExpirationRows | Sort-Object JoursRestants
Write-Host "-> $($ExpirationRows.Count) assignation(s) PIM expirant dans les 30 prochains jours.`n" -ForegroundColor $(
    if ($ExpirationRows.Count -gt 0) { "Yellow" } else { "Green" }
)

# ========================================================================================
# ÉTAPE 10 : CSV 9 — Comptes break glass
# ========================================================================================
Write-Host "10. Détection des comptes break glass..." -ForegroundColor Cyan

# Les comptes break glass sont des comptes d'urgence Global Admin permanents,
# hors MFA, hors PIM, hors CA — utilisables uniquement si le tenant devient inaccessible.
# Ils doivent exister, être permanents, et ne JAMAIS se connecter en conditions normales.
#
# Détection par deux critères combinés :
#   1. Convention de nommage (DisplayName ou UPN contient un pattern break glass)
#   2. Détenteur d'un rôle Global Administrator permanent (hors PIM)
#
# SignInActivity.LastSignInDateTime : dernière connexion interactive.
# Un break glass qui se connecte régulièrement = utilisation anormale à investiguer.
# Un break glass qui n'a jamais eu de SignInActivity = compte sain (jamais utilisé).
#
# [DEV] Sur un tenant de dev, aucun compte break glass n'existe généralement.
# Ce CSV sera vide — c'est le comportement attendu.
# [PROD] Adapter $BreakGlassPatterns à la convention de nommage du client.
$BreakGlassRows = @()

# Détection par convention de nommage
$BGUsersByName = $AllUsers | Where-Object {
    $UPN  = $_.UserPrincipalName.ToLower()
    $Name = $_.DisplayName.ToLower()
    $Match = $false
    foreach ($Pattern in $BreakGlassPatterns) {
        if ($UPN -like "*$($Pattern.ToLower())*" -or $Name -like "*$($Pattern.ToLower())*") {
            $Match = $true; break
        }
    }
    $Match
}

# Détection par rôle Global Admin permanent (hors PIM — AssignmentType "Assigned")
$GlobalAdminRoleId = ($AllRoleDefinitions | Where-Object { $_.DisplayName -eq "Global Administrator" }).Id
$GlobalAdminPermanent = $AllSchedules | Where-Object {
    $_.RoleDefinitionId -eq $GlobalAdminRoleId -and $_.AssignmentType -eq "Assigned"
}

# Union des deux détections — dédoublonnage sur Id
$BGCandidateIds = @()
$BGCandidateIds += $BGUsersByName.Id
$BGCandidateIds += ($GlobalAdminPermanent | ForEach-Object {
    $AllUsers | Where-Object { $_.Id -eq $_.PrincipalId } | Select-Object -ExpandProperty Id
})
$BGCandidateIds = $BGCandidateIds | Sort-Object -Unique

foreach ($BGId in $BGCandidateIds) {
    $BGUser = $AllUsers | Where-Object { $_.Id -eq $BGId } | Select-Object -First 1
    if (-not $BGUser) { continue }

    # Vérification : est-il Global Admin permanent ?
    $IsGlobalAdminPermanent = ($GlobalAdminPermanent |
        Where-Object { $_.PrincipalId -eq $BGId }).Count -gt 0

    # Détecté par nom uniquement (pas forcément Global Admin) ?
    $DetectedByName = ($BGUsersByName | Where-Object { $_.Id -eq $BGId }).Count -gt 0

    $BreakGlassRows += [PSCustomObject]@{
        DisplayName           = $BGUser.DisplayName
        UPN                   = $BGUser.UserPrincipalName
        CompteActif           = $BGUser.AccountEnabled
        GlobalAdminPermanent  = $IsGlobalAdminPermanent
        DetectéParNommage     = $DetectedByName
        DerniereConnexion     = if ($BGUser.SignInActivity.LastSignInDateTime) {
                                    $BGUser.SignInActivity.LastSignInDateTime
                                } else { "Jamais connecté" }
        # Une dernière connexion récente sur un break glass est un signal d'alerte.
        # "Jamais connecté" est le comportement attendu pour un vrai compte d'urgence.
        Alerte                = if ($BGUser.SignInActivity.LastSignInDateTime -gt (Get-Date).AddDays(-30)) {
                                    "CONNEXION RECENTE — À INVESTIGUER"
                                } else { "" }
        # Colonnes disponibles non exportées :
        #   $BGUser.Id                                      : ObjectId
        #   $BGUser.SignInActivity.LastNonInteractiveSignIn : dernière connexion non interactive
        #   $BGUser.UserType                                : Member (attendu) ou Guest (anormal)
    }
}

Write-Host "-> $($BreakGlassRows.Count) compte(s) break glass détecté(s).`n" -ForegroundColor $(
    if ($BreakGlassRows.Count -eq 0) { "Yellow" } else { "Green" }
)

# ========================================================================================
# ÉTAPE 11 : Résumé chiffré
# ========================================================================================
Write-Host "`n=== RÉSUMÉ ===" -ForegroundColor Magenta
[PSCustomObject]@{
    "Assignations permanentes (users)"  = $PermanentRows.Count
    "Dont rôles sensibles"              = ($PermanentRows | Where-Object { $_.Sensible -eq "SENSIBLE" }).Count
    "PIM actives en ce moment"          = $PIMActiveRows.Count
    "PIM éligibles (non activées)"      = $PIMEligibleRows.Count
    "Membres via groupes (effectifs)"   = ($GroupRoleRows | Where-Object { $_.MembreDisplayName -ne "GROUPE VIDE" }).Count
    "Service Principals avec rôles"     = $SPRoleRows.Count
    "Dont SPs tiers/internes sensibles" = ($SPRoleRows | Where-Object { $_.Sensible -eq "SENSIBLE" -and $_.Editeur -ne "Microsoft" }).Count
    "Rôles custom"                      = $CustomRoleDefs.Count
    "Rôles built-in sans détenteur"     = $NoAssignmentRows.Count
    "Expirations imminentes (30j)"      = $ExpirationRows.Count
    "Comptes break glass détectés"      = $BreakGlassRows.Count
    Scope                               = "Lecture seule — aucune modification du tenant"
} | Format-List

# ========================================================================================
# EXPORT CSV — 9 FICHIERS
# ========================================================================================
Write-Host "Export CSV en cours (9 fichiers)..." -ForegroundColor Cyan

# EN LABO / Local :
$ExportPath = "D:\Documents\ScriptsPowerShell\Exports\"
# EN PRODUCTION :
# $ExportPath = "$PSScriptRoot\Exports\"

New-Item -ItemType Directory -Force -Path $ExportPath | Out-Null
$Timestamp = Get-Date -Format "yyyyMMdd_HHmmss"

# --- CSV 1 : Assignations permanentes directes ---
# Colonnes : Utilisateur, UPN, Role, TypeRole, Sensible, Perimetre, DirectoryScopeId,
#            CompteActif, AssignationId
# Livrable principal pour remédiation : filtrer Sensible = "SENSIBLE" et convertir
# en PIM éligible (exo 6b). Toute assignation permanente sur rôle sensible = priorité 1.
# Exclut les groupes (CSV 4) et les SPs (CSV 5).
if ($PermanentRows.Count -gt 0) {
    $PermanentRows | Sort-Object Sensible -Descending | Export-Csv `
        -Path "$ExportPath\RBAC_Permanentes_$Timestamp.csv" `
        -Encoding UTF8 -NoTypeInformation
    Write-Host "-> Permanentes    : $($PermanentRows.Count) ligne(s)" -ForegroundColor Green
} else {
    Write-Host "-> Permanentes    : aucune donnée." -ForegroundColor Yellow
}

# --- CSV 2 : PIM actives ---
# Colonnes : Utilisateur, UPN, TypePrincipal, Role, Sensible, Perimetre,
#            DirectoryScopeId, Statut, Expiration, AssignationId
# Snapshot des droits élevés en cours RIGHT NOW. Croiser avec CSV 8 (expirations imminentes).
# Utile en astreinte ou incident pour savoir qui peut agir immédiatement.
if ($PIMActiveRows.Count -gt 0) {
    $PIMActiveRows | Sort-Object Sensible -Descending | Export-Csv `
        -Path "$ExportPath\RBAC_PIM_Actives_$Timestamp.csv" `
        -Encoding UTF8 -NoTypeInformation
    Write-Host "-> PIM actives    : $($PIMActiveRows.Count) ligne(s)" -ForegroundColor Green
} else {
    Write-Host "-> PIM actives    : aucune donnée." -ForegroundColor Yellow
}

# --- CSV 3 : PIM éligibles ---
# Colonnes : Utilisateur, UPN, TypePrincipal, Role, Sensible, Perimetre,
#            DirectoryScopeId, Statut, DebutEligibilite, FinEligibilite, EligibiliteId
# Vue "qui peut activer quoi" — complément indispensable du CSV 2.
# Un audit RBAC sans ce CSV manque tous les utilisateurs éligibles non activés.
if ($PIMEligibleRows.Count -gt 0) {
    $PIMEligibleRows | Sort-Object Sensible -Descending | Export-Csv `
        -Path "$ExportPath\RBAC_PIM_Eligibles_$Timestamp.csv" `
        -Encoding UTF8 -NoTypeInformation
    Write-Host "-> PIM éligibles  : $($PIMEligibleRows.Count) ligne(s)" -ForegroundColor Green
} else {
    Write-Host "-> PIM éligibles  : aucune donnée." -ForegroundColor Yellow
}

# --- CSV 4 : Membres via groupes ---
# Colonnes : NomGroupe, GroupeId, MembreDisplayName, MembreUPN, Role, Sensible,
#            Perimetre, DirectoryScopeId, CompteActif
# Vecteur d'élévation discret : ajouter un user au groupe donne le rôle sans assignation
# individuelle visible. Filtrer GROUPE VIDE pour identifier les groupes assignés sans membres.
if ($GroupRoleRows.Count -gt 0) {
    $GroupRoleRows | Sort-Object Sensible -Descending | Export-Csv `
        -Path "$ExportPath\RBAC_Groupes_Membres_$Timestamp.csv" `
        -Encoding UTF8 -NoTypeInformation
    Write-Host "-> Groupes membres: $($GroupRoleRows.Count) ligne(s)" -ForegroundColor Green
} else {
    Write-Host "-> Groupes membres: aucune donnée." -ForegroundColor Yellow
}

# --- CSV 5 : Service Principals ---
# Colonnes : NomApp, AppId, Editeur, Role, Sensible, Perimetre, DirectoryScopeId, AssignationId
# Filtrer Editeur = "Tiers / Interne" ET Sensible = "SENSIBLE" pour prioriser.
# Un SP tiers avec Global Administrator = risque critique — à investiguer immédiatement.
if ($SPRoleRows.Count -gt 0) {
    $SPRoleRows | Sort-Object Sensible -Descending | Export-Csv `
        -Path "$ExportPath\RBAC_ServicePrincipals_$Timestamp.csv" `
        -Encoding UTF8 -NoTypeInformation
    Write-Host "-> Service Princ. : $($SPRoleRows.Count) ligne(s)" -ForegroundColor Green
} else {
    Write-Host "-> Service Princ. : aucune donnée." -ForegroundColor Yellow
}

# --- CSV 6 : Rôles custom ---
# Colonnes : NomRole, RoleDefinitionId, Description, Utilisateur, UPN,
#            Perimetre, DirectoryScopeId
# Filtrer Utilisateur = "AUCUNE ASSIGNATION" pour identifier les rôles custom orphelins
# (créés mais jamais utilisés — candidats à la suppression ou à la documentation).
if ($CustomRoleRows.Count -gt 0) {
    $CustomRoleRows | Export-Csv `
        -Path "$ExportPath\RBAC_Custom_$Timestamp.csv" `
        -Encoding UTF8 -NoTypeInformation
    Write-Host "-> Custom         : $($CustomRoleRows.Count) ligne(s)" -ForegroundColor Green
} else {
    Write-Host "-> Custom         : aucune donnée." -ForegroundColor Yellow
}

# --- CSV 7 : Rôles built-in sans détenteur ---
# Colonnes : NomRole, RoleDefinitionId, Description, Sensible, NbActives, NbEligibles
# Filtrer Sensible = "SENSIBLE" pour prioriser les rôles fonctionnels sans couverture.
# Sur tenant de dev : ce CSV sera volumineux (normal). Sur tenant de prod : tout rôle
# sensible sans détenteur est un signal à investiguer avec le client.
if ($NoAssignmentRows.Count -gt 0) {
    $NoAssignmentRows | Sort-Object Sensible -Descending | Export-Csv `
        -Path "$ExportPath\RBAC_Roles_Sans_Assignation_$Timestamp.csv" `
        -Encoding UTF8 -NoTypeInformation
    Write-Host "-> Sans assignat. : $($NoAssignmentRows.Count) ligne(s)" -ForegroundColor Green
} else {
    Write-Host "-> Sans assignat. : aucune donnée." -ForegroundColor Yellow
}

# --- CSV 8 : Expirations imminentes ---
# Colonnes : TypeAssignation, Utilisateur, UPN, Role, Sensible, Perimetre,
#            Expiration, JoursRestants, AssignationId
# Trié par JoursRestants ASC — les plus urgents en premier.
# Livrable hebdomadaire : transmettre aux équipes IAM pour renouvellement proactif.
# Seuil de 30 jours ajustable via $ExpirationThreshold en étape 9.
if ($ExpirationRows.Count -gt 0) {
    $ExpirationRows | Export-Csv `
        -Path "$ExportPath\RBAC_Expiration_Imminente_$Timestamp.csv" `
        -Encoding UTF8 -NoTypeInformation
    Write-Host "-> Expirations    : $($ExpirationRows.Count) ligne(s)" -ForegroundColor Green
} else {
    Write-Host "-> Expirations    : aucune donnée." -ForegroundColor Yellow
}

# --- CSV 9 : Break glass ---
# Colonnes : DisplayName, UPN, CompteActif, GlobalAdminPermanent, DetectéParNommage,
#            DerniereConnexion, Alerte
# Filtrer Alerte = "CONNEXION RECENTE" pour les cas à investiguer immédiatement.
# "Jamais connecté" = comportement attendu pour un vrai compte break glass.
# Adapter $BreakGlassPatterns en étape 1 selon la convention de nommage du client.
if ($BreakGlassRows.Count -gt 0) {
    $BreakGlassRows | Export-Csv `
        -Path "$ExportPath\RBAC_BreakGlass_$Timestamp.csv" `
        -Encoding UTF8 -NoTypeInformation
    Write-Host "-> Break glass    : $($BreakGlassRows.Count) ligne(s)" -ForegroundColor Green
} else {
    Write-Host "-> Break glass    : aucune donnée (normal sur tenant de dev)." -ForegroundColor Yellow
}

Write-Host "`n-> Export terminé dans : $ExportPath" -ForegroundColor Green

# ========================================================================================
# NETTOYAGE MÉMOIRE
# ========================================================================================
Remove-Variable Scopes, AllRoleDefinitions, AllAssignments, AllSchedules, AllEligibilities,
                AllAUs, AllUsers, AllGroups, AllServicePrincipals, SensitiveRoleNames,
                BreakGlassPatterns, PermanentRows, PIMActiveRows, PIMEligibleRows,
                GroupRoleRows, GroupAssignments, SPRoleRows, SPAssignments,
                CustomRoleRows, CustomRoleDefs, NoAssignmentRows, BuiltInRoleDefs,
                ExpirationRows, ExpirationThreshold, BreakGlassRows, BGUsersByName,
                GlobalAdminRoleId, GlobalAdminPermanent, BGCandidateIds, BGId, BGUser,
                Assignment, Schedule, Eligibility, RoleDef, User, Group, SP, Members,
                Member, MemberUser, CustomRole, Scope, AUId, IsGlobalAdminPermanent,
                DetectedByName, ExportPath, Timestamp `
                -ErrorAction SilentlyContinue

# ========================================================================================
# FERMETURE — RESET DE SESSION TOTAL
# ========================================================================================
Disconnect-MgGraph -ErrorAction SilentlyContinue
Write-Host "Session MgGraph fermée proprement." -ForegroundColor Magenta
