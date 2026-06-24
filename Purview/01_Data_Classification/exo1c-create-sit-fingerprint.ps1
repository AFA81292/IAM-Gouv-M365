# ========================================================================================
# Exercice 1c : Data Classification — Création d'un SIT par Document Fingerprinting
# ========================================================================================
# Concept : Le Document Fingerprinting ne détecte pas un pattern de texte comme le regex.
# Il détecte la STRUCTURE d'un document.
#
# Fonctionnement :
#   1. On fournit un document template (formulaire vide, contrat type, fiche RH...)
#   2. Purview extrait une "empreinte" des zones de texte structurées du document
#   3. Cette empreinte devient un SIT — Purview détecte ensuite tout document
#      qui partage cette même structure, qu'il soit vide ou rempli
#
# Différence clé vs 1b :
#   1b (regex)        → détecte "GCORP-12345" où qu'il apparaisse dans n'importe quel fichier
#   1c (fingerprint)  → détecte "ce document ressemble structurellement à notre formulaire RH"
#
# Remarque sur l'auto-incrément :
#   Même logique que 1b : le SIT fingerprint est identifié en interne par un GUID
#   généré par Purview à la création. Sur un tenant de dev, on supprime l'ancien
#   avant de recréer. Pas d'auto-incrément nécessaire.
#
# Limitation importante :
#   Le fingerprinting fonctionne sur les fichiers texte et Office (docx, xlsx, txt...).
#   Il ne fonctionne PAS sur les PDF scannés (images) ni les fichiers binaires purs.
#   La qualité de l'empreinte dépend de la richesse structurelle du template :
#   un document trop court ou trop générique donnera une empreinte peu discriminante.
#
# Ce que fait ce script :
#   1. Reset total de session
#   2. Crée le document template RH fictif en mémoire
#   3. Encode le template en bytes UTF-8 sans BOM
#   4. Génère l'empreinte documentaire (sans la sauvegarder — objet intermédiaire)
#   5. Crée le SIT Purview en lui passant l'empreinte
#   6. Vérifie la création depuis la source de vérité
#   7. Ferme proprement toutes les sessions
#
# Cas d'usage réel :
#   - Détecter des formulaires RH confidentiels qui circulent par mail ou SPO
#   - Détecter des contrats types même remplis avec des données différentes
#   - Complément au regex : le regex détecte un contenu, le fingerprint détecte une forme
#
# Module requis : ExchangeOnlineManagement
# Connexion     : Connect-IPPSSession
# ========================================================================================

# --- OUVERTURE — RESET DE SESSION TOTAL ---
# REX : Get-PSSession | Remove-PSSession est préféré à Disconnect-ExchangeOnline -Confirm:$false
# car les versions récentes du module ExchangeOnlineManagement ignorent -Confirm:$false
# et affichent une confirmation interactive qui bloque le script.
# Get-PSSession récupère toutes les sessions PS actives (IPPS, ExchangeOnline, autres)
# et Remove-PSSession les ferme toutes proprement sans prompt.
Get-PSSession | Remove-PSSession
Connect-IPPSSession -UserPrincipalName GeptorAdmin@0n4mg.onmicrosoft.com -ShowBanner:$false

# ========================================================================================
# ÉTAPE 1 : Création du document template en mémoire
# ========================================================================================
Write-Host "1. Création du document template RH fictif..." -ForegroundColor Cyan

# Le template est un document texte représentant un formulaire RH vide.
# C'est ce document que Purview va "empreinter".
# En production, ce serait un vrai formulaire Word ou PDF texte récupéré depuis
# un SharePoint ou un répertoire réseau.
# Ici on génère le contenu directement en mémoire — pas besoin de fichier sur disque.
#
# Qualité de l'empreinte : plus le template contient de champs structurés distincts,
# meilleure sera la discrimination. Un formulaire avec 15 champs labellisés est
# bien meilleur qu'un document de 3 lignes génériques.
$TemplateContent = @"
CERBERUS CORP — FORMULAIRE DE DEMANDE D'ACCÈS PRIVILÉGIÉ

Date de la demande    :
Nom du demandeur      :
Prénom du demandeur   :
Numéro de badge       :
Département           :
Responsable hiérarchique :

Système cible         :
Niveau d'accès demandé :
Justification métier  :
Date de début d'accès :
Date de fin d'accès   :

Validation RH         :
Validation SSI        :
Validation DSI        :

Signature du demandeur :
Signature du responsable :
"@

Write-Host "-> Template RH construit en mémoire.`n" -ForegroundColor Green

# ========================================================================================
# ÉTAPE 2 : Encodage du template en bytes
# ========================================================================================
Write-Host "2. Encodage du template..." -ForegroundColor Cyan

# New-DlpFingerprint attend le contenu du fichier sous forme de tableau de bytes.
# On encode en UTF-8 sans BOM — même logique que l'exo 1b.
# UTF8Encoding::new($false) : $false = emitBOM:$false → pas de Byte Order Mark.
$Utf8NoBom     = [System.Text.UTF8Encoding]::new($false)
$TemplateBytes = $Utf8NoBom.GetBytes($TemplateContent)

Write-Host "-> Template encodé : $($TemplateBytes.Length) bytes.`n" -ForegroundColor Green

