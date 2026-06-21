# ========================================================================================
# Exercice 5e : Retention Policy statique — 1 an sur Exchange + Teams
# ========================================================================================
# Concept : contrairement à 5a-5c (un Retention Label que l'utilisateur applique ou qui
# s'applique via auto-labeling), une Retention Policy "de fond" s'applique directement
# au périmètre sans passer par un label sélectionnable — invisible, rétention uniforme.
#
# Scope STATIQUE : "All" fige le périmètre à la création. Contrairement à un Adaptive
# Scope (5d), ce périmètre ne se recalcule jamais.
#
# CORRECTIF POST-DEBUG : "Exchange + Teams, 1 an" semble être une seule policy multi-
# location (comme 5c l'était pour Exchange + SharePoint). En réalité, trois contraintes
# d'architecture distinctes, toutes découvertes par erreur réelle sur ce tenant, forcent
# à séparer en TROIS policies :
#
# A. ExchangeLocation et TeamsChannelLocation/TeamsChatLocation sont deux parameter sets
#    mutuellement exclusifs de New-RetentionCompliancePolicy ("Default" vs "TeamLocation").
#    Impossible de les combiner dans un même appel, quel que soit l'agencement des
#    paramètres — la cmdlet rejette la combinaison à la résolution du parameter set,
#    avant même de regarder les valeurs.
#
# B. Teams n'est de toute façon plus géré par cette cmdlet du tout : Microsoft l'a migré
#    vers New-AppRetentionCompliancePolicy / New-AppRetentionComplianceRule, une famille
#    séparée sans paramètre de location dédié. Le ciblage se fait via -Applications,
#    syntaxe "LocationType:NomApp" (ex. "User:MicrosoftTeamsChannelMessages").
#
# C. Au sein de cette nouvelle famille, canaux (MicrosoftTeamsChannelMessages) et chats
#    (TeamsChatUserInteractions) appartiennent à deux "scenario groups" distincts côté
#    backend — une policy ne peut couvrir qu'un seul scenario group à la fois. Combiner
#    les deux apps dans un même -Applications déclenche un rejet explicite ("Applications
#    must belong to a single known scenario group").
#
# Conséquence : Exchange reste sur l'ancienne cmdlet (-ExchangeLocation "All"), Teams se
# scinde en deux policies sur la nouvelle cmdlet (une par scenario group). Dans les deux
# cas Teams, -ExchangeLocation "All" doit AUSSI être présent — contre-intuitif, mais ce
# paramètre sert d'identité de scope utilisateur (les comptes concernés), indépendamment
# du fait que le contenu réellement retenu soit dans Teams et non dans Exchange.
#
# Thème Mass Effect : rétention 1 an sur les communications de la Citadelle (mail,
# canaux Teams, chats Teams) — trois flux de communication, trois politiques de fond.
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

# --- ÉTAPE 1 : Recherche de noms disponibles (3 policies + 3 règles) ---
Write-Host "1. Recherche de noms disponibles..." -ForegroundColor Cyan

$ExchangePolicyName = "RET-POL-Citadel-Static-Exchange"
$Counter = 2
while (Get-RetentionCompliancePolicy -Identity $ExchangePolicyName -ErrorAction SilentlyContinue) {
    $ExchangePolicyName = "RET-POL-Citadel-Static-Exchange-v$Counter"
    $Counter++
}

$ExchangeRuleName = "RULE-Citadel-Static-Exchange-1an"
$Counter = 2
while (Get-RetentionComplianceRule -Identity $ExchangeRuleName -ErrorAction SilentlyContinue) {
    $ExchangeRuleName = "RULE-Citadel-Static-Exchange-1an-v$Counter"
    $Counter++
}

$TeamsChannelPolicyName = "RET-POL-Citadel-Static-TeamsCanaux"
$Counter = 2
while (Get-AppRetentionCompliancePolicy -Identity $TeamsChannelPolicyName -ErrorAction SilentlyContinue) {
    $TeamsChannelPolicyName = "RET-POL-Citadel-Static-TeamsCanaux-v$Counter"
    $Counter++
}

$TeamsChannelRuleName = "RULE-Citadel-Static-TeamsCanaux-1an"
$Counter = 2
while (Get-AppRetentionComplianceRule -Identity $TeamsChannelRuleName -ErrorAction SilentlyContinue) {
    $TeamsChannelRuleName = "RULE-Citadel-Static-TeamsCanaux-1an-v$Counter"
    $Counter++
}

$TeamsChatPolicyName = "RET-POL-Citadel-Static-TeamsChats"
$Counter = 2
while (Get-AppRetentionCompliancePolicy -Identity $TeamsChatPolicyName -ErrorAction SilentlyContinue) {
    $TeamsChatPolicyName = "RET-POL-Citadel-Static-TeamsChats-v$Counter"
    $Counter++
}

