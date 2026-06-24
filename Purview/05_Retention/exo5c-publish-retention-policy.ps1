# ========================================================================================
# Exercice 5c : Publication des labels de rétention via une Retention Label Policy
# ========================================================================================
# Concept : un Retention Label créé (5a, 5b) n'a aucun effet tant qu'il n'est pas publié.
# La publication se fait en deux objets distincts :
#   New-RetentionCompliancePolicy → définit OÙ les labels seront disponibles
#                                   (Exchange, SharePoint, OneDrive...)
#   New-RetentionComplianceRule -PublishComplianceTag → définit QUEL label devient
#                                   sélectionnable à cet endroit
#
# Delta pédagogique vs 5a/5b :
#   5a → crée un label "Delete" silencieux (suppression automatique)
#   5b → crée un label "KeepAndDelete" avec reviewer (disposition review)
#   5c → publie ces deux labels pour les rendre visibles et applicables par les
#        utilisateurs dans SharePoint, OneDrive, Exchange
#        Sans cette étape, les labels de 5a et 5b n'existent que dans le backend
#        Purview — aucun utilisateur ne peut les voir ni les appliquer.
#
# Piège -PublishComplianceTag (vérifié et documenté) :
#   -PublishComplianceTag ne peut PAS être combiné avec -Name ou -ApplyComplianceTag.
#   Une règle publie UN SEUL label — pas de tableau de labels dans un seul appel.
#   Pour publier les deux labels (5a, 5b) dans la même policy, il faut DEUX appels
#   New-RetentionComplianceRule rattachés à la même -Policy, d'où la boucle en étape 4.
#
# Résolution par préfixe (pas par nom fixe) :
#   Si 5a/5b ont été relancés et ont pris un suffixe -v2/-v3 (auto-incrément),
#   un nom fixe en dur ici les manquerait silencieusement.
#   On cherche tous les labels dont le nom commence par le préfixe attendu,
#   et on prend le plus récent (WhenCreated) pour chaque famille.
#
# Délai de propagation asymétrique :
#   SharePoint/OneDrive → ~1 jour (max 7 jours)
#   Exchange            → systématiquement jusqu'à 7 jours (cycle Managed Folder Assistant)
#   DistributionStatus "Pending" peut donc rester longtemps après un script réussi —
#   c'est une latence normale, pas un signe d'échec.
#
# Prérequis : labels créés en 5a (RET-Citadel-3ans-Modification)
#             et 5b (RET-Citadel-7ans-Creation-Review).
#
# Ce que fait ce script :
#   1. Reset total de session
#   2. Résout les labels à publier (recherche par préfixe, prend le plus récent)
#   3. Recherche un nom de policy disponible (auto-incrément)
#   4. Crée la Retention Label Policy (définit les workloads)
#   5. Publie chaque label via une règle distincte (une règle = un label)
#   6. Vérifie la création depuis la source de vérité
#   7. Affiche un résumé
#   8. Ferme proprement toutes les sessions
#
# Module requis : ExchangeOnlineManagement
# Connexion     : Connect-IPPSSession
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
# ÉTAPE 1 : Résolution des labels à publier
# ========================================================================================
Write-Host "1. Résolution des labels à publier..." -ForegroundColor Cyan
Start-Sleep -Seconds 30

# On récupère tous les ComplianceTag du tenant une seule fois pour éviter
# de multiplier les appels Get-ComplianceTag dans la boucle.
$AllTags = Get-ComplianceTag

# Recherche par préfixe pour chaque famille de labels :
#   -like "$Prefix*" matche le nom exact ET les variantes incrémentées (-v2, -v3...)
#   Sort-Object WhenCreated -Descending + [0] → on prend toujours le plus récent
$LabelPrefixes = @(
    "RET-Citadel-3ans-Modification",
    "RET-Citadel-7ans-Creation-Review"
)

