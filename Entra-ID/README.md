# Entra ID - Gestion des Identités (SC-300)

Notes de révision et scripts de validation pour les modules d'identité Microsoft.

## Prérequis
Le module Microsoft Graph PowerShell doit être installé :
```powershell
Install-Module Microsoft.Graph -Scope CurrentUser
```

## Index des Exercices (1 fichier = 1 exo)

### 01_User_Management
* [Exo 1a : Création d'un rôle personnalisé](./01_User_Management/exo1a-custom-role.ps1)
  * Objectif : Déploiement d'un rôle RBAC granulaire pour la création d'applications.
  * Licence requise : Entra ID P1/P2.
* [Exo 1b : Création unitaire d'un utilisateur](./01_User_Management/exo1b-create-user.ps1)
  * Objectif : Provisioning unitaire d'un utilisateur via Graph API.
* [Exo 1c : Création d'utilisateurs en masse](./01_User_Management/exo1c-bulk-create-users.ps1)
  * Objectif : Injection d'utilisateurs en masse via parsing du fichier [utilisateurs.csv](./01_User_Management/utilisateurs.csv).

### 02_Administrative_Units
* [Exo 2a : AU statique et droits scopés](./02_Administrative_Units/exo2a-static-au-delegation.ps1)
  * Objectif : Création d'une Administrative Unit statique, assignation de membres et délégation de rôle scopé au chef.
* [Exo 2b : AU dynamique](./02_Administrative_Units/exo2b-dynamic-au-delegation.ps1)
  * Objectif : Création d'une Administrative Unit dynamique via règle d'appartenance.
  * Licence requise : Entra ID P1/P2.

### 03_Group_Management
* [Exo 3a : Security Group statique](./03_Group_Management/exo3a-static-security-group.ps1)
  * Objectif : Création d'un Security Group statique avec owner et peuplement de membres via fichier CSV.
* [Exo 3b : Security Group dynamique](./03_Group_Management/exo3b-dynamic-security-group.ps1)
  * Objectif : Création d'un Security Group dynamique avec règle de membership automatique basée sur l'attribut département.
  * Licence requise : Entra ID P1/P2.

### 04_Entitlement_Management
* [Exo 4a : Création d'un Access Package complet](./04_Entitlement_Management/exo4a-create-access-package.ps1)
  * Objectif : Création d'un Catalog, d'un Access Package, ajout d'une ressource groupe et configuration d'une policy d'assignation avec approbation manager.
  * Licence requise : Entra ID P2.
* [Exo 4b : Création en masse d'Access Packages depuis CSV](./04_Entitlement_Management/exo4b-bulk-create-access-packages.ps1)
  * Objectif : Provisioning en masse d'Access Packages via parsing d'un fichier CSV.
  * Licence requise : Entra ID P2.
* [Exo 4c : Audit des demandes d'accès en attente](./04_Entitlement_Management/exo4c-audit-pending-requests.ps1)
  * Objectif : Lister toutes les demandes d'accès en attente d'approbation sur le tenant.
  * Licence requise : Entra ID P2.
* [Exo 4d : Nettoyage des Access Packages expirés](./04_Entitlement_Management/exo4d-cleanup-expired-packages.ps1)
  * Objectif : Identifier et supprimer les Access Packages expirés ou inutilisés.
  * Licence requise : Entra ID P2.


<details>
<summary>Commandes utiles en une ligne - Entitlement_Management </summary>
 **Commandes utiles en une ligne :**
 ```powershell
 # Lister tous les Access Packages du tenant
 Get-MgEntitlementManagementAccessPackage -All | Select-Object Id, DisplayName, Description

 # Lister tous les Catalogs
 Get-MgEntitlementManagementCatalog -All | Select-Object Id, DisplayName, State

 # Lister les demandes en attente
 Get-MgEntitlementManagementAssignmentRequest -Filter "state eq 'pendingApproval'" | Select-Object Id, RequestType, State

 # Lister les assignations actives
 Get-MgEntitlementManagementAssignment -Filter "state eq 'delivered'" -All | Select-Object Id, State

# Supprimer un Access Package (récupérer l'ID via Get-MgEntitlementManagementAccessPackage)
Remove-MgEntitlementManagementAccessPackage -AccessPackageId "id-de-l-access-package"

 # Supprimer un Catalog (récupérer l'ID via Get-MgEntitlementManagementCatalog)
 Remove-MgEntitlementManagementCatalog -AccessPackageCatalogId "id-du-catalog"
 ```
<details>

