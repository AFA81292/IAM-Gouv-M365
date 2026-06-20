# ========================================================================================
# Exercice 2a : Sensitivity Labels — Création d'un label group via PowerShell
# ========================================================================================
# Concept : Sur le schéma moderne de labels Purview (actif par défaut sur tout tenant
# créé après le 01/10/2025), un "label group" n'est PAS un objet distinct côté API.
# C'est un label normal dont deux propriétés de settings sont positionnées :
#   - islabelgroup : déclare l'intention "ce label sert de conteneur organisationnel"
#   - isparent     : calculée AUTOMATIQUEMENT par le service Purview, PAS settable
#                     manuellement. Elle passe à True dès qu'au moins un sublabel
#                     référence ce label comme parent via -ParentId.
#
# Découverte par investigation directe (documentée ici car contre-intuitive) :
#   1. New-Label -AdvancedSettings @{islabelgroup="True"} crée le conteneur
#   2. New-Label -ParentId <Guid-du-groupe> crée un sublabel rattaché
#   3. Le service met alors isparent=True sur le groupe, en retour, sans action admin
#
# Module requis : ExchangeOnlineManagement
# Connexion : Connect-IPPSSession
# ========================================================================================

# --- OUVERTURE ---
Get-PSSession | Remove-PSSession
Connect-IPPSSession -UserPrincipalName GeptorAdmin@0n4mg.onmicrosoft.com -ShowBanner:$false

# --- ÉTAPE 1 : Création du label group ---
Write-Host "1. Création du label group 'NormandySR2 - Confidentiel'..." -ForegroundColor Cyan

try {
    $LabelGroup = New-Label `
        -Name "NormandySR2 - Confidentiel" `
        -DisplayName "NormandySR2 - Confidentiel" `
        -Tooltip "Documents confidentiels Cerberus Corp — groupe de classification" `
        -Comment "Label group créé en PowerShell. Cerberus Corp IAM Lab." `
        -AdvancedSettings @{islabelgroup="True"} `
        -ErrorAction Stop

    Write-Host "-> Label group créé. Guid : $($LabelGroup.Guid)`n" -ForegroundColor Green
}
catch {
    Write-Host "-> Échec création label group : $_" -ForegroundColor Red
    return
}

# --- ÉTAPE 1bis : Vérification immédiate de la création du groupe ---
Start-Sleep -Seconds 15
$VerifyGroup = Get-Label -Identity "NormandySR2 - Confidentiel" -ErrorAction SilentlyContinue

if (-not $VerifyGroup) {
    Write-Host "-> ÉCHEC : le label group n'est pas retrouvable après création. Arrêt du script." -ForegroundColor Red
    return
}
Write-Host "-> Label group confirmé présent dans Purview.`n" -ForegroundColor Green

# --- ÉTAPE 2 : Création du premier sublabel rattaché ---
Write-Host "2. Création du premier sublabel 'NormandySR2 - Interne'..." -ForegroundColor Cyan

try {
    $SubLabel = New-Label `
        -Name "NormandySR2 - Interne" `
        -DisplayName "NormandySR2 - Interne" `
        -ParentId $LabelGroup.Guid `
        -Tooltip "Document confidentiel à usage interne uniquement" `
        -Comment "Sublabel sans chiffrement à ce stade — chiffrement ajouté en exo 2b." `
        -ErrorAction Stop

    Write-Host "-> Sublabel créé. Guid : $($SubLabel.Guid)`n" -ForegroundColor Green
}
catch {
    Write-Host "-> Échec création sublabel : $_" -ForegroundColor Red
    return
}

# --- ÉTAPE 3 : Vérification finale — sublabel ET isparent sur le groupe ---
Write-Host "3. Vérification finale (propagation ~20s)..." -ForegroundColor Cyan
Start-Sleep -Seconds 20

$VerifySubLabel = Get-Label -Identity "NormandySR2 - Interne" -ErrorAction SilentlyContinue

if (-not $VerifySubLabel) {
    Write-Host "-> ÉCHEC : le sublabel 'NormandySR2 - Interne' n'est pas retrouvable après création." -ForegroundColor Red
    Write-Host "-> Vérifier manuellement dans le portail Purview avant de continuer." -ForegroundColor Red
    return
}
Write-Host "-> Sublabel confirmé présent dans Purview." -ForegroundColor Green

$CheckGroup = Get-Label -Identity "NormandySR2 - Confidentiel"
$IsParentEntry = $CheckGroup.Settings | Where-Object { $_.Name -eq "isparent" }

if ($IsParentEntry.Value -eq "True") {
    Write-Host "-> Confirmé : isparent=True — le label group est pleinement fonctionnel.`n" -ForegroundColor Green
} else {
    Write-Host "-> ATTENTION : isparent toujours False malgré la présence du sublabel." -ForegroundColor Yellow
    Write-Host "-> Réplication possiblement encore en cours — revérifier dans quelques minutes.`n" -ForegroundColor Yellow
}

# --- RÉCAPITULATIF FINAL ---
Write-Host "=== RÉCAPITULATIF ===" -ForegroundColor Cyan
[PSCustomObject]@{
    LabelGroup      = $VerifyGroup.DisplayName
    LabelGroupGuid  = $VerifyGroup.Guid
    Sublabel        = $VerifySubLabel.DisplayName
    SublabelGuid    = $VerifySubLabel.Guid
    SublabelParent  = $VerifySubLabel.ParentId
} | Format-List

# --- NETTOYAGE MÉMOIRE ---
Remove-Variable LabelGroup, SubLabel, VerifyGroup, VerifySubLabel, CheckGroup, IsParentEntry `
    -ErrorAction SilentlyContinue

# --- FERMETURE ---
Get-PSSession | Remove-PSSession
Write-Host "`nSession fermée." -ForegroundColor Magenta