$TeamsChatRuleName = "RULE-Citadel-Static-TeamsChats-1an"
$Counter = 2
while (Get-AppRetentionComplianceRule -Identity $TeamsChatRuleName -ErrorAction SilentlyContinue) {
    $TeamsChatRuleName = "RULE-Citadel-Static-TeamsChats-1an-v$Counter"
    $Counter++
}

Write-Host "-> Exchange      : '$ExchangePolicyName' / '$ExchangeRuleName'" -ForegroundColor Green
Write-Host "-> Teams canaux  : '$TeamsChannelPolicyName' / '$TeamsChannelRuleName'" -ForegroundColor Green
Write-Host "-> Teams chats   : '$TeamsChatPolicyName' / '$TeamsChatRuleName'`n" -ForegroundColor Green

# --- ÉTAPE 2 : Policy + règle Exchange (ancienne cmdlet, parameter set "Default") ---
try {
    $ExchangePolicy = New-RetentionCompliancePolicy `
        -Name             $ExchangePolicyName `
        -ExchangeLocation "All" `
        -Comment          "Exo 5e — Rétention statique 1 an, Exchange." `
        -ErrorAction Stop

    New-RetentionComplianceRule `
        -Name                      $ExchangeRuleName `
        -Policy                    $ExchangePolicyName `
        -RetentionDuration         365 `
        -RetentionComplianceAction "KeepAndDelete" `
        -ExpirationDateOption      "CreationAgeInDays" `
        -ErrorAction Stop | Out-Null

    Write-Host "2. Policy + règle Exchange créées.`n" -ForegroundColor Green
}
catch {
    Write-Host "-> Échec création Exchange : $_" -ForegroundColor Red
    Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
    Get-PSSession | Remove-PSSession
    return
}

# --- ÉTAPE 3 : Policy + règle Teams CANAUX (nouvelle cmdlet, scenario group "Teams") ---
# Pourquoi New-AppRetentionCompliancePolicy et pas New-RetentionCompliancePolicy : Teams
# n'est plus géré par l'ancienne cmdlet du tout (testé en amont — rejet explicite "Teams
# Chat and Channel policies are not supported using this cmdlet, Use NewAppRetention
# cmdlet"). Pas de paramètre TeamsChannelLocation ici : le ciblage passe par -Applications,
# syntaxe "LocationType:NomApp" où LocationType est "User" ou "Group".
#
# Pourquoi -Applications "User:MicrosoftTeamsChannelMessages" SEUL, pas combiné aux
# chats : canaux et chats appartiennent à deux "scenario groups" distincts côté backend
# (testé en amont — combiner les deux rejette avec "Applications must belong to a single
# known scenario group", catégorie retournée : "Mixed"). Une policy = un scenario group.
#
# Pourquoi -ExchangeLocation "All" est quand même là : contre-intuitif puisque le contenu
# concerné est dans Teams, pas Exchange — mais ce paramètre identifie le SCOPE utilisateur
# (qui est concerné), indépendamment d'OÙ vit le contenu. Sans lui : rejet "user
# applications are present, but ExchangeLocations is missing" (testé en amont).
try {
    $TeamsChannelPolicy = New-AppRetentionCompliancePolicy `
        -Name             $TeamsChannelPolicyName `
        -Applications     "User:MicrosoftTeamsChannelMessages" `
        -ExchangeLocation "All" `
        -Comment          "Exo 5e — Rétention statique 1 an, Teams canaux." `
        -ErrorAction Stop

    New-AppRetentionComplianceRule `
        -Name                      $TeamsChannelRuleName `
        -Policy                    $TeamsChannelPolicyName `
        -RetentionDuration         365 `
        -RetentionComplianceAction "KeepAndDelete" `
        -ErrorAction Stop | Out-Null

    Write-Host "3. Policy + règle Teams canaux créées.`n" -ForegroundColor Green
}
catch {
    Write-Host "-> Échec création Teams canaux : $_" -ForegroundColor Red
    Write-Host "   Exchange reste valide malgré cet échec." -ForegroundColor Yellow
    Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
    Get-PSSession | Remove-PSSession
    return
}

