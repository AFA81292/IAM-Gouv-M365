# ========================================================================================
# Exercice 6d : Entra ID — PIM — Audit des rôles permanents à risque
# ========================================================================================
# Concept : En arrivant en mission, un consultant IAM audite les comptes surprivilégiés.
# Un rôle permanent sans expiration = risque sécurité.
# Si le compte est compromis, l'attaquant dispose des droits indéfiniment.
#
# Ce script identifie :
#   - Les assignations permanentes à convertir en éligibles PIM
#   - Les rôles sensibles (Global Admin, Privileged Role Admin...) assignés en direct
#   - Le niveau de criticité de chaque assignation
#
# Cas d'usage réel : première semaine en mission IAM — état des lieux sécurité PIM,
# avec export CSV pour transmission au RSSI ou archivage d'audit.
#
# Delta pédagogique vs 6a :
#   6a → audit global : éligibles + actives + demandes en attente (vue exhaustive)
#   6d → audit ciblé sécurité : focus sur les assignations permanentes à risque
#        et les rôles sensibles, avec signalement visuel "CRITIQUE"
#
# Ce que fait ce script :
#   1. Reset total de session
#   2. Définit la liste des rôles sensibles à surveiller
#   3. Audite les assignations permanentes (Type "noExpiration" + AssignmentType "Assigned")
#   4. Audite tous les détenteurs de rôles sensibles (permanent ou non)
#   5. Affiche un résumé chiffré
#   6. Exporte les deux jeux de données en CSV horodatés
#   7. Ferme proprement toutes les sessions
#
# Note : ce script est en lecture seule — aucune modification du tenant.
#
# Fichiers CSV générés :
#   PIM_Permanents_YYYYMMDD_HHmmss.csv
#   PIM_RolesSensibles_YYYYMMDD_HHmmss.csv
#
# Module requis : Microsoft.Graph.Identity.Governance, Microsoft.Graph.Users
# Connexion     : Connect-MgGraph
# ========================================================================================

# --- OUVERTURE — RESET DE SESSION TOTAL ---
# RoleManagement.Read.All  : lire les assignations PIM actives
# User.Read.All            : résoudre les PrincipalId (GUID) en DisplayName/UPN lisibles
# -ContextScope Process    : bypasse le cache WAM — voir REX exercices 5b/5c.
$Scopes = @(
    "RoleManagement.Read.All",
    "User.Read.All"
)

Disconnect-MgGraph -ErrorAction SilentlyContinue
Connect-MgGraph -Scopes $Scopes -ContextScope Process -NoWelcome

# ========================================================================================
# ÉTAPE 1 : Définition des rôles sensibles à surveiller
# ========================================================================================
Write-Host "1. Définition des rôles sensibles..." -ForegroundColor Cyan

# Ces rôles donnent un accès total ou quasi-total au tenant.
# Toute assignation permanente ("Assigned" + "noExpiration") sur ces rôles
# est considérée comme un risque critique à documenter et à corriger.
#
# Bonne pratique PIM :
#   → Aucun de ces rôles ne devrait être "Assigned" permanent en production.
#   → Convertir en "Eligible" : l'utilisateur active uniquement quand nécessaire,
#     avec justification, durée limitée, et traçabilité dans l'audit PIM.
$SensitiveRoles = @(
    "Global Administrator",
    "Privileged Role Administrator",
    "Security Administrator",
    "User Administrator",
    "Exchange Administrator",
    "SharePoint Administrator"
)

Write-Host "-> $($SensitiveRoles.Count) rôles sensibles définis.`n" -ForegroundColor Green

# ========================================================================================
# ÉTAPE 2 : Récupération de toutes les assignations actives
# ========================================================================================
Write-Host "2. Récupération des assignations actives..." -ForegroundColor Cyan

# Get-MgRoleManagementDirectoryRoleAssignmentSchedule -All retourne l'ensemble
# des assignations de rôles effectivement actives sur le tenant à cet instant.
# C'est la même cmdlet que dans 6a — ici on la filtre différemment.
$AllActive = Get-MgRoleManagementDirectoryRoleAssignmentSchedule -All
Write-Host "-> $($AllActive.Count) assignations actives récupérées.`n" -ForegroundColor Green

