# ========================================================================================
# Exercice 2a : Entra ID — Création d'une AU statique, ajout de membres et délégation RBAC
# ========================================================================================
# Concept : Les Administrative Units (AU) permettent de segmenter le tenant en périmètres
# d'administration délégués. Un admin scopé sur une AU ne peut gérer QUE les utilisateurs
# membres de cette AU — pas l'ensemble du tenant.
#
# Ce que fait ce script :
#   1. Reset total de session
#   2. Recherche un nom d'AU disponible (auto-incrément)
#   3. Crée l'AU statique
#   4. Injecte les membres depuis un CSV (ou liste manuelle en variante commentée)
#   5. Assigne un administrateur scopé (User Administrator) sur l'AU
#   6. Ferme proprement toutes les sessions
#
# AU statique vs dynamique :
#   Statique  : membres ajoutés manuellement ou via script — contrôle explicite.
#   Dynamique : membres calculés automatiquement selon une règle (ex: Department -eq "SecOps").
#               Nécessite une licence Entra ID P1 minimum. Abordé en exercice 2b.
#
# Personnages test : "Kaer-Morhen-Staff" — forteresse Witcher, tenant de dev (0n4mg.onmicrosoft.com)
#
# Module requis : Microsoft.Graph.Identity.DirectoryManagement, Microsoft.Graph.Users
# Connexion     : Connect-MgGraph
# ========================================================================================

# --- OUVERTURE — RESET DE SESSION TOTAL ---
# REX : AdministrativeUnit.ReadWrite.All et RoleManagement.ReadWrite.Directory sont des
# scopes élevés. Si une session précédente tourne avec des scopes inférieurs, les appels
# de création d'AU ou d'assignation de rôle échouent avec 403 sans message explicite.
# On repart d'une session propre sans exception.
$Scopes = @(
    "AdministrativeUnit.ReadWrite.All",   # Créer/modifier/supprimer des AUs et leurs membres
    "RoleManagement.ReadWrite.Directory", # Assigner des rôles scopés sur l'AU
    "User.Read.All"                       # Résoudre les UPNs en ObjectIds
)

Disconnect-MgGraph -ErrorAction SilentlyContinue
Connect-MgGraph -Scopes $Scopes

# ========================================================================================
# ÉTAPE 1 : Définition des variables
# ========================================================================================
Write-Host "1. Définition des variables..." -ForegroundColor Cyan

$AuBaseName    = "Kaer-Morhen-Staff"
$AuDescription = "Périmètre de gestion statique pour le staff et les alliés de la forteresse."
$AdminUPN      = "geralt@0n4mg.onmicrosoft.com"

# ID de template du rôle "User Administrator" — GUID stable, identique sur tous les tenants.
# RoleTemplateId vs RoleId :
#   RoleTemplateId = identifiant universel du rôle (même valeur partout).
#   RoleId         = identifiant de l'instance activée du rôle sur CE tenant.
# Get-MgDirectoryRole retourne les instances activées — on filtre par RoleTemplateId
# pour obtenir le RoleId local à utiliser dans l'assignation scopée.
$RoleTemplateId = "fe930be7-5e62-47db-91af-98c3a49a38b1"

Write-Host "-> AU cible  : $AuBaseName" -ForegroundColor Green
Write-Host "-> Admin AU  : $AdminUPN`n" -ForegroundColor Green

# ========================================================================================
# ÉTAPE 2 : Recherche d'un nom d'AU disponible (auto-incrément)
# ========================================================================================
Write-Host "2. Recherche d'un nom d'AU disponible..." -ForegroundColor Cyan

