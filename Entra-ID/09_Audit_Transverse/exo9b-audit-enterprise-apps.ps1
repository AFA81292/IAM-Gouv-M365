# ========================================================================================
# Exercice 9b : Entra ID — Audit transverse — Audit des Enterprise Applications
# ========================================================================================
# Concept : Les Enterprise Applications (Service Principals) sont le vecteur d'attaque
# le plus sous-audité des tenants M365. Un tenant de prod accumule des centaines d'apps
# consenties par des utilisateurs, parfois avec des permissions excessives, sans owner,
# sans utilisation récente. Chaque app inutilisée avec des permissions élevées est
# une surface d'attaque dormante.
#
# Ce script produit quatre angles d'analyse :
#   A) Inventaire global : toutes les apps, Microsoft vs tierces, actives vs inactives
#   B) Apps récemment créées : nouveautés des 30 derniers jours (shadow IT, supply chain)
#   C) Apps sans owner : gouvernance défaillante, personne responsable en cas d'incident
#   D) Apps avec permissions élevées : AppRoles Graph sensibles consenties au niveau tenant
#
# Ce que fait ce script :
#   1. Reset total de session
#   2. Chargement en cache de tous les Service Principals et App Registrations
#   3. Inventaire global avec classification Microsoft / Tiers / Interne
#   4. Détection des apps récemment créées
#   5. Détection des apps sans owner
#   6. Détection des apps avec permissions Graph élevées (application permissions)
#   7. Résumé chiffré
#   8. Export CSV horodatés (4 fichiers)
#   9. Fermeture propre
#
# Note : ce script est en lecture seule — aucune modification du tenant.
#
# DÉCOUVERTE TECHNIQUE : distinction Service Principal vs App Registration
#   App Registration (Get-MgApplication)  : l'identité de l'app dans le tenant home
#   Service Principal (Get-MgServicePrincipal) : la projection de l'app dans UN tenant
#   Une app Microsoft a un SP dans chaque tenant client — sans App Registration locale.
#   Une app interne a les deux : une App Registration + un SP dans le même tenant.
#   Ce script audite les Service Principals (vue tenant) + croise avec les App Registrations
#   pour identifier les apps internes vs les apps externes consenties.
#
# Fichiers CSV générés :
#   Apps_Inventaire_YYYYMMDD_HHmmss.csv    (toutes les apps classifiées)
#   Apps_Recentes_YYYYMMDD_HHmmss.csv      (créées dans les 30 derniers jours)
#   Apps_SansOwner_YYYYMMDD_HHmmss.csv     (apps sans propriétaire)
#   Apps_Permissions_YYYYMMDD_HHmmss.csv   (apps avec permissions élevées)
#
# Delta pédagogique vs exo 9c (audit apps sans owner) :
#   9b → inventaire global + 4 angles dont sans owner en passant
#   9c → focus gouvernance : sans owner, multi-owners, inactivité — granularité maximale
#
# Module requis : Microsoft.Graph.Applications
# Connexion     : Connect-MgGraph
# ========================================================================================

# --- OUVERTURE — RESET DE SESSION TOTAL ---
# Application.Read.All : lire les Service Principals, App Registrations et permissions
#
# Pas de -ContextScope Process requis : lecture seule, aucun scope d'écriture.
$Scopes = @(
    "Application.Read.All"
)

Disconnect-MgGraph -ErrorAction SilentlyContinue
Connect-MgGraph -Scopes $Scopes -NoWelcome

# ========================================================================================
# ÉTAPE 1 : Chargement en cache
# ========================================================================================
Write-Host "1. Chargement des données sources en cache..." -ForegroundColor Cyan

# Service Principals : toutes les apps présentes dans le tenant (Microsoft + tierces + internes)
$AllSPs = Get-MgServicePrincipal -All `
    -Property "Id,DisplayName,AppId,AppOwnerOrganizationId,CreatedDateTime,AccountEnabled,ServicePrincipalType,Tags"

# App Registrations : uniquement les apps enregistrées localement dans ce tenant
# Leur AppId croise avec celui des SPs pour identifier les apps "internes"
$AllAppRegs = Get-MgApplication -All `
    -Property "Id,DisplayName,AppId,CreatedDateTime,SignInAudience"

# GUID Microsoft connu — tous les SPs dont AppOwnerOrganizationId == ce GUID sont des apps Microsoft
$MicrosoftTenantId = "f8cdef31-a31e-4b4a-93e4-5f571e91255a"

