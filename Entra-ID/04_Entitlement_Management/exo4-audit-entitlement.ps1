# ========================================================================================
# Exercice 4a : Entitlement Management — Création d'un Access Package complet
# ========================================================================================
# Scénario : Un consultant arrive en mission. Au lieu de créer les accès un par un,
# l'IT a préparé un Access Package "Admin-SP-Mission-Run" qui regroupe tous les droits
# nécessaires. Le manager approuve en un clic, les droits sont assignés automatiquement.
# A l'expiration — révocation automatique, zéro oubli.
#
# Structure Entitlement Management — dans cet ordre obligatoire :
#   1. Catalog        = le dossier. Contient les ressources et les packages.
#   2. Resource       = ce qu'on déclare dans le dossier (groupe, app, rôle SP)
#   3. Access Package = ce que l'utilisateur voit et demande dans My Access
#   4. ResourceScope  = le lien entre le package et la ressource + le rôle attribué
#   5. Policy         = qui demande, qui approuve, combien de temps
#
# Prérequis : SP-IAM-Lab avec admin consent sur :
#   EntitlementManagement.ReadWrite.All, Group.ReadWrite.All, User.Read.All
# ========================================================================================

# --- ÉTAPE 1 : Connexion via SP-IAM-Lab ---
# On utilise le SP dédié — EntitlementManagement.ReadWrite.All n'est pas autorisé
# via l'app générique Microsoft Graph Command Line Tools (WAM bloque ce scope)
$ClientId = "d54d29cb-2daf-45ef-baee-8abc79516b2c" # SP-IAM-Lab — GUID obligatoire
$TenantId = "0n4mg.onmicrosoft.com"

$Scopes = @(
    "EntitlementManagement.ReadWrite.All",
    "Group.ReadWrite.All",
    "User.Read.All"
)

Connect-MgGraph -ClientId $ClientId -TenantId $TenantId -Scopes $Scopes

# --- ÉTAPE 2 : Définition des variables ---
$CatalogName   = "Outils-IT-M365"
$CatalogDesc   = "Catalog des ressources IT pour les missions de support M365."
$PackageName   = "Admin-SP-Mission-Run"
$PackageDesc   = "Pack d'accès complet pour les missions de run SharePoint."
$ResourceGroup = "Witchers-Brotherhood"
$ApproverUPN   = "geralt@0n4mg.onmicrosoft.com"

# --- ÉTAPE 3 : Création du Catalog ---
# Le Catalog est le dossier — il doit exister AVANT le package et AVANT les ressources
# IsExternallyVisible $false = invisible aux utilisateurs externes au tenant
# En prod : un catalog par département ou par usage (Outils-IT, Outils-RH, Outils-Finance)
Write-Host "1. Création du Catalog '$CatalogName'..." -ForegroundColor Cyan

$CatalogParams = @{
    DisplayName         = $CatalogName
    Description         = $CatalogDesc
    IsExternallyVisible = $false
}

$NewCatalog = New-MgEntitlementManagementCatalog -BodyParameter $CatalogParams

if (-not $NewCatalog) { Write-Error "Échec de la création du Catalog." ; return }

Write-Host "-> Succès : Catalog créé avec l'ID : $($NewCatalog.Id)`n" -ForegroundColor Green

# --- ÉTAPE 4 : Déclaration du groupe comme ressource dans le Catalog ---
# Avant de mettre un groupe dans un package, il faut le déclarer dans le Catalog
# C'est dire à Entra : "ce groupe existe, je veux pouvoir l'utiliser dans mes packages"
# OriginSystem "AadGroup" = groupe Entra ID (vs "AadApplication" pour les apps)
# RequestType "adminAdd" = ajout par un admin, pas une demande utilisateur
Write-Host "2. Déclaration du groupe '$ResourceGroup' dans le Catalog..." -ForegroundColor Cyan

$Group = Get-MgGroup -Filter "displayName eq '$ResourceGroup'" -ErrorAction Stop

if (-not $Group) { Write-Error "Groupe '$ResourceGroup' introuvable." ; return }

$ResourceParams = @{
    CatalogId   = $NewCatalog.Id
    RequestType = "adminAdd"
    Resource    = @{
        OriginId     = $Group.Id
        OriginSystem = "AadGroup"
    }
}

New-MgEntitlementManagementResourceRequest -BodyParameter $ResourceParams | Out-Null

# Attente réplication Azure — le Catalog doit enregistrer la ressource avant qu'on puisse
# récupérer son ID interne à l'étape 6
Start-Sleep -Seconds 5

Write-Host "-> Succès : Groupe déclaré dans le Catalog.`n" -ForegroundColor Green

# --- ÉTAPE 5 : Création de l'Access Package ---
# Le package est ce que l'utilisateur voit et demande dans le portail My Access
# IsHidden $false = visible dans My Access
# CatalogId = rattaché au Catalog créé à l'étape 3 — obligatoire
Write-Host "3. Création de l'Access Package '$PackageName'..." -ForegroundColor Cyan

