# ========================================================================================
# Exercice 3a : Entra ID — Création d'un Security Group statique, owner et membres CSV
# ========================================================================================
# Concept : Les Security Groups sont le socle de la délégation d'accès dans Entra.
# Ils servent à cibler des politiques de Conditional Access, des assignations PIM,
# des périmètres d'accès aux applications, et des règles de licence.
#
# Ce que fait ce script :
#   1. Reset total de session
#   2. Recherche un nom de groupe disponible (auto-incrément)
#   3. Crée le Security Group statique
#   4. Assigne un owner
#   5. Injecte les membres depuis un CSV
#   6. Vérifie le groupe depuis la source de vérité
#   7. Ferme proprement toutes les sessions
#
# Types de groupes Graph — la combinaison de 3 paramètres définit le type :
#
#   TYPE                     | GroupTypes                        | SecurityEnabled | MailEnabled
#   -------------------------|-----------------------------------|-----------------|------------
#   Security Group statique  | @()                               | $true           | $false
#   Security Group dynamique | @("DynamicMembership")            | $true           | $false
#   M365 Group statique      | @("Unified")                      | $false          | $true
#   M365 Group dynamique     | @("Unified","DynamicMembership")  | $false          | $true
#
# Ici : Security Group statique — membership manuel via CSV.
#
# Personnages test : "Witchers-Brotherhood" — tenant de dev (0n4mg.onmicrosoft.com)
#
# Module requis : Microsoft.Graph.Groups, Microsoft.Graph.Users
# Connexion     : Connect-MgGraph
# ========================================================================================

# --- OUVERTURE — RESET DE SESSION TOTAL ---
# REX : Group.ReadWrite.All et User.Read.All sont deux scopes distincts.
# Une session ouverte avec User.Read.All uniquement (ex : script précédent) laissera
# passer Get-MgUser mais échouera silencieusement sur New-MgGroup avec un 403.
# On repart d'une session propre sans exception.
$Scopes = @(
    "Group.ReadWrite.All", # Créer/modifier des groupes, gérer owners et membres
    "User.Read.All"        # Résoudre les UPNs en ObjectIds pour owners et membres
)

Disconnect-MgGraph -ErrorAction SilentlyContinue
Connect-MgGraph -Scopes $Scopes

# ========================================================================================
# ÉTAPE 1 : Définition des variables
# ========================================================================================
Write-Host "1. Définition des variables..." -ForegroundColor Cyan

$GroupBaseName    = "Witchers-Brotherhood"
$GroupDescription = "Security Group statique — membres du contrat de Kaer Morhen."
$OwnerUPN         = "geralt@0n4mg.onmicrosoft.com"

# Chemin du CSV — décommenter la ligne correspondant à l'environnement d'exécution.
# EN LABO / Local :
$PathCSV = "D:\Documents\ScriptsPowerShell\membres.csv"
# EN PRODUCTION :
# $PathCSV = "$PSScriptRoot\membres.csv"

Write-Host "-> Groupe cible : $GroupBaseName" -ForegroundColor Green
Write-Host "-> Owner        : $OwnerUPN`n" -ForegroundColor Green

# ========================================================================================
# ÉTAPE 2 : Vérification du fichier CSV
# ========================================================================================
Write-Host "2. Vérification du fichier CSV..." -ForegroundColor Cyan

if (-not (Test-Path $PathCSV)) {
    Write-Host "-> Erreur : fichier introuvable à '$PathCSV'." -ForegroundColor Red
    Disconnect-MgGraph -ErrorAction SilentlyContinue
    return
}
Write-Host "-> Fichier CSV localisé.`n" -ForegroundColor Green

# ========================================================================================
# ÉTAPE 3 : Recherche d'un nom de groupe disponible (auto-incrément)
# ========================================================================================
Write-Host "3. Recherche d'un nom de groupe disponible..." -ForegroundColor Cyan

# DÉCOUVERTE TECHNIQUE : Graph autorise techniquement deux groupes avec le même
# DisplayName — il n'y a pas de contrainte d'unicité sur ce champ.
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
# ÉTAPE 4 : Création du Security Group statique
# ========================================================================================
Write-Host "4. Création du Security Group '$GroupName'..." -ForegroundColor Cyan

