# ========================================================================================
# Exercice 3d : Entra ID — Audit des groupes
# ========================================================================================
# Concept : Les groupes Entra sont le socle de la gestion des accès — licences,
# applications, politiques CA, Access Packages, SharePoint... Un tenant mal gouverné
# accumule des groupes fantômes : vides, sans owner, dupliqués, jamais utilisés.
# Auditer les groupes régulièrement est une hygiène IAM de base.
#
# Ce script inventorie les groupes du tenant selon 4 angles :
#   - Vue d'ensemble          → tous les groupes, type, membership, owner count
#   - Groupes par type        → Security statique, Security dynamique, M365, M365 dynamique
#   - Groupes vides           → aucun membre
#   - Groupes sans owner      → traités en détail dans l'exo 3e (ici : comptage + flag)
#
# Delta pédagogique vs exercice 3e (audit groupes sans owner) :
#   3d → inventaire général tous groupes confondus — vue de surface exhaustive
#   3e → drill-down gouvernance : focus groupes sans owner, plusieurs owners, sans membres
#        avec résolution complète des owners et export dédié
#
# Ce que fait ce script :
#   1. Reset total de session
#   2. Récupère tous les groupes du tenant
#   3. Pour chaque groupe : résout le nombre de membres et d'owners
#   4. Segmente par type de groupe
#   5. Identifie les groupes vides
#   6. Affiche la vue d'ensemble complète
#   7. Affiche un résumé chiffré
#   8. Exporte les résultats en CSV horodatés
#   9. Ferme proprement toutes les sessions
#
# Note : ce script est en lecture seule — aucune modification du tenant.
#
# Fichiers CSV générés :
#   Groups_Overview_YYYYMMDD_HHmmss.csv     → tous les groupes avec compteurs
#   Groups_Security_YYYYMMDD_HHmmss.csv     → Security Groups (statiques + dynamiques)
#   Groups_M365_YYYYMMDD_HHmmss.csv         → M365 Groups (Unified, statiques + dynamiques)
#   Groups_Empty_YYYYMMDD_HHmmss.csv        → groupes sans membre
#
# Note sur les performances : ce script effectue 2 appels API par groupe
# (Get-MgGroupMember + Get-MgGroupOwner). Sur un tenant de dev avec peu de groupes,
# négligeable. Sur un tenant de production avec des milliers de groupes, préférer
# un ciblage par type ou par segment.
#
# Module requis : Microsoft.Graph.Groups
# Connexion     : Connect-MgGraph
# ========================================================================================

# --- OUVERTURE — RESET DE SESSION TOTAL ---
# Group.Read.All : lire tous les groupes, leurs membres et leurs owners.
# Pas de -ContextScope Process requis ici — opération en lecture seule,
# WAM ne bloque pas les scopes de lecture.
$Scopes = @(
    "Group.Read.All"
)

Disconnect-MgGraph -ErrorAction SilentlyContinue
Connect-MgGraph -Scopes $Scopes -NoWelcome

# ========================================================================================
# ÉTAPE 1 : Récupération de tous les groupes
# ========================================================================================
Write-Host "1. Récupération de tous les groupes..." -ForegroundColor Cyan

# -Property : on demande explicitement les champs nécessaires pour la classification.
# GroupTypes est le champ clé pour distinguer les types de groupes — voir tableau ci-dessous.
#
# Rappel des types de groupes Graph — combinaison de 3 paramètres :
#
#   TYPE                      | GroupTypes                        | SecurityEnabled | MailEnabled
#   --------------------------|-----------------------------------|-----------------|------------
#   Security statique         | @()                               | $true           | $false
#   Security dynamique        | @("DynamicMembership")            | $true           | $false
#   M365 statique (Unified)   | @("Unified")                      | $false          | $true
#   M365 dynamique            | @("Unified","DynamicMembership")  | $false          | $true
#   Mail-enabled Security     | @()                               | $true           | $true
#
# Mail-enabled Security Groups : créés depuis Exchange, non gérables via Graph en écriture.
# Ils apparaissent dans l'inventaire mais sont signalés séparément.
$AllGroups = Get-MgGroup -All `
    -Property "Id, DisplayName, Description, GroupTypes, SecurityEnabled,
               MailEnabled, Mail, MailNickname, MembershipRule,
               MembershipRuleProcessingState, CreatedDateTime, Visibility" `
    -ErrorAction Stop

