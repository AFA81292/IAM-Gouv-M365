# ========================================================================================
# Exercice 6d : eDiscovery Case + Hold sur mailbox ciblée
# ========================================================================================
# eDiscovery = processus légal de collecte et conservation de preuves numériques.
# Dans Purview, deux niveaux :
#   - eDiscovery Standard (inclus E3/E5) : cases, holds, searches, exports basiques
#   - eDiscovery Premium (inclus E5)     : analyse avancée, custodians, review sets
#
# Ce script couvre eDiscovery Standard.
#
# Différence Hold vs Retention Policy :
#   Retention Policy (chap. 05) : règle de fond, gouvernance préétablie —
#   conserve le contenu X ans selon une politique générale.
#   eDiscovery Hold              : blocage ciblé dans le cadre d'une enquête —
#   empêche toute suppression sur une mailbox SPÉCIFIQUE pendant l'investigation.
#   Le hold prime sur toute politique de suppression automatique.
#
# Cas d'usage réel :
#   RH signale qu'un employé est suspecté de fuite de données.
#   Sécurité ouvre un case, pose un hold sur sa mailbox, lance une Content Search,
#   exporte pour le juridique. Le hold garantit que rien ne peut être supprimé
#   pendant l'enquête — même si une Retention Policy prévoyait une suppression.
#
# ARCHITECTURE SESSION — même logique que 6b :
#   Les cmdlets eDiscovery (*-ComplianceCase, *-CaseHoldPolicy, *-CaseHoldRule)
#   ne sont chargées QUE si la session IPPSSession est ouverte avec
#   -EnableSearchOnlySession. Sans ce flag, les cmdlets sont introuvables
#   ("not recognized as a name of a cmdlet") même si le module est bien installé.
#   Contrairement à 6b qui nécessitait deux sessions (New- sans flag, Start- avec),
#   ici TOUTES les opérations nécessitent le flag — une seule session suffit.
#
#   Vérification mailbox : nécessite Connect-ExchangeOnline séparément,
#   car Exchange Online et IPPSSession sont deux endpoints distincts.
#
# Module requis : ExchangeOnlineManagement >= 3.9.0
# Connexion     : Connect-ExchangeOnline (check mailbox) + Connect-IPPSSession -EnableSearchOnlySession
# Licence       : Microsoft Purview eDiscovery Standard (inclus E3/E5)
# ========================================================================================

# --- OUVERTURE — RESET DE SESSION TOTAL ---
Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
Get-PSSession | Remove-PSSession
$env:MSAL_ENABLE_WAM = "0"

# ========================================================================================
# ÉTAPE 1 : Vérification du prérequis mailbox (Connect-ExchangeOnline)
# ========================================================================================
# Un hold posé sur une mailbox inexistante se crée sans erreur mais ne protège rien.
# On vérifie l'existence avant de continuer.
# Cette vérification nécessite Connect-ExchangeOnline — pas IPPSSession.
Write-Host "1. Vérification de la mailbox cible..." -ForegroundColor Cyan

$TargetMailbox = "shepard@0n4mg.onmicrosoft.com"

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

# Fermeture Exchange Online — le reste utilise uniquement IPPSSession.
Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
Get-PSSession | Remove-PSSession
Start-Sleep -Seconds 2

# ========================================================================================
# OUVERTURE SESSION IPPS — avec -EnableSearchOnlySession (obligatoire)
# ========================================================================================
# Sans ce flag, *-ComplianceCase et *-CaseHoldPolicy ne sont pas chargées —
# elles retournent "not recognized as a name of a cmdlet" même avec le bon module.
# Avec le flag, le module charge un ensemble de fonctions supplémentaires depuis
# un endpoint Microsoft dédié eDiscovery (cpfdwebservicecloudapp.net).
Write-Host "Ouverture session IPPSSession avec -EnableSearchOnlySession..." -ForegroundColor Gray
Connect-IPPSSession -UserPrincipalName GeptorAdmin@0n4mg.onmicrosoft.com -EnableSearchOnlySession

# ========================================================================================
# ÉTAPE 2 : Recherche d'un nom disponible pour le Case (auto-incrément)
# ========================================================================================
# "Lazarus" = le projet de résurrection de Shepard dans Mass Effect 2.
Write-Host "`n2. Recherche d'un nom disponible pour le Case..." -ForegroundColor Cyan

$BaseCaseName = "CASE-ProjectLazarus-Shepard"
$CaseName     = $BaseCaseName
$Counter      = 2

