# ========================================================================================
# Exercice 5c : Conditional Access — Block Legacy Authentication
# ========================================================================================
# Concept : Les protocoles legacy (SMTP, IMAP, POP3, Exchange ActiveSync, MAPI)
# ne supportent pas le MFA interactif. Un attaquant peut les utiliser pour
# contourner une politique MFA obligatoire — même si CA001 est en place.
# Cette politique bloque tous ces protocoles sur l'ensemble du tenant.
#
# C'est la politique CA numéro 2 dans toute organisation sécurisée,
# après le MFA obligatoire (CA001).
#
# State : Report-Only — observer l'impact avant activation.
# Attention : activer cette politique peut casser des vieux clients mail
# (Outlook 2010, applications legacy) — toujours tester en Report-Only d'abord.
#
# Astuce technique : -ContextScope Process bypasse le cache WAM.
# ========================================================================================

# --- ÉTAPE 1 : Connexion à Microsoft Graph ---
# Policy.ReadWrite.ConditionalAccess : créer/modifier des politiques CA
# -ContextScope Process : session isolée — bypasse le cache WAM
$Scopes = @(
    "Policy.ReadWrite.ConditionalAccess"
)

Disconnect-MgGraph -ErrorAction SilentlyContinue
Connect-MgGraph -Scopes $Scopes -ContextScope Process

# --- ÉTAPE 2 : Définition des variables ---
$PolicyName = "CA002 - Block Legacy Authentication"

# --- ÉTAPE 3 : Construction de la politique CA ---
# ClientAppTypes = les types de clients ciblés par la condition
# "exchangeActiveSync" = protocole ActiveSync (mobiles legacy)
# "other"             = tous les autres protocoles legacy (SMTP, IMAP, POP3, MAPI...)
# On cible TOUS les users et TOUTES les apps — pas d'exclusion
# Le seul moyen de se connecter en legacy c'est de bloquer — pas d'approbation possible
Write-Host "1. Construction de la politique '$PolicyName'..." -ForegroundColor Cyan

$PolicyParams = @{
    DisplayName = $PolicyName

    # Report-Only = évaluée mais pas appliquée
    # Passer à "enabled" uniquement après validation de l'impact en Report-Only
    State       = "enabledForReportingButNotEnforced"

    Conditions  = @{
        # Tous les utilisateurs — pas d'exclusion break-glass nécessaire
        # Les comptes break-glass n'utilisent pas de protocoles legacy
        Users = @{
            IncludeUsers = @("All")
        }
        Applications = @{
            IncludeApplications = @("All")
        }
        # C'est ICI la différence avec CA001 — on cible les protocoles legacy
        # exchangeActiveSync = ActiveSync (mobiles, clients legacy)
        # other = SMTP, IMAP, POP3, MAPI et tous les autres protocoles non-modernes
        ClientAppTypes = @("exchangeActiveSync", "other")
    }

    GrantControls = @{
        Operator        = "OR"
        # "block" = blocage total — pas de MFA, pas d'alternative
        # C'est intentionnel : les protocoles legacy ne peuvent pas faire de MFA
        BuiltInControls = @("block")
    }
}

# --- ÉTAPE 4 : Création de la politique ---
Write-Host "2. Création de la politique '$PolicyName'..." -ForegroundColor Cyan

try {
    $NewPolicy = New-MgIdentityConditionalAccessPolicy -BodyParameter $PolicyParams -ErrorAction Stop
    Write-Host "-> Succès : Politique créée avec l'ID : $($NewPolicy.Id)" -ForegroundColor Green
    Write-Host "-> State : $($NewPolicy.State) (Report-Only — non appliquée)" -ForegroundColor Yellow
}
catch {
    Write-Host "-> Échec de création : $_" -ForegroundColor Red
    return
}

# --- ÉTAPE 5 : Vérification depuis Entra (source de vérité) ---
# Réplication CA plus lente que les objets users/groupes — 10 secondes minimum
Write-Host "3. Attente de la réplication Azure (10s)..." -ForegroundColor Cyan
Start-Sleep -Seconds 10

try {
    Get-MgIdentityConditionalAccessPolicy -ConditionalAccessPolicyId $NewPolicy.Id -ErrorAction Stop |
        Select-Object Id, DisplayName, State
}
catch {
    Write-Host "-> Politique créée mais réplication en cours." -ForegroundColor Yellow
    Write-Host "-> ID : $($NewPolicy.Id) — vérifie dans Entra Admin Center." -ForegroundColor Yellow
}

# --- ÉTAPE 6 : Nettoyage ---
Remove-Variable Scopes, PolicyName, PolicyParams, NewPolicy -ErrorAction SilentlyContinue

Write-Host "`nMémoire locale nettoyée. Session Microsoft Graph toujours active." -ForegroundColor Magenta
