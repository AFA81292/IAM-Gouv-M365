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
* [Exo 3a : Vérification de l'état IRM sur le tenant](./03_Message_Encryption/exo3a-check-irm.ps1)
  * Objectif : Contrôler l'état d'Azure RMS et d'IRM — prérequis indispensable avant tout exercice de chiffrement de messages.
  * Connexion requise : `Connect-ExchangeOnline`
* [Exo 3b : Transport Rule OME — Encrypt-Only](./03_Message_Encryption/exo3b-transport-rule-encrypt-only.ps1)
  * Objectif : Créer une règle de flux qui applique automatiquement le template OME `Encrypt-Only` sur les mails sortants contenant le mot-clé `CONFIDENTIEL`.
  * Connexion requise : `Connect-ExchangeOnline`
  * Licence requise : Microsoft Purview Message Encryption (inclus E3/E5)
* [Exo 3c : Transport Rule OME — Do Not Forward hors tenant](./03_Message_Encryption/exo3c-transport-rule-dnf.ps1)
  * Objectif : Créer une règle de flux qui applique `Do Not Forward` sur les mails envoyés vers des destinataires extérieurs au tenant.
  * Connexion requise : `Connect-ExchangeOnline`
  * Licence requise : Microsoft Purview Message Encryption (inclus E3/E5)
* [Exo 3d : Audit des Transport Rules liées au chiffrement](./03_Message_Encryption/exo3d-audit-transport-rules.ps1)
  * Objectif : Lister toutes les Transport Rules du tenant, filtrer celles qui portent une action OME, afficher leur état et leur priorité.
  * Connexion requise : `Connect-ExchangeOnline`

> **Note technique :** EDM (Exact Data Match) et les Trainable Classifiers ne sont pas couverts en script.
> EDM nécessite un pipeline d'upload de données sensibles (hash, schéma, fichier source) dont le temps
> de propagation dépasse plusieurs heures et dont la surface PowerShell est essentiellement un wrapper
> autour d'appels Graph non documentés publiquement. Les Trainable Classifiers sont intégralement GUI —
> aucune cmdlet de création n'est exposée. Ces deux fonctionnalités sont gérées via le portail Purview.

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

> **Note technique :** Un label group n'est pas un objet distinct côté API Purview —
> c'est un label dont la propriété `islabelgroup` est positionnée à `True` via
> `-AdvancedSettings`. La propriété `isparent`, elle, n'est PAS settable manuellement :
> elle est calculée automatiquement par le service dès qu'un sublabel référence ce
> label comme parent via `-ParentId`. Testé et confirmé par investigation directe
> (tentatives de force via `-AdvancedSettings` et `Set-Label` post-création, sans
> succès — la documentation Microsoft Learn sur ce point est ambiguë/incomplète).

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
  * Objectif : Contrôler l'état d'Azure RMS et d'IRM (Information Rights Management) — prérequis indispensable avant tout exercice de chiffrement de messages.
  * Connexion requise : `Connect-ExchangeOnline`
* [Exo 3b : Transport Rule OME — Encrypt-Only](./03_Message_Encryption/exo3b-transport-rule-encrypt-only.ps1)
  * Objectif : Créer une règle de flux de messagerie qui applique automatiquement le template OME `Encrypt-Only` sur les mails sortants contenant le mot-clé `CONFIDENTIEL`.
  * Connexion requise : `Connect-ExchangeOnline`
* [Exo 3c : Transport Rule OME — Do Not Forward hors tenant](./03_Message_Encryption/exo3c-transport-rule-dnf.ps1)
  * Objectif : Créer une règle de flux qui applique `Do Not Forward` sur les mails envoyés vers des destinataires extérieurs au tenant — le destinataire peut lire, mais ne peut pas transférer, copier ni imprimer.
  * Connexion requise : `Connect-ExchangeOnline`
* [Exo 3d : Audit des Transport Rules liées au chiffrement](./03_Message_Encryption/exo3d-audit-transport-rules.ps1)
  * Objectif : Lister toutes les Transport Rules du tenant, filtrer celles qui portent une action OME, afficher leur état et leur priorité.
  * Connexion requise : `Connect-ExchangeOnline`

> **Note technique — Advanced Message Encryption (AME) :**
> AME ajoute deux capacités au-dessus de l'OME standard : le **branding personnalisé** du portail
> de lecture (logo, couleurs, message d'accueil) et la **révocation de message** — possibilité de
> couper l'accès à un mail déjà envoyé, à condition que le destinataire le lise via le portail web OME
> (pas via un client Outlook natif qui aurait déchiffré le message localement).
>
> En production, AME est pertinent dans deux scénarios : communications client avec charte graphique
> imposée (secteur bancaire, juridique) et gestion de crise post-envoi (mauvais destinataire,
> fuite de données — on révoque l'accès avant que le mail soit lu).
>
> AME nécessite une licence **E5 ou l'add-on Microsoft Purview Message Encryption**. Les cmdlets
> existent (`New-OMEConfiguration`, `Set-OMEConfiguration`) mais le résultat n'est vérifiable
> qu'en envoyant un vrai mail et en inspectant le portail de lecture — hors périmètre d'un
> exercice PowerShell autonome sur tenant dev. Configuration via :
> **Exchange Admin Center > Mail flow > Message encryption**.

<details>
<summary>Commandes utiles en une ligne — Message Encryption</summary>

```powershell
# Vérifier l'état IRM complet du tenant
Get-IRMConfiguration | Format-List

# Lister les templates RMS disponibles (Encrypt-Only, Do Not Forward, custom)
Get-RMSTemplate | Select-Object Name, Description, Guid

# Lister toutes les Transport Rules par priorité
Get-TransportRule | Select-Object Name, Priority, State | Sort-Object Priority

# Filtrer les rules avec une action OME (chiffrement appliqué)
Get-TransportRule | Where-Object {
    $_.ApplyRightsProtectionTemplate -ne $null -or $_.ApplyOME -eq $true
} | Select-Object Name, State, Priority

# Désactiver une Transport Rule sans la supprimer
Disable-TransportRule -Identity "Nom-de-la-rule"

# Réactiver une Transport Rule
Enable-TransportRule -Identity "Nom-de-la-rule"

# Supprimer une Transport Rule
Remove-TransportRule -Identity "Nom-de-la-rule" -Confirm:$false

# Fermer proprement la session Exchange Online
Disconnect-ExchangeOnline -Confirm:$false
```

</details>

---
