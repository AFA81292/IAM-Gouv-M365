# Entra ID - Gestion des Identités (SC-300)

Notes de révision et scripts de validation pour les modules d'identité Microsoft.

## Prérequis

Le module Microsoft Graph PowerShell doit être installé :
```powershell
Install-Module Microsoft.Graph -Scope CurrentUser
```

Connexion standard (lecture seule, opérations basiques) :
```powershell
Connect-MgGraph -Scopes "User.Read.All", "Group.Read.All"
```

Les exercices d'écriture (CA, PIM, Access Reviews, RBAC) nécessitent `-ContextScope Process` pour bypasser le cache WAM :
```powershell
Connect-MgGraph -Scopes "Policy.ReadWrite.ConditionalAccess" -ContextScope Process
```

## Index des Exercices (1 fichier = 1 exo)

### 01_User_Management

#### Provisioning
* [Exo 1a : Création unitaire d'un utilisateur](./01_User_Management/exo1a-create-user.ps1)
  * Objectif : Provisioning unitaire d'un utilisateur via Graph API.
  * Connexion requise : `Connect-MgGraph -Scopes "User.ReadWrite.All"` + `-ContextScope Process`
* [Exo 1b : Création d'utilisateurs en masse](./01_User_Management/exo1b-bulk-create-users.ps1)
  * Objectif : Injection d'utilisateurs en masse via parsing du fichier [utilisateurs.csv](./01_User_Management/utilisateurs.csv).
  * Connexion requise : `Connect-MgGraph -Scopes "User.ReadWrite.All"` + `-ContextScope Process`
* [Exo 1c : Attribution de licence unitaire](./01_User_Management/exo1c-single-licence-assignment.ps1)
  * Objectif : Attribuer une licence M365 à un utilisateur — vérification du UsageLocation, contrôle des places disponibles, attribution via Graph API.
  * Connexion requise : `Connect-MgGraph -Scopes "User.ReadWrite.All", "Directory.ReadWrite.All"` + `-ContextScope Process`
  * Licence requise : selon la licence attribuée
* [Exo 1d : Attribution de licence en masse](./01_User_Management/exo1d-bulk-licence-assignment.ps1)
  * Objectif : Attribuer la même licence à un ensemble d'utilisateurs depuis un CSV — détection des doublons, gestion des UsageLocation manquants.
  * Connexion requise : `Connect-MgGraph -Scopes "User.ReadWrite.All", "Directory.ReadWrite.All"` + `-ContextScope Process`
  * Licence requise : selon la licence attribuée

#### Cycle de vie
* [Exo 1e : Désactivation d'un compte](./01_User_Management/exo1e-disable-user.ps1)
  * Objectif : Désactiver un compte utilisateur — première étape d'un offboarding, avant suppression définitive.
  * Connexion requise : `Connect-MgGraph -Scopes "User.ReadWrite.All"` + `-ContextScope Process`
* [Exo 1f : Réactivation d'un compte](./01_User_Management/exo1f-enable-user.ps1)
  * Objectif : Réactiver un compte précédemment désactivé — pendant logique de l'exo 1e.
  * Connexion requise : `Connect-MgGraph -Scopes "User.ReadWrite.All"` + `-ContextScope Process`
* [Exo 1g : Modification d'attributs](./01_User_Management/exo1g-update-user.ps1)
  * Objectif : Mettre à jour les attributs d'un utilisateur — département, job title, manager, usage location.
  * Connexion requise : `Connect-MgGraph -Scopes "User.ReadWrite.All"` + `-ContextScope Process`
* [Exo 1h : Suppression d'un compte](./01_User_Management/exo1h-delete-user.ps1)
  * Objectif : Supprimer un compte utilisateur — suppression logique vers la corbeille Entra (récupérable 30 jours).
  * Connexion requise : `Connect-MgGraph -Scopes "User.ReadWrite.All"` + `-ContextScope Process`
* [Exo 1i : Retrait de licence](./01_User_Management/exo1i-remove-licence.ps1)
  * Objectif : Retirer une ou plusieurs licences d'un utilisateur — pendant logique des exos 1c et 1d.
  * Connexion requise : `Connect-MgGraph -Scopes "User.ReadWrite.All", "Directory.ReadWrite.All"` + `-ContextScope Process`

#### Audit
* [Exo 1j : Audit des identités](./01_User_Management/exo1j-audit-identities.ps1)
  * Objectif : Inventorier tous les comptes du tenant — membres, invités, actifs, désactivés, avec export CSV.
  * Connexion requise : `Connect-MgGraph -Scopes "User.Read.All"`
* [Exo 1k : Audit des comptes invités](./01_User_Management/exo1k-audit-guests.ps1)
  * Objectif : Contrôler les accès externes — état des invités, dernière connexion, jamais connectés, inactifs.
  * Connexion requise : `Connect-MgGraph -Scopes "User.Read.All"`
* [Exo 1l : Audit des comptes inactifs](./01_User_Management/exo1l-audit-inactive.ps1)
  * Objectif : Détecter les comptes à nettoyer — inactifs depuis 30, 90, 180 jours ou jamais connectés.
  * Connexion requise : `Connect-MgGraph -Scopes "User.Read.All", "AuditLog.Read.All"`
* [Exo 1m : Audit des licences](./01_User_Management/exo1m-audit-licences.ps1)
  * Objectif : Inventaire des licences du tenant — utilisateurs sans licence, avec plusieurs licences, filtre par SKU.
  * Connexion requise : `Connect-MgGraph -Scopes "User.Read.All", "Directory.Read.All"`

<details>
<summary>Commandes utiles en une ligne — User Management</summary>

```powershell
# Lister tous les utilisateurs
Get-MgUser -All | Select-Object Id, DisplayName, UserPrincipalName, Department

# Rechercher un utilisateur par UPN
Get-MgUser -UserId "upn@domaine.onmicrosoft.com" | Select-Object Id, DisplayName, JobTitle, Department

# Désactiver un compte utilisateur
Update-MgUser -UserId "id-utilisateur" -AccountEnabled $false

# Réactiver un compte utilisateur
Update-MgUser -UserId "id-utilisateur" -AccountEnabled $true

# Modifier le département d'un utilisateur
Update-MgUser -UserId "id-utilisateur" -Department "Nouveau département"

# Modifier le manager d'un utilisateur
$ManagerRef = @{ "@odata.id" = "https://graph.microsoft.com/v1.0/users/id-du-manager" }
Set-MgUserManagerByRef -UserId "id-utilisateur" -BodyParameter $ManagerRef

# Supprimer un utilisateur (suppression logique — récupérable 30 jours via la corbeille Entra)
Remove-MgUser -UserId "id-utilisateur"

# Lister les utilisateurs supprimés (corbeille)
Get-MgDirectoryDeletedItemAsUser -All | Select-Object Id, DisplayName, UserPrincipalName

# Restaurer un utilisateur supprimé depuis la corbeille
Restore-MgDirectoryDeletedItem -DirectoryObjectId "id-utilisateur"

# Lister les licences disponibles dans le tenant
Get-MgSubscribedSku | Select-Object SkuPartNumber, ConsumedUnits, @{N="Total";E={$_.PrepaidUnits.Enabled}}

# Lister les licences d'un utilisateur
Get-MgUserLicenseDetail -UserId "upn@domaine.onmicrosoft.com" | Select-Object SkuPartNumber

# Retirer une licence à un utilisateur
Set-MgUserLicense -UserId "id-utilisateur" -AddLicenses @() -RemoveLicenses @("sku-id")

# Lister les utilisateurs sans licence
Get-MgUser -All -Property Id, DisplayName, UserPrincipalName, AssignedLicenses |
    Where-Object { $_.AssignedLicenses.Count -eq 0 } |
    Select-Object DisplayName, UserPrincipalName

# Lister les invités uniquement
Get-MgUser -All -Filter "userType eq 'Guest'" |
    Select-Object DisplayName, UserPrincipalName, CreatedDateTime

# Déconnecter proprement la session Graph
Disconnect-MgGraph
```

</details>

---

### 02_Administrative_Units
* [Exo 2a : AU statique et droits scopés](./02_Administrative_Units/exo2a-static-au-delegation.ps1)
  * Objectif : Création d'une Administrative Unit statique, assignation de membres et délégation de rôle scopé.
  * Connexion requise : `Connect-MgGraph -Scopes "AdministrativeUnit.ReadWrite.All", "RoleManagement.ReadWrite.Directory"` + `-ContextScope Process`
* [Exo 2b : AU dynamique](./02_Administrative_Units/exo2b-dynamic-au-delegation.ps1)
  * Objectif : Création d'une Administrative Unit dynamique via règle d'appartenance.
  * Connexion requise : `Connect-MgGraph -Scopes "AdministrativeUnit.ReadWrite.All"` + `-ContextScope Process`
  * Licence requise : Entra ID P1/P2
* [Exo 2c : Audit des Administrative Units](./02_Administrative_Units/exo2c-audit-au.ps1)
  * Objectif : Inventorier les AUs du tenant — membres, admins scopés, AUs vides, AUs sans admin délégué.
  * Connexion requise : `Connect-MgGraph -Scopes "AdministrativeUnit.Read.All", "RoleManagement.Read.Directory"`

<details>
<summary>Commandes utiles en une ligne — Administrative Units</summary>

```powershell
# Lister toutes les AUs
Get-MgDirectoryAdministrativeUnit -All | Select-Object Id, DisplayName, MembershipType

# Lister les membres d'une AU (récupérer l'ID via Get-MgDirectoryAdministrativeUnit)
Get-MgDirectoryAdministrativeUnitMember -AdministrativeUnitId "id-de-lau" | Select-Object Id

# Lister les admins scopés d'une AU
Get-MgDirectoryAdministrativeUnitScopedRoleMember -AdministrativeUnitId "id-de-lau"

# Filtrer les AUs sans membres
Get-MgDirectoryAdministrativeUnit -All | Where-Object {
    (Get-MgDirectoryAdministrativeUnitMember -AdministrativeUnitId $_.Id).Count -eq 0
} | Select-Object DisplayName

# Filtrer les AUs sans admin scopé
Get-MgDirectoryAdministrativeUnit -All | Where-Object {
    (Get-MgDirectoryAdministrativeUnitScopedRoleMember -AdministrativeUnitId $_.Id).Count -eq 0
} | Select-Object DisplayName

# Supprimer une AU
Remove-MgDirectoryAdministrativeUnit -AdministrativeUnitId "id-de-lau"

# Déconnecter proprement la session Graph
Disconnect-MgGraph
```

</details>

---

### 03_Group_Management
* [Exo 3a : Security Group statique](./03_Group_Management/exo3a-static-security-group.ps1)
  * Objectif : Création d'un Security Group statique avec owner et peuplement de membres via fichier CSV.
  * Connexion requise : `Connect-MgGraph -Scopes "Group.ReadWrite.All", "User.Read.All"` + `-ContextScope Process`
* [Exo 3b : Security Group dynamique](./03_Group_Management/exo3b-dynamic-security-group.ps1)
  * Objectif : Création d'un Security Group dynamique avec règle de membership automatique basée sur l'attribut département.
  * Connexion requise : `Connect-MgGraph -Scopes "Group.ReadWrite.All", "User.Read.All"` + `-ContextScope Process`
  * Licence requise : Entra ID P1/P2
* [Exo 3c : Groupe M365 (Unified Group)](./03_Group_Management/exo3c-create-m365-group.ps1)
  * Objectif : Création d'un groupe M365 avec mailbox partagée — utilisé comme cible de Label Policy dans Purview 2d.
  * Connexion requise : `Connect-MgGraph -Scopes "Group.ReadWrite.All"` + `-ContextScope Process`
  * Note : `-BodyParameter` obligatoire sur `New-MgGroup` — les paramètres directs `-MailEnabled` et `-SecurityEnabled` lèvent une erreur de type sur les versions récentes du module Graph.
* [Exo 3d : Audit des groupes](./03_Group_Management/exo3d-audit-groups.ps1)
  * Objectif : Inventorier les groupes du tenant — Security Groups, M365 Groups, groupes dynamiques, avec export CSV.
  * Connexion requise : `Connect-MgGraph -Scopes "Group.Read.All"`
* [Exo 3e : Audit des groupes sans propriétaire](./03_Group_Management/exo3e-audit-groups-no-owner.ps1)
  * Objectif : Identifier les groupes mal gouvernés — sans owner, avec plusieurs owners, sans membres.
  * Connexion requise : `Connect-MgGraph -Scopes "Group.Read.All"`

<details>
<summary>Commandes utiles en une ligne — Group Management</summary>

```powershell
# Lister tous les groupes
Get-MgGroup -All | Select-Object Id, DisplayName, SecurityEnabled, GroupTypes

# Filtrer les groupes M365 uniquement (Unified)
Get-MgGroup -All | Where-Object { $_.GroupTypes -contains "Unified" } | Select-Object Id, DisplayName, Mail

# Filtrer les Security Groups uniquement
Get-MgGroup -All | Where-Object { $_.SecurityEnabled -eq $true -and $_.GroupTypes -notcontains "Unified" } |
    Select-Object Id, DisplayName

# Filtrer les groupes dynamiques uniquement
Get-MgGroup -All | Where-Object { $_.GroupTypes -contains "DynamicMembership" } |
    Select-Object Id, DisplayName, MembershipRule

# Lister les membres d'un groupe (récupérer l'ID via Get-MgGroup)
Get-MgGroupMember -GroupId "id-du-groupe" | Select-Object Id

# Résoudre les membres d'un groupe avec leur UPN
Get-MgGroupMember -GroupId "id-du-groupe" |
    ForEach-Object { Get-MgUser -UserId $_.Id | Select-Object DisplayName, UserPrincipalName }

# Lister les owners d'un groupe
Get-MgGroupOwner -GroupId "id-du-groupe" | Select-Object Id

# Identifier les groupes sans owner
Get-MgGroup -All | Where-Object {
    (Get-MgGroupOwner -GroupId $_.Id).Count -eq 0
} | Select-Object DisplayName, Id

# Identifier les groupes sans membres
Get-MgGroup -All | Where-Object {
    (Get-MgGroupMember -GroupId $_.Id).Count -eq 0
} | Select-Object DisplayName, Id

# Supprimer un groupe
Remove-MgGroup -GroupId "id-du-groupe"

# Déconnecter proprement la session Graph
Disconnect-MgGraph
```

</details>

---

### 04_Entitlement_Management
* [Exo 4 : Audit des ressources Entitlement Management](./04_Entitlement_Management/exo4-audit-entitlement.ps1)
  * Objectif : Lister les Catalogs, Access Packages, assignations actives et demandes en attente du tenant.
  * Connexion requise : `Connect-MgGraph -Scopes "EntitlementManagement.Read.All"` + `-ContextScope Process`
  * Licence requise : Entra ID P2

<details>
<summary>Note technique — opérations d'écriture Entitlement Management non couvertes</summary>

> Les opérations d'écriture Entitlement Management (création d'Access Packages, ajout de ressources,
> suppressions) sont redirigées par Graph vers un service backend IGA Microsoft séparé.
> Ce service retourne systématiquement 403 sur ce tenant de Dev E5 — indépendamment des scopes,
> du Service Principal utilisé, et du rôle Global Admin. Testé via cmdlets PowerShell ET via
> `Invoke-MgGraphRequest`. Les créations/suppressions sont gérées via **Entra Admin Center >
> Identity Governance > Entitlement Management**.
>
> Note : le 403 est lié à un bug introduit dans le module Graph >= 2.25.0 sur les cmdlets IGA v1.0.
> Contournement documenté : cmdlets Beta (`New-MgBetaEntitlementManagementAccessPackage`) —
> non couvert ici car hors périmètre d'un exercice de dev tenant stable.

</details>

<details>
<summary>Commandes utiles en une ligne — Entitlement Management</summary>

```powershell
# Lister tous les Catalogs
Get-MgEntitlementManagementCatalog -All | Select-Object Id, DisplayName, State

# Filtrer les Catalogs publiés uniquement
Get-MgEntitlementManagementCatalog -All |
    Where-Object { $_.State -eq "published" } | Select-Object Id, DisplayName

# Lister tous les Access Packages
Get-MgEntitlementManagementAccessPackage -All | Select-Object Id, DisplayName, Description, CatalogId

# Filtrer les Access Packages non masqués (visibles dans My Access)
Get-MgEntitlementManagementAccessPackage -All |
    Where-Object { $_.IsHidden -eq $false } | Select-Object Id, DisplayName

# Filtrer les Access Packages sans assignation active (packages potentiellement inutilisés)
Get-MgEntitlementManagementAccessPackage -All | Where-Object {
    (Get-MgEntitlementManagementAssignment -Filter "accessPackageId eq '$($_.Id)' and state eq 'delivered'" -All).Count -eq 0
} | Select-Object DisplayName, Id

# Lister les assignations actives
Get-MgEntitlementManagementAssignment -Filter "state eq 'delivered'" -All | Select-Object Id, State

# Lister les demandes en attente
Get-MgEntitlementManagementAssignmentRequest -Filter "state eq 'pendingApproval'" |
    Select-Object Id, RequestType, State

# Déconnecter proprement la session Graph
Disconnect-MgGraph
```

</details>

---

### 05_Conditional_Access
* [Exo 5a : Audit des politiques Conditional Access](./05_Conditional_Access/exo5a-audit-conditional-access.ps1)
  * Objectif : Lister toutes les politiques CA du tenant — état, répartition actives/Report-Only/désactivées.
  * Connexion requise : `Connect-MgGraph -Scopes "Policy.Read.All"`
  * Licence requise : Entra ID P1/P2
* [Exo 5b : MFA obligatoire pour tous les utilisateurs](./05_Conditional_Access/exo5b-ca-require-mfa-all-users.ps1)
  * Objectif : Création d'une politique CA imposant le MFA à tous les utilisateurs avec exclusion d'un groupe break-glass.
  * State : Report-Only — bonne pratique avant activation en prod.
  * Connexion requise : `Connect-MgGraph -Scopes "Policy.ReadWrite.ConditionalAccess", "Group.Read.All"` + `-ContextScope Process`
  * Licence requise : Entra ID P1/P2
* [Exo 5c : Blocage des protocoles d'authentification legacy](./05_Conditional_Access/exo5c-ca-block-legacy-auth.ps1)
  * Objectif : Création d'une politique CA bloquant les protocoles legacy (SMTP, IMAP, POP3, Exchange ActiveSync) qui ne supportent pas le MFA.
  * State : Report-Only — bonne pratique avant activation en prod.
  * Connexion requise : `Connect-MgGraph -Scopes "Policy.ReadWrite.ConditionalAccess"` + `-ContextScope Process`
  * Licence requise : Entra ID P1/P2
* [Exo 5d : Modification de l'état d'une politique CA](./05_Conditional_Access/exo5d-ca-update-state.ps1)
  * Objectif : Démonstration du cycle de vie d'une politique CA — passage de Report-Only à Enabled, puis retour en Report-Only.
  * Connexion requise : `Connect-MgGraph -Scopes "Policy.ReadWrite.ConditionalAccess"` + `-ContextScope Process`
  * Licence requise : Entra ID P1/P2

<details>
<summary>Note technique — WAM et -ContextScope Process</summary>

> Les opérations d'écriture CA nécessitent le scope `Policy.ReadWrite.ConditionalAccess`.
> Ce scope est bloqué par WAM (Web Account Manager — gestionnaire de tokens Windows) sur
> l'app générique Microsoft Graph Command Line Tools.
> Solution : `-ContextScope Process` sur `Connect-MgGraph` force une session isolée
> qui bypasse le cache WAM. Sans ce paramètre — 403 systématique.
> Ce comportement s'applique également à PIM (`RoleManagement.ReadWrite.Directory`)
> et Access Reviews (`AccessReview.ReadWrite.All`).

</details>

<details>
<summary>Commandes utiles en une ligne — Conditional Access</summary>

```powershell
# Lister toutes les politiques CA
Get-MgIdentityConditionalAccessPolicy -All | Select-Object Id, DisplayName, State

# Lister uniquement les politiques actives
Get-MgIdentityConditionalAccessPolicy -All |
    Where-Object { $_.State -eq "enabled" } | Select-Object Id, DisplayName

# Lister les politiques en Report-Only
Get-MgIdentityConditionalAccessPolicy -All |
    Where-Object { $_.State -eq "enabledForReportingButNotEnforced" } | Select-Object Id, DisplayName

# Lister les politiques désactivées
Get-MgIdentityConditionalAccessPolicy -All |
    Where-Object { $_.State -eq "disabled" } | Select-Object Id, DisplayName

# Afficher les grant controls d'une politique (MFA, blocage, poste conforme...)
Get-MgIdentityConditionalAccessPolicy -ConditionalAccessPolicyId "id-de-la-politique" |
    Select-Object -ExpandProperty GrantControls

# Afficher les conditions d'une politique (users, apps, plateformes ciblés)
Get-MgIdentityConditionalAccessPolicy -ConditionalAccessPolicyId "id-de-la-politique" |
    Select-Object -ExpandProperty Conditions

# Filtrer les politiques créées récemment (30 derniers jours)
$Seuil = (Get-Date).AddDays(-30)
Get-MgIdentityConditionalAccessPolicy -All |
    Where-Object { $_.CreatedDateTime -gt $Seuil } | Select-Object DisplayName, CreatedDateTime

# Supprimer une politique CA (récupérer l'ID via Get-MgIdentityConditionalAccessPolicy)
Remove-MgIdentityConditionalAccessPolicy -ConditionalAccessPolicyId "id-de-la-politique"

# Déconnecter proprement la session Graph
Disconnect-MgGraph
```

</details>

---

### 06_PIM
* [Exo 6a : Audit des assignations PIM](./06_PIM/exo6a-audit-pim.ps1)
  * Objectif : Lister les assignations éligibles et actives, les rôles PIM configurés et les demandes d'activation en cours.
  * Connexion requise : `Connect-MgGraph -Scopes "RoleManagement.Read.Directory"` + `-ContextScope Process`
  * Licence requise : Entra ID P2
* [Exo 6b : Assignation éligible d'un rôle via PIM](./06_PIM/exo6b-pim-eligible-assignment.ps1)
  * Objectif : Rendre un utilisateur éligible à un rôle Entra via PIM — activation sur demande avec justification obligatoire.
  * Connexion requise : `Connect-MgGraph -Scopes "RoleManagement.ReadWrite.Directory"` + `-ContextScope Process`
  * Licence requise : Entra ID P2
* [Exo 6c : Assignation active time-bound d'un rôle via PIM](./06_PIM/exo6c-pim-active-assignment.ps1)
  * Objectif : Assigner un rôle de manière active et temporaire — accès immédiat avec expiration automatique.
  * Connexion requise : `Connect-MgGraph -Scopes "RoleManagement.ReadWrite.Directory"` + `-ContextScope Process`
  * Licence requise : Entra ID P2
* [Exo 6d : Audit des rôles permanents à risque](./06_PIM/exo6d-pim-audit-permanent-roles.ps1)
  * Objectif : Identifier les assignations permanentes sur les rôles sensibles — base d'un rapport sécurité en première semaine de mission.
  * Connexion requise : `Connect-MgGraph -Scopes "RoleManagement.Read.Directory"` + `-ContextScope Process`
  * Licence requise : Entra ID P2

<details>
<summary>Note technique — WAM et -ContextScope Process</summary>

> PIM utilise le scope `RoleManagement.ReadWrite.Directory`, bloqué par WAM sur l'app générique
> Microsoft Graph Command Line Tools. `-ContextScope Process` est requis pour bypasser le cache WAM.
> Voir note identique dans le chapitre 05_Conditional_Access — même mécanisme, même solution.

</details>

<details>
<summary>Commandes utiles en une ligne — PIM</summary>

```powershell
# Lister toutes les assignations éligibles
Get-MgRoleManagementDirectoryRoleEligibilitySchedule -All |
    Select-Object Id, PrincipalId, RoleDefinitionId

# Lister toutes les assignations actives
Get-MgRoleManagementDirectoryRoleAssignmentSchedule -All |
    Select-Object Id, PrincipalId, RoleDefinitionId, Status

# Lister les assignations permanentes uniquement
Get-MgRoleManagementDirectoryRoleAssignmentSchedule -All |
    Where-Object { $_.ScheduleInfo.Expiration.Type -eq "noExpiration" } |
    Select-Object Id, PrincipalId, RoleDefinitionId

# Filtrer les assignations permanentes de type "Assigned" (hors PIM — à convertir en éligibles)
Get-MgRoleManagementDirectoryRoleAssignmentSchedule -All |
    Where-Object {
        $_.ScheduleInfo.Expiration.Type -eq "noExpiration" -and
        $_.AssignmentType -eq "Assigned"
    } | Select-Object Id, PrincipalId, RoleDefinitionId

# Filtrer les assignations éligibles proches de l'expiration (30 prochains jours)
$Seuil = (Get-Date).AddDays(30)
Get-MgRoleManagementDirectoryRoleEligibilitySchedule -All |
    Where-Object { $_.ScheduleInfo.Expiration.EndDateTime -lt $Seuil -and
                   $_.ScheduleInfo.Expiration.EndDateTime -ne $null } |
    Select-Object Id, PrincipalId, RoleDefinitionId

# Lister les demandes d'activation en cours
Get-MgRoleManagementDirectoryRoleAssignmentScheduleRequest -All |
    Select-Object Id, Action, Status, PrincipalId

# Supprimer une assignation éligible
Remove-MgRoleManagementDirectoryRoleEligibilitySchedule -UnifiedRoleEligibilityScheduleId "id-de-lassignation"

# Déconnecter proprement la session Graph
Disconnect-MgGraph
```

</details>

---

### 07_Access_Reviews
* [Exo 7a : Audit des campagnes de révision](./07_Access_Reviews/exo7a-audit-access-reviews.ps1)
  * Objectif : Lister toutes les campagnes Access Review — état, instances en cours, décisions prises.
  * Connexion requise : `Connect-MgGraph -Scopes "AccessReview.Read.All"` + `-ContextScope Process`
  * Licence requise : Entra ID P2
* [Exo 7b : Création d'une campagne de révision trimestrielle](./07_Access_Reviews/exo7b-create-access-review.ps1)
  * Objectif : Création d'une campagne de révision récurrente sur un groupe — reviewer désigné, décision automatique Deny si pas de réponse.
  * Connexion requise : `Connect-MgGraph -Scopes "AccessReview.ReadWrite.All"` + `-ContextScope Process`
  * Licence requise : Entra ID P2

<details>
<summary>Note technique — WAM et -ContextScope Process</summary>

> Access Reviews utilise le scope `AccessReview.ReadWrite.All`, bloqué par WAM sur l'app générique
> Microsoft Graph Command Line Tools. `-ContextScope Process` est requis pour bypasser le cache WAM.
> Voir note identique dans le chapitre 05_Conditional_Access — même mécanisme, même solution.

</details>

<details>
<summary>Commandes utiles en une ligne — Access Reviews</summary>

```powershell
# Lister toutes les campagnes de révision
Get-MgIdentityGovernanceAccessReviewDefinition -All | Select-Object Id, DisplayName, Status

# Filtrer les campagnes actives uniquement
Get-MgIdentityGovernanceAccessReviewDefinition -All |
    Where-Object { $_.Status -eq "inProgress" } | Select-Object Id, DisplayName

# Lister les instances en cours d'une campagne
Get-MgIdentityGovernanceAccessReviewDefinitionInstance `
    -AccessReviewScheduleDefinitionId "id-de-la-campagne" -All |
    Where-Object { $_.Status -eq "inProgress" }

# Lister les décisions d'une instance
Get-MgIdentityGovernanceAccessReviewDefinitionInstanceDecision `
    -AccessReviewScheduleDefinitionId "id-campagne" `
    -AccessReviewInstanceId "id-instance" -All |
    Select-Object Decision, Principal

# Filtrer les décisions "Deny" uniquement
Get-MgIdentityGovernanceAccessReviewDefinitionInstanceDecision `
    -AccessReviewScheduleDefinitionId "id-campagne" `
    -AccessReviewInstanceId "id-instance" -All |
    Where-Object { $_.Decision -eq "Deny" } | Select-Object Decision, Principal

# Supprimer une campagne
Remove-MgIdentityGovernanceAccessReviewDefinition -AccessReviewScheduleDefinitionId "id-de-la-campagne"

# Déconnecter proprement la session Graph
Disconnect-MgGraph
```

</details>

---

### 08_RBAC
* [Exo 8a : Création d'un rôle personnalisé](./08_RBAC/exo8a-custom-role.ps1)
  * Objectif : Déploiement d'un rôle RBAC granulaire pour la création d'applications — démonstration du least privilege via rôle custom vs rôle built-in trop large.
  * Connexion requise : `Connect-MgGraph -Scopes "RoleManagement.ReadWrite.Directory"` + `-ContextScope Process`
  * Licence requise : Entra ID P1/P2
  * Note : script déplacé depuis `01_User_Management/exo1a` — même contenu, reclassé dans son chapitre naturel.
* [Exo 8b : Assignation d'un rôle built-in](./08_RBAC/exo8b-assign-builtin-role.ps1)
  * Objectif : Assigner un rôle Entra built-in à un utilisateur — opération la plus fréquente en mission IAM, avec vérification de l'assignation existante avant création.
  * Connexion requise : `Connect-MgGraph -Scopes "RoleManagement.ReadWrite.Directory"` + `-ContextScope Process`
* [Exo 8c : Désassignation d'un rôle](./08_RBAC/exo8c-remove-role-assignment.ps1)
  * Objectif : Retirer un rôle Entra à un utilisateur — pendant logique de l'exo 8b, cycle de vie complet d'une assignation.
  * Connexion requise : `Connect-MgGraph -Scopes "RoleManagement.ReadWrite.Directory"` + `-ContextScope Process`
* [Exo 8d : Membres d'un rôle](./08_RBAC/exo8d-list-role-members.ps1)
  * Objectif : Lister tous les détenteurs d'un rôle donné — opération de contrôle immédiate après assignation ou désassignation.
  * Connexion requise : `Connect-MgGraph -Scopes "RoleManagement.Read.Directory"`
* [Exo 8e : Assignation scopée à une Administrative Unit](./08_RBAC/exo8e-scoped-role-assignment-au.ps1)
  * Objectif : Assigner un rôle Entra limité au périmètre d'une AU — délégation granulaire sans droits tenant-wide, lien naturel avec le chapitre 02_Administrative_Units.
  * Connexion requise : `Connect-MgGraph -Scopes "RoleManagement.ReadWrite.Directory", "AdministrativeUnit.Read.All"` + `-ContextScope Process`
* [Exo 8f : Audit des rôles administratifs](./08_RBAC/exo8f-audit-admin-roles.ps1)
  * Objectif : Inventorier tous les détenteurs de rôles Entra — rôles built-in vs custom, Global Admins, Security Admins, rôles sensibles, avec export CSV.
  * Connexion requise : `Connect-MgGraph -Scopes "RoleManagement.Read.Directory", "User.Read.All"`

<details>
<summary>Note technique — RBAC Entra vs rôles Azure RBAC</summary>

> Les rôles couverts dans ce chapitre sont les **rôles Entra ID** (anciennement Azure AD roles) —
> ils gouvernent les actions d'administration sur le tenant Entra (créer des users, gérer des apps,
> configurer le CA, etc.). Ils sont distincts des **rôles Azure RBAC** qui gouvernent les ressources
> Azure (VM, Storage, Key Vault...) et dont la surface PowerShell passe par le module `Az`.
>
> Deux familles de cmdlets coexistent selon le contexte :
> - `Get-MgRoleManagementDirectoryRoleDefinition` → rôles Entra ID (ce chapitre)
> - `Get-AzRoleDefinition` → rôles Azure RBAC (hors périmètre SC-300)
>
> En production, les deux systèmes se complètent : un Global Admin Entra n'est pas
> automatiquement Owner sur les subscriptions Azure — les deux périmètres sont séparés
> et doivent être audités indépendamment.

</details>

<details>
<summary>Note technique — WAM et -ContextScope Process</summary>

> Les opérations d'écriture RBAC nécessitent le scope `RoleManagement.ReadWrite.Directory`,
> bloqué par WAM sur l'app générique Microsoft Graph Command Line Tools.
> `-ContextScope Process` est requis pour bypasser le cache WAM.
> Voir note identique dans le chapitre 05_Conditional_Access — même mécanisme, même solution.

</details>

<details>
<summary>Commandes utiles en une ligne — RBAC</summary>

```powershell
# Lister tous les rôles Entra disponibles (built-in + custom)
Get-MgRoleManagementDirectoryRoleDefinition -All | Select-Object Id, DisplayName, IsBuiltIn

# Lister uniquement les rôles custom (créés par l'admin)
Get-MgRoleManagementDirectoryRoleDefinition -All |
    Where-Object { $_.IsBuiltIn -eq $false } | Select-Object Id, DisplayName

# Rechercher un rôle built-in par nom
Get-MgRoleManagementDirectoryRoleDefinition -All |
    Where-Object { $_.DisplayName -eq "Helpdesk Administrator" } | Select-Object Id, DisplayName

# Lister les assignations actives d'un rôle donné (récupérer l'ID du rôle au préalable)
Get-MgRoleManagementDirectoryRoleAssignment -All |
    Where-Object { $_.RoleDefinitionId -eq "id-du-role" } |
    Select-Object PrincipalId, RoleDefinitionId, DirectoryScopeId

# Lister toutes les assignations de rôles du tenant avec résolution des noms
Get-MgRoleManagementDirectoryRoleAssignment -All | ForEach-Object {
    $User = Get-MgUser -UserId $_.PrincipalId -ErrorAction SilentlyContinue
    $Role = Get-MgRoleManagementDirectoryRoleDefinition -UnifiedRoleDefinitionId $_.RoleDefinitionId
    [PSCustomObject]@{
        Utilisateur = if ($User) { $User.DisplayName } else { $_.PrincipalId }
        Role        = $Role.DisplayName
        Perimetre   = $_.DirectoryScopeId
    }
}

# Lister les membres d'une AU avec leur rôle scopé
Get-MgDirectoryAdministrativeUnitScopedRoleMember -AdministrativeUnitId "id-de-lau"

# Supprimer un rôle personnalisé
Remove-MgRoleManagementDirectoryRoleDefinition -UnifiedRoleDefinitionId "id-du-role"

# Supprimer une assignation de rôle
Remove-MgRoleManagementDirectoryRoleAssignment -UnifiedRoleAssignmentId "id-de-lassignation"

# Déconnecter proprement la session Graph
Disconnect-MgGraph
```

</details>

---

### 09_Audit_Transverse
* [Exo 9a : Audit MFA](./09_Audit_Transverse/exo9a-audit-mfa.ps1)
  * Objectif : Contrôler la posture MFA du tenant — utilisateurs sans MFA, méthodes enregistrées (Authenticator, SMS, FIDO2), export CSV.
  * Connexion requise : `Connect-MgGraph -Scopes "UserAuthenticationMethod.Read.All", "User.Read.All"`
  * Licence requise : Entra ID P1/P2
* [Exo 9b : Audit des Enterprise Applications](./09_Audit_Transverse/exo9b-audit-enterprise-apps.ps1)
  * Objectif : Inventorier les applications du tenant — applications Microsoft vs tierces, récemment créées, avec export CSV.
  * Connexion requise : `Connect-MgGraph -Scopes "Application.Read.All"`
* [Exo 9c : Audit des applications sans propriétaire](./09_Audit_Transverse/exo9c-audit-apps-no-owner.ps1)
  * Objectif : Identifier les applications mal gouvernées — sans owner, avec plusieurs owners, sans activité récente.
  * Connexion requise : `Connect-MgGraph -Scopes "Application.Read.All"`
* [Exo 9d : Tenant Security Snapshot](./09_Audit_Transverse/exo9d-tenant-snapshot.ps1)
  * Objectif : Mini audit IAM global — génère en une passe l'ensemble des CSV d'audit (identités, invités, groupes, licences, rôles admin, MFA, Enterprise Apps, CA) et un fichier Summary.txt avec les chiffres clés du tenant.
  * Connexion requise : `Connect-MgGraph -Scopes "User.Read.All", "Group.Read.All", "Directory.Read.All", "Policy.Read.All", "RoleManagement.Read.Directory", "UserAuthenticationMethod.Read.All", "Application.Read.All", "AuditLog.Read.All"`

<details>
<summary>Note technique — UserAuthenticationMethod et droits admin requis</summary>

> `UserAuthenticationMethod.Read.All` est un scope sensible — il expose les méthodes
> d'authentification enregistrées de tous les utilisateurs du tenant (numéros de téléphone,
> devices FIDO2, tokens OATH...). Ce scope nécessite un rôle **Authentication Administrator**
> ou **Global Admin** sur le compte connecté — un compte standard avec consentement délégué
> ne suffit pas.
>
> Sur un tenant de dev E5, le compte Global Admin dispose de ce droit sans configuration
> supplémentaire. En production, ce scope doit être consenti explicitement par un admin
> dans le portail Entra (Entra Admin Center > App registrations > API permissions).
>
> Note : `Get-MgUserAuthenticationMethod` retourne les méthodes enregistrées par utilisateur.
> Pour savoir si un utilisateur a le MFA activé, on vérifie si au moins une méthode autre que
> `#microsoft.graph.passwordAuthenticationMethod` est présente dans la liste retournée.

</details>

<details>
<summary>Note technique — périmètre du Tenant Security Snapshot (9d)</summary>

> Le Snapshot agrège les données de plusieurs chapitres en une seule passe.
> Il ne remplace pas les scripts d'audit détaillés — il donne une vue chiffrée rapide
> exploitable en 30 secondes, utile en début de mission ou en reporting hebdomadaire.
>
> Les CSV générés sont intentionnellement moins détaillés que leurs équivalents chapitres
> (pas de résolution de tous les GUIDs, pas de variantes) — l'objectif est la rapidité
> d'exécution, pas l'exhaustivité. Pour approfondir un point, se référer au script
> d'audit dédié dans le chapitre correspondant.
>
> Structure générée :
> ```
> Reports\
> ├── Identity-Audit.csv
> ├── Guest-Audit.csv
> ├── Groups-Audit.csv
> ├── Licences-Audit.csv
> ├── AdminRoles-Audit.csv
> ├── MFA-Audit.csv
> ├── EnterpriseApps-Audit.csv
> ├── ConditionalAccess-Audit.csv
> └── Summary.txt
> ```

</details>

<details>
<summary>Commandes utiles en une ligne — Audit Transverse</summary>

```powershell
# Lister les méthodes MFA enregistrées d'un utilisateur
Get-MgUserAuthenticationMethod -UserId "upn@domaine.onmicrosoft.com" |
    Select-Object Id, AdditionalProperties

# Identifier les utilisateurs sans aucune méthode MFA enregistrée
Get-MgUser -All | ForEach-Object {
    $Methods = Get-MgUserAuthenticationMethod -UserId $_.Id
    if ($Methods.Count -le 1) {  # 1 = mot de passe uniquement
        [PSCustomObject]@{ DisplayName = $_.DisplayName; UPN = $_.UserPrincipalName }
    }
}

# Lister toutes les Enterprise Applications (Service Principals)
Get-MgServicePrincipal -All | Select-Object Id, DisplayName, AppId, CreatedDateTime

# Filtrer les applications tierces (non Microsoft)
Get-MgServicePrincipal -All |
    Where-Object { $_.AppOwnerOrganizationId -ne "f8cdef31-a31e-4b4a-93e4-5f571e91255a" } |
    Select-Object DisplayName, AppId, CreatedDateTime

# Filtrer les applications Microsoft uniquement
Get-MgServicePrincipal -All |
    Where-Object { $_.AppOwnerOrganizationId -eq "f8cdef31-a31e-4b4a-93e4-5f571e91255a" } |
    Select-Object DisplayName, AppId

# Lister les owners d'une application
Get-MgServicePrincipalOwner -ServicePrincipalId "id-de-lapp" | Select-Object Id

# Identifier les applications sans owner
Get-MgServicePrincipal -All | Where-Object {
    (Get-MgServicePrincipalOwner -ServicePrincipalId $_.Id).Count -eq 0
} | Select-Object DisplayName, AppId, CreatedDateTime

# Filtrer les applications créées récemment (30 derniers jours)
$Seuil = (Get-Date).AddDays(-30)
Get-MgServicePrincipal -All |
    Where-Object { $_.CreatedDateTime -gt $Seuil } |
    Select-Object DisplayName, AppId, CreatedDateTime

# Déconnecter proprement la session Graph
Disconnect-MgGraph
```

</details>
