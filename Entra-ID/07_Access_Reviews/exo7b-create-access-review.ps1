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
# Delta pédagogique vs 7a :
#   7a → lecture seule : audit des campagnes existantes, instances en cours, décisions
#   7b → création : on définit une nouvelle campagne avec récurrence, reviewer,
#        décision automatique par défaut et notifications mail
#
# Scénario : campagne trimestrielle sur le groupe Witchers-Brotherhood.
# Reviewer : Geralt. Décision par défaut si pas de réponse : Deny.
#
# Architecture d'une campagne Access Review :
#   scope     → ce qu'on révise (membres d'un groupe, assignations de rôles...)
#   reviewers → qui fait la révision (user, manager, owner du groupe...)
#   settings  → durée de l'instance, récurrence, décision automatique, notifications
#
# Piège technique camelCase :
#   Toutes les clés du BodyParameter doivent être en camelCase strict.
#   Le SDK Graph ne traduit pas PascalCase → camelCase lors de la sérialisation JSON.
#   Une clé mal casée = propriété ignorée = 400 BadRequest silencieux.
#
# Ce que fait ce script :
#   1. Reset total de session
#   2. Définit les variables (groupe, reviewer, nom de campagne)
#   3. Récupère les IDs du groupe et du reviewer
#   4. Recherche un nom de campagne disponible (auto-incrément)
#   5. Crée la campagne avec récurrence trimestrielle
#   6. Vérifie la création depuis la source de vérité
#   7. Ferme proprement toutes les sessions
#
# Module requis : Microsoft.Graph.Identity.Governance, Microsoft.Graph.Groups,
#                 Microsoft.Graph.Users
# Connexion     : Connect-MgGraph
# ========================================================================================

# --- OUVERTURE — RESET DE SESSION TOTAL ---
# AccessReview.ReadWrite.All : créer et modifier des campagnes de révision
# Group.Read.All             : récupérer l'ID du groupe cible
# User.Read.All              : récupérer l'ID du reviewer
# -ContextScope Process      : bypasse le cache WAM — voir REX exercices 5b/5c.
# REX : sans ce paramètre, WAM réutilise un token de session précédente avec des
# scopes insuffisants — cause la plus fréquente des 403 silencieux sur les scripts Graph.
$Scopes = @(
    "AccessReview.ReadWrite.All",
    "Group.Read.All",
    "User.Read.All"
)

Disconnect-MgGraph -ErrorAction SilentlyContinue
Connect-MgGraph -Scopes $Scopes -ContextScope Process -NoWelcome

# ========================================================================================
# ÉTAPE 1 : Définition des variables
# ========================================================================================
Write-Host "1. Définition des variables..." -ForegroundColor Cyan

$GroupName      = "Witchers-Brotherhood"
$ReviewerUPN    = "geralt@0n4mg.onmicrosoft.com"
$BaseReviewName = "Révision trimestrielle — Witchers-Brotherhood"

Write-Host "-> Groupe cible  : $GroupName" -ForegroundColor Green
Write-Host "-> Reviewer      : $ReviewerUPN" -ForegroundColor Green
Write-Host "-> Nom de base   : $BaseReviewName`n" -ForegroundColor Green

# ========================================================================================
# ÉTAPE 2 : Récupération des IDs groupe et reviewer
# ========================================================================================
Write-Host "2. Récupération du groupe et du reviewer..." -ForegroundColor Cyan
Start-Sleep -Seconds 30

$Group    = Get-MgGroup -Filter "displayName eq '$GroupName'" -ErrorAction SilentlyContinue
$Reviewer = Get-MgUser  -UserId $ReviewerUPN                  -ErrorAction SilentlyContinue

if (-not $Group) {
    Write-Host "-> Groupe '$GroupName' introuvable. Vérifier le displayName exact." -ForegroundColor Red
    Disconnect-MgGraph -ErrorAction SilentlyContinue
    return
}
if (-not $Reviewer) {
    Write-Host "-> Reviewer '$ReviewerUPN' introuvable. Vérifier l'UPN." -ForegroundColor Red
    Disconnect-MgGraph -ErrorAction SilentlyContinue
    return
}

