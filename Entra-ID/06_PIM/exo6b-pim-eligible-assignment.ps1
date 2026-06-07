# ========================================================================================
# Exercice 6b : PIM — Assignation ELIGIBLE d'un rôle Entra
# ========================================================================================
# Concept : Rendre un utilisateur ELIGIBLE à un rôle via PIM.
# Eligible = il peut activer le rôle quand il en a besoin,
# avec justification obligatoire et durée limitée d'activation.
# Il n'a PAS le rôle activé en permanence — least privilege appliqué aux admins.
#
# Différence avec une assignation classique :
#   Classique → rôle actif en permanence, pas de traçabilité
#   PIM Eligible → activation sur demande, justification, durée limitée, logs complets
#
# Scénario : Geralt devient éligible au rôle User Administrator.
# Il devra activer le rôle via My Access quand il en a besoin.
# ========================================================================================

# --- ÉTAPE 1 : Connexion à Microsoft Graph ---
# RoleManagement.ReadWrite.Directory : créer des assignations PIM
# -ContextScope Process : bypasse le cache WAM
$Scopes = @(
    "RoleManagement.ReadWrite.Directory",
    "User.Read.All"
)

Disconnect-MgGraph -ErrorAction SilentlyContinue
Connect-MgGraph -Scopes $Scopes -ContextScope Process

# --- ÉTAPE 2 : Définition des variables ---
$TargetUPN      = "geralt@0n4mg.onmicrosoft.com"
# User Administrator = rôle Entra qui permet de gérer les users sans être Global Admin
# C'est le rôle typique pour les helpdesk et les admins de périmètre
$RoleName       = "User Administrator"
# Durée de l'éligibilité — après cette date, l'éligibilité expire automatiquement
$EligibilityDays = 90

# --- ÉTAPE 3 : Récupération de l'utilisateur et du rôle ---
Write-Host "1. Récupération de l'utilisateur et du rôle cible..." -ForegroundColor Cyan

$TargetUser = Get-MgUser -UserId $TargetUPN -ErrorAction Stop

$TargetRole = Get-MgRoleManagementDirectoryRoleDefinition -All |
    Where-Object { $_.DisplayName -eq $RoleName }

if (-not $TargetRole) { Write-Error "Rôle '$RoleName' introuvable." ; return }

Write-Host "-> Utilisateur : $($TargetUser.DisplayName) ($($TargetUser.Id))" -ForegroundColor Green
Write-Host "-> Rôle : $($TargetRole.DisplayName) ($($TargetRole.Id))`n" -ForegroundColor Green

# --- ÉTAPE 4 : Création de l'assignation éligible ---
# Action "adminAssign" = assignation par un admin (vs "selfActivate" = activation par l'user)
# AssignmentType "Eligible" = éligible, pas actif
# ScheduleInfo définit la durée de l'éligibilité
Write-Host "2. Création de l'assignation éligible..." -ForegroundColor Cyan

$EligibilityParams = @{
    # adminAssign = l'admin crée l'éligibilité
    # adminRemove = l'admin supprime l'éligibilité
    Action           = "adminAssign"
    # Justification visible dans les logs d'audit
    Justification    = "Assignation éligible lab SC300 — User Administrator pour Geralt"
    RoleDefinitionId = $TargetRole.Id
    PrincipalId      = $TargetUser.Id
    # DirectoryScope "/" = périmètre tenant entier
    # Pour un périmètre AU : "/administrativeUnits/id-de-lau"
    DirectoryScopeId = "/"
    ScheduleInfo     = @{
        StartDateTime = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ssZ")
        Expiration    = @{
            # AfterDateTime = expiration à une date précise
            # AfterDuration = expiration après une durée
            # NoExpiration  = permanent (à éviter sauf break-glass)
            Type        = "AfterDateTime"
            EndDateTime = (Get-Date).AddDays($EligibilityDays).ToString("yyyy-MM-ddTHH:mm:ssZ")
        }
    }
}

try {
    $NewEligibility = New-MgRoleManagementDirectoryRoleEligibilityScheduleRequest `
        -BodyParameter $EligibilityParams -ErrorAction Stop
    Write-Host "-> Succès : Assignation éligible créée." -ForegroundColor Green
    Write-Host "-> ID : $($NewEligibility.Id)" -ForegroundColor Green
    Write-Host "-> Expiration : dans $EligibilityDays jours" -ForegroundColor Yellow
}
catch {
    Write-Host "-> Échec : $_" -ForegroundColor Red
    return
}

# --- ÉTAPE 5 : Vérification ---
Write-Host "`n3. Vérification depuis Entra (source de vérité, attente 10s)..." -ForegroundColor Cyan
Start-Sleep -Seconds 10

$Verification = Get-MgRoleManagementDirectoryRoleEligibilitySchedule -All |
    Where-Object { $_.PrincipalId -eq $TargetUser.Id -and $_.RoleDefinitionId -eq $TargetRole.Id }

if ($Verification) {
    Write-Host "-> Assignation éligible confirmée :" -ForegroundColor Green
    [PSCustomObject]@{
        Utilisateur  = $TargetUser.DisplayName
        Role         = $TargetRole.DisplayName
        TypeMembre   = $Verification.MemberType
        Expiration   = $Verification.ScheduleInfo.Expiration.EndDateTime
    }
} else {
    Write-Host "-> Assignation créée mais réplication en cours." -ForegroundColor Yellow
    Write-Host "-> Vérifie dans Entra Admin Center — PIM — Eligible assignments." -ForegroundColor Yellow
}

# --- ÉTAPE 6 : Nettoyage ---
Remove-Variable Scopes, TargetUPN, RoleName, EligibilityDays, TargetUser, `
                TargetRole, EligibilityParams, NewEligibility, Verification `
                -ErrorAction SilentlyContinue

Write-Host "`nMémoire locale nettoyée. Session Microsoft Graph toujours active." -ForegroundColor Magenta
