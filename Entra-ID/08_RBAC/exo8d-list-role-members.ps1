# ========================================================================================
# Exercice 8d : Entra ID — RBAC — Membres d'un rôle
# ========================================================================================
# Concept : Savoir qui détient un rôle donné est l'opération de contrôle immédiate
# après toute assignation ou désassignation. C'est aussi le premier réflexe en mission :
# "qui est Global Admin sur ce tenant ?" — avant même de toucher quoi que ce soit.
#
# Un rôle Entra peut avoir des détenteurs via 3 canaux distincts :
#   1. Assignation permanente directe  → visible dans roleAssignments
#   2. PIM éligible                    → visible dans roleEligibilitySchedules
#   3. PIM active (activée ou time-bound) → visible dans roleAssignmentSchedules
#
# Ce script interroge les 3 canaux pour un rôle donné et produit une vue consolidée.
# C'est la vérification post-assignation naturelle après les exos 8b et 8c.
#
# Delta pédagogique vs exercice 6a (audit PIM global) :
#   6a → audit global PIM : toutes les éligibilités + toutes les activations du tenant,
#        toutes rôles confondus — vue exhaustive pour un état des lieux complet
#   8d → focus sur UN rôle précis, tous canaux confondus (permanent + PIM) —
#        vérification ciblée post-opération RBAC, ou contrôle rapide en début de mission
#
# Delta pédagogique vs exercice 8f (audit global des rôles) :
#   8f → tous les rôles du tenant, tous les détenteurs — inventaire complet avec export CSV
#   8d → un seul rôle, résolution complète, affichage immédiat — vérification spot
#
# Ce que fait ce script :
#   1. Reset total de session
#   2. Résout le rôle par nom
#   3. Interroge les 3 canaux (permanent, PIM éligible, PIM active)
#   4. Résout les PrincipalId en DisplayName/UPN
#   5. Affiche la vue consolidée par canal
#   6. Affiche un résumé chiffré
#   7. Ferme proprement toutes les sessions
#
# Note : ce script est en lecture seule — aucune modification du tenant.
#
# Module requis : Microsoft.Graph.Identity.Governance, Microsoft.Graph.Users
# Connexion     : Connect-MgGraph
# ========================================================================================

# --- OUVERTURE — RESET DE SESSION TOTAL ---
# RoleManagement.Read.Directory : lire les assignations de rôles (tous canaux)
# User.Read.All                 : résoudre les PrincipalId en DisplayName/UPN
#
# -ContextScope Process : requis pour bypasser le cache WAM même en lecture
# sur RoleManagement.Read.Directory dans certaines configurations.
# Comportement observé sur tenant de dev E5 — sans ce paramètre, 403 intermittent.
$Scopes = @(
    "RoleManagement.Read.Directory",
    "User.Read.All"
)

Disconnect-MgGraph -ErrorAction SilentlyContinue
Connect-MgGraph -Scopes $Scopes -ContextScope Process -NoWelcome

# ========================================================================================
# ÉTAPE 1 : Définition des variables
# ========================================================================================
Write-Host "1. Définition des variables..." -ForegroundColor Cyan

# Rôle à auditer — modifier selon le besoin.
# Exemples fréquents en première semaine de mission :
#   "Global Administrator"         → qui a les clés du tenant ?
#   "Privileged Role Administrator" → qui peut assigner des rôles ?
#   "Security Administrator"       → qui gère les politiques sécurité ?
#   "Helpdesk Administrator"       → vérification post-assignation exo 8b
#   "User Administrator"           → qui peut créer/modifier/supprimer des users ?
$RoleName = "Helpdesk Administrator"

Write-Host "-> Rôle audité : $RoleName`n" -ForegroundColor Green

# ========================================================================================
# ÉTAPE 2 : Résolution du rôle par nom
# ========================================================================================
Write-Host "2. Résolution du rôle '$RoleName'..." -ForegroundColor Cyan

$RoleDef = Get-MgRoleManagementDirectoryRoleDefinition -All |
    Where-Object { $_.DisplayName -eq $RoleName } |
    Select-Object -First 1

