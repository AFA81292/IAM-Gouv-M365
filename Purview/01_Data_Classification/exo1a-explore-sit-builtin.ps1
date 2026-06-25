# ========================================================================================
# Exercice 1a : Purview — Data Classification — Exploration des SIT built-in
# ========================================================================================
# Concept : Les Sensitive Information Types (SIT) sont les briques de base de la
# classification dans Purview. Avant de créer ses propres SIT ou ses politiques DLP,
# il faut savoir lire ce que Microsoft fournit nativement — et comprendre la structure
# d'un SIT (pattern, niveau de confiance, éléments corroborants).
#
# Cas d'usage réel :
#   - Première semaine de mission : auditer ce qui existe avant de créer quoi que ce soit
#   - Identifier si un SIT built-in couvre déjà le besoin métier (souvent le cas pour
#     les données financières FR, NIR, IBAN, CB) avant de partir sur du custom
#   - Répondre à la question "est-ce que Purview détecte déjà les numéros de sécu ?"
#
# Ce que fait ce script :
#   1. Reset total de session
#   2. Vue d'ensemble : total SIT, répartition built-in vs custom
#   3. Filtrage par domaines métier (financier, identité FR, santé)
#   4. Zoom sur un SIT spécifique (structure interne, niveau de confiance)
#   5. Exporte l'inventaire complet et les filtres métier en CSV horodatés
#   6. Ferme proprement toutes les sessions
#
# Note : ce script est en lecture seule — aucune modification du tenant.
#
# Fichiers CSV générés :
#   SIT_InventaireComplet_YYYYMMDD_HHmmss.csv
#   SIT_Financiers_YYYYMMDD_HHmmss.csv
#   SIT_IdentiteFR_YYYYMMDD_HHmmss.csv
#   SIT_Sante_YYYYMMDD_HHmmss.csv
#   SIT_Custom_YYYYMMDD_HHmmss.csv
#
# Module requis : ExchangeOnlineManagement
# Connexion     : Connect-IPPSSession (Security & Compliance PowerShell)
# ========================================================================================

# --- OUVERTURE — RESET DE SESSION TOTAL ---
# REX : des sessions fantômes restées ouvertes depuis un script précédent peuvent
# provoquer des erreurs silencieuses ou des authentifications croisées.
# On purge TOUT avant de commencer, sans exception.
#
# Pourquoi Get-PSSession | Remove-PSSession plutôt que Disconnect-ExchangeOnline ?
# Les versions récentes du module ExchangeOnlineManagement ignorent -Confirm:$false
# et affichent une confirmation interactive qui bloque le script.
# Get-PSSession récupère toutes les sessions PS actives (IPPS, ExchangeOnline, autres)
# et Remove-PSSession les ferme toutes proprement sans prompt.
#
# Note : Connect-IPPSSession ne supporte pas -ShowBanner:$false — bandeau normal.
Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
Get-PSSession | Remove-PSSession
$env:MSAL_ENABLE_WAM = "0"
Connect-IPPSSession -UserPrincipalName GeptorAdmin@0n4mg.onmicrosoft.com

# ========================================================================================
# ÉTAPE 1 : Vue d'ensemble — tous les SIT disponibles
# ========================================================================================
Write-Host "1. Vue d'ensemble des SIT du tenant..." -ForegroundColor Cyan

# Get-DlpSensitiveInformationType retourne l'ensemble des SIT disponibles sur le tenant :
# built-in Microsoft + custom créés par les admins.
# Sur un tenant E5, Microsoft expose plusieurs centaines de SIT built-in couvrant
# les données financières, d'identité, de santé, pour de nombreux pays.
$AllSIT = Get-DlpSensitiveInformationType

Write-Host "-> Total SIT disponibles : $($AllSIT.Count)" -ForegroundColor Green

# Répartition built-in vs custom :
#   Publisher "Microsoft Corporation" → SIT natif, maintenu par Microsoft
#   Publisher différent               → SIT custom créé par un admin du tenant
# Sur un tenant de dev sans custom, $Custom.Count devrait être 0.
$BuiltIn = $AllSIT | Where-Object { $_.Publisher -eq "Microsoft Corporation" }
$Custom  = $AllSIT | Where-Object { $_.Publisher -ne "Microsoft Corporation" }

Write-Host "-> Built-in Microsoft : $($BuiltIn.Count)" -ForegroundColor Green
Write-Host "-> Custom (admin)     : $($Custom.Count)`n" -ForegroundColor Yellow

