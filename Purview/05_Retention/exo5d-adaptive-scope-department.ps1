# ========================================================================================
# Exercice 5d : Adaptive Scope — ciblage dynamique par attribut département
# ========================================================================================
# Concept : un scope statique (5e) fige sa liste de membres à la création. Un Adaptive
# Scope, lui, est une REQUÊTE — il se recalcule en continu. Si un utilisateur change de
# département après coup, il entre ou sort automatiquement du périmètre, sans toucher à
# la policy qui consomme ce scope (cf. 5f).
#
# Delta pédagogique vs 5e/5f :
#   5d → Adaptive Scope : requête dynamique, membres recalculés en continu
#   5e → Static Scope   : liste figée à la création, mise à jour manuelle nécessaire
#   5f → Retention Policy avec Adaptive Scope : consomme le scope créé ici
#        La policy ne change pas quand des utilisateurs rejoignent ou quittent Legal —
#        c'est le scope qui se met à jour, pas la policy.
#
# Deux pièges documentés sur cet exercice :
#
#   Piège n°1 — syntaxe -FilterConditions :
#     -FilterConditions n'est PAS une chaîne OPATH simple comme pour les groupes
#     dynamiques Entra (cf. 4b). C'est une hashtable structurée :
#     @{ Conditions = @(@{ Value=...; Operator=...; Name=... }); Conjunction = "And" }
#     Cette structure imbriquée est source d'erreurs et n'est pas utilisée ici.
#
#   Piège n°2 — bug confirmé -FilterConditions (rencontré en test réel) :
#     -FilterConditions échoue avec "Unexpected value type for key 'Conditions'.
#     Expected type: System.Object[]" — y compris en suivant l'exemple officiel
#     Microsoft Learn au mot près. Confirmé par d'autres administrateurs en ligne
#     (practical365.com : "Even the example in [Microsoft Learn] doesn't work.
#     I've reported the issue to Microsoft").
#     Solution retenue : -RawQuery, parameter set alternatif et MUTUELLEMENT EXCLUSIF
#     avec -FilterConditions. Il attend une simple chaîne OPATH — même syntaxe que
#     les groupes dynamiques Entra — et contourne complètement le chemin de code buggué.
#
# Propagation lente :
#   La création du scope est immédiate, mais son contenu réel peut mettre jusqu'à 5 jours
#   à se peupler. On valide donc la logique de la requête séparément via Get-User -Filter
#   (même syntaxe OPATH, retour instantané) — pas besoin d'attendre 5 jours pour savoir
#   si la requête est correcte.
#
# Thème Mass Effect : la Citadelle isole dynamiquement le personnel juridique —
# quiconque rejoint ou quitte "Legal" entre/sort du périmètre sans intervention manuelle.
#
# Ce que fait ce script :
#   1. Reset total de session
#   2. Recherche un nom de scope disponible (auto-incrément)
#   3. Valide la requête en amont via Get-User -Filter (retour instantané)
#   4. Crée l'Adaptive Scope avec -RawQuery (contournement bug -FilterConditions)
#   5. Vérifie la création depuis la source de vérité
#   6. Affiche un résumé
#   7. Ferme proprement toutes les sessions
#
# Module requis : ExchangeOnlineManagement
# Connexion     : Connect-IPPSSession
# Licence       : Microsoft Purview Records Management (inclus E5)
# ========================================================================================

# --- OUVERTURE — RESET DE SESSION TOTAL ---
# REX : des sessions fantômes restées ouvertes depuis un script précédent peuvent
# provoquer des erreurs silencieuses ou des authentifications croisées.
# On purge TOUT avant de commencer, sans exception.
#
# Ordre : Disconnect-ExchangeOnline → Remove-PSSession → workaround WAM → reconnexion.
# Note : Connect-IPPSSession ne supporte pas -ShowBanner:$false — bandeau normal.
Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
Get-PSSession | Remove-PSSession
$env:MSAL_ENABLE_WAM = "0"
Connect-IPPSSession -UserPrincipalName GeptorAdmin@0n4mg.onmicrosoft.com

# ========================================================================================
# ÉTAPE 1 : Recherche d'un nom disponible (auto-incrément)
# ========================================================================================
Write-Host "1. Recherche d'un nom disponible..." -ForegroundColor Cyan

$BaseScopeName = "ASCOPE-Citadel-Legal"
$ScopeName     = $BaseScopeName
$Counter       = 2
while (Get-AdaptiveScope -Identity $ScopeName -ErrorAction SilentlyContinue) {
    Write-Host "   '$ScopeName' déjà pris — test avec suffixe -v$Counter..." -ForegroundColor Yellow
    $ScopeName = "$BaseScopeName-v$Counter"
    $Counter++
}
Write-Host "-> Nom retenu : '$ScopeName'`n" -ForegroundColor Green

# ========================================================================================
# ÉTAPE 2 : Validation préalable de la requête
# ========================================================================================
Write-Host "2. Validation de la requête (Department -eq 'Legal')..." -ForegroundColor Cyan
Start-Sleep -Seconds 30

