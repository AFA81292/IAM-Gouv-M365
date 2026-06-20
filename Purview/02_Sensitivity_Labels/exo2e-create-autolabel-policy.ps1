# ========================================================================================
# Exercice 2e : Sensitivity Labels — Politique d'auto-labeling côté service (Exchange)
# ========================================================================================
# Contrairement aux exos précédents (label appliqué manuellement ou publié pour choix
# utilisateur), ici c'est Purview qui scanne le contenu en arrière-plan et applique le
# label tout seul, sans action humaine — y compris sur des emails déjà envoyés.
#
# Deux objets séparés à créer :
#   New-AutoSensitivityLabelPolicy → le conteneur (label à appliquer, emplacement, mode)
#   New-AutoSensitivityLabelRule   → la condition (quel SIT, quel seuil)
# Une policy sans règle ne détecte rien.
#
# Module requis : ExchangeOnlineManagement
# Connexion : Connect-IPPSSession
# ========================================================================================

# --- OUVERTURE ---
$env:MSAL_ENABLE_WAM = "0"
Get-PSSession | Remove-PSSession
Connect-IPPSSession -UserPrincipalName GeptorAdmin@0n4mg.onmicrosoft.com -ShowBanner:$false

# --- ÉTAPE 0 : Vérification des prérequis ---
Write-Host "0. Vérification des prérequis..." -ForegroundColor Cyan

$TargetLabel = "NormandySR2 - Interne"
$LabelCheck  = Get-Label -Identity $TargetLabel -ErrorAction SilentlyContinue

if (-not $LabelCheck) {
    Write-Host "   -> MANQUANT : label '$TargetLabel'. Exécuter 2a/2b au préalable." -ForegroundColor Red
    Get-PSSession | Remove-PSSession
    return
}
Write-Host "   -> OK : label '$TargetLabel' trouvé (Guid : $($LabelCheck.Guid))." -ForegroundColor Green

$TargetSIT = "Cerberus Corp - Numéro de Badge Interne"
$SITCheck  = Get-DlpSensitiveInformationType | Where-Object { $_.Name -eq $TargetSIT }

if (-not $SITCheck) {
    Write-Host "   -> MANQUANT : SIT '$TargetSIT'. Exécuter 1b au préalable." -ForegroundColor Red
    Get-PSSession | Remove-PSSession
    return
}
Write-Host "   -> OK : SIT '$TargetSIT' trouvé.`n" -ForegroundColor Green

# --- ÉTAPE 1 : Recherche d'un nom disponible (auto-incrément) ---
Write-Host "1. Recherche d'un nom disponible pour la policy..." -ForegroundColor Cyan

$BasePolicyName = "AL-NormandySR2-BadgeGCORP"
$PolicyName     = $BasePolicyName
$Counter        = 2

while (Get-AutoSensitivityLabelPolicy -Identity $PolicyName -ErrorAction SilentlyContinue) {
    Write-Host "   '$PolicyName' déjà pris — test avec suffixe -v$Counter..." -ForegroundColor Yellow
    $PolicyName = "$BasePolicyName-v$Counter"
    $Counter++
}
Write-Host "-> Nom retenu : '$PolicyName'`n" -ForegroundColor Green

# --- ÉTAPE 2 : Création de la policy ---
Write-Host "2. Création de la policy '$PolicyName'..." -ForegroundColor Cyan

# Mode TestWithoutNotifications, pas TestWithNotifications : ce dernier est
# documenté par Microsoft Learn comme valeur valide pour cette cmdlet, mais en test
# réel, New-AutoSensitivityLabelPolicy le rejette (ModeNotSupportedByMipCmdletException)
# — et l'astuce "créer en Test puis basculer via Set-" ne marche pas non plus, le
# Set- refuse la même valeur. Concrètement, TestWithNotifications n'est aujourd'hui
# pilotable que depuis le portail Purview, pas en PowerShell.
try {
    $NewPolicy = New-AutoSensitivityLabelPolicy `
        -Name                $PolicyName `
        -ExchangeLocation    "All" `
        -ApplySensitivityLabel $TargetLabel `
        -Mode                "TestWithoutNotifications" `
        -Comment             "Auto-labeling Exchange : détecte le SIT badge GCORP (1b), applique NormandySR2 - Interne (2b)." `
        -ErrorAction Stop

    Write-Host "-> Policy créée. Guid : $($NewPolicy.Guid)`n" -ForegroundColor Green
}
catch {
    Write-Host "-> Échec création policy : $_" -ForegroundColor Red
    Get-PSSession | Remove-PSSession
    return
}

# --- ÉTAPE 3 : Création de la règle ---
Write-Host "3. Création de la règle de détection..." -ForegroundColor Cyan

# Pas de minconfidence ici : le SIT (1b) a déjà ses propres seuils (85/75) dans son
# XML. minconfidence filtrerait par-dessus — on laisse Purview évaluer nativement et
# on ne contraint que le nombre d'occurrences.
#
# -Workload est différent de -ExchangeLocation vu sur la policy : ExchangeLocation
# définit le périmètre global de la policy, Workload définit sur quoi CETTE règle
# précise s'évalue. Paramètre obligatoire, non documenté comme tel par défaut.
#
# Le nom de règle doit être unique sur tout le scénario AutoLabeling du tenant, pas
# juste dans sa policy — on le dérive donc du même suffixe que $PolicyName pour
# qu'ils avancent toujours ensemble.
$RuleName = $PolicyName -replace [regex]::Escape($BasePolicyName), "Rule-DetectBadgeGCORP"

