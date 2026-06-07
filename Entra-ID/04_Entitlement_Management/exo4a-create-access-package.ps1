# ========================================================================================
# Exercice 4a : Entitlement Management — Création d'un Access Package complet
# ========================================================================================
# Scénario : Un consultant arrive en mission. Au lieu de créer les accès un par un,
# l'IT a préparé un Access Package "Admin-SP-Mission-Run" qui regroupe tous les droits
# nécessaires. Le manager approuve en un clic, les droits sont assignés automatiquement.
# A l'expiration — révocation automatique, zéro oubli.
#
# Structure Entitlement Management :
#   Catalog        = conteneur logique qui regroupe les ressources et les packages
#   Access Package = ensemble de droits demandables par un utilisateur
#   Resource       = ce qu'on met dans le package (groupe, app, rôle SP)
#   Policy         = qui peut demander, qui approuve, durée, expiration
# ========================================================================================

# --- ÉTAPE 1 : Connexion à Microsoft Graph ---
# EntitlementManagement.ReadWrite.All : créer/modifier catalogs et access packages
# Group.ReadWrite.All : ajouter un groupe comme ressource dans le catalog
# User.Read.All : récupérer l'ID de l'approbateur
$Scopes = @(
    "EntitlementManagement.ReadWrite.All",
    "Group.ReadWrite.All",
    "User.Read.All"
)
Connect-MgGraph -Scopes $Scopes

# --- ÉTAPE 2 : Définition des variables ---
$CatalogName     = "Outils-IT-M365"
$CatalogDesc     = "Catalog des ressources IT pour les missions de support M365."
$PackageName     = "Admin-SP-Mission-Run"
$PackageDesc     = "Pack d'accès complet pour les missions de run SharePoint."
$ResourceGroup   = "Witchers-Brotherhood"
$ApproverUPN     = "geralt@0n4mg.onmicrosoft.com"

# --- ÉTAPE 3 : Création du Catalog ---
# Le Catalog est le conteneur — il doit exister avant l'Access Package
# IsExternallyVisible $false = le catalog n'est pas visible par les utilisateurs externes
Write-Host "1. Création du Catalog '$CatalogName'..." -ForegroundColor Cyan

$CatalogParams = @{
    DisplayName          = $CatalogName
    Description          = $CatalogDesc
    IsExternallyVisible  = $false
}

$NewCatalog = New-MgEntitlementManagementCatalog -BodyParameter $CatalogParams

if (-not $NewCatalog) { Write-Error "Échec de la création du Catalog." ; return }

Write-Host "-> Succès : Catalog créé avec l'ID : $($NewCatalog.Id)`n" -ForegroundColor Green

# --- ÉTAPE 4 : Ajout du groupe comme ressource dans le Catalog ---
# Une ressource doit être ajoutée au Catalog avant de pouvoir être mise dans un package
# originSystem "AadGroup" = groupe Entra ID (vs "AadApplication" pour les apps)
Write-Host "2. Ajout du groupe '$ResourceGroup' comme ressource dans le Catalog..." -ForegroundColor Cyan

$Group = Get-MgGroup -Filter "displayName eq '$ResourceGroup'" -ErrorAction Stop

if (-not $Group) { Write-Error "Groupe '$ResourceGroup' introuvable." ; return }

$ResourceParams = @{
    CatalogId = $NewCatalog.Id
    RequestType = "adminAdd"
    Resource = @{
        OriginId     = $Group.Id
        OriginSystem = "AadGroup"
    }
}

New-MgEntitlementManagementResourceRequest -BodyParameter $ResourceParams | Out-Null

# Attente réplication Azure avant lecture de la ressource ajoutée
Start-Sleep -Seconds 5

Write-Host "-> Succès : Groupe ajouté comme ressource dans le Catalog.`n" -ForegroundColor Green

# --- ÉTAPE 5 : Création de l'Access Package ---
# L'Access Package est rattaché au Catalog créé à l'étape 3
Write-Host "3. Création de l'Access Package '$PackageName'..." -ForegroundColor Cyan

$PackageParams = @{
    DisplayName  = $PackageName
    Description  = $PackageDesc
    CatalogId    = $NewCatalog.Id
    IsHidden     = $false
}

