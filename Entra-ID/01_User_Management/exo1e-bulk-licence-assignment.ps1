# ========================================================================================
# Exercice 1e : Attribution de licences en masse depuis CSV
# ========================================================================================
# Concept : Attribuer la même licence à un ensemble d'utilisateurs via un fichier CSV.
# Cas d'usage réel : onboarding d'une équipe complète — les comptes sont créés (exo 1c),
# il faut maintenant leur attribuer les licences pour qu'ils aient accès aux services M365.
#
# Le script vérifie pour chaque user :
#   - L'existence du compte dans Entra
#   - La présence d'un UsageLocation (obligatoire pour l'attribution)
#   - Que la licence n'est pas déjà attribuée (évite les doublons)
#
# Try/Catch dans la boucle — même logique que l'exo 1c :
# un échec sur un user ne tue pas les attributions des suivants.
# ========================================================================================

# --- ÉTAPE 1 : Connexion à Microsoft Graph ---
$Scopes = @(
    "User.ReadWrite.All",
    "Directory.Read.All"
)

Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
Connect-MgGraph -Scopes $Scopes -ContextScope Process -NoWelcome

# --- ÉTAPE 2 : Définition des variables ---
$SkuPartNumber = "DEVELOPERPACK_E5"

# Chemin du CSV — décommenter la ligne nécessaire
# EN LABO/Local :
$PathCSV = "D:\Documents\ScriptsPowerShell\utilisateurs.csv"
# EN PRODUCTION :
# $PathCSV = "$PSScriptRoot\utilisateurs.csv"

# --- ÉTAPE 3 : Vérifications préalables ---
# Fichier CSV
if (-not (Test-Path $PathCSV)) {
    Write-Error "Fichier introuvable : $PathCSV"
    return
}

# Licence disponible dans le tenant
$TargetSku = Get-MgSubscribedSku | Where-Object { $_.SkuPartNumber -eq $SkuPartNumber }
if (-not $TargetSku) { Write-Error "Licence '$SkuPartNumber' introuvable dans le tenant." ; return }

# Vérification des places disponibles avant de lancer la boucle
$Available = $TargetSku.PrepaidUnits.Enabled - $TargetSku.ConsumedUnits
Write-Host "Licence : $SkuPartNumber — $Available places disponibles`n" -ForegroundColor Cyan

if ($Available -le 0) { Write-Error "Aucune place disponible." ; return }

# --- ÉTAPE 4 : Import du CSV ---
$UsersToLicense = Import-Csv -Path $PathCSV -Delimiter ","
Write-Host "--- Début de l'attribution en masse ($($UsersToLicense.Count) comptes détectés) ---`n" -ForegroundColor Cyan

# --- ÉTAPE 5 : Boucle d'attribution ---
# Try/Catch dans la boucle — un échec ne tue pas les attributions suivantes
foreach ($User in $UsersToLicense) {
    try {
        # Récupération du compte Entra
        $UserObject = Get-MgUser -UserId $User.UserPrincipalName -ErrorAction Stop

        # Vérification et définition du UsageLocation si manquant
        # UsageLocation obligatoire avant toute attribution — contrainte légale Microsoft
        if (-not $UserObject.UsageLocation) {
            Update-MgUser -UserId $UserObject.Id -UsageLocation "FR" -ErrorAction Stop
        }

        # Vérification si la licence est déjà attribuée — évite les doublons et les erreurs
        $ExistingLicenses = Get-MgUserLicenseDetail -UserId $UserObject.Id
        $AlreadyAssigned  = $ExistingLicenses | Where-Object { $_.SkuPartNumber -eq $SkuPartNumber }

        if ($AlreadyAssigned) {
            Write-Host "[SKIP]    $($User.UserPrincipalName) — licence déjà attribuée." -ForegroundColor Yellow
            continue
        }

        # Attribution de la licence
        $LicenseParams = @{
            AddLicenses    = @(
                @{
                    SkuId         = $TargetSku.SkuId
                    DisabledPlans = @()
                }
            )
            RemoveLicenses = @()
        }

        Set-MgUserLicense -UserId $UserObject.Id -BodyParameter $LicenseParams -ErrorAction Stop | Out-Null
        Write-Host "[SUCCESS] $($User.UserPrincipalName) — licence $SkuPartNumber attribuée." -ForegroundColor Green
    }
    catch {
        Write-Host "[ERROR]   $($User.UserPrincipalName) — échec : $_" -ForegroundColor Red
    }
}

Write-Host "`n--- Fin du traitement ---" -ForegroundColor Cyan

# Moyen sympa de jouer avec les if/elseif/else s'il faut traiter plusieurs types de licence :
# Simulation de la variable (ex: récupérée via un Get-MgUser)
# $personne = "FR"
# 
# if ($personne -eq "FR") {
#     $Licence = "W"
#     Write-Host "Attribution de la licence W (France)" -ForegroundColor Green
# } 
# elseif ($personne -eq "EN") {
#     $Licence = "Y"
#     Write-Host "Attribution de la licence Y (UK/US)" -ForegroundColor Green
# } 
# else {
#     # Ici on gère le cas "SP" (Espagne) ou toute autre valeur par défaut
#     $Licence = "Z"
#     Write-Host "Attribution de la licence Z (Par défaut / Espagne)" -ForegroundColor Yellow
# }
# 
# OU ALORS
# $personne = "SP"
# 
# switch ($personne) {
#     "FR"    { $Licence = "W" }
#     "EN"    { $Licence = "Y" }
#     "SP"    { $Licence = "Z" }
#     Default { $Licence = "Standard" } # Si le pays n'est pas dans la liste
# }

Write-Host "Licence finale à appliquer : $Licence" -ForegroundColor Cyan


# --- ÉTAPE 6 : Nettoyage ---
Remove-Variable Scopes, SkuPartNumber, PathCSV, TargetSku, Available, `
                UsersToLicense, User, UserObject, ExistingLicenses, `
                AlreadyAssigned, LicenseParams -ErrorAction SilentlyContinue

Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
Write-Host "`nMémoire locale nettoyée. Session Microsoft Graph fermée." -ForegroundColor Magenta
