# ========================================================================================
# Exercice 3a : Purview — Message Encryption — Vérification de l'état IRM sur le tenant
# ========================================================================================
# Concept : Avant de créer des Transport Rules avec chiffrement OME, il faut s'assurer
# qu'Azure RMS (Rights Management Service) est actif sur le tenant.
#
# Ce que fait ce script :
#   1. Reset total de session
#   2. Vérifie la configuration IRM globale du tenant
#   3. Liste les templates RMS disponibles (built-in + custom si AME configuré)
#   4. Teste la connectivité RMS end-to-end (Test-IRMConfiguration)
#   5. Ferme proprement toutes les sessions
#
# Terminologie :
#   IRM (Information Rights Management) = nom Exchange du service de protection RMS.
#   C'est le même moteur que Purview Information Protection, vu depuis Exchange.
#   RMS = Azure Rights Management Service — moteur de chiffrement sous-jacent.
#   OME = Office Message Encryption — couche applicative Exchange au-dessus de RMS.
#
# Sans RMS actif : les templates de chiffrement (Encrypt-Only, Do Not Forward) ne sont
# pas disponibles, et les Transport Rules avec action OME échouent silencieusement.
#
# DÉCOUVERTE TECHNIQUE : IRM est une fonctionnalité Exchange, pas Security & Compliance.
# On utilise Connect-ExchangeOnline (pas Connect-IPPSSession).
# Connect-ExchangeOnline n'est pas affecté par le problème WAM qui nécessite
# $env:MSAL_ENABLE_WAM = "0" sur Connect-IPPSSession — pas de workaround requis ici.
#
# Module requis : ExchangeOnlineManagement
# Connexion     : Connect-ExchangeOnline
# ========================================================================================

# --- OUVERTURE — RESET DE SESSION TOTAL ---
# REX : des sessions Exchange Online résiduelles peuvent provoquer des erreurs
# silencieuses sur Get-IRMConfiguration si le token est expiré ou si la session
# est dans un état incohérent. On purge avant de commencer.
# -ShowBanner:$false supprime le bandeau de connexion Exchange pour un output plus lisible.
Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
Connect-ExchangeOnline -UserPrincipalName GeptorAdmin@0n4mg.onmicrosoft.com -ShowBanner:$false

# ========================================================================================
# ÉTAPE 1 : Configuration IRM globale du tenant
# ========================================================================================
Write-Host "1. Configuration IRM du tenant..." -ForegroundColor Cyan

# Get-IRMConfiguration retourne l'état global du service RMS vu depuis Exchange.
#
# Propriétés clés à vérifier avant tout usage OME :
#
#   AzureRMSLicensingEnabled      : $true = RMS actif, le moteur peut chiffrer.
#                                   Si $false : aucun template disponible, toutes les
#                                   Transport Rules OME échoueront silencieusement.
#
#   InternalLicensingEnabled      : $true = chiffrement applicable aux mails internes
#                                   (expéditeur et destinataire dans le même tenant).
#
#   ExternalLicensingEnabled      : $true = chiffrement applicable aux mails externes
#                                   (destinataire hors tenant — partenaire, client).
#
#   TransportDecryptionSetting    : "Mandatory" = Exchange déchiffre automatiquement
#                                   les mails chiffrés entrants pour permettre au moteur
#                                   DLP et aux Transport Rules de scanner le contenu.
#                                   Sans ce réglage, un mail chiffré passe en aveugle
#                                   devant les règles de conformité.
#
#   SimplifiedClientAccessEnabled : $true = portail OME web activé.
#                                   Les destinataires externes sans Outlook peuvent lire
#                                   les mails chiffrés via navigateur (portal.office.com/EncryptedMail).
$IRMConfig = Get-IRMConfiguration
$IRMConfig | Format-List

# Vérification bloquante : si AzureRMSLicensingEnabled est $false,
# les exercices 3b et 3c (Transport Rules OME) ne fonctionneront pas.
if (-not $IRMConfig.AzureRMSLicensingEnabled) {
    Write-Host "-> ATTENTION : AzureRMSLicensingEnabled = False." -ForegroundColor Red
    Write-Host "   Le service RMS n'est pas actif sur ce tenant." -ForegroundColor Red
    Write-Host "   Activer via : Set-IRMConfiguration -AzureRMSLicensingEnabled `$true" -ForegroundColor Yellow
} else {
    Write-Host "-> OK : Azure RMS actif sur le tenant.`n" -ForegroundColor Green
}