$NewPackage = New-MgEntitlementManagementAccessPackage -BodyParameter $PackageParams

if (-not $NewPackage) { Write-Error "Échec de la création de l'Access Package." ; return }

Write-Host "-> Succès : Access Package créé avec l'ID : $($NewPackage.Id)`n" -ForegroundColor Green

# --- ÉTAPE 6 : Ajout de la ressource dans l'Access Package ---
# On récupère la ressource telle qu'elle est enregistrée dans le Catalog
# pour obtenir son ID interne — différent de l'ID du groupe Entra
$CatalogResource = Get-MgEntitlementManagementCatalogResource `
    -AccessPackageCatalogId $NewCatalog.Id `
    -Filter "originId eq '$($Group.Id)'"

$ResourceRoleParams = @{
    Role = @{
        DisplayName  = "Member"
        OriginSystem = "AadGroup"
        OriginId     = "Member_$($Group.Id)"
        Resource     = @{
            Id           = $CatalogResource.Id
            OriginId     = $Group.Id
            OriginSystem = "AadGroup"
        }
    }
    Scope = @{
        OriginSystem = "AadGroup"
        OriginId     = $Group.Id
    }
}

New-MgEntitlementManagementAccessPackageResourceRoleScope `
    -AccessPackageId $NewPackage.Id `
    -BodyParameter $ResourceRoleParams | Out-Null

Write-Host "-> Succès : Ressource ajoutée à l'Access Package.`n" -ForegroundColor Green

# --- ÉTAPE 7 : Configuration de la Policy d'assignation ---
# La Policy définit : qui peut demander, qui approuve, durée, expiration
# requestorSettings : AllExistingDirectoryMemberUsers = tout utilisateur du tenant peut demander
# approvalSettings : approbation en 1 étape par le manager défini dans $ApproverUPN
# expirationDate : durée de l'assignation — ici 90 jours
Write-Host "4. Configuration de la Policy d'assignation..." -ForegroundColor Cyan

$Approver = Get-MgUser -UserId $ApproverUPN -ErrorAction Stop

$PolicyParams = @{
    AccessPackageId = $NewPackage.Id
    DisplayName     = "Politique approbation manager"
    Description     = "Demande ouverte à tous les membres — approbation par le manager."

    RequestorSettings = @{
        ScopeType        = "AllExistingDirectoryMemberUsers"
        AcceptRequests   = $true
    }

    RequestApprovalSettings = @{
        IsApprovalRequired = $true
        ApprovalStages     = @(
            @{
                ApprovalStageTimeOutInDays      = 14
                IsApproverJustificationRequired = $true
                IsEscalationEnabled             = $false
                PrimaryApprovers                = @(
                    @{
                        # Approbateur unique — Geralt
                        "@odata.type" = "#microsoft.graph.singleUser"
                        UserId        = $Approver.Id
                    }
                )
            }
        )
    }

    # Expiration automatique après 90 jours — zéro oubli de révocation
    ExpirationDateTime = (Get-Date).AddDays(90).ToString("yyyy-MM-ddTHH:mm:ssZ")
}

New-MgEntitlementManagementAccessPackageAssignmentPolicy `
    -BodyParameter $PolicyParams | Out-Null

Write-Host "-> Succès : Policy configurée — approbation par $ApproverUPN, expiration 90 jours.`n" -ForegroundColor Green

# --- ÉTAPE 8 : Vérification finale ---
Write-Host "5. Vérification depuis Entra (source de vérité)..." -ForegroundColor Cyan
Start-Sleep -Seconds 2

Get-MgEntitlementManagementAccessPackage -AccessPackageId $NewPackage.Id |
    Select-Object Id, DisplayName, Description, CatalogId

# --- ÉTAPE 9 : Nettoyage ---
Remove-Variable Scopes, CatalogName, CatalogDesc, PackageName, PackageDesc, `
                ResourceGroup, ApproverUPN, CatalogParams, NewCatalog, Group, `
                ResourceParams, PackageParams, NewPackage, CatalogResource, `
                ResourceRoleParams, Approver, PolicyParams `
                -ErrorAction SilentlyContinue

Write-Host "`nMémoire locale nettoyée. Session Microsoft Graph toujours active." -ForegroundColor Magenta
