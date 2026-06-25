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
#   5. Exporte les trois jeux de données en CSV horodatés
#   6. Ferme proprement toutes les sessions
#
# Cas d'usage réel : un consultant IAM arrive en mission et veut identifier :
#   - Qui peut activer quels rôles (éligibles)
#   - Qui a des rôles actifs en ce moment (actifs permanents vs activés via PIM)
#   - Quelles demandes d'activation sont en attente de validation
#   Le tout exporté en CSV pour transmission au RSSI ou archivage d'audit.
#
# AssignmentType sur les actives :
#   "Assigned"  = assignation permanente hors PIM — risque sécurité à identifier
#                 et convertir en éligible
#   "Activated" = activé via PIM par un utilisateur éligible — comportement attendu
#
# Fichiers CSV générés :
#   PIM_Eligibles_YYYYMMDD_HHmmss.csv
#   PIM_Actives_YYYYMMDD_HHmmss.csv
#   PIM_DemandesEnAttente_YYYYMMDD_HHmmss.csv
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

# On construit les objets normalisés dans une collection réutilisable pour le CSV.
# Évite de parcourir $EligibleAssignments deux fois (console + export).
$EligibleRows = @()

if ($EligibleAssignments) {
    foreach ($Assignment in $EligibleAssignments) {
        # PrincipalId et RoleDefinitionId sont des GUIDs — on résout en noms lisibles.
        # -ErrorAction SilentlyContinue : certains principals peuvent être des groupes
        # ou des service principals, pas des users — Get-MgUser retourne $null dans ce cas.
        $User = Get-MgUser -UserId $Assignment.PrincipalId -ErrorAction SilentlyContinue
        $Role = Get-MgRoleManagementDirectoryRoleDefinition `
            -UnifiedRoleDefinitionId $Assignment.RoleDefinitionId `
            -ErrorAction SilentlyContinue

        $Row = [PSCustomObject]@{
            Utilisateur   = if ($User) { $User.DisplayName } else { $Assignment.PrincipalId }
            PrincipalId   = $Assignment.PrincipalId
            Role          = if ($Role) { $Role.DisplayName } else { $Assignment.RoleDefinitionId }
            RoleDefinitionId = $Assignment.RoleDefinitionId
            # MemberType :
            #   "Direct" = assignation directe à l'utilisateur
            #   "Group"  = assignation via un groupe — l'utilisateur hérite de l'éligibilité
            TypeMembre    = $Assignment.MemberType
            # ScheduleInfo.Expiration.EndDateTime = null → éligibilité sans limite de durée.
            # Une éligibilité permanente est acceptable (vs une activation permanente = risque).
            Expiration    = if ($Assignment.ScheduleInfo.Expiration.EndDateTime) {
                                $Assignment.ScheduleInfo.Expiration.EndDateTime
                            } else { "Permanent" }
        }
        $EligibleRows += $Row
        $Row | Select-Object Utilisateur, Role, TypeMembre, Expiration
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

$ActiveRows = @()

if ($ActiveAssignments) {
    foreach ($Assignment in $ActiveAssignments) {
        $User = Get-MgUser -UserId $Assignment.PrincipalId -ErrorAction SilentlyContinue
        $Role = Get-MgRoleManagementDirectoryRoleDefinition `
            -UnifiedRoleDefinitionId $Assignment.RoleDefinitionId `
            -ErrorAction SilentlyContinue

        $Row = [PSCustomObject]@{
            Utilisateur      = if ($User) { $User.DisplayName } else { $Assignment.PrincipalId }
            PrincipalId      = $Assignment.PrincipalId
            Role             = if ($Role) { $Role.DisplayName } else { $Assignment.RoleDefinitionId }
            RoleDefinitionId = $Assignment.RoleDefinitionId
            Statut           = $Assignment.Status
            # AssignmentType — point d'attention audit :
            #   "Assigned"  = rôle permanent assigné hors PIM → à convertir en éligible
            #   "Activated" = activé via PIM par un utilisateur éligible → comportement attendu
            TypeAssig        = $Assignment.AssignmentType
            Expiration       = if ($Assignment.ScheduleInfo.Expiration.EndDateTime) {
                                   $Assignment.ScheduleInfo.Expiration.EndDateTime
                               } else { "Permanent" }
        }
        $ActiveRows += $Row
        $Row | Select-Object Utilisateur, Role, Statut, TypeAssig, Expiration
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
# On filtre sur "PendingApproval" — demandes soumises, pas encore validées.
$PendingRequests = Get-MgRoleManagementDirectoryRoleAssignmentScheduleRequest `
    -All | Where-Object { $_.Status -eq "PendingApproval" }

$PendingRows = @()

if ($PendingRequests) {
    foreach ($Request in $PendingRequests) {
        $User = Get-MgUser -UserId $Request.PrincipalId -ErrorAction SilentlyContinue
        $Role = Get-MgRoleManagementDirectoryRoleDefinition `
            -UnifiedRoleDefinitionId $Request.RoleDefinitionId `
            -ErrorAction SilentlyContinue

        $Row = [PSCustomObject]@{
            Utilisateur      = if ($User) { $User.DisplayName } else { $Request.PrincipalId }
            PrincipalId      = $Request.PrincipalId
            Role             = if ($Role) { $Role.DisplayName } else { $Request.RoleDefinitionId }
            RoleDefinitionId = $Request.RoleDefinitionId
            # Action :
            #   "SelfActivate"   = l'utilisateur active son propre rôle éligible
            #   "AdminAssign"    = un admin assigne le rôle directement
            #   "SelfDeactivate" = l'utilisateur désactive son rôle avant expiration
            Action           = $Request.Action
            Statut           = $Request.Status
            # Justification = texte saisi par l'utilisateur à l'activation — loggé en audit.
            # Colonne particulièrement utile pour les audits de conformité.
            Justification    = $Request.Justification
        }
        $PendingRows += $Row
        $Row | Select-Object Utilisateur, Role, Action, Statut, Justification
    }
} else {
    Write-Host "-> Aucune demande en attente d'approbation." -ForegroundColor Yellow
}

# ========================================================================================
# RÉSUMÉ
# ========================================================================================
Write-Host "`n=== RÉSUMÉ ===" -ForegroundColor Magenta
[PSCustomObject]@{
    AssignationsEligibles = $EligibleRows.Count
    AssignationsActives   = $ActiveRows.Count
    DemandesEnAttente     = $PendingRows.Count
    Scope                 = "RoleManagement.Read.All (lecture seule)"
    PointAttentionAudit   = "AssignmentType 'Assigned' sur les actives = permanent hors PIM — à convertir en éligible"
} | Format-List

Write-Host "=== FIN DE L'AUDIT PIM ===" -ForegroundColor Green

# ========================================================================================
# EXPORT CSV
# ========================================================================================
Write-Host "Export CSV en cours..." -ForegroundColor Cyan

# EN LABO / Local :
$ExportPath = "D:\Documents\ScriptsPowerShell\Exports\"
# EN PRODUCTION :
# $ExportPath = "$PSScriptRoot\Exports\"

New-Item -ItemType Directory -Force -Path $ExportPath | Out-Null
$Timestamp = Get-Date -Format "yyyyMMdd_HHmmss"

# --- CSV 1 : Assignations éligibles ---
# Colonnes exportées : Utilisateur, PrincipalId, Role, RoleDefinitionId, TypeMembre, Expiration
# Colonnes disponibles non exportées :
#   $Assignment.DirectoryScopeId  : périmètre de l'assignation (tenant-wide = "/")
#   $Assignment.AppScopeId        : périmètre applicatif si scopé à une app
#   $Assignment.CreatedDateTime   : date de création de l'assignation éligible
if ($EligibleRows.Count -gt 0) {
    $EligibleRows | Export-Csv `
        -Path "$ExportPath\PIM_Eligibles_$Timestamp.csv" `
        -Encoding UTF8 -NoTypeInformation
    Write-Host "-> Éligibles : $($EligibleRows.Count) ligne(s) — PIM_Eligibles_$Timestamp.csv" -ForegroundColor Green
} else {
    Write-Host "-> Éligibles : aucune donnée à exporter." -ForegroundColor Yellow
}

# --- CSV 2 : Assignations actives ---
# Colonnes exportées : Utilisateur, PrincipalId, Role, RoleDefinitionId, Statut, TypeAssig, Expiration
# Colonnes disponibles non exportées :
#   $Assignment.DirectoryScopeId  : périmètre de l'assignation
#   $Assignment.StartDateTime     : date d'activation effective du rôle
#
# Point d'attention à l'analyse : filtrer sur TypeAssig = "Assigned" + Expiration = "Permanent"
# pour identifier les comptes à risque (droits permanents hors PIM).
if ($ActiveRows.Count -gt 0) {
    $ActiveRows | Export-Csv `
        -Path "$ExportPath\PIM_Actives_$Timestamp.csv" `
        -Encoding UTF8 -NoTypeInformation
    Write-Host "-> Actives : $($ActiveRows.Count) ligne(s) — PIM_Actives_$Timestamp.csv" -ForegroundColor Green
} else {
    Write-Host "-> Actives : aucune donnée à exporter." -ForegroundColor Yellow
}

# --- CSV 3 : Demandes en attente ---
# Colonnes exportées : Utilisateur, PrincipalId, Role, RoleDefinitionId,
#                      Action, Statut, Justification
# Colonnes disponibles non exportées :
#   $Request.CreatedDateTime   : date de soumission de la demande
#   $Request.CompletedDateTime : date de traitement (null si encore en attente)
#   $Request.ScheduleInfo      : durée demandée pour l'activation
#
# La colonne Justification est particulièrement utile pour les audits de conformité —
# elle trace le motif déclaré par l'utilisateur pour chaque activation.
if ($PendingRows.Count -gt 0) {
    $PendingRows | Export-Csv `
        -Path "$ExportPath\PIM_DemandesEnAttente_$Timestamp.csv" `
        -Encoding UTF8 -NoTypeInformation
    Write-Host "-> Demandes en attente : $($PendingRows.Count) ligne(s) — PIM_DemandesEnAttente_$Timestamp.csv" -ForegroundColor Green
} else {
    Write-Host "-> Demandes en attente : aucune donnée à exporter." -ForegroundColor Yellow
}

Write-Host "-> Export terminé dans : $ExportPath`n" -ForegroundColor Green

# ========================================================================================
# NETTOYAGE MÉMOIRE
# ========================================================================================
Remove-Variable Scopes, EligibleAssignments, ActiveAssignments, PendingRequests,
                EligibleRows, ActiveRows, PendingRows,
                Assignment, User, Role, Row, Request,
                ExportPath, Timestamp `
                -ErrorAction SilentlyContinue

# ========================================================================================
# FERMETURE — RESET DE SESSION TOTAL
# ========================================================================================
Disconnect-MgGraph -ErrorAction SilentlyContinue
Write-Host "Session MgGraph fermée proprement." -ForegroundColor Magenta
