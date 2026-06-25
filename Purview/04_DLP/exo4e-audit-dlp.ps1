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
#   6. Exporte trois CSV horodatés (policies, règles, orphelines)
#   7. Ferme proprement toutes les sessions
#
# Note : ce script est en lecture seule — aucune modification du tenant.
#
# Fichiers CSV générés :
#   DLP_Policies_YYYYMMDD_HHmmss.csv        — inventaire des policies (mode, workloads)
#   DLP_Regles_YYYYMMDD_HHmmss.csv          — règles par policy (statut, blocage, scope)
#   DLP_PoliciesOrphelines_YYYYMMDD_HHmmss.csv — policies sans aucune règle associée
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
#
# Les collections $RegleRows et $OrphelineRows sont alimentées dans cette boucle unique —
# pas de second appel API pour le comptage des orphelines dans le résumé.
$RegleRows     = @()
$OrphelineRows = @()

foreach ($Policy in $AllPolicies) {
    $Rules = Get-DlpComplianceRule -Policy $Policy.Name -ErrorAction SilentlyContinue

    Write-Host "`n[$($Policy.Name)] — Mode : $($Policy.Mode)" -ForegroundColor White

    if (-not $Rules) {
        Write-Host "   ATTENTION : aucune règle associée — policy orpheline." -ForegroundColor Red
        Write-Host "   Nettoyage : Remove-DlpCompliancePolicy -Identity '$($Policy.Name)' -Confirm:`$false" -ForegroundColor Yellow

        $OrphelineRows += [PSCustomObject]@{
            PolicyNom  = $Policy.Name
            PolicyMode = $Policy.Mode
            Enabled    = $Policy.Enabled
            SharePoint = if ($Policy.SharePointLocation) { "Oui" } else { "-" }
            OneDrive   = if ($Policy.OneDriveLocation)   { "Oui" } else { "-" }
            Exchange   = if ($Policy.ExchangeLocation)   { "Oui" } else { "-" }
        }
        continue
    }

    # Colonnes affichées pour chaque règle :
    #   Disabled        → $true = règle désactivée manuellement (policy active mais règle muette)
    #   BlockAccess     → $true = blocage configuré (effectif uniquement si policy en mode Enable)
    #   BlockAccessScope → "PerUser" (seul le contrevenant) ou "All" (tout le monde bloqué)
    $Rules | Select-Object Name, Disabled, BlockAccess, BlockAccessScope |
        Format-Table -AutoSize

    foreach ($Rule in $Rules) {
        $RegleRows += [PSCustomObject]@{
            PolicyNom        = $Policy.Name
            PolicyMode       = $Policy.Mode
            RegleNom         = $Rule.Name
            # Disabled : $true = règle muette même si la policy est active.
            # Une policy Enable avec toutes ses règles Disabled = policy inopérante en pratique.
            Disabled         = $Rule.Disabled
            # BlockAccess : $true = une action de blocage est configurée sur la règle.
            # N'est effectif que si la policy est en mode Enable — ignoré en mode Test.
            BlockAccess      = $Rule.BlockAccess
            # BlockAccessScope : portée du blocage.
            #   "PerUser" = seul l'auteur de la violation est bloqué (défaut).
            #   "All"     = tout accès au document est bloqué pour tous les utilisateurs.
            BlockAccessScope = $Rule.BlockAccessScope
            # Colonnes disponibles non exportées :
            #   ContentContainsSensitiveInformation : SITs déclencheurs de la règle
            #     → ($Rule.ContentContainsSensitiveInformation | ConvertTo-Json -Compress -Depth 3)
            #   NotifyUser : destinataires des notifications DLP
            #     → $Rule.NotifyUser -join "|"
            #   EncryptRMSTemplate : template de chiffrement OME si action combinée
            #     → $Rule.EncryptRMSTemplate
        }
    }
}

# ========================================================================================
# RÉSUMÉ
# ========================================================================================
Write-Host "`n=== RÉSUMÉ ===" -ForegroundColor Magenta

