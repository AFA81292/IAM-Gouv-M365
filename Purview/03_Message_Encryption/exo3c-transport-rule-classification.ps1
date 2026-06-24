# ========================================================================================
# Exercice 3c : Purview — Message Encryption — DLP Compliance Rule déclenchée
#               par classification SIT (chiffrement OME automatique)
# ========================================================================================
# Concept : Chiffrer automatiquement un mail à la détection du SIT custom
# "Cerberus Corp - Numéro de Badge Interne" (créé en exercice 1b), via une
# DLP Compliance Rule utilisant l'action EncryptRMSTemplate.
#
# Ce que fait ce script :
#   1. Reset total de session (dual session IPPS + EXO)
#   2. Vérifie l'existence du SIT custom et l'état RMS
#   3. Résout le template de chiffrement (EN + FR, ou override manuel)
#   4. Recherche des noms disponibles pour policy et rule (auto-incrément synchronisé)
#   5. Crée la DLP Policy en mode TestWithNotifications
#   6. Crée la DLP Rule avec repli de template EN/FR
#   7. Vérifie en mode test
#   8. Bascule en mode Enable
#   9. Vérifie l'état final
#  10. Ferme proprement toutes les sessions
#
# DÉCOUVERTE TECHNIQUE — Dépréciation de MessageContainsDataClassifications dans les ETR :
#   Depuis aka.ms/NoDLPinETRs, il n'est plus possible de déclencher une Transport Rule
#   Exchange sur la présence d'un SIT. La solution supportée est la DLP Compliance Rule
#   avec l'action -EncryptRMSTemplate, gérée depuis le Security & Compliance Center
#   (Connect-IPPSSession), et non depuis Exchange (Connect-ExchangeOnline).
#
# DÉCOUVERTE TECHNIQUE — Nom de template localisé vs backend DLP :
#   Get-RMSTemplate (Exchange Online) retourne le nom localisé : "Chiffrer" sur un tenant FR.
#   Mais le backend DLP (IPPS) n'accepte pas ce nom localisé dans -EncryptRMSTemplate —
#   il attend "Encrypt". Les deux modules parlent au même moteur RMS mais avec des
#   mappings de noms distincts. Solution : boucle de repli sur candidats EN + FR.
#
# STRATÉGIE DE REJOUABILITÉ — auto-incrément, PAS suppression + recréation :
#   La suppression d'un objet Purview (DLP Policy, Rule, label, SIT) est asynchrone —
#   jusqu'à 24h de propagation. Recréer un objet du même nom pendant cette fenêtre
#   échoue avec CompliancePolicyAlreadyExistsInScenarioException même si Remove- a
#   retourné un succès apparent. On cherche un nom disponible (suffixe -v2, -v3...)
#   plutôt que de tenter une suppression qui bloquerait le développement pendant 24h.
#
# Dual session requise :
#   Connect-IPPSSession → DLP Policy/Rule, SIT (Security & Compliance)
#   Connect-ExchangeOnline → Get-RMSTemplate, Get-IRMConfiguration (Exchange Online)
#
# Module requis : ExchangeOnlineManagement
# ========================================================================================

# --- OUVERTURE — RESET DE SESSION TOTAL ---
# REX : cette ouverture purge les PSSession résiduelles sans passer par
# Disconnect-ExchangeOnline / Disconnect-IPPSSession car les deux sessions
# coexistent dans le même contexte PowerShell. Get-PSSession | Remove-PSSession
# les ferme toutes deux proprement en un seul appel.
# $env:MSAL_ENABLE_WAM = "0" est requis pour Connect-IPPSSession — contournement
# du cache WAM qui bloque l'authentification interactive sur certains environnements.
Get-PSSession | Remove-PSSession
$env:MSAL_ENABLE_WAM = "0"
Connect-IPPSSession  -UserPrincipalName GeptorAdmin@0n4mg.onmicrosoft.com -ShowBanner:$false
Connect-ExchangeOnline -UserPrincipalName GeptorAdmin@0n4mg.onmicrosoft.com -ShowBanner:$false

# ========================================================================================
# ÉTAPE 0 : Variables à confirmer avant exécution
# ========================================================================================
# $TemplateNameOverride : si renseigné, saute toute résolution automatique EN/FR.
# Renseigner uniquement si l'heuristique de l'étape 3 échoue sur ce tenant.
# Exemple : $TemplateNameOverride = "Encrypt"
$SitName              = "Cerberus Corp - Numéro de Badge Interne"
$TemplateNameOverride = $null

