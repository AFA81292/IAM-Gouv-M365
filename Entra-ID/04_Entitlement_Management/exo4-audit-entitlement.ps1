# ========================================================================================
# Exercice 4 : Entra ID — Entitlement Management — Audit complet des ressources
# ========================================================================================
# Concept : L'Entitlement Management (EM) est le module IGA (Identity Governance &
# Administration) d'Entra ID. Il permet de gouverner les accès via des Access Packages —
# des ensembles de droits demandables par les utilisateurs via le portail My Access.
#
# Ce que fait ce script :
#   1. Reset total de session
#   2. Audite les Catalogs (conteneurs logiques)
#   3. Audite les Access Packages (ensembles de droits)
#   4. Audite les assignations actives (droits effectivement délivrés)
#   5. Audite les demandes en attente d'approbation
#   6. Exporte les quatre jeux de données en CSV horodatés
#   7. Ferme proprement toutes les sessions
#
# Cas d'usage réel : un consultant IAM arrive en mission et veut un état des lieux
# complet des accès gouvernés en moins d'une minute — sans toucher à aucun objet,
# avec un export CSV exploitable immédiatement dans Excel.
#
# DÉCOUVERTE TECHNIQUE : les opérations d'écriture (création, suppression d'Access
# Packages, de Catalogs, de policies EM) retournent systématiquement 403 sur les
# tenants Developer. Le backend IGA Microsoft est hors périmètre Graph standard
# sur ce type de tenant. Ce script se limite donc à la lecture — audit/reporting uniquement.
#
# Architecture Entitlement Management :
#   Catalog        → conteneur logique (un par département ou usage en prod)
#   Access Package → ensemble de droits demandables (groupes, rôles, apps, SPO)
#   Assignment     → droits effectivement délivrés à un utilisateur
#   Request        → demande soumise par un utilisateur (approuvée, en attente, refusée)
#
# Fichiers CSV générés :
#   EM_Catalogs_YYYYMMDD_HHmmss.csv
#   EM_AccessPackages_YYYYMMDD_HHmmss.csv
#   EM_AssignationsActives_YYYYMMDD_HHmmss.csv
#   EM_DemandesEnAttente_YYYYMMDD_HHmmss.csv
#
# Module requis : Microsoft.Graph.Identity.Governance
# Connexion     : Connect-MgGraph
# ========================================================================================

# --- OUVERTURE — RESET DE SESSION TOTAL ---
# EntitlementManagement.Read.All suffit — ce script ne fait que lire.
# Pas besoin du service principal SP-IAM-Lab — le ClientId par défaut du SDK Graph
# supporte ce scope en délégué (contexte utilisateur connecté).
$Scopes = @(
    "EntitlementManagement.Read.All"
)

Disconnect-MgGraph -ErrorAction SilentlyContinue
Connect-MgGraph -Scopes $Scopes

# ========================================================================================
# ÉTAPE 1 : Audit des Catalogs
# ========================================================================================
Write-Host "`n=== CATALOGS ===" -ForegroundColor Cyan

# Le Catalog est le conteneur de premier niveau de l'Entitlement Management.
# En production : un Catalog par département (RH, Finance, IT) ou par usage (interne/externe).
#
# State :
#   "published"   = Catalog actif, visible et utilisable
#   "unpublished" = Catalog désactivé — les Access Packages qu'il contient
#                   ne sont plus accessibles aux utilisateurs
#
# IsExternallyVisible :
#   $true  = le Catalog est visible pour les utilisateurs invités (B2B)
#   $false = réservé aux utilisateurs internes du tenant
$Catalogs = Get-MgEntitlementManagementCatalog -All

$Catalogs | Select-Object Id, DisplayName, State, IsExternallyVisible |
    Format-Table -AutoSize

# ========================================================================================
# ÉTAPE 2 : Audit des Access Packages
# ========================================================================================
Write-Host "`n=== ACCESS PACKAGES ===" -ForegroundColor Cyan

