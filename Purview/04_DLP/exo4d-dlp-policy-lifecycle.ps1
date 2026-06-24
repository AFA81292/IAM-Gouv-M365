# ========================================================================================
# Exercice 4d : Cycle de vie d'une DLP policy — TestWithNotifications → Enable → Test
# ========================================================================================
# Concept : une DLP policy n'est jamais activée directement en prod. Le cycle standard est :
#   TestWithNotifications → Enable → retour Test si besoin de réajuster
#   (faux positifs, règle trop large, périmètre à affiner).
#
# Set-DlpCompliancePolicy -Mode pilote ce cycle sans recréer la policy ni perdre
# l'historique de matches — c'est la commande clé de cet exercice.
#
# Delta pédagogique vs 4a/4b :
#   4a → création en mode Test (observation seule)
#   4b → création en mode Enable (blocage actif)
#   4d → démontre le cycle complet de bascule entre les modes sur une même policy
#        Script autoporté : crée sa propre policy + règle pour ne pas dépendre
#        de l'état laissé par les exercices précédents.
#
# Miroir Entra : même logique de bascule progressive que l'exo 5d côté
# Conditional Access (Report-Only → Enabled → Report-Only).
#
# Les trois modes DLP :
#   TestWithNotifications → détecte, notifie, logge — ne bloque pas
#                           Mode de démarrage obligatoire en prod avant tout Enable
#   Enable                → blocage actif — les actions définies dans les règles s'appliquent
#   TestWithoutNotifications → détecte et logge uniquement, sans notifier l'utilisateur
#                              (utilisé pour des tests silencieux sans impact UX)
#
# Ce que fait ce script :
#   1. Reset total de session
#   2. Recherche un nom de policy disponible (auto-incrément)
#   3. Crée la policy + règle en mode TestWithNotifications
#   4. Vérifie l'état initial
#   5. Bascule vers Enable — vérifie
#   6. Retour vers TestWithNotifications (simulation faux positif) — vérifie
#   7. Affiche un résumé du cycle parcouru
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
# Ordre : Disconnect-ExchangeOnline → Remove-PSSession → workaround WAM → reconnexion.
# Note : Connect-IPPSSession ne supporte pas -ShowBanner:$false — bandeau normal.
Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
Get-PSSession | Remove-PSSession
$env:MSAL_ENABLE_WAM = "0"
Connect-IPPSSession -UserPrincipalName GeptorAdmin@0n4mg.onmicrosoft.com

# ========================================================================================
# ÉTAPE 1 : Recherche d'un nom disponible (auto-incrément)
# ========================================================================================
Write-Host "1. Recherche d'un nom disponible..." -ForegroundColor Cyan

# Thème Mass Effect : Cerberus teste puis active une politique de confinement.
# La règle n'est pas incrémentée — si la policy n'existe pas, la règle non plus.
# Les règles DLP sont liées à leur policy parente : elles n'existent pas sans elle.
$BasePolicyName = "DLP-Cerberus-LifecycleDemo"
$PolicyName     = $BasePolicyName
$Counter        = 2
while (Get-DlpCompliancePolicy -Identity $PolicyName -ErrorAction SilentlyContinue) {
    Write-Host "   '$PolicyName' déjà pris — test avec suffixe -v$Counter..." -ForegroundColor Yellow
    $PolicyName = "$BasePolicyName-v$Counter"
    $Counter++
}

$RuleName = "RULE-Cerberus-LifecycleDemo"
Write-Host "-> Nom retenu pour la policy : '$PolicyName'" -ForegroundColor Green
Write-Host "-> Nom retenu pour la règle  : '$RuleName'`n" -ForegroundColor Green

# ========================================================================================
# ÉTAPE 2 : Création de la policy en mode TestWithNotifications
# ========================================================================================
Write-Host "2. Création de la policy + règle en mode TestWithNotifications..." -ForegroundColor Cyan

# On démarre TOUJOURS en TestWithNotifications, jamais directement en Enable.
# C'est précisément le comportement qu'on démontre ici — le cycle commence ici.
#
# Périmètre SharePoint + OneDrive uniquement (pas Exchange) :
# Suffisant pour démontrer le cycle de vie sans multiplier les workloads.
#
# Note sur la règle : -BlockAccess $true est défini dans la règle, mais en mode
# TestWithNotifications, ce paramètre est IGNORÉ — aucun blocage réel ne se produit.
# C'est toute la logique du mode Test : les actions sont définies mais non exécutées.
# Elles s'activeront automatiquement quand la policy passera en mode Enable (étape 4).
try {
    $NewPolicy = New-DlpCompliancePolicy `
        -Name               $PolicyName `
        -SharePointLocation "All" `
        -OneDriveLocation   "All" `
        -Mode               "TestWithNotifications" `
        -Comment            "Exo 4d — Démo cycle de vie. Détecte Credit Card Number." `
        -ErrorAction Stop

    New-DlpComplianceRule `
        -Name                                $RuleName `
        -Policy                              $PolicyName `
        -ContentContainsSensitiveInformation @{ Name = "Credit Card Number"; minCount = "1" } `
        -BlockAccess                         $true `
        -NotifyUser                          "LastModifier" `
        -ErrorAction Stop | Out-Null

    Write-Host "-> Policy '$PolicyName' créée." -ForegroundColor Green
    Write-Host "-> Règle  '$RuleName' créée.`n" -ForegroundColor Green
}
catch {
    Write-Host "-> Échec création : $_" -ForegroundColor Red
    Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
    Get-PSSession | Remove-PSSession
    return
}

