# ========================================================================================
# Exercice 5c : Publication des labels de rétention via une Retention Label Policy
# ========================================================================================
# Concept : un Retention Label créé (5a, 5b) n'a aucun effet tant qu'il n'est pas publié.
# La publication se fait via New-RetentionCompliancePolicy (définit OÙ : Exchange,
# SharePoint...) + New-RetentionComplianceRule -PublishComplianceTag (définit QUEL label
# devient sélectionnable à cet endroit).
#
# Piège vérifié en amont : -PublishComplianceTag ne peut PAS être combiné avec -Name ou
# -ApplyComplianceTag — une règle publie UN SEUL label. Pour publier les deux labels
# (5a, 5b) dans la même policy, il faut donc DEUX appels New-RetentionComplianceRule
# rattachés à la même -Policy, pas une seule règle avec un tableau de labels.
#
# Délai de propagation asymétrique : SharePoint/OneDrive ~1 jour (max 7), Exchange
# systématiquement jusqu'à 7 jours (cycle Managed Folder Assistant). DistributionStatus
# peut donc rester "Pending" longtemps après un script qui a pourtant réussi — normal,
# pas un signe d'échec.
#
# Prérequis : labels créés en 5a (RET-Citadel-3ans-Modification) et 5b
# (RET-Citadel-7ans-Creation-Review).
#
# Module requis : ExchangeOnlineManagement
# Connexion : Connect-IPPSSession
# ========================================================================================

# --- OUVERTURE ---
Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
Get-PSSession | Remove-PSSession
$env:MSAL_ENABLE_WAM = "0"
Connect-IPPSSession -UserPrincipalName GeptorAdmin@0n4mg.onmicrosoft.com

# --- ÉTAPE 1 : Vérification de l'existence des labels cibles ---
Write-Host "1. Vérification des labels à publier..." -ForegroundColor Cyan

$LabelNames = @(
    "RET-Citadel-3ans-Modification",
    "RET-Citadel-7ans-Creation-Review"
)

$ResolvedLabels = @()
foreach ($Name in $LabelNames) {
    $Label = Get-ComplianceTag -Identity $Name -ErrorAction SilentlyContinue
    if ($Label) {
        $ResolvedLabels += $Label.Name
        Write-Host "   OK : '$Name' trouvé." -ForegroundColor Gray
    } else {
        Write-Host "   MANQUANT : '$Name' introuvable. Vérifier exos 5a/5b." -ForegroundColor Yellow
    }
}

if ($ResolvedLabels.Count -eq 0) {
    Write-Host "-> Aucun label résolu. Arrêt du script." -ForegroundColor Red
    Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
    Get-PSSession | Remove-PSSession
    return
}

Write-Host "-> $($ResolvedLabels.Count) label(s) résolu(s).`n" -ForegroundColor Green

# --- ÉTAPE 2 : Recherche d'un nom disponible ---
# Thème Mass Effect : la Citadelle diffuse ses protocoles d'archivage aux Spectres.
Write-Host "2. Recherche d'un nom disponible..." -ForegroundColor Cyan

$BasePolicyName = "LBL-POL-Citadel-Archives"
$PolicyName     = $BasePolicyName
$Counter        = 2
while (Get-RetentionCompliancePolicy -Identity $PolicyName -ErrorAction SilentlyContinue) {
    $PolicyName = "$BasePolicyName-v$Counter"
    $Counter++
}
Write-Host "-> Nom retenu : '$PolicyName'`n" -ForegroundColor Green

# --- ÉTAPE 3 : Création de la policy (définit l'emplacement, pas encore les labels) ---
try {
    $NewPolicy = New-RetentionCompliancePolicy `
        -Name             $PolicyName `
        -ExchangeLocation "All" `
        -SharePointLocation "All" `
        -Comment          "Exo 5c — Publication des labels RET-Citadel vers Exchange + SharePoint." `
        -ErrorAction Stop

    Write-Host "3. Policy créée : $($NewPolicy.Name)`n" -ForegroundColor Green
}
catch {
    Write-Host "-> Échec création policy : $_" -ForegroundColor Red
    Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
    Get-PSSession | Remove-PSSession
    return
}

# --- ÉTAPE 4 : Publication de chaque label (une règle distincte par label) ---
# -PublishComplianceTag est incompatible avec -Name et -ApplyComplianceTag : chaque
# appel ne peut publier qu'UN label. D'où la boucle plutôt qu'un seul appel groupé.
Write-Host "4. Publication des labels (une règle par label)..." -ForegroundColor Cyan

$CreatedRules = @()
foreach ($Label in $ResolvedLabels) {
    try {
        $Rule = New-RetentionComplianceRule `
            -Policy             $PolicyName `
            -PublishComplianceTag $Label `
            -ErrorAction Stop

        $CreatedRules += $Rule
        Write-Host "   OK : '$Label' publié." -ForegroundColor Gray
    }
    catch {
        Write-Host "   ÉCHEC : publication de '$Label' — $_" -ForegroundColor Red
    }
}

if ($CreatedRules.Count -eq 0) {
    Write-Host "-> Aucune règle créée. Policy '$PolicyName' orpheline." -ForegroundColor Red
    Write-Host "   Supprimer via : Remove-RetentionCompliancePolicy -Identity '$PolicyName' -Confirm:`$false" -ForegroundColor Yellow
} else {
    Write-Host "-> $($CreatedRules.Count)/$($ResolvedLabels.Count) label(s) publié(s).`n" -ForegroundColor Green
}

# --- ÉTAPE 5 : Vérification depuis la source de vérité ---
Write-Host "5. Vérification..." -ForegroundColor Cyan
Start-Sleep -Seconds 30

$CheckPolicy = Get-RetentionCompliancePolicy -Identity $PolicyName -ErrorAction SilentlyContinue
$CheckRules  = Get-RetentionComplianceRule -Policy $PolicyName -ErrorAction SilentlyContinue

if ($CheckPolicy) {
    [PSCustomObject]@{
        Nom            = $CheckPolicy.Name
        Exchange       = if ($CheckPolicy.ExchangeLocation) { "Oui" } else { "Non" }
        SharePoint     = if ($CheckPolicy.SharePointLocation) { "Oui" } else { "Non" }
        DistribStatus  = $CheckPolicy.DistributionStatus
    } | Format-List
}

if ($CheckRules) {
    $CheckRules | Select-Object Name, PublishComplianceTag | Format-Table -AutoSize
}

# --- RÉSUMÉ ---
Write-Host "=== RÉSUMÉ ===" -ForegroundColor Magenta
Write-Host "Propagation : jusqu'à 1 jour pour SharePoint, jusqu'à 7 jours pour Exchange" -ForegroundColor Yellow
Write-Host "(cycle Managed Folder Assistant). DistributionStatus 'Pending' = normal," -ForegroundColor Yellow
Write-Host "pas un échec.`n" -ForegroundColor Yellow

[PSCustomObject]@{
    PolicyCréée    = $PolicyName
    LabelsPubliés  = ($ResolvedLabels -join " | ")
    Workloads      = "Exchange, SharePoint"
} | Format-List

# --- NETTOYAGE MÉMOIRE ---
Remove-Variable LabelNames, Name, Label, ResolvedLabels,
                BasePolicyName, PolicyName, Counter,
                NewPolicy, CreatedRules, Rule, CheckPolicy, CheckRules `
                -ErrorAction SilentlyContinue

# --- FERMETURE ---
Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
Get-PSSession | Remove-PSSession
Write-Host "Sessions fermées proprement." -ForegroundColor Magenta
