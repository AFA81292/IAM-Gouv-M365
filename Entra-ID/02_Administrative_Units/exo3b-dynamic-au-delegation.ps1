# ========================================================================================
# Exercice 3b : Création d'une AU Dynamique avec règles basées sur les attributs (MagicOps)
# ========================================================================================

# --- ÉTAPE 1 : Connexion à Microsoft Graph (Permissions verticales) ---
$Scopes = @(
    "AdministrativeUnit.ReadWrite.All",
    "RoleManagement.ReadWrite.Directory",
    "Directory.ReadWrite.All",
    "User.Read.All"
)
Connect-MgGraph -Scopes $Scopes

# --- ÉTAPE 2 : Définition des variables du Lab ---
$AuName = "MagicOps-Command-Center"
$AuDescription = "AU dynamique : Gestion automatique des ressources du département MagicOps."

$TargetDepartment = "MagicOps"
$MembershipRule = "(user.department -eq `"$TargetDepartment`")"
$AdminUPN = "geralt@0n4mg.onmicrosoft.com"
$RoleTemplateId = "fe930be7-5e62-47db-91af-98c3a49a38b1"

# --- ÉTAPE 3 : Création de l'Administrative Unit Dynamique ---
Write-Host "1. Création de l'Administrative Unit Dynamique '$AuName'..." -ForegroundColor Cyan
Write-Host "   Règle appliquée : $MembershipRule" -ForegroundColor Gray

try {
    $NewAU = Invoke-MgGraphRequest -Method POST `
        -Uri "https://graph.microsoft.com/v1.0/directory/administrativeUnits" `
        -Body @{
            displayName                   = $AuName
            description                   = $AuDescription
            membershipType                = "Dynamic"
            membershipRule                = $MembershipRule
            membershipRuleProcessingState = "On"
        } `
        -ContentType "application/json" `
        -ErrorAction Stop

    Write-Host "-> Succès : AU dynamique créée avec l'ID : $($NewAU.id)`n" -ForegroundColor Green
}
catch {
    Write-Host "-> Échec critique de création : $_" -ForegroundColor Red
    break
}

# --- ÉTAPE 4 : Confirmation du moteur de règle ---
Write-Host "2. Vérification du moteur de règle..." -ForegroundColor Cyan
$AuStatus = Invoke-MgGraphRequest -Method GET `
    -Uri "https://graph.microsoft.com/v1.0/directory/administrativeUnits/$($NewAU.id)"
Write-Host "-> Statut du moteur : $($AuStatus.membershipRuleProcessingState)" -ForegroundColor Green
Write-Host "-> Info : Les membres seront peuplés automatiquement par Entra (délai jusqu'à 24h).`n" -ForegroundColor Yellow

# --- ÉTAPE 5 : Assignation de l'admin (AVEC BOUCLE D'ATTENTE) ---
Write-Host "3. Assignation de l'admin $AdminUPN..." -ForegroundColor Cyan
$Success = $false

for ($i=1; $i -le 3; $i++) {
    try {
        $AdminObject = Get-MgUser -UserId $AdminUPN -ErrorAction Stop
        $ActiveRole = Get-MgDirectoryRole | Where-Object {$_.RoleTemplateId -eq $RoleTemplateId}
        
        $ExistingAdmins = Get-MgDirectoryAdministrativeUnitScopedRoleMember -AdministrativeUnitId $NewAU.id -ErrorAction SilentlyContinue
        $IsAlreadyAdmin = $ExistingAdmins | Where-Object {$_.Id -eq $AdminObject.Id}

        if ($IsAlreadyAdmin) {
            Write-Host "-> Info : $AdminUPN est DÉJÀ admin de cette AU. Aucune action nécessaire." -ForegroundColor Yellow
            $Success = $true
            break
        }
        else {
            $ScopedRoleParams = @{
                RoleId = $ActiveRole.Id
                RoleMemberInfo = @{ Id = $AdminObject.Id }
            }
            New-MgDirectoryAdministrativeUnitScopedRoleMember -AdministrativeUnitId $NewAU.id -BodyParameter $ScopedRoleParams -ErrorAction Stop | Out-Null
            Write-Host "-> Succès : $AdminUPN est désormais admin de '$AuName'." -ForegroundColor Green
            $Success = $true
            break
        }
    }
    catch {
        Write-Host "   Tentative $i/3 : Erreur de propagation ou rôle non trouvé (réessai)..." -ForegroundColor Gray
        Start-Sleep -Seconds 5
    }
}

if (-not $Success) { 
    Write-Host "-> Échec final : Impossible d'assigner l'admin après 3 tentatives." -ForegroundColor Red 
}

# --- ÉTAPE 6 : Nettoyage de la mémoire locale ---
Remove-Variable Scopes, AuName, AuDescription, TargetDepartment, MembershipRule, AdminUPN, `
                  RoleTemplateId, NewAU, AuStatus, Members, Success, `
                  AdminObject, ActiveRole, ExistingAdmins, IsAlreadyAdmin, ScopedRoleParams -ErrorAction SilentlyContinue

Write-Host "`nMémoire locale nettoyée. Session Microsoft Graph toujours active." -ForegroundColor Magenta