# ========================================================================================
# ÉTAPE 1 : Garde-fou — le SIT custom doit exister
# ========================================================================================
Write-Host "1. Vérification de l'existence du SIT '$SitName'..." -ForegroundColor Cyan

# Le SIT "Cerberus Corp - Numéro de Badge Interne" a été créé en exercice 1b.
# Sans ce SIT, la condition de la DLP Rule ne peut pas être résolue par le backend Purview.
$SitObject = Get-DlpSensitiveInformationType -Identity $SitName -ErrorAction SilentlyContinue

if (-not $SitObject) {
    Write-Host "-> ARRÊT : SIT '$SitName' introuvable sur ce tenant." -ForegroundColor Red
    Write-Host "   SIT custom disponibles (non-Microsoft) :" -ForegroundColor Yellow
    Get-DlpSensitiveInformationType |
        Where-Object { $_.Publisher -ne "Microsoft Corporation" } |
        Select-Object Name | Format-Table -AutoSize
    Get-PSSession | Remove-PSSession
    return
}
Write-Host "-> OK : SIT trouvé.`n" -ForegroundColor Green

# ========================================================================================
# ÉTAPE 2 : Garde-fou — RMS doit être actif
# ========================================================================================
Write-Host "2. Vérification du prérequis RMS..." -ForegroundColor Cyan

# Get-IRMConfiguration s'exécute via la session Exchange Online (pas IPPS).
# Les deux sessions coexistent — PowerShell route automatiquement chaque cmdlet
# vers la session qui l'expose.
$IRMConfig = Get-IRMConfiguration
if (-not $IRMConfig.AzureRMSLicensingEnabled) {
    Write-Host "-> ARRÊT : RMS non actif sur le tenant (voir exercice 3a)." -ForegroundColor Red
    Write-Host "   Activer via : Set-IRMConfiguration -AzureRMSLicensingEnabled `$true" -ForegroundColor Yellow
    Get-PSSession | Remove-PSSession
    return
}
Write-Host "-> OK : RMS actif.`n" -ForegroundColor Green

# ========================================================================================
# ÉTAPE 3 : Résolution du template de chiffrement simple
# ========================================================================================
Write-Host "3. Résolution du template RMS de chiffrement simple..." -ForegroundColor Cyan

if ($TemplateNameOverride) {
    $Template = $TemplateNameOverride
    Write-Host "-> Override manuel utilisé : '$Template'`n" -ForegroundColor Yellow
}
else {
    # Get-RMSTemplate s'exécute via la session Exchange Online.
    # Heuristique EN + FR — même logique qu'en exercice 3b.
    # Limite documentée : tenant dans une 3e langue → renseigner $TemplateNameOverride.
    $AllTemplates     = Get-RMSTemplate
    $PositiveKeywords = "Encrypt|Chiffrer"
    $NegativeKeywords = "Forward|transférer"

    $EncryptTemplate = $AllTemplates | Where-Object {
        $_.Name -match $PositiveKeywords -and $_.Name -notmatch $NegativeKeywords
    } | Select-Object -First 1

    if (-not $EncryptTemplate) {
        Write-Host "-> ARRÊT : aucun template résolu automatiquement (heuristique EN/FR)." -ForegroundColor Red
        Write-Host "   Templates disponibles sur ce tenant :" -ForegroundColor Yellow
        $AllTemplates | Select-Object Name | Format-Table -AutoSize
        Write-Host "   -> Renseigner `$TemplateNameOverride en ÉTAPE 0 avec le nom exact." -ForegroundColor Yellow
        Get-PSSession | Remove-PSSession
        return
    }
    $Template = $EncryptTemplate.Name
    Write-Host "-> Template résolu automatiquement : '$Template'`n" -ForegroundColor Green
}

# ========================================================================================
# ÉTAPE 4 : Recherche de noms disponibles (auto-incrément synchronisé policy + rule)
# ========================================================================================
Write-Host "4. Recherche de noms disponibles pour la policy et la rule..." -ForegroundColor Cyan

# Policy et Rule incrémentent ensemble avec le même suffixe (-v2, -v3...).
# Raison : éviter une "Policy-v3" rattachée à une "Rule-v2" — la désynchronisation
# des suffixes rend le tenant illisible six mois plus tard.
# On vérifie l'existence de l'UNE OU l'autre à chaque tentative.
$BasePolicyName = "DLP-N7-Classification-Chiffrement"
$BaseRuleName   = "OME-N7-Classification-Sortant"
$PolicyName     = $BasePolicyName
$RuleName       = $BaseRuleName
$Counter        = 2

