# ========================================================================================
# Exercice 5b : Entra ID — Conditional Access — Require MFA for All Users
#               (Break-Glass exclu)
# ========================================================================================
# Concept : Politique CA fondamentale présente dans toute organisation sécurisée.
# Toute tentative de connexion déclenche une exigence MFA, sauf pour le groupe
# break-glass — compte d'urgence garanti si MFA est indisponible à l'échelle du tenant.
#
# Ce que fait ce script :
#   1. Reset total de session
#   2. Recherche un nom de politique disponible (auto-incrément)
#   3. Récupère le groupe break-glass (exclu de la politique)
#   4. Crée la politique CA en mode Report-Only
#   5. Vérifie la création depuis la source de vérité
#   6. Ferme proprement toutes les sessions
#
# State : "enabledForReportingButNotEnforced" (Report-Only)
# Bonne pratique systématique : observer l'impact sur les Sign-in logs avant
# toute activation en production. Ne jamais passer directement en "enabled"
# sans phase de test — risque de blocage massif des utilisateurs.
#
# Architecture de la politique :
#   Conditions    → tous les utilisateurs sauf le groupe break-glass,
#                   toutes les applications
#   GrantControls → MFA obligatoire (operator OR = un seul contrôle suffit)
#
# DÉCOUVERTE TECHNIQUE : -ContextScope Process force une session PowerShell isolée
# qui bypasse le cache WAM (Windows Authentication Manager).
# WAM mémorise les tokens par application et les réutilise même quand on demande
# de nouveaux scopes — les erreurs 403 sur Policy.ReadWrite.ConditionalAccess
# sans ce paramètre en sont la cause la plus fréquente.
#
# Module requis : Microsoft.Graph.Identity.SignIns, Microsoft.Graph.Groups
# Connexion     : Connect-MgGraph
# ========================================================================================

# --- OUVERTURE — RESET DE SESSION TOTAL ---
# Policy.ReadWrite.ConditionalAccess : créer/modifier des politiques CA
# Group.Read.All : récupérer l'ID du groupe break-glass pour l'exclusion
$Scopes = @(
    "Policy.ReadWrite.ConditionalAccess",
    "Group.Read.All"
)

Disconnect-MgGraph -ErrorAction SilentlyContinue
Connect-MgGraph -Scopes $Scopes -ContextScope Process -NoWelcome

# ========================================================================================
# ÉTAPE 1 : Définition des variables
# ========================================================================================
Write-Host "1. Définition des variables..." -ForegroundColor Cyan

$PolicyBaseName = "CA001 - Require MFA for All Users"
$BreakGlassName = "MagicOps-Dynamic-Team"

# Convention de nommage CA : préfixe numéroté (CA001, CA002...) pour la lisibilité
# dans le portail Entra et dans les Sign-in logs. Permet d'ordonner les politiques
# par priorité logique et de les référencer facilement en incident.

Write-Host "-> Politique cible  : $PolicyBaseName" -ForegroundColor Green
Write-Host "-> Groupe break-glass : $BreakGlassName`n" -ForegroundColor Green

# ========================================================================================
# ÉTAPE 2 : Recherche d'un nom de politique disponible (auto-incrément)
# ========================================================================================
Write-Host "2. Recherche d'un nom de politique disponible..." -ForegroundColor Cyan

# DÉCOUVERTE TECHNIQUE : contrairement aux groupes, Graph impose l'unicité du DisplayName
# sur les politiques CA — une tentative de création avec un nom existant retourne une
# erreur. L'auto-incrément évite ce conflit sur le tenant de dev.
$PolicyName = $PolicyBaseName
$Counter    = 2
while (
    Get-MgIdentityConditionalAccessPolicy -All -ErrorAction SilentlyContinue |
    Where-Object { $_.DisplayName -eq $PolicyName }
) {
    Write-Host "   '$PolicyName' déjà pris — test avec suffixe -v$Counter..." -ForegroundColor Yellow
    $PolicyName = "$PolicyBaseName-v$Counter"
    $Counter++
}
Write-Host "-> Nom retenu pour la politique : '$PolicyName'`n" -ForegroundColor Green

# ========================================================================================
# ÉTAPE 3 : Récupération du groupe break-glass
# ========================================================================================
Write-Host "3. Récupération du groupe break-glass '$BreakGlassName'..." -ForegroundColor Cyan

# Le groupe break-glass est exclu de la politique MFA.
# Raison : si le service MFA est indisponible (panne Azure MFA, urgence critique),
# les comptes break-glass doivent pouvoir se connecter sans blocage.
# En production : le groupe break-glass contient 2 comptes max, sans licence,
# avec MDP complexe, stocké dans un coffre physique sécurisé.
$BreakGlassGroup = Get-MgGroup -Filter "displayName eq '$BreakGlassName'" -ErrorAction Stop

if (-not $BreakGlassGroup) {
    Write-Host "-> Erreur : groupe '$BreakGlassName' introuvable dans le tenant." -ForegroundColor Red
    Disconnect-MgGraph -ErrorAction SilentlyContinue
    return
}
Write-Host "-> Groupe trouvé : $($BreakGlassGroup.DisplayName) [ID : $($BreakGlassGroup.Id)]`n" -ForegroundColor Green

