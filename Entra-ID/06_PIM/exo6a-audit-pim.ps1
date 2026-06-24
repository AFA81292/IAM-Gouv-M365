# ========================================================================================
# Exercice 6a : Entra ID — PIM — Audit des assignations et rôles privilégiés
# ========================================================================================
# Concept : PIM (Privileged Identity Management) gouverne les accès privilégiés.
# Au lieu d'assigner un rôle en permanence, PIM permet deux modes :
#
#   Eligible  = l'utilisateur PEUT activer le rôle quand il en a besoin.
#               Il doit justifier, valider le MFA — le rôle expire automatiquement.
#               C'est le mode recommandé pour tous les admins en production.
#
#   Active    = le rôle est actif immédiatement.
#               Permanent   = toujours actif (break-glass, comptes de service).
#               Time-bound  = actif pour une durée définie, révoqué automatiquement.
#
# Principe fondamental : least privilege appliqué aux identités privilégiées.
# Personne ne détient de droits Admin permanents inutiles — on active uniquement
# quand nécessaire, pour la durée nécessaire, avec justification.
#
# Ce que fait ce script :
#   1. Reset total de session
#   2. Audite les assignations ELIGIBLES (rôle disponible, pas encore activé)
#   3. Audite les assignations ACTIVES (rôle actif en ce moment)
#   4. Audite les demandes d'activation en attente d'approbation
#   5. Ferme proprement toutes les sessions
#
# Cas d'usage réel : un consultant IAM arrive en mission et veut identifier :
#   - Qui peut activer quels rôles (éligibles)
#   - Qui a des rôles actifs en ce moment (actifs permanents vs activés via PIM)
#   - Quelles demandes d'activation sont en attente de validation
#
# AssignmentType sur les actives :
#   "Assigned"  = assignation permanente hors PIM — risque sécurité à identifier
#                 et convertir en éligible
#   "Activated" = activé via PIM par un utilisateur éligible — comportement attendu
#
# Module requis : Microsoft.Graph.Identity.Governance, Microsoft.Graph.Users
# Connexion     : Connect-MgGraph
# ========================================================================================

# --- OUVERTURE — RESET DE SESSION TOTAL ---
# RoleManagement.Read.All : lire les assignations PIM (éligibles, actives, demandes)
# User.Read.All : résoudre les PrincipalId (GUID) en DisplayName lisibles
# -ContextScope Process : bypasse le cache WAM — voir REX exercices 5b/5c.
$Scopes = @(
    "RoleManagement.Read.All",
    "User.Read.All"
)

Disconnect-MgGraph -ErrorAction SilentlyContinue
Connect-MgGraph -Scopes $Scopes -ContextScope Process -NoWelcome

# ========================================================================================
# ÉTAPE 1 : Audit des assignations ELIGIBLES
# ========================================================================================
Write-Host "`n=== ASSIGNATIONS ELIGIBLES ===" -ForegroundColor Cyan
Write-Host "Utilisateurs pouvant activer un rôle privilégié sur demande :`n" -ForegroundColor Gray

# Get-MgRoleManagementDirectoryRoleEligibilitySchedule retourne toutes les assignations
# éligibles du tenant — utilisateurs qui ONT le droit d'activer un rôle via PIM,
# mais dont le rôle n'est pas encore actif.
$EligibleAssignments = Get-MgRoleManagementDirectoryRoleEligibilitySchedule -All

if ($EligibleAssignments) {
    foreach ($Assignment in $EligibleAssignments) {
        # PrincipalId et RoleDefinitionId sont des GUIDs — on résout en noms lisibles.
        # -ErrorAction SilentlyContinue : certains principals peuvent être des groupes
        # ou des service principals, pas des users — Get-MgUser retourne $null dans ce cas.
        $User = Get-MgUser -UserId $Assignment.PrincipalId -ErrorAction SilentlyContinue
        $Role = Get-MgRoleManagementDirectoryRoleDefinition `
            -UnifiedRoleDefinitionId $Assignment.RoleDefinitionId `
            -ErrorAction SilentlyContinue

        [PSCustomObject]@{
            Utilisateur = if ($User) { $User.DisplayName } else { $Assignment.PrincipalId }
            Role        = if ($Role) { $Role.DisplayName } else { $Assignment.RoleDefinitionId }
            # MemberType :
            #   "Direct" = assignation directe à l'utilisateur
            #   "Group"  = assignation via un groupe — l'utilisateur hérite de l'éligibilité
            TypeMembre  = $Assignment.MemberType
            # ScheduleInfo.Expiration.EndDateTime = null → assignation éligible sans limite
            # Une éligibilité permanente est acceptable (vs une activation permanente qui est un risque)
            Expiration  = if ($Assignment.ScheduleInfo.Expiration.EndDateTime) {
                              $Assignment.ScheduleInfo.Expiration.EndDateTime
                          } else { "Permanent" }
        }
    }
} else {
    Write-Host "-> Aucune assignation éligible trouvée." -ForegroundColor Yellow
}

