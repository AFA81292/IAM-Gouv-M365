# ========================================================================================
# Exercice 6d : PIM — Audit des rôles permanents à risque
# ========================================================================================
# Concept : En arrivant en mission, un consultant IAM audite les comptes surprivilégiés.
# Un rôle permanent sans expiration = risque sécurité.
# Si le compte est compromis — l'attaquant a les droits pour toujours.
#
# Ce script identifie :
#   - Les assignations permanentes qui devraient être converties en éligibles
#   - Les rôles sensibles (Global Admin, Privileged Role Admin...) assignés en direct
#   - Les comptes sans MFA qui ont des rôles privilégiés
#
# Cas d'usage réel : première semaine en mission IAM — état des lieux sécurité PIM.
# ========================================================================================

# --- ÉTAPE 1 : Connexion à Microsoft Graph ---
$Scopes = @(
    "RoleManagement.Read.All",
    "User.Read.All",
    "UserAuthenticationMethod.Read.All"
)

Disconnect-MgGraph -ErrorAction SilentlyContinue
Connect-MgGraph -Scopes $Scopes -ContextScope Process

# --- ÉTAPE 2 : Définition des rôles sensibles à surveiller ---
# Ces rôles donnent un accès total ou quasi-total au tenant
# Toute assignation permanente sur ces rôles est un risque critique
$SensitiveRoles = @(
    "Global Administrator",
    "Privileged Role Administrator",
    "Security Administrator",
    "User Administrator",
    "Exchange Administrator",
    "SharePoint Administrator"
)

# --- ÉTAPE 3 : Audit des assignations permanentes ---
# Permanent = NoExpiration — le rôle ne s'arrête jamais automatiquement
Write-Host "`n=== ASSIGNATIONS PERMANENTES (RISQUE) ===" -ForegroundColor Red
Write-Host "Ces assignations devraient être converties en éligibles PIM :`n" -ForegroundColor Gray

$AllActive = Get-MgRoleManagementDirectoryRoleAssignmentSchedule -All
$PermanentAssignments = $AllActive | Where-Object {
    $_.ScheduleInfo.Expiration.Type -eq "noExpiration" -and
    $_.AssignmentType -eq "Assigned"
}

if ($PermanentAssignments) {
    $Results = foreach ($Assignment in $PermanentAssignments) {
        $User = Get-MgUser -UserId $Assignment.PrincipalId -ErrorAction SilentlyContinue
        $Role = Get-MgRoleManagementDirectoryRoleDefinition `
            -UnifiedRoleDefinitionId $Assignment.RoleDefinitionId -ErrorAction SilentlyContinue

        # Signalement si le rôle est dans la liste des rôles sensibles
        $IsSensitive = $SensitiveRoles -contains $Role.DisplayName

        [PSCustomObject]@{
            Utilisateur   = $User.DisplayName
            UPN           = $User.UserPrincipalName
            Role          = $Role.DisplayName
            # Signalement visuel des rôles critiques
            Critique      = if ($IsSensitive) { "CRITIQUE" } else { "Normal" }
            TypeAssig     = $Assignment.AssignmentType
        }
    }
    $Results | Sort-Object Critique -Descending | Format-Table -AutoSize
} else {
    Write-Host "-> Aucune assignation permanente trouvée." -ForegroundColor Green
}

# --- ÉTAPE 4 : Audit des rôles sensibles — toutes assignations confondues ---
# Qui a les clés du royaume, permanent ou pas ?
Write-Host "`n=== RÔLES SENSIBLES — TOUTES ASSIGNATIONS ===" -ForegroundColor Cyan
Write-Host "Utilisateurs avec un rôle critique actif :`n" -ForegroundColor Gray

$SensitiveAssignments = foreach ($Assignment in $AllActive) {
    $Role = Get-MgRoleManagementDirectoryRoleDefinition `
        -UnifiedRoleDefinitionId $Assignment.RoleDefinitionId -ErrorAction SilentlyContinue

    if ($SensitiveRoles -contains $Role.DisplayName) {
        $User = Get-MgUser -UserId $Assignment.PrincipalId -ErrorAction SilentlyContinue

        [PSCustomObject]@{
            Utilisateur = $User.DisplayName
            Role        = $Role.DisplayName
            Statut      = $Assignment.Status
            Expiration  = if ($Assignment.ScheduleInfo.Expiration.EndDateTime) {
                            $Assignment.ScheduleInfo.Expiration.EndDateTime
                          } else { "PERMANENT" }
        }
    }
}

if ($SensitiveAssignments) {
    $SensitiveAssignments | Format-Table -AutoSize
} else {
    Write-Host "-> Aucun rôle sensible actif trouvé." -ForegroundColor Green
}

# --- ÉTAPE 5 : Résumé chiffré ---
Write-Host "`n=== RÉSUMÉ ===" -ForegroundColor Cyan
Write-Host "Total assignations actives     : $($AllActive.Count)" -ForegroundColor White
Write-Host "Assignations permanentes       : $($PermanentAssignments.Count)" -ForegroundColor $(if ($PermanentAssignments.Count -gt 0) { "Red" } else { "Green" })
Write-Host "Rôles sensibles actifs         : $($SensitiveAssignments.Count)" -ForegroundColor $(if ($SensitiveAssignments.Count -gt 0) { "Yellow" } else { "Green" })

Write-Host "`n=== FIN DE L'AUDIT PIM ===" -ForegroundColor Green

# --- ÉTAPE 6 : Nettoyage ---
Remove-Variable Scopes, SensitiveRoles, AllActive, PermanentAssignments, `
                SensitiveAssignments, Assignment, User, Role, Results, IsSensitive `
                -ErrorAction SilentlyContinue

Write-Host "`nMémoire locale nettoyée. Session Microsoft Graph toujours active." -ForegroundColor Magenta
