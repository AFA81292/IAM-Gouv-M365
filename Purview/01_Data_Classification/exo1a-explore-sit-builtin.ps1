# ========================================================================================
# Exercice 1a : Data Classification — Exploration des SIT built-in
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
# Module requis : ExchangeOnlineManagement
# Connexion : Connect-IPPSSession (Security & Compliance PowerShell)
# ========================================================================================

# --- OUVERTURE : Fermeture d'une session fantôme éventuelle ---
# Fermeture de toutes les sessions PowerShell actives
# Get-PSSession | Remove-PSSession est préféré à Disconnect-ExchangeOnline -Confirm:$false
# car les versions récentes du module ExchangeOnlineManagement ignorent -Confirm:$false
# et affichent une confirmation interactive qui bloque le script.
# Get-PSSession récupère toutes les sessions PS actives (IPPS, ExchangeOnline, autres)
# et Remove-PSSession les ferme toutes proprement sans prompt.
Get-PSSession | Remove-PSSession

# --- ÉTAPE 1 : Connexion ---
Connect-IPPSSession -UserPrincipalName GeptorAdmin@0n4mg.onmicrosoft.com -ShowBanner:$false

# --- ÉTAPE 2 : Vue d'ensemble — tous les SIT disponibles ---
# Le tenant E5 expose plusieurs centaines de SIT built-in Microsoft.
# Type "Microsoft" = built-in. Type différent = custom (on n'en a pas encore ici).
Write-Host "1. Vue d'ensemble des SIT du tenant..." -ForegroundColor Cyan

$AllSIT = Get-DlpSensitiveInformationType
Write-Host "-> Total SIT disponibles : $($AllSIT.Count)" -ForegroundColor Green

# Répartition built-in vs custom
$BuiltIn = $AllSIT | Where-Object { $_.Publisher -eq "Microsoft Corporation" }
$Custom  = $AllSIT | Where-Object { $_.Publisher -ne "Microsoft Corporation" }

Write-Host "-> Built-in Microsoft : $($BuiltIn.Count)" -ForegroundColor Green
Write-Host "-> Custom (admin)     : $($Custom.Count)`n" -ForegroundColor Yellow

# --- ÉTAPE 3 : Filtrage par mots-clés métier ---
# En mission, on cherche rarement "tous les SIT" — on cherche ce qui couvre
# un périmètre donné. Exemples de filtres utiles :
Write-Host "2. Filtrage par domaine métier..." -ForegroundColor Cyan

# Données financières
$Financial = $AllSIT | Where-Object { $_.Name -match "Credit|Bank|IBAN|SWIFT|Financial" }
Write-Host "-> SIT financiers : $($Financial.Count)"
$Financial | Select-Object Name | Format-Table -AutoSize

# Identité / données personnelles FR
$Identity = $AllSIT | Where-Object { $_.Name -match "France|French|Passport|National|Social" }
Write-Host "-> SIT identité/FR : $($Identity.Count)"
$Identity | Select-Object Name | Format-Table -AutoSize

# Données médicales / santé
$Health = $AllSIT | Where-Object { $_.Name -match "Health|Medical|Drug|ICD" }
Write-Host "-> SIT santé : $($Health.Count)`n"
$Health | Select-Object Name | Format-Table -AutoSize

# --- ÉTAPE 4 : Zoom sur un SIT spécifique ---
# Comprendre la structure interne d'un SIT est essentiel pour la SC-401 et pour
# savoir ce que Purview détecte réellement — et avec quel niveau de confiance.
Write-Host "3. Détail d'un SIT cible : 'France National ID Card (CNI)'..." -ForegroundColor Cyan

$TargetSIT = Get-DlpSensitiveInformationType -Identity "France National ID Card (CNI)"

if ($TargetSIT) {
    [PSCustomObject]@{
        Nom                   = $TargetSIT.Name
        Editeur               = $TargetSIT.Publisher
        # Recommended = seuil de confiance recommandé par Microsoft pour déclencher une règle
        ConfidenceRecommandee = $TargetSIT.RecommendedConfidence
        # MinCount = nombre minimum d'occurrences pour déclencher
        OccurrencesMin        = $TargetSIT.MinCount
        OccurrencesMax        = $TargetSIT.MaxCount
        Description           = $TargetSIT.Description
    } | Format-List

    # Les SupportedLanguages indiquent les locales couvertes par les patterns
    Write-Host "-> Langues supportées : $($TargetSIT.SupportedLanguages -join ', ')" -ForegroundColor Green
} else {
    Write-Host "-> SIT introuvable — vérifie le nom exact via Get-DlpSensitiveInformationType" -ForegroundColor Red
}

# --- ÉTAPE 5 : Export optionnel ---
# Utile pour avoir une référence locale de tous les SIT disponibles
Write-Host "`n4. Export CSV optionnel..." -ForegroundColor Cyan

# Mon bureau est dans D:\ on modifie donc le Path pour le rendre universel
$ExportPath = [Environment]::GetFolderPath("Desktop") + "\SIT-Audit-$(Get-Date -Format 'yyyyMMdd').csv"
$AllSIT | Select-Object Name, Publisher, RecommendedConfidence, MinCount, MaxCount |
    Export-Csv -Path $ExportPath -NoTypeInformation -Encoding UTF8

Write-Host "-> Export disponible : $ExportPath" -ForegroundColor Green

# --- NETTOYAGE MÉMOIRE ---
Remove-Variable AllSIT, BuiltIn, Custom, Financial, Identity, Health, TargetSIT, ExportPath `
    -ErrorAction SilentlyContinue

# --- FERMETURE : Fermer la porte derrière soi ---
Get-PSSession | Remove-PSSession

Write-Host "`nSession fermée. Mémoire locale nettoyée." -ForegroundColor Magenta
