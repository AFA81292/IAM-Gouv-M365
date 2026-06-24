# ========================================================================================
# Exercice 2b : Sensitivity Labels — Chiffrement admin-defined sur un sublabel
# ========================================================================================
# Concept : Le sublabel "NormandySR2 - Interne" créé en 2a existe mais sans protection.
# Ce script lui ajoute un chiffrement RMS (Azure Rights Management) via Set-Label.
#
# Admin-defined vs user-defined :
#   Admin-defined  = l'admin fixe les permissions à l'avance dans la définition du label.
#                    L'utilisateur applique le label — les droits sont déjà déterminés.
#                    C'est l'approche de cet exercice.
#   User-defined   = l'utilisateur choisit lui-même les destinataires et les droits
#                    au moment d'appliquer le label (ex : "Ne pas transférer").
#
# Permissions définies dans cet exercice :
#   Co-Owner (OWNER)   : Shepard — contrôle total, peut modifier les permissions RMS
#   Co-Author          : Liara, Garrus — lecture, modification, extraction, transfert
#
# Pièges documentés :
#   1. -EncryptionRightsDefinitions attend UNE chaîne unique, pas un tableau PS.
#      Format attendu : "user1@dom:DROIT1,DROIT2;user2@dom:DROIT3"
#      → Construction d'un tableau intermédiaire + -join ";" avant l'appel.
#   2. Le droit Co-Owner s'appelle "OWNER" côté cmdlet, pas "CO-OWNER".
#      Le portail Purview affiche "Co-Owner" — la cmdlet refuse cette valeur.
#   3. -ShowBanner:$false est invalide sur Connect-IPPSSession — bandeau normal attendu.
#
# Ce que fait ce script :
#   1. Reset total de session
#   2. Vérifie que le sublabel cible (créé en 2a) est bien présent
#   3. Construit la chaîne de droits RMS
#   4. Applique le chiffrement admin-defined via Set-Label
#   5. Vérifie l'application depuis la source de vérité
#   6. Ferme proprement toutes les sessions
#
# Prérequis : exo 2a exécuté — sublabel "NormandySR2 - Interne" doit exister
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
# ÉTAPE 1 : Vérification préalable — le sublabel cible doit exister
# ========================================================================================
Write-Host "1. Vérification du sublabel cible..." -ForegroundColor Cyan

# Ce script modifie un objet existant (Set-Label), pas un nouvel objet (New-Label).
# Si le sublabel n'existe pas (exo 2a non exécuté ou label supprimé), on arrête
# immédiatement — il n'y a rien à modifier.
$SubLabelName = "NormandySR2 - Interne"
$TargetExists = Get-Label -Identity $SubLabelName -ErrorAction SilentlyContinue

if (-not $TargetExists) {
    Write-Host "-> ÉCHEC : '$SubLabelName' introuvable." -ForegroundColor Red
    Write-Host "   Exécuter l'exo 2a au préalable pour créer le sublabel." -ForegroundColor Yellow
    Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
    Get-PSSession | Remove-PSSession
    return
}
Write-Host "-> Sublabel '$SubLabelName' confirmé présent — poursuite du script.`n" -ForegroundColor Green

# ========================================================================================
# ÉTAPE 2 : Construction de la chaîne de droits RMS
# ========================================================================================
Write-Host "2. Construction de la chaîne de droits RMS..." -ForegroundColor Cyan

# Définition des titulaires et de leurs droits respectifs.
# Ces variables sont des tableaux PS standards — ils seront retraités plus bas
# pour produire le format chaîne attendu par -EncryptionRightsDefinitions.
$CoOwners  = @("shepard@0n4mg.onmicrosoft.com")
$CoAuthors = @("liara@0n4mg.onmicrosoft.com", "garrus@0n4mg.onmicrosoft.com")

# Construction du tableau intermédiaire d'entrées de droits.
#
# FORMAT ATTENDU PAR LA CMDLET :
#   "identite1:DROIT1,DROIT2;identite2:DROIT3,DROIT4"
#   → Une seule chaîne, identités séparées par ";" et droits par ","
#   → Pas de tableau PowerShell — la cmdlet refusera avec une erreur de type.
#
# DROIT "OWNER" (Co-Owner) :
#   Mot-clé accepté par la cmdlet : "OWNER"
#   Affiché dans le portail Purview comme "Co-Owner" — ne pas se laisser piéger.
#   Donne le contrôle total, y compris la capacité à modifier les permissions RMS.
#
# DROITS Co-Author (droits explicitement listés) :
#   VIEW     : lecture du document
#   EDIT     : modification du contenu
#   EXTRACT  : copier/coller, impression
#   REPLY    : répondre à un email protégé
#   REPLYALL : répondre à tous sur un email protégé
#   FORWARD  : transférer un email protégé
#   Note : pas de PRINT séparé — EXTRACT couvre l'impression dans ce contexte RMS.
$RightsEntries = @()
foreach ($Owner in $CoOwners) {
    $RightsEntries += "${Owner}:OWNER"
}
foreach ($Author in $CoAuthors) {
    $RightsEntries += "${Author}:VIEW,EDIT,EXTRACT,REPLY,REPLYALL,FORWARD"
}

