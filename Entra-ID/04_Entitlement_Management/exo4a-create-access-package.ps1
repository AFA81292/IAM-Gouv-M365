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
# OriginSystem "AadGroup" = groupe Entra
