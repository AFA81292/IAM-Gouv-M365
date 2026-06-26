# ========================================================================================
# Exercice 9d : Entra ID — Audit transverse — Tenant Security Snapshot
# ========================================================================================
# Concept : Arriver en mission et avoir une vue exhaustive du tenant en une exécution.
# Une connexion, une passe, huit CSV d'audit + un Summary.txt chiffré prêt à transmettre.
#
# Ce script est le consommateur final de tout le repo — il agrège les logiques des
# chapitres précédents en une seule passe optimisée :
#   Chapitre 01 → identités, invités, inactifs
#   Chapitre 03 → groupes
#   Chapitre 01 → licences
#   Chapitre 08 → rôles admin (sous-ensemble de 8f : permanents + sensibles)
#   Chapitre 09a → MFA
#   Chapitre 09b → Enterprise Apps
#   Chapitre 05 → Conditional Access
#
# Delta pédagogique vs scripts chapitres dédiés :
#   Scripts chapitres → granularité maximale, tous les angles, tous les CSV
#   9d → vue de première semaine en mission : les chiffres clés, les signaux d'alerte,
#        le tout en une connexion avec les scopes cumulés
#
# Ce que fait ce script :
#   1.  Reset total de session + connexion multi-scopes
#   2.  Chargement en cache de toutes les données sources
#   3.  CSV 1 : Identity-Audit (identités membres + état)
#   4.  CSV 2 : Guest-Audit (invités + inactivité)
#   5.  CSV 3 : Groups-Audit (groupes + type + owner)
#   6.  CSV 4 : Licences-Audit (SKUs + utilisateurs sans licence)
#   7.  CSV 5 : AdminRoles-Audit (rôles permanents + sensibles — from 8f)
#   8.  CSV 6 : MFA-Audit (posture MFA par utilisateur — from 9a)
#   9.  CSV 7 : EnterpriseApps-Audit (apps tierces + sans owner — from 9b)
#   10. CSV 8 : ConditionalAccess-Audit (politiques CA + état — from 5a)
#   11. Summary.txt — chiffres clés du tenant, signaux d'alerte
#   12. Fermeture propre
#
# Note : ce script est en lecture seule — aucune modification du tenant.
#
# DÉCOUVERTE TECHNIQUE — dates Graph et PowerShell (REX exo 9c) :
#   Graph retourne les dates en string ISO 8601, pas en [DateTime].
#   PIÈGE 1 : soustraction arithmétique → cast obligatoire [DateTime]$obj.XxxDateTime
#   PIÈGE 2 : certains champs DateTime peuvent être $null (Managed Identities, SPs...)
#             → garde-fou $x -and [DateTime]$x avant tout cast
#   PIÈGE 3 : return if (...) invalide en PS → if (...) { return X } else { return Y }
#   Ces trois pièges sont documentés et corrigés dans ce script dès la génération.
#
# Structure générée :
#   Reports\
#   ├── Identity-Audit.csv
#   ├── Guest-Audit.csv
#   ├── Groups-Audit.csv
#   ├── Licences-Audit.csv
#   ├── AdminRoles-Audit.csv
#   ├── MFA-Audit.csv
#   ├── EnterpriseApps-Audit.csv
#   ├── ConditionalAccess-Audit.csv
#   └── Summary.txt
#
# Module requis : Microsoft.Graph (tous modules)
# Connexion     : Connect-MgGraph
# ========================================================================================

