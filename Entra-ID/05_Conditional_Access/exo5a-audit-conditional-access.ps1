# ========================================================================================
# Exercice 5a : Entra ID — Conditional Access — Audit des politiques du tenant
# ========================================================================================
# Concept : Le Conditional Access (CA) est le moteur de contrôle d'accès conditionnel
# d'Entra ID. Chaque politique évalue des conditions (qui, depuis où, avec quoi)
# et applique des grant controls (bloquer, exiger MFA, exiger poste conforme, etc.).
#
# Ce que fait ce script :
#   1. Reset total de session
#   2. Récupère toutes les politiques CA du tenant
#   3. Affiche un inventaire global (Id, Nom, État)
#   4. Détaille les politiques par état (actives / report-only / désactivées)
#   5. Ferme proprement toutes les sessions
#
# Cas d'usage réel : un consultant IAM arrive en mission et veut un état des lieux
# complet des politiques CA en place en moins d'une minute — sans toucher à aucun objet.
#
# États possibles d'une politique CA :
#   "enabled"                          → active, évaluée ET appliquée en production
#   "enabledForReportingButNotEnforced" → Report-Only : évaluée, loggée, mais pas bloquante
#                                         Bonne pratique avant toute activation en prod —
#                                         permet d'observer l'impact sans risque utilisateur
#   "disabled"                         → désactivée, n'évalue rien, n'applique rien
#
# Architecture d'une politique CA :
#   Conditions    → qui (users/groupes), depuis où (named locations, pays),
#                   avec quoi (apps, plateformes, device compliance)
#   Grant Controls → bloquer, exiger MFA, exiger poste Intune conforme,
#                    exiger Hybrid Azure AD Join, etc.
#   Session Controls → fréquence de reconnexion, persistance de session, app enforced
#
# Module requis : Microsoft.Graph.Identity.SignIns
# Connexion     : Connect-MgGraph
# ========================================================================================

# --- OUVERTURE — RESET DE SESSION TOTAL ---
# Policy.Read.All suffit — ce script ne fait que lire.
# Pas besoin du service principal SP-IAM-Lab — le ClientId par défaut du SDK Graph
# supporte ce scope en délégué (contexte utilisateur connecté).
#
# REX : sur les scripts CA, -ContextScope Process est particulièrement important.
# Le cache WAM mémorise les tokens par application — une session précédente ouverte
# sans Policy.Read.All retourne un token valide structurellement mais sans le scope
# nécessaire, ce qui provoque un 403 silencieux sur Get-MgIdentityConditionalAccessPolicy.
$Scopes = @(
    "Policy.Read.All"
)

Disconnect-MgGraph -ErrorAction SilentlyContinue
Connect-MgGraph -Scopes $Scopes -ContextScope Process -NoWelcome

# ========================================================================================
# ÉTAPE 1 : Récupération de toutes les politiques CA
# ========================================================================================
Write-Host "`n1. Récupération des politiques Conditional Access..." -ForegroundColor Cyan

$Policies = Get-MgIdentityConditionalAccessPolicy -All

if (-not $Policies) {
    Write-Host "-> Aucune politique CA trouvée dans ce tenant." -ForegroundColor Yellow
    Disconnect-MgGraph -ErrorAction SilentlyContinue
    return
}
Write-Host "-> $($Policies.Count) politique(s) CA trouvée(s).`n" -ForegroundColor Green

# ========================================================================================
# ÉTAPE 2 : Inventaire global
# ========================================================================================
Write-Host "=== POLITIQUES CONDITIONAL ACCESS — INVENTAIRE GLOBAL ===" -ForegroundColor Cyan

# Vue synthétique : Id, Nom, État — point de départ pour identifier ce qui existe.
# L'Id est utile pour les scripts d'écriture (5b) qui ciblent une politique par Id.
$Policies | Select-Object Id, DisplayName, State | Format-Table -AutoSize

# ========================================================================================
# ÉTAPE 3 : Détail par état
# ========================================================================================

# --- Politiques ACTIVES ---
# Évaluées ET appliquées — un utilisateur ciblé par une politique "enabled"
# se verra bloquer ou contraindre (MFA, poste conforme, etc.) si les conditions matchent.
$Enabled = $Policies | Where-Object { $_.State -eq "enabled" }
Write-Host "`n--- Politiques ACTIVES ($($Enabled.Count)) ---" -ForegroundColor Green
if ($Enabled) {
    $Enabled | Select-Object DisplayName, State | Format-Table -AutoSize
} else {
    Write-Host "-> Aucune politique active." -ForegroundColor Yellow
}

# --- Politiques REPORT-ONLY ---
# Évaluées et loggées dans les Sign-in logs Entra, mais pas bloquantes.
# DÉCOUVERTE TECHNIQUE : en Report-Only, la politique apparaît dans les logs sous
# "conditionalAccessPolicies" avec le résultat "reportOnly" — visible dans
# Entra ID > Sign-in logs > détail d'une connexion > onglet Conditional Access.
# Bonne pratique systématique avant toute activation en production :
# observer l'impact réel sur les utilisateurs sans risque de blocage.
$ReportOnly = $Policies | Where-Object { $_.State -eq "enabledForReportingButNotEnforced" }
Write-Host "`n--- Politiques REPORT-ONLY ($($ReportOnly.Count)) ---" -ForegroundColor Yellow
if ($ReportOnly) {
    $ReportOnly | Select-Object DisplayName, State | Format-Table -AutoSize
} else {
    Write-Host "-> Aucune politique en Report-Only." -ForegroundColor Yellow
}

# --- Politiques DÉSACTIVÉES ---
# Existent dans le tenant mais n'évaluent rien — ni log, ni blocage.
# Présence possible : politiques en cours de conception, héritées d'un projet passé,
# ou volontairement suspendues sans suppression (pour conservation de la config).
$Disabled = $Policies | Where-Object { $_.State -eq "disabled" }
Write-Host "`n--- Politiques DÉSACTIVÉES ($($Disabled.Count)) ---" -ForegroundColor Red
if ($Disabled) {
    $Disabled | Select-Object DisplayName, State | Format-Table -AutoSize
} else {
    Write-Host "-> Aucune politique désactivée." -ForegroundColor Yellow
}

# ========================================================================================
# RÉSUMÉ
# ========================================================================================
Write-Host "`n=== RÉSUMÉ ===" -ForegroundColor Magenta
[PSCustomObject]@{
    TotalPolitiques = $Policies.Count
    Actives         = $Enabled.Count
    ReportOnly      = $ReportOnly.Count
    Désactivées     = $Disabled.Count
    Scope           = "Policy.Read.All (lecture seule)"
    Remarque        = "Les grant controls et conditions détaillées sont accessibles via `$Policies[n].Conditions et .GrantControls"
} | Format-List

Write-Host "=== FIN DE L'AUDIT ===" -ForegroundColor Green

# ========================================================================================
# NETTOYAGE MÉMOIRE
# ========================================================================================
Remove-Variable Scopes, Policies, Enabled, ReportOnly, Disabled `
    -ErrorAction SilentlyContinue

# ========================================================================================
# FERMETURE — RESET DE SESSION TOTAL
# ========================================================================================
Disconnect-MgGraph -ErrorAction SilentlyContinue
Write-Host "Session MgGraph fermée proprement." -ForegroundColor Magenta
