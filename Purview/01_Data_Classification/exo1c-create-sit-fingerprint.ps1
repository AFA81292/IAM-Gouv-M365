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
# Cas d'usage réel :
#   - Détecter des formulaires RH confidentiels qui circulent par mail ou SPO
#   - Détecter des contrats types même remplis avec des données différentes
#   - Complément au regex : le regex détecte un contenu, le fingerprint détecte une forme
#
# Différence clé vs 1b :
#   1b (regex)        → détecte "GCORP-12345" où qu'il apparaisse
#   1c (fingerprint)  → détecte "ce document ressemble à notre formulaire RH"
#
# Limitation importante :
#   Le fingerprinting fonctionne sur les fichiers texte et Office (docx, xlsx, txt...).
#   Il ne fonctionne PAS sur les PDF scannés (images) ni les fichiers binaires purs.
#
# Module requis : ExchangeOnlineManagement
# Connexion : Connect-IPPSSession
# ========================================================================================

# --- OUVERTURE ---
Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
Connect-IPPSSession -UserPrincipalName GeptorAdmin@0n4mg.onmicrosoft.com -ShowBanner:$false

# --- ÉTAPE 1 : Création du document template en mémoire ---
Write-Host "1. Création du document template RH fictif..." -ForegroundColor Cyan

# Le template est un document texte représentant un formulaire RH vide.
# C'est ce document que Purview va "empreinter".
# En production, ce serait un vrai formulaire Word ou PDF texte.
# Ici on génère le contenu directement en mémoire — pas besoin de fichier sur disque.
#
# IMPORTANT : le contenu doit avoir suffisamment de structure textuelle pour que
# Purview puisse en extraire une empreinte exploitable. Un document trop court
# ou trop générique donnera une empreinte de mauvaise qualité.
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

Write-Host "-> Template RH construit en mémoire." -ForegroundColor Green

# --- ÉTAPE 2 : Conversion du template en bytes ---
# New-DlpFingerprint attend le contenu du fichier sous forme de tableau de bytes.
# On encode en UTF-8 sans BOM — même logique que l'exo 1b.
Write-Host "`n2. Encodage du template..." -ForegroundColor Cyan

$Utf8NoBom       = [System.Text.UTF8Encoding]::new($false)
$TemplateBytes   = $Utf8NoBom.GetBytes($TemplateContent)

Write-Host "-> Template encodé : $($TemplateBytes.Length) bytes." -ForegroundColor Green

# --- ÉTAPE 3 : Génération de l'empreinte ---
# New-DlpFingerprint génère l'empreinte du document MAIS ne la sauvegarde pas encore.
# Elle retourne un objet empreinte qu'on stocke en variable — à passer ensuite
# à New-DlpSensitiveInformationType qui, lui, crée le vrai SIT dans Purview.
# C'est un pipeline en deux temps : générer l'empreinte → créer le SIT avec cette empreinte.
Write-Host "`n3. Génération de l'empreinte documentaire..." -ForegroundColor Cyan

try {
    $Fingerprint = New-DlpFingerprint `
        -FileData $TemplateBytes `
        -Description "Empreinte formulaire demande accès privilégié Cerberus Corp" `
        -ErrorAction Stop

    Write-Host "-> Empreinte générée." -ForegroundColor Green
}
catch {
    Write-Host "-> Échec génération empreinte : $_" -ForegroundColor Red
    return
}

# --- ÉTAPE 4 : Création du SIT basé sur l'empreinte ---
# New-DlpSensitiveInformationType crée le SIT visible dans Purview.
# On lui passe l'empreinte générée à l'étape 3 via -Fingerprints.
# ThresholdConfig définit le seuil de similarité requis pour déclencher une détection :
#   - Count          : nombre minimum de correspondances structurelles requises
#   - ConfidenceLevel: niveau de confiance associé (75 = medium, 85 = high)
Write-Host "`n4. Création du SIT basé sur l'empreinte..." -ForegroundColor Cyan

$SITName        = "Cerberus Corp - Formulaire Accès Privilégié"
$SITDescription = "Détecte les formulaires de demande d'accès privilégié Cerberus Corp"

try {
    New-DlpSensitiveInformationType `
        -Name        $SITName `
        -Description $SITDescription `
        -Fingerprints $Fingerprint `
        -ErrorAction Stop

    Write-Host "-> SIT fingerprint créé avec succès." -ForegroundColor Green
}
catch {
    Write-Host "-> Échec création SIT : $_" -ForegroundColor Red
    return
}

# --- ÉTAPE 5 : Vérification ---
Write-Host "`n5. Vérification (propagation ~30s)..." -ForegroundColor Cyan
Start-Sleep -Seconds 30

$NewSIT = Get-DlpSensitiveInformationType | Where-Object { $_.Name -eq $SITName }

if ($NewSIT) {
    Write-Host "-> SIT fingerprint visible dans Purview :" -ForegroundColor Green
    [PSCustomObject]@{
        Nom                   = $NewSIT.Name
        Editeur               = $NewSIT.Publisher
        ConfidenceRecommandee = $NewSIT.RecommendedConfidence
        OccurrencesMin        = $NewSIT.MinCount
        OccurrencesMax        = $NewSIT.MaxCount
    } | Format-List
} else {
    Write-Host "-> SIT pas encore visible — réplication en cours." -ForegroundColor Yellow
    Write-Host "-> Vérifie dans Purview portal > Data Classification > Sensitive info types." -ForegroundColor Yellow
}

# --- NETTOYAGE MÉMOIRE ---
Remove-Variable TemplateContent, Utf8NoBom, TemplateBytes, Fingerprint, `
                SITName, SITDescription, NewSIT -ErrorAction SilentlyContinue

# --- FERMETURE ---
Disconnect-ExchangeOnline -Confirm:$false
Write-Host "`nSession fermée. Mémoire locale nettoyée." -ForegroundColor Magenta
