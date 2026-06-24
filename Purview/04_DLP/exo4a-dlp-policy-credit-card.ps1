# ========================================================================================
# Exercice 4a : Purview — DLP — Création d'une policy simple de protection des numéros de CB
# ========================================================================================
# Concept : Une DLP policy (Data Loss Prevention) est un objet conteneur qui définit :
#   - les WORKLOADS surveillés (Exchange, SharePoint, OneDrive, Teams, Devices...)
#   - les RÈGLES de détection et d'action (quoi détecter, que faire quand ça matche)
#   - le MODE global (Test, TestWithNotifications, Enable)
#
# Architecture d'une DLP policy :
#
#   DlpCompliancePolicy  (conteneur — workloads + mode)
#   └── DlpComplianceRule  (règle — conditions + actions)
#       ├── ContentContainsSensitiveInformation  (condition : SIT à détecter)
#       ├── AccessScope                          (condition : interne / externe)
#       ├── GenerateIncidentReport               (action : rapport d'incident)
#       ├── NotifyUser                           (action : notifier l'utilisateur)
#       └── BlockAccess                          (action : blocage — pas ici en 4a)
#
# Ce que fait ce script :
#   1. Reset total de session
#   2. Recherche un nom disponible (auto-incrément)
#   3. Crée la DLP policy sur Exchange + SharePoint + OneDrive
#   4. Crée la règle de détection (SIT : Credit Card Number, Medium, 1+ occurrence)
#   5. Vérifie la création depuis la source de vérité
#   6. Ferme proprement toutes les sessions
#
# Différence entre les modes :
#   TestWithoutNotifications : détection silencieuse, logs uniquement, aucun mail
#   TestWithNotifications    : détection + rapports d'incident envoyés, aucun blocage
#   Enable                   : enforcement réel — les actions (blocage, etc.) s'appliquent
#
# Ce script utilise TestWithNotifications — on voit ce qui se passe sans impact utilisateur.
# L'exo 4d montrera comment basculer en Enable puis revenir en Test.
#
# Prérequis : SIT built-in "Credit Card Number" (natif, aucune création nécessaire)
#
# Module requis : ExchangeOnlineManagement
# Connexion : Connect-IPPSSession (Security & Compliance — pas Connect-ExchangeOnline)
# ========================================================================================

# --- OUVERTURE — RESET DE SESSION TOTAL ---
# REX : des sessions fantômes (Exchange Online ou IPPSSession) restées ouvertes depuis
# un script précédent peuvent provoquer des erreurs silencieuses, des authentifications
# croisées, ou des cmdlets qui tapent sur le mauvais endpoint. On purge TOUT avant de
# commencer, sans exception, même si on pense qu'aucune session n'est ouverte.
#
# Ordre de nettoyage :
#   1. Disconnect-ExchangeOnline : ferme proprement la session Exchange Online si active
#   2. Get-PSSession | Remove-PSSession : purge les sessions PowerShell résiduelles
#      (IPPSSession, sessions RPS legacy, tout ce qui traîne en mémoire)
#   3. $env:MSAL_ENABLE_WAM = "0" : workaround WAM AVANT la nouvelle connexion
#      (WAM = Windows Authentication Manager — broker auth Windows 11 qui peut bloquer
#       Connect-IPPSSession avec une erreur MSAL silencieuse sur certaines configs)
#
# Note : Connect-IPPSSession ne supporte pas -ShowBanner:$false (contrairement à
# Connect-ExchangeOnline). Le bandeau REST s'affiche toujours — comportement normal.
Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
Get-PSSession | Remove-PSSession
$env:MSAL_ENABLE_WAM = "0"
Connect-IPPSSession -UserPrincipalName GeptorAdmin@0n4mg.onmicrosoft.com

# ========================================================================================
# ÉTAPE 1 : Recherche d'un nom disponible (auto-incrément)
# ========================================================================================
Write-Host "1. Recherche d'un nom disponible..." -ForegroundColor Cyan

