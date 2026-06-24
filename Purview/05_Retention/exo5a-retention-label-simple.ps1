# ========================================================================================
# Exercice 5a : Retention Label simple — 3 ans depuis modification, sans review
# ========================================================================================
# Concept : un Retention Label seul (New-ComplianceTag) n'a aucun effet tant qu'il n'est
# pas publié via une Label Policy (exo 5c). Cet exo crée juste l'objet label.
#
# Delta pédagogique vs 5b/5c :
#   5a → label simple : suppression automatique à l'expiration, sans reviewer
#   5b → label avec disposition review : un humain valide avant suppression définitive
#   5c → label policy : publie les labels créés en 5a/5b pour les rendre visibles
#        des utilisateurs dans SharePoint, OneDrive, Exchange
#
# Deux paramètres clés à distinguer :
#
#   RetentionAction :
#     "Keep"          → conserve uniquement, ne supprime jamais
#     "Delete"        → suppression automatique et silencieuse à l'expiration
#                       (pas de coffre-fort consultable, pas de reviewer)
#     "KeepAndDelete" → conserve pendant la durée, puis supprime
#                       (ajoute un coffre-fort consultable avant suppression)
#
#   RetentionType :
#     "ModificationAgeInDays" → compteur démarre à la DERNIÈRE MODIFICATION du contenu
#                               Pertinent pour des documents vivants (contrats en cours,
#                               politiques internes régulièrement mises à jour)
#     "CreationAgeInDays"     → compteur démarre à la CRÉATION
#                               Pertinent pour des archives figées (factures, PV de réunion)
#     "EventAgeInDays"        → compteur démarre à un événement métier défini (départ
#                               d'un employé, fin de contrat...) — cf. exos avancés
#
# Thème Mass Effect : la Citadelle purge ses archives après 3 ans d'inactivité.
#
# Ce que fait ce script :
#   1. Reset total de session
#   2. Recherche un nom de label disponible (auto-incrément)
#   3. Crée le label avec suppression à 3 ans depuis dernière modification
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

$BaseLabelName = "RET-Citadel-3ans-Modification"
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

# RetentionDuration attend un nombre de JOURS — pas d'unité Year/Month acceptée.
# 3 ans = 365 × 3 = 1095 jours.
# Le champ DuréeApprox dans la vérification (étape 3) reconvertit en années pour
# faciliter la lecture humaine — l'API ne stocke que les jours.
#
# -Comment : visible dans le portail Purview Admin Center — utile pour tracer l'origine
# du label (exo, date, intention) quand on revient sur le tenant 6 mois plus tard.
try {
    $NewLabel = New-ComplianceTag `
        -Name              $LabelName `
        -RetentionAction   "Delete" `
        -RetentionDuration 1095 `
        -RetentionType     "ModificationAgeInDays" `
        -Comment           "Exo 5a — Purge silencieuse 3 ans après dernière modification." `
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
        # DispositionReview : ReviewerEmail non nul → un reviewer humain doit valider
        # avant suppression définitive. Ici $null = suppression automatique, sans review.
        # La variante avec reviewer est l'objet de l'exo 5b.
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
    RetentionAction   = "Delete (suppression silencieuse)"
    RetentionDuration = "1095 jours (3 ans)"
    RetentionType     = "ModificationAgeInDays (compteur depuis dernière modification)"
    DispositionReview = "Non (suppression automatique sans reviewer)"
    Statut            = "Créé — non publié — invisible des utilisateurs"
    ÉtapeSuivante     = "Publication via Label Policy : cf. exo 5c"
} | Format-List

# ========================================================================================
# NETTOYAGE MÉMOIRE
# ========================================================================================
Remove-Variable BaseLabelName, LabelName, Counter, NewLabel, CheckLabel `
                -ErrorAction SilentlyContinue

# ========================================================================================
# FERMETURE — RESET DE SESSION TOTAL
# ========================================================================================
Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
Get-PSSession | Remove-PSSession
Write-Host "Sessions fermées proprement." -ForegroundColor Magenta
