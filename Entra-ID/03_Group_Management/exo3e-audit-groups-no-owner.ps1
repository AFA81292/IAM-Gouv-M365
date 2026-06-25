# ========================================================================================
# Exercice 3e : Entra ID — Audit des groupes sans propriétaire
# ========================================================================================
# Concept : Un groupe sans owner est un groupe orphelin — personne n'est responsable
# de sa gouvernance : qui y a accès, pourquoi, pour combien de temps.
# En Access Review, un groupe sans owner ne peut pas être soumis à une révision
# par son responsable métier — l'IT doit reprendre la main, ce qui ralentit le processus.
# À l'inverse, un groupe avec trop d'owners dilue la responsabilité.
#
# Ce script identifie 3 populations à risque gouvernance :
#   - Groupes sans owner                → orphelins, non gouvernés
#   - Groupes avec plusieurs owners     → responsabilité diluée (seuil configurable)
#   - Groupes sans membre               → potentiellement inutiles (complément de l'exo 3d)
#
# Delta pédagogique vs exercice 3d (audit général) :
#   3d → inventaire exhaustif tous groupes — comptage owners/membres, segmentation par type
#   3e → drill-down gouvernance : résolution complète des owners (nom + UPN),
#        détection des anomalies ownership, export dédié par anomalie
#
# Ce que fait ce script :
#   1. Reset total de session
#   2. Récupère tous les groupes du tenant
#   3. Pour chaque groupe : résout les owners en DisplayName + UPN
#   4. Identifie les groupes sans owner
#   5. Identifie les groupes avec trop d'owners
#   6. Identifie les groupes sans membre
#   7. Affiche la vue d'ensemble gouvernance
#   8. Affiche un résumé chiffré
#   9. Exporte les résultats en CSV horodatés
#  10. Ferme proprement toutes les sessions
#
# Note : ce script est en lecture seule — aucune modification du tenant.
#
# Fichiers CSV générés :
#   Groups_NoOwner_YYYYMMDD_HHmmss.csv       → groupes sans owner
#   Groups_MultiOwner_YYYYMMDD_HHmmss.csv    → groupes avec > seuil owners
#   Groups_NoMember_YYYYMMDD_HHmmss.csv      → groupes sans membre
#   Groups_Governance_YYYYMMDD_HHmmss.csv    → vue complète avec owners résolus
#
# Module requis : Microsoft.Graph.Groups, Microsoft.Graph.Users
# Connexion     : Connect-MgGraph
# ========================================================================================

# --- OUVERTURE — RESET DE SESSION TOTAL ---
# Group.Read.All : lire tous les groupes, leurs membres et leurs owners
# User.Read.All  : résoudre les PrincipalId des owners en DisplayName/UPN lisibles
#
# REX : Get-MgGroupOwner retourne des objets DirectoryObject avec un Id (GUID).
# Sans User.Read.All, on ne peut pas résoudre ces GUIDs en noms lisibles —
# le rapport n'afficherait que des identifiants bruts inexploitables.
$Scopes = @(
    "Group.Read.All",
    "User.Read.All"
)

Disconnect-MgGraph -ErrorAction SilentlyContinue
Connect-MgGraph -Scopes $Scopes -NoWelcome

# ========================================================================================
# ÉTAPE 1 : Définition du seuil multi-owners
# ========================================================================================
Write-Host "1. Définition des paramètres..." -ForegroundColor Cyan

# Seuil au-delà duquel un groupe est considéré comme ayant trop d'owners.
# 2 owners est la recommandation Microsoft pour la continuité (1 titulaire + 1 backup).
# Au-delà de ce seuil, la responsabilité se dilue — qui valide les demandes d'accès ?
#
# Variantes selon la politique de l'organisation :
#   2 → recommandation Microsoft standard (1 titulaire + 1 backup)
#   3 → acceptable pour les grands départements (titulaire + 2 délégués)
#   5 → seuil large, souvent utilisé pour les groupes de distribution M365
$MultiOwnerThreshold = 2