# ========================================================================================
# ÉTAPE 3 : Génération de l'empreinte documentaire
# ========================================================================================
Write-Host "3. Génération de l'empreinte documentaire..." -ForegroundColor Cyan

# New-DlpFingerprint génère l'empreinte du document MAIS ne la sauvegarde pas encore.
# Elle retourne un objet empreinte qu'on stocke en variable — à passer ensuite
# à New-DlpSensitiveInformationType qui, lui, crée le vrai SIT dans Purview.
#
# Pipeline en deux temps (obligatoire) :
#   New-DlpFingerprint → objet empreinte en mémoire (pas visible dans Purview)
#   New-DlpSensitiveInformationType → SIT créé dans Purview avec cette empreinte
#
# Il n'est pas possible de passer directement les bytes à New-DlpSensitiveInformationType.
# L'étape intermédiaire New-DlpFingerprint est imposée par l'API Purview.
try {
    $Fingerprint = New-DlpFingerprint `
        -FileData    $TemplateBytes `
        -Description "Empreinte formulaire demande accès privilégié Cerberus Corp" `
        -ErrorAction Stop

    Write-Host "-> Empreinte générée.`n" -ForegroundColor Green
}
catch {
    Write-Host "-> Échec de la génération de l'empreinte : $_" -ForegroundColor Red
    Get-PSSession | Remove-PSSession
    return
}

# ========================================================================================
# ÉTAPE 4 : Création du SIT basé sur l'empreinte
# ========================================================================================
Write-Host "4. Création du SIT basé sur l'empreinte..." -ForegroundColor Cyan

$SITName        = "Cerberus Corp - Formulaire Accès Privilégié"
$SITDescription = "Détecte les formulaires de demande d'accès privilégié Cerberus Corp"

# New-DlpSensitiveInformationType crée le SIT visible dans Purview.
# On lui passe l'empreinte générée à l'étape 3 via -Fingerprints.
#
# Comportement de détection :
#   Purview compare la structure de tout document scanné avec l'empreinte stockée.
#   Si la similarité structurelle dépasse le seuil interne, le SIT est déclenché.
#   Le niveau de confiance retourné correspond au degré de ressemblance avec le template.
try {
    New-DlpSensitiveInformationType `
        -Name         $SITName `
        -Description  $SITDescription `
        -Fingerprints $Fingerprint `
        -ErrorAction  Stop | Out-Null

    Write-Host "-> SIT fingerprint créé avec succès.`n" -ForegroundColor Green
}
catch {
    Write-Host "-> Échec de la création du SIT : $_" -ForegroundColor Red
    Get-PSSession | Remove-PSSession
    return
}

# ========================================================================================
# ÉTAPE 5 : Vérification depuis la source de vérité
# ========================================================================================
Write-Host "5. Vérification (propagation ~30s)..." -ForegroundColor Cyan

# REX : même latence que 1b — 30 secondes minimum pour que le SIT soit
# visible dans Get-DlpSensitiveInformationType après création.
Start-Sleep -Seconds 30

$NewSIT = Get-DlpSensitiveInformationType | Where-Object { $_.Name -eq $SITName }

if ($NewSIT) {
    Write-Host "-> SIT fingerprint visible dans Purview :" -ForegroundColor Green
    [PSCustomObject]@{
        Nom                   = $NewSIT.Name
        Editeur               = $NewSIT.Publisher
        ConfidenceRecommandée = $NewSIT.RecommendedConfidence
        OccurrencesMin        = $NewSIT.MinCount
        OccurrencesMax        = $NewSIT.MaxCount
    } | Format-List
} else {
    Write-Host "-> SIT pas encore visible — réplication encore en cours." -ForegroundColor Yellow
    Write-Host "   Vérifier dans : Purview portal > Data Classification > Sensitive info types." -ForegroundColor Yellow
}

# ========================================================================================
# RÉSUMÉ
# ========================================================================================
Write-Host "=== RÉSUMÉ ===" -ForegroundColor Magenta
[PSCustomObject]@{
    SITCréé           = $SITName
    TypeDétection     = "Document Fingerprinting (structure, pas contenu)"
    TemplateSoumis    = "Formulaire demande accès privilégié Cerberus Corp (texte en mémoire)"
    TailleTemplate    = "$($TemplateBytes.Length) bytes"
    Limitation        = "Ne fonctionne pas sur PDF scannés ni fichiers binaires purs"
    DifférenceVs1b    = "1b détecte GCORP-XXXXX partout — 1c détecte la structure du formulaire"
    ProchainePourSuiteExo = "Utiliser ce SIT comme condition dans une DLP policy (exo 4a/4b)"
} | Format-List

# ========================================================================================
# NETTOYAGE MÉMOIRE
# ========================================================================================
Remove-Variable TemplateContent, Utf8NoBom, TemplateBytes, Fingerprint, `
                SITName, SITDescription, NewSIT `
                -ErrorAction SilentlyContinue

# ========================================================================================
# FERMETURE — RESET DE SESSION TOTAL
# ========================================================================================
Get-PSSession | Remove-PSSession
Write-Host "Sessions fermées proprement." -ForegroundColor Magenta