# Un Access Package = ensemble de droits demandables par un utilisateur via My Access.
# Il peut contenir : des membres de groupes, des rôles d'apps, des rôles SPO, des rôles Entra.
# Un utilisateur soumet une demande → le workflow d'approbation se déclenche →
# si approuvé, les droits sont délivrés (Assignment en état "delivered").
#
# IsHidden :
#   $false = visible dans le portail My Access (myaccess.microsoft.com)
#   $true  = masqué — accessible uniquement via lien direct ou assignation administrative
#
# CatalogId : référence le Catalog parent — utile pour filtrer par département.
$AccessPackages = Get-MgEntitlementManagementAccessPackage -All

$AccessPackages | Select-Object Id, DisplayName, Description, CatalogId, IsHidden |
    Format-Table -AutoSize

# ========================================================================================
# ÉTAPE 3 : Audit des assignations actives
# ========================================================================================
Write-Host "`n=== ASSIGNATIONS ACTIVES ===" -ForegroundColor Cyan

# State "delivered" = droits effectivement actifs sur le compte de l'utilisateur.
# C'est l'état final positif du cycle de vie d'une demande EM.
#
# Cycle de vie d'une assignation :
#   submitted → pendingApproval → approved → delivering → delivered → expired/removed
#
# Cas d'usage audit : qui a accès à quoi à un instant T ?
$ActiveAssignments = Get-MgEntitlementManagementAssignment `
    -Filter "state eq 'delivered'" -All

if ($ActiveAssignments) {
    $ActiveAssignments | Select-Object Id, State, AccessPackageId, TargetId |
        Format-Table -AutoSize
} else {
    Write-Host "-> Aucune assignation active détectée." -ForegroundColor Yellow
}

# ========================================================================================
# ÉTAPE 4 : Audit des demandes en attente d'approbation
# ========================================================================================
Write-Host "`n=== DEMANDES EN ATTENTE ===" -ForegroundColor Cyan

# State "pendingApproval" = demandes soumises par des utilisateurs,
# en attente de validation par un approbateur désigné dans la policy de l'Access Package.
#
# RequestType :
#   "UserAdd"    = demande d'accès initiale
#   "UserRemove" = demande de retrait d'accès
#   "AdminAdd"   = assignation directe par un admin (sans workflow)
$PendingRequests = Get-MgEntitlementManagementAssignmentRequest `
    -Filter "state eq 'pendingApproval'"

if ($PendingRequests) {
    $PendingRequests | Select-Object Id, RequestType, State | Format-Table -AutoSize
} else {
    Write-Host "-> Aucune demande en attente d'approbation." -ForegroundColor Yellow
}

# ========================================================================================
# RÉSUMÉ
# ========================================================================================
Write-Host "`n=== RÉSUMÉ ===" -ForegroundColor Magenta
[PSCustomObject]@{
    Scope               = "EntitlementManagement.Read.All"
    CatalogsAudités     = if ($Catalogs)           { $Catalogs.Count           } else { 0 }
    AccessPackagesAudités = if ($AccessPackages)   { $AccessPackages.Count     } else { 0 }
    AssignationsActives = if ($ActiveAssignments)  { $ActiveAssignments.Count  } else { 0 }
    DemandesEnAttente   = if ($PendingRequests)    { $PendingRequests.Count    } else { 0 }
    LimitesTenant       = "Écriture EM bloquée sur tenant Developer (403 — backend IGA hors périmètre)"
} | Format-List

Write-Host "=== FIN DE L'AUDIT ===" -ForegroundColor Green

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

# --- CSV 1 : Catalogs ---
# Colonnes exportées : Id, DisplayName, State, IsExternallyVisible
# Colonnes disponibles non exportées :
#   Description      : description du catalog
#   CreatedDateTime  : date de création
#   ModifiedDateTime : date de dernière modification
$CatalogExport = $Catalogs |
    Select-Object Id, DisplayName, State, IsExternallyVisible

$CatalogExport | Export-Csv `
    -Path "$ExportPath\EM_Catalogs_$Timestamp.csv" `
    -Encoding UTF8 -NoTypeInformation
