# ========================================================================================
# Exercice 2c : Entra ID — Audit des Administrative Units
# ========================================================================================
# Concept : Les Administrative Units (AU) sont des conteneurs de délégation dans Entra.
# Elles permettent de limiter la portée d'un rôle admin à un sous-ensemble d'objets
# du tenant (ex : un Helpdesk Admin qui ne peut gérer que les users d'une région).
# Mal gouvernées, elles génèrent deux risques opposés :
#   - AU vide    → délégation fantôme, rôle scopé sans objet — à nettoyer
#   - AU sans admin scopé → conteneur peuplé mais personne pour le gérer — gouvernance morte
#
# Ce script identifie 4 populations à analyser :
#   - Toutes les AUs du tenant               → vue d'ensemble (statique + dynamique)
#   - AUs vides                              → aucun membre
#   - AUs sans admin scopé                   → aucun rôle délégué
#   - AUs avec leur détail complet           → membres + admins scopés résolus
#
# Delta pédagogique vs exercices 2a/2b (création) :
#   2a → création d'une AU statique + délégation d'un rôle scopé
#   2b → création d'une AU dynamique avec règle de membership
#   2c → audit en lecture seule : inventaire, détection des AUs mal gouvernées,
#        résolution des membres et admins scopés, export CSV
#
# Ce que fait ce script :
#   1. Reset total de session
#   2. Récupère toutes les AUs du tenant
#   3. Pour chaque AU : résout les membres et les admins scopés
#   4. Identifie les AUs vides
#   5. Identifie les AUs sans admin scopé
#   6. Affiche la vue détaillée complète
#   7. Affiche un résumé chiffré
#   8. Exporte les résultats en CSV horodatés
#   9. Ferme proprement toutes les sessions
#
# Note : ce script est en lecture seule — aucune modification du tenant.
#
# Fichiers CSV générés :
#   AU_Overview_YYYYMMDD_HHmmss.csv      → toutes les AUs avec compteurs
#   AU_Empty_YYYYMMDD_HHmmss.csv         → AUs sans membres
#   AU_NoAdmin_YYYYMMDD_HHmmss.csv       → AUs sans admin scopé
#   AU_Detail_YYYYMMDD_HHmmss.csv        → vue détaillée membres + admins résolus
#
# Note sur les performances : ce script effectue des appels API par AU
# (Get-MgDirectoryAdministrativeUnitMember + Get-MgDirectoryAdministrativeUnitScopedRoleMember).
# Sur un tenant de dev avec peu d'AUs, le temps d'exécution est négligeable.
# Sur un tenant de production avec des centaines d'AUs, préférer un ciblage par AU.
#
# Module requis : Microsoft.Graph.Identity.DirectoryManagement, Microsoft.Graph.Users
# Connexion     : Connect-MgGraph
# ========================================================================================

# --- OUVERTURE — RESET DE SESSION TOTAL ---
# AdministrativeUnit.Read.All    : lire les AUs, leurs membres et leurs admins scopés
# RoleManagement.Read.Directory  : résoudre les rôles Entra des admins scopés
# User.Read.All                  : résoudre les PrincipalId (GUID) en DisplayName/UPN
#
# REX : sans RoleManagement.Read.Directory, Get-MgRoleManagementDirectoryRoleDefinition
# retourne une erreur 403 silencieuse — les noms de rôles restent des GUIDs illisibles
# dans le rapport. User.Read.All est requis pour la même raison sur les membres.
$Scopes = @(
    "AdministrativeUnit.Read.All",
    "RoleManagement.Read.Directory",
    "User.Read.All"
)

Disconnect-MgGraph -ErrorAction SilentlyContinue
Connect-MgGraph -Scopes $Scopes -NoWelcome

# ========================================================================================
# ÉTAPE 1 : Récupération de toutes les Administrative Units
# ========================================================================================
Write-Host "1. Récupération des Administrative Units..." -ForegroundColor Cyan

# Get-MgDirectoryAdministrativeUnit -All retourne toutes les AUs du tenant.
# -Property : on demande explicitement les champs nécessaires.
# MembershipType : "Assigned" (statique, membres ajoutés manuellement)
#                  "Dynamic"   (dynamique, membres calculés par règle — requiert P1/P2)
#                  $null       → AU créée avant l'introduction de MembershipType,
#                                se comporte comme "Assigned"
$AllAUs = Get-MgDirectoryAdministrativeUnit -All `
    -Property "Id, DisplayName, Description, MembershipType, MembershipRule,
               MembershipRuleProcessingState, Visibility" `
    -ErrorAction Stop

Write-Host "-> $($AllAUs.Count) Administrative Unit(s) trouvée(s).`n" -ForegroundColor Green