# Sur un tenant de dev, on reteste souvent le même script sans attendre que la
# suppression précédente se propage (le backend Purview peut mettre plusieurs minutes
# à libérer un nom même après un Remove-DlpCompliancePolicy réussi).
# L'auto-incrément évite le blocage : on cherche le premier nom libre parmi
# "DLP-Citadelle-CreditCard-Protection", "-v2", "-v3", etc.
$BasePolicyName = "DLP-Citadelle-CreditCard-Protection"
$PolicyName     = $BasePolicyName
$Counter        = 2
while (Get-DlpCompliancePolicy -Identity $PolicyName -ErrorAction SilentlyContinue) {
    Write-Host "   '$PolicyName' déjà pris — test avec suffixe -v$Counter..." -ForegroundColor Yellow
    $PolicyName = "$BasePolicyName-v$Counter"
    $Counter++
}
Write-Host "-> Nom retenu pour la policy : '$PolicyName'" -ForegroundColor Green

# Même logique pour la règle — les noms de règles doivent être uniques dans le tenant,
# indépendamment de la policy parente.
$BaseRuleName = "RULE-Citadelle-CreditCard-Detection"
$RuleName     = $BaseRuleName
$Counter      = 2
while (Get-DlpComplianceRule -Identity $RuleName -ErrorAction SilentlyContinue) {
    Write-Host "   '$RuleName' déjà pris — test avec suffixe -v$Counter..." -ForegroundColor Yellow
    $RuleName = "$BaseRuleName-v$Counter"
    $Counter++
}
Write-Host "-> Nom retenu pour la règle : '$RuleName'`n" -ForegroundColor Green

# ========================================================================================
# ÉTAPE 2 : Création de la DLP policy (conteneur)
# ========================================================================================
Write-Host "2. Création de la DLP policy '$PolicyName'..." -ForegroundColor Cyan

