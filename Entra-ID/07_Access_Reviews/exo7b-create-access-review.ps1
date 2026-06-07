# ========================================================================================
# Exercice 7b : Access Reviews — Création d'une campagne de révision trimestrielle
# ========================================================================================
# Concept : Créer une campagne de révision périodique pour un groupe.
# Les membres du groupe seront révisés par Geralt tous les 3 mois.
# Si le reviewer ne répond pas dans les 14 jours — décision automatique : révoquer.
#
# Pourquoi c'est critique en gouvernance IAM :
#   - Un consultant dont le contrat est terminé reste dans les groupes sans révision
#   - Un accès accordé "temporairement" il y a 2 ans est toujours là
#   - Access Reviews automatise la révision — périodique, traçable, auditée
#
# Scénario : campagne trimestrielle sur Witchers-Brotherhood.
# Reviewer : Geralt. Décision par défaut : Deny si pas de réponse.
#
# Astuce technique : -ContextScope Process bypasse le cache WAM.
# Note SDK : toutes les clés du BodyParameter doivent être en camelCase strict
# (ex: displayName, not DisplayName) — le SDK Graph ne traduit pas automatiquement
# la casse lors de la sérialisation JSON, ce qui provoque des 400 silencieux.
# Merci LLM =)
# ========================================================================================

# --- ÉTAPE 1 : Connexion à Microsoft Graph ---
# AccessReview.ReadWrite.All : créer et modifier des campagnes
# Group.Read.All : récupérer l'ID du groupe
# User.Read.All : récupérer l'ID du reviewer
$Scopes = @(
    "AccessReview.ReadWrite.All",
    "Group.Read.All",
    "User.Read.All"
)

Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
Connect-MgGraph -Scopes $Scopes -ContextScope Process -NoWelcome

# --- ÉTAPE 2 : Définition des variables ---
$GroupName   = "Witchers-Brotherhood"
$ReviewerUPN = "geralt@0n4mg.onmicrosoft.com"
$ReviewName  = "Révision trimestrielle — Witchers-Brotherhood"

# --- ÉTAPE 3 : Récupération du groupe et du reviewer ---
Write-Host "1. Récupération du groupe et du reviewer..." -ForegroundColor Cyan

$Group    = Get-MgGroup -Filter "displayName eq '$GroupName'" -ErrorAction Stop
$Reviewer = Get-MgUser -UserId $ReviewerUPN -ErrorAction Stop

if (-not $Group)    { Write-Error "Groupe '$GroupName' introuvable."    ; return }
if (-not $Reviewer) { Write-Error "Reviewer '$ReviewerUPN' introuvable." ; return }

Write-Host "-> Groupe   : $($Group.DisplayName) ($($Group.Id))" -ForegroundColor Green
Write-Host "-> Reviewer : $($Reviewer.DisplayName)`n" -ForegroundColor Green

# --- ÉTAPE 4 : Construction de la campagne ---
# Une campagne Access Review se compose de :
#   scope     = ce qu'on révise
#   reviewers = qui fait la révision
#   settings  = durée, récurrence, décision automatique
#
# IMPORTANT : toutes les clés sont en camelCase strict
# Le SDK Graph ne traduit pas PascalCase → camelCase lors de la sérialisation JSON
# Une clé mal casée = propriété inconnue = 400 BadRequest silencieux
Write-Host "2. Création de la campagne '$ReviewName'..." -ForegroundColor Cyan

# Récupération de la date du jour pour aligner le pattern de récurrence
# L'API exige que StartDate et DayOfMonth soient cohérents
# DayOfMonth prend dynamiquement le jour actuel pour éviter le 400
$CurrentDate = Get-Date

