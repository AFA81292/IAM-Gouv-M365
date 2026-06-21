# ========================================================================================
# Exercice 5d : Adaptive Scope — ciblage dynamique par attribut département
# ========================================================================================
# Concept : un scope statique (5e) fige sa liste de membres à la création. Un Adaptive
# Scope, lui, est une REQUÊTE — il se recalcule en continu. Si un utilisateur change de
# département après coup, il entre ou sort automatiquement du périmètre, sans toucher à
# la policy qui consomme ce scope (cf. 5f).
#
# Piège de syntaxe : -FilterConditions n'est PAS une chaîne OPATH simple comme pour les
# groupes dynamiques Entra (cf. 4b, "(user.department -eq 'X')"). C'est une hashtable
# structurée : { Conditions = @(@{Value=...; Operator=...; Name=...}); Conjunction = "And" }.
# Les deux syntaxes ne sont pas interchangeables malgré la ressemblance conceptuelle.
#
# Propagation lente : il peut falloir jusqu'à 5 jours pour que la liste de membres se
# peuple — la création du scope est immédiate, son contenu réel ne l'est pas. On valide
# donc la requête à part via Get-User -Filter (même syntaxe OPATH, retour instantané)
# plutôt que d'attendre que le scope se peuple pour savoir si la logique est correcte.
#
# Thème Mass Effect : la Citadelle isole dynamiquement le personnel du département
# juridique — quiconque rejoint ou quitte "Legal" entre/sort du périmètre sans intervention.
#
# Module requis : ExchangeOnlineManagement
# Connexion : Connect-IPPSSession
# Licence requise : Microsoft Purview Records Management (inclus E5)
# ========================================================================================

# --- OUVERTURE ---
Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
Get-PSSession | Remove-PSSession
$env:MSAL_ENABLE_WAM = "0"
Connect-IPPSSession -UserPrincipalName GeptorAdmin@0n4mg.onmicrosoft.com

# --- ÉTAPE 1 : Recherche d'un nom disponible ---
Write-Host "1. Recherche d'un nom disponible..." -ForegroundColor Cyan

$BaseScopeName = "ASCOPE-Citadel-Legal"
$ScopeName     = $BaseScopeName
$Counter       = 2
while (Get-AdaptiveScope -Identity $ScopeName -ErrorAction SilentlyContinue) {
    $ScopeName = "$BaseScopeName-v$Counter"
    $Counter++
}
Write-Host "-> Nom retenu : '$ScopeName'`n" -ForegroundColor Green

# --- ÉTAPE 2 : Validation préalable de la requête (sans attendre la propagation) ---
# Get-User -Filter accepte la même syntaxe OPATH que celle encodée dans FilterConditions.
# On vérifie ici qu'au moins un utilisateur matche AVANT de créer un scope qui mettrait
# possiblement plusieurs jours à révéler que la requête ne retourne rien.
Write-Host "2. Validation de la requête (Department -eq 'Legal')..." -ForegroundColor Cyan

$TargetDepartment = "Legal"
$MatchingUsers = Get-User -Filter "{Department -eq '$TargetDepartment'}" -ErrorAction SilentlyContinue

if (-not $MatchingUsers) {
    Write-Host "-> ATTENTION : aucun utilisateur avec Department = '$TargetDepartment' trouvé." -ForegroundColor Yellow
    Write-Host "   Le scope sera créé mais restera vide tant qu'aucun utilisateur ne correspond." -ForegroundColor Yellow
} else {
    Write-Host "-> $($MatchingUsers.Count) utilisateur(s) correspondant(s) trouvé(s).`n" -ForegroundColor Green
}

# --- ÉTAPE 3 : Création de l'Adaptive Scope ---
# FilterConditions : structure obligatoire, pas une chaîne. Un seul critère ici donc pas
# de tableau de Conditions imbriqué (cf. note d'en-tête pour la syntaxe à conditions multiples).
$FilterConditions = @{
    Conditions = @{
        Value    = $TargetDepartment
        Operator = "Equals"
        Name     = "Department"
    }
    Conjunction = "And"
}

try {
    $NewScope = New-AdaptiveScope `
        -Name             $ScopeName `
        -LocationType     "User" `
        -FilterConditions $FilterConditions `
        -Comment          "Exo 5d — Périmètre dynamique département Legal." `
        -ErrorAction Stop

    Write-Host "3. Scope créé : $($NewScope.Name)`n" -ForegroundColor Green
}
catch {
    Write-Host "-> Échec création : $_" -ForegroundColor Red
    Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
    Get-PSSession | Remove-PSSession
    return
}

# --- ÉTAPE 4 : Vérification depuis la source de vérité ---
Write-Host "4. Vérification..." -ForegroundColor Cyan
Start-Sleep -Seconds 30

$CheckScope = Get-AdaptiveScope -Identity $ScopeName -ErrorAction SilentlyContinue

if ($CheckScope) {
    [PSCustomObject]@{
        Nom          = $CheckScope.Name
        LocationType = $CheckScope.LocationType
    } | Format-List
} else {
    Write-Host "-> ATTENTION : scope non trouvé lors de la vérification." -ForegroundColor Red
}

# --- RÉSUMÉ ---
Write-Host "=== RÉSUMÉ ===" -ForegroundColor Magenta
Write-Host "Population des membres : jusqu'à 5 jours avant que le scope reflète" -ForegroundColor Yellow
Write-Host "la liste réelle des utilisateurs Legal. Validation immédiate effectuée" -ForegroundColor Yellow
Write-Host "via Get-User -Filter à l'étape 2 (logique de requête confirmée séparément).`n" -ForegroundColor Yellow

[PSCustomObject]@{
    ScopeCréé          = $ScopeName
    Critère            = "Department -eq '$TargetDepartment'"
    UtilisateursValidés = if ($MatchingUsers) { $MatchingUsers.Count } else { 0 }
} | Format-List

Write-Host "Utilisation : cf. exo 5f (Retention Policy avec Adaptive Scope).`n" -ForegroundColor Yellow

# --- NETTOYAGE MÉMOIRE ---
Remove-Variable BaseScopeName, ScopeName, Counter, TargetDepartment, MatchingUsers,
                FilterConditions, NewScope, CheckScope `
                -ErrorAction SilentlyContinue

# --- FERMETURE ---
Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
Get-PSSession | Remove-PSSession
Write-Host "Sessions fermées proprement." -ForegroundColor Magenta
