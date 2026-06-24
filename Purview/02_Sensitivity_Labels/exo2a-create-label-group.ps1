# ========================================================================================
# Exercice 2a : Sensitivity Labels — Création d'un label group et d'un sublabel
# ========================================================================================
# Concept : Un "label group" n'est pas un objet distinct dans Purview — c'est un label
# normal auquel on ajoute deux propriétés particulières :
#
#   islabelgroup : on la pose manuellement via -AdvancedSettings.
#                  Elle indique à Purview "ce label sert de conteneur parent".
#
#   isparent     : calculée automatiquement par Purview dès qu'un sublabel le référence
#                  via -ParentId. On ne peut PAS la forcer manuellement — elle passe à
#                  True uniquement quand un sublabel est rattaché.
#
# Ordre logique imposé par cette mécanique :
#   1. Créer le label group (islabelgroup=True, isparent encore False)
#   2. Créer un sublabel avec -ParentId pointant vers le groupe
#   3. Purview passe isparent=True automatiquement sur le groupe
#
# Ce que fait ce script :
#   1. Reset total de session
#   2. Recherche un nom disponible pour le label group (auto-incrément)
#   3. Crée le label group avec islabelgroup=True
#   4. Vérifie la présence du groupe avant de créer le sublabel
#   5. Crée le premier sublabel rattaché au groupe
#   6. Vérifie le sublabel ET la bascule isparent=True sur le groupe
#   7. Ferme proprement toutes les sessions
#
# Cas d'usage réel :
#   - Structurer une hiérarchie de labels de classification (Public > Interne > Confidentiel)
#   - Le label group apparaît comme catégorie dans le menu de labellisation Office/M365
#   - Les sublabels sont les niveaux applicables réels — on n'applique jamais le groupe lui-même
#
# Module requis : ExchangeOnlineManagement
# Connexion     : Connect-IPPSSession
# ========================================================================================

# --- OUVERTURE — RESET DE SESSION TOTAL ---
# REX : Get-PSSession | Remove-PSSession est préféré à Disconnect-ExchangeOnline -Confirm:$false
# car les versions récentes du module ExchangeOnlineManagement ignorent -Confirm:$false
# et affichent une confirmation interactive qui bloque le script.
Get-PSSession | Remove-PSSession
Connect-IPPSSession -UserPrincipalName GeptorAdmin@0n4mg.onmicrosoft.com -ShowBanner:$false

# ========================================================================================
# ÉTAPE 1 : Recherche d'un nom disponible pour le label group (auto-incrément)
# ========================================================================================
Write-Host "1. Recherche d'un nom disponible pour le label group..." -ForegroundColor Cyan

# Les labels Purview sont identifiés par leur Name (pas leur GUID) dans les cmdlets
# de création — un doublon de Name provoque une erreur. D'où l'auto-incrément.
$BaseGroupName = "NormandySR2 - Confidentiel"
$GroupName     = $BaseGroupName
$Counter       = 2
while (Get-Label -Identity $GroupName -ErrorAction SilentlyContinue) {
    Write-Host "   '$GroupName' déjà pris — test avec suffixe -v$Counter..." -ForegroundColor Yellow
    $GroupName = "$BaseGroupName-v$Counter"
    $Counter++
}
Write-Host "-> Nom retenu pour le label group : '$GroupName'" -ForegroundColor Green

$BaseSubLabelName = "NormandySR2 - Interne"
$SubLabelName     = $BaseSubLabelName
$Counter          = 2
while (Get-Label -Identity $SubLabelName -ErrorAction SilentlyContinue) {
    Write-Host "   '$SubLabelName' déjà pris — test avec suffixe -v$Counter..." -ForegroundColor Yellow
    $SubLabelName = "$BaseSubLabelName-v$Counter"
    $Counter++
}
Write-Host "-> Nom retenu pour le sublabel : '$SubLabelName'`n" -ForegroundColor Green

# ========================================================================================
# ÉTAPE 2 : Création du label group
# ========================================================================================
Write-Host "2. Création du label group '$GroupName'..." -ForegroundColor Cyan

# -AdvancedSettings @{islabelgroup="True"} :
#   C'est cette propriété qui fait du label un "conteneur" dans la hiérarchie Purview.
#   Sans elle, le label est un label normal — il ne peut pas accueillir de sublabels.
#   isparent restera False jusqu'à ce qu'un sublabel le référence via -ParentId.
try {
    $LabelGroup = New-Label `
        -Name            $GroupName `
        -DisplayName     $GroupName `
        -Tooltip         "Documents confidentiels Cerberus Corp — groupe de classification" `
        -Comment         "Label group créé en PowerShell. Cerberus Corp IAM Lab." `
        -AdvancedSettings @{ islabelgroup = "True" } `
        -ErrorAction Stop

    Write-Host "-> Label group créé. Guid : $($LabelGroup.Guid)`n" -ForegroundColor Green
}
catch {
    Write-Host "-> Échec de la création du label group : $_" -ForegroundColor Red
    Get-PSSession | Remove-PSSession
    return
}

# ========================================================================================
# ÉTAPE 3 : Vérification intermédiaire avant création du sublabel
# ========================================================================================
Write-Host "3. Vérification intermédiaire (propagation ~30s)..." -ForegroundColor Cyan

