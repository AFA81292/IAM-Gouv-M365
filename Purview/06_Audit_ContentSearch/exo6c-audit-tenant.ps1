# ========================================================================================
# Exercice 6c : Audit du tenant — Audit Retention Policies et Content Searches
# ========================================================================================
# Script de lecture pure — aucune création, aucune modification.
# Objectif : vue d'ensemble de la posture d'audit et de recherche du tenant.
#
# Deux familles d'objets interrogées :
#   1. Audit Retention Policies (créées en 6a)
#      → *-UnifiedAuditLogRetentionPolicy
#      → Contrôle la durée de conservation des logs d'audit
#
#   2. Content Searches (créées en 6b)
#      → *-ComplianceSearch
#      → Recherches de contenu sur Exchange/SharePoint/OneDrive/Teams
#
# RAPPEL PIÈGE : Get-UnifiedAuditLogRetentionPolicy ne supporte pas -Identity.
#   Tout filtre par nom passe par Where-Object.
#
# Connexion requise : Connect-IPPSSession uniquement
# Licence           : Microsoft Purview Audit Premium (inclus E5)
# ========================================================================================

# --- OUVERTURE — RESET DE SESSION TOTAL ---
Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
Get-PSSession | Remove-PSSession
$env:MSAL_ENABLE_WAM = "0"
Connect-IPPSSession -UserPrincipalName GeptorAdmin@0n4mg.onmicrosoft.com

# ========================================================================================
# SECTION 1 : Audit Retention Policies
# ========================================================================================
Write-Host "`n========================================" -ForegroundColor Magenta
Write-Host "  SECTION 1 : AUDIT RETENTION POLICIES" -ForegroundColor Magenta
Write-Host "========================================`n" -ForegroundColor Magenta

$AllARPs = Get-UnifiedAuditLogRetentionPolicy -ErrorAction SilentlyContinue

if (-not $AllARPs) {
    Write-Host "Aucune Audit Retention Policy trouvée sur le tenant." -ForegroundColor Yellow
} else {
    # --- 1a : Vue globale par priorité ---
    Write-Host "1a. Toutes les ARPs par priorité :" -ForegroundColor Cyan
    $AllARPs | Sort-Object Priority |
        Select-Object Name, RecordTypes, RetentionDuration, Priority |
        Format-Table -AutoSize

    # --- 1b : Répartition par durée de rétention ---
    Write-Host "1b. Répartition par durée de rétention :" -ForegroundColor Cyan
    $AllARPs | Group-Object RetentionDuration |
        Select-Object @{N="Durée"; E={$_.Name}}, @{N="Nombre"; E={$_.Count}} |
        Sort-Object Durée |
        Format-Table -AutoSize

    # --- 1c : Détail complet de chaque ARP ---
    # Utile pour inspecter les RecordTypes multiples, les UserIds ciblés, etc.
    Write-Host "1c. Détail complet par ARP :" -ForegroundColor Cyan
    foreach ($ARP in ($AllARPs | Sort-Object Priority)) {
        Write-Host "   --- $($ARP.Name) (Priorité $($ARP.Priority)) ---" -ForegroundColor Gray
        [PSCustomObject]@{
            Nom            = $ARP.Name
            RecordTypes    = ($ARP.RecordTypes -join ", ")
            DuréeRétention = $ARP.RetentionDuration
            Priorité       = $ARP.Priority
            UserIds        = if ($ARP.UserIds) { ($ARP.UserIds -join ", ") } else { "Tous les utilisateurs" }
            Operations     = if ($ARP.Operations) { ($ARP.Operations -join ", ") } else { "Toutes les opérations" }
            Description    = $ARP.Description
        } | Format-List
    }

    # --- 1d : ARPs créées par ce repo (filtre sur convention de nommage) ---
    Write-Host "1d. ARPs créées par ce repo (préfixe 'ARP-') :" -ForegroundColor Cyan
    $RepoARPs = $AllARPs | Where-Object { $_.Name -like "ARP-*" }
    if ($RepoARPs) {
        $RepoARPs | Sort-Object Priority |
            Select-Object Name, RecordTypes, RetentionDuration, Priority |
            Format-Table -AutoSize
    } else {
        Write-Host "   Aucune ARP avec préfixe 'ARP-' trouvée." -ForegroundColor Yellow
    }
}

# ========================================================================================
# SECTION 2 : Content Searches
# ========================================================================================
Write-Host "`n====================================" -ForegroundColor Magenta
Write-Host "  SECTION 2 : CONTENT SEARCHES" -ForegroundColor Magenta
Write-Host "====================================`n" -ForegroundColor Magenta

$AllSearches = Get-ComplianceSearch -ErrorAction SilentlyContinue