[PSCustomObject]@{
    TotalPolicies      = $AllPolicies.Count
    EnModeTest         = ($AllPolicies | Where-Object { $_.Mode -eq "TestWithNotifications"    }).Count
    EnModeEnable       = ($AllPolicies | Where-Object { $_.Mode -eq "Enable"                   }).Count
    EnModeSilencieux   = ($AllPolicies | Where-Object { $_.Mode -eq "TestWithoutNotifications" }).Count
    PoliciesOrphelines = $OrphelineRows.Count
    TotalRegles        = $RegleRows.Count
    Scope              = "Lecture seule — aucune modification du tenant"
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

# --- CSV 1 : Inventaire des policies ---
# Colonnes exportées : Name, Mode, Enabled, SharePoint, OneDrive, Exchange
# Mode    : "TestWithNotifications" / "Enable" / "TestWithoutNotifications"
#           — colonne de triage principale en audit : toute policy Enable mérite vérification.
# Enabled : $true/$false — une policy Enabled:$false est désactivée indépendamment du Mode.
# Colonnes disponibles non exportées :
#   TeamsLocation      : couverture Teams — appeler via $_.TeamsLocation
#   EndpointDlpEnabled : DLP endpoint activé (Defender for Endpoint requis)
#                        appeler via $_.EndpointDlpEnabled
#   WhenCreated / WhenChanged : traçabilité — appeler via $_.WhenCreated, $_.WhenChanged
$AllPolicies | Select-Object Name, Mode, Enabled,
    @{ N = "SharePoint"; E = { if ($_.SharePointLocation) { "Oui" } else { "-" } } },
    @{ N = "OneDrive";   E = { if ($_.OneDriveLocation)   { "Oui" } else { "-" } } },
    @{ N = "Exchange";   E = { if ($_.ExchangeLocation)   { "Oui" } else { "-" } } } |
    Export-Csv `
        -Path "$ExportPath\DLP_Policies_$Timestamp.csv" `
        -Encoding UTF8 -NoTypeInformation
Write-Host "-> Policies : $($AllPolicies.Count) ligne(s) — DLP_Policies_$Timestamp.csv" -ForegroundColor Green

# --- CSV 2 : Règles par policy ---
# Colonnes exportées : PolicyNom, PolicyMode, RegleNom, Disabled, BlockAccess, BlockAccessScope
# Cas d'usage principal : identifier les règles Disabled:$true sur une policy Enable
# (policy active en apparence, règle muette en pratique — piège classique en audit).
# Colonnes disponibles non exportées (commentées inline dans la boucle étape 3) :
#   ContentContainsSensitiveInformation (JSON), NotifyUser, EncryptRMSTemplate
if ($RegleRows.Count -gt 0) {
    $RegleRows | Export-Csv `
        -Path "$ExportPath\DLP_Regles_$Timestamp.csv" `
        -Encoding UTF8 -NoTypeInformation
    Write-Host "-> Règles    : $($RegleRows.Count) ligne(s) — DLP_Regles_$Timestamp.csv" -ForegroundColor Green
} else {
    Write-Host "-> Règles    : aucune règle trouvée — pas d'export." -ForegroundColor Yellow
}

# --- CSV 3 : Policies orphelines ---
# Colonnes exportées : PolicyNom, PolicyMode, Enabled, SharePoint, OneDrive, Exchange
# Ce CSV est le livrable opérationnel de nettoyage : chaque ligne = une policy à supprimer
# ou à compléter d'une règle. Sur un tenant dev propre après les exos 4a-4d,
# ce fichier devrait être vide. S'il ne l'est pas → une création de règle a échoué.
if ($OrphelineRows.Count -gt 0) {
    $OrphelineRows | Export-Csv `
        -Path "$ExportPath\DLP_PoliciesOrphelines_$Timestamp.csv" `
        -Encoding UTF8 -NoTypeInformation
    Write-Host "-> Orphelines : $($OrphelineRows.Count) ligne(s) — DLP_PoliciesOrphelines_$Timestamp.csv" -ForegroundColor Green
} else {
    Write-Host "-> Orphelines : aucune policy orpheline — pas d'export." -ForegroundColor Yellow
}

Write-Host "-> Export terminé dans : $ExportPath`n" -ForegroundColor Green

# ========================================================================================
# NETTOYAGE MÉMOIRE
# ========================================================================================
Remove-Variable AllPolicies, Policy, Rules, Rule,
                RegleRows, OrphelineRows,
                ExportPath, Timestamp `
                -ErrorAction SilentlyContinue

# ========================================================================================
# FERMETURE — RESET DE SESSION TOTAL
# ========================================================================================
Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
Get-PSSession | Remove-PSSession
Write-Host "Sessions fermées proprement." -ForegroundColor Magenta
