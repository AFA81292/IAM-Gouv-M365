# ========================================================================================
# Exercice 4c : Purview — DLP — Policy basée sur un label de sensibilité (Sensitivity Label)
# ========================================================================================
# Concept : 4a/4b détectaient un SIT (pattern dans le contenu brut).
# Ici, la condition est "ce fichier PORTE le label NormandySR2", peu importe son contenu.
# Les deux approches sont complémentaires — défense en profondeur :
#   - Un fichier Confidentiel sans numéro de CB reste protégé par 4c
#   - Un fichier non-labellisé avec un CB reste couvert par 4a/4b
#
# Ce que fait ce script :
#   1. Reset total de session
#   2. Résout les GUIDs des labels cibles (NormandySR2 - Confidentiel/Interne/Externe)
#   3. Recherche des noms disponibles (auto-incrément)
#   4. Crée la DLP policy sur SharePoint + OneDrive en mode TestWithNotifications
#   5. Construit le JSON -AdvancedRule (labels en OR + AccessScope externe intégré)
#   6. Crée la règle avec blocage PerUser
#   7. Vérifie la création depuis la source de vérité
#   8. Ferme proprement toutes les sessions
#
# DÉCOUVERTE TECHNIQUE — Pas de paramètre -ContentContainsSensitiveLabel :
#   Ce paramètre n'existe pas dans New-DlpComplianceRule. La condition sur label
#   passe obligatoirement par -AdvancedRule (JSON), construit ici en hashtables
#   PowerShell → ConvertTo-Json. Aucun fichier externe requis — 100% dans ce script.
#
# DÉCOUVERTE TECHNIQUE — AccessScope dans le JSON, pas en paramètre séparé :
#   Avec -BlockAccess et une condition de partage externe, le moteur DLP exige que
#   "ContentSharedFromMicrosoftOneDriveForBusiness" ou "AccessScope NotInOrganization"
#   soit une condition DANS le JSON en AND avec le bloc labels — pas passé comme
#   paramètre -AccessScope séparé. Sans ça, la règle se crée mais retourne une erreur
#   à l'enforcement : "you must have 'Content is shared with people outside your
#   organization' as the first condition along with operator AND".
#
# OR vs AND entre labels :
#   Un fichier ne porte qu'UN seul sensitivity label à la fois. Matcher
#   "Confidentiel ET Interne ET Externe" simultanément n'a jamais de sens —
#   c'est toujours OR entre labels d'une même famille.
#
# Cible SharePoint + OneDrive uniquement :
#   Les labels de sensibilité sur fichiers ne s'appliquent pas aux emails Exchange
#   dans ce contexte. Le chiffrement par label sur Exchange est couvert en exercice 3.
#
# Prérequis : labels créés en exercices 2a/2b/2c (NormandySR2 - Confidentiel/Interne/Externe)
# Module requis : ExchangeOnlineManagement
# Connexion     : Connect-IPPSSession
# ========================================================================================

# --- OUVERTURE — RESET DE SESSION TOTAL ---
# Même séquence que les exercices précédents : Disconnect → Remove-PSSession →
# workaround WAM → reconnexion propre.
Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
Get-PSSession | Remove-PSSession
$env:MSAL_ENABLE_WAM = "0"
Connect-IPPSSession -UserPrincipalName GeptorAdmin@0n4mg.onmicrosoft.com

# ========================================================================================
# ÉTAPE 1 : Récupération des GUIDs des labels cibles
# ========================================================================================
Write-Host "1. Récupération des GUIDs des labels NormandySR2..." -ForegroundColor Cyan

# On résout par nom → GUID au runtime plutôt que de coder les GUIDs en dur.
# Le GUID est stable tant qu'on ne recrée pas le label de zéro — plus fiable
# qu'une valeur fixée en dur qui devient obsolète si les labels sont recréés.
# Si un label est manquant, on continue avec les labels disponibles (dégradation gracieuse)
# sauf si aucun label n'est résolu — dans ce cas le script s'arrête proprement.
$LabelNames = @(
    "NormandySR2 - Confidentiel",
    "NormandySR2 - Interne",
    "NormandySR2 - Externe"
)

$LabelGuids = @()
foreach ($LabelName in $LabelNames) {
    $Label = Get-Label -Identity $LabelName -ErrorAction SilentlyContinue
    if ($Label) {
        $LabelGuids += $Label.Guid
        Write-Host "   OK : '$LabelName' — GUID : $($Label.Guid)" -ForegroundColor Gray
    } else {
        Write-Host "   MANQUANT : '$LabelName' introuvable — vérifier exercices 2a/2b/2c." -ForegroundColor Yellow
    }
}

if ($LabelGuids.Count -eq 0) {
    Write-Host "-> ARRÊT : aucun label résolu. Impossible de construire la condition DLP." -ForegroundColor Red
    Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
    Get-PSSession | Remove-PSSession
    return
}
Write-Host "-> $($LabelGuids.Count) label(s) résolu(s).`n" -ForegroundColor Green

