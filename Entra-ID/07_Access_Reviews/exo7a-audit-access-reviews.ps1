# ========================================================================================
# Exercice 7a : Entra ID — Access Reviews — Audit des campagnes de révision
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
# Delta pédagogique vs 6a/6d :
#   6a/6d → audit PIM : qui a quels rôles, permanents ou éligibles
#   7a    → audit Access Reviews : campagnes de révision en cours, décisions prises
#           On ne regarde plus les rôles directement, mais le processus de gouvernance
#           qui garantit que ces rôles (et memberships de groupes) sont régulièrement
#           revalidés par un humain responsable.
#
# Trois niveaux d'objets Access Reviews :
#   AccessReviewScheduleDefinition → la campagne (définition, fréquence, scope)
#   AccessReviewInstance           → une occurrence de la campagne (ex : mois de juin)
#   AccessReviewInstanceDecision   → une décision individuelle dans une instance
#                                    (Approve / Deny / NotReviewed par reviewer)
#
# Ce que fait ce script :
#   1. Reset total de session
#   2. Audite toutes les campagnes de révision définies sur le tenant
#   3. Identifie les instances actuellement en cours (statut "inProgress")
#   4. Agrège les décisions prises par campagne (Approve / Deny / NotReviewed)
#   5. Affiche un résumé chiffré
#   6. Exporte les trois jeux de données en CSV horodatés
#   7. Ferme proprement toutes les sessions
#
# Note : ce script est en lecture seule — aucune modification du tenant.
#
# Fichiers CSV générés :
#   AR_Campagnes_YYYYMMDD_HHmmss.csv
#   AR_InstancesEnCours_YYYYMMDD_HHmmss.csv
#   AR_DecisionsParCampagne_YYYYMMDD_HHmmss.csv
#
# Module requis : Microsoft.Graph.Identity.Governance, Microsoft.Graph.Users
# Connexion     : Connect-MgGraph
# ========================================================================================

# --- OUVERTURE — RESET DE SESSION TOTAL ---
# AccessReview.Read.All : lire les campagnes, instances et décisions
# User.Read.All         : résoudre les identifiants en DisplayName/UPN lisibles
# -ContextScope Process : bypasse le cache WAM — voir REX exercices 5b/5c.
$Scopes = @(
    "AccessReview.Read.All",
    "User.Read.All"
)

Disconnect-MgGraph -ErrorAction SilentlyContinue
Connect-MgGraph -Scopes $Scopes -ContextScope Process -NoWelcome

# ========================================================================================
# ÉTAPE 1 : Récupération de toutes les campagnes de révision
# ========================================================================================
Write-Host "1. Récupération des campagnes de révision..." -ForegroundColor Cyan

# Get-MgIdentityGovernanceAccessReviewDefinition retourne toutes les campagnes définies
# sur le tenant — actives, terminées, ou non encore démarrées.
# Une AccessReviewScheduleDefinition = la définition de la campagne (pas une occurrence).
$Reviews = Get-MgIdentityGovernanceAccessReviewDefinition -All

Write-Host "-> $($Reviews.Count) campagne(s) trouvée(s).`n" -ForegroundColor Green

# ========================================================================================
# ÉTAPE 2 : Audit des campagnes de révision
# ========================================================================================
Write-Host "2. Détail des campagnes..." -ForegroundColor Cyan
Write-Host "`n=== CAMPAGNES DE RÉVISION ===" -ForegroundColor Cyan

# On construit les objets normalisés dans une collection réutilisable pour le CSV.
$CampagneRows = @()

if ($Reviews) {
    foreach ($Review in $Reviews) {
        $Row = [PSCustomObject]@{
            Id         = $Review.Id
            Nom        = $Review.DisplayName
            Statut     = $Review.Status
            # Recurrence.Pattern.Type :
            #   "weekly" / "absoluteMonthly" / "absoluteYearly" → campagne récurrente
            #   $null → campagne ponctuelle (une seule occurrence)
            Recurrence = if ($Review.ScheduleSettings.Recurrence.Pattern.Type) {
                             $Review.ScheduleSettings.Recurrence.Pattern.Type
                         } else { "Ponctuelle" }
            Debut      = $Review.ScheduleSettings.StartDate
            # CreatedBy.UserPrincipalName → qui a créé la campagne
            # Utile pour identifier le responsable à contacter si la campagne est bloquée
            CreePar    = $Review.CreatedBy.UserPrincipalName
        }
        $CampagneRows += $Row
        $Row | Select-Object Nom, Statut, Recurrence, Debut, CreePar
    }
} else {
    Write-Host "-> Aucune campagne de révision trouvée." -ForegroundColor Yellow
}

