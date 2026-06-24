# ========================================================================================
# Exercice 1d : Entra ID — Attribution de licence unitaire via Graph API
# ========================================================================================
# Concept : Attribuer une licence Microsoft 365 à un utilisateur existant.
# En production, un compte créé sans licence n'a accès à aucun service M365.
# L'attribution de licence est l'étape qui suit immédiatement la création du compte.
#
# Ce que fait ce script :
#   1. Reset total de session
#   2. Récupère l'utilisateur cible et le SKU correspondant dans le tenant
#   3. Vérifie les places disponibles et le UsageLocation
#   4. Attribue la licence via Set-MgUserLicense
#   5. Vérifie l'attribution depuis la source de vérité
#   6. Ferme proprement toutes les sessions
#
# Structure de l'attribution Graph :
#   SkuId          = GUID technique de la licence (pas le SkuPartNumber lisible)
#   AddLicenses    = tableau des licences à ajouter
#   RemoveLicenses = tableau des licences à retirer (vide ici)
#   DisabledPlans  = services à désactiver dans la licence (vide = tout activé)
#
# Utilisateur cible : geralt@0n4mg.onmicrosoft.com (personnage Witcher — tenant de dev)
#
# Module requis : Microsoft.Graph.Users, Microsoft.Graph.Identity.DirectoryManagement
# Connexion     : Connect-MgGraph
# ========================================================================================

# --- OUVERTURE — RESET DE SESSION TOTAL ---
# REX : -ContextScope Process isole le contexte d'authentification au processus PowerShell
# en cours. Sans ce paramètre, le token WAM (Windows Authentication Manager) peut être
# réutilisé depuis une session précédente avec des scopes différents — provoquant des
# erreurs 403 silencieuses sur les appels Graph nécessitant Directory.Read.All.
# -NoWelcome supprime le bandeau de connexion pour un output console plus lisible.
$Scopes = @(
    "User.ReadWrite.All",    # Modifier les propriétés utilisateur (UsageLocation, licences)
    "Directory.Read.All"     # Lire les SKUs disponibles dans le tenant
)

Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
Connect-MgGraph -Scopes $Scopes -ContextScope Process -NoWelcome

# ========================================================================================
# ÉTAPE 1 : Définition des variables cibles
# ========================================================================================
Write-Host "1. Définition des variables cibles..." -ForegroundColor Cyan

$TargetUPN     = "geralt@0n4mg.onmicrosoft.com"
$SkuPartNumber = "DEVELOPERPACK_E5"
# SkuPartNumber = identifiant lisible de la licence (affiché dans le portail M365 Admin).
# L'API Graph n'accepte que le SkuId (GUID) — on résout la correspondance à l'étape suivante
# via Get-MgSubscribedSku.

Write-Host "-> Utilisateur cible : $TargetUPN" -ForegroundColor Green
Write-Host "-> Licence cible     : $SkuPartNumber`n" -ForegroundColor Green

# ========================================================================================
# ÉTAPE 2 : Récupération de l'utilisateur et du SKU
# ========================================================================================
Write-Host "2. Récupération de l'utilisateur et de la licence dans le tenant..." -ForegroundColor Cyan

$TargetUser = Get-MgUser -UserId $TargetUPN -ErrorAction Stop
$TargetSku  = Get-MgSubscribedSku | Where-Object { $_.SkuPartNumber -eq $SkuPartNumber }

if (-not $TargetUser) {
    Write-Host "-> Erreur : utilisateur '$TargetUPN' introuvable." -ForegroundColor Red
    Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
    return
}
if (-not $TargetSku) {
    Write-Host "-> Erreur : licence '$SkuPartNumber' introuvable dans le tenant." -ForegroundColor Red
    Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
    return
}

# Vérification des places disponibles avant attribution.
# PrepaidUnits.Enabled = nombre total de sièges achetés/activés.
# ConsumedUnits        = nombre de sièges déjà attribués.
# Si Available <= 0 : l'attribution échouera côté Graph — autant sortir proprement maintenant.
$Available = $TargetSku.PrepaidUnits.Enabled - $TargetSku.ConsumedUnits
if ($Available -le 0) {
    Write-Host "-> Erreur : aucune place disponible pour '$SkuPartNumber'." -ForegroundColor Red
    Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
    return
}

Write-Host "-> Utilisateur : $($TargetUser.DisplayName)" -ForegroundColor Green
Write-Host "-> Licence     : $SkuPartNumber ($Available place(s) disponible(s))`n" -ForegroundColor Green

# ========================================================================================
# ÉTAPE 3 : Vérification et définition du UsageLocation
# ========================================================================================
Write-Host "3. Vérification du UsageLocation..." -ForegroundColor Cyan

