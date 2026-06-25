# ========================================================================================
# Exercice 1d : Entra ID — Attribution de licences en masse depuis CSV
# ========================================================================================
# Concept : Attribuer la même licence à un ensemble d'utilisateurs via un fichier CSV.
# Cas d'usage réel : onboarding d'une équipe complète — les comptes sont créés (exo 2bis),
# il faut maintenant leur attribuer les licences pour qu'ils aient accès aux services M365.
#
# Ce que fait ce script :
#   1. Reset total de session
#   2. Vérifie la présence du CSV et la disponibilité de la licence dans le tenant
#   3. Pour chaque utilisateur du CSV :
#      - Vérifie l'existence du compte dans Entra
#      - Définit le UsageLocation si absent
#      - Vérifie que la licence n'est pas déjà attribuée (évite les doublons)
#      - Attribue la licence via Set-MgUserLicense
#   4. Ferme proprement toutes les sessions
#
# Try/Catch dans la boucle : un échec sur un user ne tue pas les attributions suivantes.
#
# Module requis : Microsoft.Graph.Users, Microsoft.Graph.Identity.DirectoryManagement
# Connexion     : Connect-MgGraph
# ========================================================================================

# --- OUVERTURE — RESET DE SESSION TOTAL ---
# REX : -ContextScope Process isole le token d'authentification au processus PowerShell
# en cours. Sans ce paramètre, le token WAM peut être réutilisé depuis une session
# précédente avec des scopes insuffisants — les erreurs 403 résultantes sont silencieuses
# dans une boucle ForEach et se manifestent uniquement par des [ERROR] sans cause claire.
$Scopes = @(
    "User.ReadWrite.All",    # Modifier les propriétés utilisateur (UsageLocation, licences)
    "Directory.Read.All"     # Lire les SKUs disponibles dans le tenant
)

Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
Connect-MgGraph -Scopes $Scopes -ContextScope Process -NoWelcome

# ========================================================================================
# ÉTAPE 1 : Définition des variables
# ========================================================================================
Write-Host "1. Définition des variables..." -ForegroundColor Cyan

$SkuPartNumber = "DEVELOPERPACK_E5"

# Chemin du CSV — décommenter la ligne correspondant à l'environnement d'exécution.
# EN LABO / Local :
$PathCSV = "D:\Documents\ScriptsPowerShell\utilisateurs.csv"
# EN PRODUCTION :
# $PathCSV = "$PSScriptRoot\utilisateurs.csv"
# $PSScriptRoot résout automatiquement le dossier contenant le script en cours
# d'exécution — portable, indépendant de la machine ou du profil utilisateur.

Write-Host "-> Licence cible : $SkuPartNumber" -ForegroundColor Green
Write-Host "-> Fichier CSV   : $PathCSV`n" -ForegroundColor Green

# ========================================================================================
# ÉTAPE 2 : Vérifications préalables
# ========================================================================================
Write-Host "2. Vérifications préalables..." -ForegroundColor Cyan

# Présence du fichier CSV
if (-not (Test-Path $PathCSV)) {
    Write-Host "-> Erreur : fichier introuvable à '$PathCSV'." -ForegroundColor Red
    Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
    return
}
Write-Host "-> Fichier CSV localisé." -ForegroundColor Green

# Résolution du SKU dans le tenant
# Get-MgSubscribedSku retourne tous les SKUs actifs du tenant.
# On filtre sur SkuPartNumber (lisible) pour récupérer le SkuId (GUID) requis par l'API.
$TargetSku = Get-MgSubscribedSku | Where-Object { $_.SkuPartNumber -eq $SkuPartNumber }
if (-not $TargetSku) {
    Write-Host "-> Erreur : licence '$SkuPartNumber' introuvable dans le tenant." -ForegroundColor Red
    Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
    return
}

# Vérification globale des places disponibles AVANT la boucle.
# Inutile de lancer 50 attributions si le quota est déjà épuisé.
# PrepaidUnits.Enabled = sièges achetés/activés. ConsumedUnits = sièges déjà attribués.
$Available = $TargetSku.PrepaidUnits.Enabled - $TargetSku.ConsumedUnits
if ($Available -le 0) {
    Write-Host "-> Erreur : aucune place disponible pour '$SkuPartNumber'." -ForegroundColor Red
    Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
    return
}
Write-Host "-> Licence '$SkuPartNumber' : $Available place(s) disponible(s).`n" -ForegroundColor Green

# ========================================================================================
# ÉTAPE 3 : Import du CSV
# ========================================================================================
Write-Host "3. Import du fichier CSV..." -ForegroundColor Cyan

$UsersToLicense = Import-Csv -Path $PathCSV -Delimiter ","
Write-Host "-> $($UsersToLicense.Count) compte(s) détecté(s) dans le CSV.`n" -ForegroundColor Green

# ========================================================================================
# ÉTAPE 4 : Boucle d'attribution
# ========================================================================================
Write-Host "4. Début de l'attribution en masse ($($UsersToLicense.Count) compte(s))..." -ForegroundColor Cyan
Write-Host "-------------------------------------------------------------------" -ForegroundColor Gray

