# ========================================================================================
# Exercice 2b : Sensitivity Labels — Chiffrement admin-defined sur un sublabel
# ========================================================================================
# Concept : Le sublabel "NSR2 - Interne" a été créé en 2a sans chiffrement. On lui
# ajoute maintenant la couche de protection RMS via Set-Label — étape volontairement
# séparée de la création pour rester lisible (1 action = 1 étape de script).
#
# Chiffrement "admin-defined" vs "user-defined" :
#   - Admin-defined (ce script)  : l'admin fixe les permissions exactes. L'utilisateur
#     applique le label, les droits sont déjà figés.
#   - User-defined               : l'utilisateur choisit lui-même les destinataires
#     au moment d'appliquer le label.
#
# Permissions définies ici :
#   - Co-Owner (contrôle total) : Shepard
#   - Co-Author (lecture + modification, pas de réattribution de droits) : Liara, Garrus
#
# Cas d'usage réel :
#   - Documents internes sensibles où on veut garantir QUI peut les ouvrir,
#     indépendamment du canal de partage (email, SharePoint, clé USB...)
#
# Module requis : ExchangeOnlineManagement
# Connexion : Connect-IPPSSession
# ========================================================================================

# --- OUVERTURE ---
Get-PSSession | Remove-PSSession
Connect-IPPSSession -UserPrincipalName GeptorAdmin@0n4mg.onmicrosoft.com -ShowBanner:$false

# --- ÉTAPE 1 : Définition des variables ---
Write-Host "1. Définition des permissions..." -ForegroundColor Cyan

$SubLabelName = "NSR2 - Interne"
$CoOwners     = @("shepard@0n4mg.onmicrosoft.com")
$CoAuthors    = @("liara@0n4mg.onmicrosoft.com", "garrus@0n4mg.onmicrosoft.com")

Write-Host "-> Sublabel cible : $SubLabelName`n" -ForegroundColor Green

# --- ÉTAPE 2 : Application du chiffrement admin-defined ---
# -EncryptionProtectionType "Template" : chiffrement admin-defined (permissions fixes)
# -EncryptionRightsDefinitions : format "email:DROITS" séparés par virgule
Write-Host "2. Application du chiffrement..." -ForegroundColor Cyan

$RightsDefinitions = @()
foreach ($Owner in $CoOwners) {
    $RightsDefinitions += "${Owner}:CO-OWNER"
}
foreach ($Author in $CoAuthors) {
    $RightsDefinitions += "${Author}:VIEW,EDIT,EXTRACT,REPLY,REPLYALL,FORWARD"
}

try {
    Set-Label -Identity $SubLabelName `
        -EncryptionEnabled $true `
        -EncryptionProtectionType "Template" `
        -EncryptionRightsDefinitions $RightsDefinitions `
        -EncryptionContentExpiredOnDateInDaysOrNever "Never" `
        -EncryptionOfflineAccessDays 30 `
        -ErrorAction Stop

    Write-Host "-> Chiffrement appliqué." -ForegroundColor Green
    Write-Host "-> Co-Owners  : $($CoOwners -join ', ')" -ForegroundColor Green
    Write-Host "-> Co-Authors : $($CoAuthors -join ', ')`n" -ForegroundColor Green
}
catch {
    Write-Host "-> Échec application chiffrement : $_" -ForegroundColor Red
    return
}

# --- ÉTAPE 3 : Vérification ---
Write-Host "3. Vérification (propagation ~30s)..." -ForegroundColor Cyan
Start-Sleep -Seconds 30

$CheckLabel = Get-Label -Identity $SubLabelName -IncludeDetailedLabelActions

if ($CheckLabel) {
    Write-Host "-> Sublabel confirmé dans Purview :" -ForegroundColor Green
    [PSCustomObject]@{
        Nom                = $CheckLabel.DisplayName
        ParentId           = $CheckLabel.ParentId
        ChiffrementActif   = [bool]$CheckLabel.EncryptionEnabled
        TypeProtection     = $CheckLabel.EncryptionProtectionType
        OfflineAccessJours = $CheckLabel.EncryptionOfflineAccessDays
    } | Format-List
} else {
    Write-Host "-> Sublabel pas encore visible — réplication en cours." -ForegroundColor Yellow
}

# --- NETTOYAGE MÉMOIRE ---
Remove-Variable SubLabelName, CoOwners, CoAuthors, RightsDefinitions, `
                Owner, Author, CheckLabel -ErrorAction SilentlyContinue

# --- FERMETURE ---
Get-PSSession | Remove-PSSession
Write-Host "`nSession fermée." -ForegroundColor Magenta
