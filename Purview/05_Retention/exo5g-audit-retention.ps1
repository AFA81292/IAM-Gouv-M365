# ========================================================================================
# Exercice 5g : Audit des labels et policies de rétention — vue d'ensemble du tenant
# ========================================================================================
# Concept : exo de lecture pure, miroir de 4e. Couvre TROIS familles d'objets distinctes,
# pas une seule — leçon directe de 5e/5f : Exchange/SharePoint restent sur les cmdlets
# *-RetentionCompliance* classiques, mais Teams (canaux et chats, scenario groups
# séparés) vit exclusivement dans *-AppRetentionCompliance*. Un audit qui n'interroge que
# Get-RetentionCompliancePolicy manquerait silencieusement toutes les policies Teams.
#
# Module requis : ExchangeOnlineManagement
# Connexion : Connect-IPPSSession
# ========================================================================================

# --- OUVERTURE ---
Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
Get-PSSession | Remove-PSSession
$env:MSAL_ENABLE_WAM = "0"
Connect-IPPSSession -UserPrincipalName GeptorAdmin@0n4mg.onmicrosoft.com

# --- ÉTAPE 1 : Retention Labels (l'étiquette elle-même, cf. 5a/5b) ---
Write-Host "1. Retention Labels du tenant..." -ForegroundColor Cyan

$AllLabels = Get-ComplianceTag

if ($AllLabels) {
    $AllLabels | Select-Object Name, RetentionAction, RetentionDuration, RetentionType,
        @{N = "Review"; E = { if ($_.ReviewerEmail) { "Oui" } else { "Non" } }} |
        Format-Table -AutoSize
    Write-Host "-> $($AllLabels.Count) label(s) trouvé(s).`n" -ForegroundColor Green
} else {
    Write-Host "-> Aucun Retention Label trouvé.`n" -ForegroundColor Yellow
}

# --- ÉTAPE 2 : Retention Policies classiques (Exchange/SharePoint — 5e Exchange, 5f) ---
# Distinction Label Policy (publie un label, cf. 5c) vs Retention Policy de fond (5e/5f) :
# RetentionRuleTypes contient "ComplianceTagRetention" pour une Label Policy.
Write-Host "2. Retention Policies classiques (*-RetentionCompliance*)..." -ForegroundColor Cyan

$ClassicPolicies = Get-RetentionCompliancePolicy -RetentionRuleTypes

if ($ClassicPolicies) {
    $ClassicPolicies | Select-Object Name,
        @{N = "Type"; E = { if ($_.RetentionRuleTypes -contains "ComplianceTagRetention") { "Label Policy" } else { "Retention Policy (fond)" } }},
        @{N = "ScopeAdaptatif"; E = { if ($_.AdaptiveScopeLocation) { "Oui" } else { "Non (statique)" } }},
        DistributionStatus |
        Format-Table -AutoSize
    Write-Host "-> $($ClassicPolicies.Count) policy(ies) classique(s) trouvée(s).`n" -ForegroundColor Green
} else {
    Write-Host "-> Aucune Retention Policy classique trouvée.`n" -ForegroundColor Yellow
}

# --- ÉTAPE 3 : App Retention Policies (Teams canaux/chats — 5e Teams) ---
Write-Host "3. App Retention Policies (*-AppRetentionCompliance*, Teams/Viva Engage/IA)..." -ForegroundColor Cyan

$AppPolicies = Get-AppRetentionCompliancePolicy

if ($AppPolicies) {
    $AppPolicies | Select-Object Name,
        @{N = "Applications"; E = { $_.Applications -join ", " }} |
        Format-Table -AutoSize
    Write-Host "-> $($AppPolicies.Count) App Retention Policy(ies) trouvée(s).`n" -ForegroundColor Green
} else {
    Write-Host "-> Aucune App Retention Policy trouvée.`n" -ForegroundColor Yellow
}

# --- ÉTAPE 4 : Règles associées à chaque policy classique ---
# Une policy sans règle est un objet "mort" — créé mais inopérant (même piège qu'en 4c/4e).
Write-Host "4. Règles des policies classiques..." -ForegroundColor Cyan

$OrphanClassicCount = 0
foreach ($Policy in $ClassicPolicies) {
    $Rules = Get-RetentionComplianceRule -Policy $Policy.Name -ErrorAction SilentlyContinue
    if (-not $Rules) {
        Write-Host "   ATTENTION : '$($Policy.Name)' — aucune règle associée (orpheline)." -ForegroundColor Red
        $OrphanClassicCount++
    } else {
        Write-Host "   OK : '$($Policy.Name)' — $($Rules.Count) règle(s)." -ForegroundColor Gray
    }
}
Write-Host ""

# --- ÉTAPE 5 : Règles associées à chaque App Retention Policy ---
Write-Host "5. Règles des App Retention Policies..." -ForegroundColor Cyan

$OrphanAppCount = 0
foreach ($Policy in $AppPolicies) {
    $Rules = Get-AppRetentionComplianceRule -Policy $Policy.Name -ErrorAction SilentlyContinue
    if (-not $Rules) {
        Write-Host "   ATTENTION : '$($Policy.Name)' — aucune règle associée (orpheline)." -ForegroundColor Red
        $OrphanAppCount++
    } else {
        Write-Host "   OK : '$($Policy.Name)' — $($Rules.Count) règle(s)." -ForegroundColor Gray
    }
}
Write-Host ""

# --- ÉTAPE 6 : Adaptive Scopes existants ---
Write-Host "6. Adaptive Scopes du tenant..." -ForegroundColor Cyan

$AllScopes = Get-AdaptiveScope

if ($AllScopes) {
    $AllScopes | Select-Object Name, LocationType | Format-Table -AutoSize
    Write-Host "-> $($AllScopes.Count) scope(s) trouvé(s).`n" -ForegroundColor Green
} else {
    Write-Host "-> Aucun Adaptive Scope trouvé.`n" -ForegroundColor Yellow
}

# --- RÉSUMÉ ---
Write-Host "=== RÉSUMÉ ===" -ForegroundColor Magenta
[PSCustomObject]@{
    RetentionLabels        = if ($AllLabels) { $AllLabels.Count } else { 0 }
    PoliciesClassiques     = if ($ClassicPolicies) { $ClassicPolicies.Count } else { 0 }
    AppRetentionPolicies   = if ($AppPolicies) { $AppPolicies.Count } else { 0 }
    AdaptiveScopes         = if ($AllScopes) { $AllScopes.Count } else { 0 }
    PoliciesOrphelines     = $OrphanClassicCount + $OrphanAppCount
} | Format-List

# --- NETTOYAGE MÉMOIRE ---
Remove-Variable AllLabels, ClassicPolicies, AppPolicies, Policy, Rules,
                OrphanClassicCount, OrphanAppCount, AllScopes `
                -ErrorAction SilentlyContinue

# --- FERMETURE ---
Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
Get-PSSession | Remove-PSSession
Write-Host "Sessions fermées proprement." -ForegroundColor Magenta
