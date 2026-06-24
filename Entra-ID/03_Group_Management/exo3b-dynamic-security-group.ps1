# ========================================================================================
# Exercice 4b : Entra ID — Création d'un Security Group dynamique avec règle de membership
# ========================================================================================
# Concept : Un Security Group dynamique peuple ses membres automatiquement via une règle
# basée sur les attributs Entra (Department, Country, JobTitle, etc.).
# Entra évalue la règle en arrière-plan — aucun ajout manuel de membre possible ou requis.
#
# Ce que fait ce script :
#   1. Reset total de session
#   2. Recherche un nom de groupe disponible (auto-incrément)
#   3. Crée le Security Group dynamique via New-MgGroup
#   4. Assigne un owner
#   5. Vérifie l'activation du moteur de règle depuis la source de vérité
#   6. Ferme proprement toutes les sessions
#
# Différence clé vs exercice 4a (statique) :
#   4a : GroupTypes = @()                  → membership manuel via CSV
#   4b : GroupTypes = @("DynamicMembership") → membership calculé par règle Entra
#
# Types de groupes Graph — la combinaison de 3 paramètres définit le type :
#
#   TYPE                     | GroupTypes                        | SecurityEnabled | MailEnabled
#   -------------------------|-----------------------------------|-----------------|------------
#   Security Group statique  | @()                               | $true           | $false
#   Security Group dynamique | @("DynamicMembership")            | $true           | $false  ← ICI
#   M365 Group statique      | @("Unified")                      | $false          | $true
#   M365 Group dynamique     | @("Unified","DynamicMembership")  | $false          | $true
#
# Note importante : sur un groupe dynamique, l'owner NE PEUT PAS modifier les membres
# manuellement — le membership est exclusivement géré par le moteur de règle Entra.
#
# Personnages test : "MagicOps-Dynamic-Team" — tenant de dev (0n4mg.onmicrosoft.com)
#
# Module requis : Microsoft.Graph.Groups, Microsoft.Graph.Users
# Connexion     : Connect-MgGraph
# ========================================================================================

# --- OUVERTURE — RESET DE SESSION TOTAL ---
# REX : Group.ReadWrite.All couvre la création et la modification de groupes,
# y compris les groupes dynamiques. Une session ouverte avec des scopes inférieurs
# (ex : Group.Read.All) échouera sur New-MgGroup avec un 403 sans message explicite.
$Scopes = @(
    "Group.ReadWrite.All", # Créer/modifier des groupes, gérer owners
    "User.Read.All"        # Résoudre l'UPN de l'owner en ObjectId
)

Disconnect-MgGraph -ErrorAction SilentlyContinue
Connect-MgGraph -Scopes $Scopes

# ========================================================================================
# ÉTAPE 1 : Définition des variables
# ========================================================================================
Write-Host "1. Définition des variables..." -ForegroundColor Cyan

$GroupBaseName    = "MagicOps-Dynamic-Team"
$GroupDescription = "Security Group dynamique — peuplé automatiquement par département."
$OwnerUPN         = "geralt@0n4mg.onmicrosoft.com"
$TargetDepartment = "MagicOps"

# Règle de membership — syntaxe identique aux AU dynamiques (exercice 3b).
# Les backticks (`") échappent les guillemets doubles internes dans la chaîne PowerShell.
# Sans eux, PowerShell interpréterait le guillemet comme fin de chaîne → erreur de parsing.
# Entra évalue : si user.department == "MagicOps" → entrée dans le groupe.
# Si l'attribut change → sortie automatique du groupe.
$MembershipRule = "(user.department -eq `"$TargetDepartment`")"

Write-Host "-> Groupe cible : $GroupBaseName" -ForegroundColor Green
Write-Host "-> Règle        : $MembershipRule" -ForegroundColor Green
Write-Host "-> Owner        : $OwnerUPN`n" -ForegroundColor Green

# ========================================================================================
# ÉTAPE 2 : Recherche d'un nom de groupe disponible (auto-incrément)
# ========================================================================================
Write-Host "2. Recherche d'un nom de groupe disponible..." -ForegroundColor Cyan

# DÉCOUVERTE TECHNIQUE : Graph n'impose pas l'unicité sur le DisplayName des groupes.
# L'auto-incrément est une convention de lab pour éviter la pollution du tenant
# et rester cohérent avec les autres exercices.
$GroupName = $GroupBaseName
$Counter   = 2
while (Get-MgGroup -Filter "DisplayName eq '$GroupName'" -ErrorAction SilentlyContinue) {
    Write-Host "   '$GroupName' déjà pris — test avec suffixe -v$Counter..." -ForegroundColor Yellow
    $GroupName = "$GroupBaseName-v$Counter"
    $Counter++
}
Write-Host "-> Nom retenu pour le groupe : '$GroupName'`n" -ForegroundColor Green

# ========================================================================================
# ÉTAPE 3 : Création du Security Group dynamique
# ========================================================================================
Write-Host "3. Création du Security Group dynamique '$GroupName'..." -ForegroundColor Cyan
Write-Host "   Règle appliquée : $MembershipRule" -ForegroundColor Gray

