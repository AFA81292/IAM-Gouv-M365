# ========================================================================================
# Exercice 2e : Sensitivity Labels — Politique d'auto-labeling côté service (Exchange)
# ========================================================================================
# Concept : Contrairement aux exos précédents (label appliqué manuellement ou publié
# pour choix utilisateur), ici c'est Purview qui scanne le contenu en arrière-plan
# et applique le label automatiquement, sans action humaine — y compris sur des
# emails déjà envoyés stockés dans Exchange.
#
# Architecture : deux objets distincts à créer, dans l'ordre :
#   New-AutoSensitivityLabelPolicy → le conteneur
#                                    (quel label appliquer, quel emplacement, quel mode)
#   New-AutoSensitivityLabelRule   → la condition de déclenchement
#                                    (quel SIT, quel seuil d'occurrences)
#   → Une policy sans règle ne détecte rien.
#   → Une règle sans policy ne peut pas exister.
#
# Mode "TestWithoutNotifications" — pourquoi pas "TestWithNotifications" :
#   La doc Microsoft Learn liste TestWithNotifications comme valeur valide, mais en
#   pratique New-AutoSensitivityLabelPolicy le rejette avec ModeNotSupportedByMipCmdletException.
#   La solution de contournement "créer en Test puis basculer via Set-" échoue aussi.
#   TestWithNotifications n'est pilotable qu'depuis le portail Purview, pas en PowerShell.
#   → On utilise TestWithoutNotifications : scan silencieux, détections visibles dans
#     Activity Explorer, aucun label appliqué réellement, aucun utilisateur notifié.
#
# REX — suppression et PendingDeletion :
#   Remove-AutoSensitivityLabel* ne supprime pas immédiatement l'objet — il le passe
#   en état "PendingDeletion" qui peut durer des heures. Pendant ce temps, le nom
#   reste considéré comme pris : une recréation avec le même nom échoue même si
#   l'objet semble avoir disparu du portail. Solution : toujours changer de nom
#   (auto-incrément) plutôt que d'attendre la fin du PendingDeletion.
#
# Ce que fait ce script :
#   1. Reset total de session
#   2. Vérifie que le label cible et le SIT prérequis existent
#   3. Recherche un nom de policy disponible (auto-incrément)
#   4. Crée la policy d'auto-labeling en mode TestWithoutNotifications
#   5. Crée la règle de détection (SIT + seuil)
#   6. Démarre la simulation (sans ça, Activity Explorer reste vide)
#   7. Vérifie la création depuis la source de vérité
#   8. Ferme proprement toutes les sessions
#
# Module requis : ExchangeOnlineManagement
# Connexion     : Connect-IPPSSession
# ========================================================================================

# --- OUVERTURE — RESET DE SESSION TOTAL ---
# REX : des sessions fantômes restées ouvertes depuis un script précédent peuvent
# provoquer des erreurs silencieuses ou des authentifications croisées.
# On purge TOUT avant de commencer, sans exception.
#
# $env:MSAL_ENABLE_WAM = "0" : désactive WAM pour cette session PowerShell.
# WAM peut interférer avec Connect-IPPSSession et provoquer des boucles
# d'authentification silencieuses. À positionner AVANT Connect-IPPSSession.
#
# Note : Connect-IPPSSession ne supporte pas -ShowBanner:$false — bandeau normal.
Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
Get-PSSession | Remove-PSSession
$env:MSAL_ENABLE_WAM = "0"
Connect-IPPSSession -UserPrincipalName GeptorAdmin@0n4mg.onmicrosoft.com

# ========================================================================================
# ÉTAPE 1 : Vérification des prérequis
# ========================================================================================
Write-Host "1. Vérification des prérequis..." -ForegroundColor Cyan

# Prérequis 1 : le label cible doit exister (créé en 2b).
# Sans lui, la policy ne peut pas être créée — ApplySensitivityLabel serait invalide.
$TargetLabel = "NormandySR2 - Interne"
$LabelCheck  = Get-Label -Identity $TargetLabel -ErrorAction SilentlyContinue

