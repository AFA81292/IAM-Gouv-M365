# ========================================================================================
# Exercice 2a : Sensitivity Labels — Création d'un label parent
# ========================================================================================
# Concept : Un label de sensibilité peut exister seul (label simple) ou comme parent
# d'une hiérarchie de sublabels (ex: Confidentiel > Interne / Externe). Un label parent
# n'a pas forcément de chiffrement — il peut servir de regroupement visuel/organisationnel,
# le chiffrement étant alors appliqué uniquement sur les sublabels (voir 2b, 2c).
#
# Ici on crée "Confidentiel" comme label parent SANS chiffrement — uniquement du
# marquage visuel (watermark, header, footer). Le chiffrement viendra sur les sublabels.
#
# Pourquoi séparer marquage et chiffrement à ce niveau :
#   - Le marquage visuel a un coût d'usage quasi nul (juste informatif pour l'utilisateur)
#   - Le chiffrement a un coût réel (gestion des droits, compatibilité, support)
#   - Bonne pratique de gouvernance : forcer la décision de chiffrement au niveau sublabel,
#     pas au niveau parent — évite le chiffrement "par défaut" non réfléchi
#
# Cas d'usage réel :
#   - Premier label d'une hiérarchie de classification d'entreprise
#   - Démontrer la compréhension de la distinction marquage vs protection
#
# Module requis : ExchangeOnlineManagement
# Connexion : Connect-IPPSSession
# ========================================================================================

# --- OUVERTURE ---
Get-PSSession | Remove-PSSession
Connect-IPPSSession -UserPrincipalName GeptorAdmin@0n4mg.onmicrosoft.com -ShowBanner:$false

# --- ÉTAPE 1 : Définition des variables ---
Write-Host "1. Définition du label parent..." -ForegroundColor Cyan

$LabelName        = "Confidentiel"
$LabelDisplayName = "Confidentiel"
$LabelComment     = "Label parent — marquage visuel uniquement, sans chiffrement. Cerberus Corp IAM Lab."

Write-Host "-> Nom : $LabelName" -ForegroundColor Green

# --- ÉTAPE 2 : Création du label ---
# New-Label crée le label dans Purview. Sans -ParentId, c'est un label racine.
# -Tooltip : texte affiché au survol dans les apps Office
# -Comment : visible uniquement côté admin, pas par les utilisateurs
Write-Host "`n2. Création du label dans Purview..." -ForegroundColor Cyan

try {
    $NewLabel = New-Label `
        -Name $LabelName `
        -DisplayName $LabelDisplayName `
        -Tooltip "Document confidentiel — usage interne Cerberus Corp" `
        -Comment $LabelComment `
        -ErrorAction Stop

    Write-Host "-> Label créé. Id : $($NewLabel.Guid)" -ForegroundColor Green
}
catch {
    Write-Host "-> Échec création label : $_" -ForegroundColor Red
    return
}

# --- ÉTAPE 3 : Configuration du marquage visuel ---
# Set-Label applique le marquage après création — séparé volontairement de New-Label
# pour rester lisible (New-Label avec tous les paramètres de marquage serait illisible).
#
# ApplyContentMarkingFooterEnabled / HeaderEnabled / WatermarkingEnabled :
#   Chacun est indépendant — on peut activer un seul des trois ou les trois ensemble.
# FontSize, FontColor : en hexadécimal, cohérence visuelle avec une charte d'entreprise
Write-Host "3. Configuration du marquage visuel..." -ForegroundColor Cyan

try {
    Set-Label -Identity $LabelName `
        -ApplyContentMarkingFooterEnabled $true `
        -ApplyContentMarkingFooterText "CONFIDENTIEL - Cerberus Corp" `
        -ApplyContentMarkingFooterFontSize 10 `
        -ApplyContentMarkingFooterFontColor "#C00000" `
        -ApplyContentMarkingHeaderEnabled $true `
        -ApplyContentMarkingHeaderText "CONFIDENTIEL" `
        -ApplyContentMarkingHeaderFontSize 12 `
        -ApplyContentMarkingHeaderFontColor "#C00000" `
        -ApplyWatermarkingEnabled $true `
        -ApplyWatermarkingText "CONFIDENTIEL" `
        -ApplyWatermarkingFontSize 100 `
        -ErrorAction Stop

    Write-Host "-> Marquage visuel appliqué." -ForegroundColor Green
}
catch {
    Write-Host "-> Échec configuration marquage : $_" -ForegroundColor Red
    return
}

# --- ÉTAPE 4 : Vérification ---
# IMPORTANT : Get-Label simple ne retourne pas de manière fiable les propriétés
# de marquage (Footer/Header/Watermark) même quand elles sont actives côté serveur.
# -IncludeDetailedLabelActions force le retour complet de ces propriétés.
# Sans ce paramètre, on observe un faux négatif (tout à False alors que c'est actif).
Write-Host "`n4. Vérification (propagation ~30s)..." -ForegroundColor Cyan
Start-Sleep -Seconds 30

$CheckLabel = Get-Label -Identity $LabelName -IncludeDetailedLabelActions

if ($CheckLabel) {
    Write-Host "-> Label confirmé dans Purview :" -ForegroundColor Green
    [PSCustomObject]@{
        Nom            = $CheckLabel.DisplayName
        Priority       = $CheckLabel.Priority
        Footer         = [bool]$CheckLabel.ApplyContentMarkingFooterEnabled
        Header         = [bool]$CheckLabel.ApplyContentMarkingHeaderEnabled
        Watermark      = [bool]$CheckLabel.ApplyWatermarkingEnabled
        EstParent      = -not [bool]$CheckLabel.ParentId
    } | Format-List
} else {
    Write-Host "-> Label pas encore visible — réplication en cours." -ForegroundColor Yellow
}

# --- NETTOYAGE MÉMOIRE ---
Remove-Variable LabelName, LabelDisplayName, LabelComment, NewLabel, CheckLabel `
    -ErrorAction SilentlyContinue

# --- FERMETURE ---
Get-PSSession | Remove-PSSession
Write-Host "`nSession fermée. Mémoire locale nettoyée." -ForegroundColor Magenta
