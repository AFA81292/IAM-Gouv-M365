# ========================================================================================
# Exercice 5a : Conditional Access — Audit des politiques du tenant
# ========================================================================================
# Objectif : Lister l'état complet des politiques Conditional Access —
# nom, état, conditions, grant controls.
#
# Cas d'usage réel : un consultant IAM arrive en mission et veut un état des lieux
# complet des politiques CA en place — actives, en Report-Only, désactivées.
#
# Ce script se limite à la lecture — use case audit/reporting. 
# ========================================================================================

# --- ÉTAPE 1 : Connexion à Microsoft Graph ---
# Policy.Read.All suffit — on ne fait que lire
# Fonctionne avec le ClientId par défaut — pas besoin du SP-IAM-Lab
$Scopes = @(
    "Policy.Read.All"
)
Connect-MgGraph -Scopes $Scopes

# --- ÉTAPE 2 : Récupération de toutes les politiques CA ---
Write-Host "`n=== POLITIQUES CONDITIONAL ACCESS ===" -ForegroundColor Cyan

$Policies = Get-MgIdentityConditionalAccessPolicy -All

if (-not $Policies) {
    Write-Host "-> Aucune politique CA trouvée." -ForegroundColor Yellow
    return
}

# Affichage synthétique — Id, Nom, État
# State : "enabled" = active / "disabled" = désactivée
# "enabledForReportingButNotEnforced" = Report-Only (évaluée mais pas appliquée)
$Policies | Select-Object Id, DisplayName, State | Format-Table -AutoSize

# --- ÉTAPE 3 : Détail par état ---
# Politiques actives — appliquées en prod
$Enabled = $Policies | Where-Object {$_.State -eq "enabled"}
Write-Host "`n--- Politiques ACTIVES ($($Enabled.Count)) ---" -ForegroundColor Green
if ($Enabled) {
    $Enabled | Select-Object DisplayName, State | Format-Table -AutoSize
} else {
    Write-Host "-> Aucune politique active." -ForegroundColor Yellow
}

# Politiques en Report-Only — évaluées mais pas appliquées
# Bonne pratique avant activation en prod — permet d'observer l'impact sans bloquer
$ReportOnly = $Policies | Where-Object {$_.State -eq "enabledForReportingButNotEnforced"}
Write-Host "`n--- Politiques REPORT-ONLY ($($ReportOnly.Count)) ---" -ForegroundColor Yellow
if ($ReportOnly) {
    $ReportOnly | Select-Object DisplayName, State | Format-Table -AutoSize
} else {
    Write-Host "-> Aucune politique en Report-Only." -ForegroundColor Yellow
}

# Politiques désactivées — existent mais n'évaluent rien
$Disabled = $Policies | Where-Object {$_.State -eq "disabled"}
Write-Host "`n--- Politiques DÉSACTIVÉES ($($Disabled.Count)) ---" -ForegroundColor Red
if ($Disabled) {
    $Disabled | Select-Object DisplayName, State | Format-Table -AutoSize
} else {
    Write-Host "-> Aucune politique désactivée." -ForegroundColor Yellow
}

Write-Host "`n=== FIN DE L'AUDIT ===" -ForegroundColor Green

# --- ÉTAPE 4 : Nettoyage ---
Remove-Variable Scopes, Policies, Enabled, ReportOnly, Disabled -ErrorAction SilentlyContinue

Write-Host "`nMémoire locale nettoyée. Session Microsoft Graph toujours active." -ForegroundColor Magenta
