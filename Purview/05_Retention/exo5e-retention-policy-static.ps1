# ========================================================================================
# Exercice 5e : Retention Policy statique — 1 an sur Exchange + Teams
# ========================================================================================
# Concept : contrairement à 5a-5c (un Retention Label que l'utilisateur applique ou qui
# s'applique via auto-labeling), une Retention Policy "de fond" s'applique directement
# au périmètre sans passer par un label sélectionnable — invisible, rétention uniforme.
#
# Scope STATIQUE : "All" fige le périmètre à la création. Contrairement à un Adaptive
# Scope (5d), ce périmètre ne se recalcule jamais — toute modification requiert une
# intervention manuelle sur la policy.
#
# Delta pédagogique vs 5d/5f :
#   5d → Adaptive Scope : requête dynamique, membres recalculés en continu
#   5e → Retention Policy statique : périmètre figé "All", trois policies distinctes
#   5f → Retention Policy avec Adaptive Scope : même logique que 5e mais scope dynamique
#        (compare 5e et 5f pour comprendre la différence statique vs adaptatif en prod)
#
# Pourquoi 3 policies et pas 1 — trois contraintes d'architecture découvertes en test réel :
#
#   Contrainte A — parameter sets mutuellement exclusifs :
#     ExchangeLocation et TeamsChannelLocation/TeamsChatLocation appartiennent à deux
#     parameter sets distincts de New-RetentionCompliancePolicy ("Default" vs "TeamLocation").
#     Impossible de les combiner dans un même appel — la cmdlet rejette la combinaison
#     à la résolution du parameter set, avant même de regarder les valeurs.
#
#   Contrainte B — Teams migré vers une nouvelle famille de cmdlets :
#     Teams n'est plus géré par New-RetentionCompliancePolicy du tout.
#     Microsoft l'a migré vers New-AppRetentionCompliancePolicy /
#     New-AppRetentionComplianceRule. Le ciblage se fait via -Applications,
#     syntaxe "LocationType:NomApp" (ex. "User:MicrosoftTeamsChannelMessages").
#     Tenter New-RetentionCompliancePolicy avec Teams provoque :
#     "Teams Chat and Channel policies are not supported using this cmdlet,
#      Use NewAppRetention cmdlet" (testé et confirmé sur ce tenant).
#
#   Contrainte C — scenario groups distincts dans la nouvelle famille :
#     Au sein de New-AppRetentionCompliancePolicy, canaux (MicrosoftTeamsChannelMessages)
#     et chats (TeamsChatUserInteractions) appartiennent à deux "scenario groups" distincts
#     côté backend. Une policy ne peut couvrir qu'un seul scenario group à la fois.
#     Combiner les deux dans un même -Applications déclenche : "Applications must belong
#     to a single known scenario group" (testé et confirmé sur ce tenant).
#     Bonus pédagogique : cette séparation a aussi du sens métier — retenir les canaux
#     Teams 1 an mais purger les chats plus vite (confidentialité des échanges privés)
#     est un cas d'usage réel en production.
#
#   Cas particulier -ExchangeLocation "All" sur les policies Teams :
#     Contre-intuitif : le contenu retenu est dans Teams, pas Exchange — pourtant ce
#     paramètre est OBLIGATOIRE sur les policies AppRetentionCompliance.
#     Il identifie le SCOPE UTILISATEUR (qui est concerné), indépendamment d'où vit
#     le contenu. Sans lui : "user applications are present, but ExchangeLocations is
#     missing" (testé et confirmé sur ce tenant).
#
# Thème Mass Effect : rétention 1 an sur les communications de la Citadelle (mail,
# canaux Teams, chats Teams) — trois flux, trois politiques de fond.
#
# Ce que fait ce script :
#   1. Reset total de session
#   2. Recherche des noms disponibles (3 policies + 3 règles, auto-incrément)
#   3. Crée la policy + règle Exchange (ancienne cmdlet, parameter set "Default")
#   4. Crée la policy + règle Teams canaux (nouvelle cmdlet AppRetention)
#   5. Crée la policy + règle Teams chats (nouvelle cmdlet AppRetention, scenario distinct)
#   6. Vérifie les trois créations depuis la source de vérité
#   7. Affiche un résumé
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
# ÉTAPE 1 : Recherche des noms disponibles (3 policies + 3 règles)
# ========================================================================================
Write-Host "1. Recherche des noms disponibles..." -ForegroundColor Cyan
Start-Sleep -Seconds 30

