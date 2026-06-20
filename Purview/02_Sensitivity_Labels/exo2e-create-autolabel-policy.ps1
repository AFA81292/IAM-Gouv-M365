# ========================================================================================
# Exercice 2e : Sensitivity Labels — Politique d'auto-labeling côté service (Exchange)
# ========================================================================================
# Concept : Jusqu'ici, l'application d'un label dépendait d'un humain (l'utilisateur
# choisit le label dans Outlook/Word) ou d'une policy de publication qui rend le label
# disponible mais n'agit pas toute seule. L'auto-labeling "côté service" (service-side)
# inverse la logique : c'est Purview lui-même qui scanne le contenu EN ARRIÈRE-PLAN,
# détecte un Sensitive Information Type (SIT), et applique un label automatiquement —
# sans aucune action de l'utilisateur, et même sur des emails déjà envoyés/reçus.
#
# Différence avec l'auto-labeling "client-side" (Word/Excel/Outlook) :
#   - Client-side : agit pendant que l'utilisateur édite le document, suggère ou applique
#     le label localement, nécessite le client Office.
#   - Service-side (notre cas) : agit côté serveur Exchange/SharePoint/OneDrive, scanne
#     le contenu déjà stocké ou en transit, fonctionne même sans client Office.
#
# Pourquoi un objet "policy" ET un objet "rule" séparés ?
#
#   Contrairement à une DLP policy classique où New-DlpCompliancePolicy et
#   New-DlpComplianceRule sont quasi toujours créés en binôme immédiat, ici la séparation
#   est plus marquée conceptuellement :
#
#   New-AutoSensitivityLabelPolicy  → le CONTENEUR : quel label appliquer, sur quels
#                                      emplacements (Exchange/SharePoint/OneDrive),
#                                      dans quel mode (Test, TestWithNotifications, Enable).
#                                      Une policy SANS règle ne fait rien — elle ne sait
#                                      pas encore QUOI détecter.
#
#   New-AutoSensitivityLabelRule    → la CONDITION : quel SIT chercher, avec quel seuil
#                                      de confiance, quel nombre minimum d'occurrences.
#                                      Une règle est toujours rattachée à une policy
#                                      existante via -Policy.
#
#   On crée donc la policy d'abord (vide de logique), puis on lui attache sa règle.
#
# Mode TestWithoutNotifications — et pourquoi pas TestWithNotifications malgré la doc :
#
#   On ne bascule JAMAIS une auto-labeling policy en Enable sans être passé par une
#   phase de simulation. Trois modes existent en théorie :
#     - TestWithoutNotifications : simule, log les matches dans Activity Explorer,
#                                   AUCUNE notification, AUCUN label appliqué. Mode audit pur.
#     - TestWithNotifications    : simule + notifie les utilisateurs de ce qui SERAIT fait.
#     - Enable                   : applique réellement le label.
#
#   PIÈGE DOCUMENTAIRE CONFIRMÉ EN TEST : Microsoft Learn liste "TestWithNotifications"
#   comme valeur valide pour New-AutoSensitivityLabelPolicy. EN PRATIQUE, le cmdlet la
#   rejette à la création avec ModeNotSupportedByMipCmdletException. Et la voie de
#   contournement "créer en Test puis Set-AutoSensitivityLabelPolicy -Mode
#   TestWithNotifications" ne fonctionne pas non plus : Set-AutoSensitivityLabelPolicy
#   documente lui-même cette valeur comme "Not supported" sur ce cmdlet précis.
#   Conclusion : TestWithNotifications est, à ce jour, une valeur fantôme côté
#   PowerShell pour l'auto-labeling — accessible uniquement via le portail Purview
#   (toggle GUI). On script donc en TestWithoutNotifications, qui est le seul mode
#   de simulation réellement créable par cmdlet.
#
#   On démarre donc en TestWithoutNotifications (audit silencieux, observable
#   uniquement via Activity Explorer) — cohérent avec un cycle de vie réel où on
#   valide d'abord sans notifier personne, avant d'envisager un Enable.
#
# Seuil de détection — MinCount = 2 :
#
#   Le SIT "Cerberus Corp - Numéro de Badge Interne" créé en 1b a deux niveaux de
#   confiance (85 = regex + keyword corroborant, 75 = regex seul). On exige ici un
#   MINIMUM DE 2 OCCURRENCES du SIT dans le contenu pour déclencher la règle — pas 1.
#   Logique : un seul numéro de badge isolé dans un email peut être une mention anodine
#   ("voir avec le détenteur du badge GCORP-12345"). Deux occurrences ou plus dans le
#   même message suggèrent une vraie liste/export de données — plus représentatif d'un
#   cas réel où on évite de déclencher sur un simple faux positif isolé.
#
# Emplacement ciblé : Exchange uniquement.
#
#   L'énoncé de l'exercice est scopé "détection du SIT custom... côté service (Exchange)".
#   On cible donc -ExchangeLocation uniquement, pas SharePoint/OneDrive — cohérent avec
#   l'exo 3 (Message Encryption) qui est également centré Exchange/mail flow.
#
# Module requis : ExchangeOnlineManagement
# Connexion : Connect-IPPSSession
# ========================================================================================