# ========================================================================================
# LIMITES DE SCALABILITÉ — CE SCRIPT SUR UN TENANT DE PRODUCTION À GRANDE ÉCHELLE
# ========================================================================================
# Ce script est un POC sur tenant de dev. Il fonctionne parfaitement jusqu'à quelques
# milliers d'utilisateurs. Sur un tenant de 50 000+ users (AXA, BNP, Total...), trois
# problèmes structurels apparaissent.
#
# DEUX CORRECTIONS ont été appliquées dans ce script (non négociables) :
#   ✔ Hashtables pour tous les lookups → O(n) au lieu de O(n²)
#   ✔ Endpoint MFA agrégé (/reports/...) au lieu de 1 appel Graph par user
#
# TROIS PATTERNS restent volontairement en mode POC (lisibilité > performance) :
#   ✘ Get-MgGroupOwner en boucle     → fan-out API, acceptable en lab
#   ✘ Get-MgServicePrincipalOwner    → idem
#   ✘ Get-MgUser -All (tout en RAM)  → pagination streaming hors périmètre POC
#
# ────────────────────────────────────────────────────────────────────────────────────────
# PROBLÈME 1 — LOOKUPS O(n²) : résolu dans ce script via hashtables
# ────────────────────────────────────────────────────────────────────────────────────────
# Sans hashtable (naïf) :
#   $OwnerUser = $AllUsers | Where-Object { $_.Id -eq $Owner.Id }
#   → scan complet du tableau à chaque lookup
#   → sur 50k users avec 200 owners de groupes : 10 000 000 comparaisons
#
# Avec hashtable (ce script) :
#   $UsersById = @{}; $AllUsers | ForEach-Object { $UsersById[$_.Id] = $_ }
#   $OwnerUser = $UsersById[$Owner.Id]
#   → lookup direct, O(1) par accès
#   → même logique, même lisibilité, performance radicalement différente
#   → c'est le seul upgrade "gratuit" : tu ne changes pas le modèle mental
#
# ────────────────────────────────────────────────────────────────────────────────────────
# PROBLÈME 2 — MFA PER-USER CALLS : résolu via endpoint agrégé
# ────────────────────────────────────────────────────────────────────────────────────────
# Version naïve (exo 9a, acceptable car script dédié) :
#   foreach ($User in $AllUsers) {
#       Get-MgUserAuthenticationMethod -UserId $User.Id   ← 1 call Graph par user
#   }
#   → 125 000 appels Graph sur AXA → throttling + ~7h d'exécution
#
# Version snapshot (ce script) :
#   Get-MgReportAuthenticationMethodUserRegistration -All  ← 1 appel total
#   → retourne IsMfaRegistered, IsMfaCapable, MethodsRegistered pour tous les users
#   → trade-off assumé : posture globale ✔ | granularité forensic ✘
#
# Comparaison des deux approches :
#   Endpoint per-user (9a) : précision maximale, méthodes détaillées, lent à scale
#   Endpoint report (9d)   : posture rapide, 1 appel, suffisant pour un snapshot
#   → Pour un audit approfondi → exo 9a
#   → Pour un snapshot de première semaine → cet endpoint est le bon choix
#
# ────────────────────────────────────────────────────────────────────────────────────────
# PROBLÈME 3 — PATTERNS RESTANTS EN MODE POC (volontairement non optimisés)
# ────────────────────────────────────────────────────────────────────────────────────────
# Get-MgGroupOwner / Get-MgServicePrincipalOwner en boucle :
#   Pattern acceptable en lab / POC, non recommandé à scale.
#   Solution enterprise : batching Graph ($batch endpoint, 20 requêtes groupées)
#   ou expansion OData ($expand=owners dans la requête initiale).
#   Non implémenté ici : le code batch détruit la lisibilité linéaire du script
#   sans changer l'objectif (snapshot pédagogique, pas engine Graph).
#
# Get-MgUser -All (tout en RAM) :
#   Pattern acceptable jusqu'à ~10 000 users sur une machine standard.
#   Solution enterprise : pagination streaming + écriture CSV au fil de l'eau.
#   Non implémenté ici : la pagination casse le modèle "une passe → résumé global"
#   qui est l'invariant cognitif principal de ce script.
#
# Retry sur throttling (429) :
#   Non implémenté — sur tenant de dev le quota n'est jamais atteint.
#   Solution enterprise : wrapper function avec backoff exponentiel sur tous les appels.
#   Voir bloc éducatif dans l'en-tête de ce script pour l'exemple de code.
#
# ────────────────────────────────────────────────────────────────────────────────────────
# RÈGLE D'ARBITRAGE (à retenir pour tout repo pédagogique)
# ────────────────────────────────────────────────────────────────────────────────────────
# Si une optimisation rend le code impossible à lire sans réfléchir 10 secondes
# → elle est hors scope POC.
#
# Ce script applique cette règle :
#   Hashtables → coût cognitif nul, gain de perf réel    → appliqué
#   Endpoint MFA agrégé → code plus simple, pas plus complexe → appliqué
#   Batching / pagination / retry → coût cognitif élevé  → documenté, non implémenté
#
# Pour un tenant enterprise (50 000+ users) → utiliser à la place :
#   Entra ID Governance (rapports natifs, export CSV intégré)
#   Microsoft Graph Data Connect (export massif hors bande, Azure requis)
#   Microsoft Sentinel / KQL (logs streamés, requêtes incrémentales)
#   Outils IAM spécialisés : Saviynt, SailPoint, Varonis, CyberArk
# ========================================================================================

# --- OUVERTURE — RESET DE SESSION TOTAL ---
# Scopes cumulés de tous les chapitres couverts :
#   User.Read.All                    : identités, invités, résolution principals
#   Group.Read.All                   : groupes, membres, owners
#   Directory.Read.All               : SKUs licences, objets directory
#   Policy.Read.All                  : politiques Conditional Access
#   RoleManagement.Read.Directory    : rôles Entra + assignations
#   Reports.Read.All                 : endpoint MFA agrégé (/reports/authenticationMethods/...)
#   Application.Read.All             : Enterprise Apps, SPs, owners
#   AuditLog.Read.All                : SignInActivity (inactivité invités)
#
# Pas de -ContextScope Process requis : lecture seule, aucun scope d'écriture.
$Scopes = @(
    "User.Read.All",
    "Group.Read.All",
    "Directory.Read.All",
    "Policy.Read.All",
    "RoleManagement.Read.Directory",
    "Reports.Read.All",
    "Application.Read.All",
    "AuditLog.Read.All"
)

Disconnect-MgGraph -ErrorAction SilentlyContinue
Connect-MgGraph -Scopes $Scopes -NoWelcome

# ========================================================================================
# ÉTAPE 1 : Chargement en cache + construction des hashtables de lookup
# ========================================================================================
Write-Host "1. Chargement des données sources en cache..." -ForegroundColor Cyan

