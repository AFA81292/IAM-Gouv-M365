# ========================================================================================
# Exercice 3b : Message Encryption — Transport Rule OME automatique (mot-clé CONFIDENTIEL)
# ========================================================================================
# [... bloc de concept inchangé : FromScope vs SentToScope, cycle Audit -> Enforce ...]
#
# Leçon apprise (2e échec) : le nom du template système dépend de la langue d'affichage
# du tenant. Sur un tenant FR, les templates OME par défaut s'appellent "Chiffrer" et
# "Ne pas transférer" — pas "Encrypt" / "Encrypt-Only". Le filtre ci-dessous couvre EN+FR
# explicitement (limite assumée, pas de solution garantie locale-proof sans GUID connu).
# Une variable d'override est fournie pour forcer le nom exact si l'heuristique échoue.
# ========================================================================================

# --- OUVERTURE ---
Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
Connect-ExchangeOnline -UserPrincipalName GeptorAdmin@0n4mg.onmicrosoft.com -ShowBanner:$false

# --- ÉTAPE 0 : Override manuel (optionnel) ---
# Si renseigné, on saute toute la résolution automatique et on utilise ce nom tel quel.
# Utile si l'heuristique EN/FR ne matche pas sur un autre tenant plus tard.
$TemplateNameOverride = $null   # ex : "Chiffrer"

# --- ÉTAPE 1 : Garde-fou — RMS doit être actif (prérequis validé en 3a) ---
Write-Host "1. Vérification rapide du prérequis RMS..." -ForegroundColor Cyan

$IRMConfig = Get-IRMConfiguration
if (-not $IRMConfig.AzureRMSLicensingEnabled) {
    Write-Host "-> ARRÊT : RMS n'est pas actif sur le tenant (voir exo 3a)." -ForegroundColor Red
    Disconnect-ExchangeOnline -Confirm:$false
    return
}
Write-Host "-> OK : RMS actif.`n" -ForegroundColor Green

# --- ÉTAPE 2 : Résolution du template de chiffrement simple (EN + FR, ou override) ---
Write-Host "2. Résolution du template RMS de chiffrement simple..." -ForegroundColor Cyan

if ($TemplateNameOverride) {
    $Template = $TemplateNameOverride
    Write-Host "-> Override manuel utilisé : '$Template'`n" -ForegroundColor Yellow
}
else {
    $AllTemplates = Get-RMSTemplate

    # Mots-clés "positifs" (chiffrement simple) et "négatifs" (Do Not Forward, à exclure)
    # en anglais et en français. Documenté comme limite : tenant dans une 3e langue = échec.
    $PositiveKeywords = "Encrypt|Chiffrer"
    $NegativeKeywords = "Forward|transférer"

    $EncryptTemplate = $AllTemplates | Where-Object {
        $_.Name -match $PositiveKeywords -and $_.Name -notmatch $NegativeKeywords
    } | Select-Object -First 1

    if (-not $EncryptTemplate) {
        Write-Host "-> ARRÊT : aucun template résolu automatiquement (EN/FR)." -ForegroundColor Red
        Write-Host "   Templates disponibles sur ce tenant :" -ForegroundColor Yellow
        $AllTemplates | Select-Object Name | Format-Table -AutoSize
        Write-Host "   -> Renseigne `$TemplateNameOverride en haut du script avec le nom exact." -ForegroundColor Yellow
        Disconnect-ExchangeOnline -Confirm:$false
        return
    }

    $Template = $EncryptTemplate.Name
    Write-Host "-> Template résolu automatiquement : '$Template'`n" -ForegroundColor Green
}

# --- ÉTAPE 3 : Définition des variables de la règle ---
$RuleName = "OME-N7-Confidentiel-Sortant"
$Keyword  = "CONFIDENTIEL"