# New-DlpCompliancePolicy crée le conteneur. Les paramètres clés :
#
#   -ExchangeLocation "All"    : surveille TOUS les emails Exchange du tenant
#   -SharePointLocation "All"  : surveille TOUS les sites SharePoint
#   -OneDriveLocation "All"    : surveille TOUS les OneDrive For Business
#
# Ces trois workloads couvrent l'essentiel des scénarios de fuite documentaire et email.
# On exclut Teams, Devices et autres workloads avancés pour rester cohérent avec le
# niveau d'un tenant de dev.
#
#   -Mode "TestWithNotifications" : démarre en mode test avec rapports d'incident.
#   Le mode peut être changé après création via Set-DlpCompliancePolicy (cf. exo 4d).
#
#   -Comment : champ de documentation interne visible dans le portail Purview.
#   Bonne pratique : toujours renseigner pour l'audit et les équipes Sec/Comp.
try {
    $NewPolicy = New-DlpCompliancePolicy `
        -Name               $PolicyName `
        -ExchangeLocation   "All" `
        -SharePointLocation "All" `
        -OneDriveLocation   "All" `
        -Mode               "TestWithNotifications" `
        -Comment            "Exo 4a — DLP protection CB sur Exchange + SPO + ODfB. Mode test, aucun blocage." `
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
# ÉTAPE 3 : Création de la règle DLP (conditions + actions)
# ========================================================================================
Write-Host "3. Création de la règle '$RuleName'..." -ForegroundColor Cyan

# New-DlpComplianceRule crée la règle à l'intérieur de la policy.
# Une policy sans règle ne fait rien — c'est la règle qui porte la logique de détection.
#
# --- CONDITION ---
# -ContentContainsSensitiveInformation : condition de détection SIT.
# On lui passe un TABLEAU de hashtables (même pour un seul SIT — le tableau est obligatoire).
#
# PIÈGE 1 — clés en minuscules strictes :
# L'API REST Purview v3 (module ExchangeOnlineManagement >= 3.x) exige des clés
# en minuscules. Les clés PascalCase (Name, MinCount) documentées sur Microsoft Learn
# sont rejetées avec "InvalidContentContainsSensitiveInformationException".
# Clés valides : "name", "mincount", "maxcount", "confidencelevel"
# Les valeurs numériques de count doivent être passées comme strings ("1").
#
# PIÈGE 2 — confidencelevel remplace minconfidence :
# Les clés "minconfidence" et "maxconfidence" sont dépréciées depuis le module v3.
# La clé attendue est "confidencelevel" avec les valeurs textuelles "High", "Medium", "Low".
#
# Pour "Credit Card Number", les niveaux correspondent à :
#   Low    : pattern regex seul — plus de faux positifs
#   Medium : regex + checksum Luhn valide
#   High   : regex + Luhn + mot-clé proche (Visa, MasterCard, etc.)
# On utilise "Medium" — bon équilibre détection / faux positifs sur tenant dev.
#
# -AccessScope "NotInOrganization" : la règle se déclenche uniquement quand le contenu
# est partagé vers l'EXTÉRIEUR du tenant.
# Valeurs possibles :
#   NotInOrganization : partage externe (email sortant, lien SPO public, etc.)
#   InOrganization    : trafic interne uniquement
#   All               : interne + externe
#
# --- ACTIONS ---
# -GenerateIncidentReport "SiteAdmin" : rapport d'incident envoyé à l'admin du site
# (SPO/ODfB) ou à l'admin Exchange.
# -IncidentReportContent @("All") : inclut tout dans le rapport.
#
# PIÈGE 3 — NotifyUser "LastModifier", pas "LastModifiedBy" :
# La doc Microsoft Learn indique "LastModifiedBy" — la valeur réellement acceptée
# par l'API REST v3 est "LastModifier" (sans "By").
# Valeurs valides : "LastModifier", "Owner", "SiteAdmin", adresse SMTP explicite.
#
# Note : -BlockAccess n'est PAS défini ici — volontaire.
# En mode TestWithNotifications, même avec BlockAccess=$true, rien n'est bloqué.
# On l'ajoute explicitement en 4b pour la démonstration du blocage actif.
$SITCondition = @(
    @{
        name            = "Credit Card Number"
        mincount        = "1"
        confidencelevel = "Medium"
    }
)

try {
    $NewRule = New-DlpComplianceRule `
        -Name                                $RuleName `
        -Policy                              $PolicyName `
        -ContentContainsSensitiveInformation $SITCondition `
        -AccessScope                         "NotInOrganization" `
        -GenerateIncidentReport              "SiteAdmin" `
        -IncidentReportContent               @("All") `
        -NotifyUser                          "LastModifier" `
        -Comment                             "Exo 4a — Détection CB (Medium, 1+), rapport + notification, aucun blocage." `
        -ErrorAction Stop

    Write-Host "-> Règle créée : $($NewRule.Name)" -ForegroundColor Green
    Write-Host "   Policy parente : $($NewRule.ParentPolicyName)`n" -ForegroundColor Gray
}
catch {
    Write-Host "-> Échec de la création de la règle : $_" -ForegroundColor Red
    Write-Host "   La policy '$PolicyName' a été créée mais reste sans règle." -ForegroundColor Yellow
    Write-Host "   Supprimer via : Remove-DlpCompliancePolicy -Identity '$PolicyName' -Confirm:`$false" -ForegroundColor Yellow
    Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
    Get-PSSession | Remove-PSSession
    return
}

# ========================================================================================
# ÉTAPE 4 : Vérification depuis la source de vérité
# ========================================================================================
Write-Host "4. Vérification depuis le backend Purview..." -ForegroundColor Cyan

# REX : on relit depuis l'API plutôt que de faire confiance à l'objet local retourné
# par New-DlpCompliancePolicy — le backend peut avoir normalisé certaines valeurs.
# 30 secondes couvrent la latence de propagation du backend Purview.
Start-Sleep -Seconds 30

