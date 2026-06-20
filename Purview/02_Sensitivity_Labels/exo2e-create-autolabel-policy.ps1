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
# Mode TestWithNotifications — pourquoi pas Enable direct :
#
#   On ne bascule JAMAIS une auto-labeling policy en Enable sans être passé par une
#   phase de simulation. TestWithNotifications est le choix réaliste en mission client :
#     - Test                    : simule, log les matches dans Activity Explorer,
#                                  AUCUNE notification, AUCUN label appliqué.
#     - TestWithNotifications   : simule + notifie les utilisateurs concernés par email
#                                  de ce qui SERAIT fait (transparence, prépare le terrain).
#                                  AUCUN label réellement appliqué.
#     - Enable                  : applique réellement le label. On n'y passe qu'après
#                                  avoir validé en Test/TestWithNotifications qu'il n'y a
#                                  pas de faux positifs en masse.
#
#   Ici on démarre directement en TestWithNotifications (on saute le Test silencieux)
#   car le volume sur un tenant de dev est nul — pas de risque de spam de notifications.
#   Sur un tenant de prod avec du volume réel, on commencerait par Test seul.
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

$BasePolicyName = "AL-NormandySR2-BadgeCerberus"
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
        -Mode                "TestWithNotifications" `
        -Comment             "Auto-labeling Exchange : détecte le SIT Cerberus Corp Badge (1b), applique NormandySR2 - Interne (2b). Simulation avec notifications." `
        -ErrorAction Stop

    Write-Host "-> Policy créée. Guid : $($NewPolicy.Guid)" -ForegroundColor Green
    Write-Host "-> Mode : TestWithNotifications (aucun label réellement appliqué pour l'instant).`n" -ForegroundColor Green
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
$RuleName = "Rule-DetectBadgeCerberus"

try {
    $NewRule = New-AutoSensitivityLabelRule `
        -Policy $PolicyName `
        -Name   $RuleName `
        -ContentContainsSensitiveInformation @{
            Name     = $TargetSIT
            MinCount = "2"
        } `
        -ErrorAction Stop

    Write-Host "-> Règle créée : '$RuleName'." -ForegroundColor Green
    Write-Host "-> Condition : SIT '$TargetSIT', MinCount = 2.`n" -ForegroundColor Green
}
catch {
    Write-Host "-> Échec création règle : $_" -ForegroundColor Red
    Write-Host "-> Nettoyage : suppression de la policy orpheline '$PolicyName'..." -ForegroundColor Yellow
    Remove-AutoSensitivityLabelPolicy -Identity $PolicyName -Confirm:$false -ErrorAction SilentlyContinue
    Get-PSSession | Remove-PSSession
    return
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
# En mode TestWithNotifications, RIEN n'est appliqué. Pour observer le comportement :
#   1. Envoyer un email de test contenant 2+ occurrences de "GCORP-12345" (ou autre
#      numéro au bon format) à un destinataire interne, avec un mot-clé corroborant
#      type "badge" pour viser la confiance haute (85).
#   2. Attendre la propagation (peut prendre jusqu'à 24h sur certains tenants, souvent
#      plus rapide en pratique sur un tenant dev).
#   3. Consulter Purview portal > Data Classification > Activity Explorer pour voir
#      les matches simulés, ou Purview portal > Information Protection > Auto-labeling
#      > la policy > onglet "Insights" pour le résumé de simulation.
#   4. Une fois validé sans faux positif majeur, basculer en Enable via :
#      Set-AutoSensitivityLabelPolicy -Identity $PolicyName -Mode Enable
Write-Host "`nRappel : policy en mode simulation. Voir Activity Explorer dans le portail Purview pour observer les détections." -ForegroundColor Magenta

# --- NETTOYAGE MÉMOIRE ---
Remove-Variable TargetLabel, LabelCheck, TargetSIT, SITCheck, BasePolicyName, PolicyName, `
                Counter, NewPolicy, RuleName, NewRule, CheckPolicy, CheckRule -ErrorAction SilentlyContinue

# --- FERMETURE ---
Get-PSSession | Remove-PSSession
Write-Host "`nSession fermée." -ForegroundColor Magenta