$ResolvedLabels = @()
foreach ($Prefix in $LabelPrefixes) {
    $Matches = $AllTags | Where-Object { $_.Name -like "$Prefix*" } |
        Sort-Object WhenCreated -Descending

    if ($Matches) {
        $Latest = $Matches[0].Name
        $ResolvedLabels += $Latest
        Write-Host "   OK      : '$Latest' retenu (préfixe '$Prefix')." -ForegroundColor Gray
        if ($Matches.Count -gt 1) {
            Write-Host "   Info    : $($Matches.Count) variantes trouvées — la plus récente est retenue." -ForegroundColor DarkGray
        }
    } else {
        Write-Host "   MANQUANT : aucun label '$Prefix*' trouvé." -ForegroundColor Yellow
        Write-Host "              Vérifier que les exos 5a et 5b ont bien été exécutés." -ForegroundColor Yellow
    }
}

if ($ResolvedLabels.Count -eq 0) {
    Write-Host "-> Aucun label résolu. Arrêt du script." -ForegroundColor Red
    Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
    Get-PSSession | Remove-PSSession
    return
}

Write-Host "-> $($ResolvedLabels.Count) label(s) résolu(s) pour publication.`n" -ForegroundColor Green

# ========================================================================================
# ÉTAPE 2 : Recherche d'un nom de policy disponible (auto-incrément)
# ========================================================================================
Write-Host "2. Recherche d'un nom disponible..." -ForegroundColor Cyan

# Thème Mass Effect : la Citadelle diffuse ses protocoles d'archivage aux Spectres.
# Get-RetentionCompliancePolicy (pas Get-DlpCompliancePolicy) — objets distincts
# malgré la ressemblance de nommage.
$BasePolicyName = "LBL-POL-Citadel-Archives"
$PolicyName     = $BasePolicyName
$Counter        = 2
while (Get-RetentionCompliancePolicy -Identity $PolicyName -ErrorAction SilentlyContinue) {
    Write-Host "   '$PolicyName' déjà pris — test avec suffixe -v$Counter..." -ForegroundColor Yellow
    $PolicyName = "$BasePolicyName-v$Counter"
    $Counter++
}
Write-Host "-> Nom retenu : '$PolicyName'`n" -ForegroundColor Green

# ========================================================================================
# ÉTAPE 3 : Création de la Retention Label Policy
# ========================================================================================
Write-Host "3. Création de la policy '$PolicyName'..." -ForegroundColor Cyan

# New-RetentionCompliancePolicy définit UNIQUEMENT les workloads (où les labels
# seront publiés). Elle ne sait pas encore quels labels publier — c'est le rôle
# des règles créées à l'étape suivante.
#
# ExchangeLocation "All" → toutes les boîtes aux lettres Exchange
# SharePointLocation "All" → tous les sites SharePoint
# OneDriveLocation n'est pas ajouté ici pour rester aligné avec le périmètre des exos
# 5a/5b — peut être ajouté librement en rajoutant -OneDriveLocation "All".
try {
    $NewPolicy = New-RetentionCompliancePolicy `
        -Name               $PolicyName `
        -ExchangeLocation   "All" `
        -SharePointLocation "All" `
        -Comment            "Exo 5c — Publication des labels RET-Citadel vers Exchange + SharePoint." `
        -ErrorAction Stop

    Write-Host "-> Policy créée : $($NewPolicy.Name)`n" -ForegroundColor Green
}
catch {
    Write-Host "-> Échec création policy : $_" -ForegroundColor Red
    Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
    Get-PSSession | Remove-PSSession
    return
}

# ========================================================================================
# ÉTAPE 4 : Publication de chaque label (une règle distincte par label)
# ========================================================================================
Write-Host "4. Publication des labels (une règle par label)..." -ForegroundColor Cyan

