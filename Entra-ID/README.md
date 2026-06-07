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

<details>
<summary>Commandes utiles en une ligne — User Management</summary>

```powershell
# Lister tous les utilisateurs
Get-MgUser -All | Select-Object Id, DisplayName, UserPrincipalName, Department

# Rechercher un utilisateur par UPN
Get-MgUser -UserId "upn@domaine.onmicrosoft.com" | Select-Object Id, DisplayName, JobTitle, Department

# Désactiver un compte utilisateur
Update-MgUser -UserId "id-utilisateur" -AccountEnabled $false

# Supprimer un utilisateur
Remove-MgUser -UserId "id-utilisateur"

# Lister tous les rôles personnalisés
Get-MgRoleManagementDirectoryRoleDefinition -All | Where-Object {$_.IsBuiltIn -eq $false} | Select-Object Id, DisplayName

# Supprimer un rôle personnalisé (récupérer l'ID via Get-MgRoleManagementDirectoryRoleDefinition)
Remove-MgRoleManagementDirectoryRoleDefinition -UnifiedRoleDefinitionId "id-du-role"
```

</details>

---

### 02_Administrative_Units
* [Exo 2a : AU statique et droits scopés](./02_Administrative_Units/exo2a-static-au-delegation.ps1)
  * Objectif : Création d'une Administrative Unit statique, assignation de membres et délégation de rôle scopé.
* [Exo 2b : AU dynamique](./02_Administrative_Units/exo2b-dynamic-au-delegation.ps1)
  * Objectif : Création d'une Administrative Unit dynamique via règle d'appartenance.
  * Licence requise : Entra ID P1/P2.

<details>
<summary>Commandes utiles en une ligne — Administrative Units</summary>

```powershell
# Lister toutes les AUs
Get-MgDirectoryAdministrativeUnit -All | Select-Object Id, DisplayName, MembershipType

# Lister les membres d'une AU (récupérer l'ID via Get-MgDirectoryAdministrativeUnit)
Get-MgDirectoryAdministrativeUnitMember -AdministrativeUnitId "id-de-lau" | Select-Object Id

# Lister les admins scopés d'une AU
Get-MgDirectoryAdministrativeUnitScopedRoleMember -AdministrativeUnitId "id-de-lau"

# Supprimer une AU
Remove-MgDirectoryAdministrativeUnit -AdministrativeUnitId "id-de-lau"
```

</details>

---

### 03_Group_Management
* [Exo 3a : Security Group statique](./03_Group_Management/exo3a-static-security-group.ps1)
  * Objectif : Création d'un Security Group statique avec owner et peuplement de membres via fichier CSV.
* [Exo 3b : Security Group dynamique](./03_Group_Management/exo3b-dynamic-security-group.ps1)
  * Objectif : Création d'un Security Group dynamique avec règle de membership automatique basée sur l'attribut département.
  * Licence requise : Entra ID P1/P2.

<details>
<summary>Commandes utiles en une ligne — Group Management</summary>

```powershell
# Lister tous les groupes
Get-MgGroup -All | Select-Object Id, DisplayName, SecurityEnabled, GroupTypes

# Lister les membres d'un groupe (récupérer l'ID via Get-MgGroup)
Get-MgGroupMember -GroupId "id-du-groupe" | Select-Object Id

# Lister les owners d'un groupe
Get-MgGroupOwner -GroupId "id-du-groupe" | Select-Object Id

# Supprimer un groupe
Remove-MgGroup -GroupId "id-du-groupe"
```

</details>

---

### 04_Entitlement_Management
* [Exo 4 : Audit des ressources Entitlement Management](./04_Entitlement_Management/exo4-audit-entitlement.ps1)
  * Objectif : Lister les Catalogs, Access Packages, assignations actives et demandes en attente du tenant.
  * Licence requise : Entra ID P2.

> **Note technique :** Les opérations d'écriture Entitlement Management (création d'Access Packages,
> ajout de ressources, suppressions) sont redirigées par Graph vers un service backend IGA Microsoft séparé.
> Ce service retourne systématiquement 403 sur ce tenant de Dev E5 — indépendamment des scopes,
> du Service Principal utilisé, et du rôle Global Admin. Testé via cmdlets PowerShell ET via
> Invoke-MgGraphRequest. Les créations/suppressions sont gérées via GUI Entra Admin Center.

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

---

### 05_Conditional_Access
* [Exo 5a : Audit des politiques Conditional Access](./05_Conditional_Access/exo5a-audit-conditional-access.ps1)
  * Objectif : Lister toutes les politiques CA du tenant — état, répartition actives/Report-Only/désactivées.
  * Licence requise : Entra ID P1/P2.