Write-Host "-> Seuil multi-owners : > $MultiOwnerThreshold owners considéré comme anomalie" -ForegroundColor Green

# ========================================================================================
# ÉTAPE 2 : Récupération de tous les groupes
# ========================================================================================
Write-Host "`n2. Récupération de tous les groupes..." -ForegroundColor Cyan

$AllGroups = Get-MgGroup -All `
    -Property "Id, DisplayName, Description, GroupTypes,
               SecurityEnabled, MailEnabled, Mail, CreatedDateTime" `
    -ErrorAction Stop

Write-Host "-> $($AllGroups.Count) groupe(s) récupéré(s).`n" -ForegroundColor Green

if ($AllGroups.Count -eq 0) {
    Write-Host "Aucun groupe à analyser. Fin du script." -ForegroundColor Yellow
    Disconnect-MgGraph -ErrorAction SilentlyContinue
    return
}

# ========================================================================================
# ÉTAPE 3 : Résolution des owners et membres par groupe
# ========================================================================================
Write-Host "3. Résolution des owners et membres (2 appels API par groupe)..." -ForegroundColor Cyan
Write-Host "   Cela peut prendre quelques secondes selon le nombre de groupes..." -ForegroundColor Gray

$GovernanceRows = foreach ($Group in $AllGroups) {

    # --- Classification du type (reprise de la logique exo 3d) ---
    $IsDynamic = $Group.GroupTypes -contains "DynamicMembership"
    $IsUnified = $Group.GroupTypes -contains "Unified"

    $GroupType = if ($IsUnified -and $IsDynamic)     { "M365 Dynamique" }
                 elseif ($IsUnified)                 { "M365 Statique" }
                 elseif ($Group.SecurityEnabled -and
                         $Group.MailEnabled)         { "Mail-enabled Security" }
                 elseif ($Group.SecurityEnabled -and
                         $IsDynamic)                 { "Security Dynamique" }
                 elseif ($Group.SecurityEnabled)     { "Security Statique" }
                 else                                { "Autre" }

    # --- Résolution des owners ---
    # Get-MgGroupOwner retourne des objets DirectoryObject (Id uniquement par défaut).
    # On résout chaque Id en objet User via Get-MgUser.
    # -ErrorAction SilentlyContinue : l'owner peut être un Service Principal (app)
    # et non un utilisateur — dans ce cas Get-MgUser retourne null, on garde l'Id brut.
    $Owners = Get-MgGroupOwner -GroupId $Group.Id -All -ErrorAction SilentlyContinue

    $OwnersResolved = @()
    foreach ($Owner in $Owners) {
        $OwnerUser = Get-MgUser -UserId $Owner.Id -ErrorAction SilentlyContinue
        if ($OwnerUser) {
            $OwnersResolved += [PSCustomObject]@{
                DisplayName = $OwnerUser.DisplayName
                UPN         = $OwnerUser.UserPrincipalName
                Id          = $Owner.Id
                Type        = "User"
            }
        } else {
            # L'owner n'est pas un utilisateur — probablement un Service Principal.
            # On garde l'Id brut et on signale le type inconnu pour investigation.
            # Cas courant : applications M365 (Teams, Planner...) automatiquement
            # ajoutées comme owners lors de la création d'un groupe via ces services.
            $OwnersResolved += [PSCustomObject]@{
                DisplayName = "Non résolu (SP ou objet non-user)"
                UPN         = "N/A"
                Id          = $Owner.Id
                Type        = "ServicePrincipal/Autre"
            }
        }
    }

    # --- Comptage des membres ---
    # On récupère uniquement le count — pas besoin de résoudre les membres ici,
    # l'exo 3d couvre déjà l'inventaire détaillé des membres.
    $Members = Get-MgGroupMember -GroupId $Group.Id -All -ErrorAction SilentlyContinue

    # --- Concaténation des owners pour le CSV ---
    # Une ligne par groupe — les owners sont concaténés en une seule cellule.
    # En Excel, filtrer sur la colonne OwnerNames pour retrouver tous les groupes
    # dont un owner spécifique est responsable.
    #
    # Variante une ligne par owner (meilleure pour les pivots Excel) :
    #   foreach ($Owner in $OwnersResolved) {
    #       [PSCustomObject]@{ GroupName = ...; OwnerName = $Owner.DisplayName; ... }
    #   }
    # Cette variante est utilisée dans les CSV dédiés ci-dessous pour les groupes sans owner.
    $OwnerNames = ($OwnersResolved | ForEach-Object { $_.DisplayName }) -join " | "
    $OwnerUPNs  = ($OwnersResolved | ForEach-Object { $_.UPN })         -join " | "

    [PSCustomObject]@{
        DisplayName      = $Group.DisplayName
        Description      = $Group.Description
        GroupType        = $GroupType
        CreatedDateTime  = $Group.CreatedDateTime
        NombreOwners     = $Owners.Count
        NombreMembers    = $Members.Count
        OwnerNames       = if ($OwnerNames) { $OwnerNames } else { "AUCUN OWNER" }
        OwnerUPNs        = if ($OwnerUPNs)  { $OwnerUPNs }  else { "AUCUN OWNER" }
        # Flags de gouvernance — utilisés pour les segments suivants
        SansOwner        = ($Owners.Count -eq 0)
        MultiOwner       = ($Owners.Count -gt $MultiOwnerThreshold)
        SansMembre       = ($Members.Count -eq 0)
        Id               = $Group.Id
    }
}