# ========================================================================================
# ÉTAPE 3 : Vérification de l'état initial (Test)
# ========================================================================================
Write-Host "3. Vérification de l'état initial..." -ForegroundColor Cyan

# Sleep 30s : la propagation d'un changement de Mode côté backend Purview n'est pas
# instantanée. Lire trop tôt peut renvoyer l'état précédent et simuler un faux échec
# de transition. 30s = marge réaliste pour la propagation API.
Start-Sleep -Seconds 30

$Check = Get-DlpCompliancePolicy -Identity $PolicyName -ErrorAction SilentlyContinue
Write-Host "-> État actuel : $($Check.Mode)`n" -ForegroundColor Cyan

# ========================================================================================
# ÉTAPE 4 : Transition TestWithNotifications → Enable
# ========================================================================================
Write-Host "4. Transition vers Enable (activation du blocage réel)..." -ForegroundColor Cyan

# Set-DlpCompliancePolicy -Mode : c'est LA commande clé de cet exercice.
# Elle bascule le mode sans recréer la policy, sans perdre l'historique de matches,
# sans modifier les règles. C'est l'outil de pilotage du cycle de vie DLP.
#
# Après cette transition :
#   - -BlockAccess $true sur la règle devient effectif
#   - Tout partage de fichier contenant un numéro CB sera réellement bloqué
#   - Les notifications utilisateur s'envoient pour de vrai
# C'est la transition qu'on ferait après avoir validé en Test qu'il n'y a pas
# de faux positifs massifs sur le périmètre réel.
Set-DlpCompliancePolicy -Identity $PolicyName -Mode "Enable" -Confirm:$false -ErrorAction Stop

Start-Sleep -Seconds 30
$Check = Get-DlpCompliancePolicy -Identity $PolicyName -ErrorAction SilentlyContinue
Write-Host "-> État actuel : $($Check.Mode)`n" -ForegroundColor Green

# ========================================================================================
# ÉTAPE 5 : Transition Enable → retour TestWithNotifications
# ========================================================================================
Write-Host "5. Retour vers TestWithNotifications (simulation faux positif)..." -ForegroundColor Cyan

# Scénario réel : un faux positif remonte (ex. un cas légitime bloqué).
# L'admin repasse en Test le temps d'ajuster la règle — sans supprimer ni recréer
# la policy, et sans perdre les matches déjà loggés dans l'audit Purview.
# C'est l'avantage clé de Set-DlpCompliancePolicy vs suppression/recréation.
Set-DlpCompliancePolicy -Identity $PolicyName -Mode "TestWithNotifications" -Confirm:$false -ErrorAction Stop

Start-Sleep -Seconds 30
$Check = Get-DlpCompliancePolicy -Identity $PolicyName -ErrorAction SilentlyContinue
Write-Host "-> État actuel : $($Check.Mode)`n" -ForegroundColor Green

# ========================================================================================
# RÉSUMÉ
# ========================================================================================
Write-Host "=== RÉSUMÉ ===" -ForegroundColor Magenta
[PSCustomObject]@{
    PolicyCréée   = $PolicyName
    RègleCréée    = $RuleName
    CycleParcouru = "TestWithNotifications → Enable → TestWithNotifications"
    ÉtatFinal     = $Check.Mode
    Workloads     = "SharePoint, OneDrive"
    SITSurveillé  = "Credit Card Number (1+ occurrence)"
} | Format-List

# Rappel nettoyage manuel si souhaité — la policy reste sur le tenant après le script.
# Elle peut servir de base pour l'exo 4e (audit de précédence des policies DLP).
Write-Host "Nettoyage optionnel (si policy non réutilisée) :" -ForegroundColor Yellow
Write-Host "Remove-DlpComplianceRule   -Identity '$RuleName'   -Confirm:`$false" -ForegroundColor Yellow
Write-Host "Remove-DlpCompliancePolicy -Identity '$PolicyName' -Confirm:`$false`n" -ForegroundColor Yellow

# ========================================================================================
# NETTOYAGE MÉMOIRE
# ========================================================================================
Remove-Variable BasePolicyName, PolicyName, RuleName, Counter, NewPolicy, Check `
                -ErrorAction SilentlyContinue

# ========================================================================================
# FERMETURE — RESET DE SESSION TOTAL
# ========================================================================================
Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
Get-PSSession | Remove-PSSession
Write-Host "Sessions fermées proprement." -ForegroundColor Magenta
