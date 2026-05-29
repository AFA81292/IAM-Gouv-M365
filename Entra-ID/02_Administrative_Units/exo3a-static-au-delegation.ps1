# ========================================================================================
# Exercice 3a : Création d'une AU, ajout de membres en masse et délégation d'un admin
# ========================================================================================

# --- ÉTAPE 1 : Connexion à Microsoft Graph (Permissions verticales) ---
$Scopes = @(
    "AdministrativeUnit.ReadWrite.All",
    "RoleManagement.ReadWrite.Directory",
    "User.Read.All"
)
Connect-MgGraph -Scopes $Scopes

# --- ÉTAPE 2 : Définition des variables du Lab ---
$AuName = "Kaer-Morhen-Staff"
$AuDescription = "Périmètre de gestion statique pour le staff et les alliés de la forteresse."

# Membres à ajouter "plus ou moins en masse"
$BulkMembers = @(
    "triss@0n4mg.onmicrosoft.com",
    "yennefer@0n4mg.onmicrosoft.com"
)

# Administrateur ciblé pour cette AU
$AdminUPN = "geralt@0n4mg.onmicrosoft.com"
$HelpdeskRoleTemplateId = "72982c3a-934d-4716-8315-78655c9f91a5" # ID fixe du rôle Helpdesk Admin

# --- ÉTAPE 3 : Création de l'Administrative Unit ---
$AuParams = @{
    DisplayName = $AuName
    Description = $AuDescription
}

Write-Host "1. Création de l'Administrative Unit '$AuName'..." -ForegroundColor Cyan
$NewAU = New-MgDirectoryAdministrativeUnit -BodyParameter $AuParams
Write-Host "-> Succès : AU créée avec l'ID : $($NewAU.Id)`n" -ForegroundColor Green


# --- ÉTAPE 4 : Ajout des membres en masse via une boucle ---
Write-Host "2. Injection des membres dans l'AU..." -ForegroundColor Cyan

foreach ($UserUPN in $BulkMembers) {
    try {
        # Récupération de l'ID de l'utilisateur
        $UserObject = Get-MgUser -UserId $UserUPN
        
        # Préparation du paramètre de liaison (OData)
        $MemberParams = @{
            "@odata.id" = "https://graph.microsoft.com/v1.0/users/$($UserObject.Id)"
        }
        
        # Liaison à l'AU
        New-MgDirectoryAdministrativeUnitMemberByRef -AdministrativeUnitId $NewAU.Id -BodyParameter $MemberParams
        Write-Host "   -> Média : $UserUPN ajouté avec succès." -ForegroundColor Green
    }
    catch {
        Write-Host "   -> Échec pour $UserUPN : $_" -ForegroundColor Yellow
    }
}
Write-Host "-> Fin de l'injection des membres.`n" -ForegroundColor Green


# --- ÉTAPE 5 : Assignation de l'administrateur scopé (RBAC ciblé) ---
Write-Host "3. Assignation de l'administrateur de l'AU ($AdminUPN)..." -ForegroundColor Cyan

try {
    # Récupération de l'ID de l'admin
    $AdminObject = Get-MgUser -UserId $AdminUPN
    
    # Configuration du rôle scopé à l'AU créée à l'Étape 3
    $ScopedRoleParams = @{
        RoleId = $HelpdeskRoleTemplateId
        RoleMemberInfo = @{
            Id = $AdminObject.Id
        }
    }
    
    New-MgDirectoryAdministrativeUnitScopedRoleMember -AdministrativeUnitId $NewAU.Id -BodyParameter $ScopedRoleParams
    Write-Host "-> Succès : $AdminUPN est désormais admin Helpdesk scopé sur '$AuName'.`n" -ForegroundColor Green
}
catch {
    Write-Host "-> Échec de l'assignation de l'admin : $_" -ForegroundColor Red
}

# --- ÉTAPE 6 : Déconnexion ---
Disconnect-MgGraph
Write-Host "Script terminé. Session Graph fermée." -ForegroundColor Magenta