while (
    (Get-DlpCompliancePolicy -Identity $PolicyName -ErrorAction SilentlyContinue) -or
    (Get-DlpComplianceRule   -Identity $RuleName   -ErrorAction SilentlyContinue)
) {
    Write-Host "   '$PolicyName' / '$RuleName' déjà pris (ou suppression asynchrone en attente) — test -v$Counter..." -ForegroundColor Yellow
    $PolicyName = "$BasePolicyName-v$Counter"
    $RuleName   = "$BaseRuleName-v$Counter"
    $Counter++
}
Write-Host "-> Noms retenus : Policy='$PolicyName' / Rule='$RuleName'`n" -ForegroundColor Green

# ========================================================================================
# ÉTAPE 5 : Définition de la condition de classification
# ========================================================================================
Write-Host "5. Paramètres de la policy/rule :" -ForegroundColor Cyan

# minCount = "1" : une seule occurrence du SIT suffit pour déclencher la rule.
# Pas de confidenceLevel forcé ici — le SIT custom Cerberus a son propre seuil
# de confiance défini à la création (exercice 1b).
$ClassificationCondition = @(
    @{ Name = $SitName; minCount = "1" }
)

Write-Host "   Policy     : $PolicyName" -ForegroundColor Gray
Write-Host "   Rule       : $RuleName"   -ForegroundColor Gray
Write-Host "   Condition  : SIT '$SitName' (1+ occurrence)" -ForegroundColor Gray
Write-Host "   Template   : $Template`n" -ForegroundColor Gray

# ========================================================================================
# ÉTAPE 6 : Création de la DLP Policy en mode TestWithNotifications
# ========================================================================================
Write-Host "6. Création de la DLP Policy '$PolicyName' en mode TestWithNotifications..." -ForegroundColor Cyan

# -ExchangeLocation "All" : la policy couvre tous les utilisateurs Exchange du tenant.
# -Mode TestWithNotifications : évalue la rule, génère des alertes dans Activity Explorer,
# mais N'APPLIQUE PAS le chiffrement. Permet de valider les matches avant enforcement.
try {
    New-DlpCompliancePolicy `
        -Name            $PolicyName `
        -ExchangeLocation "All" `
        -Mode            TestWithNotifications `
        -ErrorAction     Stop | Out-Null
    Write-Host "-> Policy créée en mode TestWithNotifications.`n" -ForegroundColor Green
}
catch {
    Write-Host "-> Échec de la création de la policy : $_`n" -ForegroundColor Red
    Get-PSSession | Remove-PSSession
    return
}

# ========================================================================================
# ÉTAPE 7 : Création de la DLP Rule avec boucle de repli sur le nom de template
# ========================================================================================
Write-Host "7. Création de la DLP Rule '$RuleName'..." -ForegroundColor Cyan

# DÉCOUVERTE TECHNIQUE : le backend DLP (IPPS) et le module Exchange Online utilisent
# des mappings de noms de templates distincts pour le même moteur RMS.
# "Chiffrer" (retourné par Get-RMSTemplate sur tenant FR) → NoRmsTemplateFoundException
#   côté IPPS.
# "Encrypt" → accepté par le backend DLP même sur tenant FR.
# Solution : boucle de repli qui teste d'abord le nom résolu à l'étape 3,
# puis "Encrypt" en fallback si le premier candidat échoue.
$TemplateCandidates = @($Template)
if ($TemplateCandidates -notcontains "Encrypt") { $TemplateCandidates += "Encrypt" }