# AppIds des apps enregistrées localement — pour croiser avec les SPs
$LocalAppIds = $AllAppRegs | Select-Object -ExpandProperty AppId

Write-Host "-> Service Principals   : $($AllSPs.Count)" -ForegroundColor Green
Write-Host "-> App Registrations    : $($AllAppRegs.Count)" -ForegroundColor Green

# Permissions Graph sensibles à surveiller — application permissions (pas delegated)
# Ces permissions donnent un accès tenant-wide sans utilisateur connecté
$SensitiveAppRoles = @(
    "User.ReadWrite.All",
    "Directory.ReadWrite.All",
    "RoleManagement.ReadWrite.Directory",
    "Mail.ReadWrite",
    "Mail.Send",
    "Files.ReadWrite.All",
    "Sites.FullControl.All",
    "Group.ReadWrite.All",
    "Application.ReadWrite.All",
    "Policy.ReadWrite.ConditionalAccess"
)

Write-Host "-> $($SensitiveAppRoles.Count) permissions sensibles surveillées.`n" -ForegroundColor Green

# ========================================================================================
# ÉTAPE 2 : Inventaire global — classification des apps
# ========================================================================================
Write-Host "2. Inventaire global des applications..." -ForegroundColor Cyan

# Seuil d'inactivité — apps créées avant cette date sans connexion récente
# Non utilisé directement ici (nécessite SignInActivity sur SP — scope distinct)
# mais documenté pour extension en mission
# $InactivityThreshold = (Get-Date).AddDays(-90)

$InventaireRows = @()
$RecentThreshold = (Get-Date).AddDays(-30)

foreach ($SP in $AllSPs) {

    # Classification éditeur :
    #   Microsoft  → AppOwnerOrganizationId == GUID Microsoft
    #   Interne    → AppId présent dans les App Registrations locales
    #   Tiers      → ni Microsoft ni enregistré localement (app externe consentie)
    $Editeur = if ($SP.AppOwnerOrganizationId -eq $MicrosoftTenantId) { "Microsoft" }
               elseif ($LocalAppIds -contains $SP.AppId) { "Interne" }
               else { "Tiers" }

    # Type de SP :
    #   Application → app standard avec AppId
    #   ManagedIdentity → identité managée Azure (VM, Function App...)
    #   Legacy → app héritée (pré-Entra)
    $InventaireRows += [PSCustomObject]@{
        DisplayName              = $SP.DisplayName
        AppId                    = $SP.AppId
        Editeur                  = $Editeur
        TypeSP                   = $SP.ServicePrincipalType
        Actif                    = $SP.AccountEnabled
        CreeLe                   = $SP.CreatedDateTime
        Recent                   = [DateTime]$SP.CreatedDateTime -gt $RecentThreshold
        # Colonnes disponibles non exportées :
        #   $SP.Id                        : ObjectId du SP (pour Get-MgServicePrincipalOwner)
        #   $SP.AppOwnerOrganizationId    : GUID tenant éditeur
        #   $SP.Tags                      : tags Entra (ex : "WindowsAzureActiveDirectoryIntegratedApp")
        #   $SP.Homepage                  : URL homepage de l'app
        #   $SP.ReplyUrls                 : redirect URIs enregistrées
        #   $SP.SignInActivity             : nécessite AuditLog.Read.All en plus
    }
}

$NbMicrosoft = ($InventaireRows | Where-Object { $_.Editeur -eq "Microsoft" }).Count
$NbInterne   = ($InventaireRows | Where-Object { $_.Editeur -eq "Interne" }).Count
$NbTiers     = ($InventaireRows | Where-Object { $_.Editeur -eq "Tiers" }).Count

Write-Host "-> $($InventaireRows.Count) app(s) : $NbMicrosoft Microsoft | $NbInterne Interne(s) | $NbTiers Tiers.`n" -ForegroundColor Green

# ========================================================================================
# ÉTAPE 3 : Apps récemment créées (30 derniers jours)
# ========================================================================================
Write-Host "3. Détection des apps récemment créées..." -ForegroundColor Cyan

# Les apps créées récemment méritent une attention particulière :
#   → Shadow IT : un utilisateur a consenti une app tierce sans validation IT
#   → Supply chain attack : une app compromise injectée dans le tenant
#   → Onboarding légitime : nouvelle intégration à documenter et governer
# En mission : livrable hebdomadaire à valider avec l'équipe sécurité.
$RecentRows = $InventaireRows | Where-Object { $_.Recent -eq $true } |
    Sort-Object CreeLe -Descending