$AllUsers           = Get-MgUser -All -Property "Id,DisplayName,UserPrincipalName,UserType,AccountEnabled,Department,JobTitle,CreatedDateTime,SignInActivity,AssignedLicenses"
$AllGroups          = Get-MgGroup -All -Property "Id,DisplayName,GroupTypes,SecurityEnabled,MembershipRule,CreatedDateTime"
$AllSKUs            = Get-MgSubscribedSku -All
$AllRoleDefinitions = Get-MgRoleManagementDirectoryRoleDefinition -All
$AllRoleAssignments = Get-MgRoleManagementDirectoryRoleAssignment -All
$AllRoleSchedules   = Get-MgRoleManagementDirectoryRoleAssignmentSchedule -All
$AllEligibilities   = Get-MgRoleManagementDirectoryRoleEligibilitySchedule -All
$AllSPs             = Get-MgServicePrincipal -All -Property "Id,DisplayName,AppId,AppOwnerOrganizationId,CreatedDateTime,AccountEnabled,ServicePrincipalType"
$AllAppRegs         = Get-MgApplication -All -Property "Id,DisplayName,AppId,CreatedDateTime"
$AllCAPolicies      = Get-MgIdentityConditionalAccessPolicy -All

# Endpoint MFA agrégé — 1 appel total pour tous les users
# Remplace le loop per-user de 9a (1 appel Graph/user → throttling à scale)
# Retourne : IsMfaRegistered, IsMfaCapable, MethodsRegistered, UserPrincipalName
# DÉCOUVERTE TECHNIQUE : nécessite Reports.Read.All — scope distinct de User.Read.All
# Trade-off assumé : posture globale ✔ | granularité forensic par méthode ✘ (→ exo 9a)
$MFAReport = Get-MgReportAuthenticationMethodUserRegistration -All

# ────────────────────────────────────────────────────────────────────────────────────────
# HASHTABLES DE LOOKUP — correction O(n²) → O(n)
# Construites une seule fois ici, réutilisées dans toutes les étapes suivantes.
# Pattern : $Index[$Id] = $Objet → lookup O(1) au lieu de Where-Object O(n)
# ────────────────────────────────────────────────────────────────────────────────────────
$UsersById       = @{}; $AllUsers           | ForEach-Object { $UsersById[$_.Id]       = $_ }
$GroupsById      = @{}; $AllGroups          | ForEach-Object { $GroupsById[$_.Id]      = $_ }
$RoleDefsById    = @{}; $AllRoleDefinitions | ForEach-Object { $RoleDefsById[$_.Id]    = $_ }
$SchedulesById   = @{}; $AllRoleSchedules   | ForEach-Object { $SchedulesById[$_.Id]   = $_ }
$MFAByUPN        = @{}; $MFAReport          | ForEach-Object { $MFAByUPN[$_.UserPrincipalName] = $_ }
$LocalAppIds     = @{}; $AllAppRegs         | ForEach-Object { $LocalAppIds[$_.AppId]  = $true }

# Constantes de référence
$MicrosoftTenantId   = "f8cdef31-a31e-4b4a-93e4-5f571e91255a"
$InactivityThreshold = (Get-Date).AddDays(-90)
$RecentThreshold     = (Get-Date).AddDays(-30)
$SensitiveRoleNames  = @(
    "Global Administrator", "Privileged Role Administrator",
    "Security Administrator", "User Administrator",
    "Exchange Administrator", "SharePoint Administrator",
    "Application Administrator", "Cloud Application Administrator"
)

Write-Host "-> Users          : $($AllUsers.Count)" -ForegroundColor Green
Write-Host "-> Groups         : $($AllGroups.Count)" -ForegroundColor Green
Write-Host "-> SKUs           : $($AllSKUs.Count)" -ForegroundColor Green
Write-Host "-> Rôle defs      : $($AllRoleDefinitions.Count)" -ForegroundColor Green
Write-Host "-> Assignations   : $($AllRoleAssignments.Count)" -ForegroundColor Green
Write-Host "-> SPs            : $($AllSPs.Count)" -ForegroundColor Green
Write-Host "-> CA Policies    : $($AllCAPolicies.Count)" -ForegroundColor Green
Write-Host "-> MFA Report     : $($MFAReport.Count) entrées (1 appel Graph total)`n" -ForegroundColor Green

# Chemin de sortie
# EN LABO / Local :
$ExportPath = "D:\Documents\ScriptsPowerShell\Exports\Reports\"
# EN PRODUCTION :
# $ExportPath = "$PSScriptRoot\Reports\"

New-Item -ItemType Directory -Force -Path $ExportPath | Out-Null
$Timestamp = Get-Date -Format "yyyyMMdd_HHmmss"

# ========================================================================================
# ÉTAPE 2 : CSV 1 — Identity-Audit
# ========================================================================================
Write-Host "2. Identity-Audit..." -ForegroundColor Cyan

$IdentityRows = @()
$MemberUsers  = $AllUsers | Where-Object { $_.UserType -eq "Member" }