$ReviewParams = @{
    displayName             = $ReviewName
    # Description visible par les admins dans le portail Entra
    descriptionForAdmins    = "Révision trimestrielle des membres du groupe $GroupName."
    # Description visible par Geralt dans My Access quand il reçoit la demande
    descriptionForReviewers = "Veuillez réviser les membres de ce groupe et confirmer ou révoquer leurs accès."

    # scope = ce qu'on révise
    # L'API Access Reviews v1.0 n'accepte que /members pour les groupes
    # /transitiveMembers provoque un 400 — limitation de l'API v1.0
    scope = @{
        "@odata.type" = "#microsoft.graph.accessReviewQueryScope"
        query         = "/groups/$($Group.Id)/members"
        queryType     = "MicrosoftGraph"
    }

    # reviewers = qui révise
    # "@odata.type" accessReviewReviewerScope obligatoire — sans lui l'API refuse
    # Alternatives pour query : "./manager", "./owners", "/groups/id/members"
    reviewers = @(
        @{
            "@odata.type" = "#microsoft.graph.accessReviewReviewerScope"
            query         = "/users/$($Reviewer.Id)"
            queryType     = "MicrosoftGraph"
        }
    )

    settings = @{
        # Durée de chaque instance — 14 jours pour répondre avant décision automatique
        instanceDurationInDays = 14

        # Récurrence — tous les 3 mois, le même jour que le jour de création
        # absoluteMonthly = même jour chaque mois
        # dayOfMonth synchronisé avec startDate — exigence stricte de l'API
        # interval = 3 : tous les 3 mois
        # noEnd = tourne indéfiniment jusqu'à suppression manuelle
        recurrence = @{
            pattern = @{
                type       = "absoluteMonthly"
                dayOfMonth = $CurrentDate.Day
                interval   = 3
            }
            range = @{
                type      = "noEnd"
                startDate = $CurrentDate.ToString("yyyy-MM-dd")
            }
        }

        # defaultDecision = décision automatique si le reviewer ne répond pas dans les 14 jours
        # "Deny"           = accès révoqué — recommandé pour les groupes sensibles
        # "Approve"        = accès maintenu — moins sécurisé
        # "Recommendation" = Microsoft décide selon l'activité du compte
        defaultDecisionEnabled          = $true
        defaultDecision                 = "Deny"

        # Justification obligatoire pour chaque approbation — traçabilité audit
        justificationRequiredOnApproval = $true

        # mailNotificationsEnabled = active l'ensemble du flux mail Entra vers le reviewer
        # reminderNotificationsEnabled = rappels avant expiration de l'instance
        mailNotificationsEnabled        = $true
        reminderNotificationsEnabled    = $true
    }
}

try {
    $NewReview = New-MgIdentityGovernanceAccessReviewDefinition `
        -BodyParameter $ReviewParams -ErrorAction Stop
    Write-Host "-> Succès : Campagne créée avec l'ID : $($NewReview.Id)" -ForegroundColor Green
    Write-Host "-> Récurrence  : trimestrielle — le $($CurrentDate.Day) de chaque mois" -ForegroundColor Yellow
    Write-Host "-> Décision par défaut : Deny (si pas de réponse sous 14 jours)" -ForegroundColor Yellow
}
catch {
    Write-Host "-> Échec : $_" -ForegroundColor Red
    return
}

# --- ÉTAPE 5 : Vérification depuis Entra (source de vérité) ---
Write-Host "`n3. Vérification depuis Entra (attente 10s)..." -ForegroundColor Cyan
Start-Sleep -Seconds 10

try {
    Get-MgIdentityGovernanceAccessReviewDefinition `
        -AccessReviewScheduleDefinitionId $NewReview.Id -ErrorAction Stop |
        Select-Object Id, DisplayName, Status
}
catch {
    Write-Host "-> Campagne créée mais réplication en cours." -ForegroundColor Yellow
    Write-Host "-> Vérifie dans Entra Admin Center — Identity Governance — Access Reviews." -ForegroundColor Yellow
}

# --- ÉTAPE 6 : Nettoyage ---
Remove-Variable Scopes, GroupName, ReviewerUPN, ReviewName, CurrentDate, `
                Group, Reviewer, ReviewParams, NewReview `
                -ErrorAction SilentlyContinue

Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
Write-Host "`nMémoire locale nettoyée. Session Microsoft Graph fermée." -ForegroundColor Magenta
