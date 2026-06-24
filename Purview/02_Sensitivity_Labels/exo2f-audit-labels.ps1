# ========================================================================================
# Exercice 2f : Sensitivity Labels — Audit des labels et policies
# ========================================================================================
# Concept : Exo de lecture pure — aucune création, aucune modification.
# On boucle la section Sensitivity Labels en listant tout ce qui a été créé :
#   - Labels (groupe parent + sublabels rattachés)
#   - Label Policies de publication (2d)
#   - Policies d'auto-labeling (2e)
#
# Cas d'usage réel : un consultant IAM arrive en mission et veut une vue d'ensemble
# immédiate de l'état des labels sur le tenant, sans naviguer dans le portail Purview.
# Ce script donne un inventaire lisible en quelques secondes.
# Utile aussi pour soi-même après une pause : repartir d'une vue d'ensemble plutôt
# que de fouiller dans le portail pour retrouver ce qui a été configuré.
#
# Points techniques notables :
#
# -IncludeDetailedLabelActions (Get-Label) :
#   Sans ce paramètre, EncryptionEnabled ressort toujours $false même sur un label
#   réellement chiffré. Get-Label seul retourne un résumé allégé — pas l'état complet
#   des actions de protection. Toujours l'inclure pour un audit fiable.
#
# IsParent (propriété native de Get-Label) :
#   Exposée directement comme propriété de l'objet — pas besoin de fouiller dans
#   Settings (qui est une ArrayList de paires positionnelles, pas un objet avec des
#   propriétés .Name/.Value accessibles directement). IsParent = $true signifie
#   "ce label est un conteneur avec au moins un sublabel".
#
# Filtrage des sublabels custom vs labels système Microsoft :
#   On ne filtre pas simplement sur ParentId -ne $null, car les labels système
#   Microsoft natifs ont eux aussi un ParentId (vers leurs propres groupes natifs).
#   On filtre sur les GUIDs de NOS label groups uniquement — ce qui exclut proprement
#   les labels système sans avoir à les lister explicitement.
#
# Ce que fait ce script :
#   1. Reset total de session
#   2. Audite les labels (groupe parent + sublabels custom)
#   3. Audite les Label Policies de publication
#   4. Audite les policies d'auto-labeling et leurs règles associées
#   5. Affiche un récapitulatif chiffré
#   6. Ferme proprement toutes les sessions
#
# Module requis : ExchangeOnlineManagement
# Connexion     : Connect-IPPSSession
# ========================================================================================

# --- OUVERTURE — RESET DE SESSION TOTAL ---
# REX : des sessions fantômes restées ouvertes depuis un script précédent peuvent
# provoquer des erreurs silencieuses ou des authentifications croisées.
# On purge TOUT avant de commencer, sans exception.
#
# Note : Connect-IPPSSession ne supporte pas -ShowBanner:$false — bandeau normal.
# $env:MSAL_ENABLE_WAM = "0" non nécessaire ici : script de lecture seule,
# pas de risque d'interférence WAM sur un Connect-IPPSSession simple.
Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
Get-PSSession | Remove-PSSession
Connect-IPPSSession -UserPrincipalName GeptorAdmin@0n4mg.onmicrosoft.com

# ========================================================================================
# ÉTAPE 1 : Audit des labels (groupe parent + sublabels)
# ========================================================================================
Write-Host "1. Audit des labels existants sur le tenant..." -ForegroundColor Cyan

# -IncludeDetailedLabelActions : obligatoire pour avoir EncryptionEnabled fiable.
# Sans ce paramètre, la propriété est toujours $false même sur un label chiffré.
$AllLabels = Get-Label -IncludeDetailedLabelActions

# Identification des label groups (parents) :
# IsParent est une propriété native de l'objet retourné par Get-Label.
# Un label group ne peut pas être appliqué directement — il sert de conteneur
# organisationnel pour regrouper des sublabels dans le client (Word, Outlook, Teams).
$LabelGroups = $AllLabels | Where-Object { $_.IsParent -eq $true }

Write-Host "`n-- Label groups (parents) --" -ForegroundColor Yellow
if ($LabelGroups) {
    $LabelGroups | Select-Object DisplayName, Guid | Format-Table -AutoSize
} else {
    Write-Host "   Aucun label group trouvé sur ce tenant." -ForegroundColor Gray
}

