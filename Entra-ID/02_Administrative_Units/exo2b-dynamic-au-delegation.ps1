# ========================================================================================
# Exercice 2b : Entra ID — Création d'une AU dynamique avec règle d'appartenance
# ========================================================================================
# Concept : Une AU dynamique peuple ses membres automatiquement selon une règle
# basée sur les attributs Entra (ex : Department, Country, JobTitle).
# Contrairement à l'AU statique (exercice 2a), aucun ajout manuel de membre n'est requis.
# Entra évalue la règle en arrière-plan et maintient la liste à jour en continu.
#
# Ce que fait ce script :
#   1. Reset total de session
#   2. Recherche un nom d'AU disponible (auto-incrément)
#   3. Crée l'AU dynamique via Invoke-MgGraphRequest (API HTTP directe)
#   4. Vérifie l'activation du moteur de règle
#   5. Assigne un administrateur scopé (User Administrator) sur l'AU
#   6. Ferme proprement toutes les sessions
#
# AU statique vs dynamique :
#   Statique  : membres ajoutés explicitement — contrôle total, maintenance manuelle.
#   Dynamique : membres calculés via règle d'attribut — zéro maintenance, délai de propagation.
#               Nécessite une licence Entra ID P1 minimum.
#
# DÉCOUVERTE TECHNIQUE : New-MgDirectoryAdministrativeUnit (cmdlet SDK PowerShell Graph)
# ne supporte pas les paramètres dynamiques (membershipType, membershipRule,
# membershipRuleProcessingState). Le cmdlet ne couvre que la création d'AU statiques.
# Solution : Invoke-MgGraphRequest — appel HTTP direct à l'API Graph, sans passer
# par le formulaire pré-rempli du cmdlet. On contrôle le body JSON manuellement.
#
# Département cible : "MagicOps" — tenant de dev (0n4mg.onmicrosoft.com)
#
# Module requis : Microsoft.Graph.Identity.DirectoryManagement, Microsoft.Graph.Users
# Connexion     : Connect-MgGraph
# ========================================================================================

# --- OUVERTURE — RESET DE SESSION TOTAL ---
# REX : Directory.ReadWrite.All est un scope très élevé (lecture/écriture sur tout
# le répertoire). Si une session précédente tourne sans ce scope, Invoke-MgGraphRequest
# retourne un 403 encapsulé dans une exception générique — difficile à diagnostiquer
# sans partir d'une session propre.
$Scopes = @(
    "AdministrativeUnit.ReadWrite.All",   # Créer/modifier/supprimer des AUs
    "RoleManagement.ReadWrite.Directory", # Assigner des rôles scopés sur l'AU
    "Directory.ReadWrite.All",            # Requis pour Invoke-MgGraphRequest sur les AUs dynamiques
    "User.Read.All"                       # Résoudre les UPNs en ObjectIds
)

Disconnect-MgGraph -ErrorAction SilentlyContinue
Connect-MgGraph -Scopes $Scopes

# ========================================================================================
# ÉTAPE 1 : Définition des variables
# ========================================================================================
Write-Host "1. Définition des variables..." -ForegroundColor Cyan

$AuBaseName       = "MagicOps-Command-Center"
$AuDescription    = "AU dynamique : Gestion automatique des ressources du département MagicOps."
$TargetDepartment = "MagicOps"
$AdminUPN         = "geralt@0n4mg.onmicrosoft.com"

# Règle d'appartenance dynamique — syntaxe identique aux groupes dynamiques Entra.
# Les backticks échappent les guillemets internes dans la chaîne PowerShell.
# Entra évalue : si user.department == "MagicOps" → l'utilisateur entre dans l'AU.
# Si l'attribut change ultérieurement → l'utilisateur en sort automatiquement.
$MembershipRule = "(user.department -eq `"$TargetDepartment`")"

# ID de template du rôle "User Administrator" — GUID stable, identique sur tous les tenants.
$RoleTemplateId = "fe930be7-5e62-47db-91af-98c3a49a38b1"

Write-Host "-> AU cible  : $AuBaseName" -ForegroundColor Green
Write-Host "-> Règle     : $MembershipRule" -ForegroundColor Green
Write-Host "-> Admin AU  : $AdminUPN`n" -ForegroundColor Green

# ========================================================================================
# ÉTAPE 2 : Recherche d'un nom d'AU disponible (auto-incrément)
# ========================================================================================
Write-Host "2. Recherche d'un nom d'AU disponible..." -ForegroundColor Cyan

$AuName  = $AuBaseName
$Counter = 2
while (Get-MgDirectoryAdministrativeUnit -Filter "DisplayName eq '$AuName'" -ErrorAction SilentlyContinue) {
    Write-Host "   '$AuName' déjà pris — test avec suffixe -v$Counter..." -ForegroundColor Yellow
    $AuName = "$AuBaseName-v$Counter"
    $Counter++
}
Write-Host "-> Nom retenu pour l'AU : '$AuName'`n" -ForegroundColor Green

# ========================================================================================
# ÉTAPE 3 : Création de l'AU dynamique via appel HTTP direct
# ========================================================================================
Write-Host "3. Création de l'AU dynamique '$AuName'..." -ForegroundColor Cyan