if (-not $LabelCheck) {
    Write-Host "   -> MANQUANT : label '$TargetLabel' — exécuter les exercices 2a/2b au préalable." -ForegroundColor Red
    Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
    Get-PSSession | Remove-PSSession
    return
}
Write-Host "   -> OK : label '$TargetLabel' [Guid : $($LabelCheck.Guid)]" -ForegroundColor Green

# Prérequis 2 : le SIT custom doit exister (créé en 1b).
# C'est lui qui définit ce que Purview cherche dans le contenu Exchange.
# On utilise Get-DlpSensitiveInformationType + Where-Object : pas de filtre -Identity
# direct sur les SIT custom, la recherche en masse est la méthode fiable.
$TargetSIT = "Cerberus Corp - Numéro de Badge Interne"
$SITCheck  = Get-DlpSensitiveInformationType | Where-Object { $_.Name -eq $TargetSIT }

if (-not $SITCheck) {
    Write-Host "   -> MANQUANT : SIT '$TargetSIT' — exécuter l'exercice 1b au préalable." -ForegroundColor Red
    Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
    Get-PSSession | Remove-PSSession
    return
}
Write-Host "   -> OK : SIT '$TargetSIT' trouvé.`n" -ForegroundColor Green

# ========================================================================================
# ÉTAPE 2 : Recherche d'un nom disponible (auto-incrément)
# ========================================================================================
Write-Host "2. Recherche d'un nom disponible pour la policy..." -ForegroundColor Cyan

# REX PendingDeletion (cf. concept en tête) : si un run précédent a supprimé une policy
# du même nom, elle peut être encore en PendingDeletion et bloquer la recréation.
# L'auto-incrément contourne ce piège sans attendre la fin de la purge.
$BasePolicyName = "AL-NormandySR2-BadgeGCORP"
$PolicyName     = $BasePolicyName
$Counter        = 2

while (Get-AutoSensitivityLabelPolicy -Identity $PolicyName -ErrorAction SilentlyContinue) {
    Write-Host "   '$PolicyName' déjà pris — test avec suffixe -v$Counter..." -ForegroundColor Yellow
    $PolicyName = "$BasePolicyName-v$Counter"
    $Counter++
}
Write-Host "-> Nom retenu pour la policy : '$PolicyName'`n" -ForegroundColor Green

# ========================================================================================
# ÉTAPE 3 : Création de la policy d'auto-labeling
# ========================================================================================
Write-Host "3. Création de la policy '$PolicyName'..." -ForegroundColor Cyan

# -ApplySensitivityLabel : le label qui sera appliqué automatiquement si la règle matche.
#   Accepte un nom de label (DisplayName) ou un GUID.
#   Attention : doit être un sublabel publiable — pas un label group parent.
#
# -ExchangeLocation "All" : scanne toutes les boîtes Exchange du tenant.
#   Pour cibler un groupe ou une mailbox : remplacer "All" par l'adresse SMTP.
#
# -Mode "TestWithoutNotifications" : scan silencieux.
#   Détections visibles dans Activity Explorer (portail Purview > Gestion des données).
#   Aucun label n'est appliqué réellement, aucun utilisateur n'est notifié.
#   Pour appliquer réellement après validation : Set-AutoSensitivityLabelPolicy -Mode Enable
try {
    $NewPolicy = New-AutoSensitivityLabelPolicy `
        -Name                  $PolicyName `
        -ExchangeLocation      "All" `
        -ApplySensitivityLabel $TargetLabel `
        -Mode                  "TestWithoutNotifications" `
        -Comment               "Exo 2e — Auto-labeling Exchange : détecte SIT badge GCORP (1b), applique NormandySR2 - Interne (2b)." `
        -ErrorAction Stop

    Write-Host "-> Policy créée avec succès." -ForegroundColor Green
    Write-Host "   Guid : $($NewPolicy.Guid)`n" -ForegroundColor Green
}
catch {
    Write-Host "-> Échec de la création de la policy : $_" -ForegroundColor Red
    Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
    Get-PSSession | Remove-PSSession
    return
}

# ========================================================================================
# ÉTAPE 4 : Création de la règle de détection
# ========================================================================================
Write-Host "4. Création de la règle de détection..." -ForegroundColor Cyan