# Get-User -Filter accepte exactement la même syntaxe OPATH que celle encodée dans
# -RawQuery. On valide ici qu'au moins un utilisateur matche AVANT de créer le scope.
#
# Pourquoi valider séparément ?
#   Le scope peut mettre jusqu'à 5 jours à se peupler après création.
#   Si la requête est incorrecte (faute de frappe dans le département, attribut vide),
#   on ne le saurait qu'au bout de 5 jours. Get-User -Filter répond instantanément
#   et confirme que la logique est correcte — indépendamment de la propagation.
$TargetDepartment = "Legal"
$MatchingUsers = Get-User -Filter "{Department -eq '$TargetDepartment'}" -ErrorAction SilentlyContinue

if (-not $MatchingUsers) {
    Write-Host "-> ATTENTION : aucun utilisateur avec Department = '$TargetDepartment' trouvé." -ForegroundColor Yellow
    Write-Host "   Le scope sera créé mais restera vide tant qu'aucun utilisateur ne correspond." -ForegroundColor Yellow
    Write-Host "   Vérifier les attributs via : Get-User -Filter `"{Department -eq 'Legal'}`" | Select DisplayName, Department`n" -ForegroundColor Yellow
} else {
    Write-Host "-> $($MatchingUsers.Count) utilisateur(s) correspondant(s) trouvé(s)." -ForegroundColor Green
    $MatchingUsers | Select-Object DisplayName, Department | Format-Table -AutoSize
}

# ========================================================================================
# ÉTAPE 3 : Création de l'Adaptive Scope avec -RawQuery
# ========================================================================================
Write-Host "3. Création du scope '$ScopeName'..." -ForegroundColor Cyan

# -RawQuery est utilisé à la place de -FilterConditions — voir piège n°2 en en-tête.
#
# -LocationType "User" : le scope cible des boîtes aux lettres utilisateurs.
# Autres valeurs possibles :
#   "Site"           → sites SharePoint / OneDrive
#   "UnifiedGroup"   → groupes Microsoft 365
#
# La chaîne OPATH dans $RawQuery est identique à ce que Get-User -Filter accepte
# à l'étape 2 — cohérence garantie entre la validation et la requête du scope.
$RawQuery = "Department -eq '$TargetDepartment'"

try {
    $NewScope = New-AdaptiveScope `
        -Name         $ScopeName `
        -LocationType "User" `
        -RawQuery     $RawQuery `
        -Comment      "Exo 5d — Périmètre dynamique département Legal. Contournement bug -FilterConditions via -RawQuery." `
        -ErrorAction Stop

    Write-Host "-> Scope créé : $($NewScope.Name)`n" -ForegroundColor Green
}
catch {
    Write-Host "-> Échec création : $_" -ForegroundColor Red
    Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
    Get-PSSession | Remove-PSSession
    return
}

# ========================================================================================
# ÉTAPE 4 : Vérification depuis la source de vérité
# ========================================================================================
Write-Host "4. Vérification depuis le backend Purview..." -ForegroundColor Cyan

# Sleep 30s : latence de propagation standard après création d'un AdaptiveScope.
# Rappel : la liste des membres du scope prend jusqu'à 5 jours à se peupler —
# ce Sleep couvre uniquement la disponibilité de l'objet scope dans l'API,
# pas la résolution de ses membres.
Start-Sleep -Seconds 30

$CheckScope = Get-AdaptiveScope -Identity $ScopeName -ErrorAction SilentlyContinue

if ($CheckScope) {
    Write-Host "-> Scope confirmé :" -ForegroundColor Green
    [PSCustomObject]@{
        Nom          = $CheckScope.Name
        LocationType = $CheckScope.LocationType
        # RawQuery : vérification que la requête a bien été enregistrée telle quelle
        RawQuery     = $CheckScope.RawQuery
        Commentaire  = $CheckScope.Comment
    } | Format-List
} else {
    Write-Host "-> ATTENTION : scope non trouvé lors de la vérification." -ForegroundColor Red
    Write-Host "   Réplication peut être encore en cours — vérifier dans Purview Admin Center." -ForegroundColor Yellow
}

# ========================================================================================
# RÉSUMÉ
# ========================================================================================
Write-Host "=== RÉSUMÉ ===" -ForegroundColor Magenta
[PSCustomObject]@{
    ScopeCréé            = $ScopeName
    LocationType         = "User (boîtes aux lettres)"
    Critère              = "Department -eq '$TargetDepartment'"
    UtilisateursValidés  = if ($MatchingUsers) { $MatchingUsers.Count } else { 0 }
    PropagationMembres   = "Jusqu'à 5 jours (normal — scope créé, contenu en cours de calcul)"
    ValidationRequête    = "Effectuée via Get-User -Filter à l'étape 2 (instantané)"
    ÉtapeSuivante        = "Utilisation dans une Retention Policy : cf. exo 5f"
} | Format-List

# ========================================================================================
# NETTOYAGE MÉMOIRE
# ========================================================================================
Remove-Variable BaseScopeName, ScopeName, Counter, TargetDepartment, MatchingUsers,
                RawQuery, NewScope, CheckScope `
                -ErrorAction SilentlyContinue

# ========================================================================================
# FERMETURE — RESET DE SESSION TOTAL
# ========================================================================================
Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
Get-PSSession | Remove-PSSession
Write-Host "Sessions fermées proprement." -ForegroundColor Magenta