# --- OUVERTURE ---
$env:MSAL_ENABLE_WAM = "0"
Get-PSSession | Remove-PSSession
Connect-IPPSSession -UserPrincipalName GeptorAdmin@0n4mg.onmicrosoft.com -ShowBanner:$false

# --- ÉTAPE 0 : Vérification des prérequis (label cible + SIT custom) ---
Write-Host "0. Vérification des prérequis..." -ForegroundColor Cyan

# Le label à appliquer doit déjà exister (créé en 2b avec chiffrement admin-defined).
$TargetLabel = "NormandySR2 - Interne"
$LabelCheck  = Get-Label -Identity $TargetLabel -ErrorAction SilentlyContinue

if (-not $LabelCheck) {
    Write-Host "   -> MANQUANT : label '$TargetLabel'. Exécuter 2a/2b au préalable." -ForegroundColor Red
    Get-PSSession | Remove-PSSession
    return
}
Write-Host "   -> OK : label '$TargetLabel' trouvé (Guid : $($LabelCheck.Guid))." -ForegroundColor Green

# Le SIT custom doit déjà exister (créé en 1b — Rule Package XML, pattern GCORP-XXXXX).
$TargetSIT = "Cerberus Corp - Numéro de Badge Interne"
$SITCheck  = Get-DlpSensitiveInformationType | Where-Object { $_.Name -eq $TargetSIT }

if (-not $SITCheck) {
    Write-Host "   -> MANQUANT : SIT '$TargetSIT'. Exécuter 1b au préalable." -ForegroundColor Red
    Get-PSSession | Remove-PSSession
    return
}
Write-Host "   -> OK : SIT '$TargetSIT' trouvé.`n" -ForegroundColor Green

# --- ÉTAPE 1 : Recherche d'un nom disponible pour la policy (auto-incrément) ---
Write-Host "1. Recherche d'un nom disponible pour la policy..." -ForegroundColor Cyan

$BasePolicyName = "AL-NormandySR2-BadgeGCORP"
$PolicyName     = $BasePolicyName
$Counter        = 2

# Get-AutoSensitivityLabelPolicy : équivalent de Get-LabelPolicy mais pour les policies
# d'AUTO-labeling. Ne pas confondre les deux familles de cmdlets — elles gèrent des
# objets distincts dans Purview malgré la ressemblance de nom.
while (Get-AutoSensitivityLabelPolicy -Identity $PolicyName -ErrorAction SilentlyContinue) {
    Write-Host "   '$PolicyName' déjà pris — test avec suffixe -v$Counter..." -ForegroundColor Yellow
    $PolicyName = "$BasePolicyName-v$Counter"
    $Counter++
}
Write-Host "-> Nom retenu : '$PolicyName'`n" -ForegroundColor Green

# --- ÉTAPE 2 : Création de la policy (le conteneur, sans logique de détection) ---
Write-Host "2. Création de la policy '$PolicyName'..." -ForegroundColor Cyan

try {
    $NewPolicy = New-AutoSensitivityLabelPolicy `
        -Name                $PolicyName `
        -ExchangeLocation    "All" `
        -ApplySensitivityLabel $TargetLabel `
        -Mode                "TestWithoutNotifications" `
        -Comment             "Auto-labeling Exchange : détecte le SIT Cerberus Corp Badge GCORP-XXXXX (1b), applique NormandySR2 - Interne (2b). Simulation silencieuse (TestWithNotifications non supporté par le cmdlet — cf. note en en-tête)." `
        -ErrorAction Stop

    Write-Host "-> Policy créée. Guid : $($NewPolicy.Guid)" -ForegroundColor Green
    Write-Host "-> Mode : TestWithoutNotifications (audit silencieux, aucun label réellement appliqué).`n" -ForegroundColor Green
}
catch {
    Write-Host "-> Échec création policy : $_" -ForegroundColor Red
    Get-PSSession | Remove-PSSession
    return
}

