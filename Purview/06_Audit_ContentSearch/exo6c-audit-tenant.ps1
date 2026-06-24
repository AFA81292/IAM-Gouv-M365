# ========================================================================================
# Exercice 6c : Audit du tenant — Audit Retention Policies et Content Searches
# ========================================================================================
# Concept : Script de lecture pure — aucune création, aucune modification.
# Objectif : vue d'ensemble de la posture d'audit et de recherche du tenant.
#
# Deux familles d'objets interrogées :
#
#   1. Audit Retention Policies (*-UnifiedAuditLogRetentionPolicy)
#      → Créées en exercice 6a
#      → Contrôlent la durée de conservation des logs d'audit Purview
#
#   2. Content Searches (*-ComplianceSearch)
#      → Créées en exercice 6b
#      → Recherches de contenu sur Exchange / SharePoint / OneDrive / Teams
#
# PIÈGE : Get-UnifiedAuditLogRetentionPolicy ne supporte pas -Identity.
#   Tout filtre par nom passe obligatoirement par Where-Object.
#   Tenter -Identity provoque une erreur de paramètre invalide.
#
# Ce que fait ce script :
#   1. Reset total de session
#   2. Audite les Audit Retention Policies (vue globale, répartition, détail, filtre repo)
#   3. Audite les Content Searches (vue globale, statuts, alertes, détail, filtre repo)
#   4. Affiche un résumé consolidé
#   5. Ferme proprement toutes les sessions
#
# Connexion requise : Connect-IPPSSession uniquement
# Licence           : Microsoft Purview Audit Premium (inclus E5)
# ========================================================================================

# --- OUVERTURE — RESET DE SESSION TOTAL ---
# REX : des sessions fantômes restées ouvertes depuis un script précédent peuvent
# provoquer des erreurs silencieuses ou des authentifications croisées.
# On purge TOUT avant de commencer, sans exception.
#
# $env:MSAL_ENABLE_WAM = "0" : désactive le Windows Authentication Manager.
# Sans ce workaround, WAM peut réutiliser un token de session précédente avec
# des scopes insuffisants — cause fréquente d'erreurs silencieuses sur Connect-IPPSSession.
# Note : Connect-IPPSSession ne supporte pas -ShowBanner:$false — bandeau normal.
Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
Get-PSSession | Remove-PSSession
$env:MSAL_ENABLE_WAM = "0"
Connect-IPPSSession -UserPrincipalName GeptorAdmin@0n4mg.onmicrosoft.com

# ========================================================================================
# SECTION 1 : Audit Retention Policies
# ========================================================================================
Write-Host "`n========================================" -ForegroundColor Magenta
Write-Host "  SECTION 1 : AUDIT RETENTION POLICIES"   -ForegroundColor Magenta
Write-Host "========================================`n" -ForegroundColor Magenta

# Get-UnifiedAuditLogRetentionPolicy retourne toutes les ARPs du tenant.
# Rappel : pas de -Identity disponible — tout filtre passe par Where-Object.
$AllARPs = Get-UnifiedAuditLogRetentionPolicy -ErrorAction SilentlyContinue