# ========================================================================================
# ÉTAPE 3 : Audit des instances en cours
# ========================================================================================
Write-Host "`n3. Recherche des instances en cours..." -ForegroundColor Cyan
Write-Host "`n=== INSTANCES EN COURS ===" -ForegroundColor Cyan
Write-Host "Campagnes actuellement actives et en attente de décision :`n" -ForegroundColor Gray

# Une instance = une occurrence d'une campagne dans le temps.
# On filtre sur Status "inProgress" — instances ouvertes, en attente de décision reviewer.
# Une instance "inProgress" = des reviewers ont des décisions à prendre MAINTENANT.
# C'est l'information opérationnelle clé pour un rapport mensuel de gouvernance.
$InstanceRows = @()

foreach ($Review in $Reviews) {
    $Instances = Get-MgIdentityGovernanceAccessReviewDefinitionInstance `
        -AccessReviewScheduleDefinitionId $Review.Id -All |
        Where-Object { $_.Status -eq "inProgress" }

    foreach ($Instance in $Instances) {
        $Row = [PSCustomObject]@{
            CampagneId  = $Review.Id
            Campagne    = $Review.DisplayName
            InstanceId  = $Instance.Id
            # StartDateTime / EndDateTime → fenêtre de révision ouverte.
            # Si EndDateTime est passé et Status toujours "inProgress" → campagne en retard.
            Debut       = $Instance.StartDateTime
            Fin         = $Instance.EndDateTime
            Statut      = $Instance.Status
        }
        $InstanceRows += $Row
    }
}

if ($InstanceRows.Count -gt 0) {
    $InstanceRows | Select-Object Campagne, Debut, Fin, Statut | Format-Table -AutoSize
} else {
    Write-Host "-> Aucune instance en cours." -ForegroundColor Yellow
}

# ========================================================================================
# ÉTAPE 4 : Audit des décisions prises par campagne
# ========================================================================================
Write-Host "`n4. Agrégation des décisions par campagne..." -ForegroundColor Cyan
Write-Host "`n=== DÉCISIONS PAR CAMPAGNE ===" -ForegroundColor Cyan

# Pour chaque campagne → pour chaque instance → on récupère toutes les décisions.
# Trois valeurs possibles pour Decision :
#   "Approve"     → reviewer a validé : l'accès est maintenu
#   "Deny"        → reviewer a révoqué : l'accès sera supprimé (si auto-apply activé)
#   "NotReviewed" → pas encore traité par le reviewer (ou campagne expirée sans décision)
#
# "NotReviewed" élevé = campagne mal suivie ou reviewers non notifiés — point d'attention.
$DecisionRows = @()

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
        $Total       = $AllDecisions.Count

        $Row = [PSCustomObject]@{
            CampagneId   = $Review.Id
            Campagne     = $Review.DisplayName
            Statut       = $Review.Status
            Total        = $Total
            Approuvés    = $Approved
            Révoqués     = $Denied
            NonTraités   = $NotReviewed
            # TauxTraitement : pourcentage de décisions effectivement prises.
            # Un taux bas signale des reviewers inactifs ou des notifications manquées.
            TauxTraitement = if ($Total -gt 0) {
                                 "$([math]::Round(($Approved + $Denied) / $Total * 100, 1))%"
                             } else { "N/A" }
        }
        $DecisionRows += $Row

        Write-Host "`nCampagne : $($Review.DisplayName)" -ForegroundColor White
        Write-Host "  Approuvés    : $Approved"    -ForegroundColor Green
        Write-Host "  Révoqués     : $Denied"      -ForegroundColor Red
        Write-Host "  Non traités  : $NotReviewed" -ForegroundColor Yellow
        Write-Host "  Taux         : $($Row.TauxTraitement)" -ForegroundColor Gray
    }
}

