# ========================================================================================
# Exercice 6b : Entra ID — PIM — Assignation ELIGIBLE d'un rôle Entra
# ========================================================================================
# Concept : Rendre un utilisateur ELIGIBLE à un rôle via PIM.
#
# ELIGIBLE ≠ ACTIF :
#   Eligible  = l'utilisateur PEUT activer le rôle quand il en a besoin.
#               Il doit se connecter à My Access, justifier, valider le MFA.
#               Le rôle expire automatiquement après la durée configurée.
#               → Least privilege appliqué aux identités privilégiées.
#
#   Actif permanent (hors PIM) = le rôle est là 24h/24, sans traçabilité,
#               sans justification, sans expiration. C'est le modèle à éviter.
#
# Différence avec une assignation classique :
#   Classique → rôle actif en permanence, aucune traçabilité, aucun contrôle
#   PIM Eligible → activation sur demande, justification obligatoire,
#                  durée limitée, logs complets dans l'audit Entra
#
# Scénario : Geralt devient éligible au rôle "User Administrator".
# Il devra activer le rôle via My Access quand il en a besoin.
# Sans activation, il n'a AUCUN droit administratif — le rôle est juste disponible.
#
# Ce que fait ce script :
#   1. Reset total de session
#   2. Recherche un nom d'éligibilité disponible (contrôle doublon via vérification)
#   3. Récupère l'utilisateur cible et le rôle Entra correspondant
#   4. Crée l'assignation éligible avec durée définie
#   5. Vérifie la création depuis la source de vérité
#   6. Ferme proprement toutes les sessions
#
# Module requis : Microsoft.Graph.Identity.Governance, Microsoft.Graph.Users
# Connexion     : Connect-MgGraph
# ========================================================================================

# --- OUVERTURE — RESET DE SESSION TOTAL ---
# RoleManagement.ReadWrite.Directory : créer/modifier des assignations PIM éligibles
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

$TargetUPN       = "geralt@0n4mg.onmicrosoft.com"

# User Administrator = rôle Entra qui permet de gérer les utilisateurs et les groupes
# sans être Global Admin. C'est le rôle typique pour les helpdesk et les admins de périmètre.
# Il peut créer, modifier, supprimer des comptes, réinitialiser des mots de passe,
# gérer les licences — mais ne peut pas toucher aux autres admins ni à la configuration tenant.
$RoleName        = "User Administrator"

# Durée de l'éligibilité en jours.
# Après cette date, l'éligibilité expire automatiquement — Geralt ne peut plus activer le rôle.
# Un renouvellement est nécessaire (via PIM ou un admin).
# 90 jours = durée standard pour un scénario de lab. En production : aligner sur la politique RH.
$EligibilityDays = 90

Write-Host "-> Utilisateur cible : $TargetUPN" -ForegroundColor Green
Write-Host "-> Rôle cible        : $RoleName" -ForegroundColor Green
Write-Host "-> Durée éligibilité : $EligibilityDays jours`n" -ForegroundColor Green

# ========================================================================================
# ÉTAPE 2 : Récupération de l'utilisateur et du rôle cible
# ========================================================================================
Write-Host "2. Récupération de l'utilisateur et du rôle cible..." -ForegroundColor Cyan

# Get-MgUser -UserId accepte un UPN ou un GUID.
# -ErrorAction Stop : si l'utilisateur n'existe pas, on s'arrête immédiatement.
# Mieux vaut un arrêt explicite qu'une assignation silencieuse vers le mauvais principal.
$TargetUser = Get-MgUser -UserId $TargetUPN -ErrorAction Stop

# On récupère toutes les définitions de rôles et on filtre par DisplayName.
# Il n'existe pas de paramètre -Filter directement sur DisplayName pour cette cmdlet —
# la récupération en masse + Where-Object est la méthode standard.
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
# ÉTAPE 3 : Contrôle doublon — éligibilité déjà existante ?
# ========================================================================================
Write-Host "3. Vérification d'une éligibilité existante..." -ForegroundColor Cyan

# PIM n'autorise pas deux assignations éligibles identiques (même user + même rôle).
# On vérifie avant de tenter la création pour éviter une erreur 400 cryptique.
$ExistingEligibility = Get-MgRoleManagementDirectoryRoleEligibilitySchedule -All |
    Where-Object {
        $_.PrincipalId     -eq $TargetUser.Id -and
        $_.RoleDefinitionId -eq $TargetRole.Id
    }

if ($ExistingEligibility) {
    Write-Host "-> Une assignation éligible existe déjà pour $($TargetUser.DisplayName) sur '$RoleName'." -ForegroundColor Yellow
    Write-Host "   Expiration actuelle : $($ExistingEligibility.ScheduleInfo.Expiration.EndDateTime)" -ForegroundColor Yellow
    Write-Host "   Pour renouveler : supprimer l'existante puis relancer ce script." -ForegroundColor Yellow
    Disconnect-MgGraph -ErrorAction SilentlyContinue
    return
}

Write-Host "-> Aucune éligibilité existante — création possible.`n" -ForegroundColor Green

# ========================================================================================
# ÉTAPE 4 : Création de l'assignation éligible
# ========================================================================================
Write-Host "4. Création de l'assignation éligible..." -ForegroundColor Cyan