if (-not $RoleDef) {
    Write-Host "-> ERREUR : rôle '$RoleName' introuvable." -ForegroundColor Red
    Write-Host "   Vérifier le nom via : Get-MgRoleManagementDirectoryRoleDefinition -All | Select-Object DisplayName" -ForegroundColor Yellow
    Disconnect-MgGraph -ErrorAction SilentlyContinue
    return
}

Write-Host "-> Rôle trouvé : $($RoleDef.DisplayName) [ID : $($RoleDef.Id)]" -ForegroundColor Green
Write-Host "   IsBuiltIn   : $($RoleDef.IsBuiltIn)" -ForegroundColor Gray
Write-Host "   Description : $($RoleDef.Description)`n" -ForegroundColor Gray

# ========================================================================================
# ÉTAPE 3 : Fonction de résolution des principals
# ========================================================================================

# Fonction utilitaire — résout un PrincipalId (GUID) en objet lisible.
# On tente Get-MgUser en premier. Si l'objet n'est pas un utilisateur
# (Service Principal, groupe...), on retourne l'Id brut avec un label explicite.
# Centralisée ici pour éviter la duplication dans les 3 blocs de canaux.
function Resolve-Principal {
    param([string]$PrincipalId)
    $User = Get-MgUser -UserId $PrincipalId -ErrorAction SilentlyContinue
    if ($User) {
        return [PSCustomObject]@{
            DisplayName = $User.DisplayName
            UPN         = $User.UserPrincipalName
            Type        = "User"
            Id          = $PrincipalId
        }
    }
    # Pas un utilisateur — Service Principal ou groupe.
    # En production, on pourrait tenter Get-MgServicePrincipal / Get-MgGroup
    # pour résoudre tous les types. Ici on garde simple — tenant de dev, users uniquement.
    return [PSCustomObject]@{
        DisplayName = "Non résolu (SP ou groupe)"
        UPN         = "N/A"
        Type        = "ServicePrincipal/Groupe"
        Id          = $PrincipalId
    }
}

# ========================================================================================
# ÉTAPE 4 : Canal 1 — Assignations permanentes directes
# ========================================================================================
Write-Host "4. Canal 1 — Assignations permanentes..." -ForegroundColor Cyan
Write-Host "`n=== CANAL 1 : PERMANENT (hors PIM) ===" -ForegroundColor Red
Write-Host "Assignations directes sans expiration — hors PIM :`n" -ForegroundColor Gray

# Get-MgRoleManagementDirectoryRoleAssignment retourne toutes les assignations directes.
# Filtre sur RoleDefinitionId pour ne garder que le rôle cible.
# DirectoryScopeId "/" = tenant-wide. Une assignation scopée à une AU aurait
# un DirectoryScopeId de type "/administrativeUnits/{id}".
$PermanentAssignments = Get-MgRoleManagementDirectoryRoleAssignment -All |
    Where-Object { $_.RoleDefinitionId -eq $RoleDef.Id }

$PermanentRows = @()
foreach ($Assignment in $PermanentAssignments) {
    $Principal = Resolve-Principal -PrincipalId $Assignment.PrincipalId
    $PermanentRows += [PSCustomObject]@{
        DisplayName      = $Principal.DisplayName
        UPN              = $Principal.UPN
        Type             = $Principal.Type
        Périmètre        = $Assignment.DirectoryScopeId
        AssignationId    = $Assignment.Id
        Canal            = "Permanent"
    }
}

if ($PermanentRows.Count -gt 0) {
    $PermanentRows |
        Select-Object DisplayName, UPN, Type, Périmètre |
        Format-Table -AutoSize
} else {
    Write-Host "-> Aucune assignation permanente pour ce rôle.`n" -ForegroundColor Green
}