# --- ÉTAPE 3 : Création de la règle (la condition de détection, rattachée à la policy) ---
Write-Host "3. Création de la règle de détection..." -ForegroundColor Cyan

# ContentContainsSensitiveInformation attend un tableau de hashtables.
# name        : doit matcher EXACTEMENT le nom du SIT tel qu'enregistré dans Purview.
# mincount    : nombre minimum d'occurrences du SIT dans le contenu pour déclencher
#               la règle. On exige 2 (cf. justification en en-tête de script) — pas 1.
#
# Note : on n'ajoute pas de minconfidence ici. Le SIT custom créé en 1b a déjà deux
# niveaux de confiance intégrés dans son propre Rule Package XML (85 et 75). Ajouter
# un minconfidence ici filtrerait en plus PAR-DESSUS cette logique déjà existante.
# On laisse Purview évaluer avec sa logique native du SIT, et on ne contraint que
# le nombre d'occurrences.
#
# -Workload : paramètre OBLIGATOIRE, distinct de -ExchangeLocation vu sur la policy.
#   -ExchangeLocation (sur la policy)  : QUELS emplacements Exchange sont dans le
#                                        périmètre global de la policy (All, ou liste).
#   -Workload (sur la règle)           : SUR QUEL workload CETTE règle précise s'évalue
#                                        (Exchange, SharePoint, OneDrive...). Une policy
#                                        peut couvrir plusieurs emplacements et contenir
#                                        plusieurs règles ciblant des workloads différents.
#   Ici les deux convergent sur Exchange — cohérent avec le scope de l'exercice.
#
# IMPORTANT — collision de noms découverte en test :
#   Le nom d'une règle d'auto-labeling doit être unique sur TOUT le scénario
#   "AutoLabeling" du tenant, pas seulement au sein de sa policy. Si on relance le
#   script après un échec partiel (policy créée, règle en échec), le nom de policy
#   ré-incrémente (AL-...-v2) mais le nom de règle restait fixe avant cette correction
#   → collision avec une règle orpheline d'un essai précédent. On dérive donc le nom
#   de règle DIRECTEMENT du suffixe déjà calculé pour $PolicyName (en remplaçant le
#   préfixe de policy par un préfixe de règle), pour que policy et règle avancent
#   toujours ensemble et ne collisionnent jamais entre deux tentatives.
#
#   AUTRE PIÈGE DE PROPAGATION DÉCOUVERT EN TEST : Remove-AutoSensitivityLabelRule et
#   Remove-AutoSensitivityLabelPolicy ne suppriment pas instantanément l'objet — ils le
#   passent en état "PendingDeletion", qui peut durer de plusieurs dizaines de minutes
#   à plusieurs heures. Tant que cet état n'est pas finalisé, le NOM reste considéré
#   comme "pris" par le service, et une nouvelle création portant le même nom échoue
#   avec ComplianceRuleAlreadyExistsInScenarioException même si la policy/règle visible
#   dans le portail semble avoir disparu. D'où le préfixe de base volontairement changé
#   ici (BadgeGCORP plutôt que BadgeCerberus) après un essai précédent resté en
#   PendingDeletion — pas une erreur de script, un contournement délibéré de latence
#   backend Purview pour ne pas attendre la finalisation.
$RuleName = $PolicyName -replace [regex]::Escape($BasePolicyName), "Rule-DetectBadgeGCORP"

try {
    $NewRule = New-AutoSensitivityLabelRule `
        -Policy $PolicyName `
        -Name   $RuleName `
        -Workload "Exchange" `
        -ContentContainsSensitiveInformation @{
            Name     = $TargetSIT
            MinCount = "2"
        } `
        -ErrorAction Stop

    Write-Host "-> Règle créée : '$RuleName'." -ForegroundColor Green
    Write-Host "-> Condition : SIT '$TargetSIT', MinCount = 2, Workload = Exchange.`n" -ForegroundColor Green
}
catch {
    Write-Host "-> Échec création règle : $_" -ForegroundColor Red
    Write-Host "-> Nettoyage : suppression de la policy orpheline '$PolicyName'..." -ForegroundColor Yellow

    # Pas de SilentlyContinue ici à l'aveugle : on veut SAVOIR si la suppression
    # échoue, plutôt que de laisser un orphelin invisible sur le tenant (cf. incident
    # de test où deux policies + une règle orphelines se sont accumulées sans alerte
    # claire à cause d'un nettoyage silencieux en amont).
    try {
        Remove-AutoSensitivityLabelPolicy -Identity $PolicyName -Confirm:$false -ErrorAction Stop
        Write-Host "-> Policy orpheline '$PolicyName' supprimée avec succès.`n" -ForegroundColor Green
    }
    catch {
        Write-Host "-> ÉCHEC du nettoyage automatique : $_" -ForegroundColor Red
        Write-Host "-> ACTION MANUELLE REQUISE : vérifier et supprimer '$PolicyName' à la main avant de relancer." -ForegroundColor Red
    }

    Get-PSSession | Remove-PSSession
    return
}