Write-Host "-> $($RecentRows.Count) app(s) créée(s) dans les 30 derniers jours.`n" -ForegroundColor $(
    if ($RecentRows.Count -gt 0) { "Yellow" } else { "Green" }
)

if ($RecentRows.Count -gt 0) {
    $RecentRows | Select-Object DisplayName, Editeur, TypeSP, CreeLe | Format-Table -AutoSize
}

# ========================================================================================
# ÉTAPE 4 : Apps sans owner
# ========================================================================================
Write-Host "4. Détection des apps sans owner..." -ForegroundColor Cyan

# Un owner d'app est responsable de sa maintenance, de ses permissions et de son cycle de vie.
# Sans owner : personne à contacter en cas d'incident, de compromission ou de décommission.
# En mission : tout app tierce ou interne sans owner est un risque de gouvernance.
# Note : les apps Microsoft n'ont pas d'owner par design — on les exclut du calcul.
$NoOwnerRows = @()

$NonMicrosoftSPs = $AllSPs | Where-Object {
    $_.AppOwnerOrganizationId -ne $MicrosoftTenantId
}

foreach ($SP in $NonMicrosoftSPs) {
    $Owners = Get-MgServicePrincipalOwner -ServicePrincipalId $SP.Id -ErrorAction SilentlyContinue

    if ($Owners.Count -eq 0) {
        $Editeur = if ($LocalAppIds -contains $SP.AppId) { "Interne" } else { "Tiers" }

        $NoOwnerRows += [PSCustomObject]@{
            DisplayName  = $SP.DisplayName
            AppId        = $SP.AppId
            Editeur      = $Editeur
            TypeSP       = $SP.ServicePrincipalType
            Actif        = $SP.AccountEnabled
            CreeLe       = $SP.CreatedDateTime
            # Colonnes disponibles non exportées :
            #   $SP.Id       : ObjectId pour New-MgServicePrincipalOwnerByRef (assignation owner)
            #   $SP.Tags     : tags Entra
            #   $SP.Homepage : URL pour identification manuelle
        }
    }
}

Write-Host "-> $($NoOwnerRows.Count) app(s) sans owner (hors Microsoft).`n" -ForegroundColor $(
    if ($NoOwnerRows.Count -gt 0) { "Yellow" } else { "Green" }
)

# ========================================================================================
# ÉTAPE 5 : Apps avec permissions Graph élevées (application permissions)
# ========================================================================================
Write-Host "5. Détection des apps avec permissions élevées..." -ForegroundColor Cyan

# DÉCOUVERTE TECHNIQUE : deux types de permissions Graph à distinguer :
#   Delegated permissions  : l'app agit au nom d'un utilisateur connecté
#                            → portée limitée aux droits de l'utilisateur
#   Application permissions: l'app agit en son propre nom, sans utilisateur
#                            → accès tenant-wide, indépendant de tout utilisateur
#                            → c'est ce qu'on surveille ici (AppRoleAssignments)
#
# Get-MgServicePrincipalAppRoleAssignment retourne les application permissions
# consenties au niveau tenant pour un SP donné.
# Chaque AppRoleAssignment pointe vers un ResourceId (ex : Graph) et un AppRoleId (GUID).
# On résout le GUID en nom lisible via le SP de la ressource (Microsoft Graph SP).
#
# LIMITE DE SCALABILITÉ — fan-out inévitable sur cet endpoint :
#   Il n'existe pas d'endpoint Graph agrégé pour les AppRoleAssignments de tous les SPs.
#   La seule approche disponible est 1 appel par SP — contrairement au MFA (exo 9a/9d)
#   où un endpoint /reports/ permet un appel unique.
#   Sur 227 SPs (tenant de dev) : rapide. Sur 2 000 SPs (tenant de prod) : notable.
#   Solution enterprise : batching Graph ($batch, 20 appels groupés) ou
#   Microsoft Graph Data Connect pour export massif hors bande.
#   Non implémenté ici — voir bloc scalabilité dans l'en-tête de exo 9d.
$PermissionRows = @()

# Récupération du SP Microsoft Graph pour résoudre les AppRoleIds en noms lisibles
# AppId Microsoft Graph connu et stable : 00000003-0000-0000-c000-000000000000
$GraphSP = $AllSPs | Where-Object { $_.AppId -eq "00000003-0000-0000-c000-000000000000" } |
    Select-Object -First 1

