# ========================================================================================
# Exercice 3c : Message Encryption — DLP Compliance Rule déclenchée par classification (SIT)
# ========================================================================================
# Concept : Chiffrer un mail à la détection du SIT custom "Cerberus Corp - Numéro de Badge
# Interne" (créé en 1b), avec la même intention que 3b (chiffrement automatique, sans
# intervention utilisateur) mais via le mécanisme correct pour une condition de
# classification de contenu.
#
# CHANGEMENT D'ARCHITECTURE PAR RAPPORT À LA VERSION PRÉCÉDENTE :
# Le premier essai utilisait New-TransportRule -MessageContainsDataClassifications, qui a
# échoué avec l'erreur "Vous ne pouvez pas créer ou mettre à jour des règles de flux de
# courrier liées à DLP" (https://aka.ms/NoDLPinETRs). Ce n'est pas un bug de syntaxe :
# Microsoft a retiré ce prédicat des Exchange Transport Rules en novembre 2023. Le mécanisme
# supporté pour "chiffrer sur détection de classification" est désormais une DLP Compliance
# Rule (New-DlpComplianceRule), pas une Transport Rule.
#
# Conséquence pratique : l'objet créé par ce script n'apparaîtra PAS dans Get-TransportRule
# (contrairement à 3b et au futur 3d) — il faut interroger Get-DlpComplianceRule. Le futur
# exo d'audit (3e) devra donc vérifier les deux types d'objets séparément.
#
# Simplification assumée : pas d'équivalent direct à FromScope "InOrganization" sur une DLP
# Rule de manière fiable — la règle se déclenche sur la classification, sans restriction de
# direction. Documenté ici plutôt que deviné dans le code.
#
# Prérequis : le SIT custom de l'exo 1b doit exister (vérifié, pas supposé) et le template
# de chiffrement résolu de la même manière qu'en 3b.
#
# Module requis : ExchangeOnlineManagement
# Connexion : Connect-IPPSSession (DLP Policy/Rule + vérification SIT — TOUT le cœur du
#             script tourne ici) + Connect-ExchangeOnline (uniquement pour résoudre le nom
#             du template via Get-RMSTemplate, comme en 3a/3b)
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

# --- ÉTAPE 4 : Définition des variables de la policy/rule ---
# Une DLP Compliance Rule ne peut pas exister seule — elle est toujours rattachée à une
# DLP Compliance Policy, qui définit le périmètre (ici : tout Exchange Online).
$PolicyName = "DLP-N7-Classification-Chiffrement"
$RuleName   = "OME-N7-Classification-Sortant"

# Même syntaxe de condition que MessageContainsDataClassifications sur les Transport
# Rules — coïncidence pratique, les deux objets partagent ce format de hashtable.
$ClassificationCondition = @(
    @{ Name = $SitName; minCount = "1" }
)

Write-Host "4. Paramètres de la policy/rule :" -ForegroundColor Cyan
Write-Host "   Policy     : $PolicyName" -ForegroundColor Gray
Write-Host "   Rule       : $RuleName"   -ForegroundColor Gray
Write-Host "   Condition  : SIT '$SitName' (1+ occurrence)" -ForegroundColor Gray
Write-Host "   Template   : $Template`n" -ForegroundColor Gray

# --- ÉTAPE 5 : Création de la DLP Policy en mode test ---
# TestWithNotifications : la policy est active mais aucune action des règles qu'elle
# contient n'est réellement appliquée — équivalent fonctionnel du AuditAndNotify des
# Transport Rules, adapté au vocabulaire DLP.
Write-Host "5. Création de la DLP Policy en mode TestWithNotifications..." -ForegroundColor Cyan

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

# --- ÉTAPE 6 : Création de la DLP Rule (rattachée à la policy) ---
Write-Host "6. Création de la DLP Rule..." -ForegroundColor Cyan

$RuleParams = @{
    Name                              = $RuleName
    Policy                            = $PolicyName
    ContentContainsSensitiveInformation = $ClassificationCondition
    EncryptRMSTemplate                = $Template
}

try {
    New-DlpComplianceRule @RuleParams -ErrorAction Stop | Out-Null
    Write-Host "-> Succès : règle créée et rattachée à la policy.`n" -ForegroundColor Green
}
catch {
    Write-Host "-> Échec de la création de la règle : $_`n" -ForegroundColor Red
    # Nettoyage : pas de policy orpheline sans règle si la création de la règle échoue
    Remove-DlpCompliancePolicy -Identity $PolicyName -Confirm:$false -ErrorAction SilentlyContinue
    Get-PSSession | Remove-PSSession
    return
}

# --- ÉTAPE 7 : Vérification en mode test ---
Write-Host "7. Vérification de la policy/rule créée..." -ForegroundColor Cyan
Start-Sleep -Seconds 2

Get-DlpCompliancePolicy -Identity $PolicyName | Select-Object Name, Mode, Enabled | Format-List
Get-DlpComplianceRule -Identity $RuleName -Policy $PolicyName |
    Select-Object Name, Disabled | Format-List

# --- ÉTAPE 8 : Bascule en mode Enable ---
# Comme pour les Transport Rules, ce point de contrôle existerait en prod après lecture
# des logs de test (ici : Activity Explorer / Content Explorer côté Purview).
Write-Host "8. Bascule de la policy en mode Enable..." -ForegroundColor Cyan

try {
    Set-DlpCompliancePolicy -Identity $PolicyName -Mode Enable -ErrorAction Stop
    Write-Host "-> Succès : policy active en Enable.`n" -ForegroundColor Green
}
catch {
    Write-Host "-> Échec de la bascule : $_`n" -ForegroundColor Red
}

# --- ÉTAPE 9 : Vérification finale ---
Write-Host "9. État final..." -ForegroundColor Cyan
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
# Envoyer un message de Shepard@0n4mg.onmicrosoft.com vers Garrus@0n4mg.onmicrosoft.com
# contenant un faux numéro de badge GCORP-XXXXX (ex: GCORP-74103) avec un mot corroborant
# ("badge", "matricule"). Le matching DLP n'apparaît PAS dans le message trace classique
# (réservé aux Transport Rules) — vérifier via Purview > Data loss prevention > Activity
# explorer, ou via Get-DlpDetailReport.

# --- NETTOYAGE MÉMOIRE ---
Remove-Variable SitName, TemplateNameOverride, SitObject, IRMConfig, AllTemplates, `
    EncryptTemplate, Template, PolicyName, RuleName, ClassificationCondition, RuleParams, `
    FinalPolicy -ErrorAction SilentlyContinue

# --- FERMETURE ---
Get-PSSession | Remove-PSSession
Write-Host "`nSessions fermées." -ForegroundColor Magenta