# ========================================================================================
# ÉTAPE 5 : Résumé
# ========================================================================================
Write-Host "`n=== RÉSUMÉ ===" -ForegroundColor Magenta
[PSCustomObject]@{
    TotalCampagnes      = $CampagneRows.Count
    InstancesEnCours    = $InstanceRows.Count
    CampagnesAvecDécisions = $DecisionRows.Count
    Scope               = "AccessReview.Read.All (lecture seule)"
    PointAttentionAudit = "TauxTraitement bas = reviewers inactifs ou notifications manquées"
} | Format-List

Write-Host "=== FIN DE L'AUDIT ACCESS REVIEWS ===" -ForegroundColor Green

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

# --- CSV 1 : Campagnes ---
# Colonnes exportées : Id, Nom, Statut, Recurrence, Debut, CreePar
# Colonnes disponibles non exportées :
#   $Review.Description                          : description de la campagne
#   $Review.ScheduleSettings.Recurrence.Range    : date de fin de récurrence
#   $Review.Scope                                : périmètre audité (groupes, rôles, apps)
if ($CampagneRows.Count -gt 0) {
    $CampagneRows | Export-Csv `
        -Path "$ExportPath\AR_Campagnes_$Timestamp.csv" `
        -Encoding UTF8 -NoTypeInformation
    Write-Host "-> Campagnes : $($CampagneRows.Count) ligne(s) — AR_Campagnes_$Timestamp.csv" -ForegroundColor Green
} else {
    Write-Host "-> Campagnes : aucune donnée à exporter." -ForegroundColor Yellow
}

# --- CSV 2 : Instances en cours ---
# Colonnes exportées : CampagneId, Campagne, InstanceId, Debut, Fin, Statut
# Colonnes disponibles non exportées :
#   $Instance.Reviewers         : liste des reviewers assignés à cette instance
#   $Instance.FallbackReviewers : reviewers de secours si les primaires n'agissent pas
#
# Ce CSV est le livrable opérationnel : quelles campagnes nécessitent une action immédiate.
if ($InstanceRows.Count -gt 0) {
    $InstanceRows | Export-Csv `
        -Path "$ExportPath\AR_InstancesEnCours_$Timestamp.csv" `
        -Encoding UTF8 -NoTypeInformation
    Write-Host "-> Instances en cours : $($InstanceRows.Count) ligne(s) — AR_InstancesEnCours_$Timestamp.csv" -ForegroundColor Green
} else {
    Write-Host "-> Instances en cours : aucune donnée à exporter." -ForegroundColor Yellow
}

# --- CSV 3 : Décisions par campagne ---
# Colonnes exportées : CampagneId, Campagne, Statut, Total, Approuvés, Révoqués,
#                      NonTraités, TauxTraitement
# Colonnes disponibles non exportées :
#   Détail par décision individuelle (qui a approuvé quoi) — nécessiterait un CSV
#   séparé en itérant sur $AllDecisions avec $_.ReviewedBy.UserPrincipalName
#   et $_.Principal.DisplayName pour identifier l'utilisateur concerné.
#
# Ce CSV est le livrable de reporting : vue synthétique par campagne,
# directement exploitable pour un tableau de bord gouvernance.
if ($DecisionRows.Count -gt 0) {
    $DecisionRows | Export-Csv `
        -Path "$ExportPath\AR_DecisionsParCampagne_$Timestamp.csv" `
        -Encoding UTF8 -NoTypeInformation
    Write-Host "-> Décisions : $($DecisionRows.Count) ligne(s) — AR_DecisionsParCampagne_$Timestamp.csv" -ForegroundColor Green
} else {
    Write-Host "-> Décisions : aucune donnée à exporter." -ForegroundColor Yellow
}

Write-Host "-> Export terminé dans : $ExportPath`n" -ForegroundColor Green

# ========================================================================================
# NETTOYAGE MÉMOIRE
# ========================================================================================
Remove-Variable Scopes, Reviews, CampagneRows, InstanceRows, DecisionRows,
                Review, Instance, Instances, AllDecisions,
                Approved, Denied, NotReviewed, Total, Row,
                ExportPath, Timestamp `
                -ErrorAction SilentlyContinue

# ========================================================================================
# FERMETURE — RESET DE SESSION TOTAL
# ========================================================================================
Disconnect-MgGraph -ErrorAction SilentlyContinue
Write-Host "Session MgGraph fermée proprement." -ForegroundColor Magenta