# --- ÉTAPE 3 BIS : Démarrage explicite de la simulation ---
# Purview ne lance PAS automatiquement la simulation à la création de la policy/règle
# (cf. warning observé : "Any updates to auto labeling policy requires simulation to
# be restarted"). Sans cette étape, la policy existe en base mais ne scanne rien —
# Activity Explorer resterait vide indéfiniment. -StartSimulation $true force le
# (re)démarrage du moteur de simulation pour qu'il prenne en compte la règle qu'on
# vient d'attacher.
Write-Host "3 bis. Démarrage de la simulation..." -ForegroundColor Cyan

try {
    Set-AutoSensitivityLabelPolicy -Identity $PolicyName -StartSimulation $true -ErrorAction Stop
    Write-Host "-> Simulation démarrée.`n" -ForegroundColor Green
}
catch {
    Write-Host "-> Échec démarrage simulation : $_" -ForegroundColor Red
    Write-Host "-> La policy et la règle existent malgré tout — simulation à démarrer manuellement depuis le portail si besoin.`n" -ForegroundColor Yellow
}

# --- ÉTAPE 4 : Vérification ---
Write-Host "4. Vérification (propagation 30s)..." -ForegroundColor Cyan
Start-Sleep -Seconds 30

$CheckPolicy = Get-AutoSensitivityLabelPolicy -Identity $PolicyName -ErrorAction SilentlyContinue
$CheckRule   = Get-AutoSensitivityLabelRule -Identity $RuleName -ErrorAction SilentlyContinue

if (-not $CheckPolicy -or -not $CheckRule) {
    Write-Host "-> ATTENTION : policy ou règle introuvable après vérification." -ForegroundColor Yellow
}
else {
    Write-Host "-> Policy et règle confirmées :" -ForegroundColor Green

    [PSCustomObject]@{
        Policy            = $CheckPolicy.Name
        Mode              = $CheckPolicy.Mode
        LabelApplique     = $CheckPolicy.ApplySensitivityLabel
        EmplacementCible  = ($CheckPolicy.ExchangeLocation -join ", ")
        Regle             = $CheckRule.Name
        SITCible          = $TargetSIT
        SeuilOccurrences  = 2
    } | Format-List
}

# --- RAPPEL OPÉRATIONNEL ---
# En mode TestWithoutNotifications, RIEN n'est appliqué et AUCUNE notification n'est
# envoyée — c'est un audit pur, observable uniquement côté admin. Pour l'observer :
#   1. Envoyer un email de test contenant 2+ occurrences de "GCORP-12345" (ou autre
#      numéro au bon format) à un destinataire interne, avec un mot-clé corroborant
#      type "badge" pour viser la confiance haute (85).
#   2. Attendre la propagation (peut prendre jusqu'à 24h sur certains tenants, souvent
#      plus rapide en pratique sur un tenant dev).
#   3. Consulter Purview portal > Data Classification > Activity Explorer pour voir
#      les matches simulés, ou Purview portal > Information Protection > Auto-labeling
#      > la policy > onglet "Insights" pour le résumé de simulation.
#   4. Pour activer les notifications utilisateur sans encore appliquer le label,
#      c'est une bascule GUI-only (portail Purview > la policy > Edit) — le cmdlet
#      Set-AutoSensitivityLabelPolicy refuse explicitement cette valeur de Mode.
#   5. Une fois validé sans faux positif majeur, basculer en application réelle via :
#      Set-AutoSensitivityLabelPolicy -Identity $PolicyName -Mode Enable
Write-Host "`nRappel : policy en mode audit silencieux (TestWithoutNotifications). Voir Activity Explorer dans le portail Purview pour observer les détections." -ForegroundColor Magenta

# --- NETTOYAGE MÉMOIRE ---
Remove-Variable TargetLabel, LabelCheck, TargetSIT, SITCheck, BasePolicyName, PolicyName, `
                Counter, NewPolicy, RuleName, NewRule, CheckPolicy, CheckRule -ErrorAction SilentlyContinue

# --- FERMETURE ---
Get-PSSession | Remove-PSSession
Write-Host "`nSession fermée." -ForegroundColor Magenta
