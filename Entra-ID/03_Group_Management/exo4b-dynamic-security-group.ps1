# ========================================================================================
# Exercice 4b : Création d'un Security Group dynamique avec règle de membership
# ========================================================================================

# --- ÉTAPE 1 : Connexion à Microsoft Graph ---
# Group.ReadWrite.All : créer/modifier des groupes
# User.Read.All : lire les profils utilisateurs pour les règles dynamiques
$Scopes = @(
    "Group.ReadWrite.All",
    "User.Read.All"
)
Connect-MgGraph -Scopes $Scopes

# --- ÉTAPE 2 : Définition des variables du Lab ---
$GroupName        = "MagicOps-Dynamic-Team"
$GroupDescription = "Security Group dynamique — peuplé automatiquement par département."
$OwnerUPN         = "geralt@0n4mg.onmicrosoft.com"
$TargetDepartment = "MagicOps"

# Règle de membership — syntaxe Entra ID
# Les backticks (`") échappent les guillemets doubles dans la chaîne PowerShell
# Sans eux, PowerShell interpréterait les guillemets comme fin de chaîne
$MembershipRule = "(user.department -eq `"$TargetDepartment`")"

# --- ÉTAPE 3 : Création du Security Group dynamique ---
# La combinaison de ces paramètres définit le TYPE de groupe créé :
#
#   TYPE                     | GroupTypes              | SecurityEnabled | MailEnabled
#   -------------------------|-------------------------|-----------------|------------
#   Security Group statique  | @() — vide              | $true           | $false
#   Security Group dynamique | @("DynamicMembership")  | $true           | $false  ← ICI
#   M365 Group statique      | @("Unified")            | $false          | $true
#   M365 Group dynamique     | @("Unified",            | $false          | $true
#                            |  "DynamicMembership")   |                 |
#
# Différence clé vs statique (4a) :
# - GroupTypes contient "DynamicMembership" — active le moteur de règle Entra
# - Pas de CSV, pas de membres manuels — Entra peuple automatiquement selon la règle
# - MembershipRuleProcessingState "On" démarre le moteur (vs "Paused" = arrêté)
$GroupParams = @{
    DisplayName                   = $GroupName
    Description                   = $GroupDescription
    # MailNickname obligatoire même sans mail — contrainte API Graph
    MailNickname                  = "magicops-dynamic-team"
    GroupTypes                    = @("DynamicMembership")
    SecurityEnabled               = $true
    MailEnabled                   = $false
    # La règle qui définit qui entre automatiquement dans le groupe
    MembershipRule                = $MembershipRule
    # "On" = moteur actif / "Paused" = moteur arrêté — toujours "On" à la création
    MembershipRuleProcessingState = "On"
}

Write-Host "1. Création du Security Group dynamique '$GroupName'..." -ForegroundColor Cyan
Write-Host "   Règle appliquée : $MembershipRule" -ForegroundColor Gray

$NewGroup = New-MgGroup @GroupParams

# Guard clause — si la création échoue, inutile de continuer
if (-not $NewGroup) { Write-Error "Échec de la création du groupe." ; return }

Write-Host "-> Succès : Groupe créé avec l'ID : $($NewGroup.Id)`n" -ForegroundColor Green

# --- ÉTAPE 4 : Assignation de l'owner ---
# L'owner peut gérer le groupe sans être Global Admin
# Note : sur un groupe dynamique, l'owner ne peut pas modifier les membres manuellement
# — c'est Entra qui gère le membership via la règle
Write-Host "2. Assignation de l'owner $OwnerUPN..." -ForegroundColor Cyan

try {
    $OwnerObject = Get-MgUser -UserId $OwnerUPN -ErrorAction Stop

    # Syntaxe OData — liaison par référence imposée par l'API Graph
    $OwnerParams = @{
        "@odata.id" = "https://graph.microsoft.com/v1.0/users/$($OwnerObject.Id)"
    }

    New-MgGroupOwnerByRef -GroupId $NewGroup.Id -BodyParameter $OwnerParams -ErrorAction Stop
    Write-Host "-> Succès : $OwnerUPN est owner du groupe.`n" -ForegroundColor Green
}
catch {
    Write-Host "-> Échec assignation owner : $_" -ForegroundColor Red
}

# --- ÉTAPE 5 : Vérification du moteur de règle ---
# On relit depuis Entra pour confirmer que le moteur est bien actif
# Même logique que le 3b — l'objet local ne suffit pas, on vérifie la source de vérité
Write-Host "3. Vérification du moteur de règle..." -ForegroundColor Cyan

# Attente réplication Azure avant lecture
Start-Sleep -Seconds 2

# On demande uniquement les propriétés utiles
Get-MgGroup -GroupId $NewGroup.Id `
    -Property "id,displayName,membershipRule,membershipRuleProcessingState" |
    Select-Object Id, DisplayName, MembershipRule, MembershipRuleProcessingState

# Valeur attendue : "On" = moteur actif / "Paused" ou vide = problème
# Les membres apparaissent pas immédiatement — Entra traite la règle en arrière-plan
# Délai possible jusqu'à 24h — pas un bug, c'est Azure
Write-Host "-> Info : Membres peuplés automatiquement par Entra (délai jusqu'à 24h).`n" -ForegroundColor Yellow

# --- ÉTAPE 6 : Nettoyage ---
Remove-Variable Scopes, GroupName, GroupDescription, OwnerUPN, TargetDepartment, `
                MembershipRule, GroupParams, NewGroup, OwnerObject, OwnerParams `
                -ErrorAction SilentlyContinue

Write-Host "`nMémoire locale nettoyée. Session Microsoft Graph toujours active." -ForegroundColor Magenta
