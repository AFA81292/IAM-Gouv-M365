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
#   6. Résumé chiffré
#   7. Export CSV horodatés (inventaire complet + custom + Rule Packages)
#   8. Ferme proprement toutes les sessions
#
# Cas d'usage réel :
#   - Première semaine de mission : cartographier ce qui existe avant toute modification
#   - Vérifier qu'un SIT custom déployé est bien visible et actif
#   - Produire un état des lieux pour un rapport de gouvernance
#   - Identifier des SIT obsolètes ou en doublon avant nettoyage
#
# Note : ce script est en lecture seule — aucune modification du tenant.
#
# Fichiers CSV générés :
#   SIT_InventaireComplet_YYYYMMDD_HHmmss.csv
#   SIT_Custom_YYYYMMDD_HHmmss.csv
#   SIT_RulePackagesCustom_YYYYMMDD_HHmmss.csv
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
$CustomRows = @()

if ($Custom.Count -eq 0) {
    Write-Host "-> Aucun SIT custom trouvé sur ce tenant." -ForegroundColor Yellow
} else {
    $CustomRows = $Custom | ForEach-Object {
        [PSCustomObject]@{
            Nom                   = $_.Name
            Editeur               = $_.Publisher
            Type                  = $_.Type
            ConfidenceRecommandée = $_.RecommendedConfidence
            OccurrencesMin        = $_.MinCount
            OccurrencesMax        = $_.MaxCount
            Guid                  = $_.Guid
        }
    }
    $CustomRows | Select-Object Nom, Editeur, Type, ConfidenceRecommandée, OccurrencesMin, OccurrencesMax |
        Format-Table -AutoSize
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
        Write-Host "-> [OK]       '$Nom' — Type : $($SIT.Type)" -ForegroundColor Green
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

Write-Host "-> Total Rule Packages : $($AllPackages.Count)"     -ForegroundColor Green
Write-Host "-> Custom              : $($CustomPackages.Count)`n" -ForegroundColor Yellow

$PackageRows = @()

if ($CustomPackages.Count -gt 0) {
    $PackageRows = $CustomPackages | ForEach-Object {
        [PSCustomObject]@{
            Nom                 = $_.Name
            RuleCollectionName  = $_.RuleCollectionName
            # Version : utile pour tracer les mises à jour d'un package entre deux audits.
            # Appeler via $_.Version
            # Publisher : éditeur déclaré dans le XML du package.
            # Appeler via $_.Publisher
            # Description : description du package (souvent vide pour les custom ad hoc).
            # Appeler via $_.Description
        }
    }
    $PackageRows | Select-Object Nom, RuleCollectionName | Format-Table -AutoSize
}

# ========================================================================================
# RÉSUMÉ
# ========================================================================================
Write-Host "=== RÉSUMÉ ===" -ForegroundColor Magenta
[PSCustomObject]@{
    TotalSIT           = $AllSIT.Count
    BuiltInMicrosoft   = $BuiltIn.Count
    CustomTenant       = $Custom.Count
    RulePackagesCustom = $CustomPackages.Count
    SIT1b              = if ($AllSIT | Where-Object { $_.Name -eq "Cerberus Corp - Numéro de Badge Interne" })    { "OK" } else { "MANQUANT" }
    SIT1c              = if ($AllSIT | Where-Object { $_.Name -eq "Cerberus Corp - Formulaire Accès Privilégié" }) { "OK" } else { "MANQUANT" }
} | Format-List

# ========================================================================================
# EXPORT CSV
# ========================================================================================
Write-Host "Export CSV en cours..." -ForegroundColor Cyan

# EN LABO / Local :
$ExportPath = "D:\Documents\ScriptsPowerShell\Exports\"
# EN PRODUCTION :
# $ExportPath = "$PSScriptRoot\Exports\"

New-Item -ItemType Directory -Force -Path $ExportPath | Out-Null
$Timestamp = Get-Date -Format "yyyyMMdd_HHmmss"

# --- CSV 1 : Inventaire complet ---
# Colonnes exportées : Name, Publisher, Type, RecommendedConfidence, MinCount, MaxCount, Guid
# Colonnes disponibles non exportées :
#   Description        : texte descriptif du SIT — souvent long, peut alourdir le CSV
#                        Appeler via $_.Description
#   SupportedLanguages : locales couvertes par les patterns regex
#                        Appeler via @{N="SupportedLanguages"; E={ $_.SupportedLanguages -join "|" }}
#   RulePackage        : nom du package XML contenant le SIT (pertinent surtout pour les custom)
#                        Appeler via $_.RulePackage
$InventaireExport = $AllSIT | Select-Object `
    Name, Publisher, Type, RecommendedConfidence, MinCount, MaxCount,
    @{N="Guid"; E={ $_.Guid }}

$InventaireExport | Export-Csv `
    -Path "$ExportPath\SIT_InventaireComplet_$Timestamp.csv" `
    -Encoding UTF8 -NoTypeInformation
Write-Host "-> Inventaire complet : $($InventaireExport.Count) ligne(s) — SIT_InventaireComplet_$Timestamp.csv" -ForegroundColor Green

# --- CSV 2 : SIT custom uniquement ---
# Colonnes exportées : Nom, Editeur, Type, ConfidenceRecommandée, OccurrencesMin, OccurrencesMax, Guid
# C'est le CSV le plus utile en début de mission : révèle ce que les équipes précédentes
# ont configuré — évite de recréer des SIT qui existent déjà.
# Sur un tenant de dev vierge, ce fichier sera vide.
# Colonnes disponibles non exportées :
#   SupportedLanguages : locales couvertes — appeler via $_.SupportedLanguages -join "|"
#   Description        : description textuelle du SIT custom
if ($CustomRows.Count -gt 0) {
    $CustomRows | Export-Csv `
        -Path "$ExportPath\SIT_Custom_$Timestamp.csv" `
        -Encoding UTF8 -NoTypeInformation
    Write-Host "-> SIT custom : $($CustomRows.Count) ligne(s) — SIT_Custom_$Timestamp.csv" -ForegroundColor Green
} else {
    Write-Host "-> SIT custom : aucun SIT custom trouvé — pas d'export." -ForegroundColor Yellow
}

# --- CSV 3 : Rule Packages custom ---
# Colonnes exportées : Nom, RuleCollectionName
# Ce CSV est utile pour identifier les packages orphelins ou en doublon
# (package présent sans SIT associé visible, ou plusieurs packages pour le même périmètre).
# Colonnes disponibles non exportées :
#   Version   : version du package XML — appeler via $_.Version
#   Publisher : éditeur déclaré dans le XML — appeler via $_.Publisher
#   Description : description du package — appeler via $_.Description
if ($PackageRows.Count -gt 0) {
    $PackageRows | Export-Csv `
        -Path "$ExportPath\SIT_RulePackagesCustom_$Timestamp.csv" `
        -Encoding UTF8 -NoTypeInformation
    Write-Host "-> Rule Packages custom : $($PackageRows.Count) ligne(s) — SIT_RulePackagesCustom_$Timestamp.csv" -ForegroundColor Green
} else {
    Write-Host "-> Rule Packages custom : aucun package custom trouvé — pas d'export." -ForegroundColor Yellow
}

Write-Host "-> Export terminé dans : $ExportPath`n" -ForegroundColor Green

# ========================================================================================
# NETTOYAGE MÉMOIRE
# ========================================================================================
Remove-Variable AllSIT, BuiltIn, Custom, CustomRows, `
                SITsAttendus, SIT, Nom, `
                AllPackages, CustomPackages, PackageRows, `
                InventaireExport, ExportPath, Timestamp `
                -ErrorAction SilentlyContinue

# ========================================================================================
# FERMETURE — RESET DE SESSION TOTAL
# ========================================================================================
Get-PSSession | Remove-PSSession
Write-Host "Sessions fermées proprement." -ForegroundColor Magenta