foreach ($User in $MemberUsers) {

    $LastSignIn = if ($User.SignInActivity.LastSignInDateTime) {
        $User.SignInActivity.LastSignInDateTime
    } else { $null }

    # PIÈGE 1+2 : cast [DateTime] + garde-fou null (REX exo 9c)
    $Inactif = if ($LastSignIn) {
        [DateTime]$LastSignIn -lt $InactivityThreshold
    } else { $true }

    $IdentityRows += [PSCustomObject]@{
        DisplayName       = $User.DisplayName
        UPN               = $User.UserPrincipalName
        CompteActif       = $User.AccountEnabled
        Departement       = $User.Department
        JobTitle          = $User.JobTitle
        NbLicences        = $User.AssignedLicenses.Count
        SansLicence       = $User.AssignedLicenses.Count -eq 0
        DerniereConnexion = $LastSignIn
        Inactif90j        = $Inactif
        # Colonnes disponibles non exportées :
        #   $User.Id              : ObjectId
        #   $User.CreatedDateTime : date de création du compte
    }
}

$IdentityRows | Export-Csv -Path "$ExportPath\Identity-Audit.csv" -Encoding UTF8 -NoTypeInformation
Write-Host "-> Identity-Audit.csv     : $($IdentityRows.Count) membre(s)" -ForegroundColor Green

# ========================================================================================
# ÉTAPE 3 : CSV 2 — Guest-Audit
# ========================================================================================
Write-Host "3. Guest-Audit..." -ForegroundColor Cyan

$GuestRows  = @()
$GuestUsers = $AllUsers | Where-Object { $_.UserType -eq "Guest" }

foreach ($Guest in $GuestUsers) {

    $LastSignIn = if ($Guest.SignInActivity.LastSignInDateTime) {
        $Guest.SignInActivity.LastSignInDateTime
    } else { $null }

    # PIÈGE 1+2 : garde-fou null avant cast DateTime (REX exo 9c)
    $Inactif = if ($LastSignIn) {
        [DateTime]$LastSignIn -lt $InactivityThreshold
    } else { $true }

    $GuestRows += [PSCustomObject]@{
        DisplayName       = $Guest.DisplayName
        UPN               = $Guest.UserPrincipalName
        CompteActif       = $Guest.AccountEnabled
        DerniereConnexion = $LastSignIn
        JamaisConnecte    = $null -eq $LastSignIn
        Inactif90j        = $Inactif
        Alerte            = if (-not $Guest.AccountEnabled) { "DESACTIVE" }
                            elseif ($null -eq $LastSignIn)  { "JAMAIS CONNECTE" }
                            elseif ($Inactif)               { "INACTIF 90j" }
                            else                            { "" }
        # Colonnes disponibles non exportées :
        #   $Guest.Id              : ObjectId (pour Remove-MgUser après validation)
        #   $Guest.CreatedDateTime : date d'invitation
    }
}

$GuestRows | Sort-Object Alerte | Export-Csv -Path "$ExportPath\Guest-Audit.csv" -Encoding UTF8 -NoTypeInformation
Write-Host "-> Guest-Audit.csv        : $($GuestRows.Count) invité(s)" -ForegroundColor Green

# ========================================================================================
# ÉTAPE 4 : CSV 3 — Groups-Audit
# ========================================================================================
Write-Host "4. Groups-Audit..." -ForegroundColor Cyan

# Get-MgGroupOwner en boucle : pattern POC — fan-out API, acceptable en lab.
# Solution enterprise : $expand=owners dans la requête initiale ou batching Graph.
# Non implémenté — voir bloc scalabilité en en-tête.
$GroupRows = @()

foreach ($Group in $AllGroups) {

    $Owners = Get-MgGroupOwner -GroupId $Group.Id -ErrorAction SilentlyContinue
    $OwnerNames = @()
    foreach ($Owner in $Owners) {
        # Lookup hashtable O(1) — au lieu de Where-Object O(n) sur $AllUsers
        $OwnerUser = $UsersById[$Owner.Id]
        $OwnerNames += if ($OwnerUser) { $OwnerUser.DisplayName } else { $Owner.Id }
    }

    $TypeGroupe = if ($Group.GroupTypes -contains "Unified") { "M365" }
                  elseif ($Group.SecurityEnabled) { "Security" }
                  else { "Distribution" }

    $GroupRows += [PSCustomObject]@{
        DisplayName = $Group.DisplayName
        TypeGroupe  = $TypeGroupe
        Dynamique   = $Group.GroupTypes -contains "DynamicMembership"
        NbOwners    = $Owners.Count
        Owners      = if ($OwnerNames.Count -gt 0) { $OwnerNames -join " | " } else { "SANS OWNER" }
        SansOwner   = $Owners.Count -eq 0
        # Colonnes disponibles non exportées :
        #   $Group.Id              : ObjectId
        #   $Group.MembershipRule  : règle dynamique si applicable
        #   $Group.CreatedDateTime : date de création
    }
}

$GroupRows | Sort-Object SansOwner -Descending |
    Export-Csv -Path "$ExportPath\Groups-Audit.csv" -Encoding UTF8 -NoTypeInformation
Write-Host "-> Groups-Audit.csv       : $($GroupRows.Count) groupe(s)" -ForegroundColor Green

# ========================================================================================
# ÉTAPE 5 : CSV 4 — Licences-Audit
# ========================================================================================
Write-Host "5. Licences-Audit..." -ForegroundColor Cyan

$LicenceRows = @()

