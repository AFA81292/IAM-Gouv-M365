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

if (-not $Group)    { Write-Error "Groupe '$GroupName' introuvable."   ; return }
if (-not $Reviewer) { Write-Error "Reviewer '$ReviewerUPN' introuvable." ; return }

Write-Host "-> Groupe   : $($Group.DisplayName) ($($Group.Id))" -ForegroundColor Green
Write-Host "-> Reviewer : $($Reviewer.DisplayName)`n" -ForegroundColor Green

# --- ÉTAPE 4 : Construction de la campagne ---
# Une campagne Access Review se compose de :
#   Scope    = ce qu'on révise — ici les membres user du groupe
#   Reviewers = qui fait la révision — ici Geralt
#   Settings  = durée, récurrence, décision automatique
Write-Host "2. Création de la campagne '$ReviewName'..." -ForegroundColor Cyan

$ReviewParams = @{
    DisplayName             = $ReviewName
    # Description visible par les admins dans le portail
    DescriptionForAdmins    = "Révision trimestrielle des membres du groupe $GroupName."
    # Description visible par le reviewer dans My Access
    DescriptionForReviewers = "Veuillez réviser les membres de ce groupe et confirmer ou révoquer leurs accès."

    # Scope = ce qu'on révise
    # "@odata.type" accessReviewQueryScope = révision basée sur une requête Graph
    # Query "/groups/id/members/microsoft.graph.user" = membres utilisateurs du groupe
    # Note : on filtre sur microsoft.graph.user pour exclure les groupes imbriqués
    Scope = @{
        "@odata.type" = "#microsoft.graph.accessReviewQueryScope"
        Query         = "/groups/$($Group.Id)/members/microsoft.graph.user"
        QueryType     = "MicrosoftGraph"
    }

    # Reviewers = qui révise
    # Query "/users/id" = reviewer précis (vs "/me/directReports" pour les managers)
    Reviewers = @(
        @{
            Query     = "/users/$($Reviewer.Id)"
            QueryType = "MicrosoftGraph"
        }
    )

    Settings = @{
        # Durée de chaque instance — 14 jours pour répondre avant décision automatique
        InstanceDurationInDays = 14

        # Récurrence — tous les 3 mois (absoluteMonthly + interval 3)
        # noEnd = la campagne tourne indéfiniment jusqu'à suppression manuelle
        Recurrence = @{
            Pattern = @{
                # absoluteMonthly = même jour chaque mois
                Type     = "absoluteMonthly"
                Interval = 3
            }
            Range = @{
                Type      = "noEnd"
                StartDate = (Get-Date).ToString("yyyy-MM-dd")
            }
        }

        # DefaultDecision = décision automatique si le reviewer ne répond pas
        # "Deny" = accès révoqué automatiquement — recommandé pour les groupes sensibles
        # "Approve" = accès maintenu — moins sécurisé
        # "Recommendation" = Microsoft décide selon l'activité du compte
        DefaultDecisionEnabled          = $true
        DefaultDecision                 = "Deny"

        # Justification obligatoire pour les approbations — traçabilité audit
        JustificationRequiredOnApproval = $true

        # Rappels par mail envoyés au reviewer avant expiration
        ReminderNotificationsEnabled    = $true
        NotificationToSelfEnabled       = $false
    }
}

try {
    $NewReview = New-MgIdentityGovernanceAccessReviewDefinition `
        -BodyParameter $ReviewParams -ErrorAction Stop
    Write-Host "-> Succès : Campagne créée avec l'ID : $($NewReview.Id)" -ForegroundColor Green
    Write-Host "-> Récurrence  : trimestrielle — 14 jours par instance" -ForegroundColor Yellow
    Write-Host "-> Décision par défaut : Deny (si pas de réponse sous 14 jours)" -ForegroundColor Yellow
}
catch {
    Write-Host "-> Échec : $_" -ForegroundColor Red
    return
}

# --- ÉTAPE 5 : Vérification depuis Entra (source de vérité) ---
# Réplication Access Reviews — 10 secondes
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
Remove-Variable Scopes, GroupName, ReviewerUPN, ReviewName, `
                Group, Reviewer, ReviewParams, NewReview `
                -ErrorAction SilentlyContinue

Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
Write-Host "`nMémoire locale nettoyée. Session Microsoft Graph fermée." -ForegroundColor Magenta