# Identification des sublabels custom :
# On filtre sur ParentId appartenant aux GUIDs de NOS label groups — pas un simple
# -ne $null qui inclurait les labels système Microsoft natifs (qui ont eux aussi un ParentId).
$GroupGuids = $LabelGroups.Guid
$SubLabels  = $AllLabels | Where-Object {
    $_.ParentId -and ($GroupGuids -contains $_.ParentId)
}

Write-Host "`n-- Sublabels (rattachés aux label groups identifiés ci-dessus) --" -ForegroundColor Yellow
if ($SubLabels) {
    $SubLabels | Select-Object DisplayName, ParentId,
        @{ N = "Chiffré" ; E = { [bool]$_.EncryptionEnabled } } |
        Format-Table -AutoSize
} else {
    Write-Host "   Aucun sublabel custom trouvé." -ForegroundColor Gray
}

# ========================================================================================
# ÉTAPE 2 : Audit des Label Policies de publication
# ========================================================================================
Write-Host "`n2. Audit des Label Policies de publication (exo 2d)..." -ForegroundColor Cyan

# Get-LabelPolicy retourne toutes les policies de publication du tenant.
# DistributionStatus "Pending" = distribution en cours vers les workloads.
# "Success" = labels visibles dans les clients (Word, Outlook, Teams) pour les destinataires.
$AllLabelPolicies = Get-LabelPolicy

if ($AllLabelPolicies) {
    $AllLabelPolicies | Select-Object Name,
        @{ N = "Labels" ; E = { $_.Labels -join ", " } },
        DistributionStatus |
        Format-Table -AutoSize
} else {
    Write-Host "   Aucune Label Policy de publication trouvée." -ForegroundColor Gray
}

# ========================================================================================
# ÉTAPE 3 : Audit des policies d'auto-labeling
# ========================================================================================
Write-Host "`n3. Audit des policies d'auto-labeling (exo 2e)..." -ForegroundColor Cyan

# Get-AutoSensitivityLabelPolicy retourne les policies d'auto-labeling côté service.
# Différent des Label Policies de publication : ici c'est Purview qui applique
# le label automatiquement, sans action utilisateur.
$AllAutoPolicies = Get-AutoSensitivityLabelPolicy

if ($AllAutoPolicies) {
    $AllAutoPolicies | Select-Object Name, Mode, ApplySensitivityLabel,
        @{ N = "Exchange"   ; E = { ($_.ExchangeLocation   -join ", ") } },
        @{ N = "SharePoint" ; E = { ($_.SharePointLocation -join ", ") } } |
        Format-Table -AutoSize

    # Les règles sont des objets séparés de leur policy — on les liste en complément.
    # Une règle contient la condition de détection (SIT, seuil) ; la policy contient
    # le label à appliquer et le mode. Les deux sont nécessaires pour que le scan fonctionne.
    Write-Host "`n-- Règles d'auto-labeling associées --" -ForegroundColor Yellow
    Get-AutoSensitivityLabelRule |
        Select-Object Name, ParentPolicyName, Workload, Disabled |
        Format-Table -AutoSize
} else {
    Write-Host "   Aucune Auto-Labeling Policy trouvée." -ForegroundColor Gray
}

# ========================================================================================
# RÉSUMÉ
# ========================================================================================
Write-Host "`n=== RÉSUMÉ ===" -ForegroundColor Magenta
[PSCustomObject]@{
    LabelGroups          = if ($LabelGroups)       { $LabelGroups.Count       } else { 0 }
    SublabelsCustom      = if ($SubLabels)          { $SubLabels.Count          } else { 0 }
    LabelPolicies        = if ($AllLabelPolicies)   { $AllLabelPolicies.Count   } else { 0 }
    AutoLabelingPolicies = if ($AllAutoPolicies)    { $AllAutoPolicies.Count    } else { 0 }
    Scope                = "Lecture seule — aucune création, aucune modification"
} | Format-List

Write-Host "=== FIN DE L'AUDIT SENSITIVITY LABELS ===" -ForegroundColor Green

# ========================================================================================
# NETTOYAGE MÉMOIRE
# ========================================================================================
Remove-Variable AllLabels, LabelGroups, GroupGuids, SubLabels,
                AllLabelPolicies, AllAutoPolicies `
                -ErrorAction SilentlyContinue

# ========================================================================================
# FERMETURE — RESET DE SESSION TOTAL
# ========================================================================================
Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
Get-PSSession | Remove-PSSession
Write-Host "Sessions fermées proprement." -ForegroundColor Magenta
