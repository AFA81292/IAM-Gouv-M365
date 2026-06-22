# ========================================================================================
# Exercice 6d : eDiscovery Case + Hold sur mailbox ciblée
# ========================================================================================
# eDiscovery = processus légal de collecte et conservation de preuves numériques.
# Dans Purview, il se décompose en deux niveaux :
#   - eDiscovery Standard (inclus E3/E5) : cases, holds, searches, exports basiques
#   - eDiscovery Premium (inclus E5)     : analyse avancée, custodians, review sets
#
# Ce script couvre eDiscovery Standard — le niveau pertinent pour un tenant dev E5.
#
# Différence Hold vs Retention Policy :
#   Retention Policy (chap. 05) : règle de fond appliquée à un périmètre — conserve
#   le contenu X ans selon une politique de gouvernance préétablie.
#   eDiscovery Hold              : blocage ciblé posé dans le cadre d'une enquête —
#   empêche la suppression du contenu d'une mailbox/site SPÉCIFIQUE pendant
#   la durée de l'investigation. Le hold prime sur toute politique de suppression.
#
# Cas d'usage réel :
#   RH signale qu'un employé est suspecté de fuite de données.
#   L'équipe sécurité ouvre un case, pose un hold sur sa mailbox,
#   lance une Content Search pour collecter les preuves, exporte pour le juridique.
#   Le hold garantit que rien ne peut être supprimé pendant l'enquête —
#   même si une Retention Policy prévoyait une suppression automatique.
#
# PRÉREQUIS : la mailbox shepard@0n4mg.onmicrosoft.com doit exister.
#   Si elle n'est pas encore provisionnée :
#   1. Assigner une licence E5 à Shepard depuis Entra portal
#   2. Se connecter à outlook.office.com avec le compte Shepard
#   3. Attendre 5-15 minutes
#   4. Vérifier : Connect-ExchangeOnline puis Get-Mailbox -Identity "shepard@0n4mg.onmicrosoft.com"
#
# Module requis : ExchangeOnlineManagement
# Connexion     : Connect-IPPSSession
# Licence       : Microsoft Purview eDiscovery Standard (inclus E3/E5)
# ========================================================================================

# --- OUVERTURE — RESET DE SESSION TOTAL ---
Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
Get-PSSession | Remove-PSSession
$env:MSAL_ENABLE_WAM = "0"
Connect-IPPSSession -UserPrincipalName GeptorAdmin@0n4mg.onmicrosoft.com

# ========================================================================================
# ÉTAPE 1 : Vérification du prérequis mailbox
# ========================================================================================
# Un hold posé sur une mailbox inexistante se crée sans erreur mais ne protège rien.
# On vérifie l'existence avant de continuer — si absente, on sort proprement avec
# un message explicite plutôt qu'un résultat silencieusement vide.
Write-Host "1. Vérification de la mailbox cible..." -ForegroundColor Cyan

$TargetMailbox = "shepard@0n4mg.onmicrosoft.com"

# La vérification d'existence d'une mailbox nécessite Connect-ExchangeOnline,
# pas Connect-IPPSSession. On ouvre une seconde connexion pour ce check uniquement.
Connect-ExchangeOnline -UserPrincipalName GeptorAdmin@0n4mg.onmicrosoft.com -ShowBanner:$false

$MailboxCheck = Get-Mailbox -Identity $TargetMailbox -ErrorAction SilentlyContinue

if (-not $MailboxCheck) {
    Write-Host "-> ARRÊT : mailbox '$TargetMailbox' introuvable." -ForegroundColor Red
    Write-Host "   Prérequis : assigner une licence E5 à Shepard, se connecter à OWA," -ForegroundColor Yellow
    Write-Host "   attendre 5-15 minutes, puis relancer ce script." -ForegroundColor Yellow
    Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
    Get-PSSession | Remove-PSSession
    return
}

Write-Host "-> Mailbox confirmée : $($MailboxCheck.PrimarySmtpAddress)`n" -ForegroundColor Green

# On ferme Exchange Online — le reste du script utilise uniquement IPPSSession.
Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue

# ========================================================================================
# ÉTAPE 2 : Recherche d'un nom disponible pour le Case (auto-incrément)
# ========================================================================================
# "Lazarus" = le projet de résurrection de Shepard dans Mass Effect 2 —
# approprié pour un case d'investigation sur ce personnage.
Write-Host "2. Recherche d'un nom disponible pour le Case..." -ForegroundColor Cyan

$BaseCaseName = "CASE-ProjectLazarus-Shepard"
$CaseName     = $BaseCaseName
$Counter      = 2

