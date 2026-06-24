# ========================================================================================
# Exercice 2d : Sensitivity Labels — Publication via une Label Policy
# ========================================================================================
# Concept : Un label créé en 2a/2b/2c n'est pas encore visible par les utilisateurs.
# Pour qu'il apparaisse dans Word, Outlook, Teams, SharePoint, etc., il faut le
# "publier" via une Label Policy — c'est le lien entre les labels et les
# utilisateurs/groupes autorisés à les voir et à les appliquer.
#
# Une Label Policy définit :
#   - Quels labels sont publiés (liste explicite de sublabels)
#   - À qui (users individuels, groupes M365, ou tout le tenant)
#   - Optionnellement : un label par défaut, une justification obligatoire au downgrade
#
# Subtilité importante — label group vs sublabel :
#   Un label group (parent) ne peut PAS être publié directement.
#   New-LabelPolicy lève une erreur si on l'inclut dans -Labels.
#   On publie uniquement les sublabels.
#   Le groupe parent ("NormandySR2 - Confidentiel") devient visible côté client
#   automatiquement dès qu'au moins un de ses sublabels est publié.
#
# Ce que fait ce script :
#   1. Reset total de session
#   2. Vérifie que les labels à publier existent bien (prérequis 2a/2b/2c)
#   3. Recherche un nom de policy disponible (auto-incrément)
#   4. Crée la Label Policy ciblant le groupe GRP-Spectres
#   5. Vérifie la création depuis la source de vérité
#   6. Ferme proprement toutes les sessions
#
# Périmètre : on publie les 2 sublabels NormandySR2 vers le groupe GRP-Spectres
# (créé en Entra 3c). En production : viser un groupe métier ou un département entier,
# jamais un groupe de test avec des comptes fictifs.
#
# Module requis : ExchangeOnlineManagement
# Connexion     : Connect-IPPSSession
# ========================================================================================

# --- OUVERTURE — RESET DE SESSION TOTAL ---
# REX : des sessions fantômes restées ouvertes depuis un script précédent peuvent
# provoquer des erreurs silencieuses ou des authentifications croisées.
# On purge TOUT avant de commencer, sans exception.
#
# $env:MSAL_ENABLE_WAM = "0" : désactive WAM (Windows Authentication Manager) pour
# cette session PowerShell. WAM peut interférer avec Connect-IPPSSession sur certaines
# configurations Windows et provoquer des boucles d'authentification silencieuses.
# À positionner AVANT Connect-IPPSSession, pas après.
#
# Note : Connect-IPPSSession ne supporte pas -ShowBanner:$false — bandeau normal.
Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
Get-PSSession | Remove-PSSession
$env:MSAL_ENABLE_WAM = "0"
Connect-IPPSSession -UserPrincipalName GeptorAdmin@0n4mg.onmicrosoft.com

# ========================================================================================
# ÉTAPE 1 : Vérification des labels prérequis
# ========================================================================================
Write-Host "1. Vérification des labels cibles..." -ForegroundColor Cyan

# On publie uniquement les sublabels — pas le label group parent.
# Cf. concept en tête de script : le groupe parent s'affiche automatiquement côté
# client dès qu'un de ses sublabels est publié. Inutile (et impossible) de le lister ici.
$LabelsToPublish = @(
    "NormandySR2 - Interne",
    "NormandySR2 - Externe"
)

$MissingLabels = @()
foreach ($LabelName in $LabelsToPublish) {
    # Get-Label -Identity : recherche par nom exact (DisplayName).
    # -ErrorAction SilentlyContinue : si le label n'existe pas, retourne $null sans erreur.
    $Found = Get-Label -Identity $LabelName -ErrorAction SilentlyContinue
    if (-not $Found) {
        $MissingLabels += $LabelName
        Write-Host "   -> MANQUANT : '$LabelName'" -ForegroundColor Red
    } else {
        Write-Host "   -> OK : '$LabelName' [Guid : $($Found.Guid)]" -ForegroundColor Green
    }
}

if ($MissingLabels.Count -gt 0) {
    Write-Host "`n-> ARRÊT : $($MissingLabels.Count) label(s) manquant(s) — exécuter les exercices 2a/2b/2c au préalable." -ForegroundColor Red
    Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
    Get-PSSession | Remove-PSSession
    return
}

Write-Host "-> Tous les labels présents — poursuite du script.`n" -ForegroundColor Green

# ========================================================================================
# ÉTAPE 2 : Recherche d'un nom disponible (auto-incrément)
# ========================================================================================
Write-Host "2. Recherche d'un nom disponible pour la Label Policy..." -ForegroundColor Cyan

# Même logique d'auto-incrément que sur les scripts DLP et les labels :
# si "LP-NormandySR2-Spectres" existe déjà (run précédent), on tente
# "LP-NormandySR2-Spectres-v2", puis "-v3", etc.
$BasePolicyName = "LP-NormandySR2-Spectres"
$PolicyName     = $BasePolicyName
$Counter        = 2

while (Get-LabelPolicy -Identity $PolicyName -ErrorAction SilentlyContinue) {
    Write-Host "   '$PolicyName' déjà pris — test avec suffixe -v$Counter..." -ForegroundColor Yellow
    $PolicyName = "$BasePolicyName-v$Counter"
    $Counter++
}
Write-Host "-> Nom retenu pour la Label Policy : '$PolicyName'`n" -ForegroundColor Green