# ========================================================================================
# ÉTAPE 2 : Audit des assignations ACTIVES
# ========================================================================================
Write-Host "`n=== ASSIGNATIONS ACTIVES ===" -ForegroundColor Cyan
Write-Host "Utilisateurs avec un rôle privilégié actif en ce moment :`n" -ForegroundColor Gray

# Get-MgRoleManagementDirectoryRoleAssignmentSchedule retourne toutes les assignations
# actives — rôles effectivement en vigueur sur le tenant à cet instant.
$ActiveAssignments = Get-MgRoleManagementDirectoryRoleAssignmentSchedule -All

if ($ActiveAssignments) {
    foreach ($Assignment in $ActiveAssignments) {
        $User = Get-MgUser -UserId $Assignment.PrincipalId -ErrorAction SilentlyContinue
        $Role = Get-MgRoleManagementDirectoryRoleDefinition `
            -UnifiedRoleDefinitionId $Assignment.RoleDefinitionId `
            -ErrorAction SilentlyContinue

        [PSCustomObject]@{
            Utilisateur = if ($User) { $User.DisplayName } else { $Assignment.PrincipalId }
            Role        = if ($Role) { $Role.DisplayName } else { $Assignment.RoleDefinitionId }
            Statut      = $Assignment.Status
            # AssignmentType — point d'attention audit :
            #   "Assigned"  = rôle permanent assigné hors PIM (ou via PIM en mode permanent)
            #                 → à identifier et convertir en éligible si possible
            #   "Activated" = activé via PIM par un utilisateur éligible
            #                 → comportement attendu, durée limitée
            TypeAssig   = $Assignment.AssignmentType
            Expiration  = if ($Assignment.ScheduleInfo.Expiration.EndDateTime) {
                              $Assignment.ScheduleInfo.Expiration.EndDateTime
                          } else { "Permanent" }
        }
    }
} else {
    Write-Host "-> Aucune assignation active trouvée." -ForegroundColor Yellow
}

# ========================================================================================
# ÉTAPE 3 : Audit des demandes d'activation en attente
# ========================================================================================
Write-Host "`n=== DEMANDES D'ACTIVATION EN COURS ===" -ForegroundColor Cyan

# Get-MgRoleManagementDirectoryRoleAssignmentScheduleRequest retourne l'historique
# de toutes les demandes PIM (approuvées, refusées, en attente).
# On filtre sur "PendingApproval" — demandes soumises, pas encore validées par un approbateur.
#
# Cas d'usage : un admin PIM ou un approbateur désigné veut traiter les demandes
# en attente sans passer par le portail My Access ou Entra Admin Center.
$PendingRequests = Get-MgRoleManagementDirectoryRoleAssignmentScheduleRequest `
    -All | Where-Object { $_.Status -eq "PendingApproval" }

if ($PendingRequests) {
    foreach ($Request in $PendingRequests) {
        $User = Get-MgUser -UserId $Request.PrincipalId -ErrorAction SilentlyContinue
        $Role = Get-MgRoleManagementDirectoryRoleDefinition `
            -UnifiedRoleDefinitionId $Request.RoleDefinitionId `
            -ErrorAction SilentlyContinue

        [PSCustomObject]@{
            Utilisateur   = if ($User) { $User.DisplayName } else { $Request.PrincipalId }
            Role          = if ($Role) { $Role.DisplayName } else { $Request.RoleDefinitionId }
            # Action :
            #   "SelfActivate"   = l'utilisateur active son propre rôle éligible
            #   "AdminAssign"    = un admin assigne le rôle directement
            #   "SelfDeactivate" = l'utilisateur désactive son rôle avant expiration
            Action        = $Request.Action
            Statut        = $Request.Status
            # Justification = texte saisi par l'utilisateur à l'activation — loggé en audit
            Justification = $Request.Justification
        }
    }
} else {
    Write-Host "-> Aucune demande en attente d'approbation." -ForegroundColor Yellow
}

# ========================================================================================
# RÉSUMÉ
# ========================================================================================
Write-Host "`n=== RÉSUMÉ ===" -ForegroundColor Magenta
[PSCustomObject]@{
    AssignationsEligibles = if ($EligibleAssignments) { $EligibleAssignments.Count } else { 0 }
    AssignationsActives   = if ($ActiveAssignments)   { $ActiveAssignments.Count   } else { 0 }
    DemandesEnAttente     = if ($PendingRequests)     { $PendingRequests.Count     } else { 0 }
    Scope                 = "RoleManagement.Read.All (lecture seule)"
    PointAttentionAudit   = "AssignmentType 'Assigned' sur les actives = permanent hors PIM — à convertir en éligible"
} | Format-List

Write-Host "=== FIN DE L'AUDIT PIM ===" -ForegroundColor Green

# ========================================================================================
# NETTOYAGE MÉMOIRE
# ========================================================================================
Remove-Variable Scopes, EligibleAssignments, ActiveAssignments, PendingRequests,
                Assignment, User, Role, Request `
                -ErrorAction SilentlyContinue

# ========================================================================================
# FERMETURE — RESET DE SESSION TOTAL
# ========================================================================================
Disconnect-MgGraph -ErrorAction SilentlyContinue
Write-Host "Session MgGraph fermée proprement." -ForegroundColor Magenta