while (Get-ComplianceCase -Identity $CaseName -ErrorAction SilentlyContinue) {
    Write-Host "   '$CaseName' déjà pris — test avec suffixe -v$Counter..." -ForegroundColor Yellow
    $CaseName = "$BaseCaseName-v$Counter"
    $Counter++
}

Write-Host "-> Nom retenu pour le Case : '$CaseName'`n" -ForegroundColor Green

# ========================================================================================
# ÉTAPE 3 : Création du eDiscovery Case
# ========================================================================================
# Le Case est le conteneur de l'investigation — il regroupe holds, searches et exports.
# Tout hold doit être rattaché à un Case : impossible de créer un hold orphelin.
#
# -CaseType "eDiscovery" : eDiscovery Standard. L'autre valeur est "AdvancedEdiscovery"
#   (eDiscovery Premium, fonctionnalités supplémentaires mais même licence E5 ici).
Write-Host "3. Création du eDiscovery Case '$CaseName'..." -ForegroundColor Cyan

try {
    $NewCase = New-ComplianceCase `
        -Name        $CaseName `
        -Description "Exo 6d — Investigation Project Lazarus. Hold sur mailbox Shepard." `
        -CaseType    "eDiscovery" `
        -ErrorAction Stop

    Write-Host "-> Case créé : $($NewCase.Name) [Status : $($NewCase.Status)]`n" -ForegroundColor Green
}
catch {
    Write-Host "-> Échec de la création du Case : $_" -ForegroundColor Red
    Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
    Get-PSSession | Remove-PSSession
    return
}

# ========================================================================================
# ÉTAPE 4 : Recherche d'un nom disponible pour le Hold (auto-incrément)
# ========================================================================================
Write-Host "4. Recherche d'un nom disponible pour le Hold..." -ForegroundColor Cyan

$BaseHoldName = "HOLD-Lazarus-Shepard-Mailbox"
$HoldName     = $BaseHoldName
$Counter      = 2

while (Get-CaseHoldPolicy -Identity $HoldName -ErrorAction SilentlyContinue) {
    Write-Host "   '$HoldName' déjà pris — test avec suffixe -v$Counter..." -ForegroundColor Yellow
    $HoldName = "$BaseHoldName-v$Counter"
    $Counter++
}

Write-Host "-> Nom retenu pour le Hold : '$HoldName'`n" -ForegroundColor Green

# ========================================================================================
# ÉTAPE 5 : Création du Hold sur la mailbox
# ========================================================================================
# Un eDiscovery Hold se crée en deux objets distincts, dans cet ordre obligatoire :
#
#   1. CaseHoldPolicy  : définit QUI est mis en hold (la mailbox ou le site ciblé)
#      → New-CaseHoldPolicy
#
#   2. CaseHoldRule    : définit QUOI est retenu (query KQL optionnelle — vide = tout)
#      → New-CaseHoldRule
#
# Sans CaseHoldRule, le hold existe mais ne retient rien — objet incomplet.
# C'est le même pattern Policy + Rule que DLP et Retention.
#
# --- CRÉATION DE LA CASEHOLDPOLICY ---
# -Case : nom du Case auquel ce hold est rattaché (obligatoire).
# -ExchangeLocation : mailbox(es) à mettre en hold. Accepte UPN ou adresse SMTP.
#   Autres paramètres de location disponibles (non utilisés ici) :
#   -SharePointLocation : sites SharePoint
#   -PublicFolderLocation : dossiers publics Exchange
Write-Host "5. Création du Hold '$HoldName'..." -ForegroundColor Cyan

try {
    $NewHoldPolicy = New-CaseHoldPolicy `
        -Name             $HoldName `
        -Case             $CaseName `
        -ExchangeLocation $TargetMailbox `
        -Enabled          $true `
        -ErrorAction Stop

    Write-Host "-> CaseHoldPolicy créée : $($NewHoldPolicy.Name)" -ForegroundColor Green
}
catch {
    Write-Host "-> Échec de la création de la CaseHoldPolicy : $_" -ForegroundColor Red
    Write-Host "   Le Case '$CaseName' a été créé mais reste sans hold." -ForegroundColor Yellow
    Write-Host "   Supprimer via : Remove-ComplianceCase -Identity '$CaseName' -Confirm:`$false" -ForegroundColor Yellow
    Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
    Get-PSSession | Remove-PSSession
    return
}