# ========================================================================================
# ÉTAPE 2 : Filtrage par domaines métier
# ========================================================================================
Write-Host "2. Filtrage par domaine métier..." -ForegroundColor Cyan

# En mission, on cherche rarement "tous les SIT" — on cherche ce qui couvre
# un périmètre donné. Le filtre -match accepte les regex : "|" = OU logique.

# Données financières — CB, IBAN, SWIFT, comptes bancaires
$Financial = $AllSIT | Where-Object { $_.Name -match "Credit|Bank|IBAN|SWIFT|Financial" }
Write-Host "-> SIT financiers : $($Financial.Count)" -ForegroundColor Green
$Financial | Select-Object Name | Format-Table -AutoSize

# Identité / données personnelles France — CNI, passeport, NIR (numéro de sécu)
$Identity = $AllSIT | Where-Object { $_.Name -match "France|French|Passport|National|Social" }
Write-Host "-> SIT identité/FR : $($Identity.Count)" -ForegroundColor Green
$Identity | Select-Object Name | Format-Table -AutoSize

# Données médicales / santé — utiles pour les missions dans le secteur santé ou assurance
$Health = $AllSIT | Where-Object { $_.Name -match "Health|Medical|Drug|ICD" }
Write-Host "-> SIT santé : $($Health.Count)`n" -ForegroundColor Green
$Health | Select-Object Name | Format-Table -AutoSize

# ========================================================================================
# ÉTAPE 3 : Zoom sur un SIT spécifique
# ========================================================================================
Write-Host "3. Détail d'un SIT cible : 'France National ID Card (CNI)'..." -ForegroundColor Cyan

# Comprendre la structure interne d'un SIT est essentiel pour la SC-401 et pour
# savoir ce que Purview détecte réellement — et avec quel niveau de confiance.
#
# Champs clés à connaître :
#   RecommendedConfidence → seuil recommandé par Microsoft pour déclencher une règle DLP.
#                           En dessous : risque de faux positifs élevé.
#   MinCount / MaxCount   → fourchette d'occurrences pour le déclenchement.
#   SupportedLanguages    → locales couvertes par les patterns regex du SIT.
$TargetSIT = Get-DlpSensitiveInformationType -Identity "France National ID Card (CNI)" `
    -ErrorAction SilentlyContinue

if ($TargetSIT) {
    [PSCustomObject]@{
        Nom                   = $TargetSIT.Name
        Editeur               = $TargetSIT.Publisher
        ConfidenceRecommandee = $TargetSIT.RecommendedConfidence
        OccurrencesMin        = $TargetSIT.MinCount
        OccurrencesMax        = $TargetSIT.MaxCount
        Description           = $TargetSIT.Description
    } | Format-List

    Write-Host "-> Langues supportées : $($TargetSIT.SupportedLanguages -join ', ')" -ForegroundColor Green
} else {
    Write-Host "-> SIT introuvable — vérifier le nom exact via :" -ForegroundColor Red
    Write-Host "   Get-DlpSensitiveInformationType | Where-Object { `$_.Name -match 'France' }" -ForegroundColor Yellow
}

