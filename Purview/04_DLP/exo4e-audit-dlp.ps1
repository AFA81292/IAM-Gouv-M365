# ========================================================================================
# Exercice 4e : Audit des DLP policies — vue d'ensemble du tenant
# ========================================================================================
# Concept : exo de lecture pure, miroir de 1d/2f/3e. On liste toutes les DLP policies du
# tenant (toutes créées en 4a-4d), leur mode (Test/Enable), leurs workloads, et les règles
# associées à chacune — vue d'ensemble nécessaire avant tout audit de conformité ou
# nettoyage de tenant dev.
#
# Module requis : ExchangeOnlineManagement
# Connexion : Connect-IPPSSession
# ========================================================================================

# --- OUVERTURE ---
Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
Get-PSSession | Remove-PSSession
$env:MSAL_ENABLE_WAM = "0"
Connect-IPPSSession -UserPrincipalName GeptorAdmin@0n4mg.onmicrosoft.com

# --- ÉTAPE 1 : Liste de toutes les DLP policies ---
Write-Host "1. DLP policies du tenant..." -ForegroundColor Cyan

$AllPolicies = Get-DlpCompliancePolicy

if (-not $AllPolicies) {
    Write-Host "-> Aucune DLP policy trouvée sur le tenant." -ForegroundColor Yellow
    Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
    Get-PSSession | Remove-PSSession
    return
}

$AllPolicies |
    Select-Object Name, Mode, Enabled,
        @{N = "SharePoint"; E = { if ($_.SharePointLocation) { "Oui" } else { "-" } }},
        @{N = "OneDrive";   E = { if ($_.OneDriveLocation)   { "Oui" } else { "-" } }},
        @{N = "Exchange";   E = { if ($_.ExchangeLocation)   { "Oui" } else { "-" } }} |
    Format-Table -AutoSize

Write-Host "-> $($AllPolicies.Count) policy(ies) trouvée(s).`n" -ForegroundColor Green

# --- ÉTAPE 2 : Répartition par mode ---
# Vue rapide : combien sont en Test (donc sans blocage réel) vs Enable (actives).
# Sur un tenant dev, une majorité en Test est normale — c'est l'objet même des exos.
Write-Host "2. Répartition par mode..." -ForegroundColor Cyan

$AllPolicies | Group-Object Mode | Select-Object Name, Count | Format-Table -AutoSize

# --- ÉTAPE 3 : Règles associées à chaque policy ---
# Une policy sans règle est un objet "mort" — créé mais inopérant (cf. le piège
# rencontré en 4c où une règle a échoué et la policy est restée orpheline).
Write-Host "3. Règles par policy..." -ForegroundColor Cyan

foreach ($Policy in $AllPolicies) {
    $Rules = Get-DlpComplianceRule -Policy $Policy.Name -ErrorAction SilentlyContinue

    Write-Host "`n[$($Policy.Name)] — Mode : $($Policy.Mode)" -ForegroundColor White

    if (-not $Rules) {
        Write-Host "   ATTENTION : aucune règle associée — policy orpheline." -ForegroundColor Red
        continue
    }

    $Rules | Select-Object Name, Disabled, BlockAccess, BlockAccessScope |
        Format-Table -AutoSize
}

# --- RÉSUMÉ ---
Write-Host "=== RÉSUMÉ ===" -ForegroundColor Magenta

$OrphanCount = ($AllPolicies | Where-Object {
    -not (Get-DlpComplianceRule -Policy $_.Name -ErrorAction SilentlyContinue)
}).Count

[PSCustomObject]@{
    TotalPolicies     = $AllPolicies.Count
    EnModeTest        = ($AllPolicies | Where-Object { $_.Mode -eq "TestWithNotifications" }).Count
    EnModeEnable      = ($AllPolicies | Where-Object { $_.Mode -eq "Enable" }).Count
    PoliciesOrphelines = $OrphanCount
} | Format-List

# --- NETTOYAGE MÉMOIRE ---
Remove-Variable AllPolicies, Policy, Rules, OrphanCount -ErrorAction SilentlyContinue

# --- FERMETURE ---
Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
Get-PSSession | Remove-PSSession
Write-Host "Sessions fermées proprement." -ForegroundColor Magenta