# ========================================================================================
# ÉTAPE 4 : Construction et création de la politique CA
# ========================================================================================
Write-Host "4. Création de la politique '$PolicyName'..." -ForegroundColor Cyan

# Une politique CA se compose de 3 blocs :
#   Conditions     : qui est ciblé (users, apps, platforms, niveaux de risque)
#   GrantControls  : ce qu'on exige si les conditions sont remplies
#   SessionControls: restrictions de session — non utilisé ici
#
# IncludeUsers = @("All") : tous les utilisateurs du tenant, internes et invités B2B.
# ExcludeGroups : liste des groupes exemptés — ici uniquement le break-glass.
#   En production : on y ajoute aussi les comptes de service et les pipelines
#   d'automatisation qui ne supportent pas le MFA interactif.
#
# IncludeApplications = @("All") : toutes les applications enregistrées dans Entra.
#   Les workloads non-interactifs (daemon apps, service principals) ne sont pas
#   impactés par les politiques CA ciblant les utilisateurs — ils passent par
#   le flux client_credentials, hors périmètre du CA utilisateur.
#
# Operator = "OR" : une seule condition de grant suffit pour satisfaire la politique.
#   "AND" = toutes les conditions doivent être satisfaites simultanément
#   (ex : MFA ET poste Intune conforme ET Hybrid Azure AD Join).
$PolicyParams = @{
    DisplayName = $PolicyName
    State       = "enabledForReportingButNotEnforced"

    Conditions = @{
        Users = @{
            IncludeUsers  = @("All")
            ExcludeGroups = @($BreakGlassGroup.Id)
        }
        Applications = @{
            IncludeApplications = @("All")
        }
    }

    GrantControls = @{
        Operator        = "OR"
        BuiltInControls = @("mfa")
    }
}

try {
    $NewPolicy = New-MgIdentityConditionalAccessPolicy -BodyParameter $PolicyParams -ErrorAction Stop
    Write-Host "-> Politique créée : $($NewPolicy.DisplayName) [ID : $($NewPolicy.Id)]" -ForegroundColor Green
    Write-Host "-> State : $($NewPolicy.State)`n" -ForegroundColor Yellow
}
catch {
    Write-Host "-> Échec de la création : $_" -ForegroundColor Red
    Disconnect-MgGraph -ErrorAction SilentlyContinue
    return
}

# ========================================================================================
# ÉTAPE 5 : Vérification depuis la source de vérité
# ========================================================================================
Write-Host "5. Vérification depuis Entra..." -ForegroundColor Cyan

# REX : la réplication des politiques CA est plus lente que celle des objets
# users/groupes. Get-MgIdentityConditionalAccessPolicy relu immédiatement après
# la création peut retourner une erreur 404 même si la politique existe côté backend.
# 30 secondes couvrent la latence de propagation Graph pour les objets CA.
Start-Sleep -Seconds 30

try {
    $CheckPolicy = Get-MgIdentityConditionalAccessPolicy `
        -ConditionalAccessPolicyId $NewPolicy.Id `
        -ErrorAction Stop

    Write-Host "-> Politique confirmée :" -ForegroundColor Green
    [PSCustomObject]@{
        Id          = $CheckPolicy.Id
        DisplayName = $CheckPolicy.DisplayName
        State       = $CheckPolicy.State
        BreakGlass  = "Exclu : $BreakGlassName [$($BreakGlassGroup.Id)]"
    } | Format-List
}
catch {
    # La politique est créée côté backend mais pas encore répliquée sur ce nœud Graph.
    # Vérifiable immédiatement dans Entra Admin Center > Protection > Conditional Access.
    Write-Host "-> Politique créée mais réplication encore en cours." -ForegroundColor Yellow
    Write-Host "   ID : $($NewPolicy.Id) — vérifier dans Entra Admin Center." -ForegroundColor Yellow
}

# ========================================================================================
# RÉSUMÉ
# ========================================================================================
Write-Host "=== RÉSUMÉ ===" -ForegroundColor Magenta
[PSCustomObject]@{
    PolitiqueCréée  = $PolicyName
    PolitiqueID     = $NewPolicy.Id
    State           = "Report-Only (non appliquée)"
    Cible           = "Tous les utilisateurs"
    Exclusion       = "$BreakGlassName [$($BreakGlassGroup.Id)]"
    GrantControl    = "MFA obligatoire (OR)"
    Applications    = "Toutes"
    ActivationProd  = "Passer State à 'enabled' après validation des Sign-in logs"
} | Format-List

# ========================================================================================
# NETTOYAGE MÉMOIRE
# ========================================================================================
Remove-Variable Scopes, PolicyBaseName, PolicyName, BreakGlassName,
                BreakGlassGroup, Counter, PolicyParams, NewPolicy, CheckPolicy `
                -ErrorAction SilentlyContinue

# ========================================================================================
# FERMETURE — RESET DE SESSION TOTAL
# ========================================================================================
Disconnect-MgGraph -ErrorAction SilentlyContinue
Write-Host "Session MgGraph fermée proprement." -ForegroundColor Magenta