# Invoke-MgGraphRequest : contourne les limites du cmdlet SDK PowerShell et parle
# directement à l'API Graph en HTTP. Indispensable ici car New-MgDirectoryAdministrativeUnit
# ne supporte pas les propriétés dynamiques.
#
# -Method POST  : verbe HTTP pour CRÉER une ressource
#                 (GET=lire, PATCH=modifier, DELETE=supprimer)
# -Uri          : endpoint Graph ciblé — /directory/administrativeUnits
# -Body         : payload JSON envoyé à Microsoft :
#   displayName                   = nom de l'AU
#   description                   = description
#   membershipType                = "Dynamic" (vs "Assigned" pour une AU statique)
#   membershipRule                = règle Entra évaluée sur les attributs utilisateur
#   membershipRuleProcessingState = "On" pour activer immédiatement le moteur de règle
#
# Ref : learn.microsoft.com/en-us/graph/api/directory-post-administrativeunits
try {
    $NewAU = Invoke-MgGraphRequest `
        -Method      POST `
        -Uri         "https://graph.microsoft.com/v1.0/directory/administrativeUnits" `
        -Body        @{
            displayName                   = $AuName
            description                   = $AuDescription
            membershipType                = "Dynamic"
            membershipRule                = $MembershipRule
            membershipRuleProcessingState = "On"
        } `
        -ContentType "application/json" `
        -ErrorAction Stop

    Write-Host "-> AU dynamique créée : $($NewAU.displayName) [ID : $($NewAU.id)]`n" -ForegroundColor Green
}
catch {
    Write-Host "-> Échec critique de création : $_" -ForegroundColor Red
    Disconnect-MgGraph -ErrorAction SilentlyContinue
    return
}

# ========================================================================================
# ÉTAPE 4 : Vérification du moteur de règle
# ========================================================================================
Write-Host "4. Vérification du moteur de règle..." -ForegroundColor Cyan

# On relit l'AU depuis Graph pour confirmer que membershipRuleProcessingState est bien "On".
# Invoke-MgGraphRequest en GET retourne un hashtable PowerShell — accès par clé .nomPropriété.
$AuStatus = Invoke-MgGraphRequest `
    -Method GET `
    -Uri    "https://graph.microsoft.com/v1.0/directory/administrativeUnits/$($NewAU.id)"

# Valeurs possibles de membershipRuleProcessingState :
#   "On"     = moteur actif, Entra évalue la règle en arrière-plan
#   "Paused" = moteur suspendu (ex : quota dépassé, erreur de syntaxe dans la règle)
#   vide/$null = problème de création — la règle n'a pas été enregistrée
Write-Host "-> Statut du moteur : $($AuStatus.membershipRuleProcessingState)" -ForegroundColor Green
Write-Host "-> Info : les membres seront peuplés automatiquement par Entra." -ForegroundColor Yellow
Write-Host "   Délai de propagation : quelques minutes à 24h selon la taille du tenant.`n" -ForegroundColor Yellow

# ========================================================================================
# ÉTAPE 5 : Assignation de l'administrateur scopé
# ========================================================================================
Write-Host "5. Assignation de l'administrateur scopé ($AdminUPN)..." -ForegroundColor Cyan

try {
    $AdminObject = Get-MgUser -UserId $AdminUPN -ErrorAction Stop
    $ActiveRole  = Get-MgDirectoryRole | Where-Object { $_.RoleTemplateId -eq $RoleTemplateId }

    if (-not $ActiveRole) {
        Write-Host "-> Erreur : rôle User Administrator non instancié sur ce tenant." -ForegroundColor Red
        Write-Host "   Activer via : Enable-MgDirectoryRole -RoleTemplateId '$RoleTemplateId'" -ForegroundColor Yellow
        Disconnect-MgGraph -ErrorAction SilentlyContinue
        return
    }

    # REX : l'AU est créée côté backend mais peut ne pas être immédiatement disponible
    # pour les opérations RBAC. Un appel immédiat à New-MgDirectoryAdministrativeUnitScopedRoleMember
    # retourne une erreur 404 (AU introuvable) même si la création a réussi à l'étape 3.
    # 30 secondes couvrent la latence de propagation Graph.
    Write-Host "   Attente de propagation Graph (30s)..." -ForegroundColor Yellow
    Start-Sleep -Seconds 30

    $ScopedRoleParams = @{
        RoleId         = $ActiveRole.Id
        RoleMemberInfo = @{ Id = $AdminObject.Id }
    }

    New-MgDirectoryAdministrativeUnitScopedRoleMember `
        -AdministrativeUnitId $NewAU.id `
        -BodyParameter        $ScopedRoleParams `
        -ErrorAction          Stop | Out-Null

    Write-Host "-> $AdminUPN est désormais User Administrator scopé sur '$AuName'.`n" -ForegroundColor Green
}
catch {
    Write-Host "-> Échec de l'assignation du rôle scopé : $_" -ForegroundColor Red
}

# ========================================================================================
# ÉTAPE 6 : Résumé
# ========================================================================================
Write-Host "=== RÉSUMÉ ===" -ForegroundColor Magenta
[PSCustomObject]@{
    AUCréée           = $AuName
    AUID              = $NewAU.id
    TypeAU            = "Dynamique (membres calculés par règle Entra)"
    Règle             = $MembershipRule
    MoteurRègle       = $AuStatus.membershipRuleProcessingState
    AdminScopé        = $AdminUPN
    RôleScopé         = "User Administrator (fe930be7...)"
    PropagationMembres = "Automatique — délai jusqu'à 24h"
} | Format-List

# ========================================================================================
# NETTOYAGE MÉMOIRE
# ========================================================================================
Remove-Variable Scopes, AuBaseName, AuName, AuDescription, TargetDepartment,
                MembershipRule, AdminUPN, RoleTemplateId, Counter,
                NewAU, AuStatus, AdminObject, ActiveRole, ScopedRoleParams `
                -ErrorAction SilentlyContinue

# ========================================================================================
# FERMETURE — RESET DE SESSION TOTAL
# ========================================================================================
Disconnect-MgGraph -ErrorAction SilentlyContinue
Write-Host "Session MgGraph fermée proprement." -ForegroundColor Magenta