# ========================================================================================
# ÉTAPE 5 : Canal 2 — PIM éligibles
# ========================================================================================
Write-Host "5. Canal 2 — PIM éligibles..." -ForegroundColor Cyan
Write-Host "`n=== CANAL 2 : PIM ÉLIGIBLE ===" -ForegroundColor Yellow
Write-Host "Utilisateurs éligibles — peuvent activer le rôle sur demande :`n" -ForegroundColor Gray

# Get-MgRoleManagementDirectoryRoleEligibilitySchedule retourne les éligibilités PIM.
# Un utilisateur éligible N'A PAS le rôle actif — il peut seulement l'activer.
# Status "Provisioned" = éligibilité active. "Revoked" = révoquée (peut encore apparaître
# quelques minutes après une révocation — cohérence éventuelle Graph).
$EligibleAssignments = Get-MgRoleManagementDirectoryRoleEligibilitySchedule -All |
    Where-Object { $_.RoleDefinitionId -eq $RoleDef.Id }

$EligibleRows = @()
foreach ($Assignment in $EligibleAssignments) {
    $Principal = Resolve-Principal -PrincipalId $Assignment.PrincipalId

    # Calcul de l'expiration de l'éligibilité.
    # "noExpiration" → éligibilité permanente (à éviter en prod).
    # EndDateTime    → date d'expiration de l'éligibilité (pas de l'activation).
    $Expiration = if ($Assignment.ScheduleInfo.Expiration.Type -eq "noExpiration") {
                      "Permanente"
                  } elseif ($Assignment.ScheduleInfo.Expiration.EndDateTime) {
                      $Assignment.ScheduleInfo.Expiration.EndDateTime.ToString("dd/MM/yyyy HH:mm")
                  } else { "Inconnue" }

    $EligibleRows += [PSCustomObject]@{
        DisplayName      = $Principal.DisplayName
        UPN              = $Principal.UPN
        Type             = $Principal.Type
        Statut           = $Assignment.Status
        ExpirationÉligibilité = $Expiration
        Périmètre        = $Assignment.DirectoryScopeId
        AssignationId    = $Assignment.Id
        Canal            = "PIM Éligible"
    }
}

if ($EligibleRows.Count -gt 0) {
    $EligibleRows |
        Select-Object DisplayName, UPN, Statut, ExpirationÉligibilité, Périmètre |
        Format-Table -AutoSize
} else {
    Write-Host "-> Aucune éligibilité PIM pour ce rôle.`n" -ForegroundColor Green
}

# ========================================================================================
# ÉTAPE 6 : Canal 3 — PIM actives (activées ou time-bound)
# ========================================================================================
Write-Host "6. Canal 3 — PIM actives..." -ForegroundColor Cyan
Write-Host "`n=== CANAL 3 : PIM ACTIVE (activée ou time-bound) ===" -ForegroundColor Yellow
Write-Host "Utilisateurs avec le rôle actif en ce moment :`n" -ForegroundColor Gray

# Get-MgRoleManagementDirectoryRoleAssignmentSchedule retourne les assignations actives PIM.
# Inclut :
#   - Les activations d'une éligibilité (l'utilisateur a cliqué "Activer" dans PIM)
#   - Les assignations time-bound directes (exo 8b MODE 3)
#
# AssignmentType "Activated" → activation d'une éligibilité PIM par l'utilisateur
# AssignmentType "Assigned"  → assignation active directe time-bound (admin)
$ActiveAssignments = Get-MgRoleManagementDirectoryRoleAssignmentSchedule -All |
    Where-Object { $_.RoleDefinitionId -eq $RoleDef.Id }

$ActiveRows = @()
foreach ($Assignment in $ActiveAssignments) {
    $Principal = Resolve-Principal -PrincipalId $Assignment.PrincipalId

    $Expiration = if ($Assignment.ScheduleInfo.Expiration.Type -eq "noExpiration") {
                      "Permanente"
                  } elseif ($Assignment.ScheduleInfo.Expiration.EndDateTime) {
                      $Assignment.ScheduleInfo.Expiration.EndDateTime.ToString("dd/MM/yyyy HH:mm")
                  } else { "Inconnue" }

    $ActiveRows += [PSCustomObject]@{
        DisplayName      = $Principal.DisplayName
        UPN              = $Principal.UPN
        Type             = $Principal.Type
        Statut           = $Assignment.Status
        AssignmentType   = $Assignment.AssignmentType
        ExpirationActive = $Expiration
        Périmètre        = $Assignment.DirectoryScopeId
        AssignationId    = $Assignment.Id
        Canal            = "PIM Active"
    }
}