if (-not $AllSearches) {
    Write-Host "Aucune Content Search trouvée sur le tenant." -ForegroundColor Yellow
} else {
    # --- 2a : Vue globale avec statut ---
    Write-Host "2a. Toutes les Content Searches :" -ForegroundColor Cyan
    $AllSearches | Sort-Object Name |
        Select-Object Name, Status,
            @{N="Items"; E={ if ($_.Items) { $_.Items } else { "—" } }},
            @{N="Taille"; E={
                if ($_.Size -ge 1MB)      { "$([math]::Round($_.Size / 1MB, 2)) Mo" }
                elseif ($_.Size -ge 1KB)  { "$([math]::Round($_.Size / 1KB, 2)) Ko" }
                elseif ($_.Size -gt 0)    { "$($_.Size) octets" }
                else                      { "—" }
            }} |
        Format-Table -AutoSize

    # --- 2b : Répartition par statut ---
    Write-Host "2b. Répartition par statut :" -ForegroundColor Cyan
    $AllSearches | Group-Object Status |
        Select-Object @{N="Statut"; E={$_.Name}}, @{N="Nombre"; E={$_.Count}} |
        Format-Table -AutoSize

    # Statuts possibles :
    #   NotStarted  : créée mais jamais lancée (Start-ComplianceSearch non appelé)
    #   Starting    : démarrage en cours
    #   InProgress  : exécution en cours côté backend
    #   Completed   : terminée, stats disponibles
    #   Failed      : erreur backend — relancer via Start-ComplianceSearch
    #   Stopping    : arrêt en cours (Stop-ComplianceSearch appelé)

    # --- 2c : Searches en échec ou non démarrées (attention requise) ---
    $ProblemSearches = $AllSearches | Where-Object { $_.Status -in @("Failed", "NotStarted") }
    if ($ProblemSearches) {
        Write-Host "2c. Searches nécessitant attention (Failed / NotStarted) :" -ForegroundColor Yellow
        $ProblemSearches | Select-Object Name, Status, ContentMatchQuery | Format-Table -AutoSize
        Write-Host "   Relancer via : Start-ComplianceSearch -Identity 'Nom-de-la-search'" -ForegroundColor Yellow
    } else {
        Write-Host "2c. Aucune search en échec ou non démarrée." -ForegroundColor Green
    }

    # --- 2d : Détail complet de chaque search ---
    Write-Host "2d. Détail complet par Content Search :" -ForegroundColor Cyan
    foreach ($Search in ($AllSearches | Sort-Object Name)) {
        Write-Host "   --- $($Search.Name) ---" -ForegroundColor Gray
        [PSCustomObject]@{
            Nom         = $Search.Name
            Status      = $Search.Status
            Query       = $Search.ContentMatchQuery
            Emplacements = if ($Search.ExchangeLocation) { ($Search.ExchangeLocation -join ", ") } else { "Non défini" }
            Items       = if ($Search.Items) { $Search.Items } else { "—" }
            Taille      = if ($Search.Size -ge 1MB) { "$([math]::Round($Search.Size / 1MB, 2)) Mo" }
                          elseif ($Search.Size -ge 1KB) { "$([math]::Round($Search.Size / 1KB, 2)) Ko" }
                          else { "—" }
            Description = $Search.Description
        } | Format-List
    }

    # --- 2e : Searches créées par ce repo (filtre sur convention de nommage) ---
    Write-Host "2e. Searches créées par ce repo (préfixe 'CS-') :" -ForegroundColor Cyan
    $RepoSearches = $AllSearches | Where-Object { $_.Name -like "CS-*" }
    if ($RepoSearches) {
        $RepoSearches | Select-Object Name, Status, Items | Format-Table -AutoSize
    } else {
        Write-Host "   Aucune search avec préfixe 'CS-' trouvée." -ForegroundColor Yellow
    }
}

# ========================================================================================
# RÉSUMÉ
# ========================================================================================
Write-Host "`n=== RÉSUMÉ ===" -ForegroundColor Magenta

[PSCustomObject]@{
    ARPs_Total       = if ($AllARPs)    { ($AllARPs | Measure-Object).Count }    else { 0 }
    ARPs_RepoPrefix  = if ($AllARPs)    { ($AllARPs | Where-Object { $_.Name -like "ARP-*" } | Measure-Object).Count } else { 0 }
    Searches_Total   = if ($AllSearches){ ($AllSearches | Measure-Object).Count } else { 0 }
    Searches_Completed = if ($AllSearches){ ($AllSearches | Where-Object { $_.Status -eq "Completed" } | Measure-Object).Count } else { 0 }
    Searches_Failed  = if ($AllSearches){ ($AllSearches | Where-Object { $_.Status -eq "Failed" } | Measure-Object).Count } else { 0 }
} | Format-List

# ========================================================================================
# NETTOYAGE MÉMOIRE
# ========================================================================================
Remove-Variable AllARPs, RepoARPs, ARP, AllSearches, ProblemSearches,
                RepoSearches, Search `
                -ErrorAction SilentlyContinue

# --- FERMETURE — RESET DE SESSION TOTAL ---
Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
Get-PSSession | Remove-PSSession
Write-Host "Sessions fermées proprement." -ForegroundColor Magenta
