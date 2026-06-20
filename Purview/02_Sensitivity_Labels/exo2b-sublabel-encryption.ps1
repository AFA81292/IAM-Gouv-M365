# ========================================================================================
# Exercice 2b : Sensitivity Labels — Chiffrement admin-defined sur un sublabel
# ========================================================================================
# Le sublabel "NormandySR2 - Interne" existe depuis 2a, mais sans protection. On lui
# ajoute le chiffrement RMS via Set-Label.
#
# Admin-defined vs user-defined : ici c'est nous (l'admin) qui fixons les permissions
# à l'avance. En user-defined, c'est l'utilisateur qui choisit les destinataires au
# moment d'appliquer le label.
#
# Permissions visées :
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

# Piège à connaître : on pourrait s'attendre à passer un tableau PowerShell à
# -EncryptionRightsDefinitions, mais il refuse — il veut UNE seule chaîne au format
# "identite1:droit1,droit2;identite2:droit3,droit4". D'où le tableau qu'on construit
# normalement plus bas, qu'on recolle ensuite avec -join ";" juste avant l'appel.
#
# Autre détail qui piège : le mot-clé valide côté PowerShell est "OWNER", pas
# "CO-OWNER" — le portail Purview affiche "Co-Owner" dans son interface, mais la
# valeur réellement attendue par la cmdlet est juste OWNER.
$RightsEntries = @()
foreach ($Owner in $CoOwners) {
    $RightsEntries += "${Owner}:OWNER"
}
foreach ($Author in $CoAuthors) {
    $RightsEntries += "${Author}:VIEW,EDIT,EXTRACT,REPLY,REPLYALL,FORWARD"
}

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
