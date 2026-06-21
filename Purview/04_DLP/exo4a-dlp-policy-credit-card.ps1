# ========================================================================================
# Exercice 4a : DLP — Création d'une policy simple de protection des numéros de CB
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
#   1. Recherche un nom disponible (auto-incrément si déjà pris)
#   2. Crée la DLP policy sur Exchange + SharePoint + OneDrive
#   3. Crée la règle de détection (SIT : Credit Card Number, 1+ occurrence)
#   4. Mode TestWithNotifications : aucun blocage, rapports d'incident générés
#   5. Vérifie la création depuis la source de vérité
#
# Différence entre les modes :
#   TestWithoutNotifications : détection silencieuse, logs uniquement, aucun mail
#   TestWithNotifications    : détection + rapports d'incident envoyés, aucun blocage
#   Enable                   : enforcement réel — les actions (blocage, etc.) s'appliquent
#
# Ce script utilise TestWithNotifications — on voit ce qui se passe sans impact utilisateur.
# L'exo 4d montrera comment passer en Enable, puis revenir en Test.
#
# Prérequis : SIT built-in "Credit Card Number" (natif, aucune création nécessaire)
#
# Module requis : ExchangeOnlineManagement (contient les cmdlets Security & Compliance)
# Connexion : Connect-IPPSSession (Security & Compliance, pas Exchange Online)
# ========================================================================================

# --- OUVERTURE ---
# Workaround WAM (Windows Authentication Manager) — nécessaire sur certaines machines
# Windows 11 récentes où Connect-IPPSSession échoue avec une erreur MSAL silencieuse.
# Cette variable d'environnement force l'authentification sans le broker WAM.
$env:MSAL_ENABLE_WAM = "0"
Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
Connect-IPPSSession -UserPrincipalName GeptorAdmin@0n4mg.onmicrosoft.com

# ========================================================================================
# ÉTAPE 1 : Recherche d'un nom disponible (auto-incrément)
# ========================================================================================
Write-Host "1. Recherche d'un nom disponible pour la policy..." -ForegroundColor Cyan

# Sur un tenant de dev, on reteste souvent le même script sans attendre que la
# suppression précédente se propage (le backend Purview peut mettre plusieurs minutes
# à libérer un nom même après un Remove-DlpCompliancePolicy réussi).
# L'auto-incrément évite le blocage : on cherche le premier nom libre parmi
# "DLP-CreditCard-Protection", "-v2", "-v3", etc.
$BasePolicyName = "DLP-CreditCard-Protection"
$PolicyName     = $BasePolicyName
$Counter        = 2
while (Get-DlpCompliancePolicy -Identity $PolicyName -ErrorAction SilentlyContinue) {
    Write-Host "   '$PolicyName' déjà pris — test avec suffixe -v$Counter..." -ForegroundColor Yellow
    $PolicyName = "$BasePolicyName-v$Counter"
    $Counter++
}
Write-Host "-> Nom retenu pour la policy : '$PolicyName'`n" -ForegroundColor Green

# Même logique pour la règle — elle doit aussi avoir un nom unique dans le tenant
$BaseRuleName = "RULE-CreditCard-Detection"
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
# Ces trois workloads ensemble couvrent l'essentiel des scénarios de fuite de données
# documentaires et email. On exclut Teams, Devices et autres workloads avancés pour
# garder un périmètre cohérent avec le niveau d'un tenant de dev.
#
#   -Mode "TestWithNotifications" : démarre en mode test avec rapports d'incident.
#   Le mode peut être changé après création via Set-DlpCompliancePolicy (cf. exo 4d).
#
#   -Comment : champ de documentation interne, visible dans le portail Purview.
#   Bonne pratique : toujours renseigner — utile pour l'audit et les équipes Sec/Comp.
try {
    $NewPolicy = New-DlpCompliancePolicy `
        -Name              $PolicyName `
        -ExchangeLocation  "All" `
        -SharePointLocation "All" `
        -OneDriveLocation  "All" `
        -Mode              "TestWithNotifications" `
        -Comment           "Exo 4a — DLP protection CB sur Exchange + SPO + ODfB. Mode test, aucun blocage." `
        -ErrorAction Stop

    Write-Host "-> Policy créée : $($NewPolicy.Name) [Mode : $($NewPolicy.Mode)]`n" -ForegroundColor Green
}
catch {
    Write-Host "-> Échec de la création de la policy : $_" -ForegroundColor Red
    return
}

# ========================================================================================
# ÉTAPE 3 : Création de la règle DLP (conditions + actions)
# ========================================================================================
Write-Host "3. Création de la règle '$RuleName'..." -ForegroundColor Cyan