$CheckPolicy = Get-DlpCompliancePolicy -Identity $PolicyName -ErrorAction SilentlyContinue
$CheckRule   = Get-DlpComplianceRule   -Policy   $PolicyName -ErrorAction SilentlyContinue

if ($CheckPolicy) {
    Write-Host "-> Policy confirmée :" -ForegroundColor Green
    [PSCustomObject]@{
        Nom           = $CheckPolicy.Name
        Mode          = $CheckPolicy.Mode
        Exchange      = if ($CheckPolicy.ExchangeLocation)   { "All" } else { "Non configuré" }
        SharePoint    = if ($CheckPolicy.SharePointLocation) { "All" } else { "Non configuré" }
        OneDrive      = if ($CheckPolicy.OneDriveLocation)   { "All" } else { "Non configuré" }
        DistribStatus = $CheckPolicy.DistributionStatus
    } | Format-List
} else {
    Write-Host "-> ATTENTION : policy non trouvée lors de la vérification." -ForegroundColor Red
}

if ($CheckRule) {
    Write-Host "-> Règle confirmée :" -ForegroundColor Green
    [PSCustomObject]@{
        Nom             = $CheckRule.Name
        PolicyParente   = $CheckRule.ParentPolicyName
        Désactivée      = $CheckRule.Disabled
        AccessScope     = $CheckRule.AccessScope
        RapportIncident = "SiteAdmin"
        NotifUser       = ($CheckRule.NotifyUser -join ", ")
    } | Format-List
} else {
    Write-Host "-> ATTENTION : règle non trouvée lors de la vérification." -ForegroundColor Red
}

# ========================================================================================
# ÉTAPE 5 : Résumé
# ========================================================================================
Write-Host "=== RÉSUMÉ ===" -ForegroundColor Magenta

# Note sur DistributionStatus :
# Après création, la policy affiche "Pending" — c'est normal.
# Le backend Purview distribue la policy vers les workloads (Exchange, SPO, ODfB)
# en arrière-plan. Ce processus prend quelques minutes à quelques heures.
# "Success" confirme que la distribution est terminée.
# "Pending" au moment de l'exo est attendu — pas un problème.
[PSCustomObject]@{
    PolicyCréée      = $PolicyName
    RègleCréée       = $RuleName
    Mode             = "TestWithNotifications"
    SITSurveillé     = "Credit Card Number (Medium, 1+ occurrence)"
    Workloads        = "Exchange, SharePoint, OneDrive"
    ActionBlocage    = "Aucune (mode test)"
    RapportIncident  = "Oui (SiteAdmin)"
    NotifUtilisateur = "Oui (LastModifier)"
    DistribStatus    = if ($CheckPolicy) { $CheckPolicy.DistributionStatus } else { "Non vérifié" }
} | Format-List

Write-Host "Info : DistributionStatus 'Pending' est normal à la création." -ForegroundColor Yellow
Write-Host "La propagation vers Exchange/SPO/ODfB prend quelques minutes.`n" -ForegroundColor Yellow

# ========================================================================================
# NETTOYAGE MÉMOIRE
# ========================================================================================
Remove-Variable BasePolicyName, PolicyName, BaseRuleName, RuleName, Counter,
                NewPolicy, NewRule, SITCondition, CheckPolicy, CheckRule `
                -ErrorAction SilentlyContinue

# ========================================================================================
# FERMETURE — RESET DE SESSION TOTAL
# ========================================================================================
# Même logique qu'à l'ouverture : on purge tout, sans exception.
# Disconnect-ExchangeOnline d'abord (fermeture propre côté service),
# puis Remove-PSSession pour les sessions résiduelles en mémoire locale.
Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
Get-PSSession | Remove-PSSession
Write-Host "Sessions fermées proprement." -ForegroundColor Magenta
