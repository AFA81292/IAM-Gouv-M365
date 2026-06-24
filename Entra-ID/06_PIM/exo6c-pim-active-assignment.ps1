# ========================================================================================
# Exercice 6c : Entra ID — PIM — Assignation ACTIVE time-bound d'un rôle Entra
# ========================================================================================
# Concept : Assigner un rôle de manière ACTIVE et TEMPORAIRE via PIM.
#
# Contrairement à l'éligible (6b) — le rôle est actif immédiatement.
# L'utilisateur n'a pas besoin d'activer quoi que ce soit via My Access.
# Mais le rôle expire automatiquement à la date définie — zéro oubli de révocation.
#
# Cas d'usage réel :
#   - Un consultant externe arrive pour une mission de 3 mois
#   - Il a besoin du rôle actif immédiatement (pas de flux d'activation utilisateur)
#   - À la fin de la mission : révocation automatique, aucune action manuelle requise
#   - Alternative au "permanent" qui lui, ne s'éteint jamais et crée une dette sécurité
#
# Triangle 6b / 6c / permanent :
#
#   6b Eligible   → doit activer via My Access + justification + MFA
#                   Rôle non actif par défaut — least privilege maximal
#
#   6c Active     → actif immédiatement, expire automatiquement à la date définie
#   time-bound      Moins de contrôle que 6b, mais plus sûr qu'une assignation permanente
#
#   Permanent     → actif en permanence, aucune expiration
#   (hors PIM)      À réserver aux break-glass et comptes de service — jamais aux humains
#
# Ce que fait ce script :
#   1. Reset total de session
#   2. Récupère l'utilisateur cible et le rôle Entra correspondant
#   3. Contrôle doublon — assignation active existante ?
#   4. Crée l'assignation active time-bound
#   5. Vérifie la création depuis la source de vérité
#   6. Ferme proprement toutes les sessions
#
# Module requis : Microsoft.Graph.Identity.Governance, Microsoft.Graph.Users
# Connexion     : Connect-MgGraph
# ========================================================================================

# --- OUVERTURE — RESET DE SESSION TOTAL ---
# RoleManagement.ReadWrite.Directory : créer/modifier des assignations PIM actives
# User.Read.All : résoudre l'UPN en objet User (Id, DisplayName)
# -ContextScope Process : bypasse le cache WAM (Windows Authentication Manager).
# REX : sans ce paramètre, WAM réutilise un token de session précédente avec des
# scopes insuffisants — cause la plus fréquente des 403 silencieux sur les scripts PIM.
$Scopes = @(
    "RoleManagement.ReadWrite.Directory",
    "User.Read.All"
)

Disconnect-MgGraph -ErrorAction SilentlyContinue
Connect-MgGraph -Scopes $Scopes -ContextScope Process -NoWelcome

# ========================================================================================
# ÉTAPE 1 : Définition des variables
# ========================================================================================
Write-Host "1. Définition des variables..." -ForegroundColor Cyan

$TargetUPN   = "liara@0n4mg.onmicrosoft.com"

# User Administrator = rôle Entra qui permet de gérer les utilisateurs et les groupes
# sans être Global Admin. Rôle typique pour les consultants en mission périmètre RH/accès.
$RoleName    = "User Administrator"

# Durée de la mission en jours.
# À la fin de cette période, PIM révoque le rôle automatiquement.
# L'utilisateur perd l'accès sans qu'aucune action manuelle soit nécessaire.
$MissionDays = 90

Write-Host "-> Utilisateur cible : $TargetUPN" -ForegroundColor Green
Write-Host "-> Rôle cible        : $RoleName" -ForegroundColor Green
Write-Host "-> Durée mission     : $MissionDays jours`n" -ForegroundColor Green

# ========================================================================================
# ÉTAPE 2 : Récupération de l'utilisateur et du rôle cible
# ========================================================================================
Write-Host "2. Récupération de l'utilisateur et du rôle cible..." -ForegroundColor Cyan

# -ErrorAction Stop : si l'utilisateur n'existe pas, arrêt immédiat.
# Mieux vaut un arrêt explicite qu'une assignation silencieuse vers le mauvais principal.
$TargetUser = Get-MgUser -UserId $TargetUPN -ErrorAction Stop

# Récupération en masse + filtre : il n'existe pas de paramètre -Filter sur DisplayName
# pour Get-MgRoleManagementDirectoryRoleDefinition — méthode standard avec Where-Object.
$TargetRole = Get-MgRoleManagementDirectoryRoleDefinition -All |
    Where-Object { $_.DisplayName -eq $RoleName }