# Assemblage final en une seule chaîne avec ";" comme séparateur d'identités.
$RightsDefinitionsString = $RightsEntries -join ";"
Write-Host "-> Chaîne de droits construite :" -ForegroundColor Green
Write-Host "   $RightsDefinitionsString`n" -ForegroundColor DarkGray

# ========================================================================================
# ÉTAPE 3 : Application du chiffrement admin-defined via Set-Label
# ========================================================================================
Write-Host "3. Application du chiffrement sur '$SubLabelName'..." -ForegroundColor Cyan

# -EncryptionEnabled $true :
#   Active le chiffrement RMS sur ce label. Sans ce paramètre, les autres paramètres
#   de chiffrement sont ignorés.
#
# -EncryptionProtectionType "Template" :
#   Indique que les droits sont définis par une configuration admin (admin-defined).
#   L'alternative "UserDefined" permet à l'utilisateur de choisir les droits
#   au moment de l'application — hors périmètre de cet exercice.
#
# -EncryptionRightsDefinitions $RightsDefinitionsString :
#   La chaîne construite à l'étape 2 — format "user:DROITS;user:DROITS".
#
# -EncryptionContentExpiredOnDateInDaysOrNever "Never" :
#   Le contenu chiffré n'expire jamais. En production, une expiration est recommandée
#   pour les données sensibles (ex : "365" pour 1 an), forçant un rechiffrement.
#
# -EncryptionOfflineAccessDays 30 :
#   Nombre de jours pendant lesquels un utilisateur peut ouvrir le document
#   sans se reconnecter à Azure RMS pour vérifier ses droits.
#   0 = connexion RMS requise à chaque ouverture (strict, mais contraignant).
#   30 = équilibre entre sécurité et confort d'usage en production standard.
try {
    Set-Label `
        -Identity                                    $SubLabelName `
        -EncryptionEnabled                           $true `
        -EncryptionProtectionType                    "Template" `
        -EncryptionRightsDefinitions                 $RightsDefinitionsString `
        -EncryptionContentExpiredOnDateInDaysOrNever "Never" `
        -EncryptionOfflineAccessDays                 30 `
        -ErrorAction Stop

    Write-Host "-> Chiffrement appliqué sur '$SubLabelName'.`n" -ForegroundColor Green
}
catch {
    Write-Host "-> Échec de l'application du chiffrement : $_" -ForegroundColor Red
    Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
    Get-PSSession | Remove-PSSession
    return
}

# ========================================================================================
# ÉTAPE 4 : Vérification depuis la source de vérité
# ========================================================================================
Write-Host "4. Vérification depuis le backend Purview..." -ForegroundColor Cyan

# -IncludeDetailedLabelActions : paramètre requis pour exposer les propriétés
# de chiffrement (EncryptionEnabled, EncryptionProtectionType, etc.).
# Sans ce switch, Get-Label retourne l'objet label sans les détails de protection.
Start-Sleep -Seconds 30

$CheckLabel = Get-Label -Identity $SubLabelName -IncludeDetailedLabelActions -ErrorAction SilentlyContinue

if (-not $CheckLabel) {
    Write-Host "-> ATTENTION : label non trouvé lors de la vérification." -ForegroundColor Red
} elseif (-not $CheckLabel.EncryptionEnabled) {
    Write-Host "-> ATTENTION : chiffrement non confirmé après vérification." -ForegroundColor Yellow
    Write-Host "   Réplication possiblement encore en cours — revérifier dans quelques minutes." -ForegroundColor Yellow
} else {
    Write-Host "-> Chiffrement confirmé sur le sublabel :" -ForegroundColor Green
    [PSCustomObject]@{
        Nom                = $CheckLabel.DisplayName
        ChiffrementActif   = [bool]$CheckLabel.EncryptionEnabled
        TypeProtection     = $CheckLabel.EncryptionProtectionType
        OfflineAccessJours = $CheckLabel.EncryptionOfflineAccessDays
        Expiration         = "Never"
    } | Format-List
}

# ========================================================================================
# ÉTAPE 5 : Résumé
# ========================================================================================
Write-Host "=== RÉSUMÉ ===" -ForegroundColor Magenta
[PSCustomObject]@{
    SublabelModifié    = $SubLabelName
    ChiffrementRMS     = "Activé (admin-defined)"
    CoOwner            = ($CoOwners -join ", ")
    CoAuthors          = ($CoAuthors -join ", ")
    DroitsCoAuthor     = "VIEW, EDIT, EXTRACT, REPLY, REPLYALL, FORWARD"
    OfflineAccès       = "30 jours"
    Expiration         = "Never"
    PiègesCmdlet       = "OWNER (pas CO-OWNER) / chaîne unique avec ; comme séparateur"
    SuiteLogique       = "Exo 2c — publication du label via Label Policy"
} | Format-List

# ========================================================================================
# NETTOYAGE MÉMOIRE
# ========================================================================================
Remove-Variable SubLabelName, TargetExists, CoOwners, CoAuthors,
                RightsEntries, RightsDefinitionsString, Owner, Author,
                CheckLabel `
                -ErrorAction SilentlyContinue

# ========================================================================================
# FERMETURE — RESET DE SESSION TOTAL
# ========================================================================================
Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
Get-PSSession | Remove-PSSession
Write-Host "Sessions fermées proprement." -ForegroundColor Magenta