Write-Host "-> $($AllGroups.Count) groupe(s) trouvé(s) dans le tenant.`n" -ForegroundColor Green

if ($AllGroups.Count -eq 0) {
    Write-Host "Aucun groupe à analyser. Fin du script." -ForegroundColor Yellow
    Disconnect-MgGraph -ErrorAction SilentlyContinue
    return
}

# ========================================================================================
# ÉTAPE 2 : Construction de la vue normalisée
# ========================================================================================
Write-Host "2. Construction de la vue normalisée (appels API par groupe)..." -ForegroundColor Cyan
Write-Host "   Cela peut prendre quelques secondes selon le nombre de groupes..." -ForegroundColor Gray

$GroupRows = foreach ($Group in $AllGroups) {

    # --- Comptage des membres ---
    # On récupère uniquement les IDs pour limiter le payload — on n'a besoin que du count.
    # -ConsistencyLevel eventual + -CountVariable : requis pour les requêtes avec $count
    # sur certaines versions du module Graph. Ici on utilise .Count sur la collection
    # retournée — plus simple, suffisant pour un audit.
    #
    # Variante avec $count côté API (plus rapide sur grands groupes) :
    #   $MemberCount = (Invoke-MgGraphRequest -Method GET `
    #       -Uri "https://graph.microsoft.com/v1.0/groups/$($Group.Id)/members/`$count" `
    #       -Headers @{"ConsistencyLevel"="eventual"}).value
    $Members = Get-MgGroupMember -GroupId $Group.Id -All -ErrorAction SilentlyContinue
    $Owners  = Get-MgGroupOwner  -GroupId $Group.Id -All -ErrorAction SilentlyContinue

    # --- Classification du type de groupe ---
    # On dérive le type lisible depuis la combinaison GroupTypes + SecurityEnabled + MailEnabled.
    # Cette logique est utilisée dans plusieurs exercices (3a, 3b, 3c) — ici centralisée
    # dans une variable $GroupType pour le rapport.
    $IsDynamic  = $Group.GroupTypes -contains "DynamicMembership"
    $IsUnified  = $Group.GroupTypes -contains "Unified"

    $GroupType = if ($IsUnified -and $IsDynamic)        { "M365 Dynamique" }
                 elseif ($IsUnified)                    { "M365 Statique" }
                 elseif ($Group.SecurityEnabled -and
                         $Group.MailEnabled)            { "Mail-enabled Security" }
                 elseif ($Group.SecurityEnabled -and
                         $IsDynamic)                    { "Security Dynamique" }
                 elseif ($Group.SecurityEnabled)        { "Security Statique" }
                 else                                   { "Autre" }

    [PSCustomObject]@{
        DisplayName                   = $Group.DisplayName
        Description                   = $Group.Description
        GroupType                     = $GroupType
        # SecurityEnabled / MailEnabled : colonnes brutes utiles pour filtrer en Excel
        # en complément du GroupType calculé.
        SecurityEnabled               = $Group.SecurityEnabled
        MailEnabled                   = $Group.MailEnabled
        Mail                          = $Group.Mail
        # MembershipRule : null pour les groupes statiques, renseignée pour les dynamiques.
        MembershipRule                = $Group.MembershipRule
        MembershipRuleProcessingState = $Group.MembershipRuleProcessingState
        # Visibility : "Public", "Private", ou $null (Security Groups n'ont pas ce champ)
        Visibility                    = $Group.Visibility
        CreatedDateTime               = $Group.CreatedDateTime
        NombreMembers                 = $Members.Count
        NombreOwners                  = $Owners.Count
        EstVide                       = ($Members.Count -eq 0)
        SansOwner                     = ($Owners.Count -eq 0)
        Id                            = $Group.Id
    }
}

Write-Host "-> Vue normalisée construite ($($GroupRows.Count) lignes).`n" -ForegroundColor Green

# ========================================================================================
# ÉTAPE 3 : Segmentation par type
# ========================================================================================
Write-Host "3. Segmentation par type de groupe..." -ForegroundColor Cyan

$SecurityGroups = $GroupRows | Where-Object { $GroupType = $_.GroupType
    $_.GroupType -in @("Security Statique", "Security Dynamique") }

$M365Groups     = $GroupRows | Where-Object {
    $_.GroupType -in @("M365 Statique", "M365 Dynamique") }

$MailSecGroups  = $GroupRows | Where-Object { $_.GroupType -eq "Mail-enabled Security" }

