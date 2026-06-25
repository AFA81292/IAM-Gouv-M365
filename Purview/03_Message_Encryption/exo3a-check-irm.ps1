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
#   5. Affiche un résumé chiffré
#   6. Exporte les trois jeux de données en CSV horodatés
#   7. Ferme proprement toutes les sessions
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
# Note : ce script est en lecture seule — aucune modification du tenant.
#
# Fichiers CSV générés :
#   IRM_Configuration_YYYYMMDD_HHmmss.csv
#   IRM_Templates_YYYYMMDD_HHmmss.csv
#   IRM_TestResultat_YYYYMMDD_HHmmss.csv
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
#
# Note : Test-IRMConfiguration retourne un objet narratif non tabulaire.
# On l'aplatit en colonnes exploitables pour le CSV (voir export ci-dessous).
$TestResult    = $null
$TestResultat  = "Non exécuté"
$TestErreur    = $null

try {
    $TestResult = Test-IRMConfiguration -Sender GeptorAdmin@0n4mg.onmicrosoft.com -ErrorAction Stop
    $TestResult | Format-List

    if ($TestResult.Results -match "PASS") {
        $TestResultat = "PASS"
        Write-Host "-> Test IRM : PASS — le service RMS répond correctement.`n" -ForegroundColor Green
    } else {
        $TestResultat = "FAIL"
        Write-Host "-> Test IRM : résultat à vérifier dans le détail ci-dessus.`n" -ForegroundColor Yellow
    }
}
catch {
    $TestResultat = "ERREUR"
    $TestErreur   = $_.Exception.Message
    Write-Host "-> Échec du test IRM : $TestErreur`n" -ForegroundColor Red
}

# ========================================================================================
# RÉSUMÉ
# ========================================================================================
Write-Host "=== RÉSUMÉ ===" -ForegroundColor Magenta
[PSCustomObject]@{
    AzureRMSActif          = $IRMConfig.AzureRMSLicensingEnabled
    ChiffrementInterne     = $IRMConfig.InternalLicensingEnabled
    ChiffrementExterne     = $IRMConfig.ExternalLicensingEnabled
    DéchiffrementTransport = $IRMConfig.TransportDecryptionSetting
    PortailOMEWeb          = $IRMConfig.SimplifiedClientAccessEnabled
    NombreTemplates        = ($Templates | Measure-Object).Count
    TestRMS                = $TestResultat
} | Format-List

# ========================================================================================
# EXPORT CSV
# ========================================================================================
Write-Host "Export CSV en cours..." -ForegroundColor Cyan

# EN LABO / Local :
$ExportPath = "D:\Documents\ScriptsPowerShell\Exports\"
# EN PRODUCTION :
# $ExportPath = "$PSScriptRoot\Exports\"

New-Item -ItemType Directory -Force -Path $ExportPath | Out-Null
$Timestamp = Get-Date -Format "yyyyMMdd_HHmmss"

# --- CSV 1 : Configuration IRM ---
# Colonnes exportées : les 5 propriétés clés de gouvernance OME.
# Get-IRMConfiguration retourne un objet singleton (une seule ligne) —
# ce CSV sert de snapshot de référence, horodaté, pour comparer d'un audit à l'autre.
# Colonnes disponibles non exportées :
#   LicensingLocation        : URL du service RMS Azure (diagnostic réseau)
#                              appeler via $IRMConfig.LicensingLocation
#   JournalReportDecryptionEnabled : déchiffrement des rapports de journalisation
#                              appeler via $IRMConfig.JournalReportDecryptionEnabled
#   SearchEnabled            : indexation des mails chiffrés par la recherche Exchange
#                              appeler via $IRMConfig.SearchEnabled
[PSCustomObject]@{
    AzureRMSLicensingEnabled      = $IRMConfig.AzureRMSLicensingEnabled
    InternalLicensingEnabled      = $IRMConfig.InternalLicensingEnabled
    ExternalLicensingEnabled      = $IRMConfig.ExternalLicensingEnabled
    TransportDecryptionSetting    = $IRMConfig.TransportDecryptionSetting
    SimplifiedClientAccessEnabled = $IRMConfig.SimplifiedClientAccessEnabled
} | Export-Csv `
    -Path "$ExportPath\IRM_Configuration_$Timestamp.csv" `
    -Encoding UTF8 -NoTypeInformation
Write-Host "-> Configuration IRM : 1 ligne — IRM_Configuration_$Timestamp.csv" -ForegroundColor Green

# --- CSV 2 : Templates RMS ---
# Colonnes exportées : Name, Description, Guid
# Guid est la colonne de référence stable à utiliser dans les Transport Rules OME,
# indépendamment de la langue du tenant (les noms varient, pas les GUIDs).
# Colonnes disponibles non exportées :
#   Type        : "Archived" (désactivé) ou "Distributed" (actif)
#                 appeler via $_.Type — utile pour filtrer les templates désactivés
#   IssuerUrl   : URL du tenant RMS émetteur — appeler via $_.IssuerUrl
if ($Templates) {
    $Templates | Export-Csv `
        -Path "$ExportPath\IRM_Templates_$Timestamp.csv" `
        -Encoding UTF8 -NoTypeInformation
    Write-Host "-> Templates RMS : $(($Templates | Measure-Object).Count) ligne(s) — IRM_Templates_$Timestamp.csv" -ForegroundColor Green
} else {
    Write-Host "-> Templates RMS : aucun template trouvé — pas d'export." -ForegroundColor Yellow
}

# --- CSV 3 : Résultat du test RMS ---
# Test-IRMConfiguration retourne un objet narratif (Results = bloc texte multi-lignes).
# On l'aplatit en colonnes exploitables : résultat global + erreur éventuelle.
# Ce CSV est utile pour tracer l'historique des tests (un snapshot par run).
# Colonnes disponibles non exportées :
#   $TestResult.Results (brut) : le bloc texte complet du test — lisible mais non structuré.
#   Pour l'inclure : @{N="ResultsBruts"; E={ $TestResult.Results }}
#   Utile pour le diagnostic détaillé, mais alourdit le CSV.
[PSCustomObject]@{
    Timestamp   = $Timestamp
    Expéditeur  = "GeptorAdmin@0n4mg.onmicrosoft.com"
    Résultat    = $TestResultat
    Erreur      = if ($TestErreur) { $TestErreur } else { "" }
} | Export-Csv `
    -Path "$ExportPath\IRM_TestResultat_$Timestamp.csv" `
    -Encoding UTF8 -NoTypeInformation
Write-Host "-> Test RMS : 1 ligne — IRM_TestResultat_$Timestamp.csv" -ForegroundColor Green

Write-Host "-> Export terminé dans : $ExportPath`n" -ForegroundColor Green

# ========================================================================================
# NETTOYAGE MÉMOIRE
# ========================================================================================
Remove-Variable IRMConfig, Templates, TestResult, TestResultat, TestErreur,
                ExportPath, Timestamp `
                -ErrorAction SilentlyContinue

# ========================================================================================
# FERMETURE — RESET DE SESSION TOTAL
# ========================================================================================
Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
Write-Host "Session Exchange Online fermée proprement." -ForegroundColor Magenta
