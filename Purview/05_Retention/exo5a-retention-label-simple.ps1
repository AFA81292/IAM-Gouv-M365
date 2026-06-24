# ========================================================================================
# Exercice 5b : Retention Label avec disposition review — 7 ans depuis création
# ========================================================================================
# Concept : contrairement à 5a (suppression silencieuse), ici un humain doit valider
# la suppression à l'expiration. RetentionAction "KeepAndDelete" + ReviewerEmail rempli =
# le contenu est gelé à l'expiration et apparaît dans la file de disposition review du
# reviewer désigné, qui choisit : approuver la suppression, prolonger, ou relabelliser.
#
# Delta pédagogique vs 5a :
#   5a → "Delete" + pas de reviewer : suppression automatique et silencieuse
#   5b → "KeepAndDelete" + ReviewerEmail : un humain valide avant toute suppression
#
# Piège RetentionAction + ReviewerEmail :
#   "Delete" seul n'accepte PAS de review humaine malgré ce qu'on pourrait penser.
#   ReviewerEmail n'a d'effet QUE combiné à "KeepAndDelete".
#   Logique : "KeepAndDelete" porte la sémantique "conserver jusqu'à décision humaine,
#   puis supprimer si approuvé". "Delete" seul = suppression automatique, pas de place
#   pour un reviewer dans le flux.
#   "Keep" seul ne supprime jamais rien — pas de disposition à reviewer non plus.
#
# RetentionType "CreationAgeInDays" :
#   Le compteur démarre à la CRÉATION du contenu, pas à sa dernière modification
#   (contrairement à 5a qui utilise "ModificationAgeInDays").
#   Pertinent pour des archives figées dont la date de référence est leur dépôt initial
#   (factures, PV de réunion, contrats signés) — une modification ultérieure de métadonnée
#   ne doit pas repousser l'horloge de rétention.
#
# Prérequis reviewer :
#   Le compte reviewer doit exister sur le tenant ET disposer des rôles :
#     - Disposition Management   → traiter les items en file de disposition
#     - View-Only Audit Logs     → consulter l'historique
#   Organization Management les inclut par défaut — sur ce tenant dev, GeptorAdmin convient.
#   En production : compte dédié, pas l'admin global.
#
# Thème Mass Effect : un Spectre valide la destruction des archives classifiées avant
# leur purge définitive — rien n'est détruit sans accord humain.
#
# Ce que fait ce script :
#   1. Reset total de session
#   2. Recherche un nom de label disponible (auto-incrément)
#   3. Crée le label avec disposition review à 7 ans depuis création
#   4. Vérifie la création depuis la source de vérité
#   5. Affiche un résumé
#   6. Ferme proprement toutes les sessions
#
# Module requis : ExchangeOnlineManagement
# Connexion     : Connect-IPPSSession
# Licence       : Microsoft Purview Records Management (inclus E5)
# ========================================================================================

# --- OUVERTURE — RESET DE SESSION TOTAL ---
# REX : des sessions fantômes restées ouvertes depuis un script précédent peuvent
# provoquer des erreurs silencieuses ou des authentifications croisées.
# On purge TOUT avant de commencer, sans exception.
#
# Ordre : Disconnect-ExchangeOnline → Remove-PSSession → workaround WAM → reconnexion.
# Note : Connect-IPPSSession ne supporte pas -ShowBanner:$false — bandeau normal.
Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
Get-PSSession | Remove-PSSession
$env:MSAL_ENABLE_WAM = "0"
Connect-IPPSSession -UserPrincipalName GeptorAdmin@0n4mg.onmicrosoft.com

# ========================================================================================
# ÉTAPE 1 : Recherche d'un nom disponible (auto-incrément)
# ========================================================================================
Write-Host "1. Recherche d'un nom disponible..." -ForegroundColor Cyan

$BaseLabelName = "RET-Citadel-7ans-Creation-Review"
$LabelName     = $BaseLabelName
$Counter       = 2
while (Get-ComplianceTag -Identity $LabelName -ErrorAction SilentlyContinue) {
    Write-Host "   '$LabelName' déjà pris — test avec suffixe -v$Counter..." -ForegroundColor Yellow
    $LabelName = "$BaseLabelName-v$Counter"
    $Counter++
}
Write-Host "-> Nom retenu : '$LabelName'`n" -ForegroundColor Green

# ========================================================================================
# ÉTAPE 2 : Création du label
# ========================================================================================
Write-Host "2. Création du label '$LabelName'..." -ForegroundColor Cyan