if (-not $TargetRole) {
    Write-Host "-> Rôle '$RoleName' introuvable dans le tenant." -ForegroundColor Red
    Disconnect-MgGraph -ErrorAction SilentlyContinue
    return
}

Write-Host "-> Utilisateur : $($TargetUser.DisplayName) [ID : $($TargetUser.Id)]" -ForegroundColor Green
Write-Host "-> Rôle        : $($TargetRole.DisplayName) [ID : $($TargetRole.Id)]`n" -ForegroundColor Green

# ========================================================================================
# ÉTAPE 3 : Contrôle doublon — assignation active existante ?
# ========================================================================================
Write-Host "3. Vérification d'une assignation active existante..." -ForegroundColor Cyan

# PIM n'autorise pas deux assignations actives identiques (même user + même rôle).
# On vérifie avant de tenter la création pour éviter une erreur 400 cryptique.
# Différence cmdlet vs 6b :
#   6b → Get-MgRoleManagementDirectoryRoleEligibilitySchedule (éligibles)
#   6c → Get-MgRoleManagementDirectoryRoleAssignmentSchedule  (actives)
$ExistingAssignment = Get-MgRoleManagementDirectoryRoleAssignmentSchedule -All |
    Where-Object {
        $_.PrincipalId      -eq $TargetUser.Id -and
        $_.RoleDefinitionId -eq $TargetRole.Id
    }

if ($ExistingAssignment) {
    Write-Host "-> Une assignation active existe déjà pour $($TargetUser.DisplayName) sur '$RoleName'." -ForegroundColor Yellow
    Write-Host "   Statut actuel    : $($ExistingAssignment.Status)" -ForegroundColor Yellow
    Write-Host "   Type assignation : $($ExistingAssignment.AssignmentType)" -ForegroundColor Yellow
    Write-Host "   Expiration       : $($ExistingAssignment.ScheduleInfo.Expiration.EndDateTime)" -ForegroundColor Yellow
    Write-Host "   Pour renouveler : supprimer l'existante (adminRemove) puis relancer ce script." -ForegroundColor Yellow
    Disconnect-MgGraph -ErrorAction SilentlyContinue
    return
}

Write-Host "-> Aucune assignation active existante — création possible.`n" -ForegroundColor Green

# ========================================================================================
# ÉTAPE 4 : Création de l'assignation active time-bound
# ========================================================================================
Write-Host "4. Création de l'assignation active time-bound..." -ForegroundColor Cyan

# Différence fondamentale de cmdlet vs 6b :
#   New-MgRoleManagementDirectoryRoleEligibilityScheduleRequest → crée une ÉLIGIBILITÉ
#   New-MgRoleManagementDirectoryRoleAssignmentScheduleRequest  → crée une ASSIGNATION ACTIVE
# Le nom de la cmdlet seul fait la différence entre éligible et actif.
$AssignmentParams = @{
    # Action :
    #   "adminAssign"  = un admin crée l'assignation active pour un utilisateur
    #   "adminRemove"  = un admin révoque l'assignation active
    #   "selfActivate" = l'utilisateur active son propre rôle éligible (cmdlet éligibilité)
    # Ici : adminAssign — c'est l'admin qui pose l'assignation, active immédiatement.
    Action           = "adminAssign"

    # Justification visible dans les logs d'audit Entra — toujours renseigner.
    # En production : indiquer le contexte métier, le ticket ITSM, la date de fin de mission.
    Justification    = "Mission run SharePoint 90 jours — accès actif immédiat avec expiration automatique"

    RoleDefinitionId = $TargetRole.Id
    PrincipalId      = $TargetUser.Id

    # DirectoryScopeId :
    #   "/"                           = périmètre tenant entier (scope global)
    #   "/administrativeUnits/<guid>" = périmètre limité à une Administrative Unit
    DirectoryScopeId = "/"

    # AssignmentType :
    #   "Assigned"  = rôle actif assigné directement (permanent ou time-bound selon Expiration)
    #                 → c'est ce type qui apparaît dans l'audit comme risque si permanent
    #   "Activated" = activé par l'user depuis une éligibilité PIM (résultat de selfActivate)
    #                 → comportement attendu en production quand l'user active son rôle éligible
    AssignmentType   = "Assigned"

    ScheduleInfo     = @{
        StartDateTime = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ssZ")
        Expiration    = @{
            # "AfterDateTime" = expiration à une date précise — recommandé pour les missions
            # "AfterDuration" = expiration après une durée relative (ex : P90D)
            # "NoExpiration"  = permanent — à éviter pour les comptes humains
            Type        = "AfterDateTime"
            EndDateTime = (Get-Date).AddDays($MissionDays).ToString("yyyy-MM-ddTHH:mm:ssZ")
        }
    }
}

