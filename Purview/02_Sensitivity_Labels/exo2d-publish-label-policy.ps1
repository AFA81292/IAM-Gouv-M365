# ========================================================================================
# Exercice 2d : Sensitivity Labels — Publication via une Label Policy
# ========================================================================================
# Concept : Un label créé en 2a/2b/2c n'est pas encore visible par les utilisateurs.
# Pour qu'il apparaisse dans Word, Outlook, Teams, etc., il faut le "publier" via
# une Label Policy.
#
# Label Policy : c'est le lien entre les labels et les utilisateurs/groupes.
# Sans policy de publication, les labels existent dans Purview mais sont invisibles
# côté client.
#
# Ce que fait une Label Policy :
#   - Définit QUELS labels sont publiés
#   - Définit À QUI ils sont publiés (users, groupes, ou tout le tenant)
#   - Peut définir un label par défaut, obliger une justification au downgrade, etc.
#
# IMPORTANT — label group vs sublabels :
#   Un label group (parent) ne peut PAS être publié directement — New-LabelPolicy
#   lève une erreur si on l'inclut dans -Labels. On publie uniquement les sublabels.
#   Le label group "NormandySR2 - Confidentiel" devient visible automatiquement
#   côté client dès qu'au moins un de ses sublabels est publié.
#
# Ici on publie les 2 sublabels NormandySR2 vers le groupe GRP-Spectres créé en Entra 3c.
# Sur un tenant de prod on ciblerait un groupe métier ou un département entier.
#
# Prérequis : $env:MSAL_ENABLE_WAM = "0" dans la console avant de lancer le script
#   (bypasse WAM qui interfère avec Connect-IPPSSession sur certaines configs Windows).
#
# Module requis : ExchangeOnlineManagement
# Connexion : Connect-IPPSSession
# ========================================================================================

# --- OUVERTURE ---
$env:MSAL_ENABLE_WAM = "0"
Get-PSSession | Remove-PSSession
Connect-IPPSSession -UserPrincipalName GeptorAdmin@0n4mg.onmicrosoft.com -ShowBanner:$false

# --- ÉTAPE 0 : Vérification des labels à publier ---
Write-Host "0. Vérification des labels cibles..." -ForegroundColor Cyan

# On publie uniquement les sublabels — pas le label group parent (cf. note en en-tête).
$LabelsToPublish = @(
    "NormandySR2 - Interne",
    "NormandySR2 - Externe"
)

$MissingLabels = @()
foreach ($LabelName in $LabelsToPublish) {
    $Found = Get-Label -Identity $LabelName -ErrorAction SilentlyContinue
    if (-not $Found) {
        $MissingLabels += $LabelName
        Write-Host "   -> MANQUANT : '$LabelName'" -ForegroundColor Red
    } else {
        Write-Host "   -> OK : '$LabelName' (Guid : $($Found.Guid))" -ForegroundColor Green
    }
}

if ($MissingLabels.Count -gt 0) {
    Write-Host "`n-> ÉCHEC : $($MissingLabels.Count) label(s) manquant(s). Exécuter 2a/2b/2c au préalable." -ForegroundColor Red
    Get-PSSession | Remove-PSSession
    return
}
Write-Host "-> Tous les labels présents — poursuite du script.`n" -ForegroundColor Green

# --- ÉTAPE 1 : Recherche d'un nom disponible (auto-incrément) ---
Write-Host "1. Recherche d'un nom disponible pour la policy..." -ForegroundColor Cyan

$BasePolicyName = "LP-NormandySR2-Spectres"
$PolicyName     = $BasePolicyName
$Counter        = 2

while (Get-LabelPolicy -Identity $PolicyName -ErrorAction SilentlyContinue) {
    Write-Host "   '$PolicyName' déjà pris — test avec suffixe -v$Counter..." -ForegroundColor Yellow
    $PolicyName = "$BasePolicyName-v$Counter"
    $Counter++
}
Write-Host "-> Nom retenu : '$PolicyName'`n" -ForegroundColor Green

# --- ÉTAPE 2 : Création de la Label Policy ---
Write-Host "2. Création de la Label Policy '$PolicyName'..." -ForegroundColor Cyan

# -ModernGroupLocation : cible les groupes M365 (Unified Groups).
#   Différent de -ExchangeLocation (mailboxes individuelles) ou
#   -SharePointLocation (sites SPO). Un groupe M365 couvre Exchange + SPO + Teams
#   pour ses membres — c'est le ciblage le plus cohérent pour une policy de test.
try {
    $NewPolicy = New-LabelPolicy `
        -Name                $PolicyName `
        -Labels              $LabelsToPublish `
        -ModernGroupLocation "GRP-Spectres@0n4mg.onmicrosoft.com" `
        -Comment             "Publication des sublabels NormandySR2 vers le groupe de test GRP-Spectres." `
        -ErrorAction Stop

    Write-Host "-> Label Policy créée. Guid : $($NewPolicy.Guid)`n" -ForegroundColor Green
}
catch {
    Write-Host "-> Échec création : $_" -ForegroundColor Red
    Get-PSSession | Remove-PSSession
    return
}

# --- ÉTAPE 3 : Vérification ---
Write-Host "3. Vérification (propagation 30s)..." -ForegroundColor Cyan
Start-Sleep -Seconds 30

$CheckPolicy = Get-LabelPolicy -Identity $PolicyName -ErrorAction SilentlyContinue

if (-not $CheckPolicy) {
    Write-Host "-> ATTENTION : policy introuvable après vérification." -ForegroundColor Yellow
}
else {
    Write-Host "-> Label Policy confirmée :" -ForegroundColor Green

    # DistributionStatus : "Pending" est normal juste après création.
    # La distribution vers Exchange, SharePoint, Teams prend 1 à 24h.
    [PSCustomObject]@{
        Nom                = $CheckPolicy.Name
        Guid               = $CheckPolicy.Guid
        Labels             = ($CheckPolicy.Labels -join ", ")
        GroupesCibles      = ($CheckPolicy.ModernGroupLocation -join ", ")
        StatutDistribution = $CheckPolicy.DistributionStatus
    } | Format-List
}

# --- NETTOYAGE MÉMOIRE ---
Remove-Variable LabelsToPublish, MissingLabels, LabelName, Found, BasePolicyName, `
                PolicyName, Counter, NewPolicy, CheckPolicy -ErrorAction SilentlyContinue

# --- FERMETURE ---
Get-PSSession | Remove-PSSession
Write-Host "`nSession fermée." -ForegroundColor Magenta
