# ========================================================================================
# Exercice 4c : DLP — Policy basée sur un label de sensibilité (Sensitivity Label)
# ========================================================================================
# Concept : 4a/4b détectaient un SIT (pattern dans le contenu). Ici, la condition est
# "ce fichier PORTE le label Confidentiel", peu importe son contenu. Complémentaire :
# un fichier Confidentiel sans CB reste protégé ; un fichier non-labellisé avec un CB
# reste couvert par 4a/4b. Défense en profondeur.
#
# Pas de paramètre -ContentContainsSensitiveLabel : ça n'existe pas. La condition label
# passe par -AdvancedRule (JSON), construit ici en hashtables PowerShell -> ConvertTo-Json,
# donc 100% dans ce .ps1, sans fichier externe.
#
# OR vs AND dans le groupe de labels : un fichier ne porte qu'UN seul sensitivity label
# à la fois, donc matcher "Confidentiel ET Interne ET Externe" n'a jamais de sens —
# c'est toujours OR entre plusieurs labels d'une même famille (label group + sublabels).
#
# Cible : SharePoint + OneDrive uniquement (labels sur fichiers, pas sur emails — le
# chiffrement par label sur Exchange est couvert exo 3).
#
# Prérequis : labels créés en 2a/2b/2c (NormandySR2 - Confidentiel/Interne/Externe)
# Module requis : ExchangeOnlineManagement
# Connexion : Connect-IPPSSession
# Licence requise : Microsoft Purview DLP + Information Protection (inclus E5)
# ========================================================================================

# --- OUVERTURE ---
Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
Get-PSSession | Remove-PSSession
$env:MSAL_ENABLE_WAM = "0"
Connect-IPPSSession -UserPrincipalName GeptorAdmin@0n4mg.onmicrosoft.com

# --- ÉTAPE 1 : Récupération des GUIDs des labels cibles ---
# On résout par nom -> GUID au runtime : le GUID est stable tant qu'on ne recrée pas
# le label de zéro, donc plus fiable qu'un GUID fixé en dur.
Write-Host "1. Récupération des GUIDs des labels NormandySR2..." -ForegroundColor Cyan

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
        Write-Host "   MANQUANT : '$LabelName' introuvable. Vérifier exos 2a/2b/2c." -ForegroundColor Yellow
    }
}

if ($LabelGuids.Count -eq 0) {
    Write-Host "-> Aucun label résolu. Arrêt du script." -ForegroundColor Red
    Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
    Get-PSSession | Remove-PSSession
    return
}

Write-Host "-> $($LabelGuids.Count) label(s) résolu(s).`n" -ForegroundColor Green

# --- ÉTAPE 2 : Recherche d'un nom disponible (auto-incrément) ---
# Thème Mass Effect : on protège la Citadelle contre la fuite de fichiers classifiés Spectre.
Write-Host "2. Recherche d'un nom disponible..." -ForegroundColor Cyan

$BasePolicyName = "DLP-Citadel-LabelBlock"
$PolicyName     = $BasePolicyName
$Counter        = 2
while (Get-DlpCompliancePolicy -Identity $PolicyName -ErrorAction SilentlyContinue) {
    $PolicyName = "$BasePolicyName-v$Counter"
    $Counter++
}

$BaseRuleName = "RULE-Citadel-SpectreClearance"
$RuleName     = $BaseRuleName
$Counter      = 2
while (Get-DlpComplianceRule -Identity $RuleName -ErrorAction SilentlyContinue) {
    $RuleName = "$BaseRuleName-v$Counter"
    $Counter++
}
Write-Host "-> Policy : '$PolicyName' / Règle : '$RuleName'`n" -ForegroundColor Green

# --- ÉTAPE 3 : Création de la DLP policy ---
# TestWithNotifications : prudence sur une policy label-based avant activation réelle.
try {
    $NewPolicy = New-DlpCompliancePolicy `
        -Name               $PolicyName `
        -SharePointLocation "All" `
        -OneDriveLocation   "All" `
        -Mode               "TestWithNotifications" `
        -Comment            "Exo 4c — Bloque partage externe fichiers NormandySR2 - Confidentiel/Interne/Externe." `
        -ErrorAction Stop

    Write-Host "3. Policy créée : $($NewPolicy.Name) [Mode : $($NewPolicy.Mode)]`n" -ForegroundColor Green
}
catch {
    Write-Host "-> Échec création policy : $_" -ForegroundColor Red
    Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
    Get-PSSession | Remove-PSSession
    return
}

