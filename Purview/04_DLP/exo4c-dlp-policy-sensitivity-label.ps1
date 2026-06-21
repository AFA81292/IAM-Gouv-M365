# ========================================================================================
# Exercice 4c : DLP — Policy basée sur un label de sensibilité (Sensitivity Label)
# ========================================================================================
# Concept : Les exos 4a et 4b ciblaient un SIT (pattern de données détecté à la volée).
# Cet exercice change de paradigme : la condition n'est plus "ce fichier CONTIENT
# un numéro de CB" mais "ce fichier EST LABELLISÉ Confidentiel".
#
# Pourquoi c'est différent et complémentaire :
#   - SIT (4a/4b) : détection automatique sur le contenu — fonctionne même sans label.
#     Mais un SIT peut rater du contenu non structuré, des images, des PDFs scannés.
#   - Label (4c) : la classification est posée par un humain ou une auto-label policy
#     (exo 2e). Elle est explicite, intentionnelle, et couvre tout le fichier
#     indépendamment de son contenu. Un fichier "Confidentiel" sans numéro de CB
#     est quand même protégé.
#
# Les deux mécanismes ensemble forment une défense en profondeur :
#   couche 1 — le label protège le fichier dès sa création/modification
#   couche 2 — la DLP label-based bloque le partage si le label est présent
#   couche 3 — la DLP SIT-based bloque si des données sensibles sont détectées,
#              même si le fichier n'a pas de label (oubli, document ancien, etc.)
#
# Condition utilisée : -ContentContainsSensitiveLabel
#   On cible le label group NormandySR2 - Confidentiel ET ses deux sublabels.
#   Si un fichier porte l'un de ces trois labels, le partage externe est bloqué.
#
# Ce que fait ce script :
#   1. Reset total de session
#   2. Récupère les GUIDs des labels cibles (on ne met jamais le nom en dur — le GUID
#      est la référence stable, le nom peut changer sans que le GUID change)
#   3. Recherche un nom disponible (auto-incrément)
#   4. Crée la DLP policy sur SharePoint + OneDrive (labels sur fichiers, pas Exchange)
#   5. Crée la règle avec condition label + blocage partage externe
#   6. Vérifie la création depuis la source de vérité
#   7. Ferme proprement toutes les sessions
#
# Pourquoi SharePoint + OneDrive uniquement (pas Exchange) :
#   Les sensitivity labels sur FICHIERS sont pertinents pour SPO/ODfB — c'est là
#   qu'on partage des fichiers labelisés. Pour Exchange, les labels s'appliquent
#   aux emails, et le mécanisme de protection est différent (chiffrement RMS, exo 3).
#   On pourrait ajouter Exchange, mais la condition "fichier labelisé" sur un email
#   s'applique aux pièces jointes — scénario moins direct pour un exo de démonstration.
#
# Prérequis :
#   - Labels créés en exo 2a/2b/2c :
#       NormandySR2 - Confidentiel  (label group / parent)
#       NormandySR2 - Interne       (sublabel)
#       NormandySR2 - Externe       (sublabel)
#   - Connexion IPPSSession active (labels ET DLP dans le même endpoint)
#
# Module requis : ExchangeOnlineManagement
# Connexion : Connect-IPPSSession
# Licence requise : Microsoft Purview DLP + Purview Information Protection (inclus E5)
# ========================================================================================

# --- OUVERTURE — RESET DE SESSION TOTAL ---
# REX : sessions fantômes = erreurs silencieuses ou authentifications croisées.
# On purge TOUT avant de commencer, sans exception.
Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
Get-PSSession | Remove-PSSession
$env:MSAL_ENABLE_WAM = "0"
Connect-IPPSSession -UserPrincipalName GeptorAdmin@0n4mg.onmicrosoft.com

# ========================================================================================
# ÉTAPE 1 : Récupération des GUIDs des labels cibles
# ========================================================================================
Write-Host "1. Récupération des GUIDs des labels NormandySR2..." -ForegroundColor Cyan