# --- Security Groups ---
Write-Host "`n=== SECURITY GROUPS ($($SecurityGroups.Count)) ===" -ForegroundColor Cyan
Write-Host "Statiques et dynamiques :`n" -ForegroundColor Gray

if ($SecurityGroups.Count -gt 0) {
    $SecurityGroups |
        Sort-Object GroupType, DisplayName |
        Select-Object DisplayName, GroupType, MembershipRule,
                      NombreMembers, NombreOwners, EstVide, SansOwner |
        Format-Table -AutoSize
} else {
    Write-Host "-> Aucun Security Group.`n" -ForegroundColor Yellow
}

# --- M365 Groups ---
Write-Host "`n=== M365 GROUPS / UNIFIED ($($M365Groups.Count)) ===" -ForegroundColor Cyan
Write-Host "Groupes avec mailbox partagée (Teams, SharePoint, Planner...) :`n" -ForegroundColor Gray

if ($M365Groups.Count -gt 0) {
    $M365Groups |
        Sort-Object GroupType, DisplayName |
        Select-Object DisplayName, GroupType, Mail, Visibility,
                      NombreMembers, NombreOwners, EstVide, SansOwner |
        Format-Table -AutoSize
} else {
    Write-Host "-> Aucun M365 Group.`n" -ForegroundColor Yellow
}

# --- Mail-enabled Security Groups ---
# Signalement séparé — ces groupes ne sont pas gérables en écriture via Graph PowerShell.
# Leur membership doit être géré depuis Exchange Admin Center ou via le module ExchangeOnlineManagement.
if ($MailSecGroups.Count -gt 0) {
    Write-Host "`n=== MAIL-ENABLED SECURITY GROUPS ($($MailSecGroups.Count)) ===" -ForegroundColor Yellow
    Write-Host "Non gérables en écriture via Graph — utiliser Exchange Admin Center :`n" -ForegroundColor Gray
    $MailSecGroups |
        Sort-Object DisplayName |
        Select-Object DisplayName, Mail, NombreMembers, NombreOwners |
        Format-Table -AutoSize
}

# ========================================================================================
# ÉTAPE 4 : Groupes vides
# ========================================================================================
Write-Host "4. Identification des groupes vides..." -ForegroundColor Cyan
Write-Host "`n=== GROUPES VIDES (AUCUN MEMBRE) ===" -ForegroundColor Red
Write-Host "Groupes sans membre — candidats au nettoyage :`n" -ForegroundColor Gray

$EmptyGroups = $GroupRows | Where-Object { $_.EstVide -eq $true }

if ($EmptyGroups.Count -gt 0) {
    $EmptyGroups |
        Sort-Object GroupType, DisplayName |
        Select-Object DisplayName, GroupType, NombreOwners,
                      SansOwner, CreatedDateTime |
        Format-Table -AutoSize
} else {
    Write-Host "-> Aucun groupe vide.`n" -ForegroundColor Green
}

# ========================================================================================
# ÉTAPE 5 : Vue d'ensemble complète
# ========================================================================================
Write-Host "5. Vue d'ensemble complète..." -ForegroundColor Cyan
Write-Host "`n=== VUE D'ENSEMBLE — TOUS LES GROUPES ===" -ForegroundColor Cyan
Write-Host "Triés par type puis par nombre de membres décroissant :`n" -ForegroundColor Gray

$GroupRows |
    Sort-Object GroupType, { -$_.NombreMembers } |
    Select-Object DisplayName, GroupType, NombreMembers, NombreOwners,
                  EstVide, SansOwner, CreatedDateTime |
    Format-Table -AutoSize

# ========================================================================================
# ÉTAPE 6 : Résumé chiffré
# ========================================================================================
Write-Host "`n=== RÉSUMÉ ===" -ForegroundColor Magenta

[PSCustomObject]@{
    TotalGroupes            = $AllGroups.Count
    SecurityStatiques       = ($GroupRows | Where-Object { $_.GroupType -eq "Security Statique" }).Count
    SecurityDynamiques      = ($GroupRows | Where-Object { $_.GroupType -eq "Security Dynamique" }).Count
    M365Statiques           = ($GroupRows | Where-Object { $_.GroupType -eq "M365 Statique" }).Count
    M365Dynamiques          = ($GroupRows | Where-Object { $_.GroupType -eq "M365 Dynamique" }).Count
    MailEnabledSecurity     = $MailSecGroups.Count
    GroupesVides            = $EmptyGroups.Count
    GroupesSansOwner        = ($GroupRows | Where-Object { $_.SansOwner -eq $true }).Count
    Scope                   = "Group.Read.All (lecture seule)"
    NoteAudit               = "Drill-down gouvernance owners → exo 3e"
} | Format-List

