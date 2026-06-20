# ========================================================================================
# Exercice 2b : Sensitivity Labels — Sublabel avec chiffrement admin-defined
# ========================================================================================
# Concept : Un sublabel hérite visuellement de son parent mais ajoute sa propre couche
# de protection — ici, du chiffrement RMS (Rights Management Services).
#
# Chiffrement "admin-defined" vs "user-defined" :
#   - Admin-defined (ce script)  : l'admin fixe les permissions exactes à la création
#     du label. L'utilisateur applique le label, les droits sont déjà figés.
#   - User-defined               : l'utilisateur choisit lui-même les destinataires
#     au moment d'appliquer le label (ex: "Chiffrer pour des personnes spécifiques").
#
# Permissions définies ici :
#   - Co-Owner (contrôle total) : les membres du groupe IAM admin du tenant
#   - Co-Author (lecture + modification, pas de réattribution de droits) : reste du tenant
#
# Cas d'usage réel :
#   - Documents internes sensibles où on veut garantir QUI peut les ouvrir,
#     indépendamment du canal de partage (email, SharePoint, clé USB...)
#   - Le chiffrement protège même si le fichier sort du périmètre M365
#
# Module requis : ExchangeOnlineManagement
# Connexion : Connect-IPPSSession
# ========================================================================================

# --- OUVERTURE ---
Get-PSSession | Remove-PSSession
Connect-IPPSSession -UserPrincipalName GeptorAdmin@0n4mg.onmicrosoft.com -ShowBanner:$false

# --- ÉTAPE 1 : Définition des variables ---
Write-Host "1. Définition du sublabel..." -ForegroundColor Cyan

$ParentLabelName = "Confidentiel"
$SubLabelName    = "Confidentiel - Interne"

# Utilisateurs du tenant — adapte selon les comptes présents dans ton tenant dev
$CoOwners  = @("shepard@0n4mg.onmicrosoft.com")
$CoAuthors = @("liara@0n4mg.onmicrosoft.com", "garrus@0n4mg.onmicrosoft.com")

Write-Host "-> Sublabel : $SubLabelName" -ForegroundColor Green
Write-Host "-> Parent   : $ParentLabelName`n" -ForegroundColor Green

# --- ÉTAPE 2 : Récupération du label parent ---
# Indispensable pour récupérer l'Id du parent et le passer en -ParentId
Write-Host "2. Récupération du label parent..." -ForegroundColor Cyan

$Parent = Get-Label -Identity $ParentLabelName -ErrorAction Stop
Write-Host "-> Parent trouvé. Id : $($Parent.Guid)`n" -ForegroundColor Green

# --- ÉTAPE 3 : Création du sublabel ---
# -ParentId rattache ce label au parent — il apparaîtra en sous-menu dans les apps Office
Write-Host "3. Création du sublabel..." -ForegroundColor Cyan

try {
    $NewSubLabel = New-Label `
        -Name $SubLabelName `
        -DisplayName $SubLabelName `
        -ParentId $Parent.Guid `
        -Tooltip "Document confidentiel à usage interne uniquement — chiffré" `
        -Comment "Sublabel avec chiffrement admin-defined. Cerberus Corp IAM Lab." `
        -ErrorAction Stop

    Write-Host "-> Sublabel créé. Id : $($NewSubLabel.Guid)" -ForegroundColor Green
}
catch {
    Write-Host "-> Échec création sublabel : $_" -ForegroundColor Red
    return
}

# --- ÉTAPE 4 : Application du chiffrement admin-defined ---
# -EncryptionEnabled active le RMS sur ce label
# -EncryptionProtectionType "Template" indique un chiffrement admin-defined avec
#   permissions fixes (par opposition à "UserDefined")
# -EncryptionRightsDefinitions définit qui a quel niveau de droit, au format
#   "email:DROITS" séparés par virgule. CO-OWNER = contrôle total. VIEW,EDIT = lecture/modif.
Write-Host "4. Application du chiffrement..." -ForegroundColor Cyan

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

# --- ÉTAPE 5 : Vérification ---
Write-Host "5. Vérification (propagation ~30s)..." -ForegroundColor Cyan
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
Remove-Variable ParentLabelName, SubLabelName, CoOwners, CoAuthors, Parent, `
                NewSubLabel, RightsDefinitions, Owner, Author, CheckLabel `
    -ErrorAction SilentlyContinue

# --- FERMETURE ---
Get-PSSession | Remove-PSSession
Write-Host "`nSession fermée. Mémoire locale nettoyée." -ForegroundColor Magenta
