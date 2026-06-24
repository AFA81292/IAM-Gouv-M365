# ========================================================================================
# Exercice 5f : Retention Policy avec Adaptive Scope — comparaison avec 5e (statique)
# ========================================================================================
# Concept : 5e utilisait -ExchangeLocation "All" — scope figé, tous les utilisateurs,
# recalculé jamais. Ici, -AdaptiveScopeLocation pointe vers le scope créé en 5d
# (département Legal) — le périmètre se recalcule en continu : un utilisateur qui change
# de département entre ou sort automatiquement de la policy, sans y retoucher.
#
# Delta pédagogique vs 5d/5e :
#   5d → crée l'Adaptive Scope (requête Department = Legal)
#   5e → Retention Policy statique : "All", trois policies, périmètre figé
#   5f → Retention Policy adaptative : consomme le scope de 5d, une seule policy,
#        périmètre recalculé en continu — c'est la comparaison directe avec 5e
#
# Pourquoi New-RetentionCompliancePolicy (ancienne cmdlet) et pas
# New-AppRetentionCompliancePolicy (utilisée en 5e pour Teams) :
#   -AdaptiveScopeLocation existe dans les DEUX familles de cmdlets.
#   La bascule vers AppRetention en 5e était imposée par Teams (problème de LOCATION),
#   pas par le type de scope statique vs adaptatif. Pour Exchange via scope adaptatif,
#   l'ancienne cmdlet convient parfaitement.
#
# Deux pièges documentés sur cet exercice :
#
#   Piège n°1 — -Applications obligatoire avec un scope adaptatif :
#     Sans -Applications : "MissingApplicationsLocationTypeForAdaptiveScopeException"
#     Le paramètre est obligatoire dès qu'un -AdaptiveScopeLocation est fourni —
#     même pour Exchange, qui n'en n'a pas besoin en scope statique.
#
#   Piège n°2 — préfixe de -Applications doit correspondre au -LocationType du scope :
#     "User:" si le scope est LocationType "User" (cas de 5d),
#     "Group:" si LocationType "Group" (SharePoint/sites).
#     Ce n'est pas un choix libre : passer "Group:Exchange" sur un scope "User" échoue
#     avec "Policy locations contain adaptive scope of location type 'User', but no
#     applications were specified for the same location type" — le message identifie
#     précisément le mismatch. Le scope 5d étant LocationType "User" → "User:Exchange".
#
#   -AdaptiveScopeLocation est dans son propre parameter set, incompatible avec
#   -ExchangeLocation "All" dans le même appel (logique : soit le périmètre est figé
#   "All", soit il est piloté par la requête du scope — les deux ne coexistent pas).
#
# Prérequis : Adaptive Scope créé en 5d (ASCOPE-Citadel-Legal ou variante -vN).
#
# Ce que fait ce script :
#   1. Reset total de session
#   2. Résout le scope créé en 5d (recherche par préfixe, prend le plus récent)
#   3. Recherche des noms disponibles pour la policy et la règle (auto-incrément)
#   4. Crée la Retention Policy avec scope adaptatif
#   5. Crée la règle de rétention (durée + action)
#   6. Vérifie les deux créations depuis la source de vérité
#   7. Affiche un résumé comparatif avec 5e
#   8. Ferme proprement toutes les sessions
#
# Module requis : ExchangeOnlineManagement
# Connexion     : Connect-IPPSSession
# Licence       : Microsoft Purview Records Management (inclus E5)
# ========================================================================================

# --- OUVERTURE — RESET DE SESSION TOTAL ---
# REX : des sessions fantômes restées ouvertes depuis un script précédent peuvent
# provoquer des erreurs silencieuses ou des authentifications croisées.
# On purge TOUT avant de commencer, sans exception.
#
# Ordre : Disconnect-ExchangeOnline → Remove-PSSession → workaround WAM → reconnexion.
# Note : Connect-IPPSSession ne supporte pas -ShowBanner:$false — bandeau normal.
Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
Get-PSSession | Remove-PSSession
$env:MSAL_ENABLE_WAM = "0"
Connect-IPPSSession -UserPrincipalName GeptorAdmin@0n4mg.onmicrosoft.com

# ========================================================================================
# ÉTAPE 1 : Résolution du scope créé en 5d
# ========================================================================================
Write-Host "1. Résolution de l'Adaptive Scope créé en 5d..." -ForegroundColor Cyan
Start-Sleep -Seconds 30