if ($ActiveRows.Count -gt 0) {
    $ActiveRows |
        Select-Object DisplayName, UPN, Statut, AssignmentType, ExpirationActive, Périmètre |
        Format-Table -AutoSize
} else {
    Write-Host "-> Aucune assignation active PIM pour ce rôle.`n" -ForegroundColor Green
}

# ========================================================================================
# ÉTAPE 7 : Vue consolidée — tous canaux
# ========================================================================================
Write-Host "7. Vue consolidée tous canaux..." -ForegroundColor Cyan
Write-Host "`n=== VUE CONSOLIDÉE — TOUS CANAUX ===" -ForegroundColor Cyan
Write-Host "Tous les détenteurs du rôle '$RoleName' :`n" -ForegroundColor Gray

# On agrège les 3 collections en une seule vue.
# Utile pour répondre à la question "qui a accès à ce rôle, sous quelle forme ?"
# sans avoir à lire les 3 sections séparément.
$AllHolders = @()
$AllHolders += $PermanentRows | Select-Object DisplayName, UPN, Type,
    @{N="Détail"; E={"Permanent — $($_.Périmètre)"}}, Canal
$AllHolders += $EligibleRows  | Select-Object DisplayName, UPN, Type,
    @{N="Détail"; E={"Éligible jusqu'au $($_.ExpirationÉligibilité)"}}, Canal
$AllHolders += $ActiveRows    | Select-Object DisplayName, UPN, Type,
    @{N="Détail"; E={"Actif ($($_.AssignmentType)) jusqu'au $($_.ExpirationActive)"}}, Canal

if ($AllHolders.Count -gt 0) {
    $AllHolders | Sort-Object Canal, DisplayName |
        Format-Table -AutoSize
} else {
    Write-Host "-> Aucun détenteur trouvé pour le rôle '$RoleName' — tous canaux confondus.`n" -ForegroundColor Yellow
}

# ========================================================================================
# ÉTAPE 8 : Résumé chiffré
# ========================================================================================
Write-Host "`n=== RÉSUMÉ ===" -ForegroundColor Magenta
[PSCustomObject]@{
    Rôle                  = $RoleDef.DisplayName
    RoleId                = $RoleDef.Id
    IsBuiltIn             = $RoleDef.IsBuiltIn
    DétenteursPermanents  = $PermanentRows.Count
    DétenteursÉligibles   = $EligibleRows.Count
    DétenteursActifsPIM   = $ActiveRows.Count
    TotalTousCanaux       = $AllHolders.Count
    Scope                 = "RoleManagement.Read.Directory + User.Read.All (lecture seule)"
    NoteAudit             = "Audit global tous rôles → exo 8f | Audit PIM exhaustif → exo 6a"
} | Format-List

Write-Host "=== FIN DE L'AUDIT MEMBRES DU RÔLE ===" -ForegroundColor Green

# ========================================================================================
# NETTOYAGE MÉMOIRE
# ========================================================================================
Remove-Variable Scopes, RoleName, RoleDef,
                PermanentAssignments, PermanentRows,
                EligibleAssignments, EligibleRows,
                ActiveAssignments, ActiveRows,
                AllHolders, Assignment, Principal, Expiration `
                -ErrorAction SilentlyContinue

# Suppression de la fonction utilitaire de la session
Remove-Item -Path Function:\Resolve-Principal -ErrorAction SilentlyContinue

# ========================================================================================
# FERMETURE — RESET DE SESSION TOTAL
# ========================================================================================
Disconnect-MgGraph -ErrorAction SilentlyContinue
Write-Host "Session MgGraph fermée proprement." -ForegroundColor Magenta
