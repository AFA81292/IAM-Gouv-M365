# ========================================================================================
# Exercice 3c : Entra ID — Création d'un groupe M365 (Unified Group)
# ========================================================================================
# Concept : Un groupe M365 (aussi appelé "Unified Group") est distinct d'un Security
# Group ou d'un groupe dynamique — il porte une dimension collaboration en plus
# du contrôle d'accès.
#
#   Security Group  → contrôle d'accès aux ressources (apps, SharePoint, CA, PIM)
#   Groupe M365     → collaboration : mailbox partagée, site SharePoint, Teams-ready
#   Groupe dynamique → membership automatique basé sur des attributs utilisateur
#
# Ce que fait ce script :
#   1. Reset total de session
#   2. Vérifie si le groupe existe déjà (sortie propre si oui — nom fixe, pas d'incrément)
#   3. Crée le groupe M365 via -BodyParameter
#   4. Injecte les membres
#   5. Vérifie le groupe et ses membres depuis la source de vérité
#   6. Ferme proprement toutes les sessions
#
# Pourquoi un nom fixe et non un auto-incrément ?
#   GRP-Spectres est référencé par son nom dans l'exercice Purview 2d (Label Policy).
#   Un nom incrémenté (GRP-Spectres-v2) casserait la référence croisée entre exercices.
#   Si le groupe existe déjà → le script sort proprement et affiche l'Id à réutiliser.
#
# DÉCOUVERTE TECHNIQUE : New-MgGroup n'accepte pas $true/$false PowerShell directement
# sur -MailEnabled et -SecurityEnabled — erreur "A positional parameter cannot be found
# that accepts argument 'True'". Solution : passer un hashtable via -BodyParameter.
# Le SDK Graph le convertit en JSON correctement typé, sans ambiguïté de parsing.
#
# Propriétés spécifiques aux groupes M365 dans le hashtable :
#   GroupTypes      : @("Unified") — distingue un groupe M365 d'un Security Group.
#                     Sans cette valeur → Security Group créé par défaut.
#   MailEnabled     : $true  — obligatoire pour Unified, le groupe a une mailbox.
#   SecurityEnabled : $false — un groupe M365 pur n'est pas un groupe de sécurité.
#   MailNickname    : alias email du groupe (sans espaces, sans accents, unique dans le tenant).
#
# Membres test : Shepard, Liara, Garrus — Mass Effect, tenant de dev (0n4mg.onmicrosoft.com)
#
# Module requis : Microsoft.Graph.Groups, Microsoft.Graph.Users
# Connexion     : Connect-MgGraph
# ========================================================================================

# --- OUVERTURE — RESET DE SESSION TOTAL ---
# REX : -ContextScope Process isole le token d'authentification au processus PowerShell
# en cours. Sans ce paramètre, le cache WAM (Windows Authentication Manager) peut
# réutiliser un token de session précédente avec des scopes insuffisants — les erreurs
# 403 résultantes sont silencieuses et difficiles à diagnostiquer.
# -NoWelcome supprime le bandeau de connexion pour un output console plus lisible.
Disconnect-MgGraph -ErrorAction SilentlyContinue
Connect-MgGraph -Scopes "Group.ReadWrite.All" -ContextScope Process -NoWelcome

# ========================================================================================
# ÉTAPE 0 : Vérification — le groupe existe déjà ?
# ========================================================================================
Write-Host "0. Vérification de l'existence préalable du groupe..." -ForegroundColor Cyan

# Nom fixe — pas d'auto-incrément (voir justification dans l'en-tête).
$GroupName    = "GRP-Spectres"
$MailNickname = "GRP-Spectres"

# Get-MgGroup -Filter retourne tous les groupes dont le DisplayName correspond.
# Le Where-Object en aval affine sur la correspondance exacte — le filtre OData
# peut retourner des faux positifs sur des noms partiellement similaires.
$ExistingGroup = Get-MgGroup -Filter "DisplayName eq '$GroupName'" -ErrorAction SilentlyContinue |
                 Where-Object { $_.DisplayName -eq $GroupName }

if ($ExistingGroup) {
    Write-Host "-> Groupe '$GroupName' déjà présent." -ForegroundColor Yellow
    Write-Host "   Id : $($ExistingGroup.Id)" -ForegroundColor Yellow
    Write-Host "   Aucune action — utiliser cet Id pour l'exercice Purview 2d." -ForegroundColor Yellow
    Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
    return
}
Write-Host "-> Groupe absent — création en cours.`n" -ForegroundColor Green

# ========================================================================================
# ÉTAPE 1 : Création du groupe M365 via -BodyParameter
# ========================================================================================
Write-Host "1. Création du groupe M365 '$GroupName'..." -ForegroundColor Cyan

