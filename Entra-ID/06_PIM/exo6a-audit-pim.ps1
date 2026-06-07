# ========================================================================================
# Exercice 6a : PIM — Audit des assignations et rôles privilégiés
# ========================================================================================
# Concept : PIM (Privileged Identity Management) gouverne les accès privilégiés.
# Au lieu d'assigner un rôle en permanence, PIM permet deux modes :
#
#   Eligible  = l'utilisateur PEUT activer le rôle quand il en a besoin
#               Il doit justifier, valider le MFA, et le rôle expire automatiquement
#
#   Active    = le rôle est actif immédiatement, avec ou sans durée limitée
#               Permanent = toujours actif (break-glass, comptes de service)
#               Time-bound = actif pour une durée définie, puis révoqué automatiquement
#
# Principe : least privilege appliqué aux admins — personne n'a de droits
# permanents inutiles. On active uniquement quand nécessaire.
#
# Cas d'usage réel : audit de qui a quels droits privilégiés sur le tenant,
# détection d'assignations permanentes qui devraient être éligibles.
# ========================================================================================

# --- ÉTAPE 1 : Connexion à Microsoft Graph ---
# RoleManagement.Read.All suffit pour l'audit — lecture seule
# -ContextScope Process : bypasse le cache WAM
$Scopes = @(
    "RoleManagement.Read.All",
    "User.Read.All"
)

Disconnect-MgGraph -ErrorAction SilentlyContinue
Connect-MgGraph -Scopes $Scopes -ContextScope Process

# --- ÉTAPE 2 : Audit des assignations ELIGIBLES ---
# Eligible = l'utilisateur peut activer le rôle mais ne l'a pas encore fait
# C'est le mode recommandé pour les admins — accès sur demande, pas permanent
Write-Host "`n=== ASSIGNATIONS ELIGIBLES ===" -ForegroundColor Cyan
Write-Host "Utilisateurs pouvant activer un rôle privilégié sur demande :`n" -ForegroundColor Gray

$EligibleAssignments = Get-MgRoleManagementDirectoryRoleEligibilitySchedule -All

if ($EligibleAssignments) {
    foreach ($Assignment in $EligibleAssignments) {
        # Résolution du nom de l'utilisateur depuis son ID
        $User = Get-MgUser -UserId $Assignment.PrincipalId -ErrorAction SilentlyContinue
        # Résolution du nom du rôle depuis son ID
        $Role = Get-MgRoleManagementDirectoryRoleDefinition -UnifiedRoleDefinitionId $Assignment.RoleDefinitionId -ErrorAction SilentlyContinue

        [PSCustomObject]@{
            Utilisateur   = $User.DisplayName
            Role          = $Role.DisplayName
            # MemberType : Direct = assigné directement / Group = via un groupe
            TypeMembre    = $Assignment.MemberType
            # ScheduleInfo contient les dates de début et fin — null = permanent
            Expiration    = if ($Assignment.ScheduleInfo.Expiration.EndDateTime) { $Assignment.ScheduleInfo.Expiration.EndDateTime } else { "Permanent" }
        }
    }
} else {
    Write-Host "-> Aucune assignation éligible trouvée." -ForegroundColor Yellow
}

# --- ÉTAPE 3 : Audit des assignations ACTIVES ---
# Active = le rôle est actif maintenant
# Permanent sans PIM = risque sécurité — à identifier et convertir en éligible
Write-Host "`n=== ASSIGNATIONS ACTIVES ===" -ForegroundColor Cyan
Write-Host "Utilisateurs avec un rôle privilégié actif en ce moment :`n" -ForegroundColor Gray

$ActiveAssignments = Get-MgRoleManagementDirectoryRoleAssignmentSchedule -All

if ($ActiveAssignments) {
    foreach ($Assignment in $ActiveAssignments) {
        $User = Get-MgUser -UserId $Assignment.PrincipalId -ErrorAction SilentlyContinue
        $Role = Get-MgRoleManagementDirectoryRoleDefinition -UnifiedRoleDefinitionId $Assignment.RoleDefinitionId -ErrorAction SilentlyContinue

        [PSCustomObject]@{
            Utilisateur = $User.DisplayName
            Role        = $Role.DisplayName
            Statut      = $Assignment.Status
            # AssignmentType : Assigned = permanent / Activated = activé via PIM
            TypeAssig   = $Assignment.AssignmentType
            Expiration  = if ($Assignment.ScheduleInfo.Expiration.EndDateTime) { $Assignment.ScheduleInfo.Expiration.EndDateTime } else { "Permanent" }
        }
    }
} else {
    Write-Host "-> Aucune assignation active trouvée." -ForegroundColor Yellow
}

# --- ÉTAPE 4 : Audit des demandes d'activation en cours ---
# Demandes soumises par des utilisateurs éligibles qui veulent activer leur rôle
# Utile pour un admin PIM qui veut voir les activations en cours ou en attente
Write-Host "`n=== DEMANDES D'ACTIVATION EN COURS ===" -ForegroundColor Cyan

$PendingRequests = Get-MgRoleManagementDirectoryRoleAssignmentScheduleRequest `
    -All | Where-Object { $_.Status -eq "PendingApproval" }

if ($PendingRequests) {
    foreach ($Request in $PendingRequests) {
        $User = Get-MgUser -UserId $Request.PrincipalId -ErrorAction SilentlyContinue
        $Role = Get-MgRoleManagementDirectoryRoleDefinition -UnifiedRoleDefinitionId $Request.RoleDefinitionId -ErrorAction SilentlyContinue

        [PSCustomObject]@{
            Utilisateur   = $User.DisplayName
            Role          = $Role.DisplayName
            Action        = $Request.Action
            Statut        = $Request.Status
            Justification = $Request.Justification
        }
    }
} else {
    Write-Host "-> Aucune demande en attente." -ForegroundColor Yellow
}

Write-Host "`n=== FIN DE L'AUDIT PIM ===" -ForegroundColor Green

# --- ÉTAPE 5 : Nettoyage ---
Remove-Variable Scopes, EligibleAssignments, ActiveAssignments, PendingRequests, `
                Assignment, User, Role, Request -ErrorAction SilentlyContinue

Write-Host "`nMémoire locale nettoyée. Session Microsoft Graph toujours active." -ForegroundColor Magenta