# Nomenclature de la règle : dérivée du nom de la policy via -replace.
# Pourquoi : le nom de règle doit être unique sur tout le tenant AutoLabeling,
# pas seulement dans sa policy. En dérivant du nom de policy (qui est lui-même
# incrémenté), la règle suit automatiquement le même suffixe — les deux avancent
# toujours ensemble sans collision.
$RuleName = $PolicyName -replace [regex]::Escape($BasePolicyName), "Rule-DetectBadgeGCORP"
Write-Host "-> Nom retenu pour la règle : '$RuleName'" -ForegroundColor Green

# MinCount = 2 : la règle se déclenche si au moins 2 occurrences du SIT sont détectées.
#   Seuil à 2 pour limiter les faux positifs (un seul numéro de badge peut être
#   légitime dans un email RH — deux occurrences signalent un partage non maîtrisé).
#
# Pas de minconfidence spécifié ici :
#   Le SIT custom (1b) a ses propres seuils de confiance dans son XML (85/75).
#   Ajouter minconfidence filtrerait par-dessus, ce qui risque de masquer des détections.
#   On laisse Purview évaluer nativement et on ne contraint que le nombre d'occurrences.
#
# -Workload "Exchange" :
#   Distinct de -ExchangeLocation sur la policy. ExchangeLocation définit le périmètre
#   global de la policy (quelles mailboxes sont dans le scope). Workload définit sur
#   quel service CETTE règle précise s'évalue au moment du scan.
#   Paramètre obligatoire — non documenté comme tel dans la doc officielle.
try {
    $NewRule = New-AutoSensitivityLabelRule `
        -Policy  $PolicyName `
        -Name    $RuleName `
        -Workload "Exchange" `
        -ContentContainsSensitiveInformation @{
            Name     = $TargetSIT
            MinCount = "2"
        } `
        -ErrorAction Stop

    Write-Host "-> Règle créée avec succès." -ForegroundColor Green
    Write-Host "   Règle : '$RuleName' [MinCount = 2 / Workload = Exchange]`n" -ForegroundColor Green
}
catch {
    Write-Host "-> Échec de la création de la règle : $_" -ForegroundColor Red
    Write-Host "   La policy '$PolicyName' a été créée mais reste sans règle (orpheline)." -ForegroundColor Yellow

    # Nettoyage de la policy orpheline.
    # Note : pas de -ErrorAction SilentlyContinue ici — on veut voir si Remove- échoue.
    # Si la policy est déjà en PendingDeletion, le Remove- le signalera explicitement.
    Write-Host "   Tentative de suppression de la policy orpheline..." -ForegroundColor Yellow
    try {
        Remove-AutoSensitivityLabelPolicy -Identity $PolicyName -Confirm:$false -ErrorAction Stop
        Write-Host "   -> Policy orpheline supprimée." -ForegroundColor Green
    }
    catch {
        Write-Host "   -> ÉCHEC du nettoyage automatique : $_" -ForegroundColor Red
        Write-Host "   -> Suppression manuelle requise avant de relancer (cf. REX PendingDeletion)." -ForegroundColor Red
    }

    Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
    Get-PSSession | Remove-PSSession
    return
}

# ========================================================================================
# ÉTAPE 5 : Démarrage de la simulation
# ========================================================================================
Write-Host "5. Démarrage de la simulation..." -ForegroundColor Cyan

# -StartSimulation $true : déclenche le scan Purview sur les emails Exchange.
# Sans cette commande, la policy et la règle existent mais le scan ne démarre pas.
# Purview affiche d'ailleurs un warning "requires simulation to be restarted" dans
# le portail si on crée la policy sans lancer la simulation.
# Les résultats de détection sont visibles dans Activity Explorer (portail Purview)
# après quelques heures selon le volume de mails à scanner.
try {
    Set-AutoSensitivityLabelPolicy -Identity $PolicyName -StartSimulation $true -ErrorAction Stop
    Write-Host "-> Simulation démarrée avec succès." -ForegroundColor Green
    Write-Host "   Les détections seront visibles dans Activity Explorer (portail Purview) sous quelques heures.`n" -ForegroundColor Yellow
}
catch {
    Write-Host "-> Échec du démarrage de la simulation : $_" -ForegroundColor Red
    Write-Host "   La policy et la règle existent — démarrage manuel possible depuis le portail Purview.`n" -ForegroundColor Yellow
}