# ========================================================================================
# RÉSUMÉ
# ========================================================================================
Write-Host "`n=== RÉSUMÉ ===" -ForegroundColor Magenta
[PSCustomObject]@{
    TotalSIT         = $AllSIT.Count
    BuiltInMicrosoft = $BuiltIn.Count
    CustomAdmin      = $Custom.Count
    SITFinanciers    = $Financial.Count
    SITIdentitéFR    = $Identity.Count
    SITSanté         = $Health.Count
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
# Colonnes exportées : Name, Publisher, RecommendedConfidence, MinCount, MaxCount
# Colonnes disponibles non exportées :
#   Description          : description textuelle du SIT (souvent longue — peut alourdir le CSV)
#   SupportedLanguages   : locales couvertes — appeler via $_.SupportedLanguages -join "|"
#   RulePackage          : nom du package XML contenant le SIT (utile pour les custom)
#   Guid                 : identifiant unique stable du SIT — à utiliser dans les DLP Rules
$InventaireExport = $AllSIT |
    Select-Object Name, Publisher, RecommendedConfidence, MinCount, MaxCount,
        @{N="Guid"; E={ $_.Guid }},
        @{N="SupportedLanguages"; E={ $_.SupportedLanguages -join "|" }}

$InventaireExport | Export-Csv `
    -Path "$ExportPath\SIT_InventaireComplet_$Timestamp.csv" `
    -Encoding UTF8 -NoTypeInformation
Write-Host "-> Inventaire complet : $($InventaireExport.Count) ligne(s) — SIT_InventaireComplet_$Timestamp.csv" -ForegroundColor Green

# --- CSV 2 : SIT financiers ---
# Colonnes exportées : Name, Publisher, RecommendedConfidence, MinCount, MaxCount
# Filtre regex : Credit|Bank|IBAN|SWIFT|Financial
# Cas d'usage : cadrage DLP pour une mission banque/finance — identifier la couverture
# native avant de créer des SIT custom pour les numéros de compte internes.
$Financial | Select-Object Name, Publisher, RecommendedConfidence, MinCount, MaxCount |
    Export-Csv `
        -Path "$ExportPath\SIT_Financiers_$Timestamp.csv" `
        -Encoding UTF8 -NoTypeInformation
Write-Host "-> Financiers : $($Financial.Count) ligne(s) — SIT_Financiers_$Timestamp.csv" -ForegroundColor Green

# --- CSV 3 : SIT identité / données personnelles France ---
# Colonnes exportées : Name, Publisher, RecommendedConfidence, MinCount, MaxCount
# Filtre regex : France|French|Passport|National|Social
# Cas d'usage : RGPD / conformité CNIL — vérifier si Purview couvre CNI, NIR, passeport FR.
$Identity | Select-Object Name, Publisher, RecommendedConfidence, MinCount, MaxCount |
    Export-Csv `
        -Path "$ExportPath\SIT_IdentiteFR_$Timestamp.csv" `
        -Encoding UTF8 -NoTypeInformation
Write-Host "-> Identité FR : $($Identity.Count) ligne(s) — SIT_IdentiteFR_$Timestamp.csv" -ForegroundColor Green

# --- CSV 4 : SIT santé ---
# Colonnes exportées : Name, Publisher, RecommendedConfidence, MinCount, MaxCount
# Filtre regex : Health|Medical|Drug|ICD
# Cas d'usage : mission secteur santé ou assurance — vérifier la couverture HDS avant
# de créer des SIT custom pour les numéros de dossier patient ou codes ICD.
$Health | Select-Object Name, Publisher, RecommendedConfidence, MinCount, MaxCount |
    Export-Csv `
        -Path "$ExportPath\SIT_Sante_$Timestamp.csv" `
        -Encoding UTF8 -NoTypeInformation
Write-Host "-> Santé : $($Health.Count) ligne(s) — SIT_Sante_$Timestamp.csv" -ForegroundColor Green

# --- CSV 5 : SIT custom uniquement ---
# Colonnes exportées : Name, Publisher, RecommendedConfidence, MinCount, MaxCount, Guid
# Ce CSV est le plus utile en début de mission : il révèle ce que les équipes précédentes
# ont déjà configuré en custom — évite de recréer des SIT qui existent déjà.
# Sur un tenant de dev vierge, ce fichier sera vide (Custom.Count = 0).
if ($Custom.Count -gt 0) {
    $Custom |
        Select-Object Name, Publisher, RecommendedConfidence, MinCount, MaxCount,
            @{N="Guid"; E={ $_.Guid }} |
        Export-Csv `
            -Path "$ExportPath\SIT_Custom_$Timestamp.csv" `
            -Encoding UTF8 -NoTypeInformation
    Write-Host "-> Custom : $($Custom.Count) ligne(s) — SIT_Custom_$Timestamp.csv" -ForegroundColor Green
} else {
    Write-Host "-> Custom : aucun SIT custom trouvé — pas d'export." -ForegroundColor Yellow
}

Write-Host "-> Export terminé dans : $ExportPath`n" -ForegroundColor Green

# ========================================================================================
# NETTOYAGE MÉMOIRE
# ========================================================================================
Remove-Variable AllSIT, BuiltIn, Custom, Financial, Identity, Health,
                TargetSIT, InventaireExport,
                ExportPath, Timestamp `
                -ErrorAction SilentlyContinue

# ========================================================================================
# FERMETURE — RESET DE SESSION TOTAL
# ========================================================================================
Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
Get-PSSession | Remove-PSSession
Write-Host "Sessions fermées proprement." -ForegroundColor Magenta
