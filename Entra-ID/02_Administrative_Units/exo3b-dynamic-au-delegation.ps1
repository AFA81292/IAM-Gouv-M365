# ========================================================================================
# Exercice 3b : Création d'une AU Dynamique avec règles basées sur les attributs (MagicOps)
# ========================================================================================

# --- ÉTAPE 1 : Connexion à Microsoft Graph (Permissions verticales) ---
$Scopes = @(
    "AdministrativeUnit.ReadWrite.All",
    "RoleManagement.ReadWrite.Directory",
    "Directory.ReadWrite.All",
    "User.Read.All"
)
Connect-MgGraph -Scopes $Scopes

# --- ÉTAPE 2 : Définition des variables du Lab ---
$AuName = "MagicOps-Command-Center"
$AuDescription = "AU dynamique : Gestion automatique des ressources du département MagicOps."

$TargetDepartment = "MagicOps"
$MembershipRule = "(user.department -eq `"$TargetDepartment`")"
$AdminUPN = "geralt@0n4mg.onmicrosoft.com"
$RoleTemplateId = "fe930be7-5e62-47db-91af-98c3a49a38b1"

# --- ÉTAPE 3 : Création de l'Administrative Unit Dynamique ---
# New-MgDirectoryAdministrativeUnit ne supporte pas les paramètres dynamiques - Merci LLM =)
# (membershipType, membershipRule) — le cmdlet PowerShell n'a pas ces "cases" dans son formulaire.
#
# Solution : Invoke-MgGraphRequest — on bypasse le cmdlet et on parle directement
# à l'API Graph en HTTP, comme envoyer une lettre au bureau au lieu d'utiliser
# un formulaire pré-rempli. On contrôle tout soi-même :
#
#   -Method POST  : verbe HTTP pour CRÉER une ressource
#                   (GET=lire, PATCH=modifier, DELETE=supprimer)
#   -Uri          : l'adresse du endpoint Graph ciblé
#                   (/directory/administrativeUnits = le "bureau" des AUs chez Microsoft)
#   -Body         : les paramètres qu'on envoie à Microsoft :
#                     displayName                   = nom de l'AU
#                     description                   = description
#                     membershipType                = "Dynamic" (vs "Assigned" pour statique)
#                     membershipRule                = la règle Entra (ex: user.department -eq "X")
#                     membershipRuleProcessingState = "On" pour activer le moteur de règle
#
# Ref : learn.microsoft.com/en-us/graph/api/directory-post-administrativeunits

Write-Host "1. Création de l'Administrative Unit Dynamique '$AuName'..." -ForegroundColor Cyan
Write-Host "   Règle appliquée : $MembershipRule" -ForegroundColor Gray

try {
    $NewAU = Invoke-MgGraphRequest -Method POST `
        -Uri "https://graph.microsoft.com/v1.0/directory/administrativeUnits" `
        -Body @{
            displayName                   = $AuName
            description                   = $AuDescription
            membershipType                = "Dynamic"
            membershipRule                = $MembershipRule
            membershipRuleProcessingState = "On"
        } `
        -ContentType "application/json" `
        -ErrorAction Stop

    Write-Host "-> Succès : AU dynamique créée avec l'ID : $($NewAU.id)`n" -ForegroundColor Green
}
catch {
    Write-Host "-> Échec critique de création : $_" -ForegroundColor Red
    break
}


# --- ÉTAPE 4 : Confirmation du moteur de règle ---
Write-Host "2. Vérification du moteur de règle..." -ForegroundColor Cyan

# GET = on lit ce qu'Azure a enregistré, sans modifier quoi que ce soit
# L'ID de l'AU créée à l'étape 3 est injecté dynamiquement dans l'Uri
$AuStatus = Invoke-MgGraphRequest -Method GET `
    -Uri "https://graph.microsoft.com/v1.0/directory/administrativeUnits/$($NewAU.id)"

# On affiche uniquement membershipRuleProcessingState
# Valeur attendue : "On" = moteur actif / "Paused" ou vide = problème
Write-Host "-> Statut du moteur : $($AuStatus.membershipRuleProcessingState)" -ForegroundColor Green

# "On" ne veut pas dire que les membres sont déjà là — Entra traite la règle en arrière-plan
Write-Host "-> Info : Les membres seront peuplés automatiquement par Entra (délai jusqu'à 24h).`n" -ForegroundColor Yellow

# --- ÉTAPE 5 : Assignation de l'admin scopé ---

Write-Host "3. Assignation de l'admin $AdminUPN..." -ForegroundColor Cyan

try {
    $AdminObject = Get-MgUser -UserId $AdminUPN -ErrorAction Stop
    $ActiveRole = Get-MgDirectoryRole | Where-Object {$_.RoleTemplateId -eq $RoleTemplateId}

    if (-not $ActiveRole) { Write-Error "Rôle introuvable dans le tenant." ; return }

    $ScopedRoleParams = @{
        RoleId         = $ActiveRole.Id
        RoleMemberInfo = @{ Id = $AdminObject.Id }
    }
    
# Délai de propagation Azure/Graph :
# l'AU peut être créée côté backend mais pas encore disponible
# immédiatement pour les opérations RBAC suivantes.

    Start-Sleep -Seconds 3
    New-MgDirectoryAdministrativeUnitScopedRoleMember -AdministrativeUnitId $NewAU.id -BodyParameter $ScopedRoleParams -ErrorAction Stop | Out-Null
    Write-Host "-> Succès : $AdminUPN est désormais admin de '$AuName'." -ForegroundColor Green
}
catch {
    Write-Host "-> Échec de l'assignation : $_" -ForegroundColor Red
}

# --- ÉTAPE 6 : Nettoyage de la mémoire locale ---
Remove-Variable Scopes, AuName, AuDescription, TargetDepartment, MembershipRule, AdminUPN, `
                RoleTemplateId, NewAU, AuStatus, AdminObject, ActiveRole, ScopedRoleParams `
                -ErrorAction SilentlyContinue

Write-Host "`nMémoire locale nettoyée. Session Microsoft Graph toujours active." -ForegroundColor Magenta