Write-Host "=== FIN DE L'AUDIT GROUPES ===" -ForegroundColor Green

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

# --- CSV 1 : Vue d'ensemble ---
# Colonnes exportées : DisplayName, Description, GroupType, SecurityEnabled, MailEnabled,
#                      Mail, MembershipRule, MembershipRuleProcessingState, Visibility,
#                      CreatedDateTime, NombreMembers, NombreOwners, EstVide, SansOwner, Id
# Colonnes disponibles non exportées :
#   $Group.AssignedLabels           : sensitivity labels appliqués au groupe M365
#   $Group.OnPremisesSyncEnabled    : groupe synchronisé depuis AD on-prem
#                                     un groupe on-prem ne peut pas être modifié dans Entra
#   $Group.OnPremisesLastSyncDateTime : date de la dernière synchro AAD Connect
#   $Group.RenewedDateTime          : date du dernier renouvellement (M365 Groups avec expiry policy)
#   $Group.ExpirationDateTime       : date d'expiration du groupe si une policy est configurée
$GroupRows |
    Sort-Object GroupType, { -$_.NombreMembers } |
    Export-Csv -Path "$ExportPath\Groups_Overview_$Timestamp.csv" `
               -Encoding UTF8 -NoTypeInformation
Write-Host "-> Vue d'ensemble : $($GroupRows.Count) ligne(s) — Groups_Overview_$Timestamp.csv" -ForegroundColor Green

# --- CSV 2 : Security Groups ---
if ($SecurityGroups.Count -gt 0) {
    $SecurityGroups |
        Sort-Object GroupType, DisplayName |
        Export-Csv -Path "$ExportPath\Groups_Security_$Timestamp.csv" `
                   -Encoding UTF8 -NoTypeInformation
    Write-Host "-> Security Groups : $($SecurityGroups.Count) ligne(s) — Groups_Security_$Timestamp.csv" -ForegroundColor Green
} else {
    Write-Host "-> Security Groups : aucune donnée à exporter." -ForegroundColor Yellow
}

# --- CSV 3 : M365 Groups ---
if ($M365Groups.Count -gt 0) {
    $M365Groups |
        Sort-Object GroupType, DisplayName |
        Export-Csv -Path "$ExportPath\Groups_M365_$Timestamp.csv" `
                   -Encoding UTF8 -NoTypeInformation
    Write-Host "-> M365 Groups : $($M365Groups.Count) ligne(s) — Groups_M365_$Timestamp.csv" -ForegroundColor Green
} else {
    Write-Host "-> M365 Groups : aucune donnée à exporter." -ForegroundColor Yellow
}

# --- CSV 4 : Groupes vides ---
# Livrable pour une campagne de nettoyage — à croiser avec l'exo 3e pour les sans-owner.
if ($EmptyGroups.Count -gt 0) {
    $EmptyGroups |
        Sort-Object GroupType, DisplayName |
        Export-Csv -Path "$ExportPath\Groups_Empty_$Timestamp.csv" `
                   -Encoding UTF8 -NoTypeInformation
    Write-Host "-> Groupes vides : $($EmptyGroups.Count) ligne(s) — Groups_Empty_$Timestamp.csv" -ForegroundColor Green
} else {
    Write-Host "-> Groupes vides : aucune donnée à exporter." -ForegroundColor Yellow
}

Write-Host "-> Export terminé dans : $ExportPath`n" -ForegroundColor Green

# ========================================================================================
# NETTOYAGE MÉMOIRE
# ========================================================================================
Remove-Variable Scopes, AllGroups, Group, Members, Owners, IsDynamic, IsUnified,
                GroupType, GroupRows, SecurityGroups, M365Groups, MailSecGroups,
                EmptyGroups, ExportPath, Timestamp `
                -ErrorAction SilentlyContinue

# ========================================================================================
# FERMETURE — RESET DE SESSION TOTAL
# ========================================================================================
Disconnect-MgGraph -ErrorAction SilentlyContinue
Write-Host "Session MgGraph fermée proprement." -ForegroundColor Magenta
