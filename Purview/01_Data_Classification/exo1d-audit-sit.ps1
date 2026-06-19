# ========================================================================================
# Exercice 1d : Data Classification — Audit des SIT du tenant
# ========================================================================================
# Concept : Après avoir créé des SIT custom (1b regex, 1c fingerprint), on audite
# l'état complet de la classification du tenant — built-in vs custom, types, présence
# des SIT créés dans les exercices précédents.
#
# Cas d'usage réel :
#   - Première semaine de mission : cartographier ce qui existe avant toute modification
#   - Vérifier qu'un SIT custom déployé est bien visible et actif
#   - Produire un état des lieux pour un rapport de gouvernance
#   - Identifier des SIT obsolètes ou en doublon avant nettoyage
#
# Module requis : ExchangeOnlineManagement
# Connexion : Connect-IPPSSession
# ========================================================================================

# --- OUVERTURE ---
Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
Connect-IPPSSession -UserPrincipalName GeptorAdmin@0n4mg.onmicrosoft.com -ShowBanner:$false

# --- ÉTAPE 1 : Vue d'ensemble du tenant ---
Write-Host "1. Vue d'ensemble des SIT du tenant..." -ForegroundColor Cyan

$AllSIT  = Get-DlpSensitiveInformationType
$BuiltIn = $AllSIT | Where-Object { $_.Publisher -eq "Microsoft Corporation" }
$Custom  = $AllSIT | Where-Object { $_.Publisher -ne "Microsoft Corporation" }

Write-Host "-> Total SIT disponibles : $($AllSIT.Count)" -ForegroundColor Green
Write-Host "-> Built-in Microsoft    : $($BuiltIn.Count)" -ForegroundColor Green
Write-Host "-> Custom (tenant)       : $($Custom.Count)`n" -ForegroundColor Yellow

# --- ÉTAPE 2 : Détail des SIT custom ---
# Les SIT custom sont ceux qui nous appartiennent — c'est ce qu'on audite en priorité.
# On distingue les deux types créés dans ce chapitre :
#   - Type "Fingerprint" : créés via New-DlpSensitiveInformationType + New-DlpFingerprint
#   - Type "Custom"      : créés via Rule Package XML (regex, keywords)
Write-Host "2. Détail des SIT custom du tenant..." -ForegroundColor Cyan

if ($Custom.Count -eq 0) {
    Write-Host "-> Aucun SIT custom trouvé." -ForegroundColor Yellow
} else {
    $Custom | ForEach-Object {
        [PSCustomObject]@{
            Nom                   = $_.Name
            Editeur               = $_.Publisher
            # Type permet de distinguer Fingerprint vs Custom regex
            Type                  = $_.Type
            ConfidenceRecommandee = $_.RecommendedConfidence
            OccurrencesMin        = $_.MinCount
            OccurrencesMax        = $_.MaxCount
        }
    } | Format-Table -AutoSize
}

# --- ÉTAPE 3 : Vérification des SIT créés dans les exercices précédents ---
# On vérifie explicitement la présence de nos deux SIT — bonne pratique
# en mission pour confirmer qu'un déploiement s'est bien propagé.
Write-Host "3. Vérification des SIT créés dans ce chapitre..." -ForegroundColor Cyan

$SITsAttendus = @(
    "Cerberus Corp - Numéro de Badge Interne",
    "Cerberus Corp - Formulaire Accès Privilégié"
)

foreach ($Nom in $SITsAttendus) {
    $SIT = $AllSIT | Where-Object { $_.Name -eq $Nom }
    if ($SIT) {
        Write-Host "-> [OK] '$Nom' — Type : $($SIT.Type)" -ForegroundColor Green
    } else {
        Write-Host "-> [MANQUANT] '$Nom' — SIT introuvable ou réplication en cours." -ForegroundColor Red
    }
}

# --- ÉTAPE 4 : Audit des Rule Packages custom ---
# Un Rule Package est le conteneur XML qui héberge un ou plusieurs SIT regex custom.
# Les SIT fingerprint n'ont pas de Rule Package séparé — ils sont gérés directement.
# En audit, lister les Rule Packages permet de voir ce qui a été déployé manuellement.
Write-Host "`n4. Audit des Rule Packages custom..." -ForegroundColor Cyan

$AllPackages    = Get-DlpSensitiveInformationTypeRulePackage
$CustomPackages = $AllPackages | Where-Object {
    $_.Name -notmatch "Microsoft" -and $_.Name -notmatch "Document Fingerprint"
}

Write-Host "-> Total Rule Packages : $($AllPackages.Count)" -ForegroundColor Green
Write-Host "-> Custom              : $($CustomPackages.Count)`n" -ForegroundColor Yellow

if ($CustomPackages.Count -gt 0) {
    $CustomPackages | Select-Object Name, RuleCollectionName | Format-Table -AutoSize
}

# --- ÉTAPE 5 : Export CSV ---
Write-Host "5. Export CSV..." -ForegroundColor Cyan

$ExportPath = [Environment]::GetFolderPath("Desktop") + "\Purview-SIT-Audit-$(Get-Date -Format 'yyyyMMdd').csv"

$AllSIT | Select-Object Name, Publisher, Type, RecommendedConfidence, MinCount, MaxCount |
    Export-Csv -Path $ExportPath -NoTypeInformation -Encoding UTF8

Write-Host "-> Export disponible : $ExportPath" -ForegroundColor Green

# --- NETTOYAGE MÉMOIRE ---
Remove-Variable AllSIT, BuiltIn, Custom, SITsAttendus, SIT, Nom, `
                AllPackages, CustomPackages, ExportPath -ErrorAction SilentlyContinue

# --- FERMETURE ---
Disconnect-ExchangeOnline