# Get-ComplianceCase supporte -Identity — lookup direct possible ici,
# contrairement à Get-UnifiedAuditLogRetentionPolicy (exo 6a).
while (Get-ComplianceCase -Identity $CaseName -ErrorAction SilentlyContinue) {
    Write-Host "   '$CaseName' déjà pris — test avec suffixe -v$Counter..." -ForegroundColor Yellow
    $CaseName = "$BaseCaseName-v$Counter"
    $Counter++
}

Write-Host "-> Nom retenu pour le Case : '$CaseName'`n" -ForegroundColor Green

# ========================================================================================
# ÉTAPE 3 : Création du eDiscovery Case
# ========================================================================================
# Le Case est le conteneur de l'investigation — regroupe holds, searches et exports.
# Tout hold doit être rattaché à un Case : impossible de créer un hold orphelin.
#
# -CaseType "eDiscovery" : Standard. Autre valeur : "AdvancedEdiscovery" (Premium).
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
# Un eDiscovery Hold = deux objets distincts, ordre obligatoire :
#
#   1. CaseHoldPolicy  : QUI est mis en hold (mailbox ou site ciblé)
#      → New-CaseHoldPolicy
#
#   2. CaseHoldRule    : QUOI est retenu (query KQL — vide = tout le contenu)
#      → New-CaseHoldRule
#
# Sans CaseHoldRule, la policy existe mais ne retient rien — objet incomplet.
# Même pattern Policy + Rule que DLP (chap. 04) et Retention (chap. 05).
Write-Host "5. Création du Hold '$HoldName'..." -ForegroundColor Cyan

# --- CaseHoldPolicy ---
# -Case : Case auquel ce hold est rattaché (obligatoire).
# -ExchangeLocation : mailbox(es) à mettre en hold.
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
    Write-Host "-> Échec CaseHoldPolicy : $_" -ForegroundColor Red
    Write-Host "   Supprimer le case : Remove-ComplianceCase -Identity '$CaseName' -Confirm:`$false" -ForegroundColor Yellow
    Get-PSSession | Remove-PSSession
    return
}

# --- CaseHoldRule ---
# -ContentMatchQuery "" : query vide = hold sur TOUT le contenu de la mailbox.
# On pourrait restreindre : "CONFIDENTIEL" ne retiendrait que les éléments
# contenant ce mot-clé. Sans query = filet maximal, posture standard en investigation.
try {
    $NewHoldRule = New-CaseHoldRule `
        -Policy            $HoldName `
        -ContentMatchQuery "" `
        -ErrorAction Stop

    Write-Host "-> CaseHoldRule créée : $($NewHoldRule.Name)`n" -ForegroundColor Green
}
catch {
    Write-Host "-> Échec CaseHoldRule : $_" -ForegroundColor Red
    Write-Host "   Policy créée mais sans règle — hold incomplet." -ForegroundColor Yellow
    Write-Host "   Supprimer policy : Remove-CaseHoldPolicy -Identity '$HoldName' -Confirm:`$false" -ForegroundColor Yellow
    Write-Host "   Supprimer case   : Remove-ComplianceCase -Identity '$CaseName' -Confirm:`$false" -ForegroundColor Yellow
    Get-PSSession | Remove-PSSession
    return
}

# ========================================================================================
# ÉTAPE 6 : Vérification depuis la source de vérité
# ========================================================================================
Write-Host "6. Vérification depuis le backend Purview..." -ForegroundColor Cyan
Start-Sleep -Seconds 5

$CheckCase   = Get-ComplianceCase   -Identity $CaseName -ErrorAction SilentlyContinue
$CheckPolicy = Get-CaseHoldPolicy   -Identity $HoldName -ErrorAction SilentlyContinue
$CheckRule   = Get-CaseHoldRule     -Policy   $HoldName -ErrorAction SilentlyContinue

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
        Nom           = $CheckPolicy.Name
        CaseParent    = $CheckPolicy.Case
        Activé        = $CheckPolicy.Enabled
        Mailbox       = ($CheckPolicy.ExchangeLocation -join ", ")
        DistribStatus = $CheckPolicy.DistributionStatus
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
    CaseCréé        = $CaseName
    HoldCréé        = $HoldName
    MailboxProtégée = $TargetMailbox
    PortéeHold      = "Tout le contenu (query vide)"
    DistribStatus   = if ($CheckPolicy) { $CheckPolicy.DistributionStatus } else { "Non vérifié" }
    PrioritéHold    = "Prime sur toute Retention Policy de suppression automatique"
    PropagationHold = "Effective une fois DistributionStatus = 'Success' (quelques minutes)"
} | Format-List

Write-Host "Info : DistributionStatus 'Pending' est normal à la création." -ForegroundColor Yellow

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
