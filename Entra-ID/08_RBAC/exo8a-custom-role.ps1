# ========================================================================================
# Exercice 8a : Création d'un rôle personnalisé (Custom RBAC Role)
# ========================================================================================
# Concept : Entra ID permet de créer des rôles RBAC granulaires en complément des
# rôles built-in (Global Admin, User Admin, etc.). Un rôle custom définit exactement
# quelles actions Graph API sont autorisées — ni plus, ni moins.
#
# Cas d'usage réel :
#   Un développeur a besoin de créer des App Registrations sans avoir de droits
#   d'administration globaux. Plutôt que de lui donner Application Administrator
#   (trop large), on crée un rôle qui n'autorise que la création et la lecture
#   d'applications — principe du moindre privilège.
#
# Cas d'usage réel (mission) :
#   Première semaine — audit des rôles custom existants avant d'en créer de nouveaux.
#   Un rôle custom bien documenté ici évite de recréer la même chose dans 6 mois.
#
# Module requis : Microsoft.Graph
# Connexion : Connect-MgGraph -Scopes "RoleManagement.ReadWrite.Directory" -ContextScope Process
# Licence requise : Entra ID P1/P2
# ========================================================================================

# --- OUVERTURE — RESET DE SESSION TOTAL ---
# Les sessions Graph résiduelles d'un script précédent peuvent conserver des scopes
# insuffisants ou des tokens expirés, causant des 403 silencieux.
# On déconnecte proprement avant de se reconnecter avec les bons scopes.
# -ContextScope Process : contourne le cache WAM (Web Account Manager) qui bloque
# les scopes d'écriture sur l'app générique Microsoft Graph Command Line Tools.
# Sans ce paramètre — 403 systématique sur RoleManagement.ReadWrite.Directory.
Disconnect-MgGraph -ErrorAction SilentlyContinue
$env:MSAL_ENABLE_WAM = "0"
Connect-MgGraph -Scopes "RoleManagement.ReadWrite.Directory" -ContextScope Process

# ========================================================================================
# ÉTAPE 1 : Recherche d'un nom disponible (auto-incrément)
# ========================================================================================
# Si le script a été relancé après un échec partiel, le rôle précédent peut exister
# en état orphelin. L'auto-incrément évite le conflit de nom sans intervention manuelle.
Write-Host "1. Recherche d'un nom disponible..." -ForegroundColor Cyan

$BaseRoleName = "SecOps - Custom App Creator"
$RoleName     = $BaseRoleName
$Counter      = 2

while (Get-MgRoleManagementDirectoryRoleDefinition -All |
       Where-Object { $_.DisplayName -eq $RoleName } |
       Select-Object -First 1) {
    Write-Host "   '$RoleName' déjà pris — test avec suffixe -v$Counter..." -ForegroundColor Yellow
    $RoleName = "$BaseRoleName -v$Counter"
    $Counter++
}

Write-Host "-> Nom retenu : '$RoleName'`n" -ForegroundColor Green

# ========================================================================================
# ÉTAPE 2 : Définition des permissions granulaires
# ========================================================================================
# Les permissions correspondent aux actions de l'API Microsoft Graph.
# Chaque chaîne suit le format : microsoft.directory/<ressource>/<action>
# Référence complète : https://learn.microsoft.com/en-us/graph/permissions-reference
#
# "microsoft.directory/applications/create" :
#   Autorise la création d'App Registrations dans Entra ID.
#
# "microsoft.directory/applications/standard/read" :
#   Autorise la lecture des propriétés standard des applications
#   (nom, ID client, URIs de redirection...) — sans accès aux secrets ni certificats.
Write-Host "2. Définition des permissions du rôle..." -ForegroundColor Cyan

$Permissions = @(
    "microsoft.directory/applications/create",
    "microsoft.directory/applications/standard/read"
)

Write-Host "-> Permissions définies : $($Permissions.Count)" -ForegroundColor Green
$Permissions | ForEach-Object { Write-Host "   - $_" -ForegroundColor Gray }
Write-Host ""

# ========================================================================================
# ÉTAPE 3 : Construction des paramètres et création du rôle
# ========================================================================================
# Splatting (@RoleParams) : technique PowerShell qui passe un hashtable comme paramètres
# nommés d'une cmdlet. Équivalent à passer chaque paramètre sur la même ligne,
# mais bien plus lisible quand le nombre de paramètres est élevé.
#
# RolePermissions : tableau d'objets AllowedResourceActions.
# La structure imbriquée (@(@{AllowedResourceActions = ...})) est obligatoire —
# l'API Graph n'accepte pas un tableau plat de chaînes directement.
Write-Host "3. Création du rôle '$RoleName'..." -ForegroundColor Cyan

$RoleParams = @{
    DisplayName     = $RoleName
    Description     = "Rôle restreint — autorise la création d'App Registrations sans droits Global Admin. Exo 1a."
    IsEnabled       = $true
    RolePermissions = @(
        @{
            AllowedResourceActions = $Permissions
        }
    )
}

try {
    $NewRole = New-MgRoleManagementDirectoryRoleDefinition @RoleParams -ErrorAction Stop
    Write-Host "-> Rôle créé : $($NewRole.DisplayName) [ID : $($NewRole.Id)]`n" -ForegroundColor Green
}
catch {
    Write-Host "-> Échec de la création du rôle : $_" -ForegroundColor Red
    Disconnect-MgGraph -ErrorAction SilentlyContinue
    return
}

# ========================================================================================
# ÉTAPE 4 : Vérification depuis la source de vérité
# ========================================================================================
# On relit depuis l'API plutôt que de faire confiance à l'objet $NewRole retourné
# par New- — en cas de lag backend, l'objet local peut être incomplet.
Write-Host "4. Vérification depuis Entra ID..." -ForegroundColor Cyan
Start-Sleep -Seconds 30

$CheckRole = Get-MgRoleManagementDirectoryRoleDefinition -All |
             Where-Object { $_.Id -eq $NewRole.Id }

if ($CheckRole) {
    Write-Host "-> Rôle confirmé :" -ForegroundColor Green
    [PSCustomObject]@{
        Id          = $CheckRole.Id
        Nom         = $CheckRole.DisplayName
        Activé      = $CheckRole.IsEnabled
        BuiltIn     = $CheckRole.IsBuiltIn
        Description = $CheckRole.Description
    } | Format-List
} else {
    Write-Host "-> ATTENTION : rôle non trouvé lors de la vérification." -ForegroundColor Red
}

# ========================================================================================
# ÉTAPE 5 : Résumé
# ========================================================================================
Write-Host "=== RÉSUMÉ ===" -ForegroundColor Magenta

[PSCustomObject]@{
    RôleCréé    = $RoleName
    ID          = if ($CheckRole) { $CheckRole.Id } else { "Non vérifié" }
    Permissions = $Permissions -join " | "
    Activé      = $true
    Suppression = "Remove-MgRoleManagementDirectoryRoleDefinition -UnifiedRoleDefinitionId '$($NewRole.Id)'"
} | Format-List

# ========================================================================================
# NETTOYAGE MÉMOIRE
# ========================================================================================
Remove-Variable BaseRoleName, RoleName, Counter, Permissions, RoleParams,
                NewRole, CheckRole `
                -ErrorAction SilentlyContinue

# --- FERMETURE — RESET DE SESSION TOTAL ---
Disconnect-MgGraph -ErrorAction SilentlyContinue
Write-Host "Session Graph déconnectée proprement." -ForegroundColor Magenta