# --- ÉTAPE 4 : Construction du JSON -AdvancedRule ---
# Piège corrigé après premier test sur tenant réel : -BlockAccess + un scope externe
# exige que "partagé hors organisation" soit une condition DANS le JSON lui-même
# (ConditionName "AccessScope", en AND avec le bloc labels) — pas passée comme
# paramètre -AccessScope séparé. Le moteur DLP rejette sinon la règle au moment du
# blocage : "you must have 'Content is shared with people outside your organization'
# as the first condition along with operator AND with other conditions".
Write-Host "4. Construction de l'AdvancedRule (labels OR + AccessScope externe)..." -ForegroundColor Cyan

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
Write-Host "-> JSON prêt ($($LabelEntries.Count) labels en OR, AccessScope intégré).`n" -ForegroundColor Gray

# --- ÉTAPE 5 : Création de la règle ---
# BlockAccessScope PerUser : seul l'utilisateur qui tente le partage externe est bloqué,
# les collaborateurs internes gardent leur accès.
try {
    $NewRule = New-DlpComplianceRule `
        -Name                    $RuleName `
        -Policy                  $PolicyName `
        -AdvancedRule            $AdvancedRuleJson `
        -BlockAccess             $true `
        -BlockAccessScope        "PerUser" `
        -NotifyUser              "LastModifier" `
        -GenerateIncidentReport  "SiteAdmin" `
        -IncidentReportContent   @("All") `
        -Comment                 "Exo 4c — Blocage partage externe fichiers labelisés NormandySR2 (Spectre Clearance)." `
        -ErrorAction Stop

    Write-Host "5. Règle créée : $($NewRule.Name)`n" -ForegroundColor Green
}
catch {
    Write-Host "-> Échec création règle : $_" -ForegroundColor Red
    Write-Host "   Policy '$PolicyName' créée mais orpheline. Supprimer :" -ForegroundColor Yellow
    Write-Host "   Remove-DlpCompliancePolicy -Identity '$PolicyName' -Confirm:`$false" -ForegroundColor Yellow
    Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
    Get-PSSession | Remove-PSSession
    return
}

# --- ÉTAPE 6 : Vérification depuis la source de vérité ---
Write-Host "6. Vérification..." -ForegroundColor Cyan
Start-Sleep -Seconds 3

$CheckPolicy = Get-DlpCompliancePolicy -Identity $PolicyName -ErrorAction SilentlyContinue
$CheckRule   = Get-DlpComplianceRule   -Policy   $PolicyName -ErrorAction SilentlyContinue

if ($CheckPolicy) {
    [PSCustomObject]@{
        Nom        = $CheckPolicy.Name
        Mode       = $CheckPolicy.Mode
        SharePoint = if ($CheckPolicy.SharePointLocation) { "All" } else { "Non configuré" }
        OneDrive   = if ($CheckPolicy.OneDriveLocation)   { "All" } else { "Non configuré" }
    } | Format-List
}

if ($CheckRule) {
    [PSCustomObject]@{
        Nom           = $CheckRule.Name
        Désactivée    = $CheckRule.Disabled
        BlocageActif  = $CheckRule.BlockAccess
        PortéeBlocage = $CheckRule.BlockAccessScope
        NotifUser     = ($CheckRule.NotifyUser -join ", ")
    } | Format-List
}

# --- RÉSUMÉ ---
Write-Host "=== RÉSUMÉ ===" -ForegroundColor Magenta
[PSCustomObject]@{
    PolicyCréée    = $PolicyName
    RègleCréée     = $RuleName
    Mode           = "TestWithNotifications"
    LabelsCouverts = ($LabelNames -join " | ")
    Workloads      = "SharePoint, OneDrive"
} | Format-List

Write-Host "Info : en mode TestWithNotifications, le blocage est simulé." -ForegroundColor Yellow
Write-Host "Passer en Enable via Set-DlpCompliancePolicy (cf. exo 4d).`n" -ForegroundColor Yellow

# --- NETTOYAGE ---
Remove-Variable LabelNames, LabelGuids, LabelName, Label,
                BasePolicyName, PolicyName, BaseRuleName, RuleName, Counter,
                LabelEntries, AdvancedRuleObject, AdvancedRuleJson,
                NewPolicy, NewRule, CheckPolicy, CheckRule `
                -ErrorAction SilentlyContinue

# --- FERMETURE ---
Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
Get-PSSession | Remove-PSSession
Write-Host "Sessions fermées proprement." -ForegroundColor Magenta