# Contrairement aux AU dynamiques (exercice 3b) qui nécessitaient Invoke-MgGraphRequest,
# New-MgGroup supporte nativement les paramètres dynamiques — pas de contournement HTTP requis.
#
# MembershipRule                : règle Entra évaluée sur les attributs utilisateur.
# MembershipRuleProcessingState : "On" = moteur actif dès la création.
#                                 "Paused" = moteur suspendu (utile pour modifier la règle
#                                  sans déclencher de réévaluation immédiate).
# MailNickname                  : obligatoire même pour un groupe sans mail — contrainte API Graph.
#                                 Doit être unique dans le tenant (contrairement au DisplayName).
$GroupParams = @{
    DisplayName                   = $GroupName
    Description                   = $GroupDescription
    MailNickname                  = ($GroupName.ToLower() -replace '\s+', '-')
    GroupTypes                    = @("DynamicMembership")
    SecurityEnabled               = $true
    MailEnabled                   = $false
    MembershipRule                = $MembershipRule
    MembershipRuleProcessingState = "On"
}

try {
    $NewGroup = New-MgGroup @GroupParams -ErrorAction Stop
    Write-Host "-> Groupe créé : $($NewGroup.DisplayName) [ID : $($NewGroup.Id)]`n" -ForegroundColor Green
}
catch {
    Write-Host "-> Échec de la création du groupe : $_" -ForegroundColor Red
    Disconnect-MgGraph -ErrorAction SilentlyContinue
    return
}

# ========================================================================================
# ÉTAPE 4 : Assignation de l'owner
# ========================================================================================
Write-Host "4. Assignation de l'owner ($OwnerUPN)..." -ForegroundColor Cyan

# Sur un groupe dynamique, l'owner peut modifier les paramètres du groupe (description,
# règle de membership, etc.) mais NE PEUT PAS ajouter/retirer des membres manuellement.
# Le membership est exclusivement géré par le moteur Entra.
try {
    $OwnerObject = Get-MgUser -UserId $OwnerUPN -ErrorAction Stop

    # Syntaxe OData imposée par l'API Graph pour les liaisons par référence.
    # Identique au pattern utilisé en exercice 4a pour owners et membres.
    $OwnerParams = @{
        "@odata.id" = "https://graph.microsoft.com/v1.0/users/$($OwnerObject.Id)"
    }

    New-MgGroupOwnerByRef -GroupId $NewGroup.Id -BodyParameter $OwnerParams -ErrorAction Stop
    Write-Host "-> $OwnerUPN est owner du groupe.`n" -ForegroundColor Green
}
catch {
    Write-Host "-> Échec de l'assignation de l'owner : $_" -ForegroundColor Red
}

# ========================================================================================
# ÉTAPE 5 : Vérification du moteur de règle depuis la source de vérité
# ========================================================================================
Write-Host "5. Vérification du moteur de règle..." -ForegroundColor Cyan

# REX : la propagation Graph post-création n'est pas instantanée.
# MembershipRuleProcessingState relu immédiatement après New-MgGroup peut revenir vide
# même si la création a réussi. 30 secondes couvrent la latence backend.
Start-Sleep -Seconds 30

$CheckGroup = Get-MgGroup `
    -GroupId  $NewGroup.Id `
    -Property "id,displayName,membershipRule,membershipRuleProcessingState" `
    -ErrorAction SilentlyContinue

if ($CheckGroup) {
    Write-Host "-> Groupe confirmé :" -ForegroundColor Green
    [PSCustomObject]@{
        Id              = $CheckGroup.Id
        DisplayName     = $CheckGroup.DisplayName
        Règle           = $CheckGroup.MembershipRule
        MoteurRègle     = $CheckGroup.MembershipRuleProcessingState
    } | Format-List

    # Valeurs possibles de MembershipRuleProcessingState :
    #   "On"     = moteur actif, Entra évalue la règle en arrière-plan
    #   "Paused" = moteur suspendu (erreur de syntaxe dans la règle, ou quota dépassé)
    #   vide     = problème de création — la règle n'a pas été enregistrée
    Write-Host "-> Info : les membres seront peuplés automatiquement par Entra." -ForegroundColor Yellow
    Write-Host "   Délai de propagation : quelques minutes à 24h selon la taille du tenant.`n" -ForegroundColor Yellow
} else {
    Write-Host "-> ATTENTION : groupe non trouvé lors de la vérification." -ForegroundColor Red
}

# ========================================================================================
# ÉTAPE 6 : Résumé
# ========================================================================================
Write-Host "=== RÉSUMÉ ===" -ForegroundColor Magenta
[PSCustomObject]@{
    GroupeCréé         = $GroupName
    GroupeID           = $NewGroup.Id
    TypeGroupe         = "Security Group dynamique"
    Règle              = $MembershipRule
    MoteurRègle        = if ($CheckGroup) { $CheckGroup.MembershipRuleProcessingState } else { "Non vérifié" }
    Owner              = $OwnerUPN
    PropagationMembres = "Automatique — délai jusqu'à 24h"
} | Format-List

# ========================================================================================
# NETTOYAGE MÉMOIRE
# ========================================================================================
Remove-Variable Scopes, GroupBaseName, GroupName, GroupDescription, OwnerUPN,
                TargetDepartment, MembershipRule, Counter, GroupParams,
                NewGroup, OwnerObject, OwnerParams, CheckGroup `
                -ErrorAction SilentlyContinue

# ========================================================================================
# FERMETURE — RESET DE SESSION TOTAL
# ========================================================================================
Disconnect-MgGraph -ErrorAction SilentlyContinue
Write-Host "Session MgGraph fermée proprement." -ForegroundColor Magenta