foreach ($User in $UsersToLicense) {
    try {
        # Vérification de l'existence du compte dans Entra.
        # -ErrorAction Stop force la remontée dans le bloc Catch si l'UPN est introuvable.
        # Sans Stop, Get-MgUser retourne $null silencieusement et le script continue
        # avec une variable $UserObject vide — provoquant une erreur cryptique plus loin.
        $UserObject = Get-MgUser -UserId $User.UserPrincipalName -ErrorAction Stop

        # UsageLocation obligatoire avant toute attribution de licence — contrainte légale Microsoft.
        # Microsoft doit s'assurer que la licence est conforme aux lois locales du pays de l'utilisateur.
        # Si absent : l'API Graph retourne une erreur même avec tous les droits nécessaires.
        if (-not $UserObject.UsageLocation) {
            Update-MgUser -UserId $UserObject.Id -UsageLocation "FR" -ErrorAction Stop
        }

        # Vérification si la licence est déjà attribuée.
        # Évite un doublon et une consommation inutile de siège.
        # Set-MgUserLicense sur un compte déjà licencié retourne une erreur — le catch
        # l'absorberait avec un message [ERROR] peu explicite. On préfère détecter en amont.
        $ExistingLicenses = Get-MgUserLicenseDetail -UserId $UserObject.Id
        $AlreadyAssigned  = $ExistingLicenses | Where-Object { $_.SkuPartNumber -eq $SkuPartNumber }

        if ($AlreadyAssigned) {
            Write-Host "[SKIP]    $($User.UserPrincipalName) — licence déjà attribuée." -ForegroundColor Yellow
            continue
        }

        # Attribution de la licence.
        # DisabledPlans vide = tous les services inclus dans la licence sont activés.
        # RemoveLicenses vide = aucune licence retirée simultanément.
        $LicenseParams = @{
            AddLicenses = @(
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

Write-Host "-------------------------------------------------------------------" -ForegroundColor Gray
Write-Host "-> Traitement terminé.`n" -ForegroundColor Cyan

# ========================================================================================
# ÉTAPE 5 : Résumé
# ========================================================================================
Write-Host "=== RÉSUMÉ ===" -ForegroundColor Magenta
[PSCustomObject]@{
    FichierCSV        = $PathCSV
    ComptesDétectés   = $UsersToLicense.Count
    LicenceAttribuée  = $SkuPartNumber
    PlacesInitiales   = $Available
    GestionErreurs    = "Try/Catch par ligne — pas d'interruption sur erreur"
} | Format-List

# ========================================================================================
# NOTE PÉDAGOGIQUE : Attribution conditionnelle selon le pays (if/elseif vs switch)
# ========================================================================================
# Ce bloc est une variante non exécutée — il illustre comment adapter la licence
# attribuée selon le pays de l'utilisateur, cas fréquent en environnement multinational.
#
# VARIANTE A : if / elseif / else
# Lisible pour 2-3 conditions. Au-delà, le switch est plus maintenable.
#
# $CountryCode = $UserObject.Country   # Récupéré depuis le profil Entra de l'utilisateur
#
# if ($CountryCode -eq "FR") {
#     $SkuPartNumber = "DEVELOPERPACK_E5"
#     Write-Host "Attribution licence E5 Dev (France)" -ForegroundColor Green
# }
# elseif ($CountryCode -eq "GB") {
#     $SkuPartNumber = "SPE_E3"
#     Write-Host "Attribution licence E3 (UK)" -ForegroundColor Green
# }
# else {
#     # Cas par défaut : pays non listé → licence standard internationale
#     $SkuPartNumber = "SPE_E1"
#     Write-Host "Attribution licence E1 (défaut / hors FR-GB)" -ForegroundColor Yellow
# }
#
# -----------------------------------------------------------------------
#
# VARIANTE B : switch
# Syntaxe plus compacte et lisible dès que les cas sont nombreux.
# Comportement identique au if/elseif, mais sans la répétition de $CountryCode.
# "Default" = équivalent du else — déclenché si aucun cas ne correspond.
#
# $CountryCode = $UserObject.Country
#
# switch ($CountryCode) {
#     "FR"    { $SkuPartNumber = "DEVELOPERPACK_E5" }   # France
#     "GB"    { $SkuPartNumber = "SPE_E3"           }   # Royaume-Uni
#     "ES"    { $SkuPartNumber = "SPE_E1"           }   # Espagne
#     Default { $SkuPartNumber = "SPE_E1"           }   # Tous les autres pays
# }
#
# Pour intégrer cette logique dans la boucle ForEach ci-dessus :
# remplacer la variable statique $SkuPartNumber définie en ÉTAPE 1
# par un bloc switch à l'intérieur de la boucle, après la récupération de $UserObject.
# Le SkuId serait alors résolu dynamiquement à chaque itération via Get-MgSubscribedSku.

# ========================================================================================
# NETTOYAGE MÉMOIRE
# ========================================================================================
Remove-Variable Scopes, SkuPartNumber, PathCSV, TargetSku, Available,
                UsersToLicense, User, UserObject, ExistingLicenses,
                AlreadyAssigned, LicenseParams `
                -ErrorAction SilentlyContinue

# ========================================================================================
# FERMETURE — RESET DE SESSION TOTAL
# ========================================================================================
Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
Write-Host "Session MgGraph fermée proprement." -ForegroundColor Magenta