foreach ($SKU in $AllSKUs) {
    $Restants = $SKU.PrepaidUnits.Enabled - $SKU.ConsumedUnits
    $LicenceRows += [PSCustomObject]@{
        SKU       = $SKU.SkuPartNumber
        SkuId     = $SKU.SkuId
        Achetes   = $SKU.PrepaidUnits.Enabled
        Consommes = $SKU.ConsumedUnits
        Restants  = $Restants
        Alerte    = if ($SKU.PrepaidUnits.Enabled -gt 0 -and
                        ($Restants / $SKU.PrepaidUnits.Enabled) -lt 0.10) {
                        "CAPACITE FAIBLE"
                    } else { "" }
        # Colonnes disponibles non exportées :
        #   $SKU.CapabilityStatus       : état du SKU (Enabled, Suspended, Warning)
        #   $SKU.ServicePlans           : services inclus dans le SKU
    }
}

$LicenceRows | Export-Csv -Path "$ExportPath\Licences-Audit.csv" -Encoding UTF8 -NoTypeInformation
Write-Host "-> Licences-Audit.csv     : $($LicenceRows.Count) SKU(s)" -ForegroundColor Green

# ========================================================================================
# ÉTAPE 6 : CSV 5 — AdminRoles-Audit
# ========================================================================================
Write-Host "6. AdminRoles-Audit..." -ForegroundColor Cyan

$AdminRoleRows = @()

foreach ($Assignment in $AllRoleAssignments) {

    # Lookup hashtable O(1) — schedule et rôle depuis les index préconstruits
    $Schedule    = $SchedulesById[$Assignment.Id]
    $AssignType  = if ($Schedule) { $Schedule.AssignmentType } else { "Assigned" }
    $User        = $UsersById[$Assignment.PrincipalId]
    $RoleDef     = $RoleDefsById[$Assignment.RoleDefinitionId]
    $ScopeLabel  = if ($Assignment.DirectoryScopeId -eq "/") { "Tenant-wide" } else { "AU scopée" }

    $AdminRoleRows += [PSCustomObject]@{
        Utilisateur     = if ($User)    { $User.DisplayName }      else { $Assignment.PrincipalId }
        UPN             = if ($User)    { $User.UserPrincipalName } else { "Non résolu" }
        Role            = if ($RoleDef) { $RoleDef.DisplayName }   else { $Assignment.RoleDefinitionId }
        TypeRole        = if ($RoleDef) { if ($RoleDef.IsBuiltIn) { "Built-in" } else { "Custom" } } else { "Inconnu" }
        TypeAssignation = $AssignType
        Sensible        = if ($SensitiveRoleNames -contains $RoleDef.DisplayName) { "SENSIBLE" } else { "" }
        Perimetre       = $ScopeLabel
        # Colonnes disponibles non exportées :
        #   $Assignment.Id              : ObjectId de l'assignation
        #   $Assignment.DirectoryScopeId : GUID AU si scopée
        #   Pour PIM éligibles → $AllEligibilities (non inclus ici — voir exo 8f)
    }
}

$AdminRoleRows | Sort-Object Sensible -Descending |
    Export-Csv -Path "$ExportPath\AdminRoles-Audit.csv" -Encoding UTF8 -NoTypeInformation
Write-Host "-> AdminRoles-Audit.csv   : $($AdminRoleRows.Count) assignation(s)" -ForegroundColor Green

# ========================================================================================
# ÉTAPE 7 : CSV 6 — MFA-Audit
# ========================================================================================
Write-Host "7. MFA-Audit..." -ForegroundColor Cyan

# ENDPOINT AGRÉGÉ — remplace le loop per-user de 9a
# Get-MgReportAuthenticationMethodUserRegistration = 1 appel Graph pour tous les users
# vs Get-MgUserAuthenticationMethod = 1 appel par user (125 000 appels sur AXA)
#
# Données disponibles via cet endpoint :
#   IsMfaRegistered   : booléen — au moins une méthode MFA enregistrée
#   IsMfaCapable      : booléen — capable de satisfaire une exigence MFA
#   MethodsRegistered : liste des méthodes ("microsoftAuthenticator", "softwareOath"...)
#   IsPasswordlessCapable : capable de se connecter sans mot de passe
#
# Ce qui n'est PAS disponible (trade-off assumé) :
#   Numéro de téléphone SMS enregistré
#   Modèle de la clé FIDO2
#   Date d'enregistrement de chaque méthode
# → Pour ce niveau de détail : utiliser exo 9a (per-user, plus lent mais exhaustif)
$MFARows      = @()
$CountAvecMFA = 0
$CountSansMFA = 0

foreach ($User in $AllUsers | Where-Object { $_.UserType -eq "Member" }) {

    # Lookup hashtable O(1) dans le rapport MFA préconstruit
    $MFAEntry = $MFAByUPN[$User.UserPrincipalName]
    $AVecMFA  = if ($MFAEntry) { $MFAEntry.IsMfaRegistered } else { $false }

    if ($AVecMFA) { $CountAvecMFA++ } else { $CountSansMFA++ }

    $MFARows += [PSCustomObject]@{
        DisplayName   = $User.DisplayName
        UPN           = $User.UserPrincipalName
        CompteActif   = $User.AccountEnabled
        AvecMFA       = $AVecMFA
        MFACapable    = if ($MFAEntry) { $MFAEntry.IsMfaCapable }        else { $false }
        Passwordless  = if ($MFAEntry) { $MFAEntry.IsPasswordlessCapable } else { $false }
        Methodes      = if ($MFAEntry -and $MFAEntry.MethodsRegistered) {
                            $MFAEntry.MethodsRegistered -join ", "
                        } else { "" }
        NiveauRisque  = if ($AVecMFA) { "" }
                        elseif (-not $User.AccountEnabled) { "INFO" }
                        else { "CRITIQUE" }
        # Colonnes disponibles non exportées :
        #   $MFAEntry.Id                    : ObjectId user dans le rapport
        #   $MFAEntry.IsSystemPreferredAuthenticationMethodEnabled
        #   Pour granularité forensic (numéro SMS, modèle FIDO2...) → exo 9a
    }
}