# --- ÉTAPE 4 : Policy + règle Teams CHATS (nouvelle cmdlet, scenario group distinct) ---
# Pourquoi une policy séparée plutôt qu'ajouter cette app à la policy canaux ci-dessus :
# TeamsChatUserInteractions n'appartient pas au même scenario group que
# MicrosoftTeamsChannelMessages (cf. étape 3) — le backend les traite comme deux familles
# fonctionnelles distinctes (canaux = espace d'équipe partagé, chats = conversations
# privées/groupe), chacune avec son propre cycle de vie de rétention possible en
# entreprise (ex. retenir les canaux 1 an mais purger les chats privés plus vite pour
# des raisons de confidentialité — un cas réel où séparer les deux a du sens, pas
# uniquement une contrainte technique à contourner).
#
# -ExchangeLocation "All" obligatoire ici aussi, même cause qu'à l'étape 3 : identité de
# scope utilisateur, indépendante du fait que le contenu réel soit dans Teams.
try {
    $TeamsChatPolicy = New-AppRetentionCompliancePolicy `
        -Name             $TeamsChatPolicyName `
        -Applications     "User:TeamsChatUserInteractions" `
        -ExchangeLocation "All" `
        -Comment          "Exo 5e — Rétention statique 1 an, Teams chats." `
        -ErrorAction Stop

    New-AppRetentionComplianceRule `
        -Name                      $TeamsChatRuleName `
        -Policy                    $TeamsChatPolicyName `
        -RetentionDuration         365 `
        -RetentionComplianceAction "KeepAndDelete" `
        -ErrorAction Stop | Out-Null

    Write-Host "4. Policy + règle Teams chats créées.`n" -ForegroundColor Green
}
catch {
    Write-Host "-> Échec création Teams chats : $_" -ForegroundColor Red
    Write-Host "   Exchange et Teams canaux restent valides malgré cet échec." -ForegroundColor Yellow
    Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
    Get-PSSession | Remove-PSSession
    return
}

# --- ÉTAPE 5 : Vérification depuis la source de vérité ---
Write-Host "5. Vérification..." -ForegroundColor Cyan
Start-Sleep -Seconds 30

$CheckExchangePolicy     = Get-RetentionCompliancePolicy -Identity $ExchangePolicyName -ErrorAction SilentlyContinue
$CheckTeamsChannelPolicy = Get-AppRetentionCompliancePolicy -Identity $TeamsChannelPolicyName -ErrorAction SilentlyContinue
$CheckTeamsChatPolicy    = Get-AppRetentionCompliancePolicy -Identity $TeamsChatPolicyName -ErrorAction SilentlyContinue

if ($CheckExchangePolicy) {
    [PSCustomObject]@{
        Nom           = $CheckExchangePolicy.Name
        Exchange      = if ($CheckExchangePolicy.ExchangeLocation) { "Oui" } else { "Non" }
        DistribStatus = $CheckExchangePolicy.DistributionStatus
    } | Format-List
}

if ($CheckTeamsChannelPolicy) {
    [PSCustomObject]@{
        Nom          = $CheckTeamsChannelPolicy.Name
        Applications = ($CheckTeamsChannelPolicy.Applications -join ", ")
    } | Format-List
}

if ($CheckTeamsChatPolicy) {
    [PSCustomObject]@{
        Nom          = $CheckTeamsChatPolicy.Name
        Applications = ($CheckTeamsChatPolicy.Applications -join ", ")
    } | Format-List
}

# --- RÉSUMÉ ---
Write-Host "=== RÉSUMÉ ===" -ForegroundColor Magenta
[PSCustomObject]@{
    PolicyExchange    = "$ExchangePolicyName (New-RetentionCompliancePolicy)"
    PolicyTeamsCanaux = "$TeamsChannelPolicyName (New-AppRetentionCompliancePolicy)"
    PolicyTeamsChats  = "$TeamsChatPolicyName (New-AppRetentionCompliancePolicy)"
    Durée             = "365 jours, depuis création"
    Action            = "KeepAndDelete (suppression automatique, pas de review)"
    Raison3Policies   = "Exchange (ancienne cmdlet) + 2 scenario groups Teams distincts (canaux vs chats) côté nouvelle architecture AppRetentionCompliance"
} | Format-List

Write-Host "Comparer avec 5f (même logique, mais Adaptive Scope au lieu de scope statique).`n" -ForegroundColor Yellow

# --- NETTOYAGE MÉMOIRE ---
Remove-Variable ExchangePolicyName, ExchangeRuleName,
                TeamsChannelPolicyName, TeamsChannelRuleName,
                TeamsChatPolicyName, TeamsChatRuleName, Counter,
                ExchangePolicy, TeamsChannelPolicy, TeamsChatPolicy,
                CheckExchangePolicy, CheckTeamsChannelPolicy, CheckTeamsChatPolicy `
                -ErrorAction SilentlyContinue

# --- FERMETURE ---
Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
Get-PSSession | Remove-PSSession
Write-Host "Sessions fermées proprement." -ForegroundColor Magenta