# Résolution par préfixe — même logique qu'en 5c pour les labels.
# Tolère un suffixe -v2/-v3 si 5d a été relancé, plutôt qu'un nom fixe qui manquerait
# silencieusement la variante incrémentée.
# Sort-Object WhenCreated -Descending : on prend toujours le scope le plus récent
# si plusieurs variantes coexistent sur le tenant.
$ScopePrefix    = "ASCOPE-Citadel-Legal"
$MatchingScopes = Get-AdaptiveScope |
    Where-Object { $_.Name -like "$ScopePrefix*" } |
    Sort-Object WhenCreated -Descending

if (-not $MatchingScopes) {
    Write-Host "-> Aucun scope '$ScopePrefix*' trouvé." -ForegroundColor Red
    Write-Host "   Prérequis : exécuter l'exo 5d avant 5f. Arrêt du script." -ForegroundColor Red
    Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
    Get-PSSession | Remove-PSSession
    return
}

$ScopeName = $MatchingScopes[0].Name
Write-Host "-> Scope résolu : '$ScopeName'" -ForegroundColor Green

if ($MatchingScopes.Count -gt 1) {
    Write-Host "   Info : $($MatchingScopes.Count) variantes trouvées — la plus récente est retenue." -ForegroundColor DarkGray
}
Write-Host ""

# ========================================================================================
# ÉTAPE 2 : Recherche des noms disponibles (policy + règle)
# ========================================================================================
Write-Host "2. Recherche des noms disponibles..." -ForegroundColor Cyan

$BasePolicyName = "RET-POL-Citadel-Adaptive-Legal"
$PolicyName     = $BasePolicyName
$Counter        = 2
while (Get-RetentionCompliancePolicy -Identity $PolicyName -ErrorAction SilentlyContinue) {
    Write-Host "   '$PolicyName' déjà pris — test avec suffixe -v$Counter..." -ForegroundColor Yellow
    $PolicyName = "$BasePolicyName-v$Counter"
    $Counter++
}

$BaseRuleName = "RULE-Citadel-Adaptive-Legal-1an"
$RuleName     = $BaseRuleName
$RuleCounter  = 2
while (Get-RetentionComplianceRule -Identity $RuleName -ErrorAction SilentlyContinue) {
    Write-Host "   '$RuleName' déjà pris — test avec suffixe -v$RuleCounter..." -ForegroundColor Yellow
    $RuleName = "$BaseRuleName-v$RuleCounter"
    $RuleCounter++
}

Write-Host "-> Policy : '$PolicyName'" -ForegroundColor Green
Write-Host "-> Règle  : '$RuleName'`n" -ForegroundColor Green

# ========================================================================================
# ÉTAPE 3 : Création de la Retention Policy avec scope adaptatif
# ========================================================================================
Write-Host "3. Création de la policy '$PolicyName'..." -ForegroundColor Cyan

# -AdaptiveScopeLocation : reçoit le nom du scope créé en 5d.
#   Ce paramètre est dans son propre parameter set — incompatible avec -ExchangeLocation.
#   On ne peut pas combiner les deux dans un même appel.
#
# -Applications "User:Exchange" : obligatoire avec un scope adaptatif (piège n°1).
#   Préfixe "User:" correspond au -LocationType "User" du scope 5d (piège n°2).
#   "Exchange" = workload ciblé sur les boîtes aux lettres utilisateurs.
#
# Différence vs 5e étape 2 :
#   5e → -ExchangeLocation "All" : tous les utilisateurs, figé
#   5f → -AdaptiveScopeLocation + -Applications "User:Exchange" : département Legal,
#         périmètre dynamique
try {
    $NewPolicy = New-RetentionCompliancePolicy `
        -Name                  $PolicyName `
        -AdaptiveScopeLocation $ScopeName `
        -Applications          "User:Exchange" `
        -Comment               "Exo 5f — Rétention 1 an, scope adaptatif département Legal." `
        -ErrorAction Stop

    Write-Host "-> Policy créée : $($NewPolicy.Name)`n" -ForegroundColor Green
}
catch {
    Write-Host "-> Échec création policy : $_" -ForegroundColor Red
    Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
    Get-PSSession | Remove-PSSession
    return
}

# ========================================================================================
# ÉTAPE 4 : Création de la règle de rétention
# ========================================================================================
Write-Host "4. Création de la règle '$RuleName'..." -ForegroundColor Cyan