# On résout les GUIDs dynamiquement plutôt que de les fixer en dur dans le script.
# Raison : le GUID d'un label est stable (il ne change pas si on renomme le label),
# mais si on recrée le label depuis zéro, le GUID change. En résolvant au runtime,
# le script s'adapte à l'état réel du tenant sans modification manuelle.
#
# Get-Label retourne tous les labels du tenant (groups + sublabels).
# On filtre sur le DisplayName pour cibler les trois labels NormandySR2.
$LabelNames = @(
    "NormandySR2 - Confidentiel",
    "NormandySR2 - Interne",
    "NormandySR2 - Externe"
)

$LabelGuids = @()
foreach ($LabelName in $LabelNames) {
    $Label = Get-Label -Identity $LabelName -ErrorAction SilentlyContinue
    if ($Label) {
        $LabelGuids += $Label.Guid
        Write-Host "   OK : '$LabelName' — GUID : $($Label.Guid)" -ForegroundColor Gray
    } else {
        Write-Host "   MANQUANT : '$LabelName' introuvable sur le tenant." -ForegroundColor Yellow
        Write-Host "   Vérifier que les labels ont bien été créés (exo 2a/2b/2c)." -ForegroundColor Yellow
    }
}

# Guard clause : si aucun label trouvé, inutile de créer une règle sans condition
if ($LabelGuids.Count -eq 0) {
    Write-Host "-> Aucun label NormandySR2 trouvé. Arrêt du script." -ForegroundColor Red
    Write-Host "   Créer les labels via les exos 2a, 2b, 2c avant de relancer 4c." -ForegroundColor Red
    Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
    Get-PSSession | Remove-PSSession
    return
}

Write-Host "-> $($LabelGuids.Count) label(s) résolu(s).`n" -ForegroundColor Green

# ========================================================================================
# ÉTAPE 2 : Recherche d'un nom disponible (auto-incrément)
# ========================================================================================
Write-Host "2. Recherche d'un nom disponible..." -ForegroundColor Cyan

$BasePolicyName = "DLP-Normandy-LabelBlock"
$PolicyName     = $BasePolicyName
$Counter        = 2
while (Get-DlpCompliancePolicy -Identity $PolicyName -ErrorAction SilentlyContinue) {
    Write-Host "   '$PolicyName' déjà pris — test avec suffixe -v$Counter..." -ForegroundColor Yellow
    $PolicyName = "$BasePolicyName-v$Counter"
    $Counter++
}
Write-Host "-> Nom retenu pour la policy : '$PolicyName'" -ForegroundColor Green

$BaseRuleName = "RULE-Normandy-LabelBlock"
$RuleName     = $BaseRuleName
$Counter      = 2
while (Get-DlpComplianceRule -Identity $RuleName -ErrorAction SilentlyContinue) {
    Write-Host "   '$RuleName' déjà pris — test avec suffixe -v$Counter..." -ForegroundColor Yellow
    $RuleName = "$BaseRuleName-v$Counter"
    $Counter++
}
Write-Host "-> Nom retenu pour la règle : '$RuleName'`n" -ForegroundColor Green

# ========================================================================================
# ÉTAPE 3 : Création de la DLP policy
# ========================================================================================
Write-Host "3. Création de la DLP policy '$PolicyName'..." -ForegroundColor Cyan