# ========================================================================================
# ÉTAPE 3 : Audit des assignations permanentes (risque sécurité)
# ========================================================================================
Write-Host "3. Audit des assignations permanentes..." -ForegroundColor Cyan
Write-Host "`n=== ASSIGNATIONS PERMANENTES (RISQUE) ===" -ForegroundColor Red
Write-Host "Ces assignations devraient être converties en éligibles PIM :`n" -ForegroundColor Gray

# Double filtre :
#   ScheduleInfo.Expiration.Type -eq "noExpiration" → pas de date de fin définie
#   AssignmentType -eq "Assigned"                   → assignation directe hors activation PIM
#
# Pourquoi ce double filtre ?
#   Une activation PIM time-bound a AssignmentType "Activated" — elle expire.
#   On cible uniquement les "Assigned" permanents qui ne passeront jamais
#   par le flux d'activation/justification PIM.
$PermanentAssignments = $AllActive | Where-Object {
    $_.ScheduleInfo.Expiration.Type -eq "noExpiration" -and
    $_.AssignmentType -eq "Assigned"
}

# On construit les objets normalisés dans une collection réutilisable pour le CSV.
$PermanentRows = @()

if ($PermanentAssignments) {
    foreach ($Assignment in $PermanentAssignments) {
        $User = Get-MgUser -UserId $Assignment.PrincipalId -ErrorAction SilentlyContinue
        $Role = Get-MgRoleManagementDirectoryRoleDefinition `
            -UnifiedRoleDefinitionId $Assignment.RoleDefinitionId -ErrorAction SilentlyContinue

        # Signalement visuel : "CRITIQUE" si le rôle figure dans la liste des rôles sensibles.
        $IsSensitive = $SensitiveRoles -contains $Role.DisplayName

        $Row = [PSCustomObject]@{
            Utilisateur      = if ($User) { $User.DisplayName }       else { $Assignment.PrincipalId }
            UPN              = if ($User) { $User.UserPrincipalName }  else { "Non résolu" }
            PrincipalId      = $Assignment.PrincipalId
            Role             = if ($Role) { $Role.DisplayName }       else { $Assignment.RoleDefinitionId }
            RoleDefinitionId = $Assignment.RoleDefinitionId
            # "CRITIQUE" → rôle dans la liste des rôles sensibles définis en étape 1
            # "Normal"   → rôle permanent mais hors liste sensible (à documenter quand même)
            Critique         = if ($IsSensitive) { "CRITIQUE" } else { "Normal" }
            TypeAssig        = $Assignment.AssignmentType
        }
        $PermanentRows += $Row
    }

    # Sort-Object Critique -Descending : les "CRITIQUE" remontent en haut de liste
    $PermanentRows | Sort-Object Critique -Descending |
        Select-Object Utilisateur, UPN, Role, Critique, TypeAssig |
        Format-Table -AutoSize
} else {
    Write-Host "-> Aucune assignation permanente trouvée." -ForegroundColor Green
}

# ========================================================================================
# ÉTAPE 4 : Audit des rôles sensibles — toutes assignations confondues
# ========================================================================================
Write-Host "`n=== RÔLES SENSIBLES — TOUTES ASSIGNATIONS ===" -ForegroundColor Cyan
Write-Host "Utilisateurs avec un rôle critique actif :`n" -ForegroundColor Gray

# Ici on ne filtre plus sur "noExpiration" — on veut voir TOUS les détenteurs
# de rôles sensibles, qu'ils soient permanents, time-bound ou activés via PIM.
# But : savoir qui a "les clés du royaume" en ce moment, quelle que soit la durée.
$SensitiveRows = @()

foreach ($Assignment in $AllActive) {
    $Role = Get-MgRoleManagementDirectoryRoleDefinition `
        -UnifiedRoleDefinitionId $Assignment.RoleDefinitionId -ErrorAction SilentlyContinue

    if ($SensitiveRoles -contains $Role.DisplayName) {
        $User = Get-MgUser -UserId $Assignment.PrincipalId -ErrorAction SilentlyContinue

        $Row = [PSCustomObject]@{
            Utilisateur      = if ($User) { $User.DisplayName }      else { $Assignment.PrincipalId }
            UPN              = if ($User) { $User.UserPrincipalName } else { "Non résolu" }
            PrincipalId      = $Assignment.PrincipalId
            Role             = if ($Role) { $Role.DisplayName }      else { $Assignment.RoleDefinitionId }
            RoleDefinitionId = $Assignment.RoleDefinitionId
            Statut           = $Assignment.Status
            TypeAssig        = $Assignment.AssignmentType
            # Expiration "PERMANENT" → assignation sans date de fin
            # Une date → time-bound (via PIM ou assignation directe temporaire)
            Expiration       = if ($Assignment.ScheduleInfo.Expiration.EndDateTime) {
                                   $Assignment.ScheduleInfo.Expiration.EndDateTime
                               } else { "PERMANENT" }
        }
        $SensitiveRows += $Row
    }
}

if ($SensitiveRows.Count -gt 0) {
    $SensitiveRows |
        Select-Object Utilisateur, UPN, Role, Statut, TypeAssig, Expiration |
        Format-Table -AutoSize
} else {
    Write-Host "-> Aucun rôle sensible actif trouvé." -ForegroundColor Green
}

# ========================================================================================
# ÉTAPE 5 : Résumé chiffré
# ========================================================================================
Write-Host "`n=== RÉSUMÉ ===" -ForegroundColor Magenta
[PSCustomObject]@{
    TotalAssignationsActives = $AllActive.Count
    AssignationsPermanentes  = $PermanentRows.Count
    RôlesSensiblesActifs     = $SensitiveRows.Count
    Scope                    = "RoleManagement.Read.All (lecture seule)"
    PointAttentionAudit      = "AssignmentType 'Assigned' + noExpiration = permanent hors PIM — à convertir en éligible"
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

# --- CSV 1 : Assignations permanentes ---
# Colonnes exportées : Utilisateur, UPN, PrincipalId, Role, RoleDefinitionId,
#                      Critique, TypeAssig
# Colonnes disponibles non exportées :
#   $Assignment.DirectoryScopeId : périmètre de l'assignation (tenant-wide = "/")
#   $Assignment.Status           : statut de l'assignation (Provisioned, etc.)
#   $Assignment.CreatedDateTime  : date de création de l'assignation
#
# Tri conseillé dans Excel : colonne Critique DESC pour prioriser les actions correctives.
if ($PermanentRows.Count -gt 0) {
    $PermanentRows | Sort-Object Critique -Descending |
        Export-Csv `
            -Path "$ExportPath\PIM_Permanents_$Timestamp.csv" `
            -Encoding UTF8 -NoTypeInformation
    Write-Host "-> Permanents : $($PermanentRows.Count) ligne(s) — PIM_Permanents_$Timestamp.csv" -ForegroundColor Green
} else {
    Write-Host "-> Permanents : aucune donnée à exporter." -ForegroundColor Yellow
}

# --- CSV 2 : Rôles sensibles actifs ---
# Colonnes exportées : Utilisateur, UPN, PrincipalId, Role, RoleDefinitionId,
#                      Statut, TypeAssig, Expiration
# Colonnes disponibles non exportées :
#   $Assignment.DirectoryScopeId : périmètre de l'assignation
#   $Assignment.StartDateTime    : date d'activation effective du rôle
#
# Ce CSV est le livrable principal pour le RSSI : qui a les clés du royaume en ce moment,
# et pour combien de temps. Filtrer sur Expiration = "PERMANENT" pour prioriser.
if ($SensitiveRows.Count -gt 0) {
    $SensitiveRows | Export-Csv `
        -Path "$ExportPath\PIM_RolesSensibles_$Timestamp.csv" `
        -Encoding UTF8 -NoTypeInformation
    Write-Host "-> Rôles sensibles : $($SensitiveRows.Count) ligne(s) — PIM_RolesSensibles_$Timestamp.csv" -ForegroundColor Green
} else {
    Write-Host "-> Rôles sensibles : aucune donnée à exporter." -ForegroundColor Yellow
}

Write-Host "-> Export terminé dans : $ExportPath`n" -ForegroundColor Green

# ========================================================================================
# NETTOYAGE MÉMOIRE
# ========================================================================================
Remove-Variable Scopes, SensitiveRoles, AllActive, PermanentAssignments,
                PermanentRows, SensitiveRows, Assignment, User, Role, Row, IsSensitive,
                ExportPath, Timestamp `
                -ErrorAction SilentlyContinue

# ========================================================================================
# FERMETURE — RESET DE SESSION TOTAL
# ========================================================================================
Disconnect-MgGraph -ErrorAction SilentlyContinue
Write-Host "Session MgGraph fermée proprement." -ForegroundColor Magenta
