# ========================================================================================
# Exercice 2f : Sensitivity Labels — Audit des labels et policies
# ========================================================================================
# On boucle la section en listant tout ce qu'on a créé : labels (groupe + sublabels),
# Label Policies de publication, et policies d'auto-labeling. Pas de création ici,
# que de la lecture — utile pour vérifier l'état réel du tenant en un coup d'œil,
# ou pour repartir d'une vue d'ensemble après une pause de plusieurs mois.
#
# Module requis : ExchangeOnlineManagement
# Connexion : Connect-IPPSSession
# ========================================================================================

# --- OUVERTURE ---
Get-PSSession | Remove-PSSession
Connect-IPPSSession -UserPrincipalName GeptorAdmin@0n4mg.onmicrosoft.com -ShowBanner:$false

# --- ÉTAPE 1 : Labels (groupe + sublabels) ---
Write-Host "1. Labels existants sur le tenant..." -ForegroundColor Cyan

$AllLabels = Get-Label -IncludeDetailedLabelActions

# EncryptionEnabled (utilisé plus bas) n'est correctement peuplé qu'avec ce
# paramètre — sans lui, il ressort toujours $false même sur un label réellement
# chiffré. Get-Label seul donne un résumé allégé, pas l'état complet des actions.

# Get-Label expose IsParent directement comme propriété de l'objet — pas besoin
# d'aller fouiller dans Settings (qui est une ArrayList de paires [clé, valeur]
# positionnelles, pas un objet avec des propriétés .Name/.Value : un piège si on
# essaie de filtrer dessus directement). IsParent = True signifie "ce label sert
# de conteneur à au moins un sublabel" — c'est la définition même d'un label group.
$LabelGroups = $AllLabels | Where-Object { $_.IsParent -eq $true }

Write-Host "`n-- Label groups --" -ForegroundColor Yellow
if ($LabelGroups) {
    $LabelGroups | Select-Object DisplayName, Guid | Format-Table -AutoSize
} else {
    Write-Host "   Aucun label group trouvé sur ce tenant.`n" -ForegroundColor Gray
}

# Sublabels = labels dont le ParentId pointe vers un des groupes ci-dessus. On
# exclut ainsi les labels système Microsoft par défaut, qui ont eux aussi un
# ParentId mais vers leur propre groupe natif, pas vers un de nos groupes.
$GroupGuids = $LabelGroups.Guid
$SubLabels  = $AllLabels | Where-Object { $_.ParentId -and ($GroupGuids -contains $_.ParentId) }

Write-Host "-- Sublabels (rattachés à un label group identifié ci-dessus) --" -ForegroundColor Yellow
$SubLabels | Select-Object DisplayName, ParentId, @{N="Chiffré";E={[bool]$_.EncryptionEnabled}} | Format-Table -AutoSize

# --- ÉTAPE 2 : Label Policies (publication) ---
Write-Host "2. Label Policies de publication..." -ForegroundColor Cyan

$AllLabelPolicies = Get-LabelPolicy

if ($AllLabelPolicies) {
    $AllLabelPolicies | Select-Object Name, @{N="Labels";E={$_.Labels -join ", "}}, DistributionStatus |
        Format-Table -AutoSize
} else {
    Write-Host "   Aucune Label Policy trouvée.`n" -ForegroundColor Gray
}

# --- ÉTAPE 3 : Auto-Labeling Policies ---
Write-Host "3. Politiques d'auto-labeling..." -ForegroundColor Cyan

$AllAutoPolicies = Get-AutoSensitivityLabelPolicy

if ($AllAutoPolicies) {
    $AllAutoPolicies | Select-Object Name, Mode, ApplySensitivityLabel,
        @{N="Exchange";E={($_.ExchangeLocation -join ", ")}},
        @{N="SharePoint";E={($_.SharePointLocation -join ", ")}} |
        Format-Table -AutoSize

    # Les règles vivent à part de leur policy — on les liste aussi pour avoir
    # la condition de détection associée à chaque policy.
    Write-Host "-- Règles associées --" -ForegroundColor Yellow
    Get-AutoSensitivityLabelRule | Select-Object Name, ParentPolicyName, Disabled |
        Format-Table -AutoSize
} else {
    Write-Host "   Aucune Auto-Labeling Policy trouvée.`n" -ForegroundColor Gray
}

# --- RÉCAPITULATIF ---
Write-Host "=== RÉCAPITULATIF ===" -ForegroundColor Cyan
[PSCustomObject]@{
    LabelGroups          = $LabelGroups.Count
    Sublabels             = $SubLabels.Count
    LabelPolicies         = $AllLabelPolicies.Count
    AutoLabelingPolicies  = $AllAutoPolicies.Count
} | Format-List

# --- NETTOYAGE MÉMOIRE ---
Remove-Variable AllLabels, LabelGroups, GroupGuids, SubLabels, AllLabelPolicies, AllAutoPolicies `
    -ErrorAction SilentlyContinue

# --- FERMETURE ---
Get-PSSession | Remove-PSSession
Write-Host "`nSession fermée." -ForegroundColor Magenta