try {
    $NewAssignment = New-MgRoleManagementDirectoryRoleAssignmentScheduleRequest `
        -BodyParameter $AssignmentParams `
        -ErrorAction Stop

    Write-Host "-> Assignation active créée avec succès." -ForegroundColor Green
    Write-Host "   ID de la demande : $($NewAssignment.Id)" -ForegroundColor Green
    Write-Host "   Actif jusqu'au   : $((Get-Date).AddDays($MissionDays).ToString('dd/MM/yyyy'))`n" -ForegroundColor Yellow
}
catch {
    Write-Host "-> Échec de la création de l'assignation active : $_" -ForegroundColor Red
    Disconnect-MgGraph -ErrorAction SilentlyContinue
    return
}

# ========================================================================================
# ÉTAPE 5 : Vérification depuis la source de vérité
# ========================================================================================
Write-Host "5. Vérification depuis Entra..." -ForegroundColor Cyan

# REX : la réplication des assignations PIM peut prendre quelques dizaines de secondes.
# 30 secondes couvrent la latence de propagation Graph pour les objets PIM.
# En deçà, Get-MgRoleManagementDirectoryRoleAssignmentSchedule peut ne pas encore
# retourner l'assignation fraîchement créée — faux négatif trompeur.
Start-Sleep -Seconds 30

$CheckAssignment = Get-MgRoleManagementDirectoryRoleAssignmentSchedule -All |
    Where-Object {
        $_.PrincipalId      -eq $TargetUser.Id -and
        $_.RoleDefinitionId -eq $TargetRole.Id
    }

if ($CheckAssignment) {
    Write-Host "-> Assignation active confirmée :" -ForegroundColor Green
    [PSCustomObject]@{
        Utilisateur  = $TargetUser.DisplayName
        Role         = $TargetRole.DisplayName
        Statut       = $CheckAssignment.Status
        # AssignmentType : "Assigned" attendu ici (assignation admin directe)
        # Si "Activated" apparaît : l'user a activé son rôle éligible — comportement différent
        TypeAssig    = $CheckAssignment.AssignmentType
        Expiration   = $CheckAssignment.ScheduleInfo.Expiration.EndDateTime
    } | Format-List
} else {
    Write-Host "-> Assignation créée mais réplication encore en cours." -ForegroundColor Yellow
    Write-Host "   ID : $($NewAssignment.Id)" -ForegroundColor Yellow
    Write-Host "   Vérifier dans Entra Admin Center > PIM > Active assignments." -ForegroundColor Yellow
}

# ========================================================================================
# RÉSUMÉ
# ========================================================================================
Write-Host "=== RÉSUMÉ ===" -ForegroundColor Magenta
[PSCustomObject]@{
    Utilisateur       = $TargetUser.DisplayName
    UPN               = $TargetUPN
    RôleCible         = $RoleName
    TypeAssignation   = "Active time-bound (rôle ACTIF immédiatement)"
    DuréeMission      = "$MissionDays jours"
    ExpirationAuto    = (Get-Date).AddDays($MissionDays).ToString("yyyy-MM-dd")
    RévocationAuto    = "Oui — PIM révoque à la date d'expiration sans action manuelle"
    DifférenceVs6b    = "6b = éligible (activation requise) / 6c = actif immédiat (pas d'action user)"
    DifférencePermanent = "Permanent = jamais révoqué / time-bound = révocation auto garantie"
    ProchainExo       = "6d — Audit des assignations actives et éligibles (lecture seule)"
} | Format-List

# ========================================================================================
# NETTOYAGE MÉMOIRE
# ========================================================================================
Remove-Variable Scopes, TargetUPN, RoleName, MissionDays,
                TargetUser, TargetRole, ExistingAssignment,
                AssignmentParams, NewAssignment, CheckAssignment `
                -ErrorAction SilentlyContinue

# ========================================================================================
# FERMETURE — RESET DE SESSION TOTAL
# ========================================================================================
Disconnect-MgGraph -ErrorAction SilentlyContinue
Write-Host "Session MgGraph fermée proprement." -ForegroundColor Magenta
