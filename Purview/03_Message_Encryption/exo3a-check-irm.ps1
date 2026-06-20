# ========================================================================================
# Exercice 3a : Message Encryption — Vérification de l'état IRM sur le tenant
# ========================================================================================
# Concept : Avant de créer des Transport Rules avec chiffrement OME, il faut s'assurer
# qu'Azure RMS (Rights Management Service) est actif sur le tenant.
#
# IRM = Information Rights Management — c'est le nom Exchange du service de protection
# RMS. C'est le même moteur que Purview Information Protection, vu depuis Exchange.
#
# Sans RMS actif, les templates de chiffrement (Encrypt-Only, Do Not Forward) ne sont
# pas disponibles, et les Transport Rules avec action OME échouent silencieusement.
#
# Ce que fait ce script :
#   1. Vérifie la configuration IRM globale du tenant (AzureRMSLicensingEnabled, etc.)
#   2. Liste les templates RMS disponibles (built-in + custom si AME configuré)
#   3. Teste que le service RMS répond correctement (Test-IRMConfiguration)
#
# Prérequis : connexion Exchange Online — IRM est une fonctionnalité Exchange,
# pas Security & Compliance. On utilise Connect-ExchangeOnline, pas Connect-IPPSSession.
#
# Module requis : ExchangeOnlineManagement
# Connexion : Connect-ExchangeOnline
# ========================================================================================

# --- OUVERTURE ---
# Pas de workaround MSAL_ENABLE_WAM ici — Connect-ExchangeOnline n'est pas affecté
# par le même problème WAM que Connect-IPPSSession.
Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
Connect-ExchangeOnline -UserPrincipalName GeptorAdmin@0n4mg.onmicrosoft.com -ShowBanner:$false

# --- ÉTAPE 1 : Configuration IRM globale ---
Write-Host "1. Configuration IRM du tenant..." -ForegroundColor Cyan

# Get-IRMConfiguration retourne l'état global du service RMS vu depuis Exchange.
# Propriétés clés à vérifier :
#
#   AzureRMSLicensingEnabled  : $true = RMS actif, le moteur peut chiffrer
#   InternalLicensingEnabled  : $true = chiffrement applicable aux mails internes
#   ExternalLicensingEnabled  : $true = chiffrement applicable aux mails externes
#   TransportDecryptionSetting: "Mandatory" = Exchange déchiffre pour scanner le contenu
#                               (nécessaire pour que les règles DLP voient le contenu chiffré)
#   SimplifiedClientAccessEnabled : $true = portail OME web activé pour les destinataires
#                                   externes sans client Outlook (ils lisent via navigateur)
$IRMConfig = Get-IRMConfiguration

# On affiche tout — c'est un exo de découverte, pas de filtrage
$IRMConfig | Format-List

# Vérification critique : si AzureRMSLicensingEnabled est $false, les exos 3b et 3c
# ne fonctionneront pas. On sort un avertissement explicite.
if (-not $IRMConfig.AzureRMSLicensingEnabled) {
    Write-Host "-> ATTENTION : AzureRMSLicensingEnabled = False." -ForegroundColor Red
    Write-Host "   Le service RMS n'est pas actif. Activer via :" -ForegroundColor Red
    Write-Host "   Set-IRMConfiguration -AzureRMSLicensingEnabled `$true" -ForegroundColor Yellow
} else {
    Write-Host "-> OK : Azure RMS actif sur le tenant.`n" -ForegroundColor Green
}

# --- ÉTAPE 2 : Templates RMS disponibles ---
Write-Host "2. Templates RMS disponibles..." -ForegroundColor Cyan

# Get-RMSTemplate liste les templates de protection disponibles.
# Sur un tenant E3/E5 standard, on trouve toujours au minimum :
#
#   "Encrypt-Only"       : chiffrement seul — le destinataire peut transférer, copier, imprimer.
#                          Protection minimale, utile pour la confidentialité en transit.
#
#   "Do Not Forward"     : chiffrement + restriction — le destinataire ne peut pas transférer,
#                          copier ni imprimer. La protection suit le mail où qu'il aille.
#
# Si AME (Advanced Message Encryption) est configuré, des templates de branding custom
# apparaissent ici en plus (logo, couleurs, message d'accueil personnalisé).
$Templates = Get-RMSTemplate | Select-Object Name, Description, Guid

if (-not $Templates) {
    Write-Host "-> ATTENTION : aucun template RMS retourné." -ForegroundColor Yellow
    Write-Host "   Vérifier que AzureRMSLicensingEnabled = True (étape 1).`n" -ForegroundColor Yellow
} else {
    Write-Host "-> Templates disponibles :`n" -ForegroundColor Green
    $Templates | Format-Table -AutoSize
}

# --- ÉTAPE 3 : Test de connectivité RMS ---
Write-Host "3. Test de connectivité RMS (Test-IRMConfiguration)..." -ForegroundColor Cyan

# Test-IRMConfiguration envoie une requête de test au service RMS Azure et vérifie
# que Exchange peut obtenir une licence de chiffrement.
# C'est le test end-to-end : si ça passe ici, les Transport Rules OME fonctionneront.
#
# Le paramètre -Sender est obligatoire — le test simule un envoi depuis cette mailbox.
# Résultat attendu : "OVERALL RESULT: PASS" dans la sortie.
try {
    $TestResult = Test-IRMConfiguration -Sender GeptorAdmin@0n4mg.onmicrosoft.com -ErrorAction Stop
    $TestResult | Format-List

    # Le résultat contient une propriété Results avec le détail de chaque étape du test
    # On cherche si globalement c'est un succès
    if ($TestResult.Results -match "PASS") {
        Write-Host "-> Test IRM : PASS — le service RMS répond correctement.`n" -ForegroundColor Green
    } else {
        Write-Host "-> Test IRM : résultat à vérifier dans le détail ci-dessus.`n" -ForegroundColor Yellow
    }
}
catch {
    Write-Host "-> Échec du test IRM : $_`n" -ForegroundColor Red
}

# --- RÉSUMÉ ---
Write-Host "=== RÉSUMÉ ===" -ForegroundColor Magenta
[PSCustomObject]@{
    AzureRMSActif          = $IRMConfig.AzureRMSLicensingEnabled
    ChiffrementInterne     = $IRMConfig.InternalLicensingEnabled
    ChiffrementExterne     = $IRMConfig.ExternalLicensingEnabled
    PortailOMEWeb          = $IRMConfig.SimplifiedClientAccessEnabled
    NombreTemplates        = ($Templates | Measure-Object).Count
} | Format-List

# --- NETTOYAGE MÉMOIRE ---
Remove-Variable IRMConfig, Templates, TestResult -ErrorAction SilentlyContinue

# --- FERMETURE ---
Disconnect-ExchangeOnline -Confirm:$false
Write-Host "`nSession Exchange Online fermée." -ForegroundColor Magenta
