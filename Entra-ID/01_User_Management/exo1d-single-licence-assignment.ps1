# ========================================================================================
# Exercice 1d : Attribution de licence unitaire
# ========================================================================================
# Concept : Attribuer une licence Microsoft 365 à un utilisateur via Graph API.
# En prod — un user créé sans licence n'a accès à aucun service M365.
# L'attribution de licence est donc l'étape qui suit immédiatement la création du compte.
#
# Structure de l'attribution :
#   SkuId        = l'identifiant unique de la licence (pas le SkuPartNumber lisible)
#   AddLicenses  = tableau des licences à ajouter
#   RemoveLicenses = tableau des licences à retirer (vide ici)
#
# Note : UsageLocation doit être défini sur le compte avant toute attribution de licence
# Sans UsageLocation — l'API Graph refuse l'attribution (contrainte légale Microsoft)
# ========================================================================================

# --- ÉTAPE 1 : Connexion à Microsoft Graph ---
# User.ReadWrite.All : modifier les propriétés des utilisateurs
# Directory.Read.All : lire les SKUs disponibles dans le tenant
$Scopes = @(
    "User.ReadWrite.All",
    "Directory.Read.All"
)

Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
Connect-MgGraph -Scopes $Scopes -ContextScope Process -NoWelcome

# --- ÉTAPE 2 : Définition des variables ---
$TargetUPN      = "geralt@0n4mg.onmicrosoft.com"
# SkuPartNumber lisible — on résoudra le SkuId technique à l'étape 3
$SkuPartNumber  = "DEVELOPERPACK_E5"

# --- ÉTAPE 3 : Récupération de l'utilisateur et du SKU ---
# Get-MgSubscribedSku retourne tous les SKUs du tenant avec leur SkuId technique
# L'API Graph n'accepte que le SkuId (GUID) — pas le SkuPartNumber lisible
Write-Host "1. Récupération de l'utilisateur et de la licence..." -ForegroundColor Cyan

$TargetUser = Get-MgUser -UserId $TargetUPN -ErrorAction Stop
$TargetSku  = Get-MgSubscribedSku | Where-Object { $_.SkuPartNumber -eq $SkuPartNumber }

if (-not $TargetUser) { Write-Error "Utilisateur '$TargetUPN' introuvable." ; return }
if (-not $TargetSku)  { Write-Error "Licence '$SkuPartNumber' introuvable dans le tenant." ; return }

# Vérification des places disponibles avant attribution
$Available = $TargetSku.PrepaidUnits.Enabled - $TargetSku.ConsumedUnits
if ($Available -le 0) { Write-Error "Aucune place disponible pour '$SkuPartNumber'." ; return }

Write-Host "-> Utilisateur : $($TargetUser.DisplayName)" -ForegroundColor Green
Write-Host "-> Licence     : $SkuPartNumber ($Available places disponibles)`n" -ForegroundColor Green

# --- ÉTAPE 4 : Vérification du UsageLocation ---
# UsageLocation obligatoire avant toute attribution de licence — contrainte légale Microsoft
# Sans cette propriété, l'API retourne une erreur même avec tous les droits nécessaires
if (-not $TargetUser.UsageLocation) {
    Write-Host "-> UsageLocation manquant — définition sur 'FR'..." -ForegroundColor Yellow
    Update-MgUser -UserId $TargetUser.Id -UsageLocation "FR"
    Write-Host "-> UsageLocation défini sur 'FR'" -ForegroundColor Green
}

# --- ÉTAPE 5 : Attribution de la licence ---
# AddLicenses = tableau des licences à ajouter — SkuId obligatoire
# RemoveLicenses = tableau des SkuIds à retirer — vide ici
# DisabledPlans = services à désactiver dans la licence (ex: désactiver Teams mais garder Exchange)
#                 vide ici = tous les services de la licence sont activés
Write-Host "2. Attribution de la licence '$SkuPartNumber'..." -ForegroundColor Cyan

$LicenseParams = @{
    AddLicenses    = @(
        @{
            # SkuId = GUID technique de la licence — récupéré depuis Get-MgSubscribedSku
            SkuId         = $TargetSku.SkuId
            # DisabledPlans vide = tous les services de la licence activés
            DisabledPlans = @()
        }
    )
    RemoveLicenses = @()
}

try {
    Set-MgUserLicense -UserId $TargetUser.Id -BodyParameter $LicenseParams -ErrorAction Stop | Out-Null
    Write-Host "-> Succès : Licence attribuée à $($TargetUser.DisplayName)." -ForegroundColor Green
}
catch {
    Write-Host "-> Échec : $_" -ForegroundColor Red
    return
}

# --- ÉTAPE 6 : Vérification depuis Entra (source de vérité) ---
Write-Host "`n3. Vérification depuis Entra (attente 5s)..." -ForegroundColor Cyan
Start-Sleep -Seconds 5

$AssignedLicenses = Get-MgUserLicenseDetail -UserId $TargetUser.Id
if ($AssignedLicenses) {
    $AssignedLicenses | Select-Object SkuPartNumber, SkuId | Format-Table -AutoSize
} else {
    Write-Host "-> Aucune licence assignée détectée — réplication en cours." -ForegroundColor Yellow
}

# --- ÉTAPE 7 : Nettoyage ---
Remove-Variable Scopes, TargetUPN, SkuPartNumber, TargetUser, TargetSku, `
                Available, LicenseParams, AssignedLicenses -ErrorAction SilentlyContinue

Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
Write-Host "`nMémoire locale nettoyée. Session Microsoft Graph fermée." -ForegroundColor Magenta
