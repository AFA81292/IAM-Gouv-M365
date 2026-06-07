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
* [Exo 4 : Audit des ressources Entitlement Management](./04_Entitlement_Management/exo4-audit-entitlement.ps1)
  * Objectif : Lister les Catalogs, Access Packages, assignations actives et demandes en attente du tenant.
  * Licence requise : Entra ID P2.

> **Note technique :** Les opérations d'écriture Entitlement Management (création d'Access Packages,
> ajout de ressources, suppressions) sont redirigées par Graph vers un service backend IGA Microsoft séparé.
> Ce service retourne systématiquement 403 sur mon tenant de Dev E5 — indépendamment des scopes,
> du Service Principal utilisé, et du rôle Global Admin. Testé via cmdlets PowerShell ET via
> Invoke-MgGraphRequest. Les créations/suppressions sont donc gérées via GUI Entra Admin Center uniquement.

<details>
<summary>Commandes utiles en une ligne — Entitlement Management</summary>

```powershell
# Lister tous les Catalogs
Get-MgEntitlementManagementCatalog -All | Select-Object Id, DisplayName, State

# Lister tous les Access Packages
Get-MgEntitlementManagementAccessPackage -All | Select-Object Id, DisplayName, Description, CatalogId

# Lister les assignations actives
Get-MgEntitlementManagementAssignment -Filter "state eq 'delivered'" -All | Select-Object Id, State

# Lister les demandes en attente
Get-MgEntitlementManagementAssignmentRequest -Filter "state eq 'pendingApproval'" | Select-Object Id, RequestType, State
```

</details>


### 05_Conditional_Access
* [Exo 5 : Audit des politiques Conditional Access](./05_Conditional_Access/exo5-audit-conditional-access.ps1)
  * Objectif : Lister toutes les politiques CA du tenant — état, conditions, grant controls.
  * Licence requise : Entra ID P1/P2.

> **Note technique :** Comme pour l'Entitlement Management, Les opérations d'écriture Conditionnal Access
>  sont redirigées par Graph vers un service backend IGA Microsoft séparé.
> Ce service retourne systématiquement 403 sur mon tenant de Dev E5 — indépendamment des scopes,
> du Service Principal utilisé, et du rôle Global Admin.
> Les politiques CA sont donc gérées via GUI Entra Admin Center uniquement.
> Ce script se limite à la lecture — use case audit/reporting.

<details>
<summary>Commandes utiles en une ligne — Conditional Access</summary>

```powershell
# Lister toutes les politiques CA du tenant
Get-MgIdentityConditionalAccessPolicy -All | Select-Object Id, DisplayName, State

# Lister uniquement les politiques actives
Get-MgIdentityConditionalAccessPolicy -All | Where-Object {$_.State -eq "enabled"} | Select-Object Id, DisplayName

# Lister les politiques en Report-Only
Get-MgIdentityConditionalAccessPolicy -All | Where-Object {$_.State -eq "enabledForReportingButNotEnforced"} | Select-Object Id, DisplayName

# Lister les politiques désactivées
Get-MgIdentityConditionalAccessPolicy -All | Where-Object {$_.State -eq "disabled"} | Select-Object Id, DisplayName
```

</details>