# DÉCOUVERTE TECHNIQUE : UsageLocation est obligatoire avant toute attribution de licence
# via Graph. Sans cette propriété renseignée sur le compte, l'API retourne une erreur
# même si tous les scopes et droits sont en place.
# Raison : Microsoft doit s'assurer que la licence est conforme aux lois locales
# du pays de l'utilisateur (ex : certains services sont restreints dans certains pays).
# Cette contrainte est identique en GUI (portail M365 Admin) et en API.
if (-not $TargetUser.UsageLocation) {
    Write-Host "-> UsageLocation absent — définition sur 'FR'..." -ForegroundColor Yellow
    Update-MgUser -UserId $TargetUser.Id -UsageLocation "FR"
    Write-Host "-> UsageLocation défini sur 'FR'" -ForegroundColor Green
} else {
    Write-Host "-> UsageLocation déjà défini : $($TargetUser.UsageLocation)" -ForegroundColor Green
}
Write-Host ""

# ========================================================================================
# ÉTAPE 4 : Attribution de la licence
# ========================================================================================
Write-Host "4. Attribution de la licence '$SkuPartNumber'..." -ForegroundColor Cyan

$LicenseParams = @{
    AddLicenses = @(
        @{
            # SkuId = GUID technique résolu depuis Get-MgSubscribedSku à l'étape 2.
            # Ce GUID est propre à chaque tenant — ne pas coder en dur entre tenants.
            SkuId         = $TargetSku.SkuId
            # DisabledPlans vide = tous les services inclus dans la licence sont activés.
            # Pour désactiver un service spécifique (ex : Teams), renseigner son GUID ici.
            DisabledPlans = @()
        }
    )
    # RemoveLicenses : liste des SkuIds à retirer simultanément.
    # Utile pour les migrations de licence (ex : E3 → E5) en une seule opération API.
    # Vide ici — on attribue uniquement, sans retrait.
    RemoveLicenses = @()
}

try {
    Set-MgUserLicense -UserId $TargetUser.Id -BodyParameter $LicenseParams -ErrorAction Stop | Out-Null
    Write-Host "-> Licence attribuée à $($TargetUser.DisplayName)." -ForegroundColor Green
}
catch {
    Write-Host "-> Échec de l'attribution : $_" -ForegroundColor Red
    Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
    return
}

# ========================================================================================
# ÉTAPE 5 : Vérification depuis la source de vérité
# ========================================================================================
Write-Host "`n5. Vérification depuis Entra..." -ForegroundColor Cyan

# REX : la propagation de l'attribution de licence dans Graph n'est pas instantanée.
# Get-MgUserLicenseDetail interrogé immédiatement après Set-MgUserLicense peut retourner
# un résultat vide même si l'attribution a réussi. 30 secondes couvrent la latence backend.
Start-Sleep -Seconds 30

$AssignedLicenses = Get-MgUserLicenseDetail -UserId $TargetUser.Id
if ($AssignedLicenses) {
    Write-Host "-> Licence(s) confirmée(s) sur le compte :" -ForegroundColor Green
    $AssignedLicenses | Select-Object SkuPartNumber, SkuId | Format-Table -AutoSize
} else {
    Write-Host "-> Aucune licence détectée — réplication encore en cours." -ForegroundColor Yellow
    Write-Host "   Relancer Get-MgUserLicenseDetail -UserId '$TargetUPN' dans quelques minutes." -ForegroundColor Yellow
}

# ========================================================================================
# ÉTAPE 6 : Résumé
# ========================================================================================
Write-Host "=== RÉSUMÉ ===" -ForegroundColor Magenta
[PSCustomObject]@{
    UtilisateurCible  = $TargetUPN
    DisplayName       = $TargetUser.DisplayName
    LicenceAttribuée  = $SkuPartNumber
    SkuId             = $TargetSku.SkuId
    PlacesRestantes   = ($Available - 1)
    UsageLocation     = "FR"
    StatutVérif       = if ($AssignedLicenses) { "Confirmé" } else { "Réplication en cours" }
} | Format-List

# ========================================================================================
# NETTOYAGE MÉMOIRE
# ========================================================================================
Remove-Variable Scopes, TargetUPN, SkuPartNumber, TargetUser, TargetSku,
                Available, LicenseParams, AssignedLicenses `
                -ErrorAction SilentlyContinue

# ========================================================================================
# FERMETURE — RESET DE SESSION TOTAL
# ========================================================================================
Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
Write-Host "Session MgGraph fermée proprement." -ForegroundColor Magenta
