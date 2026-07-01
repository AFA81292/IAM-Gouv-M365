# KQL — Sentinel & Log Analytics (SC-300 / SC-401)

Requêtes KQL de révision et d'audit IAM/Gouvernance, exécutables sur la démo Microsoft Sentinel.

## Environnement

Toutes les requêtes sont testées sur la démo publique Microsoft Log Analytics :
**[https://aka.ms/lademo](https://aka.ms/lademo)**

Aucune souscription Azure requise — les données de démonstration couvrent l'ensemble des tables utilisées dans ce repo.

## Tables Sentinel utilisées

| Table | Contenu | Chapitres |
|-------|---------|-----------|
| `SigninLogs` | Connexions interactives Entra ID | 01, 02, 05 |
| `AADNonInteractiveUserSignInLogs` | Connexions non interactives (apps, tokens) | 02 |
| `AADRiskyUsers` | Utilisateurs à risque détectés par Entra ID Protection | 02, 03 |
| `AADUserRiskEvents` | Événements de risque individuels (impossible travel, leaked creds...) | 02, 03 |
| `AuditLogs` | Modifications d'objets Entra (users, groupes, rôles) | 03, 05 |
| `OfficeActivity` | Activité SharePoint, Exchange, Teams | 04, 05 |
| `CloudAppEvents` | Événements Defender for Cloud Apps | 04 |

## Index des Exercices (1 fichier = 1 exo)

### 01_Bases_KQL

* [Exo 1a : Syntaxe fondamentale](./01_Bases_KQL/exo1a-syntaxe-fondamentale.kql)
  * Objectif : Maîtriser les opérateurs de base — `where`, `project`, `extend`, `sort`, `limit`, `count`.
  * Table : `SigninLogs`

* [Exo 1b : Opérateurs de temps](./01_Bases_KQL/exo1b-operateurs-temps.kql)
  * Objectif : Filtrer par plage temporelle — `ago()`, `between()`, `startofday()`, `bin()`.
  * Table : `SigninLogs`

* [Exo 1c : Summarize et visualisation](./01_Bases_KQL/exo1c-summarize-render.kql)
  * Objectif : Agréger et visualiser — `summarize`, `count()`, `dcount()`, `render timechart`.
  * Table : `SigninLogs`

<details>
<summary>Commandes utiles en une ligne — Bases KQL</summary>

```kql
// Compter les lignes d'une table
SigninLogs | count

// Voir les colonnes disponibles
SigninLogs | getschema

// Afficher les 10 premières lignes
SigninLogs | take 10

// Filtrer sur une valeur exacte
SigninLogs | where ResultType == 0

// Filtrer sur une plage de temps
SigninLogs | where TimeGenerated > ago(7d)

// Projeter uniquement certaines colonnes
SigninLogs | project TimeGenerated, UserPrincipalName, AppDisplayName, ResultType

// Trier par date décroissante
SigninLogs | sort by TimeGenerated desc

// Compter par valeur distincte
SigninLogs | summarize NbConnexions = count() by UserPrincipalName

// Visualiser en graphique temporel
SigninLogs | summarize NbConnexions = count() by bin(TimeGenerated, 1h) | render timechart
```

</details>

---

### 02_SignIn_Logs

* [Exo 2a : Connexions échouées par utilisateur](./02_SignIn_Logs/exo2a-connexions-echouees.kql)
  * Objectif : Identifier les utilisateurs avec des échecs de connexion répétés — base d'une investigation MFA ou de compte compromis.
  * Table : `SigninLogs`

* [Exo 2b : Posture MFA — succès, bypass, absents](./02_SignIn_Logs/exo2b-posture-mfa.kql)
  * Objectif : Analyser l'état MFA des connexions — connexions avec MFA, sans MFA, MFA contourné.
  * Table : `SigninLogs`

* [Exo 2c : Connexions bloquées par Conditional Access](./02_SignIn_Logs/exo2c-ca-bloquees.kql)
  * Objectif : Identifier les connexions bloquées par les politiques CA — valider l'efficacité des règles déployées.
  * Table : `SigninLogs`

* [Exo 2d : Connexions depuis pays inhabituels](./02_SignIn_Logs/exo2d-pays-inhabituels.kql)
  * Objectif : Détecter les connexions depuis des localisations géographiques anormales — signal de compromission potentielle.
  * Table : `SigninLogs`

* [Exo 2e : Détection brute force](./02_SignIn_Logs/exo2e-brute-force.kql)
  * Objectif : Identifier les attaques par force brute — seuil d'échecs consécutifs sur une courte fenêtre temporelle.
  * Table : `SigninLogs`

* [Exo 2f : Connexions non interactives suspectes](./02_SignIn_Logs/exo2f-connexions-non-interactives.kql)
  * Objectif : Auditer les connexions silencieuses — apps et tokens qui se reconnectent sans MFA en arrière-plan, écarts avec les connexions interactives.
  * Table : `AADNonInteractiveUserSignInLogs`

* [Exo 2g : Utilisateurs à risque — Entra ID Protection](./02_SignIn_Logs/exo2g-utilisateurs-a-risque.kql)
  * Objectif : Identifier les utilisateurs signalés à risque par Entra ID Protection — leaked credentials, impossible travel, connexions anonymes.
  * Tables : `AADRiskyUsers`, `AADUserRiskEvents`

<details>
<summary>Commandes utiles en une ligne — SignIn Logs</summary>

```kql
// Connexions réussies uniquement (ResultType = 0)
SigninLogs | where ResultType == 0 | project TimeGenerated, UserPrincipalName, AppDisplayName

// Connexions échouées uniquement (ResultType != 0)
SigninLogs | where ResultType != 0 | project TimeGenerated, UserPrincipalName, ResultType, ResultDescription

// Codes d'erreur courants :
//   0     → Succès
//   50074 → MFA requis mais non complété
//   50076 → MFA requis par Conditional Access
//   53003 → Bloqué par Conditional Access
//   50126 → Mot de passe incorrect
//   50057 → Compte désactivé

// Connexions avec MFA réussi
SigninLogs | where AuthenticationRequirement == "multiFactorAuthentication"
           | where ResultType == 0

// Connexions sans MFA (singleFactorAuthentication)
SigninLogs | where AuthenticationRequirement == "singleFactorAuthentication"

// Top 10 utilisateurs par volume de connexions
SigninLogs | summarize NbConnexions = count() by UserPrincipalName
           | top 10 by NbConnexions

// Connexions par pays
SigninLogs | summarize count() by Location | sort by count_ desc

// Politiques CA appliquées sur une connexion
SigninLogs | project TimeGenerated, UserPrincipalName, ConditionalAccessPolicies
           | mv-expand ConditionalAccessPolicies
           | evaluate bag_unpack(ConditionalAccessPolicies)
```

</details>

---

### 03_Audit_Logs_Entra

* [Exo 3a : Modifications de rôles administratifs](./03_Audit_Logs_Entra/exo3a-modifications-roles.kql)
  * Objectif : Tracer les assignations et révocations de rôles Entra — qui a assigné quoi à qui et quand.
  * Table : `AuditLogs`

* [Exo 3b : Créations et suppressions de comptes](./03_Audit_Logs_Entra/exo3b-cycle-vie-comptes.kql)
  * Objectif : Suivre le cycle de vie des identités — créations, désactivations, suppressions, restaurations.
  * Table : `AuditLogs`

* [Exo 3c : Modifications de groupes et memberships](./03_Audit_Logs_Entra/exo3c-modifications-groupes.kql)
  * Objectif : Auditer les changements de membership — ajouts/retraits de membres, créations/suppressions de groupes.
  * Table : `AuditLogs`

* [Exo 3d : Activations PIM](./03_Audit_Logs_Entra/exo3d-activations-pim.kql)
  * Objectif : Tracer les activations de rôles via PIM — qui a activé quel rôle, avec quelle justification, pendant combien de temps.
  * Table : `AuditLogs`

* [Exo 3e : Réponse administrative aux risques détectés](./03_Audit_Logs_Entra/exo3e-reponse-administrative-risque.kql)
  * Objectif : Auditer le PROCESSUS de traitement du risque, pas sa détection — un admin a-t-il agi sur un utilisateur signalé à risque, en combien de temps, ou jamais. Complémentaire à l'exo 2g (détection).
  * Tables : `AuditLogs` (croisement ponctuel avec `AADRiskyUsers`)

<details>
<summary>Commandes utiles en une ligne — Audit Logs Entra</summary>

```kql
// Voir toutes les catégories d'opérations disponibles
AuditLogs | summarize count() by Category | sort by count_ desc

// Voir toutes les opérations disponibles
AuditLogs | summarize count() by OperationName | sort by count_ desc

// Filtrer sur une opération spécifique
AuditLogs | where OperationName == "Add member to role"

// Extraire l'acteur (qui a fait l'action)
AuditLogs | extend Acteur = tostring(InitiatedBy.user.userPrincipalName)
           | project TimeGenerated, OperationName, Acteur, Result

// Extraire la cible (sur qui/quoi l'action a porté)
AuditLogs | extend Cible = tostring(TargetResources[0].userPrincipalName)
           | project TimeGenerated, OperationName, Cible

// Filtrer sur les opérations de rôle uniquement
AuditLogs | where Category == "RoleManagement"

// Filtrer sur les opérations PIM
AuditLogs | where Category == "RoleManagement"
           | where OperationName contains "PIM"

// Filtrer sur les opérations utilisateur
AuditLogs | where Category == "UserManagement"

// Filtrer sur les opérations de groupe
AuditLogs | where Category == "GroupManagement"
```

</details>

---

### 04_Office365_Purview

* [Exo 4a : Activité SharePoint — accès externes et partages](./04_Office365_Purview/exo4a-sharepoint-partages.kql)
  * Objectif : Identifier les partages externes SharePoint — fichiers partagés hors organisation, liens anonymes.
  * Table : `OfficeActivity`

* [Exo 4b : Activité Exchange — règles de transfert suspectes](./04_Office365_Purview/exo4b-exchange-transferts.kql)
  * Objectif : Détecter les règles de transfert email vers l'extérieur — vecteur classique d'exfiltration de données.
  * Table : `OfficeActivity`

* [Exo 4c : Activité Teams — invités et canaux externes](./04_Office365_Purview/exo4c-teams-invites.kql)
  * Objectif : Auditer les accès invités Teams — qui accède à quels canaux, depuis quels tenants externes.
  * Table : `OfficeActivity`

* [Exo 4d : Alertes DLP déclenchées (Purview)](./04_Office365_Purview/exo4d-alertes-dlp.kql)
  * Objectif : Analyser les déclenchements de politiques DLP — types de données sensibles détectées, utilisateurs concernés.
  * Table : `OfficeActivity`

<details>
<summary>Commandes utiles en une ligne — Office 365 / Purview</summary>

```kql
// Voir toutes les opérations OfficeActivity disponibles
OfficeActivity | summarize count() by Operation | sort by count_ desc

// Filtrer sur SharePoint uniquement
OfficeActivity | where OfficeWorkload == "SharePoint"

// Filtrer sur Exchange uniquement
OfficeActivity | where OfficeWorkload == "Exchange"

// Filtrer sur Teams uniquement
OfficeActivity | where OfficeWorkload == "MicrosoftTeams"

// Partages externes SharePoint
OfficeActivity | where Operation == "SharingInvitationCreated"
               | where OfficeWorkload == "SharePoint"
               | project TimeGenerated, UserId, TargetUserOrGroupName, OfficeObjectId

// Règles de transfert Exchange
OfficeActivity | where Operation == "New-InboxRule"
               | project TimeGenerated, UserId, Parameters

// Accès invités Teams
OfficeActivity | where OfficeWorkload == "MicrosoftTeams"
               | where Members has "Guest"

// Alertes DLP
OfficeActivity | where Operation == "DLPRuleMatch"
               | project TimeGenerated, UserId, PolicyDetails, SensitiveInfoTypeData
```

</details>

---

### 05_Requetes_IAM_Terrain

* [Exo 5a : Rapport comptes inactifs](./05_Requetes_IAM_Terrain/exo5a-comptes-inactifs.kql)
  * Objectif : Identifier les comptes sans connexion depuis 90 jours — pendant KQL de l'exo PowerShell 1l.
  * Table : `SigninLogs`

* [Exo 5b : Rapport invités sans activité récente](./05_Requetes_IAM_Terrain/exo5b-invites-inactifs.kql)
  * Objectif : Identifier les comptes invités inactifs — pendant KQL de l'exo PowerShell 1k.
  * Table : `SigninLogs`

* [Exo 5c : Inventaire admins globaux et dernière connexion](./05_Requetes_IAM_Terrain/exo5c-admins-derniere-connexion.kql)
  * Objectif : Croiser les activations PIM avec les connexions admin — qui a utilisé ses droits élevés et quand.
  * Tables : `AuditLogs`, `SigninLogs`

* [Exo 5d : Dashboard posture sécurité](./05_Requetes_IAM_Terrain/exo5d-dashboard-posture.kql)
  * Objectif : Requête multi-table pour une vue de posture globale — pendant KQL du Tenant Security Snapshot (exo PowerShell 9d).
  * Tables : `SigninLogs`, `AuditLogs`, `OfficeActivity`

<details>
<summary>Commandes utiles en une ligne — Requêtes IAM Terrain</summary>

```kql
// Dernière connexion par utilisateur
SigninLogs | where ResultType == 0
           | summarize DerniereConnexion = max(TimeGenerated) by UserPrincipalName
           | sort by DerniereConnexion asc

// Comptes sans connexion depuis 90 jours
SigninLogs | where ResultType == 0
           | summarize DerniereConnexion = max(TimeGenerated) by UserPrincipalName
           | where DerniereConnexion < ago(90d)

// Invités uniquement (UPN contient #EXT#)
SigninLogs | where UserPrincipalName contains "#EXT#"
           | summarize DerniereConnexion = max(TimeGenerated) by UserPrincipalName

// Activations PIM des 30 derniers jours
AuditLogs | where TimeGenerated > ago(30d)
           | where Category == "RoleManagement"
           | where OperationName == "Add member to role (PIM activation)"
           | extend Acteur = tostring(InitiatedBy.user.userPrincipalName)
           | extend Role = tostring(TargetResources[0].displayName)
           | project TimeGenerated, Acteur, Role

// Join SigninLogs + AuditLogs sur UPN
AuditLogs | where Category == "RoleManagement"
           | extend AdminUPN = tostring(InitiatedBy.user.userPrincipalName)
           | join kind=leftouter (
               SigninLogs | where ResultType == 0
               | summarize DerniereConnexion = max(TimeGenerated) by UserPrincipalName
             ) on $left.AdminUPN == $right.UserPrincipalName
           | project AdminUPN, OperationName, DerniereConnexion

// Volume d'alertes DLP par utilisateur sur 30 jours
OfficeActivity | where TimeGenerated > ago(30d)
               | where Operation == "DLPRuleMatch"
               | summarize NbAlertes = count() by UserId
               | sort by NbAlertes desc
```

</details>

---

## Notes techniques

<details>
<summary>ResultType — codes d'erreur SigninLogs les plus utiles</summary>

| Code | Signification | Contexte IAM |
|------|--------------|--------------|
| `0` | Succès | Connexion normale |
| `50074` | MFA requis, non complété | User sans MFA enregistré |
| `50076` | MFA requis par CA | Politique CA active |
| `53003` | Bloqué par CA | Politique de blocage active |
| `50126` | Mot de passe incorrect | Tentative échouée / brute force |
| `50057` | Compte désactivé | Offboarding non complété |
| `50055` | Mot de passe expiré | Politique de rotation |
| `70011` | Scope OAuth invalide | Problème app registration |
| `90095` | Interruption admin requise | Consentement admin nécessaire |

</details>

<details>
<summary>AuthenticationRequirement — valeurs possibles SigninLogs</summary>

```kql
// Les deux valeurs possibles :
//   "singleFactorAuthentication" → connexion sans MFA
//   "multiFactorAuthentication"  → MFA requis et complété

// Répartition MFA vs sans MFA sur 7 jours
SigninLogs | where TimeGenerated > ago(7d)
           | where ResultType == 0
           | summarize count() by AuthenticationRequirement
           | render piechart
```

</details>

<details>
<summary>Extraction de champs imbriqués — pattern récurrent</summary>

```kql
// AuditLogs : extraire l'acteur (initiateur de l'action)
AuditLogs | extend Acteur = tostring(InitiatedBy.user.userPrincipalName)

// AuditLogs : extraire la cible (objet modifié)
AuditLogs | extend Cible = tostring(TargetResources[0].userPrincipalName)

// AuditLogs : extraire le displayName de la cible (ex : nom du rôle assigné)
AuditLogs | extend NomCible = tostring(TargetResources[0].displayName)

// AuditLogs : extraire une propriété modifiée (ex : nouvelle valeur d'un attribut)
AuditLogs | extend NouvelleValeur = tostring(TargetResources[0].modifiedProperties[0].newValue)

// SigninLogs : extraire le résultat d'une politique CA spécifique
SigninLogs | mv-expand ConditionalAccessPolicies
           | extend NomPolitique = tostring(ConditionalAccessPolicies.displayName)
           | extend ResultatPolitique = tostring(ConditionalAccessPolicies.result)
```

</details>

<details>
<summary>Différence SigninLogs vs AADNonInteractiveUserSignInLogs</summary>

```kql
// SigninLogs : connexions interactives (utilisateur devant un écran)
// → navigateur, appli desktop, mobile avec prompt de connexion

// AADNonInteractiveUserSignInLogs : connexions silencieuses (apps, refresh tokens)
// → renouvellement de token, connexion app-to-app, Outlook en arrière-plan

// Les deux tables ont le même schéma — les requêtes sont transposables
// Exemple : connexions silencieuses échouées
AADNonInteractiveUserSignInLogs
| where ResultType != 0
| summarize NbEchecs = count() by UserPrincipalName, AppDisplayName
| sort by NbEchecs desc
```

</details>
