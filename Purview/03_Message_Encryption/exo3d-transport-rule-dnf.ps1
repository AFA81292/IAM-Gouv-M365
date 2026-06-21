# ========================================================================================
# Exercice 3d : Message Encryption — Transport Rule Do Not Forward (mails externes)
# ========================================================================================
# Concept : Chiffrer avec restriction de transfert (Do Not Forward) tout mail envoyé vers
# un destinataire extérieur au tenant. Contrairement à 3b/3c (FromScope, expéditeur
# interne), la condition ici porte sur le DESTINATAIRE : SentToScope "NotInOrganization".
#
# Reste une Transport Rule classique (pas de DLP) : SentToScope n'est pas un prédicat
# DLP-related, contrairement à MessageContainsDataClassifications (3c) — non concerné par
# la dépréciation de novembre 2023. Une seule session suffit (Connect-ExchangeOnline).
#
# Choix assumé : pas de condition de contenu (mot-clé ou SIT) — la règle s'applique à TOUT
# mail externe, sans filtrage. C'est volontairement agressif pour un exo de démonstration ;
# en prod, on la combinerait quasi certainement avec une condition de contenu pour éviter
# de chiffrer systématiquement de la correspondance anodine.
#
# Module requis : ExchangeOnlineManagement
# Connexion : Connect-ExchangeOnline
# ========================================================================================

# --- OUVERTURE ---
Get-PSSession | Remove-PSSession
Connect-ExchangeOnline -UserPrincipalName GeptorAdmin@0n4mg.onmicrosoft.com -ShowBanner:$false

# --- ÉTAPE 0 : Variables ---
$TemplateNameOverride = $null

# --- ÉTAPE 1 : Garde-fou — RMS doit être actif ---
$IRMConfig = Get-IRMConfiguration
if (-not $IRMConfig.AzureRMSLicensingEnabled) {
    Write-Host "-> ARRÊT : RMS n'est pas actif sur le tenant (voir exo 3a)." -ForegroundColor Red
    Get-PSSession | Remove-PSSession
    return
}

# --- ÉTAPE 2 : Résolution du template Do Not Forward (EN + FR, ou override) ---
Write-Host "2. Résolution du template Do Not Forward..." -ForegroundColor Cyan

if ($TemplateNameOverride) {
    $Template = $TemplateNameOverride
    Write-Host "-> Override manuel utilisé : '$Template'`n" -ForegroundColor Yellow
}
else {
    $AllTemplates = Get-RMSTemplate
    # Cette fois on CHERCHE "Forward"/"transférer" — inverse du filtre négatif de 3b/3c.
    $DnfTemplate = $AllTemplates | Where-Object { $_.Name -match "Forward|transférer" } |
        Select-Object -First 1

    if (-not $DnfTemplate) {
        Write-Host "-> ARRÊT : aucun template Do Not Forward résolu automatiquement (EN/FR)." -ForegroundColor Red
        $AllTemplates | Select-Object Name | Format-Table -AutoSize
        Get-PSSession | Remove-PSSession
        return
    }
    $Template = $DnfTemplate.Name
    Write-Host "-> Template résolu automatiquement : '$Template'`n" -ForegroundColor Green
}

# --- ÉTAPE 3 : Recherche d'un nom disponible (auto-incrément) ---
# Même logique qu'en 3c : on cherche un nom libre plutôt que de supprimer un objet d'un
# run précédent. Les Transport Rules ne sont pas soumises à la même propagation
# asynchrone que les objets Purview/Compliance (3c) — mais par cohérence avec le reste du
# chapitre, et pour ne pas réintroduire une hypothèse non vérifiée, on garde la même
# stratégie partout plutôt que de mélanger deux approches différentes selon l'exo.
Write-Host "3. Recherche d'un nom disponible pour la règle..." -ForegroundColor Cyan

$BaseRuleName = "OME-N7-DoNotForward-Externe"
$RuleName     = $BaseRuleName
$Counter      = 2

while (Get-TransportRule -Identity $RuleName -ErrorAction SilentlyContinue) {
    Write-Host "   '$RuleName' déjà pris — test -v$Counter..." -ForegroundColor Yellow
    $RuleName = "$BaseRuleName-v$Counter"
    $Counter++
}
Write-Host "-> Nom retenu : '$RuleName'`n" -ForegroundColor Green

# --- ÉTAPE 4 : Paramètres et création en mode Audit ---
Write-Host "4. Paramètres de la règle :" -ForegroundColor Cyan
Write-Host "   Nom        : $RuleName"   -ForegroundColor Gray
Write-Host "   Portée     : SentToScope NotInOrganization (destinataire externe)" -ForegroundColor Gray
Write-Host "   Template   : $Template`n" -ForegroundColor Gray

$RuleParams = @{
    Name                          = $RuleName
    Comments                      = "Exo 3d - Chiffre avec restriction de transfert les mails envoyes a des destinataires externes. Voir GitHub Purview/03_Message_Encryption."
    SentToScope                   = "NotInOrganization"
    ApplyRightsProtectionTemplate = $Template
    Mode                          = "AuditAndNotify"
}

Write-Host "5. Création de la règle en mode AuditAndNotify (test)..." -ForegroundColor Cyan
try {
    New-TransportRule @RuleParams -ErrorAction Stop
    Write-Host "-> Succès : règle créée en mode test.`n" -ForegroundColor Green
}
catch {
    Write-Host "-> Échec de la création : $_`n" -ForegroundColor Red
    Get-PSSession | Remove-PSSession
    return
}

# --- ÉTAPE 6 : Vérification puis bascule en Enforce ---
Write-Host "6. Vérification puis bascule en Enforce..." -ForegroundColor Cyan
Start-Sleep -Seconds 2

Get-TransportRule -Identity $RuleName | Select-Object Name, Mode, State, SentToScope | Format-List

try {
    Set-TransportRule -Identity $RuleName -Mode Enforce -ErrorAction Stop
    Write-Host "-> Succès : règle active en Enforce.`n" -ForegroundColor Green
}
catch {
    Write-Host "-> Échec de la bascule : $_`n" -ForegroundColor Red
}

# --- ÉTAPE 7 : Vérification finale + résumé ---
Start-Sleep -Seconds 2
$FinalRule = Get-TransportRule -Identity $RuleName
$FinalRule | Select-Object Name, Mode, State, Priority | Format-List

Write-Host "=== RÉSUMÉ ===" -ForegroundColor Magenta
[PSCustomObject]@{
    Nom      = $FinalRule.Name
    Mode     = $FinalRule.Mode
    Etat     = $FinalRule.State
    Portee   = "SentToScope: NotInOrganization"
    Template = $Template
} | Format-List

# --- NETTOYAGE / FERMETURE ---
Remove-Variable TemplateNameOverride, IRMConfig, AllTemplates, DnfTemplate, Template, `
    BaseRuleName, RuleName, Counter, RuleParams, FinalRule -ErrorAction SilentlyContinue
Get-PSSession | Remove-PSSession
Write-Host "`nSession fermée." -ForegroundColor Magenta
