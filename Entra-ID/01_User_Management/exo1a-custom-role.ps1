# ==============================================================================
# EXERCICE 1 : Création d'un rôle personnalisé
# Objectif : Déploiement d'un rôle RBAC granulaire pour la création d'applications.
# Licence requise : Entra ID P1/P2.
# ==============================================================================

# Connexion obligatoire avec les droits d'écriture sur les rôles de l'annuaire
Connect-MgGraph -Scopes "RoleManagement.ReadWrite.Directory"

# 1. Définition des permissions granulaires (Actions)
# Note : Ces chaînes correspondent aux actions de l'API Microsoft Graph
$Permissions = @(
    "microsoft.directory/applications/create",
    "microsoft.directory/applications/standard/read"
)

# 2. Construction du dictionnaire de paramètres (Splatting)
$RoleParams = @{
    DisplayName     = "SecOps - Custom App Creator"
    Description     = "Role restreint developpé pour l'exercice créa custom role - Autorise la creation d'apps sans droit Global Admin."
    IsEnabled       = $true
    RolePermissions = @(
        @{
            AllowedResourceActions = $Permissions
        }
    )
}

# 3. Exécution et création du rôle dans Entra ID
$NewRole = New-MgRoleManagementDirectoryRoleDefinition @RoleParams

# 4. Vérification et affichage de l'ID généré par Azure
if (-not $NewRole) {
    Write-Error "La création du rôle a échoué."
} else {
    $NewRole | Select-Object Id, DisplayName, IsEnabled
}

# 5. Nettoyage de la session (Évite les conflits au prochain exercice)
Remove-Variable Permissions, RoleParams, NewRole
