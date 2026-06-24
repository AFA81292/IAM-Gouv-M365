# ========================================================================================
# Exercice 1d : Data Classification — Audit des SIT du tenant
# ========================================================================================
# Concept : Après avoir créé des SIT custom (1b regex, 1c fingerprint), on audite
# l'état complet de la classification du tenant — built-in vs custom, types, présence
# des SIT créés dans les exercices précédents.
#
# Ce que fait ce script :
#   1. Reset total de session
#   2. Vue d'ensemble : comptage total / built-in / custom
#   3. Détail des SIT custom du tenant (type, confiance, occurrences)
#   4. Vérification ciblée des SIT créés dans les exercices 1b et 1c
#   5. Audit des Rule Packages custom (conteneurs XML des SIT regex)
#   6. Export CSV de l'inventaire complet sur le Bureau
#   7. Ferme proprement toutes les sessions
#
# Cas d'usage réel :
#   - Première semaine de mission : cartographier ce qui existe avant toute modification
#   - Vérifier qu'un SIT custom déployé est bien visible et actif
#   - Produire un état des lieux pour un rapport de gouvernance
#   - Identifier des SIT obsolètes ou en doublon avant nettoyage
#
# Module requis : ExchangeOnlineManagement
# Connexion     : Connect-IPPSSession
# ========================================================================================

# --- OUVERTURE — RESET DE SESSION TOTAL ---
# REX : Get-PSSession | Remove-PSSession est préféré à Disconnect-ExchangeOnline -Confirm:$false
# car les versions récentes du module ExchangeOnlineManagement ignorent -Confirm:$false
# et affichent une confirmation interactive qui bloque le script.
# Get-PSSession récupère toutes les sessions PS actives (IPPS, ExchangeOnline, autres)
# et Remove-PSSession les ferme toutes proprement sans prompt.
Get-PSSession | Remove-PSSession
Connect-IPPSSession -UserPrincipalName GeptorAdmin@0n4mg.onmicrosoft.com -ShowBanner:$false

# ========================================================================================
# ÉTAPE 1 : Vue d'ensemble des SIT du tenant
# ========================================================================================
Write-Host "1. Vue d'ensemble des SIT du tenant..." -ForegroundColor Cyan

# Get-DlpSensitiveInformationType retourne TOUS les SIT disponibles sur le tenant :
# les built-in Microsoft (>300 par défaut) et les custom créés manuellement.
# On sépare les deux catégories sur le critère Publisher.
$AllSIT  = Get-DlpSensitiveInformationType
$BuiltIn = $AllSIT | Where-Object { $_.Publisher -eq "Microsoft Corporation" }
$Custom  = $AllSIT | Where-Object { $_.Publisher -ne "Microsoft Corporation" }

Write-Host "-> Total SIT disponibles : $($AllSIT.Count)"  -ForegroundColor Green
Write-Host "-> Built-in Microsoft    : $($BuiltIn.Count)" -ForegroundColor Green
Write-Host "-> Custom (tenant)       : $($Custom.Count)`n" -ForegroundColor Yellow

# ========================================================================================
# ÉTAPE 2 : Détail des SIT custom du tenant
# ========================================================================================
Write-Host "2. Détail des SIT custom du tenant..." -ForegroundColor Cyan

# Les SIT custom sont ceux qui nous appartiennent — c'est ce qu'on audite en priorité.
# On distingue les deux types créés dans ce chapitre :
#   - Type "Fingerprint" : créés via New-DlpSensitiveInformationType + New-DlpFingerprint (exo 1c)
#   - Type "Custom"      : créés via Rule Package XML avec regex et keywords (exo 1b)
if ($Custom.Count -eq 0) {
    Write-Host "-> Aucun SIT custom trouvé sur ce tenant." -ForegroundColor Yellow
} else {
    $Custom | ForEach-Object {
        [PSCustomObject]@{
            Nom                   = $_.Name
            Editeur               = $_.Publisher
            Type                  = $_.Type
            ConfidenceRecommandée = $_.RecommendedConfidence
            OccurrencesMin        = $_.MinCount
            OccurrencesMax        = $_.MaxCount
        }
    } | Format-Table -AutoSize
}

# ========================================================================================
# ÉTAPE 3 : Vérification ciblée des SIT créés dans ce chapitre
# ========================================================================================
Write-Host "3. Vérification des SIT créés dans ce chapitre (1b et 1c)..." -ForegroundColor Cyan