try {
    $NewRule = New-AutoSensitivityLabelRule `
        -Policy $PolicyName `
        -Name   $RuleName `
        -Workload "Exchange" `
        -ContentContainsSensitiveInformation @{
            Name     = $TargetSIT
            MinCount = "2"
        } `
        -ErrorAction Stop

    Write-Host "-> Règle créée : '$RuleName' (MinCount = 2, Workload = Exchange).`n" -ForegroundColor Green
}
catch {
    Write-Host "-> Échec création règle : $_" -ForegroundColor Red
    Write-Host "-> Nettoyage : suppression de la policy orpheline '$PolicyName'..." -ForegroundColor Yellow

    # Pas de SilentlyContinue : Remove- peut échouer silencieusement si l'objet est
    # déjà en PendingDeletion (cf. note étape 3 bis) — on veut le voir, pas le rater.
    try {
        Remove-AutoSensitivityLabelPolicy -Identity $PolicyName -Confirm:$false -ErrorAction Stop
        Write-Host "-> Policy orpheline supprimée.`n" -ForegroundColor Green
    }
    catch {
        Write-Host "-> ÉCHEC nettoyage automatique : $_" -ForegroundColor Red
        Write-Host "-> Suppression manuelle requise avant de relancer." -ForegroundColor Red
    }

    Get-PSSession | Remove-PSSession
    return
}

# --- ÉTAPE 3 BIS : Démarrage de la simulation ---
# La création seule ne lance pas le scan (cf. warning "requires simulation to be
# restarted"). Sans ce -StartSimulation, Activity Explorer resterait vide.
Write-Host "3 bis. Démarrage de la simulation..." -ForegroundColor Cyan

try {
    Set-AutoSensitivityLabelPolicy -Identity $PolicyName -StartSimulation $true -ErrorAction Stop
    Write-Host "-> Simulation démarrée.`n" -ForegroundColor Green
}
catch {
    Write-Host "-> Échec démarrage simulation : $_" -ForegroundColor Red
    Write-Host "-> Policy/règle existent malgré tout — démarrage manuel possible depuis le portail.`n" -ForegroundColor Yellow
}

# --- ÉTAPE 4 : Vérification ---
Write-Host "4. Vérification (propagation 30s)..." -ForegroundColor Cyan
Start-Sleep -Seconds 30

$CheckPolicy = Get-AutoSensitivityLabelPolicy -Identity $PolicyName -ErrorAction SilentlyContinue
$CheckRule   = Get-AutoSensitivityLabelRule -Identity $RuleName -ErrorAction SilentlyContinue

if (-not $CheckPolicy -or -not $CheckRule) {
    Write-Host "-> ATTENTION : policy ou règle introuvable après vérification." -ForegroundColor Yellow
}
else {
    Write-Host "-> Policy et règle confirmées :" -ForegroundColor Green
    [PSCustomObject]@{
        Policy            = $CheckPolicy.Name
        Mode              = $CheckPolicy.Mode
        LabelApplique     = $CheckPolicy.ApplySensitivityLabel
        EmplacementCible  = ($CheckPolicy.ExchangeLocation -join ", ")
        Regle             = $CheckRule.Name
        SeuilOccurrences  = 2
    } | Format-List
}

Write-Host "Rappel : audit silencieux, rien n'est appliqué. Voir Activity Explorer (portail Purview) pour observer les détections." -ForegroundColor Magenta

# Pour passer en application réelle une fois validé sans faux positif :
#   Set-AutoSensitivityLabelPolicy -Identity $PolicyName -Mode Enable

# Pour étendre à SharePoint/OneDrive (même policy, pas besoin de recréer la règle) :
#   Set-AutoSensitivityLabelPolicy -Identity $PolicyName -AddSharePointLocation "All"
#   Set-AutoSensitivityLabelPolicy -Identity $PolicyName -AddOneDriveLocation "All"
#   (puis relancer -StartSimulation $true — Teams non couvert directement, hérite
#   du backend SharePoint pour les fichiers, hors scope pour le chat)

# Piège testé en vrai : Remove-AutoSensitivityLabel* ne supprime pas l'objet tout de
# suite, il le passe en "PendingDeletion" — ça peut durer des heures. Tant que c'est
# pending, le nom reste considéré comme pris, donc relancer une création avec le
# même nom échoue alors que l'objet semble pourtant avoir disparu du portail. Le
# plus rapide sur un tenant de dev est de changer de nom plutôt que d'attendre.

# --- NETTOYAGE MÉMOIRE ---
Remove-Variable TargetLabel, LabelCheck, TargetSIT, SITCheck, BasePolicyName, PolicyName, `
                Counter, NewPolicy, RuleName, NewRule, CheckPolicy, CheckRule -ErrorAction SilentlyContinue

# --- FERMETURE ---
Get-PSSession | Remove-PSSession
Write-Host "`nSession fermée." -ForegroundColor Magenta