foreach ($SP in $AllSPs) {
    $AppRoleAssignments = Get-MgServicePrincipalAppRoleAssignment `
        -ServicePrincipalId $SP.Id -ErrorAction SilentlyContinue

    if (-not $AppRoleAssignments) { continue }

    foreach ($Assignment in $AppRoleAssignments) {
        # Résolution du nom de la permission depuis le SP de la ressource
        $PermissionName = "Non résolu"
        if ($GraphSP -and $Assignment.ResourceId -eq $GraphSP.Id) {
            $AppRole = $GraphSP.AppRoles | Where-Object { $_.Id -eq $Assignment.AppRoleId } |
                Select-Object -First 1
            if ($AppRole) { $PermissionName = $AppRole.Value }
        }

        # On ne retient que les permissions dans la liste des sensibles
        if ($SensitiveAppRoles -notcontains $PermissionName) { continue }

        $Editeur = if ($SP.AppOwnerOrganizationId -eq $MicrosoftTenantId) { "Microsoft" }
                   elseif ($LocalAppIds -contains $SP.AppId) { "Interne" }
                   else { "Tiers" }

        $PermissionRows += [PSCustomObject]@{
            AppDisplayName   = $SP.DisplayName
            AppId            = $SP.AppId
            Editeur          = $Editeur
            Permission       = $PermissionName
            ConsenteLe       = $Assignment.CreatedDateTime
            ResourceId       = $Assignment.ResourceId
            # Colonnes disponibles non exportées :
            #   $SP.Id                  : ObjectId SP (pour révocation)
            #   $Assignment.Id          : ID de l'AppRoleAssignment (pour Remove-MgServicePrincipalAppRoleAssignment)
            #   $Assignment.PrincipalId : GUID du SP bénéficiaire
            #   Pour voir TOUTES les permissions (pas seulement les sensibles) :
            #     supprimer le filtre $SensitiveAppRoles -notcontains $PermissionName
        }
    }
}

Write-Host "-> $($PermissionRows.Count) permission(s) élevée(s) détectée(s) sur $($PermissionRows | Select-Object -ExpandProperty AppDisplayName -Unique | Measure-Object | Select-Object -ExpandProperty Count) app(s).`n" -ForegroundColor $(
    if (($PermissionRows | Where-Object { $_.Editeur -eq "Tiers" }).Count -gt 0) { "Red" }
    elseif ($PermissionRows.Count -gt 0) { "Yellow" }
    else { "Green" }
)

if ($PermissionRows.Count -gt 0) {
    $PermissionRows | Sort-Object Editeur, AppDisplayName |
        Select-Object AppDisplayName, Editeur, Permission, ConsenteLe |
        Format-Table -AutoSize
}

# ========================================================================================
# ÉTAPE 6 : Résumé chiffré
# ========================================================================================
Write-Host "`n=== RÉSUMÉ ===" -ForegroundColor Magenta
[PSCustomObject]@{
    TotalApps               = $AllSPs.Count
    AppsMicrosoft           = $NbMicrosoft
    AppsInternes            = $NbInterne
    AppsTiers               = $NbTiers
    AppsRecentes30j         = $RecentRows.Count
    AppsSansOwner           = $NoOwnerRows.Count
    AppsAvecPermElevees     = ($PermissionRows | Select-Object -ExpandProperty AppDisplayName -Unique | Measure-Object).Count
    PermissionsEleveesTotal = $PermissionRows.Count
    "Dont Tiers sensibles"  = ($PermissionRows | Where-Object { $_.Editeur -eq "Tiers" }).Count
    Scope                   = "Application.Read.All (lecture seule)"
    PointAttentionAudit     = "Prioriser : Tiers + permission élevée + sans owner = risque maximal"
} | Format-List

# ========================================================================================
# EXPORT CSV
# ========================================================================================
Write-Host "Export CSV en cours..." -ForegroundColor Cyan

# EN LABO / Local :
$ExportPath = "D:\Documents\ScriptsPowerShell\Exports\"
# EN PRODUCTION :
# $ExportPath = "$PSScriptRoot\Exports\"

New-Item -ItemType Directory -Force -Path $ExportPath | Out-Null
$Timestamp = Get-Date -Format "yyyyMMdd_HHmmss"

# --- CSV 1 : Inventaire global ---
# Colonnes : DisplayName, AppId, Editeur, TypeSP, Actif, CreeLe, Recent
# Colonnes disponibles non exportées : Id, AppOwnerOrganizationId, Tags, Homepage, ReplyUrls
# Vue exhaustive de toutes les apps du tenant.
# Dans Excel : filtrer Editeur = "Tiers" pour isoler les apps externes,
# puis Recent = TRUE pour prioriser les nouveautés à valider.
$InventaireRows | Sort-Object Editeur, DisplayName | Export-Csv `
    -Path "$ExportPath\Apps_Inventaire_$Timestamp.csv" `
    -Encoding UTF8 -NoTypeInformation