Write-Host "3. Paramètres de la règle :" -ForegroundColor Cyan
Write-Host "   Nom      : $RuleName"   -ForegroundColor Gray
Write-Host "   Mot-clé  : $Keyword (sujet OU corps du message)" -ForegroundColor Gray
Write-Host "   Template : $Template`n" -ForegroundColor Gray

# --- ÉTAPE 4 : Création de la règle en mode Audit ---
Write-Host "4. Création de la règle en mode AuditAndNotify (test)..." -ForegroundColor Cyan

$RuleParams = @{
    Name                           = $RuleName
    Comments                       = "Exo 3b - Chiffre automatiquement les mails internes contenant CONFIDENTIEL. Cree par script, voir GitHub Purview/03_Message_Encryption."
    FromScope                      = "InOrganization"
    SubjectOrBodyContainsWords     = $Keyword
    ApplyRightsProtectionTemplate  = $Template
    Mode                           = "AuditAndNotify"
}

try {
    New-TransportRule @RuleParams -ErrorAction Stop
    Write-Host "-> Succès : règle créée en mode test (AuditAndNotify).`n" -ForegroundColor Green
}
catch {
    Write-Host "-> Échec de la création : $_`n" -ForegroundColor Red
    Disconnect-ExchangeOnline -Confirm:$false
    return
}

# --- ÉTAPE 5 : Vérification de la règle en mode test ---
Write-Host "5. Vérification de la règle créée..." -ForegroundColor Cyan
Start-Sleep -Seconds 2

Get-TransportRule -Identity $RuleName |
    Select-Object Name, Mode, State, FromScope, SubjectOrBodyContainsWords |
    Format-List

# --- ÉTAPE 6 : Bascule en mode Enforce ---
Write-Host "6. Bascule de la règle en mode Enforce..." -ForegroundColor Cyan

try {
    Set-TransportRule -Identity $RuleName -Mode Enforce -ErrorAction Stop
    Write-Host "-> Succès : règle active en Enforce.`n" -ForegroundColor Green
}
catch {
    Write-Host "-> Échec de la bascule : $_`n" -ForegroundColor Red
}

# --- ÉTAPE 7 : Vérification finale ---
Write-Host "7. État final de la règle..." -ForegroundColor Cyan
Start-Sleep -Seconds 2

$FinalRule = Get-TransportRule -Identity $RuleName
$FinalRule | Select-Object Name, Mode, State, Priority | Format-List

if ($FinalRule.Mode -eq "Enforce" -and $FinalRule.State -eq "Enabled") {
    Write-Host "-> OK : règle active et enforced.`n" -ForegroundColor Green
} else {
    Write-Host "-> ATTENTION : état inattendu — vérifier Mode/State ci-dessus.`n" -ForegroundColor Yellow
}

# --- RÉSUMÉ ---
Write-Host "=== RÉSUMÉ ===" -ForegroundColor Magenta
[PSCustomObject]@{
    Nom      = $FinalRule.Name
    Mode     = $FinalRule.Mode
    Etat     = $FinalRule.State
    Portee   = "FromScope: InOrganization"
    MotCle   = $Keyword
    Template = $Template
} | Format-List

# --- COMMENT TESTER MANUELLEMENT ---
# Envoyer un message de Shepard@0n4mg.onmicrosoft.com vers Liara@0n4mg.onmicrosoft.com
# avec "CONFIDENTIEL" dans le sujet ou le corps. Vérifier via le message trace (portail
# Exchange > Mail flow > Message trace) que le message a été traité par la règle
# "OME-N7-Confidentiel-Sortant" et marqué chiffré.

# --- NETTOYAGE MÉMOIRE ---
Remove-Variable IRMConfig, AllTemplates, EncryptTemplate, Template, TemplateNameOverride, `
    RuleName, Keyword, RuleParams, FinalRule -ErrorAction SilentlyContinue

# --- FERMETURE ---
Disconnect-ExchangeOnline -Confirm:$false
Write-Host "`nSession Exchange Online fermée." -ForegroundColor Magenta
