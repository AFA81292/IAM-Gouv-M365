# ========================================================================================
# Exercice 4e : Audit des DLP policies — vue d'ensemble du tenant
# ========================================================================================
# Concept : exo de lecture pure, miroir de 1d/2f/3e côté Purview.
# On liste toutes les DLP policies du tenant (toutes créées en 4a-4d), leur mode
# (Test/Enable), leurs workloads, et les règles associées à chacune.
#
# Vue d'ensemble nécessaire avant tout audit de conformité ou nettoyage de tenant dev.
#
# Delta pédagogique vs 4a-4d :
#   4a-4d → création et manipulation de policies individuelles
#   4e    → lecture transversale : on prend de la hauteur sur l'ensemble du tenant
#            Cas d'usage réel : arriver en mission et cartographier l'existant DLP
#            avant de toucher quoi que ce soit
#
# Ce que fait ce script :
#   1. Reset total de session
#   2. Liste toutes les DLP policies avec leur mode et leurs workloads
#   3. Affiche la répartition par mode (Test vs Enable)
#   4. Liste les règles associées à chaque policy — détecte les policies orphelines
#   5. Affiche un résumé chiffré
#   6. Ferme proprement toutes les sessions
#
# Note : ce script est en lecture seule — aucune modification du tenant.
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
# ÉTAPE 1 : Liste de toutes les DLP policies
# ========================================================================================
Write-Host "1. DLP policies du tenant..." -ForegroundColor Cyan
Start-Sleep -Seconds 30

# Get-DlpCompliancePolicy sans filtre retourne toutes les policies du tenant —
# built-in Microsoft (ex. policies de base créées par défaut sur E5) + custom (nos exos).
# Sur un tenant de dev propre, seules les policies créées en 4a-4d devraient apparaître.
$AllPolicies = Get-DlpCompliancePolicy

if (-not $AllPolicies) {
    Write-Host "-> Aucune DLP policy trouvée sur le tenant." -ForegroundColor Yellow
    Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
    Get-PSSession | Remove-PSSession
    return
}

# Colonnes calculées pour les workloads :
#   SharePointLocation / OneDriveLocation / ExchangeLocation sont des collections.
#   Si la collection est non nulle → workload configuré ("Oui"), sinon ("-").
#   "All" dans la collection = toutes les instances du workload sont couvertes.
$AllPolicies |
    Select-Object Name, Mode, Enabled,
        @{ N = "SharePoint"; E = { if ($_.SharePointLocation) { "Oui" } else { "-" } } },
        @{ N = "OneDrive";   E = { if ($_.OneDriveLocation)   { "Oui" } else { "-" } } },
        @{ N = "Exchange";   E = { if ($_.ExchangeLocation)   { "Oui" } else { "-" } } } |
    Format-Table -AutoSize

Write-Host "-> $($AllPolicies.Count) policy(ies) trouvée(s).`n" -ForegroundColor Green

# ========================================================================================
# ÉTAPE 2 : Répartition par mode
# ========================================================================================
Write-Host "2. Répartition par mode..." -ForegroundColor Cyan

# Vue rapide : combien de policies sont en Test (sans blocage réel) vs Enable (actives).
# Sur un tenant dev, une majorité en TestWithNotifications est normale —
# c'est l'objet même des exos 4a-4d.
# En production, toute policy en Enable devrait être documentée et justifiée.
#
# Group-Object Mode regroupe les policies par valeur de Mode et compte les occurrences.
# Valeurs possibles :
#   "TestWithNotifications"    → détecte, notifie, ne bloque pas
#   "Enable"                   → blocage actif
#   "TestWithoutNotifications" → détecte silencieusement, sans notifier
$AllPolicies | Group-Object Mode | Select-Object Name, Count | Format-Table -AutoSize

# ========================================================================================
# ÉTAPE 3 : Règles associées à chaque policy
# ========================================================================================
Write-Host "3. Règles par policy..." -ForegroundColor Cyan

# Une policy sans règle est un objet "mort" — créé mais inopérant.
# Cas concret rencontré en 4c : la création de la règle a échoué après celle de la policy,
# laissant une policy orpheline qui consomme une entrée dans le tenant sans rien faire.
# Ce scan permet de les identifier et de les nettoyer.
foreach ($Policy in $AllPolicies) {
    $Rules = Get-DlpComplianceRule -Policy $Policy.Name -ErrorAction SilentlyContinue

    Write-Host "`n[$($Policy.Name)] — Mode : $($Policy.Mode)" -ForegroundColor White

    if (-not $Rules) {
        Write-Host "   ATTENTION : aucune règle associée — policy orpheline." -ForegroundColor Red
        Write-Host "   Nettoyage : Remove-DlpCompliancePolicy -Identity '$($Policy.Name)' -Confirm:`$false" -ForegroundColor Yellow
        continue
    }

    # Colonnes affichées pour chaque règle :
    #   Disabled        → $true = règle désactivée manuellement (policy active mais règle muette)
    #   BlockAccess     → $true = blocage configuré (effectif uniquement si policy en mode Enable)
    #   BlockAccessScope → "PerUser" (seul le contrevenant) ou "All" (tout le monde bloqué)
    $Rules | Select-Object Name, Disabled, BlockAccess, BlockAccessScope |
        Format-Table -AutoSize
}

# ========================================================================================
# RÉSUMÉ
# ========================================================================================
Write-Host "`n=== RÉSUMÉ ===" -ForegroundColor Magenta

# Deuxième passage sur Get-DlpComplianceRule pour compter les orphelines dans le résumé.
# Inévitable : on ne peut pas stocker les résultats du foreach précédent proprement
# sans complexifier le script — acceptable sur un tenant dev avec peu de policies.
$OrphanCount = ($AllPolicies | Where-Object {
    -not (Get-DlpComplianceRule -Policy $_.Name -ErrorAction SilentlyContinue)
}).Count

[PSCustomObject]@{
    TotalPolicies      = $AllPolicies.Count
    EnModeTest         = ($AllPolicies | Where-Object { $_.Mode -eq "TestWithNotifications" }).Count
    EnModeEnable       = ($AllPolicies | Where-Object { $_.Mode -eq "Enable" }).Count
    EnModeSilencieux   = ($AllPolicies | Where-Object { $_.Mode -eq "TestWithoutNotifications" }).Count
    PoliciesOrphelines = $OrphanCount
    Scope              = "Lecture seule — aucune modification du tenant"
} | Format-List

# ========================================================================================
# NETTOYAGE MÉMOIRE
# ========================================================================================
Remove-Variable AllPolicies, Policy, Rules, OrphanCount -ErrorAction SilentlyContinue

# ========================================================================================
# FERMETURE — RESET DE SESSION TOTAL
# ========================================================================================
Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
Get-PSSession | Remove-PSSession
Write-Host "Sessions fermées proprement." -ForegroundColor Magenta
