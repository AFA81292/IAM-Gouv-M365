# ========================================================================================
# Exercice 3c : Message Encryption — DLP Compliance Rule déclenchée par classification (SIT)
# ========================================================================================
# Concept : Chiffrer un mail à la détection du SIT custom "Cerberus Corp - Numéro de Badge
# Interne" (créé en 1b), via une DLP Compliance Rule (EncryptRMSTemplate) — mécanisme
# supporté depuis que MessageContainsDataClassifications est déprécié dans les Transport
# Rules (aka.ms/NoDLPinETRs, voir note technique du README).
#
# STRATÉGIE DE REJOUABILITÉ : auto-incrément, PAS suppression+recréation.
# La suppression d'un objet Purview (DLP Policy, label, SIT...) est asynchrone — jusqu'à
# 24h de propagation. Recréer un objet du même nom pendant cette fenêtre échoue avec
# CompliancePolicyAlreadyExistsInScenarioException, même si Remove- a retourné un succès
# apparent. Ce n'est pas un cas isolé : même famille de comportement déjà rencontrée sur les
# labels (chapitre 02). Le script cherche donc un nom disponible (suffixe -v2, -v3...)
# plutôt que de tenter une suppression qui bloquerait le développement pendant 24h.
#
# Module requis : ExchangeOnlineManagement
# Connexion : Connect-IPPSSession (DLP Policy/Rule, SIT) + Connect-ExchangeOnline
#             (résolution du template via Get-RMSTemplate)
# ========================================================================================

# --- OUVERTURE ---
Get-PSSession | Remove-PSSession
Connect-IPPSSession -UserPrincipalName GeptorAdmin@0n4mg.onmicrosoft.com -ShowBanner:$false
Connect-ExchangeOnline -UserPrincipalName GeptorAdmin@0n4mg.onmicrosoft.com -ShowBanner:$false

# --- ÉTAPE 0 : Variables à confirmer avant exécution ---
$SitName = "Cerberus Corp - Numéro de Badge Interne"
$TemplateNameOverride = $null

# --- ÉTAPE 1 : Garde-fou — le SIT custom doit exister ---
Write-Host "1. Vérification de l'existence du SIT '$SitName'..." -ForegroundColor Cyan

$SitObject = Get-DlpSensitiveInformationType -Identity $SitName -ErrorAction SilentlyContinue

if (-not $SitObject) {
    Write-Host "-> ARRÊT : aucun SIT nommé '$SitName' trouvé sur ce tenant." -ForegroundColor Red
    Write-Host "   SIT custom disponibles :" -ForegroundColor Yellow
    Get-DlpSensitiveInformationType |
        Where-Object { $_.Publisher -ne "Microsoft Corporation" } |
        Select-Object Name | Format-Table -AutoSize
    Get-PSSession | Remove-PSSession
    return
}
Write-Host "-> OK : SIT trouvé.`n" -ForegroundColor Green

# --- ÉTAPE 2 : Garde-fou — RMS doit être actif ---
$IRMConfig = Get-IRMConfiguration
if (-not $IRMConfig.AzureRMSLicensingEnabled) {
    Write-Host "-> ARRÊT : RMS n'est pas actif sur le tenant (voir exo 3a)." -ForegroundColor Red
    Get-PSSession | Remove-PSSession
    return
}

# --- ÉTAPE 3 : Résolution du template de chiffrement simple (EN + FR, ou override) ---
Write-Host "3. Résolution du template RMS de chiffrement simple..." -ForegroundColor Cyan

if ($TemplateNameOverride) {
    $Template = $TemplateNameOverride
    Write-Host "-> Override manuel utilisé : '$Template'`n" -ForegroundColor Yellow
}
else {
    $AllTemplates = Get-RMSTemplate
    $PositiveKeywords = "Encrypt|Chiffrer"
    $NegativeKeywords = "Forward|transférer"

    $EncryptTemplate = $AllTemplates | Where-Object {
        $_.Name -match $PositiveKeywords -and $_.Name -notmatch $NegativeKeywords
    } | Select-Object -First 1

    if (-not $EncryptTemplate) {
        Write-Host "-> ARRÊT : aucun template résolu automatiquement (EN/FR)." -ForegroundColor Red
        $AllTemplates | Select-Object Name | Format-Table -AutoSize
        Get-PSSession | Remove-PSSession
        return
    }
    $Template = $EncryptTemplate.Name
    Write-Host "-> Template résolu automatiquement : '$Template'`n" -ForegroundColor Green
}