$RuleCreated = $false
foreach ($CandidateTemplate in $TemplateCandidates) {
    try {
        New-DlpComplianceRule `
            -Name                                $RuleName `
            -Policy                              $PolicyName `
            -ContentContainsSensitiveInformation $ClassificationCondition `
            -EncryptRMSTemplate                  $CandidateTemplate `
            -ErrorAction                         Stop | Out-Null

        Write-Host "-> Rule créée avec le template '$CandidateTemplate'.`n" -ForegroundColor Green
        $Template    = $CandidateTemplate
        $RuleCreated = $true
        break
    }
    catch {
        Write-Host "-> Échec avec '$CandidateTemplate' : $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

if (-not $RuleCreated) {
    Write-Host "-> ARRÊT : aucun nom de template testé n'a fonctionné pour -EncryptRMSTemplate." -ForegroundColor Red
    Write-Host "   Candidats testés : $($TemplateCandidates -join ', ')" -ForegroundColor Yellow
    # La policy est orpheline (sans rule). On ne tente PAS de la supprimer —
    # la suppression asynchrone Purview bloquerait le prochain run pendant 24h.
    # L'auto-incrément de l'étape 4 la contournera automatiquement au prochain essai.
    Write-Host "   Policy orpheline '$PolicyName' laissée en place — l'auto-incrément la contournera." -ForegroundColor Yellow
    Get-PSSession | Remove-PSSession
    return
}

# ========================================================================================
# ÉTAPE 8 : Vérification en mode test
# ========================================================================================
Write-Host "8. Vérification de la policy/rule en mode test..." -ForegroundColor Cyan

# REX : la propagation des objets DLP Purview n'est pas instantanée.
# 30 secondes couvrent la latence de réplication backend Purview.
Start-Sleep -Seconds 30

Get-DlpCompliancePolicy -Identity $PolicyName |
    Select-Object Name, Mode, Enabled | Format-List

# DÉCOUVERTE TECHNIQUE : Get-DlpComplianceRule refuse -Identity ET -Policy ensemble
# (PolicyAndIdentityParameterUsedTogetherException). On utilise -Identity seul.
Get-DlpComplianceRule -Identity $RuleName |
    Select-Object Name, Disabled | Format-List

# ========================================================================================
# ÉTAPE 9 : Bascule en mode Enable
# ========================================================================================
Write-Host "9. Bascule de la policy en mode Enable..." -ForegroundColor Cyan

# Mode Enable = la DLP Rule s'applique réellement — le chiffrement OME est déclenché
# à la détection du SIT sur les mails Exchange. À n'activer qu'après validation
# des résultats en mode TestWithNotifications via Activity Explorer.
try {
    Set-DlpCompliancePolicy -Identity $PolicyName -Mode Enable -ErrorAction Stop
    Write-Host "-> Policy basculée en mode Enable.`n" -ForegroundColor Green
}
catch {
    Write-Host "-> Échec de la bascule : $_`n" -ForegroundColor Red
}

# ========================================================================================
# ÉTAPE 10 : Vérification finale
# ========================================================================================
Write-Host "10. Vérification de l'état final..." -ForegroundColor Cyan

Start-Sleep -Seconds 30

$FinalPolicy = Get-DlpCompliancePolicy -Identity $PolicyName -ErrorAction SilentlyContinue

if ($FinalPolicy) {
    $FinalPolicy | Select-Object Name, Mode, Enabled | Format-List

    if ($FinalPolicy.Mode -eq "Enable") {
        Write-Host "-> OK : policy active en mode Enable.`n" -ForegroundColor Green
    } else {
        Write-Host "-> ATTENTION : état inattendu — vérifier Mode ci-dessus.`n" -ForegroundColor Yellow
    }
} else {
    Write-Host "-> ATTENTION : policy non trouvée lors de la vérification finale." -ForegroundColor Red
}

# ========================================================================================
# RÉSUMÉ
# ========================================================================================
Write-Host "=== RÉSUMÉ ===" -ForegroundColor Magenta
[PSCustomObject]@{
    PolicyCréée  = $PolicyName
    RuleCréée    = $RuleName
    Mode         = if ($FinalPolicy) { $FinalPolicy.Mode } else { "Non vérifié" }
    Condition    = "SIT: $SitName (1+ occurrence)"
    Template     = $Template
    TestManuel   = "Envoyer depuis Shepard@ vers Garrus@ avec un numéro GCORP-XXXXX (ex: GCORP-74103) et un mot corroborant ('badge', 'matricule')."
    Vérification = "Purview > Activity Explorer — vérifier que '$RuleName' s'est déclenchée."
} | Format-List

# ========================================================================================
# NETTOYAGE MÉMOIRE
# ========================================================================================
Remove-Variable SitName, TemplateNameOverride, SitObject, IRMConfig,
                AllTemplates, EncryptTemplate, Template,
                BasePolicyName, BaseRuleName, PolicyName, RuleName, Counter,
                ClassificationCondition, TemplateCandidates, RuleCreated,
                FinalPolicy `
                -ErrorAction SilentlyContinue

# ========================================================================================
# FERMETURE — RESET DE SESSION TOTAL
# ========================================================================================
# Get-PSSession | Remove-PSSession ferme les deux sessions simultanément (IPPS + EXO).
Get-PSSession | Remove-PSSession
Write-Host "Sessions IPPS et Exchange Online fermées proprement." -ForegroundColor Magenta
