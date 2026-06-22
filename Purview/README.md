# Microsoft Purview - Protection de l'Information (SC-401)

Notes de révision et scripts de validation pour les modules de gouvernance et conformité Microsoft.

## Prérequis

Le module ExchangeOnlineManagement doit être installé :
```powershell
Install-Module ExchangeOnlineManagement -Scope CurrentUser
```

Connexion à Security & Compliance PowerShell (vecteur principal pour labels, DLP, rétention, audit) :
```powershell
Connect-IPPSSession -UserPrincipalName GeptorAdmin@0n4mg.onmicrosoft.com
```

Certains exercices (Message Encryption, Transport Rules) nécessitent également une connexion Exchange Online :
```powershell
Connect-ExchangeOnline -UserPrincipalName GeptorAdmin@0n4mg.onmicrosoft.com
```

## Index des Exercices (1 fichier = 1 exo)

### 01_Data_Classification
* [Exo 1a : Exploration des SIT built-in](./01_Data_Classification/exo1a-explore-sit-builtin.ps1)
  * Objectif : Lister les Sensitive Information Types natifs, filtrer par catégorie, afficher le détail d'un SIT cible.
* [Exo 1b : Création d'un SIT personnalisé par regex](./01_Data_Classification/exo1b-create-custom-sit-regex.ps1)
  * Objectif : Créer un SIT custom basé sur un pattern regex — numéro de badge interne fictif type `GCORP-XXXXX`.
* [Exo 1c : Création d'un SIT par Document Fingerprinting](./01_Data_Classification/exo1c-create-sit-fingerprint.ps1)
  * Objectif : Générer une empreinte documentaire depuis un template RH fictif et l'enregistrer comme SIT.
* [Exo 1d : Audit des SIT du tenant](./01_Data_Classification/exo1d-audit-sit.ps1)
  * Objectif : Lister et distinguer les SIT built-in vs custom, vérifier la présence et l'état des SIT créés.

<details>
<summary>Note technique — EDM et Trainable Classifiers non couverts en script</summary>

> EDM (Exact Data Match) et les Trainable Classifiers ne sont pas couverts en script.
> EDM nécessite un pipeline d'upload de données sensibles (hash, schéma, fichier source) dont le temps
> de propagation dépasse plusieurs heures et dont la surface PowerShell est essentiellement un wrapper
> autour d'appels Graph non documentés publiquement. Les Trainable Classifiers sont intégralement GUI —
> aucune cmdlet de création n'est exposée. Ces deux fonctionnalités sont gérées via le portail Purview.

</details>

<details>
<summary>Commandes utiles en une ligne — Data Classification</summary>

```powershell
# Lister tous les SIT disponibles (built-in + custom)
Get-DlpSensitiveInformationType | Select-Object Name, Publisher, Type | Sort-Object Type

# Filtrer les SIT custom uniquement (créés par l'admin)
Get-DlpSensitiveInformationType | Where-Object { $_.Publisher -ne "Microsoft Corporation" } | Select-Object Name, Publisher, Type

# Afficher le détail complet d'un SIT spécifique
Get-DlpSensitiveInformationType -Identity "Credit Card Number" | Format-List

# Lister les rule packages custom
Get-DlpSensitiveInformationTypeRulePackage | Where-Object { $_.Name -ne "Microsoft Rule Package" } | Select-Object Name, RuleCollectionName

# Supprimer un SIT custom
Remove-DlpSensitiveInformationType -Identity "Nom-du-SIT-custom"

# Supprimer un rule package custom complet
Remove-DlpSensitiveInformationTypeRulePackage -Identity "Nom-du-package"

# Supprimer un SIT fingerprint
Remove-DlpSensitiveInformationType -Identity "Nom-du-SIT-fingerprint"

# Fermer proprement toutes les sessions PowerShell
Get-PSSession | Remove-PSSession
```

</details>

---

### 02_Sensitivity_Labels
* [Exo 2a : Création d'un label group et de son premier sublabel](./02_Sensitivity_Labels/exo2a-create-label-group.ps1)
  * Objectif : Créer le label group `NormandySR2 - Confidentiel` et son sublabel `NormandySR2 - Interne` — démonstration que la création de label groups, contrairement à ce que documente Microsoft Learn, est intégralement scriptable via `-AdvancedSettings`.
* [Exo 2b : Chiffrement admin-defined sur un sublabel](./02_Sensitivity_Labels/exo2b-sublabel-encryption.ps1)
  * Objectif : Ajouter le chiffrement RMS sur `NormandySR2 - Interne` — permissions définies par l'admin (Co-Owner, Co-Author).
  * Licence requise : Microsoft Purview Information Protection (inclus E5).
* [Exo 2c : Création d'un sublabel Do Not Forward](./02_Sensitivity_Labels/exo2c-create-sublabel-dnf.ps1)
  * Objectif : Créer le sublabel `NormandySR2 - Externe` avec chiffrement Do Not Forward — protection des emails envoyés hors du tenant.
  * Licence requise : Microsoft Purview Information Protection (inclus E5).
* [Exo 2d : Publication des labels via une Label Policy](./02_Sensitivity_Labels/exo2d-publish-label-policy.ps1)
  * Objectif : Publier le label group et ses sublabels vers un groupe de test via une Label Policy.
  * Licence requise : Microsoft Purview Information Protection (inclus E5).
* [Exo 2e : Politique d'auto-labeling côté service](./02_Sensitivity_Labels/exo2e-create-autolabel-policy.ps1)
  * Objectif : Créer une politique d'auto-labeling sur Exchange — détection automatique du SIT custom créé en 1b et application du label `NormandySR2 - Interne` sans intervention utilisateur.
  * Licence requise : Microsoft Purview Information Protection (inclus E5).
* [Exo 2f : Audit des labels et policies](./02_Sensitivity_Labels/exo2f-audit-labels.ps1)
  * Objectif : Lister les labels, sublabels, policies de publication et policies d'auto-labeling — état complet de la configuration Information Protection du tenant.

<details>
<summary>Note technique — label group, islabelgroup vs isparent</summary>

> Un label group n'est pas un objet distinct côté API Purview —
> c'est un label dont la propriété `islabelgroup` est positionnée à `True` via
> `-AdvancedSettings`. La propriété `isparent`, elle, n'est PAS settable manuellement :
> elle est calculée automatiquement par le service dès qu'un sublabel référence ce
> label comme parent via `-ParentId`. Testé et confirmé par investigation directe
> (tentatives de force via `-AdvancedSettings` et `Set-Label` post-création, sans
> succès — la documentation Microsoft Learn sur ce point est ambiguë/incomplète).

</details>

<details>
<summary>Commandes utiles en une ligne — Sensitivity Labels</summary>

```powershell
# Lister tous les labels (groups + sublabels)
Get-Label | Select-Object Name, DisplayName, ParentId | Sort-Object ParentId

# Lister uniquement les label groups
Get-Label | Where-Object { $_.Settings["islabelgroup"] -eq "True" } | Select-Object Name, DisplayName

# Lister les sublabels d'un label group (récupérer le Guid via Get-Label)
Get-Label | Where-Object { $_.ParentId -eq "guid-du-group" } | Select-Object Name, DisplayName

# Afficher le détail complet d'un label avec ses propriétés de marquage/chiffrement
Get-Label -Identity "Nom-du-label" -IncludeDetailedLabelActions | Format-List

# Supprimer un sublabel (supprimer les sublabels avant le label group parent)
Remove-Label -Identity "Nom-du-sublabel"

# Lister toutes les Label Policies
Get-LabelPolicy | Select-Object Name, Labels, ExchangeLocation

# Lister toutes les politiques d'auto-labeling
Get-AutoSensitivityLabelPolicy | Select-Object Name, Mode, AutoLabelingWorkload

# Fermer proprement toutes les sessions PowerShell
Get-PSSession | Remove-PSSession
```

</details>

---

### 03_Message_Encryption
* [Exo 3a : Vérification de l'état IRM sur le tenant](./03_Message_Encryption/exo3a-check-irm.ps1)
  * Objectif : Contrôler l'état d'Azure RMS et d'IRM — prérequis indispensable avant tout exercice de chiffrement de messages.
  * Connexion requise : `Connect-ExchangeOnline`
* [Exo 3b : Transport Rule OME — chiffrement par mot-clé](./03_Message_Encryption/exo3b-transport-rule-encrypt-only.ps1)
  * Objectif : Créer une règle de flux qui applique automatiquement le template de chiffrement simple (résolu dynamiquement — `Chiffrer`/`Encrypt` selon la langue du tenant, pas un nom en dur) sur les mails sortants contenant le mot-clé `CONFIDENTIEL`.
  * Connexion requise : `Connect-ExchangeOnline`
  * Licence requise : Microsoft Purview Message Encryption (inclus E3/E5)
* [Exo 3c : DLP Compliance Rule — chiffrement par classification (SIT)](./03_Message_Encryption/exo3c-transport-rule-classification.ps1)
  * Objectif : Appliquer le même chiffrement que 3b, mais déclenché par la détection du SIT custom `Cerberus Corp - Numéro de Badge Interne` (créé en 1b) via une **DLP Compliance Rule** (`EncryptRMSTemplate`) — `MessageContainsDataClassifications` est déprécié côté Transport Rules depuis fin 2023, ce mécanisme est l'alternative supportée.
  * Connexion requise : `Connect-IPPSSession` (création de la policy/rule, vérification du SIT — cœur du script) **et** `Connect-ExchangeOnline` (uniquement pour résoudre le nom du template via `Get-RMSTemplate`)
  * Licence requise : Microsoft Purview Message Encryption (inclus E3/E5)
* [Exo 3d : Transport Rule OME — Do Not Forward hors tenant](./03_Message_Encryption/exo3d-transport-rule-dnf.ps1)
  * Objectif : Créer une règle de flux qui applique `Do Not Forward` sur les mails envoyés vers des destinataires extérieurs au tenant.
  * Connexion requise : `Connect-ExchangeOnline`
  * Licence requise : Microsoft Purview Message Encryption (inclus E3/E5)
* [Exo 3e : Message Encryption — Audit unifié du chiffrement automatique du tenant](./03_Message_Encryption/exo3e-audit-encryption.ps1)
  * Objectif : Lister les Transport Rules (3b, 3d) **et** les DLP Compliance Rules (3c) du tenant, filtrer celles qui portent une action de chiffrement, afficher leur état et leur priorité — deux types d'objets distincts à interroger séparément depuis la dépréciation décrite ci-dessous.
  * Connexion requise : `Connect-ExchangeOnline` **et** `Connect-IPPSSession`

<details>
<summary>Note technique — trois pièges d'architecture rencontrés sur ce chapitre</summary>

> 1. **Noms de templates localisés.** `Get-RMSTemplate` retourne des noms selon la langue
>    du tenant (`Chiffrer`/`Ne pas transférer` en FR, pas `Encrypt`/`Do Not Forward`). Les
>    scripts résolvent le nom dynamiquement (filtre EN+FR) plutôt que de le fixer en dur.
> 2. **`MessageContainsDataClassifications` est déprécié dans les Transport Rules** depuis
>    novembre 2023 (aka.ms/NoDLPinETRs). Le chiffrement déclenché par SIT (3c) utilise donc
>    une **DLP Compliance Rule** (`EncryptRMSTemplate`), pas une Transport Rule — objet
>    différent, à interroger séparément en audit (3e).
> 3. **Le backend DLP n'accepte pas toujours le nom localisé** que `Get-RMSTemplate`
>    (Exchange Online) a pourtant validé — `EncryptRMSTemplate` semble attendre le nom
>    canonique anglais (`Encrypt`) même sur un tenant FR. 3c teste plusieurs candidats
>    avant d'abandonner plutôt que de fixer une seule valeur supposée.
> 
> Conséquence pratique : ce chapitre combine deux surfaces de cmdlets — Exchange Online
> (Transport Rules, résolution de template) et Security & Compliance (SIT, DLP Rules).
> `Connect-IPPSSession` et `Connect-ExchangeOnline` sont tous les deux nécessaires dès
> qu'un exo touche les deux mondes (cas de 3c).
> 
</details>

<details>
<summary>Note technique — Advanced Message Encryption (AME)</summary>

> AME ajoute deux capacités au-dessus de l'OME standard : le **branding personnalisé** du portail
> de lecture (logo, couleurs, message d'accueil) et la **révocation de message** — possibilité de
> couper l'accès à un mail déjà envoyé, à condition que le destinataire le lise via le portail web OME
> (pas via un client Outlook natif qui aurait déchiffré le message localement).

> En production, AME est pertinent dans deux scénarios : communications client avec charte graphique
> imposée (secteur bancaire, juridique) et gestion de crise post-envoi (mauvais destinataire,
> fuite de données — on révoque l'accès avant que le mail soit lu).

> AME nécessite une licence **E5 ou l'add-on Microsoft Purview Message Encryption**. Les cmdlets
> existent (`New-OMEConfiguration`, `Set-OMEConfiguration`) mais le résultat n'est vérifiable
> qu'en envoyant un vrai mail et en inspectant le portail de lecture — hors périmètre d'un
> exercice PowerShell autonome sur tenant dev. Configuration via :
> **Exchange Admin Center > Mail flow > Message encryption**.

</details>

<details>
<summary>Note technique — chevauchement label / DLP rule sur un même SIT</summary>

> Le SIT `Cerberus Corp - Numéro de Badge Interne` (créé en 1b) déclenche désormais deux
> mécanismes indépendants : l'auto-labeling de l'exo 2e (qui applique un label potentiellement
> chiffrant) et la DLP Compliance Rule de l'exo 3c (qui applique un template RMS directement).
> Les deux peuvent s'exécuter sur le même message. Ce n'est pas un défaut de configuration —
> c'est un point réel de précédence à connaître en environnement de production, documenté ici
> plutôt que découvert en audit.

</details>

<details>
<summary>Commandes utiles en une ligne — Message Encryption</summary>

```powershell
# Vérifier l'état IRM complet du tenant
Get-IRMConfiguration | Format-List

# Lister les templates RMS disponibles (noms localisés selon la langue du tenant)
Get-RMSTemplate | Select-Object Name, Description, Guid

# Lister toutes les Transport Rules par priorité (chiffrement par mot-clé : 3b, 3d)
Get-TransportRule | Select-Object Name, Priority, State | Sort-Object Priority

# Filtrer les Transport Rules avec une action OME (chiffrement appliqué)
Get-TransportRule | Where-Object {
    $_.ApplyRightsProtectionTemplate -ne $null
} | Select-Object Name, State, Priority

# Lister les DLP Compliance Policies (chiffrement par classification : 3c)
Get-DlpCompliancePolicy | Select-Object Name, Mode, Enabled

# Lister les DLP Compliance Rules d'une policy donnée
Get-DlpComplianceRule -Policy "Nom-de-la-policy" | Select-Object Name, Disabled

# Filtrer les DLP rules qui appliquent un chiffrement RMS
Get-DlpComplianceRule | Where-Object { $_.EncryptRMSTemplate } |
    Select-Object Name, EncryptRMSTemplate

# Vérifier qu'un SIT custom existe (nécessite Connect-IPPSSession)
Get-DlpSensitiveInformationType -Identity "Nom-du-SIT" | Format-List

# Repasser une DLP policy en mode test sans la supprimer
Set-DlpCompliancePolicy -Identity "Nom-de-la-policy" -Mode TestWithNotifications

# Désactiver une Transport Rule sans la supprimer
Disable-TransportRule -Identity "Nom-de-la-rule"

# Supprimer une DLP rule PUIS sa policy (ordre obligatoire — la rule doit être supprimée
# avant la policy parente, même logique que les sublabels avant un label group)
Remove-DlpComplianceRule -Identity "Nom-de-la-rule" -Confirm:$false
Remove-DlpCompliancePolicy -Identity "Nom-de-la-policy" -Confirm:$false

# Supprimer une Transport Rule
Remove-TransportRule -Identity "Nom-de-la-rule" -Confirm:$false

# Fermer proprement toutes les sessions (Exchange Online ET Security & Compliance)
Get-PSSession | Remove-PSSession
```

</details>

---

### 04_DLP
* [Exo 4a : DLP policy simple — protection numéros de CB](./04_DLP/exo4a-dlp-policy-credit-card.ps1)
  * Objectif : Créer une DLP policy ciblant Exchange, SharePoint et OneDrive, déclenchée par la détection de numéros de carte bancaire (SIT built-in `Credit Card Number`), en mode `TestWithNotifications` — aucun blocage, les violations sont journalisées et des rapports d'incident sont générés.
  * Connexion requise : `Connect-IPPSSession`
  * Licence requise : Microsoft Purview DLP (inclus E3/E5)
* [Exo 4b : DLP policy avec règle de blocage et seuil](./04_DLP/exo4b-dlp-policy-block-rule.ps1)
  * Objectif : Créer une DLP policy distincte avec une règle à seuil (1+ occurrence de CB), action blocage actif + notification utilisateur + rapport d'incident — démonstration du passage d'une posture de détection à une posture d'enforcement.
  * Connexion requise : `Connect-IPPSSession`
  * Licence requise : Microsoft Purview DLP (inclus E3/E5)
* [Exo 4c : DLP policy basée sur un label de sensibilité](./04_DLP/exo4c-dlp-policy-sensitivity-label.ps1)
  * Objectif : Créer une DLP policy qui bloque le partage externe des fichiers portant le label `NormandySR2 - Confidentiel` ou ses sublabels — démonstration du couplage DLP / Sensitivity Labels comme couche de défense en profondeur.
  * Connexion requise : `Connect-IPPSSession`
  * Licence requise : Microsoft Purview DLP + Microsoft Purview Information Protection (inclus E5)
* [Exo 4d : Cycle de vie d'une DLP policy](./04_DLP/exo4d-dlp-policy-lifecycle.ps1)
  * Objectif : Démontrer le cycle `TestWithNotifications` → `Enable` (enforcement réel) → retour `Test`, sur une policy dédiée et autoportée (`DLP-Cerberus-LifecycleDemo`) — ne dépend pas de l'état laissé par 4a/4b/4c, donc rejouable indépendamment.
  * Connexion requise : `Connect-IPPSSession`
* [Exo 4e : Audit des DLP policies du tenant](./04_DLP/exo4e-audit-dlp.ps1)
  * Objectif : Lister l'ensemble des DLP policies, filtrer par mode, afficher les règles associées et leur état — vue d'ensemble de la posture DLP du tenant.
  * Connexion requise : `Connect-IPPSSession`

<details>
<summary>Note technique — pièges de syntaxe sur l'API REST Purview v3 (module >= 3.x)</summary>

Deux erreurs courantes rencontrées lors de la création de règles DLP par script :

1. **Clés de la hashtable SIT en minuscules strictes.** `-ContentContainsSensitiveInformation`
   attend un tableau de hashtables avec les clés `name`, `mincount`, `minconfidence` —
   tout en minuscules, valeurs numériques passées comme strings (`"1"`, `"75"`).
   Les clés PascalCase (`Name`, `MinCount`) documentées sur Microsoft Learn sont rejetées
   avec `InvalidContentContainsSensitiveInformationException`.

2. **`-NotifyUser` : `"LastModifier"`, pas `"LastModifiedBy"`.** La documentation
   Microsoft Learn indique `"LastModifiedBy"` — la valeur réellement acceptée par
   l'API REST v3 est `"LastModifier"` (sans "By"). L'erreur retournée est
   `InvalidSmtpAddressInNotifyUserActionException` avec la liste des valeurs valides :
   `Owner`, `LastModifier`, `SiteAdmin`, ou une adresse SMTP explicite.

</details>

<details>
<summary>Note technique — piège -AdvancedRule pour une condition basée sur un label (exo 4c)</summary>

> Il n'existe **pas** de paramètre `-ContentContainsSensitiveLabel` sur `New-DlpComplianceRule`
> — première erreur rencontrée, un nom halluciné par analogie avec `-ContentContainsSensitiveInformation`
> (qui, lui, existe mais seulement pour une condition SIT simple à une valeur). Dès qu'on veut une
> logique de groupe (plusieurs labels en OR), il faut passer par `-AdvancedRule` en JSON brut, avec
> chaque label déclaré comme `{name = "<GUID>"; type = "Sensitivity"}` dans un bloc
> `Condition.SubConditions[].Value[].groups[].labels[]`.
> 
> Deuxième piège, une fois le JSON de base fonctionnel : `-BlockAccess` combiné à un blocage externe
> (`BlockAccessScope PerUser`) **rejette la règle à la création** si `-AccessScope NotInOrganization`
> est passé en paramètre séparé du cmdlet. Le moteur DLP exige que cette condition soit elle-même
> encodée **dans** le JSON, comme un second `SubConditions` au même niveau que le bloc labels,
> relié par `Operator: "And"` — pas en paramètre externe. Message d'erreur obtenu :
> `"you must have 'Content is shared with people outside your organization' as the first condition
> along with operator 'AND' with other conditions or groups in your rule"`.
> 
> Conséquence pratique : dès qu'une condition DLP combine plusieurs critères avec une logique
> explicite (labels en OR, label + accès externe en AND, exceptions), réflexe direct vers
> `-AdvancedRule` + hashtable PowerShell + `ConvertTo-Json -Depth 100` — ne jamais chercher de
> paramètre nommé "intuitivement" pour ce niveau de complexité.

</details>

<details>
<summary>Note technique — Endpoint DLP et Adaptive Protection non couverts en script</summary>

> Ces deux fonctionnalités sont couvertes en cours (sections 6 et 5 du SC-401) mais
> ne sont pas scriptables de manière utile sur un tenant dev sans infrastructure.
> 
> **Endpoint DLP** nécessite des devices Windows 10/11 onboardés dans Microsoft Defender
> for Endpoint (MDE). Sans machine enrôlée dans MDE, les policies Endpoint DLP sont
> créables via PowerShell (`DeviceDlpRestrictions` comme workload) mais ne déclenchent
> rien — aucune activité endpoint à surveiller. Sur un tenant dev sans VM jointe au
> domaine et onboardée dans MDE, l'exercice se résume à créer un objet vide.
> Configuration et monitoring : **Microsoft Purview portal > Data loss prevention >
> Endpoint DLP settings**.
> 
> **Adaptive Protection** couple DLP et Insider Risk Management — le niveau de risque
> d'un utilisateur (calculé par IRM) fait varier dynamiquement les règles DLP qui
> s'appliquent à lui. Requires : licence E5 Compliance ou E5 Security + au moins une
> politique IRM active avec des alertes. Sans utilisateurs réels générant des signaux
> de risque (exfiltration, téléchargement massif, etc.), la fonctionnalité reste
> théorique. Configuration : **Microsoft Purview portal > Insider Risk Management >
> Adaptive Protection**.

</details>

<details>
<summary>Commandes utiles en une ligne — DLP</summary>

```powershell
# Lister toutes les DLP policies avec leur mode
Get-DlpCompliancePolicy | Select-Object Name, Mode, Enabled | Sort-Object Name

# Filtrer les policies en mode Enable (enforcement actif)
Get-DlpCompliancePolicy | Where-Object { $_.Mode -eq "Enable" } | Select-Object Name, Mode

# Filtrer les policies en mode Test (détection uniquement)
Get-DlpCompliancePolicy | Where-Object { $_.Mode -like "Test*" } | Select-Object Name, Mode

# Lister les règles d'une policy spécifique
Get-DlpComplianceRule -Policy "Nom-de-la-policy" | Select-Object Name, Disabled, BlockAccess

# Inspecter le JSON brut d'une règle complexe (AdvancedRule) — utile pour relire
# la logique d'une condition label/groupe sans repasser par le script qui l'a créée
Get-DlpComplianceRule -Identity "Nom-de-la-règle" | Select-Object -ExpandProperty AdvancedRule

# Lister toutes les règles de toutes les policies (vue globale)
Get-DlpCompliancePolicy | ForEach-Object {
    $PolicyName = $_.Name
    Get-DlpComplianceRule -Policy $PolicyName |
        Select-Object @{N="Policy";E={$PolicyName}}, Name, Disabled, BlockAccess
}

# Passer une policy en mode Enable (enforcement réel)
Set-DlpCompliancePolicy -Identity "Nom-de-la-policy" -Mode Enable

# Repasser une policy en mode Test sans notification
Set-DlpCompliancePolicy -Identity "Nom-de-la-policy" -Mode TestWithoutNotifications

# Repasser une policy en mode Test avec notification
Set-DlpCompliancePolicy -Identity "Nom-de-la-policy" -Mode TestWithNotifications

# Désactiver une règle sans supprimer la policy
Set-DlpComplianceRule -Identity "Nom-de-la-règle" -Disabled $true

# Supprimer une règle PUIS sa policy (ordre obligatoire)
Remove-DlpComplianceRule -Identity "Nom-de-la-règle" -Confirm:$false
Remove-DlpCompliancePolicy -Identity "Nom-de-la-policy" -Confirm:$false

# Fermer proprement les sessions
Get-PSSession | Remove-PSSession
```

</details>

---

### 05_Retention
* [Exo 5a : Retention Label simple](./05_Retention/exo5a-retention-label-simple.ps1)
  * Objectif : Créer un Retention Label `RET-Citadel-3ans-Modification` — rétention 3 ans calculée depuis la dernière modification, sans disposition review à l'expiration (suppression silencieuse).
  * Connexion requise : `Connect-IPPSSession`
  * Licence requise : Microsoft Purview Records Management (inclus E5)
* [Exo 5b : Retention Label avec disposition review](./05_Retention/exo5b-retention-label-review.ps1)
  * Objectif : Créer un Retention Label `RET-Citadel-7ans-Creation-Review` — rétention 7 ans depuis la création, avec disposition review à l'expiration : un réviseur humain valide la suppression au lieu qu'elle soit automatique.
  * Connexion requise : `Connect-IPPSSession`
  * Licence requise : Microsoft Purview Records Management (inclus E5)
* [Exo 5c : Publication des labels via une Label Policy](./05_Retention/exo5c-publish-retention-policy.ps1)
  * Objectif : Publier les deux labels de rétention (5a, 5b) vers Exchange et SharePoint via une Retention Label Policy — sans publication, un label de rétention créé reste invisible des utilisateurs.
  * Connexion requise : `Connect-IPPSSession`
* [Exo 5d : Adaptive Scope par attribut département](./05_Retention/exo5d-adaptive-scope-department.ps1)
  * Objectif : Créer un Adaptive Scope ciblant dynamiquement les utilisateurs dont `Department -eq "Legal"` — la portée se recalcule automatiquement si des utilisateurs changent de département, contrairement à un scope statique figé à la création.
  * Connexion requise : `Connect-IPPSSession`
* [Exo 5e : Retention Policy statique — Exchange et Teams](./05_Retention/exo5e-retention-policy-static.ps1)
  * Objectif : Créer trois Retention Policies distinctes (Exchange, Teams canaux, Teams chats) avec une rétention 1 an — découverte que l'architecture `AppRetentionCompliance` de Microsoft impose une granularité plus fine qu'attendu (voir note technique).
  * Connexion requise : `Connect-IPPSSession`
* [Exo 5f : Retention Policy avec Adaptive Scope](./05_Retention/exo5f-retention-policy-adaptive.ps1)
  * Objectif : Créer une Retention Policy Exchange rattachée à l'Adaptive Scope créé en 5d — démonstration du couplage scope dynamique / policy de rétention, utile pour des périmètres qui évoluent sans intervention manuelle.
  * Connexion requise : `Connect-IPPSSession`
* [Exo 5g : Audit des labels et policies de rétention](./05_Retention/exo5g-audit-retention.ps1)
  * Objectif : Lister les Retention Labels, les Retention Policies classiques (Exchange/SharePoint), les App Retention Policies (Teams/IA) et les Adaptive Scopes — vue d'ensemble complète de la posture de rétention du tenant.
  * Connexion requise : `Connect-IPPSSession`

<details>
<summary>Note technique — trois objets à ne pas confondre</summary>

> 1. **Retention Label** : l'étiquette elle-même (`New-ComplianceTag`). Définit la durée, le point
>    de départ (création/modification/étiquetage/événement), et le comportement à expiration
>    (suppression, review, ou rien). Un label seul n'a **aucun effet** tant qu'il n'est pas publié.
> 2. **Retention Label Policy** (`New-RetentionCompliancePolicy` + `-RetentionRuleType`) : publie
>    un ou plusieurs labels vers des emplacements (Exchange, SharePoint...) pour les rendre
>    sélectionnables par les utilisateurs ou par de l'auto-application. C'est un mécanisme de
>    **diffusion**, pas de rétention en soi.
> 3. **Retention Policy** (`New-RetentionCompliancePolicy` sans label associé + `New-RetentionComplianceRule`) :
>    applique une règle de rétention **directement** sur un périmètre (mailboxes, sites), sans
>    passer par un label sélectionnable par l'utilisateur — rétention "de fond", invisible,
>    appliquée à tout le contenu du périmètre.
> 
> Les trois partagent la même cmdlet racine `New-RetentionCompliancePolicy`, ce qui prête à
> confusion : c'est la présence ou non de `-RetentionRuleType` et de `New-RetentionComplianceRule`
> qui distinguent "publier un label" de "appliquer une rétention de fond".

</details>

<details>
<summary>Note technique — architecture AppRetentionCompliance (Teams, IA) découverte en 5e</summary>

> Couvrir "Exchange + Teams" en une seule Retention Policy est impossible. Trois contraintes
> distinctes découvertes par test réel sur ce tenant, dans cet ordre :

> **A.** `-ExchangeLocation` et `-TeamsChannelLocation`/`-TeamsChatLocation` sont deux parameter
> sets mutuellement exclusifs de `New-RetentionCompliancePolicy` ("Default" vs "TeamLocation") —
> impossible de les combiner dans un même appel, quelle que soit la combinaison de paramètres.
> 
> **B.** Teams n'est de toute façon plus géré par cette cmdlet du tout. Microsoft l'a migré vers
> `New-AppRetentionCompliancePolicy` / `New-AppRetentionComplianceRule`, une famille séparée sans
> paramètre de location dédié. Le ciblage se fait via `-Applications`, syntaxe
> `"LocationType:NomApplication"`.
> 
> **C.** Au sein de cette nouvelle famille, canaux (`MicrosoftTeamsChannelMessages`) et chats
> (`TeamsChatUserInteractions`) appartiennent à deux **scenario groups** distincts — une policy
> ne peut couvrir qu'un seul scenario group. Combiner les deux dans un même `-Applications`
> déclenche : `"Applications must belong to a single known scenario group"`. De plus,
> `-ExchangeLocation "All"` reste obligatoire même dans ces policies Teams (`New-AppRetentionCompliancePolicy`)
> car il sert à identifier le **scope utilisateur** (qui est concerné), indépendamment du fait
> que le contenu réel soit dans Teams et non Exchange.
> 
> **Conséquence :** "Exchange + Teams" = trois policies distinctes sur deux familles de cmdlets
> différentes. Ce n'est pas spécifique à un tenant dev — c'est l'architecture actuelle de
> Microsoft pour la rétention, en migration depuis les anciens emplacements
> (`*-RetentionCompliance`) vers les nouveaux (`*-AppRetentionCompliance`).
> 
> **Impact sur l'audit (5g) :** `Get-RetentionCompliancePolicy` ne retourne PAS les App
> Retention Policies — il faut systématiquement appeler `Get-AppRetentionCompliancePolicy`
> en plus, sinon les policies Teams sont silencieusement absentes de l'audit.

</details>

<details>
<summary>Note technique — piège -FilterConditions sur New-AdaptiveScope (5d)</summary>

> `-FilterConditions` (structure hashtable documentée dans Microsoft Learn) est buggué pour les
> scopes de type `User` avec un seul critère : l'erreur `InvalidFilterConditionsException` se
> produit même en suivant l'exemple officiel au mot près. Confirmé par au moins un autre
> administrateur ayant reporté le problème à Microsoft.
> 
> Solution de contournement : `-RawQuery`, un parameter set alternatif qui accepte une chaîne
> OPATH simple (`"Department -eq 'Legal'"`) et évite complètement le chemin de code buggué.
> M�me syntaxe que les groupes dynamiques Entra (exo 4b côté Entra), ce qui la rend
> familière. Sur ce tenant (test réel), `-RawQuery` fonctionne sans problème là où
> `-FilterConditions` échoue systématiquement.

</details>

<details>
<summary>Note technique — précédence en cas de policies en conflit</summary>

> Si plusieurs Retention Policies (5e statique + 5f adaptive) ou Retention Label Policies
> s'appliquent au même contenu avec des durées différentes, Purview suit des règles de
> précédence fixes : rétention la plus longue l'emporte sur suppression automatique,
> "ne pas supprimer" l'emporte sur "supprimer", explicite (label appliqué manuellement)
> l'emporte sur implicite (policy de fond). `Get-ComplianceTag -Identity "Nom" | Format-List`
> et le **Policy Lookup** du portail Purview (Records Management > Policy lookup) permettent
> de vérifier concrètement quelle règle s'applique à un élément donné — non scriptable
> (100% GUI, aucune cmdlet n'expose cette résolution).

</details>

<details>
<summary>Commandes utiles en une ligne — Retention</summary>

```powershell
# Lister tous les Retention Labels du tenant
Get-ComplianceTag | Select-Object Name, RetentionDuration, RetentionAction, RetentionType

# Afficher le détail complet d'un Retention Label
Get-ComplianceTag -Identity "Nom-du-label" | Format-List

# Lister les Retention Label Policies (labels publiés)
Get-RetentionCompliancePolicy | Where-Object { $_.RetentionRuleTypes -contains "ComplianceTagRetention" } |
    Select-Object Name, ExchangeLocation, SharePointLocation

# Lister les Retention Policies "de fond" classiques (Exchange/SharePoint)
Get-RetentionCompliancePolicy | Where-Object { $_.RetentionRuleTypes -notcontains "ComplianceTagRetention" } |
    Select-Object Name, ExchangeLocation, SharePointLocation, AdaptiveScopeLocation

# Lister les App Retention Policies (Teams/IA — famille distincte, non retournée par la commande ci-dessus)
Get-AppRetentionCompliancePolicy | Select-Object Name, Applications

# Lister les règles de rétention associées à une policy classique
Get-RetentionComplianceRule -Policy "Nom-de-la-policy" | Select-Object Name, RetentionDuration, RetentionComplianceAction

# Lister les règles d'une App Retention Policy
Get-AppRetentionComplianceRule -Policy "Nom-de-la-policy" | Select-Object Name, RetentionDuration, RetentionComplianceAction

# Lister tous les Adaptive Scopes
Get-AdaptiveScope | Select-Object Name, LocationType

# Afficher le détail d'un Adaptive Scope (règle de filtrage dynamique)
Get-AdaptiveScope -Identity "Nom-du-scope" | Format-List

# Vérifier l'état de distribution d'une policy (propagation vers les emplacements)
Get-RetentionCompliancePolicy -Identity "Nom-de-la-policy" | Select-Object Name, DistributionStatus

# Supprimer une règle PUIS sa policy classique (ordre obligatoire)
Remove-RetentionComplianceRule -Identity "Nom-de-la-règle" -Confirm:$false
Remove-RetentionCompliancePolicy -Identity "Nom-de-la-policy" -Confirm:$false

# Supprimer une App Retention Policy (règle puis policy)
Remove-AppRetentionComplianceRule -Identity "Nom-de-la-règle" -Confirm:$false
Remove-AppRetentionCompliancePolicy -Identity "Nom-de-la-policy" -Confirm:$false

# Supprimer un Retention Label (le retirer de toute policy de publication avant)
Remove-ComplianceTag -Identity "Nom-du-label" -Confirm:$false

# Supprimer un Adaptive Scope
Remove-AdaptiveScope -Identity "Nom-du-scope" -Confirm:$false

# Fermer proprement toutes les sessions
Get-PSSession | Remove-PSSession
```

</details>

---

### 06_Audit_ContentSearch
* [Exo 6a : Audit Retention Policy — Exchange Admin Activity](./06_Audit_ContentSearch/exo6a-audit-retention-policy.ps1)
  * Objectif : Créer une Audit Retention Policy ciblant les activités d'administration Exchange (`ExchangeAdmin`), rétention 1 an — permet de conserver les traces d'actions à privilège élevé au-delà de la période par défaut (180 jours sans Audit Premium).
  * Connexion requise : `Connect-IPPSSession`
  * Licence requise : Microsoft Purview Audit (Premium, inclus E5)
* [Exo 6b : Content Search — mailbox ciblée, date range, mot-clé](./06_Audit_ContentSearch/exo6b-content-search.ps1)
  * Objectif : Créer et lancer une Content Search sur la mailbox `shepard@0n4mg.onmicrosoft.com`, mot-clé `CONFIDENTIEL`, plage glissante de 90 jours — récupération des statistiques de résultats (nombre d'items, taille).
  * Connexion requise : `Connect-IPPSSession`
  * Licence requise : Microsoft Purview eDiscovery Standard (inclus E3/E5)
* [Exo 6c : Audit du tenant — Audit Retention Policies et Content Searches](./06_Audit_ContentSearch/exo6c-audit-tenant.ps1)
  * Objectif : Lister les Audit Retention Policies existantes, les Content Searches du tenant et leur statut — vue d'ensemble de la posture d'audit et de recherche.
  * Connexion requise : `Connect-IPPSSession`

<details>
<summary>Note technique — Insider Risk Management et DSPM for AI non couverts en script</summary>

> Ces deux fonctionnalités sont couvertes en cours (sections 8 et 10 du SC-401) mais
> n'exposent aucune surface PowerShell utile sur un tenant dev.
> 
> **Insider Risk Management** est entièrement GUI — la création de politiques, la gestion
> des alertes/cas, les templates et les notices sont exclusivement dans le portail Purview.
> Les quelques cmdlets disponibles (`Get-InsiderRiskPolicy`) sont en lecture seule et ne
> permettent pas de créer ni de déclencher des scénarios de test sans signaux utilisateur réels.
> Configuration : **Microsoft Purview portal > Insider Risk Management**.
> 
> **DSPM for AI** (Data Security Posture Management for AI) est également 100% GUI et
> nécessite des prérequis lourds (Azure VM, configuration de connecteurs, propagation de
> plusieurs heures) qui dépassent le périmètre d'un exercice PowerShell autonome sur tenant
> dev. Configuration : **Microsoft Purview portal > Data Security Posture Management**.

</details>

<details>
<summary>Note technique — Audit Retention Policy vs Retention Policy</summary>

> Ces deux objets portent des noms proches mais sont radicalement différents :
> 
> - **Retention Policy** (chapitre 05) : agit sur le **contenu** (emails, fichiers SharePoint, messages
>   Teams) — contrôle combien de temps un document ou un message est conservé avant d'être supprimé.
>   Cmdlets : `*-RetentionCompliancePolicy`, `*-AppRetentionCompliancePolicy`.
> 
> - **Audit Retention Policy** (chapitre 06) : agit sur les **logs d'audit** — contrôle combien de
>   temps les traces d'activité (qui a fait quoi, quand) sont conservées dans le journal d'audit
>   unifié. Par défaut : 90 jours (180 jours avec E5). Une policy custom peut aller jusqu'à 10 ans.
>   Cmdlets : `*-UnifiedAuditLogRetentionPolicy`.
> 
> Confusion fréquente en entretien et en production : "on a une policy de rétention" peut désigner
> l'un ou l'autre selon le contexte. L'objet cible (contenu vs trace d'activité) et la cmdlet
> (`CompliancePolicy` vs `AuditLogRetentionPolicy`) tranchent sans ambiguïté.

</details>

<details>
<summary>Note technique — priorité unique obligatoire sur les Audit Retention Policies</summary>

> Le paramètre `-Priority` de `New-UnifiedAuditLogRetentionPolicy` est **obligatoire** et doit
> être **unique** sur tout le tenant — deux policies avec la même priorité sont refusées à la
> création. La valeur 1 est la priorité la plus haute, 10000 la plus basse. Le script 6a détecte
> automatiquement les priorités déjà utilisées et incrémente depuis 100 pour éviter la collision.
> 
> Les policies créées via PowerShell avec des `RecordTypes` hors du tableau de bord GUI standard
> **n'apparaissent pas dans l'interface** Microsoft Purview — elles sont uniquement consultables
> et modifiables via `Get-/Set-UnifiedAuditLogRetentionPolicy`. Ce n'est pas un bug de propagation,
> c'est documenté par Microsoft : les scripts PowerShell et le GUI ne couvrent pas exactement le
> même périmètre de RecordTypes.

</details>

<details>
<summary>Commandes utiles en une ligne — Audit et Content Search</summary>

```powershell
# Lister toutes les Audit Retention Policies par priorité
Get-UnifiedAuditLogRetentionPolicy | Sort-Object Priority |
    Select-Object Name, RecordTypes, RetentionDuration, Priority

# Filtrer les Audit Retention Policies par type d'activité
Get-UnifiedAuditLogRetentionPolicy -RecordType ExchangeAdmin |
    Select-Object Name, RetentionDuration, Priority

# Supprimer une Audit Retention Policy
Remove-UnifiedAuditLogRetentionPolicy -Identity "Nom-de-la-policy" -Confirm:$false

# Lister toutes les Content Searches avec leur statut
Get-ComplianceSearch | Select-Object Name, Status, Items, Size | Sort-Object Name

# Relire le statut et les résultats d'une Content Search spécifique
Get-ComplianceSearch -Identity "Nom-de-la-search" | Format-List Status, Items, Size, SuccessResults

# Lancer une Content Search déjà créée
Start-ComplianceSearch -Identity "Nom-de-la-search"

# Supprimer une Content Search
Remove-ComplianceSearch -Identity "Nom-de-la-search" -Confirm:$false

# Fermer proprement toutes les sessions
Get-PSSession | Remove-PSSession
```

</details>

---