if (-not $AllARPs) {
    Write-Host "Aucune Audit Retention Policy trouvée sur le tenant." -ForegroundColor Yellow
} else {

    # --- 1a : Vue globale par priorité ---
    # Priority : plus le chiffre est bas, plus la règle est évaluée en premier.
    # En cas de conflit (un log matchant plusieurs ARPs), c'est la plus haute priorité qui gagne.
    Write-Host "1a. Toutes les ARPs par priorité :" -ForegroundColor Cyan
    $AllARPs | Sort-Object Priority |
        Select-Object Name, RecordTypes, RetentionDuration, Priority |
        Format-Table -AutoSize

    # --- 1b : Répartition par durée de rétention ---
    # Permet d'identifier rapidement si le tenant a une politique homogène
    # ou des durées mixtes (ex : 90j pour les logs courants, 1 an pour les logs sensibles).
    Write-Host "1b. Répartition par durée de rétention :" -ForegroundColor Cyan
    $AllARPs | Group-Object RetentionDuration |
        Select-Object @{N="Durée"; E={$_.Name}}, @{N="Nombre"; E={$_.Count}} |
        Sort-Object Durée |
        Format-Table -AutoSize

    # --- 1c : Détail complet de chaque ARP ---
    # Utile pour inspecter les RecordTypes multiples, les UserIds ciblés,
    # et les Operations filtrées — colonnes trop larges pour un Format-Table.
    Write-Host "1c. Détail complet par ARP :" -ForegroundColor Cyan
    foreach ($ARP in ($AllARPs | Sort-Object Priority)) {
        Write-Host "   --- $($ARP.Name) (Priorité $($ARP.Priority)) ---" -ForegroundColor Gray
        [PSCustomObject]@{
            Nom            = $ARP.Name
            RecordTypes    = ($ARP.RecordTypes -join ", ")
            DuréeRétention = $ARP.RetentionDuration
            Priorité       = $ARP.Priority
            # UserIds null = ARP s'applique à tous les utilisateurs du tenant
            UserIds        = if ($ARP.UserIds)    { ($ARP.UserIds    -join ", ") } else { "Tous les utilisateurs" }
            # Operations null = ARP couvre toutes les opérations du RecordType
            Operations     = if ($ARP.Operations) { ($ARP.Operations -join ", ") } else { "Toutes les opérations" }
            Description    = $ARP.Description
        } | Format-List
    }

    # --- 1d : ARPs créées par ce repo (filtre sur convention de nommage) ---
    # Convention : toutes les ARPs créées dans ces exercices ont le préfixe "ARP-".
    # Ce filtre permet de distinguer les objets du lab des ARPs système éventuelles.
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
Write-Host "  SECTION 2 : CONTENT SEARCHES"       -ForegroundColor Magenta
Write-Host "====================================`n" -ForegroundColor Magenta

$AllSearches = Get-ComplianceSearch -ErrorAction SilentlyContinue

if (-not $AllSearches) {
    Write-Host "Aucune Content Search trouvée sur le tenant." -ForegroundColor Yellow
} else {

    # --- 2a : Vue globale avec statut et résultats ---
    # Items et Taille ne sont disponibles que si la search a le statut "Completed".
    # Pour les searches NotStarted / InProgress, ces colonnes affichent "—".
    Write-Host "2a. Toutes les Content Searches :" -ForegroundColor Cyan
    $AllSearches | Sort-Object Name |
        Select-Object Name, Status,
            @{N="Items"; E={ if ($_.Items) { $_.Items } else { "—" } }},
            @{N="Taille"; E={
                if ($_.Size -ge 1MB)     { "$([math]::Round($_.Size / 1MB, 2)) Mo"  }
                elseif ($_.Size -ge 1KB) { "$([math]::Round($_.Size / 1KB, 2)) Ko"  }
                elseif ($_.Size -gt 0)   { "$($_.Size) octets" }
                else                     { "—" }
            }} |
        Format-Table -AutoSize

    # --- 2b : Répartition par statut ---
    # Statuts possibles :
    #   NotStarted  : créée mais jamais lancée (Start-ComplianceSearch non appelé)
    #   Starting    : démarrage en cours côté backend
    #   InProgress  : exécution en cours — stats pas encore disponibles
    #   Completed   : terminée, Items et Size disponibles
    #   Failed      : erreur backend — relancer via Start-ComplianceSearch
    #   Stopping    : arrêt en cours (Stop-ComplianceSearch appelé)
    Write-Host "2b. Répartition par statut :" -ForegroundColor Cyan
    $AllSearches | Group-Object Status |
        Select-Object @{N="Statut"; E={$_.Name}}, @{N="Nombre"; E={$_.Count}} |
        Format-Table -AutoSize

    # --- 2c : Searches nécessitant attention (Failed / NotStarted) ---
    # Failed    = la search a planté côté backend — à relancer.
    # NotStarted = créée mais jamais exécutée — orpheline ou oubliée.
    # Dans les deux cas, les stats sont inexploitables.
    $ProblemSearches = $AllSearches | Where-Object { $_.Status -in @("Failed", "NotStarted") }
    if ($ProblemSearches) {
        Write-Host "2c. Searches nécessitant attention (Failed / NotStarted) :" -ForegroundColor Yellow
        $ProblemSearches | Select-Object Name, Status, ContentMatchQuery | Format-Table -AutoSize
        Write-Host "   Relancer via : Start-ComplianceSearch -Identity 'Nom-de-la-search'" -ForegroundColor Yellow
    } else {
        Write-Host "2c. Aucune search en échec ou non démarrée." -ForegroundColor Green
    }

    # --- 2d : Détail complet de chaque search ---
    # ExchangeLocation : mailbox(es) ciblée(s) — peut être une liste si multi-mailbox.
    # ContentMatchQuery : la query KQL complète — utile pour vérifier les paramètres
    #   de recherche (mot-clé, plage de dates) sans repasser dans le portail.
    Write-Host "2d. Détail complet par Content Search :" -ForegroundColor Cyan
    foreach ($Search in ($AllSearches | Sort-Object Name)) {
        Write-Host "   --- $($Search.Name) ---" -ForegroundColor Gray
        [PSCustomObject]@{
            Nom          = $Search.Name
            Status       = $Search.Status
            Query        = $Search.ContentMatchQuery
            Emplacements = if ($Search.ExchangeLocation) { ($Search.ExchangeLocation -join ", ") } else { "Non défini" }
            Items        = if ($Search.Items)            { $Search.Items } else { "—" }
            Taille       = if ($Search.Size -ge 1MB)     { "$([math]::Round($Search.Size / 1MB, 2)) Mo" }
                           elseif ($Search.Size -ge 1KB) { "$([math]::Round($Search.Size / 1KB, 2)) Ko" }
                           else                          { "—" }
            Description  = $Search.Description
        } | Format-List
    }

    # --- 2e : Searches créées par ce repo (filtre sur convention de nommage) ---
    # Convention : toutes les searches créées dans ces exercices ont le préfixe "CS-".
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
    ARPs_Total         = if ($AllARPs)     { ($AllARPs     | Measure-Object).Count } else { 0 }
    ARPs_RepoPrefix    = if ($AllARPs)     { ($AllARPs     | Where-Object { $_.Name -like "ARP-*" } | Measure-Object).Count } else { 0 }
    Searches_Total     = if ($AllSearches) { ($AllSearches | Measure-Object).Count } else { 0 }
    Searches_Completed = if ($AllSearches) { ($AllSearches | Where-Object { $_.Status -eq "Completed" } | Measure-Object).Count } else { 0 }
    Searches_Failed    = if ($AllSearches) { ($AllSearches | Where-Object { $_.Status -eq "Failed"    } | Measure-Object).Count } else { 0 }
    Searches_RepoPrefix = if ($AllSearches){ ($AllSearches | Where-Object { $_.Name  -like "CS-*"     } | Measure-Object).Count } else { 0 }
} | Format-List

# ========================================================================================
# NETTOYAGE MÉMOIRE
# ========================================================================================
Remove-Variable AllARPs, RepoARPs, ARP, AllSearches, ProblemSearches, `
                RepoSearches, Search `
                -ErrorAction SilentlyContinue

# ========================================================================================
# FERMETURE — RESET DE SESSION TOTAL
# ========================================================================================
Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
Get-PSSession | Remove-PSSession
Write-Host "Sessions fermées proprement." -ForegroundColor Magenta