$EligibilityParams = @{
    # Action :
    #   "adminAssign"  = un admin crée l'éligibilité pour un utilisateur
    #   "adminRemove"  = un admin supprime l'éligibilité
    #   "selfActivate" = l'utilisateur active lui-même son rôle éligible (étape distincte)
    # Ici : adminAssign — c'est l'admin qui pose l'éligibilité, pas l'user qui active.
    Action           = "adminAssign"

    # Justification visible dans les logs d'audit Entra — toujours renseigner.
    # En production : indiquer le contexte métier, le ticket ITSM, la durée attendue.
    Justification    = "Assignation éligible lab SC300 — User Administrator pour Geralt"

    RoleDefinitionId = $TargetRole.Id
    PrincipalId      = $TargetUser.Id

    # DirectoryScopeId :
    #   "/"                           = périmètre tenant entier (scope global)
    #   "/administrativeUnits/<guid>" = périmètre limité à une Administrative Unit
    # Pour un rôle helpdesk périmétré à une région : utiliser l'AU, pas "/".
    # Sur un tenant de lab sans AU configurées : "/" est le seul scope valide.
    DirectoryScopeId = "/"

    ScheduleInfo     = @{
        StartDateTime = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ssZ")
        Expiration    = @{
            # Type d'expiration :
            #   "AfterDateTime" = expiration à une date précise (recommandé pour les labs et les mandats)
            #   "AfterDuration" = expiration après une durée relative (ex : P90D)
            #   "NoExpiration"  = permanent — à éviter sauf break-glass ou comptes de service
            Type        = "AfterDateTime"
            EndDateTime = (Get-Date).AddDays($EligibilityDays).ToString("yyyy-MM-ddTHH:mm:ssZ")
        }
    }
}

try {
    $NewEligibility = New-MgRoleManagementDirectoryRoleEligibilityScheduleRequest `
        -BodyParameter $EligibilityParams `
        -ErrorAction Stop

    Write-Host "-> Assignation éligible créée avec succès." -ForegroundColor Green
    Write-Host "   ID de la demande : $($NewEligibility.Id)" -ForegroundColor Green
    Write-Host "   Expiration : dans $EligibilityDays jours`n" -ForegroundColor Yellow
}
catch {
    Write-Host "-> Échec de la création de l'assignation éligible : $_" -ForegroundColor Red
    Disconnect-MgGraph -ErrorAction SilentlyContinue
    return
}

# ========================================================================================
# ÉTAPE 5 : Vérification depuis la source de vérité
# ========================================================================================
Write-Host "5. Vérification depuis Entra..." -ForegroundColor Cyan

# REX : la réplication des assignations PIM peut prendre quelques dizaines de secondes.
# 30 secondes couvrent la latence de propagation Graph pour les objets PIM.
# En deçà, Get-MgRoleManagementDirectoryRoleEligibilitySchedule peut ne pas encore
# retourner l'assignation fraîchement créée — faux négatif trompeur.
Start-Sleep -Seconds 30

$CheckEligibility = Get-MgRoleManagementDirectoryRoleEligibilitySchedule -All |
    Where-Object {
        $_.PrincipalId      -eq $TargetUser.Id -and
        $_.RoleDefinitionId -eq $TargetRole.Id
    }

if ($CheckEligibility) {
    Write-Host "-> Assignation éligible confirmée :" -ForegroundColor Green
    [PSCustomObject]@{
        Utilisateur = $TargetUser.DisplayName
        Role        = $TargetRole.DisplayName
        # MemberType :
        #   "Direct" = assignation directe à l'utilisateur
        #   "Group"  = éligibilité héritée via un groupe Entra
        TypeMembre  = $CheckEligibility.MemberType
        Expiration  = $CheckEligibility.ScheduleInfo.Expiration.EndDateTime
        Statut      = $CheckEligibility.Status
    } | Format-List
} else {
    Write-Host "-> Assignation créée mais réplication encore en cours." -ForegroundColor Yellow
    Write-Host "   ID : $($NewEligibility.Id)" -ForegroundColor Yellow
    Write-Host "   Vérifier dans Entra Admin Center > PIM > Eligible assignments." -ForegroundColor Yellow
}

# ========================================================================================
# RÉSUMÉ
# ========================================================================================
Write-Host "=== RÉSUMÉ ===" -ForegroundColor Magenta
[PSCustomObject]@{
    Utilisateur       = $TargetUser.DisplayName
    UPN               = $TargetUPN
    RôleCible         = $RoleName
    TypeAssignation   = "Eligible (activation sur demande — rôle NON actif à ce stade)"
    DuréeEligibilité  = "$EligibilityDays jours"
    ExpirationAuto    = (Get-Date).AddDays($EligibilityDays).ToString("yyyy-MM-dd")
    ActivationViaPIM  = "My Access (myaccess.microsoft.com) ou Entra Admin Center > PIM"
    Justification     = "Renseignée — visible dans les logs d'audit Entra"
    ProchainExo       = "6c — Activation du rôle éligible (selfActivate via PIM)"
} | Format-List

# ========================================================================================
# NETTOYAGE MÉMOIRE
# ========================================================================================
Remove-Variable Scopes, TargetUPN, RoleName, EligibilityDays,
                TargetUser, TargetRole, ExistingEligibility,
                EligibilityParams, NewEligibility, CheckEligibility `
                -ErrorAction SilentlyContinue

# ========================================================================================
# FERMETURE — RESET DE SESSION TOTAL
# ========================================================================================
Disconnect-MgGraph -ErrorAction SilentlyContinue
Write-Host "Session MgGraph fermée proprement." -ForegroundColor Magenta
