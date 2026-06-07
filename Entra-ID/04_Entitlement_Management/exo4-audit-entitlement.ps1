# ========================================================================================
# Exercice 4 : Entitlement Management — Audit des ressources du tenant
# ========================================================================================
# Objectif : Lister l'état complet de l'Entitlement Management —
# Catalogs, Access Packages, assignations actives, demandes en attente.
#
# Cas d'usage réel : un consultant IAM arrive en mission et veut un état des lieux
# complet des accès gouvernés en moins d'une minute.
#
# Note : Les opérations d'écriture (création, suppression) retournent 403 sur les
# tenants Developer — service backend IGA Microsoft hors périmètre Graph standard.
# Ce script se limite donc à la lecture — use case audit/reporting.
# ========================================================================================

# --- ÉTAPE 1 : Connexion à Microsoft Graph ---
# EntitlementManagement.Read.All suffit — on ne fait que lire
# Pas besoin du SP-IAM-Lab — ce scope fonctionne avec le ClientId par défaut
$Scopes = @(
    "EntitlementManagement.Read.All"
)
Connect-MgGraph -Scopes $Scopes

# --- ÉTAPE 2 : Audit des Catalogs ---
# Le Catalog est le conteneur logique — un par département ou usage en prod
# State "published" = actif / "unpublished" = désactivé
Write-Host "`n=== CATALOGS ===" -ForegroundColor Cyan
Get-MgEntitlementManagementCatalog -All |
    Select-Object Id, DisplayName, State, IsExternallyVisible |
    Format-Table -AutoSize

# --- ÉTAPE 3 : Audit des Access Packages ---
# Un Access Package = ensemble de droits demandables par un utilisateur
# IsHidden = s'il est visible dans le portail My Access
Write-Host "`n=== ACCESS PACKAGES ===" -ForegroundColor Cyan
Get-MgEntitlementManagementAccessPackage -All |
    Select-Object Id, DisplayName, Description, CatalogId, IsHidden |
    Format-Table -AutoSize

# --- ÉTAPE 4 : Audit des assignations actives ---
# State "delivered" = droits effectivement assignés à un utilisateur
# Utile pour auditer qui a accès à quoi à un instant T
Write-Host "`n=== ASSIGNATIONS ACTIVES ===" -ForegroundColor Cyan
$ActiveAssignments = Get-MgEntitlementManagementAssignment `
    -Filter "state eq 'delivered'" -All

if ($ActiveAssignments) {
    $ActiveAssignments | Select-Object Id, State | Format-Table -AutoSize
} else {
    Write-Host "-> Aucune assignation active." -ForegroundColor Yellow
}

# --- ÉTAPE 5 : Audit des demandes en attente ---
# State "pendingApproval" = demandes soumises mais pas encore approuvées
# Utile pour un manager qui veut voir les demandes en attente de sa validation
Write-Host "`n=== DEMANDES EN ATTENTE ===" -ForegroundColor Cyan
$PendingRequests = Get-MgEntitlementManagementAssignmentRequest `
    -Filter "state eq 'pendingApproval'"

if ($PendingRequests) {
    $PendingRequests | Select-Object Id, RequestType, State | Format-Table -AutoSize
} else {
    Write-Host "-> Aucune demande en attente." -ForegroundColor Yellow
}

Write-Host "`n=== FIN DE L'AUDIT ===" -ForegroundColor Green

# --- ÉTAPE 6 : Nettoyage ---
Remove-Variable Scopes, ActiveAssignments, PendingRequests -ErrorAction SilentlyContinue

Write-Host "`nMémoire locale nettoyée. Session Microsoft Graph toujours active." -ForegroundColor Magenta