Write-Host "-> Groupe   : $($Group.DisplayName) [ID : $($Group.Id)]" -ForegroundColor Green
Write-Host "-> Reviewer : $($Reviewer.DisplayName) [ID : $($Reviewer.Id)]`n" -ForegroundColor Green

# ========================================================================================
# ÉTAPE 3 : Recherche d'un nom de campagne disponible (auto-incrément)
# ========================================================================================
Write-Host "3. Recherche d'un nom de campagne disponible..." -ForegroundColor Cyan

$ReviewName = $BaseReviewName
$Counter    = 2
while (
    Get-MgIdentityGovernanceAccessReviewDefinition -All -ErrorAction SilentlyContinue |
    Where-Object { $_.DisplayName -eq $ReviewName }
) {
    Write-Host "   '$ReviewName' déjà pris — test avec suffixe -v$Counter..." -ForegroundColor Yellow
    $ReviewName = "$BaseReviewName-v$Counter"
    $Counter++
}
Write-Host "-> Nom retenu pour la campagne : '$ReviewName'`n" -ForegroundColor Green

# ========================================================================================
# ÉTAPE 4 : Construction et création de la campagne
# ========================================================================================
Write-Host "4. Création de la campagne '$ReviewName'..." -ForegroundColor Cyan

# La date du jour sert à deux choses liées :
#   - range.startDate   : date de démarrage de la première instance
#   - pattern.dayOfMonth: jour du mois de récurrence
# L'API exige que ces deux valeurs soient cohérentes — si startDate est le 15,
# dayOfMonth doit aussi être 15. Un désalignement provoque un 400 BadRequest.
$CurrentDate = Get-Date

$ReviewParams = @{
    displayName          = $ReviewName
    # descriptionForAdmins   : visible dans le portail Entra Admin Center
    # descriptionForReviewers: visible par Geralt dans My Access (myaccess.microsoft.com)
    descriptionForAdmins    = "Révision trimestrielle des membres du groupe $GroupName."
    descriptionForReviewers = "Veuillez réviser les membres de ce groupe et confirmer ou révoquer leurs accès."

    # scope = ce qu'on révise
    # "@odata.type" #microsoft.graph.accessReviewQueryScope : obligatoire pour les scopes
    # de type requête Graph — sans lui l'API ne sait pas interpréter le champ query.
    # query "/groups/id/members" : révise les membres directs du groupe.
    # Limitation API v1.0 : "/groups/id/transitiveMembers" provoque un 400 —
    # les membres imbriqués (via sous-groupes) ne sont pas supportés en v1.0.
    scope = @{
        "@odata.type" = "#microsoft.graph.accessReviewQueryScope"
        query         = "/groups/$($Group.Id)/members"
        queryType     = "MicrosoftGraph"
    }

    # reviewers = qui révise
    # "@odata.type" #microsoft.graph.accessReviewReviewerScope : obligatoire —
    # sans lui l'API refuse le reviewer avec une erreur de typage.
    # Alternatives pour query :
    #   "./manager"          → le manager direct de chaque membre révisé
    #   "./owners"           → les owners du groupe
    #   "/users/id"          → un reviewer fixe (cas ici : Geralt)
    #   "/groups/id/members" → un groupe entier comme reviewer
    reviewers = @(
        @{
            "@odata.type" = "#microsoft.graph.accessReviewReviewerScope"
            query         = "/users/$($Reviewer.Id)"
            queryType     = "MicrosoftGraph"
        }
    )

    settings = @{
        # instanceDurationInDays : durée d'ouverture de chaque instance.
        # Geralt a 14 jours pour répondre. Passé ce délai → defaultDecision s'applique.
        instanceDurationInDays = 14

        # Récurrence trimestrielle :
        #   type "absoluteMonthly" = même jour chaque mois (vs "relativeMonthly" = "le 2e lundi")
        #   interval = 3           = tous les 3 mois
        #   dayOfMonth             = synchronisé avec startDate (voir note $CurrentDate ci-dessus)
        #   range type "noEnd"     = tourne indéfiniment jusqu'à suppression manuelle
        #                           Alternative : "endDate" avec une date de fin, ou
        #                           "numbered" avec un nombre d'occurrences maximum
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

        # defaultDecisionEnabled = $true : active la décision automatique
        # defaultDecision "Deny"          : si Geralt ne répond pas → accès révoqué
        #   Alternatives :
        #     "Approve"        → accès maintenu (moins sécurisé — à éviter sur groupes sensibles)
        #     "Recommendation" → Microsoft décide selon l'activité du compte (connexions récentes)
        defaultDecisionEnabled = $true
        defaultDecision        = "Deny"

        # justificationRequiredOnApproval : Geralt doit saisir une raison pour chaque
        # approbation — la justification est loggée dans l'audit Access Reviews.
        # Bonne pratique : toujours activer sur les groupes à accès sensible.
        justificationRequiredOnApproval = $true

        # mailNotificationsEnabled     : active l'envoi du mail initial à Geralt
        # reminderNotificationsEnabled : envoie des rappels avant expiration de l'instance
        mailNotificationsEnabled     = $true
        reminderNotificationsEnabled = $true
    }
}