# SharePoint + OneDrive uniquement — voir justification dans l'en-tête.
# Mode TestWithNotifications : on reste prudent sur une policy label-based.
# En production, une telle policy en mode Enable bloquerait immédiatement tous
# les partages de fichiers labelisés Confidentiel — à activer après validation.
try {
    $NewPolicy = New-DlpCompliancePolicy `
        -Name               $PolicyName `
        -SharePointLocation "All" `
        -OneDriveLocation   "All" `
        -Mode               "TestWithNotifications" `
        -Comment            "Exo 4c — DLP label-based. Bloque partage externe fichiers NormandySR2 - Confidentiel/Interne/Externe." `
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
# ÉTAPE 4 : Création de la règle avec condition label
# ========================================================================================
Write-Host "4. Création de la règle '$RuleName'..." -ForegroundColor Cyan

# -ContentContainsSensitiveLabel : condition de détection basée sur le label.
# On passe un tableau de GUIDs — la règle se déclenche si le fichier porte
# L'UN des labels listés (logique OR, pas AND).
#
# Pourquoi des GUIDs et pas des noms ?
# L'API DLP attend des GUIDs pour les labels, pas des DisplayNames.
# Passer un nom en clair génère une erreur de résolution côté backend.
# Les GUIDs ont été résolus dynamiquement à l'étape 1.
#
# -AccessScope "NotInOrganization" :
# La règle se déclenche uniquement si le fichier est partagé vers l'extérieur.
# Un fichier Confidentiel partagé en interne reste accessible — c'est la posture
# standard : on protège la frontière du tenant, pas la collaboration interne.
#
# -BlockAccess $true + -BlockAccessScope "PerUser" :
# Même logique que 4b — blocage ciblé sur l'utilisateur qui tente le partage externe,
# les autres collaborateurs internes conservent leur accès au fichier.
#
# -NotifyUser "LastModifier" :
# Notifie l'utilisateur qui a tenté le partage. Il reçoit un message expliquant
# que le fichier est classifié Confidentiel et que le partage externe est interdit.
# En mode TestWithNotifications, la notification est envoyée mais le partage n'est
# pas bloqué réellement — comportement de test.
try {
    $NewRule = New-DlpComplianceRule `
        -Name                          $RuleName `
        -Policy                        $PolicyName `
        -ContentContainsSensitiveLabel $LabelGuids `
        -AccessScope                   "NotInOrganization" `
        -BlockAccess                   $true `
        -BlockAccessScope              "PerUser" `
        -NotifyUser                    "LastModifier" `
        -GenerateIncidentReport        "SiteAdmin" `
        -IncidentReportContent         @("All") `
        -Comment                       "Exo 4c — Blocage partage externe fichiers labelisés NormandySR2. Notification LastModifier." `
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
# ÉTAPE 5 : Vérification depuis la source de vérité
# ========================================================================================
Write-Host "5. Vérification depuis le backend Purview..." -ForegroundColor Cyan
Start-Sleep -Seconds 3

$CheckPolicy = Get-DlpCompliancePolicy -Identity $PolicyName -ErrorAction SilentlyContinue
$CheckRule   = Get-DlpComplianceRule   -Policy   $PolicyName -ErrorAction SilentlyContinue

if ($CheckPolicy) {
    Write-Host "-> Policy confirmée :" -ForegroundColor Green
    [PSCustomObject]@{
        Nom           = $CheckPolicy.Name
        Mode          = $CheckPolicy.Mode
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
        BlocageActif    = $CheckRule.BlockAccess
        PortéeBlocage   = $CheckRule.BlockAccessScope
        NotifUser       = ($CheckRule.NotifyUser -join ", ")
        LabelsGUIDs     = ($LabelGuids -join ", ")
    } | Format-List
} else {
    Write-Host "-> ATTENTION : règle non trouvée lors de la vérification." -ForegroundColor Red
}

# ========================================================================================
# ÉTAPE 6 : Résumé
# ========================================================================================
Write-Host "=== RÉSUMÉ ===" -ForegroundColor Magenta

[PSCustomObject]@{
    PolicyCréée      = $PolicyName
    RègleCréée       = $RuleName
    Mode             = "TestWithNotifications"
    ConditionType    = "Sensitivity Label (pas SIT)"
    LabelsCouverts   = ($LabelNames -join " | ")
    Workloads        = "SharePoint, OneDrive (pas Exchange)"
    ActionBlocage    = "Oui — BlockAccess PerUser (actif en mode Enable)"
    RapportIncident  = "Oui (SiteAdmin)"
    NotifUtilisateur = "Oui (LastModifier)"
    DistribStatus    = if ($CheckPolicy) { $CheckPolicy.DistributionStatus } else { "Non vérifié" }
} | Format-List

Write-Host "Info : en mode TestWithNotifications, le blocage est simulé." -ForegroundColor Yellow
Write-Host "Passer en Enable via Set-DlpCompliancePolicy (cf. exo 4d).`n" -ForegroundColor Yellow

# ========================================================================================
# NETTOYAGE MÉMOIRE
# ========================================================================================
Remove-Variable LabelNames, LabelGuids, LabelName, Label,
                BasePolicyName, PolicyName, BaseRuleName, RuleName, Counter,
                NewPolicy, NewRule, CheckPolicy, CheckRule `
                -ErrorAction SilentlyContinue

# ========================================================================================
# FERMETURE — RESET DE SESSION TOTAL
# ========================================================================================
Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
Get-PSSession | Remove-PSSession
Write-Host "Sessions fermées proprement." -ForegroundColor Magenta