$GroupParams = @{
    DisplayName     = $GroupName
    Description     = "Groupe de test Purview — cible des Label Policies NormandySR2. Spectres : agents d'élite du Conseil, accès de confiance."
    GroupTypes      = @("Unified")  # @("Unified") = groupe M365 / @() = Security Group
    MailEnabled     = $true         # Obligatoire pour Unified — mailbox partagée associée
    MailNickname    = $MailNickname  # Alias email unique dans le tenant, sans espaces ni accents
    SecurityEnabled = $false        # $false = groupe M365 pur, pas un groupe de sécurité
}

try {
    $NewGroup = New-MgGroup -BodyParameter $GroupParams -ErrorAction Stop

    Write-Host "-> Groupe créé :" -ForegroundColor Green
    Write-Host "   Id   : $($NewGroup.Id)" -ForegroundColor DarkGray
    Write-Host "   Mail : $($NewGroup.Mail)`n" -ForegroundColor DarkGray
}
catch {
    Write-Host "-> Échec de la création : $_" -ForegroundColor Red
    Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
    return
}

# ========================================================================================
# ÉTAPE 2 : Injection des membres
# ========================================================================================
Write-Host "2. Ajout des membres..." -ForegroundColor Cyan

# New-MgGroupMember attend le DirectoryObjectId (GUID Entra) — pas l'UPN.
# On résout chaque UPN via Get-MgUser avant l'ajout.
# Contrairement à New-MgGroupMemberByRef (exercice 4a), New-MgGroupMember
# prend l'Id directement via -DirectoryObjectId, sans syntaxe OData @odata.id.
$Members = @(
    "shepard@0n4mg.onmicrosoft.com",
    "liara@0n4mg.onmicrosoft.com",
    "garrus@0n4mg.onmicrosoft.com"
)

Write-Host "-------------------------------------------------------------------" -ForegroundColor Gray
foreach ($Upn in $Members) {
    $User = Get-MgUser -UserId $Upn -ErrorAction SilentlyContinue
    if (-not $User) {
        Write-Host "[SKIP]    '$Upn' introuvable dans Entra — ignoré." -ForegroundColor Yellow
        continue
    }
    try {
        New-MgGroupMember -GroupId $NewGroup.Id -DirectoryObjectId $User.Id -ErrorAction Stop
        Write-Host "[SUCCESS] $Upn ajouté." -ForegroundColor Green
    }
    catch {
        Write-Host "[ERROR]   $Upn — $_" -ForegroundColor Red
    }
}
Write-Host "-------------------------------------------------------------------" -ForegroundColor Gray
Write-Host "-> Injection terminée.`n" -ForegroundColor Green

# ========================================================================================
# ÉTAPE 3 : Vérification depuis la source de vérité
# ========================================================================================
Write-Host "3. Vérification depuis Entra..." -ForegroundColor Cyan

# REX : la propagation Graph post-création et post-ajout de membres n'est pas instantanée.
# Get-MgGroupMember relu immédiatement peut retourner une liste vide même si les ajouts
# ont réussi. 30 secondes couvrent la latence backend.
Start-Sleep -Seconds 30

$CheckGroup   = Get-MgGroup -GroupId $NewGroup.Id -ErrorAction SilentlyContinue
$CheckMembers = Get-MgGroupMember -GroupId $NewGroup.Id -ErrorAction SilentlyContinue

if (-not $CheckGroup) {
    Write-Host "-> ATTENTION : groupe introuvable lors de la vérification." -ForegroundColor Red
} else {
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

# ========================================================================================
# ÉTAPE 4 : Résumé
# ========================================================================================
Write-Host "=== RÉSUMÉ ===" -ForegroundColor Magenta
[PSCustomObject]@{
    GroupeCréé      = $GroupName
    GroupeID        = $NewGroup.Id
    TypeGroupe      = "M365 Unified Group"
    MailEnabled     = $true
    SecurityEnabled = $false
    MembresInjectés = $Members.Count
    UsagePurview    = "Cible Label Policy Purview — exercice 2d (NormandySR2)"
    StatutVérif     = if ($CheckGroup) { "Confirmé dans Graph" } else { "Non vérifié" }
} | Format-List

# ========================================================================================
# NETTOYAGE MÉMOIRE
# ========================================================================================
Remove-Variable GroupName, MailNickname, ExistingGroup, GroupParams, NewGroup,
                Members, Upn, User, CheckGroup, CheckMembers `
                -ErrorAction SilentlyContinue

# ========================================================================================
# FERMETURE — RESET DE SESSION TOTAL
# ========================================================================================
Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
Write-Host "Session MgGraph fermée proprement." -ForegroundColor Magenta