# MailNickname : obligatoire même pour un groupe sans mail — contrainte API Graph.
# Il doit être unique dans le tenant (contrairement au DisplayName).
# Convention : version kebab-case du nom, en minuscules.
$GroupParams = @{
    DisplayName     = $GroupName
    Description     = $GroupDescription
    MailNickname    = ($GroupName.ToLower() -replace '\s+', '-')
    GroupTypes      = @()      # Vide = groupe statique (pas Unified, pas DynamicMembership)
    SecurityEnabled = $true    # $true = Security Group
    MailEnabled     = $false   # $false = pas de boîte mail associée
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
# ÉTAPE 5 : Assignation de l'owner
# ========================================================================================
Write-Host "5. Assignation de l'owner ($OwnerUPN)..." -ForegroundColor Cyan

# L'owner peut gérer le groupe (membres, paramètres) sans être Global Admin.
# Un groupe sans owner explicite est orphelin — seul un admin global peut le gérer.
# Bonne pratique : toujours assigner au moins un owner à la création.
try {
    $OwnerObject = Get-MgUser -UserId $OwnerUPN -ErrorAction Stop

    # Syntaxe OData imposée par l'API Graph pour les liaisons par référence.
    # On ne peut pas passer l'ID directement — Graph attend l'URL complète de la ressource.
    # Même pattern que pour les membres d'AU (exercice 2a).
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
# ÉTAPE 6 : Injection des membres depuis le CSV
# ========================================================================================
Write-Host "6. Injection des membres depuis le CSV..." -ForegroundColor Cyan

$Members = (Import-Csv -Path $PathCSV).UserPrincipalName
Write-Host "   $($Members.Count) membre(s) détecté(s) dans le CSV." -ForegroundColor Gray
Write-Host "-------------------------------------------------------------------" -ForegroundColor Gray

foreach ($UserUPN in $Members) {
    try {
        # Résolution UPN → ObjectId — Graph n'accepte que des IDs dans les références OData.
        $UserObject = Get-MgUser -UserId $UserUPN -ErrorAction Stop

        # Même syntaxe OData que pour l'owner — liaison par référence obligatoire.
        # New-MgGroupMemberByRef et New-MgGroupOwnerByRef partagent ce pattern.
        $MemberParams = @{
            "@odata.id" = "https://graph.microsoft.com/v1.0/users/$($UserObject.Id)"
        }

        New-MgGroupMemberByRef -GroupId $NewGroup.Id -BodyParameter $MemberParams -ErrorAction Stop
        Write-Host "[SUCCESS] $UserUPN ajouté." -ForegroundColor Green
    }
    catch {
        Write-Host "[ERROR]   $UserUPN — $_" -ForegroundColor Red
    }
}

Write-Host "-------------------------------------------------------------------" -ForegroundColor Gray
Write-Host "-> Injection terminée.`n" -ForegroundColor Green

# ========================================================================================
# ÉTAPE 7 : Vérification depuis la source de vérité
# ========================================================================================
Write-Host "7. Vérification du groupe depuis Entra..." -ForegroundColor Cyan

# REX : la propagation Graph post-création n'est pas instantanée.
# Get-MgGroup interrogé immédiatement peut retourner des propriétés vides ou incomplètes.
# 30 secondes couvrent la latence backend.
Start-Sleep -Seconds 30

$CheckGroup = Get-MgGroup `
    -GroupId  $NewGroup.Id `
    -Property "id,displayName,securityEnabled,mailEnabled,groupTypes" `
    -ErrorAction SilentlyContinue

if ($CheckGroup) {
    Write-Host "-> Groupe confirmé :" -ForegroundColor Green
    [PSCustomObject]@{
        Id              = $CheckGroup.Id
        DisplayName     = $CheckGroup.DisplayName
        SecurityEnabled = $CheckGroup.SecurityEnabled
        MailEnabled     = $CheckGroup.MailEnabled
        GroupTypes      = if ($CheckGroup.GroupTypes) { $CheckGroup.GroupTypes -join ", " } else { "(vide — statique)" }
    } | Format-List
} else {
    Write-Host "-> ATTENTION : groupe non trouvé lors de la vérification." -ForegroundColor Red
}

# ========================================================================================
# ÉTAPE 8 : Résumé
# ========================================================================================
Write-Host "=== RÉSUMÉ ===" -ForegroundColor Magenta
[PSCustomObject]@{
    GroupeCréé      = $GroupName
    GroupeID        = $NewGroup.Id
    TypeGroupe      = "Security Group statique"
    Owner           = $OwnerUPN
    MembresInjectés = $Members.Count
    FichierCSV      = $PathCSV
    StatutVérif     = if ($CheckGroup) { "Confirmé dans Graph" } else { "Non vérifié" }
} | Format-List

# ========================================================================================
# NETTOYAGE MÉMOIRE
# ========================================================================================
Remove-Variable Scopes, GroupBaseName, GroupName, GroupDescription, OwnerUPN,
                PathCSV, Counter, GroupParams, NewGroup,
                OwnerObject, OwnerParams, Members, UserUPN,
                UserObject, MemberParams, CheckGroup `
                -ErrorAction SilentlyContinue

# ========================================================================================
# FERMETURE — RESET DE SESSION TOTAL
# ========================================================================================
Disconnect-MgGraph -ErrorAction SilentlyContinue
Write-Host "Session MgGraph fermée proprement." -ForegroundColor Magenta
