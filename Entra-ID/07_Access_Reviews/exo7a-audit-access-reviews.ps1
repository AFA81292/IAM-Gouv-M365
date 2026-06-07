# ========================================================================================
# Exercice 7a : Access Reviews — Audit des campagnes de révision
# ========================================================================================
# Concept : Les Access Reviews sont des campagnes périodiques de révision des accès.
# Un reviewer (manager, owner de groupe, admin) valide ou révoque les accès existants.
#
# Pourquoi c'est critique en gouvernance IAM :
#   - Un utilisateur qui quitte l'entreprise garde ses accès si personne ne les révoque
#   - Un consultant en mission dont le contrat est terminé reste dans les groupes
#   - Un rôle privilégié accordé "temporairement" il y a 2 ans est toujours là
#
# Access Reviews automatise cette révision — périodique, traçable, auditée.
#
# Cas d'usage réel : rapport mensuel des campagnes en cours et des décisions prises.
# ========================================================================================

# --- ÉTAPE 1 : Connexion à Microsoft Graph ---
# AccessReview.Read.All : lire les campagnes et décisions
$Scopes = @(
    "AccessReview.Read.All",
    "User.Read.All"
)

Disconnect-MgGraph -ErrorAction SilentlyContinue
Connect-MgGraph -Scopes $Scopes -ContextScope Process

# --- ÉTAPE 2 : Audit des campagnes de révision ---
# Une campagne = une AccessReviewScheduleDefinition
# Elle peut être ponctuelle ou récurrente (mensuelle, trimestrielle...)
Write-Host "`n=== CAMPAGNES DE RÉVISION ===" -ForegroundColor Cyan

$Reviews = Get-MgIdentityGovernanceAccessReviewDefinition -All

if ($Reviews) {
    foreach ($Review in $Reviews) {
        [PSCustomObject]@{
            Nom         = $Review.DisplayName
            Statut      = $Review.Status
            # Fréquence de récurrence — null = ponctuelle
            Recurrence  = if ($Review.ScheduleSettings.Recurrence.Pattern.Type) {
                            $Review.ScheduleSettings.Recurrence.Pattern.Type
                          } else { "Ponctuelle" }
            Debut       = $Review.ScheduleSettings.StartDate
            # CreatedBy = qui a créé la campagne
            CreePar     = $Review.CreatedBy.UserPrincipalName
        }
    }
} else {
    Write-Host "-> Aucune campagne de révision trouvée." -ForegroundColor Yellow
}

# --- ÉTAPE 3 : Audit des instances en cours ---
# Une instance = une occurrence d'une campagne récurrente
# Ex : campagne mensuelle → une instance par mois
Write-Host "`n=== INSTANCES EN COURS ===" -ForegroundColor Cyan
Write-Host "Campagnes actuellement actives et en attente de décision :`n" -ForegroundColor Gray

$ActiveInstances = foreach ($Review in $Reviews) {
    $Instances = Get-MgIdentityGovernanceAccessReviewDefinitionInstance `
        -AccessReviewScheduleDefinitionId $Review.Id -All |
        Where-Object { $_.Status -eq "inProgress" }

    foreach ($Instance in $Instances) {
        [PSCustomObject]@{
            Campagne    = $Review.DisplayName
            # Période couverte par cette instance
            Debut       = $Instance.StartDateTime
            Fin         = $Instance.EndDateTime
            Statut      = $Instance.Status
        }
    }
}

if ($ActiveInstances) {
    $ActiveInstances | Format-Table -AutoSize
} else {
    Write-Host "-> Aucune instance en cours." -ForegroundColor Yellow
}

# --- ÉTAPE 4 : Audit des décisions prises ---
# Approved = accès maintenu / Denied = accès révoqué / NotReviewed = pas encore traité
Write-Host "`n=== DÉCISIONS PAR CAMPAGNE ===" -ForegroundColor Cyan

foreach ($Review in $Reviews) {
    $Instances = Get-MgIdentityGovernanceAccessReviewDefinitionInstance `
        -AccessReviewScheduleDefinitionId $Review.Id -All

    $AllDecisions = foreach ($Instance in $Instances) {
        Get-MgIdentityGovernanceAccessReviewDefinitionInstanceDecision `
            -AccessReviewScheduleDefinitionId $Review.Id `
            -AccessReviewInstanceId $Instance.Id -All
    }

    if ($AllDecisions) {
        $Approved    = ($AllDecisions | Where-Object { $_.Decision -eq "Approve" }).Count
        $Denied      = ($AllDecisions | Where-Object { $_.Decision -eq "Deny" }).Count
        $NotReviewed = ($AllDecisions | Where-Object { $_.Decision -eq "NotReviewed" }).Count

        Write-Host "`nCampagne : $($Review.DisplayName)" -ForegroundColor White
        Write-Host "  Approuvés    : $Approved" -ForegroundColor Green
        Write-Host "  Révoqués     : $Denied" -ForegroundColor Red
        Write-Host "  Non traités  : $NotReviewed" -ForegroundColor Yellow
    }
}

Write-Host "`n=== FIN DE L'AUDIT ACCESS REVIEWS ===" -ForegroundColor Green

# --- ÉTAPE 5 : Nettoyage ---
Remove-Variable Scopes, Reviews, ActiveInstances, AllDecisions, `
                Review, Instance, Instances, Approved, Denied, NotReviewed `
                -ErrorAction SilentlyContinue

Write-Host "`nMémoire locale nettoyée. Session Microsoft Graph toujours active." -ForegroundColor Magenta