# ========================================================================================
# ÉTAPE 2 : Recherche des noms disponibles (auto-incrément)
# ========================================================================================
Write-Host "2. Recherche des noms disponibles..." -ForegroundColor Cyan

$BasePolicyName = "DLP-Citadel-LabelBlock"
$PolicyName     = $BasePolicyName
$Counter        = 2
while (Get-DlpCompliancePolicy -Identity $PolicyName -ErrorAction SilentlyContinue) {
    Write-Host "   '$PolicyName' déjà pris — test avec suffixe -v$Counter..." -ForegroundColor Yellow
    $PolicyName = "$BasePolicyName-v$Counter"
    $Counter++
}

$BaseRuleName = "RULE-Citadel-SpectreClearance"
$RuleName     = $BaseRuleName
$Counter      = 2
while (Get-DlpComplianceRule -Identity $RuleName -ErrorAction SilentlyContinue) {
    Write-Host "   '$RuleName' déjà pris — test avec suffixe -v$Counter..." -ForegroundColor Yellow
    $RuleName = "$BaseRuleName-v$Counter"
    $Counter++
}
Write-Host "-> Policy : '$PolicyName' / Règle : '$RuleName'`n" -ForegroundColor Green

# ========================================================================================
# ÉTAPE 3 : Création de la DLP policy
# ========================================================================================
Write-Host "3. Création de la DLP policy '$PolicyName'..." -ForegroundColor Cyan

# SharePoint + OneDrive uniquement — les labels de sensibilité sur fichiers
# ne s'appliquent pas à Exchange dans ce contexte (couvert par exercice 3).
# Mode TestWithNotifications : prudence sur une policy label-based avant activation réelle.
try {
    $NewPolicy = New-DlpCompliancePolicy `
        -Name               $PolicyName `
        -SharePointLocation "All" `
        -OneDriveLocation   "All" `
        -Mode               "TestWithNotifications" `
        -Comment            "Exo 4c — Bloque partage externe fichiers NormandySR2 (Confidentiel/Interne/Externe)." `
        -ErrorAction Stop

    Write-Host "-> Policy créée : $($NewPolicy.Name) [Mode : $($NewPolicy.Mode)]`n" -ForegroundColor Green
}
catch {
    Write-Host "-> Échec de la création de la policy : $_" -ForegroundColor Red
    Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
    Get-PSSession | Remove-PSSession
    return
}

# ========================================================================================
# ÉTAPE 4 : Construction du JSON -AdvancedRule
# ========================================================================================
Write-Host "4. Construction de l'AdvancedRule (labels OR + AccessScope externe intégré)..." -ForegroundColor Cyan

# Structure du JSON AdvancedRule :
#
#   Condition (AND)
#   ├── ContentContainsSensitiveInformation
#   │   └── groups (OR)
#   │       └── labels : [GUID-Confidentiel, GUID-Interne, GUID-Externe]
#   │           type   : "Sensitivity" (obligatoire — distingue label de SIT)
#   └── AccessScope : "NotInOrganization"
#       (intégré en AND dans le JSON — pas passé comme paramètre -AccessScope séparé)
#
# Pourquoi ConvertTo-Json -Depth 100 ?
#   La structure est imbriquée sur plusieurs niveaux (Condition > SubConditions > groups > labels).
#   Sans -Depth 100, ConvertTo-Json tronque les niveaux profonds et produit un JSON invalide
#   que le backend DLP rejette avec une erreur de parsing peu explicite.
#
# -Compress : supprime les espaces et retours à la ligne dans le JSON.
#   Requis car New-DlpComplianceRule attend un JSON compact sur une seule ligne.
$LabelEntries = foreach ($Guid in $LabelGuids) {
    @{ name = $Guid; type = "Sensitivity" }
}

$AdvancedRuleObject = @{
    Version   = "1.0"
    Condition = @{
        Operator      = "And"
        SubConditions = @(
            @{
                ConditionName = "ContentContainsSensitiveInformation"
                Value         = @(
                    @{
                        groups = @(
                            @{
                                Operator = "Or"
                                name     = "Default"
                                labels   = $LabelEntries
                            }
                        )
                    }
                )
            },
            @{
                ConditionName = "AccessScope"
                Value         = "NotInOrganization"
            }
        )
    }
}

$AdvancedRuleJson = $AdvancedRuleObject | ConvertTo-Json -Depth 100 -Compress
Write-Host "-> JSON prêt ($($LabelEntries.Count) label(s) en OR, AccessScope intégré en AND).`n" -ForegroundColor Gray

# ========================================================================================
# ÉTAPE 5 : Création de la règle DLP
# ========================================================================================
Write-Host "5. Création de la règle '$RuleName'..." -ForegroundColor Cyan