# Chaque famille utilise sa propre cmdlet de vérification :
#   Get-RetentionCompliancePolicy    → ancienne famille (Exchange)
#   Get-AppRetentionCompliancePolicy → nouvelle famille (Teams canaux + Teams chats)
#   Get-RetentionComplianceRule      → règles ancienne famille
#   Get-AppRetentionComplianceRule   → règles nouvelle famille

$ExchangePolicyName = "RET-POL-Citadel-Static-Exchange"
$Counter = 2
while (Get-RetentionCompliancePolicy -Identity $ExchangePolicyName -ErrorAction SilentlyContinue) {
    Write-Host "   '$ExchangePolicyName' déjà pris — test avec suffixe -v$Counter..." -ForegroundColor Yellow
    $ExchangePolicyName = "RET-POL-Citadel-Static-Exchange-v$Counter"
    $Counter++
}

$ExchangeRuleName = "RULE-Citadel-Static-Exchange-1an"
$Counter = 2
while (Get-RetentionComplianceRule -Identity $ExchangeRuleName -ErrorAction SilentlyContinue) {
    Write-Host "   '$ExchangeRuleName' déjà pris — test avec suffixe -v$Counter..." -ForegroundColor Yellow
    $ExchangeRuleName = "RULE-Citadel-Static-Exchange-1an-v$Counter"
    $Counter++
}

$TeamsChannelPolicyName = "RET-POL-Citadel-Static-TeamsCanaux"
$Counter = 2
while (Get-AppRetentionCompliancePolicy -Identity $TeamsChannelPolicyName -ErrorAction SilentlyContinue) {
    Write-Host "   '$TeamsChannelPolicyName' déjà pris — test avec suffixe -v$Counter..." -ForegroundColor Yellow
    $TeamsChannelPolicyName = "RET-POL-Citadel-Static-TeamsCanaux-v$Counter"
    $Counter++
}

$TeamsChannelRuleName = "RULE-Citadel-Static-TeamsCanaux-1an"
$Counter = 2
while (Get-AppRetentionComplianceRule -Identity $TeamsChannelRuleName -ErrorAction SilentlyContinue) {
    Write-Host "   '$TeamsChannelRuleName' déjà pris — test avec suffixe -v$Counter..." -ForegroundColor Yellow
    $TeamsChannelRuleName = "RULE-Citadel-Static-TeamsCanaux-1an-v$Counter"
    $Counter++
}

$TeamsChatPolicyName = "RET-POL-Citadel-Static-TeamsChats"
$Counter = 2
while (Get-AppRetentionCompliancePolicy -Identity $TeamsChatPolicyName -ErrorAction SilentlyContinue) {
    Write-Host "   '$TeamsChatPolicyName' déjà pris — test avec suffixe -v$Counter..." -ForegroundColor Yellow
    $TeamsChatPolicyName = "RET-POL-Citadel-Static-TeamsChats-v$Counter"
    $Counter++
}

$TeamsChatRuleName = "RULE-Citadel-Static-TeamsChats-1an"
$Counter = 2
while (Get-AppRetentionComplianceRule -Identity $TeamsChatRuleName -ErrorAction SilentlyContinue) {
    Write-Host "   '$TeamsChatRuleName' déjà pris — test avec suffixe -v$Counter..." -ForegroundColor Yellow
    $TeamsChatRuleName = "RULE-Citadel-Static-TeamsChats-1an-v$Counter"
    $Counter++
}