# DÉCOUVERTE TECHNIQUE : contrairement aux objets DLP ou aux groupes, la cmdlet
# Get-MgDirectoryAdministrativeUnit ne supporte pas -Identity directement sur un DisplayName.
# On filtre via -Filter sur le DisplayName pour détecter l'existence.
$AuName = $AuBaseName
$Counter = 2
while (Get-MgDirectoryAdministrativeUnit -Filter "DisplayName eq '$AuName'" -ErrorAction SilentlyContinue) {
    Write-Host "   '$AuName' déjà pris — test avec suffixe -v$Counter..." -ForegroundColor Yellow
    $AuName = "$AuBaseName-v$Counter"
    $Counter++
}
Write-Host "-> Nom retenu pour l'AU : '$AuName'`n" -ForegroundColor Green

# ========================================================================================
# ÉTAPE 3 : Définition de la source des membres
# ========================================================================================
Write-Host "3. Chargement des membres..." -ForegroundColor Cyan

# ----------------------------------------------------------------------------------------
# CHOIX DE LA SOURCE — décommenter l'option souhaitée
# ----------------------------------------------------------------------------------------
# OPTION A : Liste manuelle (cas par cas)
# Utile pour des ajouts ponctuels sans fichier CSV.
# $Bulkmembres = @(
#     "triss@0n4mg.onmicrosoft.com",
#     "yennefer@0n4mg.onmicrosoft.com"
# )

# OPTION B : Fichier CSV (actif)
# La colonne "UserPrincipalName" du CSV est extraite directement.
# .UserPrincipalName sur le résultat d'Import-Csv extrait uniquement les valeurs
# de cette colonne — pas d'objet PSCustomObject complet dans la boucle.
#
# EN LABO / Local :
$PathCSV = "D:\Documents\ScriptsPowerShell\membres.csv"
# EN PRODUCTION :
# $PathCSV = "$PSScriptRoot\membres.csv"

if (-not (Test-Path $PathCSV)) {
    Write-Host "-> Erreur : fichier CSV introuvable à '$PathCSV'." -ForegroundColor Red
    Disconnect-MgGraph -ErrorAction SilentlyContinue
    return
}
$Bulkmembres = (Import-Csv -Path $PathCSV).UserPrincipalName
# ----------------------------------------------------------------------------------------

Write-Host "-> $($Bulkmembres.Count) membre(s) chargé(s).`n" -ForegroundColor Green

# ========================================================================================
# ÉTAPE 4 : Création de l'Administrative Unit
# ========================================================================================
Write-Host "4. Création de l'AU '$AuName'..." -ForegroundColor Cyan

$AuParams = @{
    DisplayName = $AuName
    Description = $AuDescription
}

try {
    $NewAU = New-MgDirectoryAdministrativeUnit -BodyParameter $AuParams -ErrorAction Stop
    Write-Host "-> AU créée : $($NewAU.DisplayName) [ID : $($NewAU.Id)]`n" -ForegroundColor Green
}
catch {
    Write-Host "-> Échec de la création de l'AU : $_" -ForegroundColor Red
    Disconnect-MgGraph -ErrorAction SilentlyContinue
    return
}

# ========================================================================================
# ÉTAPE 5 : Injection des membres dans l'AU
# ========================================================================================
Write-Host "5. Injection des membres dans l'AU..." -ForegroundColor Cyan
Write-Host "-------------------------------------------------------------------" -ForegroundColor Gray