# New-DlpComplianceRule crée la règle à l'intérieur de la policy.
# Une policy sans règle ne fait rien — c'est la règle qui porte la logique.
#
# --- CONDITION ---
# -ContentContainsSensitiveInformation : c'est la condition de détection.
# On lui passe une hashtable avec :
#   Name       : le nom exact du SIT (built-in ou custom)
#   minCount   : nombre minimum d'occurrences pour déclencher la règle
#   maxCount   : nombre maximum (optionnel — "any" si omis)
#   minConfidence : niveau de confiance minimum du SIT pour compter une occurrence
#
# Pour "Credit Card Number", le SIT natif Microsoft a trois niveaux de confiance :
#   65  (Low)    : pattern regex seul — plus de faux positifs
#   75  (Medium) : regex + checksum Luhn valide
#   85  (High)   : regex + Luhn + mot-clé proche (Visa, MasterCard, etc.)
#
# On utilise 75 (Medium) — bon équilibre détection / faux positifs sur tenant dev.
# En production, on monte souvent à 85 pour réduire le bruit.
#
# -AccessScope "NotInOrganization" : la règle se déclenche uniquement quand le contenu
# est partagé vers l'EXTÉRIEUR du tenant. On ne bloque pas la circulation interne.
# Valeurs possibles :
#   NotInOrganization : partage externe (email sortant, lien SPO public, etc.)
#   InOrganization    : trafic interne uniquement
#   All               : interne + externe
#
# --- ACTIONS ---
# -GenerateIncidentReport "SiteAdmin" : envoie un rapport d'incident à l'admin du site
# (pour SPO/ODfB) ou à l'admin Exchange. Valeurs possibles : "SiteAdmin", adresse email.
# -IncidentReportContent : quelles infos inclure dans le rapport.
#   "All" = tout (contenu détecté, règle déclenchée, utilisateur, heure, etc.)
#
# -NotifyUser "LastModifiedBy" : notifie l'utilisateur qui a modifié/envoyé le fichier.
# En mode TestWithNotifications, cette notification est envoyée même si aucun blocage.
# En mode Enable, c'est une notification avant/après blocage selon la config.
# Valeurs possibles : "LastModifiedBy", "Owner", adresse email explicite
#
# Note : -BlockAccess n'est PAS défini ici — c'est volontaire.
# En mode TestWithNotifications, même avec BlockAccess=$true, rien n'est bloqué.
# On l'ajoute explicitement en 4b pour la démonstration avec une policy dédiée.
$SITCondition = @{
    Name          = "Credit Card Number"
    minCount      = 1
    minConfidence = 75
}

try {
    $NewRule = New-DlpComplianceRule `
        -Name                              $RuleName `
        -Policy                            $PolicyName `
        -ContentContainsSensitiveInformation $SITCondition `
        -AccessScope                       "NotInOrganization" `
        -GenerateIncidentReport            "SiteAdmin" `
        -IncidentReportContent             @("All") `
        -NotifyUser                        "LastModifiedBy" `
        -Comment                           "Exo 4a — Détection CB (confiance >= 75%), rapport + notification, aucun blocage." `
        -ErrorAction Stop

    Write-Host "-> Règle créée : $($NewRule.Name)" -ForegroundColor Green
    Write-Host "   Policy parente : $($NewRule.ParentPolicyName)`n" -ForegroundColor Gray
}
catch {
    Write-Host "-> Échec de la création de la règle : $_" -ForegroundColor Red
    Write-Host "   La policy '$PolicyName' a été créée mais reste sans règle." -ForegroundColor Yellow
    Write-Host "   Supprimer manuellement via : Remove-DlpCompliancePolicy -Identity '$PolicyName' -Confirm:`$false" -ForegroundColor Yellow
    return
}

# ========================================================================================
# ÉTAPE 4 : Vérification depuis la source de vérité
# ========================================================================================
Write-Host "4. Vérification depuis le backend Purview..." -ForegroundColor Cyan

# On relit depuis l'API plutôt que de faire confiance à l'objet local retourné
# par New-DlpCompliancePolicy — le backend peut avoir normalisé certaines valeurs.
Start-Sleep -Seconds 3

$CheckPolicy = Get-DlpCompliancePolicy -Identity $PolicyName -ErrorAction SilentlyContinue
$CheckRule   = Get-DlpComplianceRule   -Policy $PolicyName  -ErrorAction SilentlyContinue

if ($CheckPolicy) {
    Write-Host "-> Policy confirmée :" -ForegroundColor Green
    [PSCustomObject]@{
        Nom          = $CheckPolicy.Name
        Mode         = $CheckPolicy.Mode
        Exchange     = if ($CheckPolicy.ExchangeLocation) { "All" } else { "Non configuré" }
        SharePoint   = if ($CheckPolicy.SharePointLocation) { "All" } else { "Non configuré" }
        OneDrive     = if ($CheckPolicy.OneDriveLocation) { "All" } else { "Non configuré" }
        DistribStatus= $CheckPolicy.DistributionStatus
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
        AccessScope   = $CheckRule.AccessScope
        RapportIncident = "SiteAdmin"
        NotifUser     = $CheckRule.NotifyUser -join ", "
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
# Le backend Purview distribue la policy vers les workloads (Exchange, SPO, ODfB) en
# arrière-plan. Ce processus prend quelques minutes à quelques heures selon les workloads.
# "Success" confirme que la distribution est terminée.
# "Pending" au moment de l'exo est attendu — pas un problème.
[PSCustomObject]@{
    PolicyCréée      = $PolicyName
    RègleCréée       = $RuleName
    Mode             = "TestWithNotifications"
    SITSurveillé     = "Credit Card Number (confiance >= 75%)"
    Workloads        = "Exchange, SharePoint, OneDrive"
    ActionBlocage    = "Aucune (mode test)"
    RapportIncident  = "Oui (SiteAdmin)"
    NotifUtilisateur = "Oui (LastModifiedBy)"
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
# FERMETURE
# ========================================================================================
# On ne ferme PAS la session IPPSSession ici — les exos 4b, 4c, 4d, 4e
# s'appuient sur la même connexion et sont souvent exécutés dans la foulée.
# Fermeture manuelle en fin de session :
#   Get-PSSession | Remove-PSSession
Write-Host "Session IPPSSession conservée pour les exos suivants." -ForegroundColor Magenta
Write-Host "Fermeture manuelle : Get-PSSession | Remove-PSSession`n" -ForegroundColor Gray
