# ========================================================================================
# Exercice 5b : Conditional Access — Require MFA for All Users (Break-Glass Excluded)
# ========================================================================================
# Concept : Politique CA de base présente dans toute organisation.
# Toute tentative de connexion déclenche une demande MFA,
# sauf pour le groupe break-glass (accès d'urgence si MFA indisponible).
#
# State : Report-Only — bonne pratique prod. On observe l'impact avant d'activer.
# Jamais activer une politique CA directement en prod sans phase de test.
#
# Astuce technique : -ContextScope Process force une session PowerShell isolée
# qui bypasse le cache WAM (Web Account Manager).
# WAM = gestionnaire de tokens Windows qui réutilise les anciens tokens
# même quand on demande de nouveaux scopes — ce qui causait les 403 précédents.
# ========================================================================================

# --- ÉTAPE 1 : Connexion à Microsoft Graph ---
# Policy.ReadWrite.ConditionalAccess : créer/modifier des politiques CA
# Group.Read.All : récupérer l'ID du groupe break-glass
# -ContextScope Process : session isolée — bypasse le cache WAM
# Sans ce paramètre, WAM réutilise l'ancien token et ignore les nouveaux scopes
$Scopes = @(
    "Policy.ReadWrite.ConditionalAccess",
    "Group.Read.All"
)

Disconnect-MgGraph -ErrorAction SilentlyContinue
Connect-MgGraph -Scopes $Scopes -ContextScope Process

# --- ÉTAPE 2 : Définition des variables ---
$PolicyName     = "CA001 - Require MFA for All Users"
$BreakGlassName = "MagicOps-Dynamic-Team"

# --- ÉTAPE 3 : Récupération du groupe break-glass ---
# On exclut ce groupe de la politique — accès d'urgence si MFA indisponible
# Convention : préfixe numéroté CA001, CA002... pour la lisibilité dans le portail
Write-Host "1. Récupération du groupe break-glass '$BreakGlassName'..." -ForegroundColor Cyan

$BreakGlassGroup = Get-MgGroup -Filter "displayName eq '$BreakGlassName'" -ErrorAction Stop

if (-not $BreakGlassGroup) {
    Write-Error "Groupe '$BreakGlassName' introuvable."
    return
}

Write-Host "-> Groupe trouvé : $($BreakGlassGroup.Id)`n" -ForegroundColor Green

# --- ÉTAPE 4 : Construction de la politique CA ---
# Une politique CA se compose de 3 blocs :
#   - Conditions    : qui est ciblé (users, apps, platforms, risques)
#   - GrantControls : ce qu'on exige si les conditions sont remplies
#   - SessionControls : restrictions de session (optionnel)
#
# Ici : tous les users sauf le break-glass → MFA obligatoire
$PolicyParams = @{
    DisplayName = $PolicyName

    # Report-Only = évaluée mais pas appliquée
    # Valeurs : "enabled" / "disabled" / "enabledForReportingButNotEnforced"
    State       = "enabledForReportingButNotEnforced"

    Conditions  = @{
        Users = @{
            # Tous les utilisateurs du tenant
            IncludeUsers  = @("All")
            # Sauf le groupe break-glass — accès d'urgence garanti
            ExcludeGroups = @($BreakGlassGroup.Id)
        }
        # Toutes les apps Entra ID — les workloads non-interactifs ne sont pas impactés
        Applications = @{
            IncludeApplications = @("All")
        }
    }

    GrantControls = @{
        # "OR" = une condition suffit / "AND" = toutes obligatoires
        Operator        = "OR"
        BuiltInControls = @("mfa")
    }
}

# --- ÉTAPE 5 : Création de la politique ---
Write-Host "2. Création de la politique '$PolicyName'..." -ForegroundColor Cyan

try {
    $NewPolicy = New-MgIdentityConditionalAccessPolicy -BodyParameter $PolicyParams -ErrorAction Stop
    Write-Host "-> Succès : Politique créée avec l'ID : $($NewPolicy.Id)" -ForegroundColor Green
    Write-Host "-> State : $($NewPolicy.State) (Report-Only — non appliquée)" -ForegroundColor Yellow
}
catch {
    Write-Host "-> Échec de création : $_" -ForegroundColor Red
}

# --- ÉTAPE 6 : Vérification depuis Entra (source de vérité) ---
# 5 secondes — réplication CA plus lente que les objets users/groupes
Write-Host "3. Attente de la réplication Azure (10s)..." -ForegroundColor Cyan
Start-Sleep -Seconds 10

try {
    Get-MgIdentityConditionalAccessPolicy -ConditionalAccessPolicyId $NewPolicy.Id -ErrorAction Stop |
        Select-Object Id, DisplayName, State
}
catch {
    Write-Host "-> Politique créée mais pas encore répliquée sur ce nœud." -ForegroundColor Yellow
    Write-Host "-> Vérifie dans Entra Admin Center — elle y est." -ForegroundColor Yellow
}

# --- ÉTAPE 7 : Nettoyage ---
Remove-Variable Scopes, PolicyName, BreakGlassName, BreakGlassGroup, `
                PolicyParams, NewPolicy -ErrorAction SilentlyContinue

Write-Host "`nMémoire locale nettoyée. Session Microsoft Graph toujours active." -ForegroundColor Magenta
