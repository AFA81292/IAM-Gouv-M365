# ========================================================================================
# Exercice 5f : Retention Policy avec Adaptive Scope — comparaison avec 5e (statique)
# ========================================================================================
# Concept : 5e utilisait -ExchangeLocation "All" — scope figé, tous les utilisateurs,
# recalculé jamais. Ici, -AdaptiveScopeLocation pointe vers le scope créé en 5d
# (département Legal) — le périmètre se recalcule en continu : un utilisateur qui change
# de département entre ou sort automatiquement de la policy, sans y retoucher.
#
# Pourquoi New-RetentionCompliancePolicy (l'ancienne cmdlet) et pas
# New-AppRetentionCompliancePolicy (utilisée en 5e pour Teams) : -AdaptiveScopeLocation
# existe dans les DEUX familles de cmdlets, dans un parameter set "AdaptiveScopeLocation"
# séparé. Pour cibler Exchange via un scope adaptatif, pas besoin de la nouvelle
# architecture — confirmé par un exemple réel publié (Practical365, scope "Legal Matter")
# utilisant New-RetentionCompliancePolicy -AdaptiveScopeLocation $scopeName telle quelle,
# pas la cmdlet App. La bascule vers AppRetention ne s'imposait en 5e que parce que Teams
# lui-même n'est plus géré par l'ancienne cmdlet — un problème de LOCATION (Teams),
# pas de TYPE de scope (statique vs adaptatif).
#
# -AdaptiveScopeLocation est dans son propre parameter set, incompatible avec
# -ExchangeLocation "All" dans le même appel (logique : soit le scope est figé "All",
# soit il est piloté par la requête de l'Adaptive Scope — les deux ne coexistent pas
# dans une seule policy).
#
# Thème Mass Effect : rétention adaptative sur les mailboxes du département Legal de la
# Citadelle — le périmètre suit les mutations de personnel sans intervention manuelle.
#
# Prérequis : Adaptive Scope créé en 5d (ASCOPE-Citadel-Legal ou variante -vN).
#
# Module requis : ExchangeOnlineManagement
# Connexion : Connect-IPPSSession
# Licence requise : Microsoft Purview Records Management (inclus E5)
# ========================================================================================

# --- OUVERTURE ---
Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
Get-PSSession | Remove-PSSession
$env:MSAL_ENABLE_WAM = "0"
Connect-IPPSSession -UserPrincipalName GeptorAdmin@0n4mg.onmicrosoft.com

# --- ÉTAPE 1 : Résolution du scope créé en 5d ---
# Résolution par préfixe (même logique qu'en 5c pour les labels) : tolère un suffixe
# -v2/-v3 si 5d a été relancé, plutôt qu'un nom fixe qui manquerait silencieusement.
Write-Host "1. Résolution de l'Adaptive Scope créé en 5d..." -ForegroundColor Cyan

$ScopePrefix = "ASCOPE-Citadel-Legal"
$MatchingScopes = Get-AdaptiveScope | Where-Object { $_.Name -like "$ScopePrefix*" }

if (-not $MatchingScopes) {
    Write-Host "-> Aucun scope '$ScopePrefix*' trouvé. Exécuter 5d avant 5f. Arrêt." -ForegroundColor Red
    Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
    Get-PSSession | Remove-PSSession
    return
}

$ScopeName = $MatchingScopes[0].Name
Write-Host "-> Scope résolu : '$ScopeName'`n" -ForegroundColor Green

# --- ÉTAPE 2 : Recherche d'un nom disponible ---
Write-Host "2. Recherche d'un nom disponible..." -ForegroundColor Cyan

$BasePolicyName = "RET-POL-Citadel-Adaptive-Legal"
$PolicyName     = $BasePolicyName
$Counter        = 2
while (Get-RetentionCompliancePolicy -Identity $PolicyName -ErrorAction SilentlyContinue) {
    $PolicyName = "$BasePolicyName-v$Counter"
    $Counter++
}

$BaseRuleName = "RULE-Citadel-Adaptive-Legal-1an"
$RuleName     = $BaseRuleName
$RuleCounter  = 2
while (Get-RetentionComplianceRule -Identity $RuleName -ErrorAction SilentlyContinue) {
    $RuleName = "$BaseRuleName-v$RuleCounter"
    $RuleCounter++
}
Write-Host "-> Policy : '$PolicyName' / Règle : '$RuleName'`n" -ForegroundColor Green