Write-Host "-> Exchange      : '$ExchangePolicyName' / '$ExchangeRuleName'" -ForegroundColor Green
Write-Host "-> Teams canaux  : '$TeamsChannelPolicyName' / '$TeamsChannelRuleName'" -ForegroundColor Green
Write-Host "-> Teams chats   : '$TeamsChatPolicyName' / '$TeamsChatRuleName'`n" -ForegroundColor Green

# ========================================================================================
# ÉTAPE 2 : Policy + règle Exchange (ancienne cmdlet, parameter set "Default")
# ========================================================================================
Write-Host "2. Création policy + règle Exchange..." -ForegroundColor Cyan

# New-RetentionCompliancePolicy parameter set "Default" — couvre Exchange, SharePoint,
# OneDrive, mais PAS Teams (cf. contrainte B en en-tête).
#
# -RetentionComplianceAction "KeepAndDelete" :
#   Conserve le contenu pendant la durée définie, puis le supprime automatiquement.
#   Pas de reviewer (suppression silencieuse) — contrairement aux labels de 5b.
#
# -ExpirationDateOption "CreationAgeInDays" :
#   Le compteur de 365 jours démarre à la création de l'item.
#   Pour Exchange, "création" = date de réception/envoi du mail.
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

    Write-Host "-> Policy + règle Exchange créées.`n" -ForegroundColor Green
}
catch {
    Write-Host "-> Échec création Exchange : $_" -ForegroundColor Red
    Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
    Get-PSSession | Remove-PSSession
    return
}

# ========================================================================================
# ÉTAPE 3 : Policy + règle Teams CANAUX (nouvelle cmdlet AppRetention)
# ========================================================================================
Write-Host "3. Création policy + règle Teams canaux..." -ForegroundColor Cyan

# New-AppRetentionCompliancePolicy remplace New-RetentionCompliancePolicy pour Teams.
# -Applications "User:MicrosoftTeamsChannelMessages" : cible les messages des canaux Teams.
#   Syntaxe : "LocationType:NomApp"
#   LocationType "User" = les comptes utilisateurs sont le scope d'identité.
#
# -ExchangeLocation "All" obligatoire même ici : identité de scope utilisateur —
# voir explication détaillée contrainte C en en-tête.
#
# New-AppRetentionComplianceRule : pas de -ExpirationDateOption sur cette cmdlet —
# la durée s'applique depuis la création de l'item Teams (comportement natif).
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

    Write-Host "-> Policy + règle Teams canaux créées.`n" -ForegroundColor Green
}
catch {
    Write-Host "-> Échec création Teams canaux : $_" -ForegroundColor Red
    Write-Host "   La policy Exchange reste valide malgré cet échec." -ForegroundColor Yellow
    Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
    Get-PSSession | Remove-PSSession
    return
}

# ========================================================================================
# ÉTAPE 4 : Policy + règle Teams CHATS (nouvelle cmdlet, scenario group distinct)
# ========================================================================================
Write-Host "4. Création policy + règle Teams chats..." -ForegroundColor Cyan

# -Applications "User:TeamsChatUserInteractions" : cible les chats Teams (1:1 et groupes).
# Scenario group distinct de MicrosoftTeamsChannelMessages — voir contrainte C en en-tête.
#
# Séparation métier justifiée indépendamment de la contrainte technique :
#   Canaux Teams = espaces d'équipe partagés, contenu professionnel collaboratif
#   → durée de rétention longue souvent justifiée (conformité, traçabilité projet)
#   Chats Teams  = conversations privées ou de petit groupe, nature plus personnelle
#   → durée de rétention plus courte parfois préférable (confidentialité, RGPD)
# Ici les deux sont à 365 jours pour simplifier l'exercice, mais la séparation en deux
# policies permet de les gérer indépendamment en production si besoin.
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

    Write-Host "-> Policy + règle Teams chats créées.`n" -ForegroundColor Green
}
catch {
    Write-Host "-> Échec création Teams chats : $_" -ForegroundColor Red
    Write-Host "   Les policies Exchange et Teams canaux restent valides malgré cet échec." -ForegroundColor Yellow
    Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
    Get-PSSession | Remove-PSSession
    return
}