$MFARows | Sort-Object NiveauRisque -Descending |
    Export-Csv -Path "$ExportPath\MFA-Audit.csv" -Encoding UTF8 -NoTypeInformation
Write-Host "-> MFA-Audit.csv          : $($MFARows.Count) membre(s) — 1 appel Graph total" -ForegroundColor Green

# ========================================================================================
# ÉTAPE 8 : CSV 7 — EnterpriseApps-Audit
# ========================================================================================
Write-Host "8. EnterpriseApps-Audit..." -ForegroundColor Cyan

# Get-MgServicePrincipalOwner en boucle : pattern POC — fan-out API, acceptable en lab.
# Solution enterprise : batching Graph ou $expand=owners dans la requête initiale.
# Non implémenté — voir bloc scalabilité en en-tête.
$AppRows         = @()
$NonMicrosoftSPs = $AllSPs | Where-Object {
    $_.AppOwnerOrganizationId -ne $MicrosoftTenantId
}

foreach ($SP in $NonMicrosoftSPs) {

    $Owners = Get-MgServicePrincipalOwner -ServicePrincipalId $SP.Id -ErrorAction SilentlyContinue
    $OwnerNames = @()
    foreach ($Owner in $Owners) {
        # Lookup hashtable O(1)
        $OwnerUser = $UsersById[$Owner.Id]
        $OwnerNames += if ($OwnerUser) { $OwnerUser.DisplayName } else { $Owner.Id }
    }

    $Editeur = if ($LocalAppIds[$SP.AppId]) { "Interne" } else { "Tiers" }

    # PIÈGE 1+2 : CreatedDateTime peut être null sur Managed Identities (REX exo 9c)
    $EstRecent = if ($SP.CreatedDateTime) {
        [DateTime]$SP.CreatedDateTime -gt $RecentThreshold
    } else { $false }

    $AppRows += [PSCustomObject]@{
        DisplayName = $SP.DisplayName
        AppId       = $SP.AppId
        Editeur     = $Editeur
        Actif       = $SP.AccountEnabled
        CreeLe      = $SP.CreatedDateTime
        Recent30j   = $EstRecent
        NbOwners    = $Owners.Count
        Owners      = if ($OwnerNames.Count -gt 0) { $OwnerNames -join " | " } else { "SANS OWNER" }
        SansOwner   = $Owners.Count -eq 0
        # Colonnes disponibles non exportées :
        #   $SP.Id                  : ObjectId (pour permissions, révocation)
        #   $SP.ServicePrincipalType : Application, ManagedIdentity, Legacy
        #   Pour permissions élevées → exo 9b étape 5
    }
}

$AppRows | Sort-Object SansOwner -Descending, Editeur |
    Export-Csv -Path "$ExportPath\EnterpriseApps-Audit.csv" -Encoding UTF8 -NoTypeInformation
Write-Host "-> EnterpriseApps-Audit.csv : $($AppRows.Count) app(s) hors Microsoft" -ForegroundColor Green

# ========================================================================================
# ÉTAPE 9 : CSV 8 — ConditionalAccess-Audit
# ========================================================================================
Write-Host "9. ConditionalAccess-Audit..." -ForegroundColor Cyan

$CARows = @()

foreach ($Policy in $AllCAPolicies) {

    $GrantControls = if ($Policy.GrantControls.BuiltInControls) {
        $Policy.GrantControls.BuiltInControls -join ", "
    } elseif ($Policy.GrantControls.CustomAuthenticationFactors) {
        "Custom: $($Policy.GrantControls.CustomAuthenticationFactors -join ', ')"
    } else { "Block ou aucun" }

    $CARows += [PSCustomObject]@{
        DisplayName   = $Policy.DisplayName
        Etat          = $Policy.State
        # États possibles :
        #   "enabled"                          → politique active et appliquée
        #   "enabledForReportingButNotEnforced" → Report-Only (audit sans blocage)
        #   "disabled"                          → désactivée
        GrantControls = $GrantControls
        UsersIncluded = if ($Policy.Conditions.Users.IncludeUsers) {
                            $Policy.Conditions.Users.IncludeUsers -join ", "
                        } else { "" }
        AppsIncluded  = if ($Policy.Conditions.Applications.IncludeApplications) {
                            $Policy.Conditions.Applications.IncludeApplications -join ", "
                        } else { "" }
        CreeLe        = $Policy.CreatedDateTime
        ModifieLe     = $Policy.ModifiedDateTime
        # Colonnes disponibles non exportées :
        #   $Policy.Id                              : ObjectId de la politique
        #   $Policy.Conditions.Users.ExcludeGroups  : groupes exclus (break glass)
        #   $Policy.SessionControls                 : contrôles de session
    }
}