foreach ($UserUPN in $Bulkmembres) {
    try {
        # Résolution de l'UPN en ObjectId — l'API Graph n'accepte que des IDs dans
        # les références OData, pas les UPNs directement.
        $UserObject = Get-MgUser -UserId $UserUPN -ErrorAction Stop

        # Liaison via référence OData (@odata.id).
        # C'est le mécanisme Graph pour créer des relations entre objets :
        # on passe l'URL complète de la ressource à lier, pas juste son ID.
        # New-MgDirectoryAdministrativeUnitMemberByRef attend exactement ce format.
        $MemberParams = @{
            "@odata.id" = "https://graph.microsoft.com/v1.0/users/$($UserObject.Id)"
        }

        New-MgDirectoryAdministrativeUnitMemberByRef `
            -AdministrativeUnitId $NewAU.Id `
            -BodyParameter $MemberParams `
            -ErrorAction Stop | Out-Null

        Write-Host "[SUCCESS] $UserUPN ajouté à l'AU." -ForegroundColor Green
    }
    catch {
        Write-Host "[ERROR]   $UserUPN — $_" -ForegroundColor Red
    }
}

Write-Host "-------------------------------------------------------------------" -ForegroundColor Gray
Write-Host "-> Injection terminée.`n" -ForegroundColor Green

# ========================================================================================
# ÉTAPE 6 : Assignation de l'administrateur scopé (RBAC ciblé sur l'AU)
# ========================================================================================
Write-Host "6. Assignation de l'administrateur scopé ($AdminUPN)..." -ForegroundColor Cyan

try {
    $AdminObject = Get-MgUser -UserId $AdminUPN -ErrorAction Stop

    # Get-MgDirectoryRole retourne uniquement les rôles déjà activés (instanciés) sur le tenant.
    # Un rôle non encore utilisé n'apparaît pas ici — il faut l'activer via Enable-MgDirectoryRole
    # avant de pouvoir l'assigner. Sur un tenant E5 dev, User Administrator est généralement
    # déjà instancié dès la première assignation manuelle via le portail.
    $ActiveRole = Get-MgDirectoryRole | Where-Object { $_.RoleTemplateId -eq $RoleTemplateId }

    if (-not $ActiveRole) {
        Write-Host "-> Erreur : rôle User Administrator non instancié sur ce tenant." -ForegroundColor Red
        Write-Host "   Activer via : Enable-MgDirectoryRole -RoleTemplateId '$RoleTemplateId'" -ForegroundColor Yellow
        Disconnect-MgGraph -ErrorAction SilentlyContinue
        return
    }

    # Assignation scopée : le rôle est limité au périmètre de l'AU ($NewAU.Id).
    # Hors de ce périmètre, $AdminUPN n'a aucun droit administratif sur les autres users.
    $ScopedRoleParams = @{
        RoleId = $ActiveRole.Id
        RoleMemberInfo = @{
            Id = $AdminObject.Id
        }
    }

    New-MgDirectoryAdministrativeUnitScopedRoleMember `
        -AdministrativeUnitId $NewAU.Id `
        -BodyParameter $ScopedRoleParams `
        -ErrorAction Stop | Out-Null

    Write-Host "-> $AdminUPN est désormais User Administrator scopé sur '$AuName'.`n" -ForegroundColor Green
}
catch {
    Write-Host "-> Échec de l'assignation du rôle scopé : $_" -ForegroundColor Red
}

# ========================================================================================
# ÉTAPE 7 : Résumé
# ========================================================================================
Write-Host "=== RÉSUMÉ ===" -ForegroundColor Magenta
[PSCustomObject]@{
    AUCréée          = $AuName
    AUID             = $NewAU.Id
    Description      = $AuDescription
    TypeAU           = "Statique (membres ajoutés explicitement)"
    MembresInjectés  = $Bulkmembres.Count
    AdminScopé       = $AdminUPN
    RôleScopé        = "User Administrator (fe930be7...)"
} | Format-List

# ========================================================================================
# NETTOYAGE MÉMOIRE
# ========================================================================================
Remove-Variable Scopes, AuBaseName, AuName, AuDescription, AdminUPN, RoleTemplateId,
                Counter, PathCSV, Bulkmembres, AuParams, NewAU,
                UserUPN, UserObject, MemberParams, AdminObject,
                ActiveRole, ScopedRoleParams `
                -ErrorAction SilentlyContinue

# ========================================================================================
# FERMETURE — RESET DE SESSION TOTAL
# ========================================================================================
Disconnect-MgGraph -ErrorAction SilentlyContinue
Write-Host "Session MgGraph fermée proprement." -ForegroundColor Magenta