Write-Host "-> Catalogs : $($CatalogExport.Count) ligne(s) — EM_Catalogs_$Timestamp.csv" -ForegroundColor Green

# --- CSV 2 : Access Packages ---
# Colonnes exportées : Id, DisplayName, Description, CatalogId, IsHidden
# Colonnes disponibles non exportées :
#   CreatedDateTime     : date de création du package
#   ModifiedDateTime    : date de dernière modification
#   IsRoleScopesVisible : visibilité des rôles dans le portail My Access
$PackageExport = $AccessPackages |
    Select-Object Id, DisplayName, Description, CatalogId, IsHidden

$PackageExport | Export-Csv `
    -Path "$ExportPath\EM_AccessPackages_$Timestamp.csv" `
    -Encoding UTF8 -NoTypeInformation
Write-Host "-> Access Packages : $($PackageExport.Count) ligne(s) — EM_AccessPackages_$Timestamp.csv" -ForegroundColor Green

# --- CSV 3 : Assignations actives ---
# Colonnes exportées : Id, State, AccessPackageId, TargetId, AssignmentPolicyId
# Colonnes disponibles non exportées :
#   ExpiredDateTime    : date d'expiration (null = permanente)
#   Schedule           : détail de la planification si time-bound
#
# Note : TargetId = ObjectId Entra de l'utilisateur assigné.
# Pour résoudre en DisplayName : Get-MgUser -UserId $_.TargetId (coûteux en volume)
if ($ActiveAssignments) {
    $ActiveAssignments |
        Select-Object Id, State, AccessPackageId, TargetId, AssignmentPolicyId |
        Export-Csv `
            -Path "$ExportPath\EM_AssignationsActives_$Timestamp.csv" `
            -Encoding UTF8 -NoTypeInformation
    Write-Host "-> Assignations actives : $($ActiveAssignments.Count) ligne(s) — EM_AssignationsActives_$Timestamp.csv" -ForegroundColor Green
} else {
    Write-Host "-> Assignations actives : aucune donnée à exporter." -ForegroundColor Yellow
}

# --- CSV 4 : Demandes en attente ---
# Colonnes exportées : Id, RequestType, State, RequestorId, AccessPackageId
# Colonnes disponibles non exportées :
#   CreatedDateTime   : date de soumission de la demande
#   CompletedDateTime : date de traitement (null si encore en attente)
#   Justification     : texte saisi par le demandeur — utile pour audit de conformité
#   Answers           : réponses aux questions du workflow d'approbation
#
# Note : RequestorId = ObjectId Entra du demandeur.
# Pour résoudre en DisplayName : Get-MgUser -UserId $_.Requestor.ObjectId
if ($PendingRequests) {
    $PendingRequests |
        Select-Object Id, RequestType, State,
            @{N="RequestorId";    E={ $_.Requestor.ObjectId }},
            @{N="AccessPackageId"; E={ $_.AccessPackage.Id }} |
        Export-Csv `
            -Path "$ExportPath\EM_DemandesEnAttente_$Timestamp.csv" `
            -Encoding UTF8 -NoTypeInformation
    Write-Host "-> Demandes en attente : $($PendingRequests.Count) ligne(s) — EM_DemandesEnAttente_$Timestamp.csv" -ForegroundColor Green
} else {
    Write-Host "-> Demandes en attente : aucune donnée à exporter." -ForegroundColor Yellow
}

Write-Host "-> Export terminé dans : $ExportPath`n" -ForegroundColor Green

# ========================================================================================
# NETTOYAGE MÉMOIRE
# ========================================================================================
Remove-Variable Scopes, Catalogs, AccessPackages, ActiveAssignments, PendingRequests,
                ExportPath, Timestamp, CatalogExport, PackageExport `
                -ErrorAction SilentlyContinue

# ========================================================================================
# FERMETURE — RESET DE SESSION TOTAL
# ========================================================================================
Disconnect-MgGraph -ErrorAction SilentlyContinue
Write-Host "Session MgGraph fermée proprement." -ForegroundColor Magenta