# ========================================================================================
# ÉTAPE 3 : Création de la Label Policy
# ========================================================================================
Write-Host "3. Création de la Label Policy '$PolicyName'..." -ForegroundColor Cyan

# -ModernGroupLocation vs autres paramètres de ciblage :
#
#   -ModernGroupLocation : cible les groupes M365 (Unified Groups).
#     Un groupe M365 couvre Exchange + SPO + Teams pour ses membres.
#     C'est le ciblage le plus cohérent pour une policy de test ciblée.
#
#   -ExchangeLocation   : cible des mailboxes individuelles (pas des groupes).
#
#   -SharePointLocation : cible des sites SPO individuels.
#
#   Pour publier vers tout le tenant : utiliser -ModernGroupLocation "All"
#   (ou l'équivalent selon la cmdlet — vérifier la syntaxe dans la doc Purview).
#   Sur un tenant de lab sans risque : "All" est acceptable pour tester la propagation.
#   En production : toujours cibler un groupe maîtrisé, jamais "All" sans validation.
try {
    $NewPolicy = New-LabelPolicy `
        -Name                $PolicyName `
        -Labels              $LabelsToPublish `
        -ModernGroupLocation "GRP-Spectres@0n4mg.onmicrosoft.com" `
        -Comment             "Exo 2d — Publication des sublabels NormandySR2 vers le groupe de test GRP-Spectres." `
        -ErrorAction Stop

    Write-Host "-> Label Policy créée avec succès." -ForegroundColor Green
    Write-Host "   Guid : $($NewPolicy.Guid)`n" -ForegroundColor Green
}
catch {
    Write-Host "-> Échec de la création de la Label Policy : $_" -ForegroundColor Red
    Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
    Get-PSSession | Remove-PSSession
    return
}

# ========================================================================================
# ÉTAPE 4 : Vérification depuis la source de vérité
# ========================================================================================
Write-Host "4. Vérification depuis le backend Purview..." -ForegroundColor Cyan

# REX : la propagation des Label Policies vers Exchange, SharePoint et Teams
# peut prendre de quelques minutes à 24h. Le délai ici couvre la réplication
# vers le backend Purview (confirmation que l'objet existe) — pas la distribution
# complète vers les workloads. DistributionStatus "Pending" est normal à ce stade.
Start-Sleep -Seconds 30

$CheckPolicy = Get-LabelPolicy -Identity $PolicyName -ErrorAction SilentlyContinue

if (-not $CheckPolicy) {
    Write-Host "-> ATTENTION : Label Policy introuvable lors de la vérification." -ForegroundColor Yellow
    Write-Host "   La réplication est peut-être encore en cours — vérifier dans le portail Purview." -ForegroundColor Yellow
} else {
    Write-Host "-> Label Policy confirmée :" -ForegroundColor Green
    [PSCustomObject]@{
        Nom                = $CheckPolicy.Name
        Guid               = $CheckPolicy.Guid
        Labels             = ($CheckPolicy.Labels -join ", ")
        GroupesCibles      = ($CheckPolicy.ModernGroupLocation -join ", ")
        # DistributionStatus "Pending" = distribution en cours vers Exchange/SPO/Teams.
        # Ce statut est NORMAL à la création — ne pas interpréter comme une erreur.
        # La propagation complète vers les clients (Word, Outlook, Teams) prend 1 à 24h.
        StatutDistribution = $CheckPolicy.DistributionStatus
    } | Format-List
}

# ========================================================================================
# RÉSUMÉ
# ========================================================================================
Write-Host "=== RÉSUMÉ ===" -ForegroundColor Magenta
[PSCustomObject]@{
    PolicyCréée         = $PolicyName
    LabelsPubiliés      = ($LabelsToPublish -join ", ")
    GroupeCible         = "GRP-Spectres@0n4mg.onmicrosoft.com"
    TypeCiblage         = "ModernGroupLocation (groupe M365 — couvre Exchange + SPO + Teams)"
    StatutDistribution  = if ($CheckPolicy) { $CheckPolicy.DistributionStatus } else { "Non vérifié" }
    PropagationClients  = "1 à 24h — les labels n'apparaissent pas instantanément dans Word/Outlook"
    LabelGroupParent    = "NormandySR2 - Confidentiel (visible auto dès qu'un sublabel est publié)"
} | Format-List

Write-Host "Info : DistributionStatus 'Pending' est normal à la création." -ForegroundColor Yellow
Write-Host "La propagation vers Exchange/SPO/Teams prend quelques minutes à 24h.`n" -ForegroundColor Yellow

# ========================================================================================
# NETTOYAGE MÉMOIRE
# ========================================================================================
Remove-Variable LabelsToPublish, MissingLabels, LabelName, Found,
                BasePolicyName, PolicyName, Counter,
                NewPolicy, CheckPolicy `
                -ErrorAction SilentlyContinue

# ========================================================================================
# FERMETURE — RESET DE SESSION TOTAL
# ========================================================================================
Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
Get-PSSession | Remove-PSSession
Write-Host "Sessions fermées proprement." -ForegroundColor Magenta