# --- CRÉATION DE LA CASEHOLDRULE ---
# -Policy : nom de la CaseHoldPolicy parente (obligatoire).
# -ContentMatchQuery "" : query KQL vide = hold sur TOUT le contenu de la mailbox.
#   On pourrait restreindre : "CONFIDENTIEL" ne retiendrait que les éléments
#   contenant ce mot-clé. Sans query = filet maximal, posture standard en investigation.
#
# Note : pas de paramètre -Name obligatoire sur New-CaseHoldRule —
# le nom est généré automatiquement par Purview à partir du nom de la policy.
try {
    $NewHoldRule = New-CaseHoldRule `
        -Policy             $HoldName `
        -ContentMatchQuery  "" `
        -ErrorAction Stop

    Write-Host "-> CaseHoldRule créée : $($NewHoldRule.Name)`n" -ForegroundColor Green
}
catch {
    Write-Host "-> Échec de la création de la CaseHoldRule : $_" -ForegroundColor Red
    Write-Host "   La CaseHoldPolicy '$HoldName' existe mais est sans règle — hold incomplet." -ForegroundColor Yellow
    Write-Host "   Supprimer policy : Remove-CaseHoldPolicy -Identity '$HoldName' -Confirm:`$false" -ForegroundColor Yellow
    Write-Host "   Supprimer case   : Remove-ComplianceCase -Identity '$CaseName' -Confirm:`$false" -ForegroundColor Yellow
    Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
    Get-PSSession | Remove-PSSession
    return
}

# ========================================================================================
# ÉTAPE 6 : Vérification depuis la source de vérité
# ========================================================================================
Write-Host "6. Vérification depuis le backend Purview..." -ForegroundColor Cyan
Start-Sleep -Seconds 5

$CheckCase   = Get-ComplianceCase    -Identity $CaseName -ErrorAction SilentlyContinue
$CheckPolicy = Get-CaseHoldPolicy    -Identity $HoldName -ErrorAction SilentlyContinue
$CheckRule   = Get-CaseHoldRule      -Policy   $HoldName -ErrorAction SilentlyContinue

if ($CheckCase) {
    Write-Host "-> Case confirmé :" -ForegroundColor Green
    [PSCustomObject]@{
        Nom         = $CheckCase.Name
        Status      = $CheckCase.Status
        Type        = $CheckCase.CaseType
        Description = $CheckCase.Description
    } | Format-List
} else {
    Write-Host "-> ATTENTION : Case non trouvé lors de la vérification." -ForegroundColor Red
}

if ($CheckPolicy) {
    Write-Host "-> CaseHoldPolicy confirmée :" -ForegroundColor Green
    [PSCustomObject]@{
        Nom              = $CheckPolicy.Name
        CaseParent       = $CheckPolicy.Case
        Activé           = $CheckPolicy.Enabled
        Mailbox          = ($CheckPolicy.ExchangeLocation -join ", ")
        DistribStatus    = $CheckPolicy.DistributionStatus
    } | Format-List
} else {
    Write-Host "-> ATTENTION : CaseHoldPolicy non trouvée lors de la vérification." -ForegroundColor Red
}

if ($CheckRule) {
    Write-Host "-> CaseHoldRule confirmée :" -ForegroundColor Green
    [PSCustomObject]@{
        Nom    = $CheckRule.Name
        Policy = $CheckRule.Policy
        Query  = if ($CheckRule.ContentMatchQuery) { $CheckRule.ContentMatchQuery } else { "(vide — hold sur tout le contenu)" }
    } | Format-List
} else {
    Write-Host "-> ATTENTION : CaseHoldRule non trouvée lors de la vérification." -ForegroundColor Red
}

# ========================================================================================
# ÉTAPE 7 : Résumé
# ========================================================================================
Write-Host "=== RÉSUMÉ ===" -ForegroundColor Magenta

[PSCustomObject]@{
    CaseCréé         = $CaseName
    HoldCréé         = $HoldName
    MailboxProtégée  = $TargetMailbox
    PortéeHold       = "Tout le contenu (query vide)"
    DistribStatus    = if ($CheckPolicy) { $CheckPolicy.DistributionStatus } else { "Non vérifié" }
    EffetImmédiat    = "Non — propagation vers Exchange Online en cours (quelques minutes)"
    PrioritéHold     = "Prime sur toute Retention Policy de suppression automatique"
} | Format-List

Write-Host "Info : DistributionStatus 'Pending' est normal à la création." -ForegroundColor Yellow
Write-Host "Le hold est effectif une fois DistributionStatus = 'Success'.`n" -ForegroundColor Yellow

# ========================================================================================
# NETTOYAGE MÉMOIRE
# ========================================================================================
Remove-Variable TargetMailbox, MailboxCheck, BaseCaseName, CaseName, BaseHoldName,
                HoldName, Counter, NewCase, NewHoldPolicy, NewHoldRule,
                CheckCase, CheckPolicy, CheckRule `
                -ErrorAction SilentlyContinue

# --- FERMETURE — RESET DE SESSION TOTAL ---
Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
Get-PSSession | Remove-PSSession
Write-Host "Sessions fermées proprement." -ForegroundColor Magenta