* [Exo 5b : MFA obligatoire pour tous les utilisateurs](./05_Conditional_Access/exo5b-ca-require-mfa-all-users.ps1)
  * Objectif : Création d'une politique CA imposant le MFA à tous les utilisateurs avec exclusion d'un groupe break-glass.
  * State : Report-Only — bonne pratique avant activation en prod.
  * Licence requise : Entra ID P1/P2.
* [Exo 5c : Blocage des protocoles d'authentification legacy](./05_Conditional_Access/exo5c-ca-block-legacy-auth.ps1)
  * Objectif : Création d'une politique CA bloquant les protocoles legacy (SMTP, IMAP, POP3, Exchange ActiveSync) qui ne supportent pas le MFA.
  * State : Report-Only — bonne pratique avant activation en prod.
  * Licence requise : Entra ID P1/P2.
* [Exo 5d : Modification de l'état d'une politique CA](./05_Conditional_Access/exo5d-ca-update-state.ps1)
  * Objectif : Démonstration du cycle de vie d'une politique CA — passage de Report-Only à Enabled, puis retour en Report-Only.
  * Licence requise : Entra ID P1/P2.

> **Note technique :** Les opérations d'écriture CA nécessitent le scope
> Policy.ReadWrite.ConditionalAccess. Ce scope est bloqué par WAM (Web Account Manager —
> gestionnaire de tokens Windows) sur l'app générique Microsoft Graph Command Line Tools.
> Solution : `-ContextScope Process` sur Connect-MgGraph force une session isolée
> qui bypasse le cache WAM. Sans ce paramètre — 403 systématique.

<details>
<summary>Commandes utiles en une ligne — Conditional Access</summary>

```powershell
# Lister toutes les politiques CA
Get-MgIdentityConditionalAccessPolicy -All | Select-Object Id, DisplayName, State

# Lister uniquement les politiques actives
Get-MgIdentityConditionalAccessPolicy -All | Where-Object {$_.State -eq "enabled"} | Select-Object Id, DisplayName

# Lister les politiques en Report-Only
Get-MgIdentityConditionalAccessPolicy -All | Where-Object {$_.State -eq "enabledForReportingButNotEnforced"} | Select-Object Id, DisplayName

# Lister les politiques désactivées
Get-MgIdentityConditionalAccessPolicy -All | Where-Object {$_.State -eq "disabled"} | Select-Object Id, DisplayName

# Supprimer une politique CA (récupérer l'ID via Get-MgIdentityConditionalAccessPolicy)
Remove-MgIdentityConditionalAccessPolicy -ConditionalAccessPolicyId "id-de-la-politique"
```

</details>

---

### 06_PIM
* [Exo 6a : Audit des assignations PIM](./06_PIM/exo6a-audit-pim.ps1)
  * Objectif : Lister les assignations éligibles et actives, les rôles PIM configurés et les demandes d'activation en cours.
  * Licence requise : Entra ID P2.
* [Exo 6b : Assignation éligible d'un rôle via PIM](./06_PIM/exo6b-pim-eligible-assignment.ps1)
  * Objectif : Rendre un utilisateur éligible à un rôle Entra via PIM — il devra activer le rôle manuellement avec justification.
  * Licence requise : Entra ID P2.
* [Exo 6c : Assignation active time-bound d'un rôle via PIM](./06_PIM/exo6c-pim-active-assignment.ps1)
  * Objectif : Assigner un rôle de manière active et temporaire via PIM — accès immédiat avec expiration automatique.
  * Licence requise : Entra ID P2.

> **Note technique :** PIM utilise le scope RoleManagement.ReadWrite.Directory.
> Comme pour le Conditional Access, `-ContextScope Process` est requis pour bypasser le cache WAM.

<details>
<summary>Commandes utiles en une ligne — PIM</summary>

```powershell
# Lister toutes les assignations éligibles
Get-MgRoleManagementDirectoryRoleEligibilitySchedule -All | Select-Object Id, PrincipalId, RoleDefinitionId

# Lister toutes les assignations actives
Get-MgRoleManagementDirectoryRoleAssignmentSchedule -All | Select-Object Id, PrincipalId, RoleDefinitionId, Status

# Lister les demandes d'activation en cours
Get-MgRoleManagementDirectoryRoleAssignmentScheduleRequest -All | Select-Object Id, Action, Status, PrincipalId

# Supprimer une assignation éligible (récupérer l'ID via Get-MgRoleManagementDirectoryRoleEligibilitySchedule)
Remove-MgRoleManagementDirectoryRoleEligibilitySchedule -UnifiedRoleEligibilityScheduleId "id-de-lassignation"
```

</details>