Write-Host "-> Résolution terminée ($($GovernanceRows.Count) groupes traités).`n" -ForegroundColor Green

# ========================================================================================
# ÉTAPE 4 : Groupes sans owner
# ========================================================================================
Write-Host "4. Groupes sans owner..." -ForegroundColor Cyan
Write-Host "`n=== GROUPES SANS OWNER ===" -ForegroundColor Red
Write-Host "Groupes orphelins — aucun responsable désigné :`n" -ForegroundColor Gray

$NoOwnerGroups = $GovernanceRows | Where-Object { $_.SansOwner -eq $true }

if ($NoOwnerGroups.Count -gt 0) {
    $NoOwnerGroups |
        Sort-Object GroupType, DisplayName |
        Select-Object DisplayName, GroupType, NombreMembers, CreatedDateTime |
        Format-Table -AutoSize
} else {
    Write-Host "-> Aucun groupe sans owner.`n" -ForegroundColor Green
}

# ========================================================================================
# ÉTAPE 5 : Groupes avec trop d'owners
# ========================================================================================
Write-Host "5. Groupes avec > $MultiOwnerThreshold owners..." -ForegroundColor Cyan
Write-Host "`n=== GROUPES AVEC TROP D'OWNERS (> $MultiOwnerThreshold) ===" -ForegroundColor Yellow
Write-Host "Responsabilité diluée — à revoir avec les métiers :`n" -ForegroundColor Gray

$MultiOwnerGroups = $GovernanceRows | Where-Object { $_.MultiOwner -eq $true }

if ($MultiOwnerGroups.Count -gt 0) {
    $MultiOwnerGroups |
        Sort-Object NombreOwners -Descending |
        Select-Object DisplayName, GroupType, NombreOwners, NombreMembers, OwnerNames |
        Format-Table -AutoSize
} else {
    Write-Host "-> Aucun groupe au-dessus du seuil de $MultiOwnerThreshold owners.`n" -ForegroundColor Green
}

# ========================================================================================
# ÉTAPE 6 : Groupes sans membre
# ========================================================================================
Write-Host "6. Groupes sans membre..." -ForegroundColor Cyan
Write-Host "`n=== GROUPES SANS MEMBRE ===" -ForegroundColor Yellow
Write-Host "Groupes vides — candidats au nettoyage (complément exo 3d) :`n" -ForegroundColor Gray