# -BlockAccessScope "PerUser" : seul l'utilisateur qui tente le partage externe est bloqué.
# Les collaborateurs internes qui accèdent normalement au fichier conservent leur accès.
# Posture la moins disruptive en production — même logique qu'en exercice 4b.
try {
    $NewRule = New-DlpComplianceRule `
        -Name                   $RuleName `
        -Policy                 $PolicyName `
        -AdvancedRule           $AdvancedRuleJson `
        -BlockAccess            $true `
        -BlockAccessScope       "PerUser" `
        -NotifyUser             "LastModifier" `
        -GenerateIncidentReport "SiteAdmin" `
        -IncidentReportContent  @("All") `
        -Comment                "Exo 4c — Blocage partage externe fichiers labelisés NormandySR2 (Spectre Clearance)." `
        -ErrorAction Stop

    Write-Host "-> Règle créée : $($NewRule.Name)`n" -ForegroundColor Green
}
catch {
    Write-Host "-> Échec de la création de la règle : $_" -ForegroundColor Red
    Write-Host "   La policy '$PolicyName' a été créée mais reste orpheline." -ForegroundColor Yellow
    Write-Host "   Supprimer via : Remove-DlpCompliancePolicy -Identity '$PolicyName' -Confirm:`$false" -ForegroundColor Yellow
    Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
    Get-PSSession | Remove-PSSession
    return
}

# ========================================================================================
# ÉTAPE 6 : Vérification depuis la source de vérité
# ========================================================================================
Write-Host "6. Vérification depuis le backend Purview..." -ForegroundColor Cyan

# 30 secondes couvrent la latence de propagation du backend Purview.
Start-Sleep -Seconds 30

$CheckPolicy = Get-DlpCompliancePolicy -Identity $PolicyName -ErrorAction SilentlyContinue
$CheckRule   = Get-DlpComplianceRule   -Policy   $PolicyName -ErrorAction SilentlyContinue

if ($CheckPolicy) {
    Write-Host "-> Policy confirmée :" -ForegroundColor Green
    [PSCustomObject]@{
        Nom        = $CheckPolicy.Name
        Mode       = $CheckPolicy.Mode
        SharePoint = if ($CheckPolicy.SharePointLocation) { "All" } else { "Non configuré" }
        OneDrive   = if ($CheckPolicy.OneDriveLocation)   { "All" } else { "Non configuré" }
        DistribStatus = $CheckPolicy.DistributionStatus
    } | Format-List
} else {
    Write-Host "-> ATTENTION : policy non trouvée lors de la vérification." -ForegroundColor Red
}

if ($CheckRule) {
    Write-Host "-> Règle confirmée :" -ForegroundColor Green
    [PSCustomObject]@{
        Nom           = $CheckRule.Name
        PolicyParente = $CheckRule.ParentPolicyName
        Désactivée    = $CheckRule.Disabled
        BlocageActif  = $CheckRule.BlockAccess
        PortéeBlocage = $CheckRule.BlockAccessScope
        NotifUser     = ($CheckRule.NotifyUser -join ", ")
    } | Format-List
} else {
    Write-Host "-> ATTENTION : règle non trouvée lors de la vérification." -ForegroundColor Red
}

# ========================================================================================
# RÉSUMÉ
# ========================================================================================
Write-Host "=== RÉSUMÉ ===" -ForegroundColor Magenta
[PSCustomObject]@{
    PolicyCréée     = $PolicyName
    RègleCréée      = $RuleName
    Mode            = "TestWithNotifications (simulation — pas de blocage réel)"
    LabelsCouverts  = ($LabelNames -join " | ")
    Workloads       = "SharePoint, OneDrive"
    BlocagePerUser  = "Oui (partage externe uniquement)"
    RapportIncident = "Oui (SiteAdmin)"
    ActivationProd  = "Set-DlpCompliancePolicy -Identity '$PolicyName' -Mode Enable (cf. exo 4d)"
    DistribStatus   = if ($CheckPolicy) { $CheckPolicy.DistributionStatus } else { "Non vérifié" }
} | Format-List

Write-Host "Info : en mode TestWithNotifications, le blocage est simulé." -ForegroundColor Yellow
Write-Host "Passer en Enable via Set-DlpCompliancePolicy (cf. exercice 4d).`n" -ForegroundColor Yellow

# ========================================================================================
# NETTOYAGE MÉMOIRE
# ========================================================================================
Remove-Variable LabelNames, LabelGuids, LabelName, Label,
                BasePolicyName, PolicyName, BaseRuleName, RuleName, Counter,
                LabelEntries, AdvancedRuleObject, AdvancedRuleJson,
                NewPolicy, NewRule, CheckPolicy, CheckRule `
                -ErrorAction SilentlyContinue

# ========================================================================================
# FERMETURE — RESET DE SESSION TOTAL
# ========================================================================================
Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
Get-PSSession | Remove-PSSession
Write-Host "Sessions fermées proprement." -ForegroundColor Magenta