# Rappel du piège documenté en en-tête :
# -PublishComplianceTag est incompatible avec -Name et -ApplyComplianceTag.
# Un seul label par appel New-RetentionComplianceRule — d'où la boucle.
#
# Le nom de la règle est auto-généré par Purview quand -Name n'est pas fourni —
# comportement attendu et documenté pour les règles de publication de labels.
$CreatedRules = @()
foreach ($Label in $ResolvedLabels) {
    try {
        $Rule = New-RetentionComplianceRule `
            -Policy               $PolicyName `
            -PublishComplianceTag $Label `
            -ErrorAction Stop

        $CreatedRules += $Rule
        Write-Host "   OK    : '$Label' publié." -ForegroundColor Gray
    }
    catch {
        Write-Host "   ÉCHEC : publication de '$Label' — $_" -ForegroundColor Red
    }
}

if ($CreatedRules.Count -eq 0) {
    Write-Host "-> Aucune règle créée. Policy '$PolicyName' orpheline." -ForegroundColor Red
    Write-Host "   Nettoyage : Remove-RetentionCompliancePolicy -Identity '$PolicyName' -Confirm:`$false" -ForegroundColor Yellow
} else {
    Write-Host "-> $($CreatedRules.Count)/$($ResolvedLabels.Count) label(s) publié(s).`n" -ForegroundColor Green
}

# ========================================================================================
# ÉTAPE 5 : Vérification depuis la source de vérité
# ========================================================================================
Write-Host "5. Vérification depuis le backend Purview..." -ForegroundColor Cyan

# Sleep 30s : latence de propagation standard après création d'une RetentionCompliancePolicy.
# DistributionStatus peut rester "Pending" bien plus longtemps (jusqu'à 7 jours pour
# Exchange) — ce n'est pas un signe d'échec, voir note sur la propagation en en-tête.
Start-Sleep -Seconds 30

$CheckPolicy = Get-RetentionCompliancePolicy -Identity $PolicyName -ErrorAction SilentlyContinue
$CheckRules  = Get-RetentionComplianceRule   -Policy   $PolicyName -ErrorAction SilentlyContinue

if ($CheckPolicy) {
    Write-Host "-> Policy confirmée :" -ForegroundColor Green
    [PSCustomObject]@{
        Nom           = $CheckPolicy.Name
        Exchange      = if ($CheckPolicy.ExchangeLocation)   { "Oui" } else { "Non" }
        SharePoint    = if ($CheckPolicy.SharePointLocation) { "Oui" } else { "Non" }
        DistribStatus = $CheckPolicy.DistributionStatus
    } | Format-List
} else {
    Write-Host "-> ATTENTION : policy non trouvée lors de la vérification." -ForegroundColor Red
}

if ($CheckRules) {
    Write-Host "-> Règles confirmées :" -ForegroundColor Green
    $CheckRules | Select-Object Name, PublishComplianceTag | Format-Table -AutoSize
} else {
    Write-Host "-> ATTENTION : aucune règle trouvée lors de la vérification." -ForegroundColor Red
}

# ========================================================================================
# RÉSUMÉ
# ========================================================================================
Write-Host "=== RÉSUMÉ ===" -ForegroundColor Magenta
[PSCustomObject]@{
    PolicyCréée    = $PolicyName
    LabelsPubliés  = ($ResolvedLabels -join " | ")
    Workloads      = "Exchange, SharePoint"
    DistribStatus  = if ($CheckPolicy) { $CheckPolicy.DistributionStatus } else { "Non vérifié" }
    PropagationSPO = "~1 jour (max 7 jours)"
    PropagationEXO = "Jusqu'à 7 jours (cycle Managed Folder Assistant)"
    NoteStatut     = "DistributionStatus 'Pending' = normal à la création, pas un échec"
} | Format-List

# ========================================================================================
# NETTOYAGE MÉMOIRE
# ========================================================================================
Remove-Variable LabelPrefixes, AllTags, Prefix, Matches, Latest, ResolvedLabels,
                BasePolicyName, PolicyName, Counter,
                NewPolicy, CreatedRules, Rule, CheckPolicy, CheckRules `
                -ErrorAction SilentlyContinue

# ========================================================================================
# FERMETURE — RESET DE SESSION TOTAL
# ========================================================================================
Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
Get-PSSession | Remove-PSSession
Write-Host "Sessions fermées proprement." -ForegroundColor Magenta