# Bonne pratique de mission : après un déploiement, on confirme explicitement
# que chaque SIT attendu est bien visible et propagé — pas de présupposition.
# Si un SIT est MANQUANT ici, soit la réplication n'est pas terminée (attendre),
# soit la création a échoué silencieusement (relancer l'exo correspondant).
$SITsAttendus = @(
    "Cerberus Corp - Numéro de Badge Interne",      # Créé en 1b (regex)
    "Cerberus Corp - Formulaire Accès Privilégié"   # Créé en 1c (fingerprint)
)

foreach ($Nom in $SITsAttendus) {
    $SIT = $AllSIT | Where-Object { $_.Name -eq $Nom }
    if ($SIT) {
        Write-Host "-> [OK]      '$Nom' — Type : $($SIT.Type)" -ForegroundColor Green
    } else {
        Write-Host "-> [MANQUANT] '$Nom' — SIT introuvable ou réplication en cours." -ForegroundColor Red
    }
}
Write-Host ""

# ========================================================================================
# ÉTAPE 4 : Audit des Rule Packages custom
# ========================================================================================
Write-Host "4. Audit des Rule Packages custom..." -ForegroundColor Cyan

# Un Rule Package est le conteneur XML qui héberge un ou plusieurs SIT regex custom.
# Les SIT fingerprint (exo 1c) n'ont pas de Rule Package séparé — ils sont gérés directement
# via New-DlpSensitiveInformationType et n'apparaissent pas ici.
# En audit, lister les Rule Packages permet de voir ce qui a été déployé manuellement
# et d'identifier des packages orphelins ou en doublon.
#
# Filtre : on exclut les packages Microsoft natifs et les packages "Document Fingerprint"
# (générés automatiquement par Purview pour les SIT fingerprint).
$AllPackages    = Get-DlpSensitiveInformationTypeRulePackage
$CustomPackages = $AllPackages | Where-Object {
    $_.Name -notmatch "Microsoft" -and $_.Name -notmatch "Document Fingerprint"
}

Write-Host "-> Total Rule Packages : $($AllPackages.Count)"    -ForegroundColor Green
Write-Host "-> Custom              : $($CustomPackages.Count)`n" -ForegroundColor Yellow

if ($CustomPackages.Count -gt 0) {
    $CustomPackages | Select-Object Name, RuleCollectionName | Format-Table -AutoSize
}

# ========================================================================================
# ÉTAPE 5 : Export CSV
# ========================================================================================
Write-Host "5. Export CSV de l'inventaire complet..." -ForegroundColor Cyan

# Export horodaté sur le Bureau — format yyyyMMdd pour tri chronologique naturel.
# -NoTypeInformation : supprime la ligne de type PS en tête de fichier (#TYPE ...).
# -Encoding UTF8 : nécessaire pour les caractères accentués dans les noms de SIT.
$ExportPath = [Environment]::GetFolderPath("Desktop") + "\Purview-SIT-Audit-$(Get-Date -Format 'yyyyMMdd').csv"

$AllSIT | Select-Object Name, Publisher, Type, RecommendedConfidence, MinCount, MaxCount |
    Export-Csv -Path $ExportPath -NoTypeInformation -Encoding UTF8

Write-Host "-> Export disponible : $ExportPath`n" -ForegroundColor Green

# ========================================================================================
# RÉSUMÉ
# ========================================================================================
Write-Host "=== RÉSUMÉ ===" -ForegroundColor Magenta
[PSCustomObject]@{
    TotalSIT         = $AllSIT.Count
    BuiltInMicrosoft = $BuiltIn.Count
    CustomTenant     = $Custom.Count
    RulePackagesCustom = $CustomPackages.Count
    SIT1b            = if ($AllSIT | Where-Object { $_.Name -eq "Cerberus Corp - Numéro de Badge Interne" })    { "OK" } else { "MANQUANT" }
    SIT1c            = if ($AllSIT | Where-Object { $_.Name -eq "Cerberus Corp - Formulaire Accès Privilégié" }) { "OK" } else { "MANQUANT" }
    ExportCSV        = $ExportPath
} | Format-List

# ========================================================================================
# NETTOYAGE MÉMOIRE
# ========================================================================================
Remove-Variable AllSIT, BuiltIn, Custom, SITsAttendus, SIT, Nom, `
                AllPackages, CustomPackages, ExportPath `
                -ErrorAction SilentlyContinue

# ========================================================================================
# FERMETURE — RESET DE SESSION TOTAL
# ========================================================================================
Get-PSSession | Remove-PSSession
Write-Host "Sessions fermées proprement." -ForegroundColor Magenta