$CARows | Sort-Object Etat |
    Export-Csv -Path "$ExportPath\ConditionalAccess-Audit.csv" -Encoding UTF8 -NoTypeInformation
Write-Host "-> ConditionalAccess-Audit.csv : $($CARows.Count) politique(s) CA`n" -ForegroundColor Green

# ========================================================================================
# ÉTAPE 10 : Summary.txt
# ========================================================================================
Write-Host "10. Génération du Summary.txt..." -ForegroundColor Cyan

$NbMembers          = ($AllUsers | Where-Object { $_.UserType -eq "Member" }).Count
$NbGuests           = ($AllUsers | Where-Object { $_.UserType -eq "Guest" }).Count
$NbGuestsInactifs   = ($GuestRows | Where-Object { $_.Inactif90j -eq $true }).Count
$NbSansLicence      = ($AllUsers | Where-Object { $_.AssignedLicenses.Count -eq 0 }).Count
$NbGroupesSansOwner = ($GroupRows | Where-Object { $_.SansOwner -eq $true }).Count
$NbRolesSensibles   = ($AdminRoleRows | Where-Object { $_.Sensible -eq "SENSIBLE" }).Count
$NbSansMFACritique  = ($MFARows | Where-Object { $_.NiveauRisque -eq "CRITIQUE" }).Count
$TauxMFA            = if ($MFARows.Count -gt 0) {
    [math]::Round(($CountAvecMFA / $MFARows.Count) * 100, 1)
} else { 0 }
$NbAppsSansOwner    = ($AppRows | Where-Object { $_.SansOwner -eq $true }).Count
$NbAppsRecentes     = ($AppRows | Where-Object { $_.Recent30j -eq $true }).Count
$NbCAActive         = ($CARows | Where-Object { $_.Etat -eq "enabled" }).Count
$NbCAReportOnly     = ($CARows | Where-Object { $_.Etat -eq "enabledForReportingButNotEnforced" }).Count
$NbCADisabled       = ($CARows | Where-Object { $_.Etat -eq "disabled" }).Count
$NbPIMEligibles     = $AllEligibilities.Count
$NbCustomRoles      = ($AllRoleDefinitions | Where-Object { $_.IsBuiltIn -eq $false }).Count

$SummaryContent = @"
================================================================================
TENANT SECURITY SNAPSHOT — $($Timestamp.Substring(0,8)) — Tenant : $((Get-MgContext).TenantId)
Généré par : $((Get-MgContext).Account)
================================================================================

--- IDENTITÉS ---
Utilisateurs membres (actifs + désactivés) : $NbMembers
Utilisateurs invités (guests)              : $NbGuests
  Dont invités inactifs depuis 90j         : $NbGuestsInactifs
Utilisateurs sans licence                  : $NbSansLicence

--- GROUPES ---
Total groupes                              : $($AllGroups.Count)
Groupes sans owner                         : $NbGroupesSansOwner

--- LICENCES ---
SKUs actifs dans le tenant                 : $($AllSKUs.Count)
$(($LicenceRows | ForEach-Object { "  $($_.SKU) : $($_.Consommes)/$($_.Achetes) sièges$( if ($_.Alerte) { ' ← ' + $_.Alerte } else { '' })" }) -join "`n")

--- RBAC / RÔLES ---
Total assignations actives                 : $($AdminRoleRows.Count)
  Dont rôles sensibles                     : $NbRolesSensibles
Éligibilités PIM (non activées)            : $NbPIMEligibles
Rôles custom créés                         : $NbCustomRoles

--- MFA ---
Taux de couverture MFA (membres)           : $TauxMFA %
Membres avec MFA                           : $CountAvecMFA / $($MFARows.Count)
Membres sans MFA (niveau CRITIQUE)         : $NbSansMFACritique
Source : endpoint agrégé /reports/authenticationMethods/userRegistrationDetails

--- ENTERPRISE APPS ---
Apps hors Microsoft (tierces + internes)   : $($AppRows.Count)
  Dont sans owner                          : $NbAppsSansOwner
  Dont créées dans les 30 derniers jours   : $NbAppsRecentes

--- CONDITIONAL ACCESS ---
Politiques CA actives (enabled)            : $NbCAActive
Politiques CA Report-Only                  : $NbCAReportOnly
Politiques CA désactivées                  : $NbCADisabled

--- SIGNAUX D'ALERTE ---
$(if ($NbSansMFACritique -gt 0)  { "⚠  $NbSansMFACritique membre(s) actif(s) sans MFA — risque critique" })
$(if ($NbRolesSensibles -gt 0)   { "⚠  $NbRolesSensibles assignation(s) sur rôles sensibles — vérifier si PIM éligible" })
$(if ($NbGuestsInactifs -gt 0)   { "⚠  $NbGuestsInactifs invité(s) inactif(s) depuis 90j — candidats à révocation" })
$(if ($NbGroupesSansOwner -gt 0) { "⚠  $NbGroupesSansOwner groupe(s) sans owner — dette de gouvernance" })
$(if ($NbAppsSansOwner -gt 0)    { "⚠  $NbAppsSansOwner app(s) sans owner — dette de gouvernance" })
$(if ($NbAppsRecentes -gt 0)     { "⚠  $NbAppsRecentes app(s) créée(s) dans les 30 derniers jours — valider avec sécurité" })
$(if ($NbCADisabled -gt 0)       { "⚠  $NbCADisabled politique(s) CA désactivée(s) — vérifier si intentionnel" })
$(if ($NbSansMFACritique -eq 0 -and $NbRolesSensibles -eq 0 -and $NbGuestsInactifs -eq 0 -and
      $NbGroupesSansOwner -eq 0 -and $NbAppsSansOwner -eq 0 -and $NbCADisabled -eq 0) {
    "✓  Aucun signal d'alerte majeur détecté — posture saine"
})

