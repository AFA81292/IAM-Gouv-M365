# ========================================================================================
# Exercice 6c : PIM — Assignation ACTIVE time-bound d'un rôle Entra
# ========================================================================================
# Concept : Assigner un rôle de manière ACTIVE et TEMPORAIRE via PIM.
# Contrairement à l'éligible (6b) — le rôle est actif immédiatement.
# L'utilisateur n'a pas besoin d'activer quoi que ce soit.
# Mais le rôle expire automatiquement à la date définie.
#
# Cas d'usage réel :
#   - Un consultant arrive pour une mission de 3 mois
#   - Il a besoin du rôle actif immédiatement sans passer par My Access
#   - A la fin de la mission — révocation automatique, zéro oubli
#
# Différence 6b vs 6c :
#   6b Eligible  → doit activer via My Access + justification + MFA
#   6c Active    → actif immédiatement, expire automatiquement
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
$TargetUPN = "liara@0n4mg.onmicrosoft.com"
$RoleName    = "User Administrator"
# Durée de la mission — après cette date, révocation automatique
$MissionDays = 90

# --- ÉTAPE 3 : Récupération de l'utilisateur et du rôle ---
Write-Host "1. Récupération de l'utilisateur et du rôle cible..." -ForegroundColor Cyan

$TargetUser = Get-MgUser -UserId $TargetUPN -ErrorAction Stop

$TargetRole = Get-MgRoleManagementDirectoryRoleDefinition -All |
    Where-Object { $_.DisplayName -eq $RoleName }

if (-not $TargetRole) { Write-Error "Rôle '$RoleName' introuvable." ; return }

Write-Host "-> Utilisateur : $($TargetUser.DisplayName) ($($TargetUser.Id))" -ForegroundColor Green
Write-Host "-> Rôle : $($TargetRole.DisplayName) ($($TargetRole.Id))`n" -ForegroundColor Green

# --- ÉTAPE 4 : Création de l'assignation active time-bound ---
# Différence vs 6b :
#   New-MgRoleManagementDirectoryRoleEligibilityScheduleRequest → éligible
#   New-MgRoleManagementDirectoryRoleAssignmentScheduleRequest  → actif
Write-Host "2. Création de l'assignation active time-bound..." -ForegroundColor Cyan

$AssignmentParams = @{
    # adminAssign = assignation par un admin
    Action           = "adminAssign"
    Justification    = "Mission run SharePoint 90 jours — accès actif immédiat avec expiration automatique"
    RoleDefinitionId = $TargetRole.Id
    PrincipalId      = $TargetUser.Id
    DirectoryScopeId = "/"
    # AssignmentType "Assigned" = actif permanent ou time-bound
    # vs "Activated" = activé par l'user depuis une éligibilité
    AssignmentType   = "Assigned"
    ScheduleInfo     = @{
        StartDateTime = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ssZ")
        Expiration    = @{
            Type        = "AfterDateTime"
            EndDateTime = (Get-Date).AddDays($MissionDays).ToString("yyyy-MM-ddTHH:mm:ssZ")
        }
    }
}

try {
    $NewAssignment = New-MgRoleManagementDirectoryRoleAssignmentScheduleRequest `
        -BodyParameter $AssignmentParams -ErrorAction Stop
    Write-Host "-> Succès : Assignation active créée." -ForegroundColor Green
    Write-Host "-> ID : $($NewAssignment.Id)" -ForegroundColor Green
    Write-Host "-> Actif jusqu'au : $((Get-Date).AddDays($MissionDays).ToString('dd/MM/yyyy'))" -ForegroundColor Yellow
}
catch {
    Write-Host "-> Échec : $_" -ForegroundColor Red
    return
}

# --- ÉTAPE 5 : Vérification ---
Write-Host "`n3. Vérification depuis Entra (source de vérité, attente 10s)..." -ForegroundColor Cyan
Start-Sleep -Seconds 10

$Verification = Get-MgRoleManagementDirectoryRoleAssignmentSchedule -All |
    Where-Object { $_.PrincipalId -eq $TargetUser.Id -and $_.RoleDefinitionId -eq $TargetRole.Id }

if ($Verification) {
    Write-Host "-> Assignation active confirmée :" -ForegroundColor Green
    [PSCustomObject]@{
        Utilisateur  = $TargetUser.DisplayName
        Role         = $TargetRole.DisplayName
        Statut       = $Verification.Status
        TypeAssig    = $Verification.AssignmentType
        Expiration   = $Verification.ScheduleInfo.Expiration.EndDateTime
    }
} else {
    Write-Host "-> Assignation créée mais réplication en cours." -ForegroundColor Yellow
    Write-Host "-> Vérifie dans Entra Admin Center — PIM — Active assignments." -ForegroundColor Yellow
}

# --- ÉTAPE 6 : Nettoyage ---
Remove-Variable Scopes, TargetUPN, RoleName, MissionDays, TargetUser, `
                TargetRole, AssignmentParams, NewAssignment, Verification `
                -ErrorAction SilentlyContinue

Write-Host "`nMémoire locale nettoyée. Session Microsoft Graph toujours active." -ForegroundColor Magenta