# --- ÉTAPE 4 : Recherche d'un nom disponible (auto-incrément) ---
# Policy ET Rule sont cherchées ensemble avec le même suffixe, pour rester visuellement
# synchronisées (évite un "Policy-v3" rattaché à une "Rule-v2" qui désoriente à la lecture
# six mois plus tard). On vérifie l'existence de l'une OU l'autre à chaque tentative.
Write-Host "4. Recherche d'un nom disponible pour la policy/rule..." -ForegroundColor Cyan

$BasePolicyName = "DLP-N7-Classification-Chiffrement"
$BaseRuleName   = "OME-N7-Classification-Sortant"
$PolicyName     = $BasePolicyName
$RuleName       = $BaseRuleName
$Counter        = 2

while (
    (Get-DlpCompliancePolicy -Identity $PolicyName -ErrorAction SilentlyContinue) -or
    (Get-DlpComplianceRule -Identity $RuleName -ErrorAction SilentlyContinue)
) {
    Write-Host "   '$PolicyName' / '$RuleName' déjà pris (ou suppression en attente) — test -v$Counter..." -ForegroundColor Yellow
    $PolicyName = "$BasePolicyName-v$Counter"
    $RuleName   = "$BaseRuleName-v$Counter"
    $Counter++
}
Write-Host "-> Noms retenus : Policy='$PolicyName' / Rule='$RuleName'`n" -ForegroundColor Green

# --- ÉTAPE 5 : Définition de la condition de classification ---
$ClassificationCondition = @(
    @{ Name = $SitName; minCount = "1" }
)

Write-Host "5. Paramètres de la policy/rule :" -ForegroundColor Cyan
Write-Host "   Policy     : $PolicyName" -ForegroundColor Gray
Write-Host "   Rule       : $RuleName"   -ForegroundColor Gray
Write-Host "   Condition  : SIT '$SitName' (1+ occurrence)" -ForegroundColor Gray
Write-Host "   Template   : $Template`n" -ForegroundColor Gray

# --- ÉTAPE 6 : Création de la DLP Policy en mode test ---
Write-Host "6. Création de la DLP Policy en mode TestWithNotifications..." -ForegroundColor Cyan

try {
    New-DlpCompliancePolicy -Name $PolicyName -ExchangeLocation "All" `
        -Mode TestWithNotifications -ErrorAction Stop | Out-Null
    Write-Host "-> Succès : policy créée en mode test.`n" -ForegroundColor Green
}
catch {
    Write-Host "-> Échec de la création de la policy : $_`n" -ForegroundColor Red
    Get-PSSession | Remove-PSSession
    return
}

# --- ÉTAPE 7 : Création de la DLP Rule (avec repli de template EN/FR) ---
Write-Host "7. Création de la DLP Rule..." -ForegroundColor Cyan

# Le backend DLP n'accepte pas toujours le nom localisé que Get-RMSTemplate (Exchange
# Online) a pourtant validé — découvert en testant 'Chiffrer' (échoue, NoRmsTemplateFound
# Exception) puis 'Encrypt' (fonctionne). On teste donc plusieurs candidats.
$TemplateCandidates = @($Template)
if ($TemplateCandidates -notcontains "Encrypt") { $TemplateCandidates += "Encrypt" }

