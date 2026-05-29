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

# La règle est définie ici. 
# Syntaxe : user.department -eq "Valeur"
$TargetDepartment = "MagicOps"
$MembershipRule = "user.department -eq `"$TargetDepartment`""
$AdminUPN = "geralt@0n4mg.onmicrosoft.com"
$RoleTemplateId = "fe930be7-5e62-47db-91af-98c3a49a38b1"

# --- ÉTAPE 3 : Préparation et création de l'Administrative Unit Dynamique ---
$AuParams = @{
    DisplayName                   = $AuName
    Description                   = $AuDescription
    # Le paramètre clé pour rendre l'AU dynamique
    MembershipType                = "dynamicMembership"
    MembershipRule                = $MembershipRule
    # Activation immédiate du moteur de règle
    MembershipRuleProcessingState = "on"
}

Write-Host "1. Création de l'Administrative Unit Dynamique '$AuName'..." -ForegroundColor Cyan
Write-Host "   Règle appliquée : $MembershipRule" -ForegroundColor Gray

try {
    $NewAU = New-MgDirectoryAdministrativeUnit -BodyParameter $AuParams -ErrorAction Stop
    Write-Host "-> Succès : AU dynamique créée avec l'ID : $($NewAU.Id)`n" -ForegroundColor Green
}
catch {
    Write-Host "-> Échec critique de création : $_" -ForegroundColor Red
    break # Arrête le script si l'AU ne peut pas être créée
}

# --- ÉTAPE 4 : Audit (AVEC BOUCLE D'ATTENTE) ---
# On boucle jusqu'à 5 fois (5s par essai) pour attendre le moteur de règle
Write-Host "Vérification des membres (Attente synchro)..." -ForegroundColor Cyan
$Found = $false
for ($i=1; $i -le 5; $i++) {
    $Members = Get-MgDirectoryAdministrativeUnitMember -AdministrativeUnitId $NewAU.Id -ErrorAction SilentlyContinue
    if ($Members) { $Found = $true; break }
    Write-Host "   Tentative $i/5 : Moteur en cours de calcul..." -ForegroundColor Gray
    Start-Sleep -Seconds 5
}

if ($Found) { Write-Host "-> Succès : $(@($Members).Count) membres trouvés." -ForegroundColor Green }
else { Write-Host "-> Attention : Aucun membre détecté après 25s." -ForegroundColor Yellow }

# --- ÉTAPE 5 : Assignation de l'admin (AVEC BOUCLE D'ATTENTE) ---
# Parfois, l'objet AU vient d'être créé et n'est pas encore "visible" par le service de rôle
Write-Host "`n4. Assignation de l'admin $AdminUPN (Vérification et propagation)..." -ForegroundColor Cyan
$Success = $false

for ($i=1; $i -le 3; $i++) {
    try {
        # 1. Récupération des objets nécessaires
        $AdminObject = Get-MgUser -UserId $AdminUPN -ErrorAction Stop
        $ActiveRole = Get-MgDirectoryRole | Where-Object {$_.RoleTemplateId -eq $RoleTemplateId}
        
        # 2. Vérification idempotente : Est-il déjà admin ?
        $ExistingAdmins = Get-MgDirectoryAdministrativeUnitScopedRoleMember -AdministrativeUnitId $NewAU.Id -ErrorAction SilentlyContinue
        $IsAlreadyAdmin = $ExistingAdmins | Where-Object {$_.Id -eq $AdminObject.Id}

        if ($IsAlreadyAdmin) {
            Write-Host "-> Info : $AdminUPN est DÉJÀ admin de cette AU. Aucune action nécessaire." -ForegroundColor Yellow
            $Success = $true
            break # On sort de la boucle avec succès
        }
        else {
            # 3. Tentative d'ajout
            $ScopedRoleParams = @{
                RoleId = $ActiveRole.Id
                RoleMemberInfo = @{ Id = $AdminObject.Id }
            }
            New-MgDirectoryAdministrativeUnitScopedRoleMember -AdministrativeUnitId $NewAU.Id -BodyParameter $ScopedRoleParams -ErrorAction Stop
            Write-Host "-> Succès : $AdminUPN est désormais admin de '$AuName'." -ForegroundColor Green
            $Success = $true
            break
        }
    }
    catch {
        # En cas d'erreur de propagation, on attend et on réessaie
        Write-Host "   Tentative $i/3 : Erreur de propagation ou rôle non trouvé (réessai)..." -ForegroundColor Gray
        Start-Sleep -Seconds 5
    }
}

if (-not $Success) { 
    Write-Host "-> Échec final : Impossible d'assigner l'admin après 3 tentatives." -ForegroundColor Red 
}

ifif (-not $Success) { 
    Write-Host "-> Échec final : Impossible d'assigner l'admin après 3 tentatives." -ForegroundColor Red 
}

# --- ÉTAPE 6 : Nettoyage de la mémoire locale ---
Remove-Variable Scopes, AuName, AuDescription, TargetDepartment, MembershipRule, AdminUPN, `
                  RoleTemplateId, AuParams, NewAU, VerificationAU, Members, Success, `
                  AdminObject, ActiveRole, ExistingAdmins, IsAlreadyAdmin, ScopedRoleParams -ErrorAction SilentlyContinue

Write-Host "`nMémoire locale nettoyée. Session Microsoft Graph toujours active." -ForegroundColor Magenta
