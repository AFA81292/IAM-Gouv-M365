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
#   6. Ferme proprement toutes les sessions
#
# Cas d'usage réel : un consultant IAM arrive en mission et veut un état des lieux
# complet des accès gouvernés en moins d'une minute — sans toucher à aucun objet.
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
Get-MgEntitlementManagementCatalog -All |
    Select-Object Id, DisplayName, State, IsExternallyVisible |
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
Get-MgEntitlementManagementAccessPackage -All |
    Select-Object Id, DisplayName, Description, CatalogId, IsHidden |
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
# En production, on enrichirait cet export avec AccessPackageId et TargetId
# pour identifier l'utilisateur et le package concernés.
$ActiveAssignments = Get-MgEntitlementManagementAssignment `
    -Filter "state eq 'delivered'" -All

if ($ActiveAssignments) {
    $ActiveAssignments | Select-Object Id, State | Format-Table -AutoSize
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
# Cas d'usage : un manager ou un admin IAM veut voir les demandes en attente
# de sa validation sans passer par le portail My Access.
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
    Scope              = "EntitlementManagement.Read.All"
    CatalogsAuditEs    = "Oui"
    AccessPackagesAud  = "Oui"
    AssignationsActives = if ($ActiveAssignments) { $ActiveAssignments.Count } else { 0 }
    DemandesEnAttente  = if ($PendingRequests)    { $PendingRequests.Count    } else { 0 }
    LimitesTenant      = "Écriture EM bloquée sur tenant Developer (403 — backend IGA hors périmètre)"
} | Format-List

Write-Host "=== FIN DE L'AUDIT ===" -ForegroundColor Green

# ========================================================================================
# NETTOYAGE MÉMOIRE
# ========================================================================================
Remove-Variable Scopes, ActiveAssignments, PendingRequests `
    -ErrorAction SilentlyContinue

# ========================================================================================
# FERMETURE — RESET DE SESSION TOTAL
# ========================================================================================
Disconnect-MgGraph -ErrorAction SilentlyContinue
Write-Host "Session MgGraph fermée proprement." -ForegroundColor Magenta
