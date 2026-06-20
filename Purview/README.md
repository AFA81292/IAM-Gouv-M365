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

> **Prérequis manuel :** Sur le schéma moderne de labels Purview (actif par défaut sur
> tout tenant créé après le 01/10/2025), la création d'un **label group** n'est possible
> que via le portail Purview — aucune cmdlet PowerShell équivalente n'existe à ce jour
> (vérifié via `Get-Command "*Label*"` sur les modules ExchangeOnlineManagement et
> Microsoft.Graph.Security). Le label group "NSR2 - Confidentiel" doit donc être créé
> manuellement avant d'exécuter les scripts ci-dessous : *Purview portal > Information
> Protection > Sensitivity labels > Create a label*, nom uniquement, aucune autre config
> (les label groups ne supportent que nom/description/couleur/priorité).

* [Exo 2a : Récupération du label group créé via GUI](./02_Sensitivity_Labels/exo2a-get-label-group.ps1)
  * Objectif : Documenter la limitation API, récupérer le label group "NSR2 - Confidentiel" et son Guid pour les exos suivants.
* [Exo 2b : Création d'un sublabel avec chiffrement admin-defined](./02_Sensitivity_Labels/exo2b-create-sublabel-encryption.ps1)
  * Objectif : Créer le sublabel `NSR2 - Interne` sous le label group, avec chiffrement — permissions définies par l'admin (Co-Owner, Co-Author).
  * Licence requise : Microsoft Purview Information Protection (inclus E5).
* [Exo 2c : Création d'un sublabel Do Not Forward](./02_Sensitivity_Labels/exo2c-create-sublabel-dnf.ps1)
  * Objectif : Créer le sublabel `NSR2 - Externe` avec chiffrement Do Not Forward — protection des emails envoyés hors du tenant.
  * Licence requise : Microsoft Purview Information Protection (inclus E5).
* [Exo 2d : Publication des labels via une Label Policy](./02_Sensitivity_Labels/exo2d-publish-label-policy.ps1)
  * Objectif : Publier le label group et ses sublabels vers un groupe de test via une Label Policy.
  * Licence requise : Microsoft Purview Information Protection (inclus E5).
* [Exo 2e : Politique d'auto-labeling côté service](./02_Sensitivity_Labels/exo2e-create-autolabel-policy.ps1)
  * Objectif : Créer une politique d'auto-labeling sur Exchange — détection automatique du SIT custom créé en 1b et application du label `NSR2 - Interne` sans intervention utilisateur.
  * Licence requise : Microsoft Purview Information Protection (inclus E5).
* [Exo 2f : Audit des labels et policies](./02_Sensitivity_Labels/exo2f-audit-labels.ps1)
  * Objectif : Lister les labels, sublabels, policies de publication et policies d'auto-labeling — état complet de la configuration Information Protection du tenant.

> **Note technique :** Le marquage visuel (watermark, header, footer) qu'on aurait
> appliqué à un label parent dans l'ancien schéma se configure désormais au niveau
> sublabel, pas au niveau label group — les label groups sont de purs conteneurs
> organisationnels sans paramètres de protection ni de contenu.

<details>
<summary>Commandes utiles en une ligne — Sensitivity Labels</summary>

```powershell
# Lister tous les labels (groups + sublabels)
Get-Label | Select-Object Name, DisplayName, ParentId | Sort-Object ParentId

# Lister uniquement les label groups (pas de ParentId = soit group, soit label simple)
Get-Label | Where-Object { -not $_.ParentId } | Select-Object Name, DisplayName

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