# REX : on vérifie explicitement la présence du groupe avant de créer le sublabel.
# Si le groupe n'est pas encore propagé et qu'on tente de créer le sublabel avec
# son -ParentId, Purview retourne une erreur de référence invalide.
# 30 secondes couvrent la latence de réplication observée sur tenant dev.
Start-Sleep -Seconds 30

$VerifyGroup = Get-Label -Identity $GroupName -ErrorAction SilentlyContinue

if (-not $VerifyGroup) {
    Write-Host "-> ÉCHEC : le label group n'est pas retrouvable après création." -ForegroundColor Red
    Write-Host "   Attendre quelques minutes et relancer — ou vérifier dans le portail Purview." -ForegroundColor Yellow
    Get-PSSession | Remove-PSSession
    return
}
Write-Host "-> Label group confirmé présent dans Purview.`n" -ForegroundColor Green

# ========================================================================================
# ÉTAPE 4 : Création du sublabel rattaché au groupe
# ========================================================================================
Write-Host "4. Création du sublabel '$SubLabelName'..." -ForegroundColor Cyan

# -ParentId $LabelGroup.Guid : c'est ce paramètre qui rattache le sublabel au groupe.
# Dès que Purview enregistre ce rattachement, il bascule isparent=True sur le groupe.
# Note : pas de chiffrement configuré à ce stade — c'est l'objet de l'exercice 2b.
try {
    $SubLabel = New-Label `
        -Name        $SubLabelName `
        -DisplayName $SubLabelName `
        -ParentId    $LabelGroup.Guid `
        -Tooltip     "Document confidentiel à usage interne uniquement" `
        -Comment     "Sublabel sans chiffrement à ce stade — chiffrement ajouté en exo 2b." `
        -ErrorAction Stop

    Write-Host "-> Sublabel créé. Guid : $($SubLabel.Guid)`n" -ForegroundColor Green
}
catch {
    Write-Host "-> Échec de la création du sublabel : $_" -ForegroundColor Red
    Get-PSSession | Remove-PSSession
    return
}

# ========================================================================================
# ÉTAPE 5 : Vérification finale — sublabel ET isparent sur le groupe
# ========================================================================================
Write-Host "5. Vérification finale (propagation ~30s)..." -ForegroundColor Cyan

Start-Sleep -Seconds 30

$VerifySubLabel = Get-Label -Identity $SubLabelName -ErrorAction SilentlyContinue

if (-not $VerifySubLabel) {
    Write-Host "-> ÉCHEC : le sublabel '$SubLabelName' n'est pas retrouvable après création." -ForegroundColor Red
    Write-Host "   Vérifier manuellement dans le portail Purview avant de continuer." -ForegroundColor Yellow
    Get-PSSession | Remove-PSSession
    return
}
Write-Host "-> Sublabel confirmé présent dans Purview." -ForegroundColor Green

# Vérification de la bascule isparent=True sur le groupe.
# $CheckGroup.Settings est une collection de paires clé/valeur — on filtre sur "isparent".
# Si isparent=True : le groupe est pleinement fonctionnel, la hiérarchie est établie.
# Si isparent=False : la réplication n'est pas encore terminée — pas d'action requise,
#                     juste attendre et revérifier.
$CheckGroup    = Get-Label -Identity $GroupName
$IsParentEntry = $CheckGroup.Settings | Where-Object { $_.Name -eq "isparent" }

if ($IsParentEntry.Value -eq "True") {
    Write-Host "-> Confirmé : isparent=True — le label group est pleinement fonctionnel.`n" -ForegroundColor Green
} else {
    Write-Host "-> ATTENTION : isparent toujours False malgré la présence du sublabel." -ForegroundColor Yellow
    Write-Host "   Réplication possiblement encore en cours — revérifier dans quelques minutes.`n" -ForegroundColor Yellow
}

# ========================================================================================
# RÉSUMÉ
# ========================================================================================
Write-Host "=== RÉSUMÉ ===" -ForegroundColor Magenta
[PSCustomObject]@{
    LabelGroup      = $VerifyGroup.DisplayName
    LabelGroupGuid  = $VerifyGroup.Guid
    IsLabelGroup    = "True (posé manuellement via AdvancedSettings)"
    IsParent        = if ($IsParentEntry.Value -eq "True") { "True (basculé automatiquement par Purview)" } else { "False (réplication en cours)" }
    Sublabel        = $VerifySubLabel.DisplayName
    SublabelGuid    = $VerifySubLabel.Guid
    SublabelParent  = $VerifySubLabel.ParentId
    Chiffrement     = "Non configuré — objet de l'exercice 2b"
} | Format-List

# ========================================================================================
# NETTOYAGE MÉMOIRE
# ========================================================================================
Remove-Variable BaseGroupName, GroupName, BaseSubLabelName, SubLabelName, Counter, `
                LabelGroup, SubLabel, VerifyGroup, VerifySubLabel, CheckGroup, IsParentEntry `
                -ErrorAction SilentlyContinue

# ========================================================================================
# FERMETURE — RESET DE SESSION TOTAL
# ========================================================================================
Get-PSSession | Remove-PSSession
Write-Host "Sessions fermées proprement." -ForegroundColor Magenta