# La règle est identique à celle de 5e (Exchange) — durée, action, base de calcul.
# La différence entre 5e et 5f est entièrement dans la policy (scope), pas dans la règle.
#
# -RetentionDuration 365         : 1 an en jours (seule unité acceptée)
# -RetentionComplianceAction "KeepAndDelete" : conserve puis supprime, sans reviewer
# -ExpirationDateOption "CreationAgeInDays"  : compteur depuis la création de l'item
try {
    $NewRule = New-RetentionComplianceRule `
        -Name                      $RuleName `
        -Policy                    $PolicyName `
        -RetentionDuration         365 `
        -RetentionComplianceAction "KeepAndDelete" `
        -ExpirationDateOption      "CreationAgeInDays" `
        -ErrorAction Stop

    Write-Host "-> Règle créée : $($NewRule.Name)`n" -ForegroundColor Green
}
catch {
    Write-Host "-> Échec création règle : $_" -ForegroundColor Red
    Write-Host "   Policy '$PolicyName' créée mais orpheline — nettoyage :" -ForegroundColor Yellow
    Write-Host "   Remove-RetentionCompliancePolicy -Identity '$PolicyName' -Confirm:`$false" -ForegroundColor Yellow
    Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
    Get-PSSession | Remove-PSSession
    return
}

# ========================================================================================
# ÉTAPE 5 : Vérification depuis la source de vérité
# ========================================================================================
Write-Host "5. Vérification depuis le backend Purview..." -ForegroundColor Cyan
Start-Sleep -Seconds 30

$CheckPolicy = Get-RetentionCompliancePolicy -Identity $PolicyName -ErrorAction SilentlyContinue
$CheckRule   = Get-RetentionComplianceRule   -Policy   $PolicyName -ErrorAction SilentlyContinue

if ($CheckPolicy) {
    Write-Host "-> Policy confirmée :" -ForegroundColor Green
    [PSCustomObject]@{
        Nom            = $CheckPolicy.Name
        # AdaptiveScopeLocation confirme que le scope dynamique est bien référencé
        ScopeAdaptatif = ($CheckPolicy.AdaptiveScopeLocation -join ", ")
        DistribStatus  = $CheckPolicy.DistributionStatus
    } | Format-List
} else {
    Write-Host "-> ATTENTION : policy non trouvée lors de la vérification." -ForegroundColor Red
    Write-Host "   Réplication peut être encore en cours — vérifier dans Purview Admin Center." -ForegroundColor Yellow
}

if ($CheckRule) {
    Write-Host "-> Règle confirmée :" -ForegroundColor Green
    [PSCustomObject]@{
        Nom        = $CheckRule.Name
        Durée      = "$($CheckRule.RetentionDuration) jours (~1 an)"
        Action     = $CheckRule.RetentionComplianceAction
        BaseCalcul = $CheckRule.ExpirationDateOption
    } | Format-List
} else {
    Write-Host "-> ATTENTION : règle non trouvée lors de la vérification." -ForegroundColor Red
}

# ========================================================================================
# RÉSUMÉ
# ========================================================================================
Write-Host "=== RÉSUMÉ ===" -ForegroundColor Magenta
[PSCustomObject]@{
    PolicyCréée      = $PolicyName
    RègleCréée       = $RuleName
    ScopeUtilisé     = $ScopeName
    Durée            = "365 jours (1 an), depuis création"
    Action           = "KeepAndDelete (suppression automatique, sans reviewer)"
    DifférenceVs5e   = "Scope adaptatif (Department=Legal) au lieu de statique (All) — périmètre recalculé en continu"
    PropagationScope = "Jusqu'à 5 jours pour que le scope reflète la liste réelle (cf. 5d)"
    NoteDistrib      = "DistributionStatus 'Pending' = normal à la création, pas un échec"
} | Format-List

# ========================================================================================
# NETTOYAGE MÉMOIRE
# ========================================================================================
Remove-Variable ScopePrefix, MatchingScopes, ScopeName,
                BasePolicyName, PolicyName, BaseRuleName, RuleName, Counter, RuleCounter,
                NewPolicy, NewRule, CheckPolicy, CheckRule `
                -ErrorAction SilentlyContinue

# ========================================================================================
# FERMETURE — RESET DE SESSION TOTAL
# ========================================================================================
Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
Get-PSSession | Remove-PSSession
Write-Host "Sessions fermées proprement." -ForegroundColor Magenta
