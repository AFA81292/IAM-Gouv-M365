# ========================================================================================
# Exercice 2b : Sensitivity Labels — Chiffrement admin-defined sur un sublabel
# ========================================================================================
# Concept : Le sublabel "NormandySR2 - Interne" a été créé en 2a sans chiffrement. On lui
# ajoute la couche de protection RMS via Set-Label.
#
# Chiffrement "admin-defined" vs "user-defined" :
#   - Admin-defined (ce script) : l'admin fixe les permissions exactes.
#   - User-defined              : l'utilisateur choisit les destinataires à l'usage.
#
# Permissions définies ici :
#   - Co-Owner (contrôle total) : Shepard
#   - Co-Author (lecture + modification) : Liara, Garrus
#
# Module requis : ExchangeOnlineManagement
# Connexion : Connect-IPPSSession
# ========================================================================================

# --- OUVERTURE ---
Get-PSSession | Remove-PSSession
Connect-IPPSSession -UserPrincipalName GeptorAdmin@0n4mg.onmicrosoft.com -ShowBanner:$false

# --- ÉTAPE 0 : Vérification préalable que le sublabel cible existe ---
# Évite un Set-Label dans le vide si 2a n'a pas (encore) été exécuté avec succès.
$SubLabelName = "NormandySR2 - Interne"
$TargetExists = Get-Label -Identity $SubLabelName -ErrorAction SilentlyContinue

if (-not $TargetExists) {
    Write-Host "-> ÉCHEC : '$SubLabelName' introuvable. Exécuter l'exo 2a au préalable." -ForegroundColor Red
    Get-PSSession | Remove-PSSession
    return
}
Write-Host "Sublabel cible confirmé présent — poursuite du script.`n" -ForegroundColor Green

# --- ÉTAPE 1 : Définition des permissions ---
Write-Host "1. Définition des permissions..." -ForegroundColor Cyan

$CoOwners  = @("shepard@0n4mg.onmicrosoft.com")
$CoAuthors = @("liara@0n4mg.onmicrosoft.com", "garrus@0n4mg.onmicrosoft.com")

# --- ÉTAPE 2 : Application du chiffrement admin-defined ---
Write-Host "2. Application du chiffrement..." -ForegroundColor Cyan

# DÉCOUVERTE TECHNIQUE : EncryptionRightsDefinitions n'accepte PAS un tableau
# PowerShell (List<string>) malgré ce qu'on pourrait attendre. Le paramètre est
# de type custom EncryptionRightsDefinitionsParameter et n'accepte qu'UNE SEULE
# chaîne au format : "identite1:droit1,droit2;identite2:droit3,droit4"
# Construire le tableau puis le -join ";" résout l'erreur de transformation
# d'argument observée avec un tableau brut.
#
# Autre piège : "OWNER" est le seul mot-clé valide pour un contrôle total
# (le portail Purview affiche "Co-Owner"/"Owner" selon la version, mais la
# valeur PowerShell sous-jacente est toujours OWNER — "CO-OWNER" lève une
# erreur de droit invalide une fois le problème de type résolu).
$RightsEntries = @()
foreach ($Owner in $CoOwners) {
    $RightsEntries += "${Owner}:OWNER"
}
foreach ($Author in $CoAuthors) {
    $RightsEntries += "${Author}:VIEW,EDIT,EXTRACT,REPLY,REPLYALL,FORWARD"
}

# Conversion en chaîne unique semicolon-separated — c'est LE point critique
$RightsDefinitionsString = $RightsEntries -join ";"
Write-Host "-> Chaîne construite : $RightsDefinitionsString" -ForegroundColor DarkGray

try {
    Set-Label -Identity $SubLabelName `
        -EncryptionEnabled $true `
        -EncryptionProtectionType "Template" `
        -EncryptionRightsDefinitions $RightsDefinitionsString `
        -EncryptionContentExpiredOnDateInDaysOrNever "Never" `
        -EncryptionOfflineAccessDays 30 `
        -ErrorAction Stop

    Write-Host "-> Chiffrement appliqué.`n" -ForegroundColor Green
}
catch {
    Write-Host "-> Échec application chiffrement : $_" -ForegroundColor Red
    return
}

# --- ÉTAPE 3 : Vérification ---
Write-Host "3. Vérification (propagation ~30s)..." -ForegroundColor Cyan
Start-Sleep -Seconds 30

$CheckLabel = Get-Label -Identity $SubLabelName -IncludeDetailedLabelActions

if (-not $CheckLabel -or -not $CheckLabel.EncryptionEnabled) {
    Write-Host "-> ATTENTION : chiffrement non confirmé après vérification." -ForegroundColor Yellow
} else {
    Write-Host "-> Sublabel confirmé chiffré :" -ForegroundColor Green
    [PSCustomObject]@{
        Nom                = $CheckLabel.DisplayName
        ChiffrementActif   = [bool]$CheckLabel.EncryptionEnabled
        TypeProtection     = $CheckLabel.EncryptionProtectionType
        OfflineAccessJours = $CheckLabel.EncryptionOfflineAccessDays
    } | Format-List
}

# --- NETTOYAGE MÉMOIRE ---
Remove-Variable SubLabelName, TargetExists, CoOwners, CoAuthors, RightsEntries, RightsDefinitionsString, `
                Owner, Author, CheckLabel -ErrorAction SilentlyContinue

# --- FERMETURE ---
Get-PSSession | Remove-PSSession
Write-Host "`nSession fermée." -ForegroundColor Magenta