$RuleCreated = $false
foreach ($CandidateTemplate in $TemplateCandidates) {
    try {
        New-DlpComplianceRule -Name $RuleName -Policy $PolicyName `
            -ContentContainsSensitiveInformation $ClassificationCondition `
            -EncryptRMSTemplate $CandidateTemplate -ErrorAction Stop | Out-Null

        Write-Host "-> Succès avec le template '$CandidateTemplate'.`n" -ForegroundColor Green
        $Template = $CandidateTemplate
        $RuleCreated = $true
        break
    }
    catch {
        Write-Host "-> Échec avec '$CandidateTemplate' : $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

if (-not $RuleCreated) {
    Write-Host "-> ARRÊT : aucun nom de template testé n'a fonctionné pour EncryptRMSTemplate." -ForegroundColor Red
    Write-Host "   Candidats testés : $($TemplateCandidates -join ', ')" -ForegroundColor Yellow
    # Policy orpheline sans règle — on ne tente PAS de la supprimer (24h de propagation,
    # bloquerait le prochain run). On la laisse, l'auto-incrément de l'étape 4 la
    # contournera au prochain essai.
    Get-PSSession | Remove-PSSession
    return
}

# --- ÉTAPE 8 : Vérification en mode test ---
Write-Host "8. Vérification de la policy/rule créée..." -ForegroundColor Cyan
Start-Sleep -Seconds 2

Get-DlpCompliancePolicy -Identity $PolicyName | Select-Object Name, Mode, Enabled | Format-List

# -Identity seul — Get-DlpComplianceRule refuse -Identity ET -Policy ensemble
# (PolicyAndIdentityParameterUsedTogetherException).
Get-DlpComplianceRule -Identity $RuleName | Select-Object Name, Disabled | Format-List

# --- ÉTAPE 9 : Bascule en mode Enable ---
Write-Host "9. Bascule de la policy en mode Enable..." -ForegroundColor Cyan

try {
    Set-DlpCompliancePolicy -Identity $PolicyName -Mode Enable -ErrorAction Stop
    Write-Host "-> Succès : policy active en Enable.`n" -ForegroundColor Green
}
catch {
    Write-Host "-> Échec de la bascule : $_`n" -ForegroundColor Red
}

# --- ÉTAPE 10 : Vérification finale ---
Write-Host "10. État final..." -ForegroundColor Cyan
Start-Sleep -Seconds 2

$FinalPolicy = Get-DlpCompliancePolicy -Identity $PolicyName
$FinalPolicy | Select-Object Name, Mode, Enabled | Format-List

if ($FinalPolicy.Mode -eq "Enable") {
    Write-Host "-> OK : policy active.`n" -ForegroundColor Green
} else {
    Write-Host "-> ATTENTION : état inattendu — vérifier Mode ci-dessus.`n" -ForegroundColor Yellow
}

# --- RÉSUMÉ ---
Write-Host "=== RÉSUMÉ ===" -ForegroundColor Magenta
[PSCustomObject]@{
    Policy    = $PolicyName
    Rule      = $RuleName
    Mode      = $FinalPolicy.Mode
    Condition = "SIT: $SitName"
    Template  = $Template
} | Format-List

# --- COMMENT TESTER MANUELLEMENT ---
Write-Host "Pour tester : envoyer un message de Shepard@0n4mg.onmicrosoft.com vers" -ForegroundColor Gray
Write-Host "Garrus@0n4mg.onmicrosoft.com avec un numéro GCORP-XXXXX (ex: GCORP-74103) et un" -ForegroundColor Gray
Write-Host "mot corroborant ('badge', 'matricule'). Vérifier via Activity Explorer (pas le" -ForegroundColor Gray
Write-Host "message trace classique) que '$RuleName' s'est déclenchée." -ForegroundColor Gray

# --- NETTOYAGE MÉMOIRE ---
Remove-Variable SitName, TemplateNameOverride, SitObject, IRMConfig, AllTemplates, `
    EncryptTemplate, Template, BasePolicyName, BaseRuleName, PolicyName, RuleName, Counter, `
    ClassificationCondition, TemplateCandidates, RuleCreated, FinalPolicy `
    -ErrorAction SilentlyContinue

# --- FERMETURE ---
Get-PSSession | Remove-PSSession
Write-Host "`nSessions fermées." -ForegroundColor Magenta