try {
    $NewReview = New-MgIdentityGovernanceAccessReviewDefinition `
        -BodyParameter $ReviewParams -ErrorAction Stop

    Write-Host "-> Campagne créée [ID : $($NewReview.Id)]" -ForegroundColor Green
    Write-Host "   Récurrence      : trimestrielle — le $($CurrentDate.Day) de chaque mois" -ForegroundColor Yellow
    Write-Host "   Décision défaut : Deny (si pas de réponse sous 14 jours)`n" -ForegroundColor Yellow
}
catch {
    Write-Host "-> Échec de la création : $_" -ForegroundColor Red
    Disconnect-MgGraph -ErrorAction SilentlyContinue
    return
}

# ========================================================================================
# ÉTAPE 5 : Vérification depuis la source de vérité
# ========================================================================================
Write-Host "5. Vérification depuis Entra..." -ForegroundColor Cyan
Start-Sleep -Seconds 30

try {
    $CheckReview = Get-MgIdentityGovernanceAccessReviewDefinition `
        -AccessReviewScheduleDefinitionId $NewReview.Id -ErrorAction Stop

    Write-Host "-> Campagne confirmée :" -ForegroundColor Green
    [PSCustomObject]@{
        Id          = $CheckReview.Id
        DisplayName = $CheckReview.DisplayName
        Status      = $CheckReview.Status
        Reviewer    = $ReviewerUPN
        Recurrence  = "Trimestrielle (absoluteMonthly, interval 3)"
        DefaultDec  = "Deny après 14 jours sans réponse"
    } | Format-List
}
catch {
    Write-Host "-> Campagne créée mais réplication encore en cours." -ForegroundColor Yellow
    Write-Host "   ID : $($NewReview.Id) — vérifier dans Entra Admin Center" -ForegroundColor Yellow
    Write-Host "   Identity Governance → Access Reviews." -ForegroundColor Yellow
}

# ========================================================================================
# RÉSUMÉ
# ========================================================================================
Write-Host "=== RÉSUMÉ ===" -ForegroundColor Magenta
[PSCustomObject]@{
    CampagneCréée   = $ReviewName
    CampagneID      = $NewReview.Id
    GroupeCible     = "$($Group.DisplayName) [$($Group.Id)]"
    Reviewer        = "$($Reviewer.DisplayName) [$ReviewerUPN]"
    Recurrence      = "Trimestrielle — le $($CurrentDate.Day) de chaque mois"
    DuréeInstance   = "14 jours"
    DécisionDéfaut  = "Deny (si pas de réponse)"
    Notifications   = "Mail + rappels activés"
} | Format-List

# ========================================================================================
# NETTOYAGE MÉMOIRE
# ========================================================================================
Remove-Variable Scopes, GroupName, ReviewerUPN, BaseReviewName, ReviewName, Counter,
                CurrentDate, Group, Reviewer, ReviewParams, NewReview, CheckReview `
                -ErrorAction SilentlyContinue

# ========================================================================================
# FERMETURE — RESET DE SESSION TOTAL
# ========================================================================================
Disconnect-MgGraph -ErrorAction SilentlyContinue
Write-Host "Session MgGraph fermée proprement." -ForegroundColor Magenta
