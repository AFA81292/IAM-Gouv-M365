# ========================================================================================
# Exercice 3c : Group Management — Création d'un groupe M365 (Unified Group)
# ========================================================================================
# Concept : Un groupe M365 (aussi appelé "Unified Group") est différent d'un Security
# Group (3a) ou d'un groupe dynamique (3b) :
#
#   Security Group    → contrôle d'accès aux ressources (apps, SharePoint, etc.)
#   Groupe M365       → collaboration : mailbox partagée, site SharePoint, Teams-ready
#   Groupe dynamique  → membership automatique basé sur des attributs utilisateur
#
# Un groupe M365 peut aussi servir de cible pour une Label Policy Purview — c'est
# l'objectif ici : créer GRP-Spectres pour l'utiliser en Purview 2d (publication
# des labels de sensibilité NormandySR2).
#
# POURQUOI -BodyParameter ET PAS LES PARAMÈTRES DIRECTS ?
#   New-MgGroup n'accepte pas $true/$false PowerShell directement sur -MailEnabled
#   et -SecurityEnabled — erreur "A positional parameter cannot be found that accepts
#   argument 'True'". La solution : passer un hashtable via -BodyParameter.
#   Le SDK Graph le convertit en JSON correctement typé, sans ambiguïté.
#
# Propriétés spécifiques aux groupes M365 dans le hashtable :
#   GroupTypes      : @("Unified") — c'est ce qui distingue un groupe M365 d'un
#                     Security Group. Sans cette valeur, on crée un groupe de sécurité.
#   MailEnabled     : $true — obligatoire pour Unified, le groupe a une mailbox.
#   MailNickname    : alias email du groupe (sans espaces, sans accents).
#   SecurityEnabled : $false — un groupe M365 pur n'est pas un groupe de sécurité.
#
# Module requis : Microsoft.Graph
# Scopes requis : Group.ReadWrite.All
# ========================================================================================

# --- OUVERTURE ---
# -ContextScope Process : force une session isolée qui bypasse le cache WAM
# (Web Account Manager). Sans ce paramètre, certains scopes retournent 403
# même avec les bons droits — voir note technique dans 05_Conditional_Access.
Connect-MgGraph -Scopes "Group.ReadWrite.All" -ContextScope Process -NoWelcome

# --- ÉTAPE 0 : Vérification — le groupe existe déjà ? ---
Write-Host "0. Vérification existence préalable..." -ForegroundColor Cyan

$GroupName    = "GRP-Spectres"
$MailNickname = "GRP-Spectres"

$ExistingGroup = Get-MgGroup -Filter "DisplayName eq '$GroupName'" -ErrorAction SilentlyContinue |
                 Where-Object { $_.DisplayName -eq $GroupName }

if ($ExistingGroup) {
    Write-Host "-> Groupe '$GroupName' déjà présent (Id : $($ExistingGroup.Id))." -ForegroundColor Yellow
    Write-Host "   Aucune action — utiliser l'Id ci-dessus pour l'exo Purview 2d." -ForegroundColor Yellow
    Disconnect-MgGraph | Out-Null
    return
}
Write-Host "-> Groupe absent — création en cours.`n" -ForegroundColor Green

# --- ÉTAPE 1 : Création du groupe M365 via BodyParameter ---
Write-Host "1. Création du groupe M365 '$GroupName'..." -ForegroundColor Cyan

$GroupParams = @{
    DisplayName     = $GroupName
    Description     = "Groupe de test Purview — cible des Label Policies NormandySR2. Spectres : agents d'élite du Conseil, accès de confiance."
    GroupTypes      = @("Unified")
    MailEnabled     = $true
    MailNickname    = $MailNickname
    SecurityEnabled = $false
}

try {
    $NewGroup = New-MgGroup -BodyParameter $GroupParams -ErrorAction Stop

    Write-Host "-> Groupe créé." -ForegroundColor Green
    Write-Host "   Id   : $($NewGroup.Id)" -ForegroundColor DarkGray
    Write-Host "   Mail : $($NewGroup.Mail)`n" -ForegroundColor DarkGray
}
catch {
    Write-Host "-> Échec création : $_" -ForegroundColor Red
    Disconnect-MgGraph | Out-Null
    return
}

# --- ÉTAPE 2 : Ajout de membres ---
Write-Host "2. Ajout des membres..." -ForegroundColor Cyan

# New-MgGroupMember attend l'Id de l'utilisateur, pas son UPN — on résout
# d'abord chaque UPN via Get-MgUser.
$Members = @(
    "shepard@0n4mg.onmicrosoft.com",
    "liara@0n4mg.onmicrosoft.com",
    "garrus@0n4mg.onmicrosoft.com"
)

foreach ($Upn in $Members) {
    $User = Get-MgUser -UserId $Upn -ErrorAction SilentlyContinue
    if (-not $User) {
        Write-Host "   -> ATTENTION : '$Upn' introuvable — ignoré." -ForegroundColor Yellow
        continue
    }
    try {
        New-MgGroupMember -GroupId $NewGroup.Id -DirectoryObjectId $User.Id -ErrorAction Stop
        Write-Host "   -> $Upn ajouté." -ForegroundColor Green
    }
    catch {
        Write-Host "   -> Échec ajout '$Upn' : $_" -ForegroundColor Red
    }
}

# --- ÉTAPE 3 : Vérification ---
Write-Host "`n3. Vérification (propagation 15s)..." -ForegroundColor Cyan
Start-Sleep -Seconds 15

$CheckGroup   = Get-MgGroup -GroupId $NewGroup.Id -ErrorAction SilentlyContinue
$CheckMembers = Get-MgGroupMember -GroupId $NewGroup.Id -ErrorAction SilentlyContinue

if (-not $CheckGroup) {
    Write-Host "-> ATTENTION : groupe introuvable après vérification." -ForegroundColor Yellow
}
else {
    Write-Host "-> Groupe confirmé :" -ForegroundColor Green
    [PSCustomObject]@{
        Nom         = $CheckGroup.DisplayName
        Id          = $CheckGroup.Id
        Mail        = $CheckGroup.Mail
        Type        = ($CheckGroup.GroupTypes -join ", ")
        MailEnabled = $CheckGroup.MailEnabled
        Membres     = ($CheckMembers | ForEach-Object {
                          (Get-MgUser -UserId $_.Id -ErrorAction SilentlyContinue).UserPrincipalName
                      }) -join ", "
    } | Format-List
}

# --- NETTOYAGE MÉMOIRE ---
Remove-Variable GroupName, MailNickname, ExistingGroup, GroupParams, NewGroup, `
                Members, Upn, User, CheckGroup, CheckMembers -ErrorAction SilentlyContinue

# --- FERMETURE ---
Disconnect-MgGraph | Out-Null
Write-Host "`nSession fermée." -ForegroundColor Magenta