# 7 ans = 365 × 7 = 2555 jours.
# RetentionDuration attend un nombre de JOURS — pas d'unité Year/Month acceptée.
#
# -ReviewerEmail : l'UPN du reviewer désigné.
# Sur ce tenant dev, GeptorAdmin (Organization Management) dispose des rôles nécessaires.
# En production, ce serait un compte dédié de type "Records Manager" ou
# "Compliance Administrator" — jamais le compte admin global.
#
# Flux de disposition review à l'expiration :
#   1. Purview détecte que le label a expiré sur un item
#   2. L'item est gelé (plus modifiable, plus supprimable par les utilisateurs)
#   3. Une entrée apparaît dans la file "Disposition" du portail Purview
#   4. Le reviewer reçoit une notification et doit choisir :
#        → Approuver la suppression : l'item est définitivement supprimé
#        → Prolonger              : nouvelle durée de rétention ajoutée
#        → Relabelliser           : un autre label de rétention est appliqué
#   5. L'action du reviewer est loggée dans l'audit Purview (traçabilité complète)
$ReviewerUPN = "GeptorAdmin@0n4mg.onmicrosoft.com"

try {
    $NewLabel = New-ComplianceTag `
        -Name              $LabelName `
        -RetentionAction   "KeepAndDelete" `
        -RetentionDuration 2555 `
        -RetentionType     "CreationAgeInDays" `
        -ReviewerEmail     $ReviewerUPN `
        -Comment           "Exo 5b — Disposition review obligatoire 7 ans après création." `
        -ErrorAction Stop

    Write-Host "-> Label créé : $($NewLabel.Name)`n" -ForegroundColor Green
}
catch {
    Write-Host "-> Échec création : $_" -ForegroundColor Red
    Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
    Get-PSSession | Remove-PSSession
    return
}

# ========================================================================================
# ÉTAPE 3 : Vérification depuis la source de vérité
# ========================================================================================
Write-Host "3. Vérification depuis le backend Purview..." -ForegroundColor Cyan

# Sleep 30s : la propagation d'un nouveau ComplianceTag vers le backend Purview
# n'est pas instantanée. Lire trop tôt peut renvoyer une erreur "introuvable"
# qui n'est qu'une latence de réplication, pas un échec de création.
Start-Sleep -Seconds 30

$CheckLabel = Get-ComplianceTag -Identity $LabelName -ErrorAction SilentlyContinue

if ($CheckLabel) {
    Write-Host "-> Label confirmé :" -ForegroundColor Green
    [PSCustomObject]@{
        Nom               = $CheckLabel.Name
        Action            = $CheckLabel.RetentionAction
        DuréeJours        = $CheckLabel.RetentionDuration
        # Reconversion jours → années pour lecture humaine (l'API ne stocke que les jours)
        DuréeApprox       = "{0:N1} ans" -f ($CheckLabel.RetentionDuration / 365)
        Type              = $CheckLabel.RetentionType
        # ReviewerEmail est une collection — -join pour affichage propre si plusieurs reviewers
        Reviewer          = ($CheckLabel.ReviewerEmail -join ", ")
        # DispositionReview "Oui" confirme que ReviewerEmail a bien été pris en compte
        # Un "Non" ici indiquerait que KeepAndDelete + ReviewerEmail n'ont pas été combinés
        DispositionReview = if ($CheckLabel.ReviewerEmail) { "Oui" } else { "Non" }
    } | Format-List
} else {
    Write-Host "-> ATTENTION : label non trouvé lors de la vérification." -ForegroundColor Red
    Write-Host "   Réplication peut être encore en cours — vérifier dans Purview Admin Center." -ForegroundColor Yellow
}

# ========================================================================================
# RÉSUMÉ
# ========================================================================================
Write-Host "=== RÉSUMÉ ===" -ForegroundColor Magenta
[PSCustomObject]@{
    LabelCréé         = $LabelName
    RetentionAction   = "KeepAndDelete (conservation puis suppression si review approuvée)"
    RetentionDuration = "2555 jours (7 ans)"
    RetentionType     = "CreationAgeInDays (compteur depuis la création du contenu)"
    Reviewer          = $ReviewerUPN
    DispositionReview = "Oui — approbation humaine requise avant suppression définitive"
    Statut            = "Créé — non publié — invisible des utilisateurs"
    ÉtapeSuivante     = "Publication via Label Policy : cf. exo 5c"
} | Format-List

# ========================================================================================
# NETTOYAGE MÉMOIRE
# ========================================================================================
Remove-Variable BaseLabelName, LabelName, Counter, ReviewerUPN, NewLabel, CheckLabel `
                -ErrorAction SilentlyContinue

# ========================================================================================
# FERMETURE — RESET DE SESSION TOTAL
# ========================================================================================
Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
Get-PSSession | Remove-PSSession
Write-Host "Sessions fermées proprement." -ForegroundColor Magenta