if ($AllAUs.Count -eq 0) {
    Write-Host "Aucune AU à analyser. Fin du script." -ForegroundColor Yellow
    Disconnect-MgGraph -ErrorAction SilentlyContinue
    return
}

# ========================================================================================
# ÉTAPE 2 : Résolution des membres et admins scopés par AU
# ========================================================================================
Write-Host "2. Résolution des membres et admins scopés (un appel API par AU)..." -ForegroundColor Cyan
Write-Host "   Cela peut prendre quelques secondes selon le nombre d'AUs..." -ForegroundColor Gray

$AURows    = @()   # Vue d'ensemble avec compteurs
$AUDetails = @()   # Vue détaillée membres + admins résolus

foreach ($AU in $AllAUs) {

    # --- Membres de l'AU ---
    # Get-MgDirectoryAdministrativeUnitMember retourne les objets membres (users, groups, devices).
    # On récupère les IDs puis on résout en DisplayName/UPN via Get-MgUser.
    # -ErrorAction SilentlyContinue : une AU peut retourner 0 membres sans erreur.
    $Members = Get-MgDirectoryAdministrativeUnitMember `
        -AdministrativeUnitId $AU.Id -All `
        -ErrorAction SilentlyContinue

    # Résolution des membres en objets lisibles.
    # On tente Get-MgUser — si le membre est un groupe ou un device, on retourne l'Id brut.
    # En production, on pourrait aussi tenter Get-MgGroup / Get-MgDevice pour résoudre
    # tous les types d'objets membres.
    $MembersResolved = @()
    foreach ($Member in $Members) {
        $UserObj = Get-MgUser -UserId $Member.Id -ErrorAction SilentlyContinue
        $MembersResolved += if ($UserObj) { $UserObj.DisplayName } else { $Member.Id }
    }

    # --- Admins scopés de l'AU ---
    # Get-MgDirectoryAdministrativeUnitScopedRoleMember retourne les assignations de rôles
    # scopées à cette AU — chaque entrée contient RoleId + RoleMemberInfo (PrincipalId).
    $ScopedAdmins = Get-MgDirectoryAdministrativeUnitScopedRoleMember `
        -AdministrativeUnitId $AU.Id -All `
        -ErrorAction SilentlyContinue

    # Résolution des admins scopés : nom du rôle + nom de l'utilisateur.
    $AdminsResolved = @()
    foreach ($Admin in $ScopedAdmins) {

        # Résolution du nom de rôle depuis son GUID.
        # Get-MgRoleManagementDirectoryRoleDefinition prend l'ID de la définition de rôle.
        # Sans cette résolution, le rapport n'affiche que des GUIDs illisibles.
        $RoleDef = Get-MgRoleManagementDirectoryRoleDefinition `
            -UnifiedRoleDefinitionId $Admin.RoleId -ErrorAction SilentlyContinue

        # RoleMemberInfo.Id = PrincipalId de l'admin scopé (GUID utilisateur).
        $AdminUser = Get-MgUser -UserId $Admin.RoleMemberInfo.Id -ErrorAction SilentlyContinue

        $AdminsResolved += [PSCustomObject]@{
            AdminDisplayName = if ($AdminUser) { $AdminUser.DisplayName } else { $Admin.RoleMemberInfo.Id }
            AdminUPN         = if ($AdminUser) { $AdminUser.UserPrincipalName } else { "Non résolu" }
            RoleName         = if ($RoleDef)   { $RoleDef.DisplayName }         else { $Admin.RoleId }
        }
    }

    # --- Construction de la ligne AU Overview ---
    $AURows += [PSCustomObject]@{
        DisplayName                  = $AU.DisplayName
        Description                  = $AU.Description
        # MembershipType null → comportement statique (AU ancienne génération)
        MembershipType               = if ($AU.MembershipType) { $AU.MembershipType } else { "Assigned (null)" }
        MembershipRule               = $AU.MembershipRule
        MembershipRuleProcessingState = $AU.MembershipRuleProcessingState
        # Visibility : "Public" (visible dans le portail) ou "HiddenMembership" (membres masqués)
        Visibility                   = $AU.Visibility
        NombreMembers                = $Members.Count
        NombreAdminsScopés           = $ScopedAdmins.Count
        # Flags de gouvernance — utilisés pour les segments "vide" et "sans admin"
        EstVide                      = ($Members.Count -eq 0)
        SansAdminScopé               = ($ScopedAdmins.Count -eq 0)
        Id                           = $AU.Id
    }

    # --- Construction des lignes AU Detail (une ligne par membre) ---
    # Si l'AU est vide, on insère quand même une ligne pour qu'elle apparaisse dans le CSV.
    if ($Members.Count -eq 0) {
        $AUDetails += [PSCustomObject]@{
            AU_DisplayName   = $AU.DisplayName
            AU_Id            = $AU.Id
            MemberType       = "Aucun membre"
            MemberName       = "-"
            MemberUPN        = "-"
            AdminName        = ($AdminsResolved | ForEach-Object { $_.AdminDisplayName }) -join " | "
            AdminUPN         = ($AdminsResolved | ForEach-Object { $_.AdminUPN })         -join " | "
            AdminRole        = ($AdminsResolved | ForEach-Object { $_.RoleName })         -join " | "
        }
    } else {
        foreach ($MemberName in $MembersResolved) {
            # On reconstruit l'UPN depuis le membre résolu si possible.
            # Pour les groupes/devices non résolus, on laisse "Non résolu".
            $MemberUser = $Members | Where-Object {
                $Obj = Get-MgUser -UserId $_.Id -ErrorAction SilentlyContinue
                $Obj -and $Obj.DisplayName -eq $MemberName
            } | Select-Object -First 1
            $MemberUPN = if ($MemberUser) {
                (Get-MgUser -UserId $MemberUser.Id -ErrorAction SilentlyContinue).UserPrincipalName
            } else { "Non résolu" }

            $AUDetails += [PSCustomObject]@{
                AU_DisplayName   = $AU.DisplayName
                AU_Id            = $AU.Id
                MemberType       = "User"
                MemberName       = $MemberName
                MemberUPN        = $MemberUPN
                # Admins scopés : concaténés sur la ligne de chaque membre pour lisibilité CSV.
                # En Excel, filtrer sur AU_DisplayName pour voir tous les membres d'une AU
                # et les admins associés sur chaque ligne.
                AdminName        = ($AdminsResolved | ForEach-Object { $_.AdminDisplayName }) -join " | "
                AdminUPN         = ($AdminsResolved | ForEach-Object { $_.AdminUPN })         -join " | "
                AdminRole        = ($AdminsResolved | ForEach-Object { $_.RoleName })         -join " | "
            }
        }
    }
}

Write-Host "-> Résolution terminée.`n" -ForegroundColor Green

# ========================================================================================
# ÉTAPE 3 : AUs vides
# ========================================================================================
Write-Host "3. Identification des AUs vides..." -ForegroundColor Cyan
Write-Host "`n=== AUs VIDES (AUCUN MEMBRE) ===" -ForegroundColor Red
Write-Host "Ces AUs n'ont aucun membre — délégations potentiellement fantômes :`n" -ForegroundColor Gray

$EmptyAUs = $AURows | Where-Object { $_.EstVide -eq $true }

if ($EmptyAUs.Count -gt 0) {
    $EmptyAUs |
        Select-Object DisplayName, Description, MembershipType,
                      NombreAdminsScopés, Id |
        Format-Table -AutoSize
} else {
    Write-Host "-> Aucune AU vide.`n" -ForegroundColor Green
}

# ========================================================================================
# ÉTAPE 4 : AUs sans admin scopé
# ========================================================================================
Write-Host "4. Identification des AUs sans admin scopé..." -ForegroundColor Cyan
Write-Host "`n=== AUs SANS ADMIN SCOPÉ ===" -ForegroundColor Yellow
Write-Host "Ces AUs ont des membres mais aucun rôle délégué — gouvernance non opérationnelle :`n" -ForegroundColor Gray

# Double condition : membres présents ET aucun admin scopé.
# Une AU vide sans admin scopé est déjà dans le segment précédent — on l'exclut ici
# pour éviter la redondance dans le rapport.
$NoAdminAUs = $AURows | Where-Object {
    $_.SansAdminScopé -eq $true -and $_.EstVide -eq $false
}

if ($NoAdminAUs.Count -gt 0) {
    $NoAdminAUs |
        Select-Object DisplayName, Description, MembershipType,
                      NombreMembers, Id |
        Format-Table -AutoSize
} else {
    Write-Host "-> Toutes les AUs peuplées ont au moins un admin scopé.`n" -ForegroundColor Green
}

# ========================================================================================
# ÉTAPE 5 : Vue d'ensemble complète
# ========================================================================================
Write-Host "5. Vue d'ensemble complète..." -ForegroundColor Cyan
Write-Host "`n=== VUE D'ENSEMBLE — TOUTES LES AUs ===" -ForegroundColor Cyan
Write-Host "Triées par nombre de membres décroissant :`n" -ForegroundColor Gray

$AURows |
    Sort-Object NombreMembers -Descending |
    Select-Object DisplayName, MembershipType, NombreMembers,
                  NombreAdminsScopés, EstVide, SansAdminScopé, Visibility |
    Format-Table -AutoSize

# ========================================================================================
# ÉTAPE 6 : Résumé chiffré
# ========================================================================================
Write-Host "`n=== RÉSUMÉ ===" -ForegroundColor Magenta

$DynamicAUs    = ($AURows | Where-Object { $_.MembershipType -eq "Dynamic" }).Count
$WellGoverned  = ($AURows | Where-Object { $_.EstVide -eq $false -and $_.SansAdminScopé -eq $false }).Count

[PSCustomObject]@{
    TotalAUs               = $AllAUs.Count
    AUsStatiques           = ($AURows | Where-Object { $_.MembershipType -ne "Dynamic" }).Count
    AUsDynamiques          = $DynamicAUs
    AUsVides               = $EmptyAUs.Count
    AUsSansAdminScopé      = $NoAdminAUs.Count
    AUsBienGouvernées      = $WellGoverned
    Scope                  = "AdministrativeUnit.Read.All + RoleManagement.Read.Directory + User.Read.All (lecture seule)"
} | Format-List

Write-Host "=== FIN DE L'AUDIT ADMINISTRATIVE UNITS ===" -ForegroundColor Green

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
# Colonnes exportées : DisplayName, Description, MembershipType, MembershipRule,
#                      MembershipRuleProcessingState, Visibility, NombreMembers,
#                      NombreAdminsScopés, EstVide, SansAdminScopé, Id
# Colonnes disponibles non exportées :
#   $AU.CreatedDateTime         : date de création de l'AU — utile pour détecter
#                                  les AUs anciennes jamais nettoyées
#   $AU.IsMemberManagementRestricted : si $true, seuls les admins scopés peuvent
#                                       gérer les membres (restreint les Global Admins)
$AURows |
    Sort-Object NombreMembers -Descending |
    Export-Csv -Path "$ExportPath\AU_Overview_$Timestamp.csv" `
               -Encoding UTF8 -NoTypeInformation
Write-Host "-> Vue d'ensemble : $($AURows.Count) ligne(s) — AU_Overview_$Timestamp.csv" -ForegroundColor Green

# --- CSV 2 : AUs vides ---
if ($EmptyAUs.Count -gt 0) {
    $EmptyAUs |
        Export-Csv -Path "$ExportPath\AU_Empty_$Timestamp.csv" `
                   -Encoding UTF8 -NoTypeInformation
    Write-Host "-> AUs vides : $($EmptyAUs.Count) ligne(s) — AU_Empty_$Timestamp.csv" -ForegroundColor Green
} else {
    Write-Host "-> AUs vides : aucune donnée à exporter." -ForegroundColor Yellow
}

# --- CSV 3 : AUs sans admin scopé ---
if ($NoAdminAUs.Count -gt 0) {
    $NoAdminAUs |
        Export-Csv -Path "$ExportPath\AU_NoAdmin_$Timestamp.csv" `
                   -Encoding UTF8 -NoTypeInformation
    Write-Host "-> AUs sans admin : $($NoAdminAUs.Count) ligne(s) — AU_NoAdmin_$Timestamp.csv" -ForegroundColor Green
} else {
    Write-Host "-> AUs sans admin : aucune donnée à exporter." -ForegroundColor Yellow
}

# --- CSV 4 : Vue détaillée membres + admins ---
# Une ligne par membre par AU — permet de filtrer dans Excel par AU_DisplayName
# pour voir tous les membres d'une AU et ses admins scopés sur chaque ligne.
# Colonnes exportées : AU_DisplayName, AU_Id, MemberType, MemberName, MemberUPN,
#                      AdminName, AdminUPN, AdminRole
# Colonnes disponibles non exportées :
#   Rôle de l'admin sur d'autres AUs    : hors périmètre de ce script (exo 8f pour l'audit RBAC global)
#   Dernière connexion du membre        : disponible via SignInActivity (exo 1l pour la logique)
$AUDetails |
    Export-Csv -Path "$ExportPath\AU_Detail_$Timestamp.csv" `
               -Encoding UTF8 -NoTypeInformation
Write-Host "-> Détail membres : $($AUDetails.Count) ligne(s) — AU_Detail_$Timestamp.csv" -ForegroundColor Green

Write-Host "-> Export terminé dans : $ExportPath`n" -ForegroundColor Green

# ========================================================================================
# NETTOYAGE MÉMOIRE
# ========================================================================================
Remove-Variable Scopes, AllAUs, AU, Members, MembersResolved, Member, MemberName,
                MemberUser, MemberUPN, UserObj, ScopedAdmins, AdminsResolved, Admin,
                RoleDef, AdminUser, AURows, AUDetails, EmptyAUs, NoAdminAUs,
                DynamicAUs, WellGoverned, ExportPath, Timestamp `
                -ErrorAction SilentlyContinue

# ========================================================================================
# FERMETURE — RESET DE SESSION TOTAL
# ========================================================================================
Disconnect-MgGraph -ErrorAction SilentlyContinue
Write-Host "Session MgGraph fermée proprement." -ForegroundColor Magenta
