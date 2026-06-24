# ========================================================================================
# Exercice 5c : Entra ID — Conditional Access — Block Legacy Authentication
# ========================================================================================
# Concept : Les protocoles d'authentification legacy (SMTP, IMAP, POP3, ActiveSync,
# MAPI) ne supportent pas le MFA interactif. Un attaquant peut les utiliser pour
# contourner CA001 (MFA obligatoire) — même si la politique est active, une connexion
# IMAP passe en dehors du flux CA standard et ignore l'exigence MFA.
#
# Ce que fait ce script :
#   1. Reset total de session
#   2. Recherche un nom de politique disponible (auto-incrément)
#   3. Crée la politique de blocage legacy en mode Report-Only
#   4. Vérifie la création depuis la source de vérité
#   5. Ferme proprement toutes les sessions
#
# CA002 est la deuxième politique fondamentale dans toute organisation sécurisée,
# après CA001 (MFA obligatoire). Sans elle, CA001 seul est contournable.
#
# State : "enabledForReportingButNotEnforced" (Report-Only)
# ATTENTION : activer cette politique en production peut casser des clients mail
# legacy (Outlook 2010 et antérieurs, applications utilisant SMTP authentifié,
# équipements réseau qui envoient des alertes par mail).
# Toujours valider l'impact dans les Sign-in logs en Report-Only avant activation.
#
# Protocoles ciblés par ClientAppTypes :
#   "exchangeActiveSync" → protocole ActiveSync (mobiles legacy, clients EAS)
#   "other"              → SMTP, IMAP, POP3, MAPI, et tous les protocoles
#                          non-modernes ne supportant pas l'authentification moderne
#
# Pas d'exclusion break-glass nécessaire ici :
#   Les comptes break-glass se connectent via navigateur (flux moderne) —
#   ils ne sont jamais impactés par un blocage des protocoles legacy.
#
# Module requis : Microsoft.Graph.Identity.SignIns
# Connexion     : Connect-MgGraph
# ========================================================================================

# --- OUVERTURE — RESET DE SESSION TOTAL ---
# Policy.ReadWrite.ConditionalAccess suffit — pas de lecture de groupes ici.
# -ContextScope Process : bypasse le cache WAM (Windows Authentication Manager).
# REX : sans ce paramètre, WAM réutilise un token de session précédente avec des
# scopes insuffisants — cause la plus fréquente des 403 silencieux sur les scripts CA.
$Scopes = @(
    "Policy.ReadWrite.ConditionalAccess"
)

Disconnect-MgGraph -ErrorAction SilentlyContinue
Connect-MgGraph -Scopes $Scopes -ContextScope Process -NoWelcome

# ========================================================================================
# ÉTAPE 1 : Définition des variables
# ========================================================================================
Write-Host "1. Définition des variables..." -ForegroundColor Cyan

$PolicyBaseName = "CA002 - Block Legacy Authentication"

# Convention de nommage : préfixe numéroté CA002 — s'insère après CA001 (MFA obligatoire)
# dans l'ordre logique de lecture des politiques dans le portail Entra.
Write-Host "-> Politique cible : $PolicyBaseName`n" -ForegroundColor Green

# ========================================================================================
# ÉTAPE 2 : Recherche d'un nom de politique disponible (auto-incrément)
# ========================================================================================
Write-Host "2. Recherche d'un nom de politique disponible..." -ForegroundColor Cyan

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
# ÉTAPE 3 : Construction et création de la politique CA
# ========================================================================================
Write-Host "3. Création de la politique '$PolicyName'..." -ForegroundColor Cyan

# Différence fondamentale vs CA001 :
#   CA001 → cible TOUS les flux d'authentification, exige MFA
#   CA002 → cible UNIQUEMENT les protocoles legacy, bloque sans alternative
#
# Le blocage total ("block") est intentionnel ici : les protocoles legacy ne peuvent
# pas présenter de MFA interactif — il n'y a pas d'alternative possible.
# On ne peut pas "exiger MFA" sur un protocole qui ne le supporte pas.
# Le seul traitement valide est le blocage.
#
# IncludeUsers = @("All") sans exclusion break-glass :
#   Les comptes break-glass utilisent un navigateur (flux moderne) —
#   ClientAppTypes "exchangeActiveSync"/"other" ne les concerne pas.
$PolicyParams = @{
    DisplayName = $PolicyName
    State       = "enabledForReportingButNotEnforced"

    Conditions = @{
        Users = @{
            IncludeUsers = @("All")
        }
        Applications = @{
            IncludeApplications = @("All")
        }
        # ClientAppTypes : c'est le filtre clé de cette politique.
        # Sans cette condition, la politique s'appliquerait à tous les flux
        # d'authentification — y compris les flux modernes déjà couverts par CA001.
        # Avec cette condition : seules les connexions via protocoles legacy matchent.
        #
        # "exchangeActiveSync" → protocole EAS : mobiles configurés en mode Exchange
        #                        natif, clients Outlook legacy sur mobile
        # "other"              → regroupe SMTP AUTH, IMAP, POP3, MAPI over HTTP,
        #                        et tout protocole n'utilisant pas l'auth moderne OIDC/OAuth2
        ClientAppTypes = @("exchangeActiveSync", "other")
    }

    GrantControls = @{
        Operator        = "OR"
        BuiltInControls = @("block")
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
# ÉTAPE 4 : Vérification depuis la source de vérité
# ========================================================================================
Write-Host "4. Vérification depuis Entra..." -ForegroundColor Cyan

# REX : la réplication des politiques CA est plus lente que celle des objets
# users/groupes. 30 secondes couvrent la latence de propagation Graph pour les objets CA.
Start-Sleep -Seconds 30

try {
    $CheckPolicy = Get-MgIdentityConditionalAccessPolicy `
        -ConditionalAccessPolicyId $NewPolicy.Id `
        -ErrorAction Stop

    Write-Host "-> Politique confirmée :" -ForegroundColor Green
    [PSCustomObject]@{
        Id              = $CheckPolicy.Id
        DisplayName     = $CheckPolicy.DisplayName
        State           = $CheckPolicy.State
        ClientAppTypes  = ($CheckPolicy.Conditions.ClientAppTypes -join ", ")
        GrantControl    = "block"
    } | Format-List
}
catch {
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
    Exclusion       = "Aucune (break-glass non impacté par les protocoles legacy)"
    ProtocolesBloqués = "exchangeActiveSync, other (SMTP, IMAP, POP3, MAPI...)"
    GrantControl    = "block (blocage total — pas d'alternative MFA possible)"
    ActivationProd  = "Passer State à 'enabled' après validation des Sign-in logs"
    Prérequis       = "Identifier et migrer les clients legacy avant activation"
} | Format-List

# ========================================================================================
# NETTOYAGE MÉMOIRE
# ========================================================================================
Remove-Variable Scopes, PolicyBaseName, PolicyName, Counter,
                PolicyParams, NewPolicy, CheckPolicy `
                -ErrorAction SilentlyContinue

# ========================================================================================
# FERMETURE — RESET DE SESSION TOTAL
# ========================================================================================
Disconnect-MgGraph -ErrorAction SilentlyContinue
Write-Host "Session MgGraph fermée proprement." -ForegroundColor Magenta