$PackageParams = @{
    DisplayName = $PackageName
    Description = $PackageDesc
    CatalogId   = $NewCatalog.Id
    IsHidden    = $false
}

$NewPackage = New-MgEntitlementManagementAccessPackage -BodyParameter $PackageParams

if (-not $NewPackage) { Write-Error "Échec de la création de l'Access Package." ; return }

Write-Host "-> Succès : Access Package créé avec l'ID : $($NewPackage.Id)`n" -ForegroundColor Green

# --- ÉTAPE 6 : Liaison ressource → package ---
# Le Catalog a donné un ID INTERNE à la ressource (différent de l'ID du groupe Entra)
# On doit d'abord récupérer cet ID interne, puis créer le lien package ↔ ressource
#
# OriginId "Member_$($Group.Id)" = quand quelqu'un obtient ce package,
# il devient MEMBRE du groupe — pas owner, pas autre chose
Write-Host "4. Liaison du groupe '$ResourceGroup' à l'Access Package..." -ForegroundColor Cyan

# Récupération de l'ID interne Catalog de la ressource — différent de l'ID Entra du groupe
$CatalogResource = Get-MgEntitlementManagementCatalogResource `
    -AccessPackageCatalogId $NewCatalog.Id `
    -Filter "originId eq '$($Group.Id)'"

$ResourceRoleParams = @{
    Role  = @{
        DisplayName  = "Member"
        OriginSystem = "AadGroup"
        # "Member_" + ID groupe = convention Graph pour le rôle membre d'un groupe Entra
        OriginId     = "Member_$($Group.Id)"
        Resource     = @{
            Id           = $CatalogResource.Id  # ID interne Catalog
            OriginId     = $Group.Id             # ID Entra du groupe
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

Write-Host "-> Succès : Groupe lié à l'Access Package — rôle : Member.`n" -ForegroundColor Green

# --- ÉTAPE 7 : Configuration de la Policy d'assignation ---
# La Policy est le cerveau du package. Elle définit 3 choses :
#
# RequestorSettings  — QUI peut demander
#   AllExistingDirectoryMemberUsers = tout membre du tenant peut faire une demande
#
# RequestApprovalSettings — COMMENT c'est approuvé
#   1 étape d'approbation, 14 jours pour répondre, justification obligatoire
#   Approbateur unique : Geralt
#
# ExpirationDateTime — COMBIEN DE TEMPS durent les droits
#   90 jours après approbation — révocation automatique, zéro oubli
Write-Host "5. Configuration de la Policy d'assignation..." -ForegroundColor Cyan

$Approver = Get-MgUser -UserId $ApproverUPN -ErrorAction Stop

$PolicyParams = @{
    AccessPackageId = $NewPackage.Id
    DisplayName     = "Politique approbation manager"
    Description     = "Demande ouverte à tous les membres — approbation par le manager."

    RequestorSettings = @{
        ScopeType      = "AllExistingDirectoryMemberUsers"
        AcceptRequests = $true
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
                        # "@odata.type" identifie le TYPE d'approbateur
                        # singleUser = une personne précise (vs manager, groupOwner...)
                        "@odata.type" = "#microsoft.graph.singleUser"
                        UserId        = $Approver.Id
                    }
                )
            }
        )
    }

    # (Get-Date).AddDays(90) = aujourd'hui + 90 jours
    # .ToString("yyyy-MM-ddTHH:mm:ssZ") = format ISO 8601 attendu par l'API Graph
    ExpirationDateTime = (Get-Date).AddDays(90).ToString("yyyy-MM-ddTHH:mm:ssZ")
}

New-MgEntitlementManagementAccessPackageAssignmentPolicy `
    -BodyParameter $PolicyParams | Out-Null

Write-Host "-> Succès : Policy configurée — approbateur : $ApproverUPN | Expiration : 90 jours.`n" -ForegroundColor Green

# --- ÉTAPE 8 : Vérification depuis Entra (source de vérité) ---
Write-Host "6. Vérification depuis Entra (source de vérité)..." -ForegroundColor Cyan
Start-Sleep -Seconds 2

Get-MgEntitlementManagementAccessPackage -AccessPackageId $NewPackage.Id |
    Select-Object Id, DisplayName, Description, CatalogId

# --- ÉTAPE 9 : Nettoyage ---
Remove-Variable ClientId, TenantId, Scopes, CatalogName, CatalogDesc, PackageName, `
                PackageDesc, ResourceGroup, ApproverUPN, CatalogParams, NewCatalog, `
                Group, ResourceParams, PackageParams, NewPackage, CatalogResource, `
                ResourceRoleParams, Approver, PolicyParams `
                -ErrorAction SilentlyContinue

Write-Host "`nMémoire locale nettoyée. Session Microsoft Graph toujours active." -ForegroundColor Magenta