# ========================================================================================
# ÉTAPE 2 : Templates RMS disponibles
# ========================================================================================
Write-Host "2. Templates RMS disponibles..." -ForegroundColor Cyan

# Get-RMSTemplate liste les templates de protection disponibles sur le tenant.
#
# DÉCOUVERTE TECHNIQUE : les noms des templates built-in varient selon la langue
# du tenant. Sur un tenant en français, on trouve "Chiffrer" et "Ne pas transférer"
# au lieu de "Encrypt-Only" et "Do Not Forward". Les GUIDs restent stables.
# Pour les Transport Rules, toujours cibler par nom tel qu'il apparaît ici.
#
# Templates built-in sur un tenant E3/E5 standard :
#
#   "Encrypt-Only" / "Chiffrer" :
#     Chiffrement seul — le destinataire peut transférer, copier, imprimer.
#     Protection minimale, utile pour la confidentialité en transit.
#     La protection ne suit pas le mail si transféré hors périmètre.
#
#   "Do Not Forward" / "Ne pas transférer" :
#     Chiffrement + restrictions — le destinataire ne peut pas transférer,
#     copier ni imprimer. La protection suit le mail où qu'il aille.
#     Posture standard pour les données sensibles vers l'extérieur.
#
# Si AME (Advanced Message Encryption) est configuré, des templates de branding custom
# apparaissent ici en plus (logo, couleurs, message d'accueil personnalisé du portail OME).
$Templates = Get-RMSTemplate | Select-Object Name, Description, Guid

if (-not $Templates) {
    Write-Host "-> ATTENTION : aucun template RMS retourné." -ForegroundColor Yellow
    Write-Host "   Vérifier que AzureRMSLicensingEnabled = True (étape 1).`n" -ForegroundColor Yellow
} else {
    Write-Host "-> Templates disponibles :`n" -ForegroundColor Green
    $Templates | Format-Table -AutoSize
}

# ========================================================================================
# ÉTAPE 3 : Test de connectivité RMS end-to-end
# ========================================================================================
Write-Host "3. Test de connectivité RMS (Test-IRMConfiguration)..." -ForegroundColor Cyan

# Test-IRMConfiguration envoie une requête de test au service RMS Azure et vérifie
# que Exchange peut obtenir une licence de chiffrement depuis le moteur RMS.
# C'est le test end-to-end : si ce test passe, les Transport Rules OME fonctionneront.
#
# -Sender obligatoire : le test simule un envoi depuis cette mailbox.
# Exchange a besoin d'un contexte expéditeur pour requêter une licence RMS.
#
# Résultat attendu dans la sortie : "OVERALL RESULT: PASS"
# Si "FAIL" : vérifier AzureRMSLicensingEnabled et la connectivité vers *.aadrm.com.
try {
    $TestResult = Test-IRMConfiguration -Sender GeptorAdmin@0n4mg.onmicrosoft.com -ErrorAction Stop
    $TestResult | Format-List

    if ($TestResult.Results -match "PASS") {
        Write-Host "-> Test IRM : PASS — le service RMS répond correctement.`n" -ForegroundColor Green
    } else {
        Write-Host "-> Test IRM : résultat à vérifier dans le détail ci-dessus.`n" -ForegroundColor Yellow
    }
}
catch {
    Write-Host "-> Échec du test IRM : $_`n" -ForegroundColor Red
}

# ========================================================================================
# RÉSUMÉ
# ========================================================================================
Write-Host "=== RÉSUMÉ ===" -ForegroundColor Magenta
[PSCustomObject]@{
    AzureRMSActif         = $IRMConfig.AzureRMSLicensingEnabled
    ChiffrementInterne    = $IRMConfig.InternalLicensingEnabled
    ChiffrementExterne    = $IRMConfig.ExternalLicensingEnabled
    DéchiffrementTransport = $IRMConfig.TransportDecryptionSetting
    PortailOMEWeb         = $IRMConfig.SimplifiedClientAccessEnabled
    NombreTemplates       = ($Templates | Measure-Object).Count
    TestRMS               = if ($TestResult.Results -match "PASS") { "PASS" } else { "À vérifier" }
} | Format-List

# ========================================================================================
# NETTOYAGE MÉMOIRE
# ========================================================================================
Remove-Variable IRMConfig, Templates, TestResult -ErrorAction SilentlyContinue

# ========================================================================================
# FERMETURE — RESET DE SESSION TOTAL
# ========================================================================================
Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
Write-Host "Session Exchange Online fermée proprement." -ForegroundColor Magenta