# ========================================================================================
# ÉTAPE 6 : Vérification depuis la source de vérité
# ========================================================================================
Write-Host "6. Vérification depuis le backend Purview..." -ForegroundColor Cyan

# REX : même délai de propagation que pour les DLP policies.
# 30 secondes couvrent la réplication vers le backend Purview.
# La distribution vers Exchange (scan effectif) est un processus long — séparé.
Start-Sleep -Seconds 30

$CheckPolicy = Get-AutoSensitivityLabelPolicy -Identity $PolicyName -ErrorAction SilentlyContinue
$CheckRule   = Get-AutoSensitivityLabelRule   -Identity $RuleName   -ErrorAction SilentlyContinue

if ($CheckPolicy) {
    Write-Host "-> Policy confirmée :" -ForegroundColor Green
    [PSCustomObject]@{
        Nom              = $CheckPolicy.Name
        Mode             = $CheckPolicy.Mode
        LabelAppliqué    = $CheckPolicy.ApplySensitivityLabel
        EmplacementCible = ($CheckPolicy.ExchangeLocation -join ", ")
        DistribStatus    = $CheckPolicy.DistributionStatus
    } | Format-List
} else {
    Write-Host "-> ATTENTION : policy non trouvée lors de la vérification." -ForegroundColor Red
}

if ($CheckRule) {
    Write-Host "-> Règle confirmée :" -ForegroundColor Green
    [PSCustomObject]@{
        Nom              = $CheckRule.Name
        PolicyParente    = $CheckRule.ParentPolicyName
        Workload         = $CheckRule.Workload
        SeuilOccurrences = 2
        Désactivée       = $CheckRule.Disabled
    } | Format-List
} else {
    Write-Host "-> ATTENTION : règle non trouvée lors de la vérification." -ForegroundColor Red
}

# ========================================================================================
# RÉSUMÉ
# ========================================================================================
Write-Host "=== RÉSUMÉ ===" -ForegroundColor Magenta
[PSCustomObject]@{
    PolicyCréée        = $PolicyName
    RègleCréée         = $RuleName
    Mode               = "TestWithoutNotifications (scan silencieux — aucun label appliqué réellement)"
    LabelCible         = $TargetLabel
    SITSurveillé       = "$TargetSIT (MinCount = 2)"
    Workload           = "Exchange (toutes les mailboxes)"
    SimulationDémarrée = "Oui — détections visibles dans Activity Explorer sous quelques heures"
    PourActiverEnProd  = "Set-AutoSensitivityLabelPolicy -Identity '$PolicyName' -Mode Enable"
    PourEtendreASPO    = "Set-AutoSensitivityLabelPolicy -Identity '$PolicyName' -AddSharePointLocation 'All'"
    PourEtendreAODB    = "Set-AutoSensitivityLabelPolicy -Identity '$PolicyName' -AddOneDriveLocation 'All'"
    DistribStatus      = if ($CheckPolicy) { $CheckPolicy.DistributionStatus } else { "Non vérifié" }
} | Format-List

Write-Host "Info : DistributionStatus 'Pending' est normal à la création." -ForegroundColor Yellow
Write-Host "Le scan Exchange effectif démarre après propagation complète.`n" -ForegroundColor Yellow

# ========================================================================================
# NETTOYAGE MÉMOIRE
# ========================================================================================
Remove-Variable TargetLabel, LabelCheck, TargetSIT, SITCheck,
                BasePolicyName, PolicyName, Counter, RuleName,
                NewPolicy, NewRule, CheckPolicy, CheckRule `
                -ErrorAction SilentlyContinue

# ========================================================================================
# FERMETURE — RESET DE SESSION TOTAL
# ========================================================================================
Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
Get-PSSession | Remove-PSSession
Write-Host "Sessions fermées proprement." -ForegroundColor Magenta