--- FICHIERS GÉNÉRÉS ---
  Identity-Audit.csv           ($($IdentityRows.Count) lignes)
  Guest-Audit.csv              ($($GuestRows.Count) lignes)
  Groups-Audit.csv             ($($GroupRows.Count) lignes)
  Licences-Audit.csv           ($($LicenceRows.Count) lignes)
  AdminRoles-Audit.csv         ($($AdminRoleRows.Count) lignes)
  MFA-Audit.csv                ($($MFARows.Count) lignes)
  EnterpriseApps-Audit.csv     ($($AppRows.Count) lignes)
  ConditionalAccess-Audit.csv  ($($CARows.Count) lignes)

--- NOTE ---
Ce snapshot est un point d'entrée — il couvre les signaux principaux.
Pour l'audit exhaustif de chaque domaine, utiliser les scripts dédiés :
  Identités       → exo 1j / 1k / 1l / 1m
  Groupes         → exo 3d / 3e
  RBAC complet    → exo 8f (9 CSV dont PIM éligibles, groupes, SPs, break glass)
  MFA détaillé    → exo 9a (per-user, granularité forensic par méthode)
  Apps détaillées → exo 9b / 9c (permissions élevées, secrets expirants)
  CA détaillé     → exo 5a
================================================================================
"@

$SummaryContent | Out-File -FilePath "$ExportPath\Summary.txt" -Encoding UTF8
Write-Host "-> Summary.txt généré.`n" -ForegroundColor Green

# ========================================================================================
# ÉTAPE 11 : Résumé console
# ========================================================================================
Write-Host "=== TENANT SECURITY SNAPSHOT — TERMINÉ ===" -ForegroundColor Magenta
Write-Host ""
Write-Host "Fichiers générés dans : $ExportPath" -ForegroundColor Green
Write-Host ""
Write-Host "--- Chiffres clés ---" -ForegroundColor Cyan
Write-Host "  Membres          : $NbMembers | Invités : $NbGuests (dont $NbGuestsInactifs inactifs)" -ForegroundColor White
Write-Host "  MFA              : $TauxMFA % de couverture | $NbSansMFACritique sans MFA CRITIQUE" -ForegroundColor $(if ($NbSansMFACritique -gt 0) { "Red" } else { "Green" })
Write-Host "  Rôles sensibles  : $NbRolesSensibles assignation(s)" -ForegroundColor $(if ($NbRolesSensibles -gt 0) { "Yellow" } else { "Green" })
Write-Host "  Apps sans owner  : $NbAppsSansOwner" -ForegroundColor $(if ($NbAppsSansOwner -gt 0) { "Yellow" } else { "Green" })
Write-Host "  CA actives       : $NbCAActive | Report-Only : $NbCAReportOnly | Désactivées : $NbCADisabled" -ForegroundColor White

# ========================================================================================
# NETTOYAGE MÉMOIRE
# ========================================================================================
Remove-Variable Scopes, AllUsers, AllGroups, AllSKUs, AllRoleDefinitions,
                AllRoleAssignments, AllRoleSchedules, AllEligibilities,
                AllSPs, AllAppRegs, AllCAPolicies, MFAReport,
                UsersById, GroupsById, RoleDefsById, SchedulesById, MFAByUPN, LocalAppIds,
                MicrosoftTenantId, InactivityThreshold, RecentThreshold, SensitiveRoleNames,
                ExportPath, Timestamp, NonMicrosoftSPs,
                IdentityRows, GuestRows, GroupRows, LicenceRows, AdminRoleRows,
                MFARows, AppRows, CARows, SummaryContent,
                MemberUsers, GuestUsers, User, Guest, Group, SKU, Assignment,
                Schedule, RoleDef, SP, Policy, Owner, OwnerUser,
                Owners, OwnerNames, MFAEntry,
                LastSignIn, Inactif, EstRecent, AVecMFA, AssignType,
                ScopeLabel, GrantControls, Editeur, Restants,
                NbMembers, NbGuests, NbGuestsInactifs, NbSansLicence,
                NbGroupesSansOwner, NbRolesSensibles, NbSansMFACritique,
                TauxMFA, NbAppsSansOwner, NbAppsRecentes,
                NbCAActive, NbCAReportOnly, NbCADisabled,
                NbPIMEligibles, NbCustomRoles, CountAvecMFA, CountSansMFA `
                -ErrorAction SilentlyContinue

# ========================================================================================
# FERMETURE — RESET DE SESSION TOTAL
# ========================================================================================
Disconnect-MgGraph -ErrorAction SilentlyContinue
Write-Host "`nSession MgGraph fermée proprement." -ForegroundColor Magenta