Write-Host "-> Inventaire  : $($InventaireRows.Count) ligne(s) — Apps_Inventaire_$Timestamp.csv" -ForegroundColor Green

# --- CSV 2 : Apps récentes ---
# Colonnes : DisplayName, AppId, Editeur, TypeSP, Actif, CreeLe, Recent
# Sous-ensemble du CSV 1 — apps créées dans les 30 derniers jours, triées par date DESC.
# Livrable hebdomadaire pour validation sécurité : toute app tierce récente non documentée
# est un candidat à la révocation (Remove-MgServicePrincipal) après validation métier.
if ($RecentRows.Count -gt 0) {
    $RecentRows | Export-Csv `
        -Path "$ExportPath\Apps_Recentes_$Timestamp.csv" `
        -Encoding UTF8 -NoTypeInformation
    Write-Host "-> Récentes    : $($RecentRows.Count) ligne(s) — Apps_Recentes_$Timestamp.csv" -ForegroundColor Green
} else {
    Write-Host "-> Récentes    : aucune app créée dans les 30 derniers jours." -ForegroundColor Yellow
}

# --- CSV 3 : Apps sans owner ---
# Colonnes : DisplayName, AppId, Editeur, TypeSP, Actif, CreeLe
# Colonnes disponibles non exportées : Id (pour New-MgServicePrincipalOwnerByRef)
# Hors apps Microsoft (pas d'owner par design).
# Action corrective : assigner un owner via New-MgServicePrincipalOwnerByRef
# ou via Entra Admin Center > Enterprise Applications > {app} > Owners.
if ($NoOwnerRows.Count -gt 0) {
    $NoOwnerRows | Sort-Object Editeur, DisplayName | Export-Csv `
        -Path "$ExportPath\Apps_SansOwner_$Timestamp.csv" `
        -Encoding UTF8 -NoTypeInformation
    Write-Host "-> Sans owner  : $($NoOwnerRows.Count) ligne(s) — Apps_SansOwner_$Timestamp.csv" -ForegroundColor Green
} else {
    Write-Host "-> Sans owner  : toutes les apps non-Microsoft ont un owner." -ForegroundColor Green
}

# --- CSV 4 : Apps avec permissions élevées ---
# Colonnes : AppDisplayName, AppId, Editeur, Permission, ConsenteLe, ResourceId
# Colonnes disponibles non exportées : SP.Id, Assignment.Id (pour révocation)
# Uniquement les application permissions (tenant-wide, sans utilisateur) dans la liste sensible.
# Prioriser : Tiers + permission élevée = risque maximal → investiguer et potentiellement révoquer.
# Pour voir TOUTES les permissions (pas seulement sensibles) : voir commentaire étape 5.
# Action corrective : Remove-MgServicePrincipalAppRoleAssignment -ServicePrincipalId -AppRoleAssignmentId
if ($PermissionRows.Count -gt 0) {
    $PermissionRows | Sort-Object Editeur, AppDisplayName | Export-Csv `
        -Path "$ExportPath\Apps_Permissions_$Timestamp.csv" `
        -Encoding UTF8 -NoTypeInformation
    Write-Host "-> Permissions : $($PermissionRows.Count) ligne(s) — Apps_Permissions_$Timestamp.csv" -ForegroundColor Green
} else {
    Write-Host "-> Permissions : aucune permission élevée détectée." -ForegroundColor Green
}

Write-Host "-> Export terminé dans : $ExportPath`n" -ForegroundColor Green

# ========================================================================================
# NETTOYAGE MÉMOIRE
# ========================================================================================
Remove-Variable Scopes, AllSPs, AllAppRegs, MicrosoftTenantId, LocalAppIds,
                SensitiveAppRoles, InventaireRows, RecentRows, NoOwnerRows,
                PermissionRows, RecentThreshold, NonMicrosoftSPs, GraphSP,
                NbMicrosoft, NbInterne, NbTiers, SP, Owners, Editeur,
                AppRoleAssignments, Assignment, AppRole, PermissionName,
                ExportPath, Timestamp `
                -ErrorAction SilentlyContinue

# ========================================================================================
# FERMETURE — RESET DE SESSION TOTAL
# ========================================================================================
Disconnect-MgGraph -ErrorAction SilentlyContinue
Write-Host "Session MgGraph fermée proprement." -ForegroundColor Magenta