# Note : les groupes dynamiques peuvent apparaître vides si le moteur de règle
# n'a pas encore évalué la membership (délai jusqu'à 24h après création).
# On signale le type pour distinguer "vraiment vide" de "en attente d'évaluation".
$NoMemberGroups = $GovernanceRows | Where-Object { $_.SansMembre -eq $true }

if ($NoMemberGroups.Count -gt 0) {
    $NoMemberGroups |
        Sort-Object GroupType, DisplayName |
        Select-Object DisplayName, GroupType, NombreOwners, OwnerNames, CreatedDateTime |
        Format-Table -AutoSize
} else {
    Write-Host "-> Aucun groupe sans membre.`n" -ForegroundColor Green
}

# ========================================================================================
# ÉTAPE 7 : Vue d'ensemble gouvernance
# ========================================================================================
Write-Host "7. Vue d'ensemble gouvernance..." -ForegroundColor Cyan
Write-Host "`n=== VUE D'ENSEMBLE — GOUVERNANCE OWNERS ===" -ForegroundColor Cyan
Write-Host "Tous les groupes — triés par anomalie de gouvernance :`n" -ForegroundColor Gray

# Ordre de tri : anomalies les plus critiques en premier.
# SansOwner > MultiOwner > SansMembre > OK
# On force l'ordre via un index numérique — même logique que l'exo 1l pour les catégories.
$GovernanceOrder = @{
    "SansOwner"   = 0
    "MultiOwner"  = 1
    "SansMembre"  = 2
    "OK"          = 3
}

$GovernanceRows |
    Sort-Object {
        if ($_.SansOwner)       { $GovernanceOrder["SansOwner"] }
        elseif ($_.MultiOwner)  { $GovernanceOrder["MultiOwner"] }
        elseif ($_.SansMembre)  { $GovernanceOrder["SansMembre"] }
        else                    { $GovernanceOrder["OK"] }
    }, DisplayName |
    Select-Object DisplayName, GroupType, NombreOwners, NombreMembers,
                  SansOwner, MultiOwner, SansMembre, OwnerNames |
    Format-Table -AutoSize

# ========================================================================================
# ÉTAPE 8 : Résumé chiffré
# ========================================================================================
Write-Host "`n=== RÉSUMÉ ===" -ForegroundColor Magenta

$WellGoverned = ($GovernanceRows | Where-Object {
    $_.SansOwner -eq $false -and
    $_.MultiOwner -eq $false
}).Count

[PSCustomObject]@{
    TotalGroupes            = $AllGroups.Count
    GroupesSansOwner        = $NoOwnerGroups.Count
    "GroupesMultiOwner_>$MultiOwnerThreshold" = $MultiOwnerGroups.Count
    GroupesSansMembre       = $NoMemberGroups.Count
    GroupesBienGouvernés    = $WellGoverned
    SeuilMultiOwner         = "> $MultiOwnerThreshold owners"
    Scope                   = "Group.Read.All + User.Read.All (lecture seule)"
    NoteAudit               = "Suite logique : Access Review sur groupes sans owner → exo 7b"
} | Format-List

Write-Host "=== FIN DE L'AUDIT GOUVERNANCE GROUPES ===" -ForegroundColor Green

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