# --- ÉTAPE 3 : Création de la policy (scope adaptatif, pas "All") ---
try {
    $NewPolicy = New-RetentionCompliancePolicy `
        -Name                 $PolicyName `
        -AdaptiveScopeLocation $ScopeName `
        -Applications         "Group:Exchange" `
        -Comment              "Exo 5f — Rétention 1 an, scope adaptatif département Legal." `
        -ErrorAction Stop

    Write-Host "3. Policy créée : $($NewPolicy.Name)`n" -ForegroundColor Green
}
catch {
    Write-Host "-> Échec création policy : $_" -ForegroundColor Red
    Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
    Get-PSSession | Remove-PSSession
    return
}

# --- ÉTAPE 4 : Création de la règle (durée + action, identique à 5e) ---
try {
    $NewRule = New-RetentionComplianceRule `
        -Name                      $RuleName `
        -Policy                    $PolicyName `
        -RetentionDuration         365 `
        -RetentionComplianceAction "KeepAndDelete" `
        -ExpirationDateOption      "CreationAgeInDays" `
        -ErrorAction Stop

    Write-Host "4. Règle créée : $($NewRule.Name)`n" -ForegroundColor Green
}
catch {
    Write-Host "-> Échec création règle : $_" -ForegroundColor Red
    Write-Host "   Policy '$PolicyName' créée mais orpheline. Supprimer :" -ForegroundColor Yellow
    Write-Host "   Remove-RetentionCompliancePolicy -Identity '$PolicyName' -Confirm:`$false" -ForegroundColor Yellow
    Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
    Get-PSSession | Remove-PSSession
    return
}

# --- ÉTAPE 5 : Vérification depuis la source de vérité ---
Write-Host "5. Vérification..." -ForegroundColor Cyan
Start-Sleep -Seconds 30

$CheckPolicy = Get-RetentionCompliancePolicy -Identity $PolicyName -ErrorAction SilentlyContinue
$CheckRule   = Get-RetentionComplianceRule -Policy $PolicyName -ErrorAction SilentlyContinue

if ($CheckPolicy) {
    [PSCustomObject]@{
        Nom            = $CheckPolicy.Name
        ScopeAdaptatif = ($CheckPolicy.AdaptiveScopeLocation -join ", ")
        DistribStatus  = $CheckPolicy.DistributionStatus
    } | Format-List
}

if ($CheckRule) {
    [PSCustomObject]@{
        Nom        = $CheckRule.Name
        Durée      = "$($CheckRule.RetentionDuration) jours (~1 an)"
        Action     = $CheckRule.RetentionComplianceAction
        BaseCalcul = $CheckRule.ExpirationDateOption
    } | Format-List
}

# --- RÉSUMÉ ---
Write-Host "=== RÉSUMÉ ===" -ForegroundColor Magenta
[PSCustomObject]@{
    PolicyCréée    = $PolicyName
    RègleCréée     = $RuleName
    ScopeUtilisé   = $ScopeName
    DifférenceVs5e = "Scope adaptatif (Department=Legal) au lieu de statique (All) — périmètre recalculé en continu"
    Durée          = "365 jours, depuis création"
    Action         = "KeepAndDelete (suppression automatique, pas de review)"
} | Format-List

Write-Host "Rappel : la liste de membres réelle du scope adaptatif peut prendre jusqu'à" -ForegroundColor Yellow
Write-Host "5 jours à se peupler (cf. 5d) — la policy est active dès maintenant, mais" -ForegroundColor Yellow
Write-Host "son périmètre effectif se stabilise progressivement.`n" -ForegroundColor Yellow

# --- NETTOYAGE MÉMOIRE ---
Remove-Variable ScopePrefix, MatchingScopes, ScopeName,
                BasePolicyName, PolicyName, BaseRuleName, RuleName, Counter, RuleCounter,
                NewPolicy, NewRule, CheckPolicy, CheckRule `
                -ErrorAction SilentlyContinue

# --- FERMETURE ---
Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
Get-PSSession | Remove-PSSession
Write-Host "Sessions fermées proprement." -ForegroundColor Magenta
