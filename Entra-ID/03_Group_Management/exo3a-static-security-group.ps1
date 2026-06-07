# ========================================================================================
# Exercice 4a : Création d'un Security Group statique, owner et peuplement via CSV
# ========================================================================================

# --- ÉTAPE 1 : Connexion à Microsoft Graph ---
# Group.ReadWrite.All : créer/modifier des groupes
# User.Read.All : lire les profils pour récupérer les IDs
$Scopes = @(
    "Group.ReadWrite.All",
    "User.Read.All"
)
Connect-MgGraph -Scopes $Scopes

# --- ÉTAPE 2 : Définition des variables du Lab ---
$GroupName        = "Witchers-Brotherhood"
$GroupDescription = "Security Group statique — membres du contrat de Kaer Morhen."
$OwnerUPN         = "geralt@0n4mg.onmicrosoft.com"

# Chemin du CSV — décommenter la ligne nécessaire
# EN LABO/Local :
$PathCSV = "D:\Documents\ScriptsPowerShell\membres.csv"
# EN PRODUCTION :
# $PathCSV = "$PSScriptRoot\membres.csv"

# --- ÉTAPE 3 : Vérification du fichier CSV ---
if (-not (Test-Path $PathCSV)) {
    Write-Error "Fichier introuvable : $PathCSV"
    return
}

# --- ÉTAPE 4 : Création du Security Group statique ---
# La combinaison de ces 3 paramètres définit le TYPE de groupe créé :
#
#   TYPE                     | GroupTypes              | SecurityEnabled | MailEnabled
#   -------------------------|-------------------------|-----------------|------------
#   Security Group statique  | @() — vide              | $true           | $false
#   Security Group dynamique | @("DynamicMembership")  | $true           | $false
#   M365 Group statique      | @("Unified")            | $false          | $true
#   M365 Group dynamique     | @("Unified",            | $false          | $true
#                            |  "DynamicMembership")   |                 |
#
# Ici : Security Group statique — utilisé pour l'assignation de rôles,
# l'accès conditionnel, PIM. Membership manuel via CSV à l'étape 6.
$GroupParams = @{
    DisplayName     = $GroupName
    Description     = $GroupDescription
    # MailNickname obligatoire même pour un groupe sans mail — contrainte API Graph
    MailNickname    = "witchers-brotherhood"
    GroupTypes      = @()
    SecurityEnabled = $true
    MailEnabled     = $false
}

Write-Host "1. Création du Security Group '$GroupName'..." -ForegroundColor Cyan
$NewGroup = New-MgGroup @GroupParams

# Guard clause — si la création échoue, inutile de continuer
if (-not $NewGroup) { Write-Error "Échec de la création du groupe." ; return }

Write-Host "-> Succès : Groupe créé avec l'ID : $($NewGroup.Id)`n" -ForegroundColor Green

# --- ÉTAPE 5 : Assignation de l'owner ---
# L'owner peut gérer le groupe (membres, paramètres) sans être Global Admin
Write-Host "2. Assignation de l'owner $OwnerUPN..." -ForegroundColor Cyan

try {
    # On récupère l'objet user pour obtenir son ID Entra
    $OwnerObject = Get-MgUser -UserId $OwnerUPN -ErrorAction Stop

    # Syntaxe OData imposée par l'API Graph pour les liaisons par référence
    # On ne peut pas passer l'ID directement — Graph attend une URL complète
    $OwnerParams = @{
        "@odata.id" = "https://graph.microsoft.com/v1.0/users/$($OwnerObject.Id)"
    }

    New-MgGroupOwnerByRef -GroupId $NewGroup.Id -BodyParameter $OwnerParams -ErrorAction Stop
    Write-Host "-> Succès : $OwnerUPN est owner du groupe.`n" -ForegroundColor Green
}
catch {
    Write-Host "-> Échec assignation owner : $_" -ForegroundColor Red
}

# --- ÉTAPE 6 : Peuplement des membres via CSV ---
# Try/Catch dans la boucle — si un user plante, les suivants continuent
# Même logique que l'exo 2bis : un échec ne tue pas le reste du peuplement
Write-Host "3. Injection des membres depuis le CSV..." -ForegroundColor Cyan
$Members = (Import-Csv -Path $PathCSV).UserPrincipalName

foreach ($UserUPN in $Members) {
    try {
        # Récupération de l'ID Entra — fonctionne avec UPN ou ObjectId
        $UserObject = Get-MgUser -UserId $UserUPN -ErrorAction Stop

        # Même syntaxe OData que pour l'owner — liaison par référence obligatoire
        $MemberParams = @{
            "@odata.id" = "https://graph.microsoft.com/v1.0/users/$($UserObject.Id)"
        }

        New-MgGroupMemberByRef -GroupId $NewGroup.Id -BodyParameter $MemberParams -ErrorAction Stop
        Write-Host "   -> $UserUPN ajouté." -ForegroundColor Green
    }
    catch {
        Write-Host "   -> Échec pour $UserUPN : $_" -ForegroundColor Yellow
    }
}
Write-Host "-> Fin de l'injection des membres.`n" -ForegroundColor Green

# --- ÉTAPE 7 : Vérification finale ---
# On va lire directement dans Entra — source de vérité, pas l'objet local
Write-Host "4. Vérification du groupe créé..." -ForegroundColor Cyan

# Attente réplication Azure avant lecture
Start-Sleep -Seconds 2

# On demande uniquement les propriétés utiles — évite de charger tout l'objet
Get-MgGroup -GroupId $NewGroup.Id -Property "id,displayName,securityEnabled,mailEnabled,groupTypes" |
    Select-Object Id, DisplayName, SecurityEnabled, MailEnabled, GroupTypes

# --- ÉTAPE 8 : Nettoyage ---
Remove-Variable Scopes, GroupName, GroupDescription, OwnerUPN, PathCSV, `
                GroupParams, NewGroup, OwnerObject, OwnerParams, `
                Members, UserUPN, UserObject, MemberParams `
                -ErrorAction SilentlyContinue

Write-Host "`nMémoire locale nettoyée. Session Microsoft Graph toujours active." -ForegroundColor Magenta