# --- CSV 1 : Vue gouvernance complète ---
# Colonnes exportées : DisplayName, Description, GroupType, CreatedDateTime,
#                      NombreOwners, NombreMembers, OwnerNames, OwnerUPNs,
#                      SansOwner, MultiOwner, SansMembre, Id
# Colonnes disponibles non exportées :
#   $Group.OnPremisesSyncEnabled   : groupe synchronisé depuis AD on-prem —
#                                     l'ownership doit être corrigée dans AD, pas dans Entra
#   $Group.AssignedLabels          : sensitivity labels (M365 Groups uniquement)
#   $Group.ExpirationDateTime      : date d'expiration si une Expiration Policy est configurée
#                                     (M365 Groups uniquement — Entra ID P1/P2 requis)
#   OwnerType (User/SP)            : disponible dans $OwnersResolved mais non remonté
#                                     dans $GovernanceRows — ajouter si besoin de détecter
#                                     les groupes dont l'unique owner est un Service Principal
$GovernanceRows |
    Sort-Object {
        if ($_.SansOwner)       { 0 }
        elseif ($_.MultiOwner)  { 1 }
        elseif ($_.SansMembre)  { 2 }
        else                    { 3 }
    }, DisplayName |
    Export-Csv -Path "$ExportPath\Groups_Governance_$Timestamp.csv" `
               -Encoding UTF8 -NoTypeInformation
Write-Host "-> Vue gouvernance : $($GovernanceRows.Count) ligne(s) — Groups_Governance_$Timestamp.csv" -ForegroundColor Green

# --- CSV 2 : Groupes sans owner ---
# Livrable principal pour une campagne de ré-ownership — à transmettre aux métiers
# pour désignation d'un responsable, ou à soumettre en Access Review (exo 7b).
if ($NoOwnerGroups.Count -gt 0) {
    $NoOwnerGroups |
        Sort-Object GroupType, DisplayName |
        Export-Csv -Path "$ExportPath\Groups_NoOwner_$Timestamp.csv" `
                   -Encoding UTF8 -NoTypeInformation
    Write-Host "-> Sans owner : $($NoOwnerGroups.Count) ligne(s) — Groups_NoOwner_$Timestamp.csv" -ForegroundColor Green
} else {
    Write-Host "-> Sans owner : aucune donnée à exporter." -ForegroundColor Yellow
}

# --- CSV 3 : Groupes avec trop d'owners ---
if ($MultiOwnerGroups.Count -gt 0) {
    $MultiOwnerGroups |
        Sort-Object NombreOwners -Descending |
        Export-Csv -Path "$ExportPath\Groups_MultiOwner_$Timestamp.csv" `
                   -Encoding UTF8 -NoTypeInformation
    Write-Host "-> Multi-owners : $($MultiOwnerGroups.Count) ligne(s) — Groups_MultiOwner_$Timestamp.csv" -ForegroundColor Green
} else {
    Write-Host "-> Multi-owners : aucune donnée à exporter." -ForegroundColor Yellow
}

# --- CSV 4 : Groupes sans membre ---
if ($NoMemberGroups.Count -gt 0) {
    $NoMemberGroups |
        Sort-Object GroupType, DisplayName |
        Export-Csv -Path "$ExportPath\Groups_NoMember_$Timestamp.csv" `
                   -Encoding UTF8 -NoTypeInformation
    Write-Host "-> Sans membre : $($NoMemberGroups.Count) ligne(s) — Groups_NoMember_$Timestamp.csv" -ForegroundColor Green
} else {
    Write-Host "-> Sans membre : aucune donnée à exporter." -ForegroundColor Yellow
}

Write-Host "-> Export terminé dans : $ExportPath`n" -ForegroundColor Green

# ========================================================================================
# NETTOYAGE MÉMOIRE
# ========================================================================================
Remove-Variable Scopes, MultiOwnerThreshold, AllGroups, Group,
                IsDynamic, IsUnified, GroupType, Owners, OwnersResolved,
                Owner, OwnerUser, OwnerNames, OwnerUPNs, Members,
                GovernanceRows, NoOwnerGroups, MultiOwnerGroups, NoMemberGroups,
                WellGoverned, GovernanceOrder, ExportPath, Timestamp `
                -ErrorAction SilentlyContinue

# ========================================================================================
# FERMETURE — RESET DE SESSION TOTAL
# ========================================================================================
Disconnect-MgGraph -ErrorAction SilentlyContinue
Write-Host "Session MgGraph fermée proprement." -ForegroundColor Magenta
