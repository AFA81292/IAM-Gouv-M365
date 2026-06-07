# ========================================================================================
# Exercice 7b : Access Reviews — Création d'une campagne de révision
# ========================================================================================
# Concept : Créer une campagne de révision périodique pour un groupe.
# Les membres du groupe seront révisés par leur manager tous les 90 jours.
# Si le manager ne répond pas dans les 14 jours — décision automatique : révoquer.
#
# C'est la configuration recommandée pour les groupes d'accès sensibles :
#   - Groupe de consultants externes
#   - Groupe d'accès à des données confidentielles
#   - Groupe d'administrateurs locaux
#
# Scénario : campagne trimestrielle sur Witchers-Brotherhood.
# ========================================================================================

# --- ÉTAPE 1 : Connexion à Microsoft Graph ---
# AccessReview.ReadWrite.All : créer et modifier des campagnes
$Scopes = @(
    "AccessReview.ReadWrite.All",
    "Group.Read.All",
    "User.Read.All"
)

Disconnect-MgGraph -ErrorAction SilentlyContinue
Connect-MgGraph -Scopes $Scopes -ContextScope Process

# --- ÉTAPE 2 : Définition des variables ---
$GroupName    = "Witchers-Brotherhood"
$ReviewerUPN  = "geralt@0n4mg.onmicrosoft.com"
$ReviewName   = "Révision trimestrielle — Witchers-Brotherhood"

# --- ÉTAPE 3 : Récupération du groupe et du reviewer ---
Write-Host "1. Récupération du groupe et du reviewer..." -ForegroundColor Cyan

$Group    = Get-MgGroup -Filter "displayName eq '$GroupName'" -ErrorAction Stop
$Reviewer = Get-MgUser -UserId $ReviewerUPN -ErrorAction Stop

if (-not $Group)    { Write-Error "Groupe '$GroupName' introuvable." ; return }
if (-not $Reviewer) { Write-Error "Reviewer '$ReviewerUPN' introuvable." ; return }

Write-Host "-> Groupe   : $($Group.DisplayName) ($($Group.Id))" -ForegroundColor Green
Write-Host "-> Reviewer : $($Reviewer.DisplayName)`n" -ForegroundColor Green

# --- ÉTAPE 4 : Construction de la campagne ---
# Une campagne Access Review se compose de :
#   Scope       = ce qu'on révise (membres d'un groupe, assignations de rôles...)
#   Reviewers   = qui fait la révision (manager, owner, personne précise)
#   Settings    = durée, récurrence, décision automatique si pas de réponse
Write-Host "2. Création de la campagne '$ReviewName'..." -ForegroundColor Cyan

$ReviewParams = @{
    DisplayName = $ReviewName

    # Scope = membres du groupe Witchers-Brotherhood
    Scope = @{
        # query = l'URL Graph qui pointe vers les membres du groupe
        Query     = "/groups/$($Group.Id)/members"
        QueryType = "MicrosoftGraph"
    }

    # Reviewers = Geralt révise les membres
    # "@odata.type" singleUser = reviewer précis (vs manager, groupOwners...)
    Reviewers = @(
        @{
            Query     = "/users/$($Reviewer.Id)"
            QueryType = "MicrosoftGraph"
        }
    )

    # Settings = paramètres de la campagne
    InstanceEnumerationScope = @{
        Query     = "/groups/$($Group.Id)"
        QueryType = "MicrosoftGraph"
    }

    Settings = @{
        # Durée de chaque instance — 14 jours pour répondre
        InstanceDurationInDays = 14

        # Récurrence — tous les 90 jours
        Recurrence = @{
            Pattern = @{
                # absoluteMonthly = tous les X mois
                Type     = "absoluteMonthly"
                Interval = 3
            }
            Range = @{
                Type      = "noEnd"
                StartDate = (Get-Date).ToString("yyyy-MM-dd")
            }
        }

        # Si le reviewer ne répond pas dans les 14 jours
        # Recommendation = Microsoft suggère Approve ou Deny selon l'activité
        DefaultDecisionEnabled     = $true
        # defaultDecision "Deny" = si pas de réponse, accès révoqué automatiquement
        # C'est la configuration recommandée pour les groupes sensibles
        DefaultDecision            = "Deny"
        JustificationRequiredOnApproval = $true

        # Envoyer des rappels par mail aux reviewers
        ReminderNotificationsEnabled    = $true
        NotificationToSelfEnabled       = $false
    }
}

try {
    $NewReview = New-MgIdentityGovernanceAccessReviewDefinition `
        -BodyParameter $ReviewParams -ErrorAction Stop
    Write-Host "-> Succès : Campagne créée avec l'ID : $($NewReview.Id)" -ForegroundColor Green
    Write-Host "-> Récurrence : trimestrielle — 14 jours par instance" -ForegroundColor Yellow
    Write-Host "-> Décision par défaut : Deny (si pas de réponse)" -ForegroundColor Yellow
}
catch {
    Write-Host "-> Échec : $_" -ForegroundColor Red
    return
}

# --- ÉTAPE 5 : Vérification ---
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

Write-Host "`nMémoire locale nettoyée. Session Microsoft Graph toujours active." -ForegroundColor Magenta