# ========================================================================================
# ÉTAPE 5 : Vérification depuis la source de vérité
# ========================================================================================
Write-Host "5. Vérification depuis le backend Purview..." -ForegroundColor Cyan
Start-Sleep -Seconds 30

$CheckExchangePolicy     = Get-RetentionCompliancePolicy    -Identity $ExchangePolicyName     -ErrorAction SilentlyContinue
$CheckTeamsChannelPolicy = Get-AppRetentionCompliancePolicy -Identity $TeamsChannelPolicyName -ErrorAction SilentlyContinue
$CheckTeamsChatPolicy    = Get-AppRetentionCompliancePolicy -Identity $TeamsChatPolicyName    -ErrorAction SilentlyContinue

if ($CheckExchangePolicy) {
    Write-Host "-> Policy Exchange confirmée :" -ForegroundColor Green
    [PSCustomObject]@{
        Nom           = $CheckExchangePolicy.Name
        Exchange      = if ($CheckExchangePolicy.ExchangeLocation) { "Oui" } else { "Non" }
        DistribStatus = $CheckExchangePolicy.DistributionStatus
    } | Format-List
} else {
    Write-Host "-> ATTENTION : policy Exchange non trouvée lors de la vérification." -ForegroundColor Red
}

if ($CheckTeamsChannelPolicy) {
    Write-Host "-> Policy Teams canaux confirmée :" -ForegroundColor Green
    [PSCustomObject]@{
        Nom          = $CheckTeamsChannelPolicy.Name
        Applications = ($CheckTeamsChannelPolicy.Applications -join ", ")
        DistribStatus = $CheckTeamsChannelPolicy.DistributionStatus
    } | Format-List
} else {
    Write-Host "-> ATTENTION : policy Teams canaux non trouvée lors de la vérification." -ForegroundColor Red
}

if ($CheckTeamsChatPolicy) {
    Write-Host "-> Policy Teams chats confirmée :" -ForegroundColor Green
    [PSCustomObject]@{
        Nom          = $CheckTeamsChatPolicy.Name
        Applications = ($CheckTeamsChatPolicy.Applications -join ", ")
        DistribStatus = $CheckTeamsChatPolicy.DistributionStatus
    } | Format-List
} else {
    Write-Host "-> ATTENTION : policy Teams chats non trouvée lors de la vérification." -ForegroundColor Red
}

# ========================================================================================
# RÉSUMÉ
# ========================================================================================
Write-Host "=== RÉSUMÉ ===" -ForegroundColor Magenta
[PSCustomObject]@{
    PolicyExchange     = "$ExchangePolicyName (New-RetentionCompliancePolicy)"
    PolicyTeamsCanaux  = "$TeamsChannelPolicyName (New-AppRetentionCompliancePolicy)"
    PolicyTeamsChats   = "$TeamsChatPolicyName (New-AppRetentionCompliancePolicy)"
    Durée              = "365 jours (1 an), depuis création"
    Action             = "KeepAndDelete (suppression automatique, sans reviewer)"
    Raison3Policies    = "Parameter sets mutuellement exclusifs + Teams migré AppRetention + scenario groups distincts canaux vs chats"
    ÉtapeSuivante      = "Comparer avec 5f : même logique avec Adaptive Scope au lieu de scope statique"
} | Format-List

# ========================================================================================
# NETTOYAGE MÉMOIRE
# ========================================================================================
Remove-Variable ExchangePolicyName, ExchangeRuleName,
                TeamsChannelPolicyName, TeamsChannelRuleName,
                TeamsChatPolicyName, TeamsChatRuleName, Counter,
                ExchangePolicy, TeamsChannelPolicy, TeamsChatPolicy,
                CheckExchangePolicy, CheckTeamsChannelPolicy, CheckTeamsChatPolicy `
                -ErrorAction SilentlyContinue

# ========================================================================================
# FERMETURE — RESET DE SESSION TOTAL
# ========================================================================================
Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
Get-PSSession | Remove-PSSession
Write-Host "Sessions fermées proprement." -ForegroundColor Magenta
