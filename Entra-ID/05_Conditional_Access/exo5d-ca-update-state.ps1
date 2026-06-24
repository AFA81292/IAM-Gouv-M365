# ========================================================================================
# Exercice 5d : Entra ID — Conditional Access — Modifier l'état d'une politique existante
# ========================================================================================
# Concept : Cycle de vie d'une politique CA.
# En production, on ne passe jamais directement de "disabled" à "enabled".
# Le workflow standard en trois temps :
#   1. Créer en "disabled" ou "enabledForReportingButNotEnforced" (Report-Only)
#   2. Observer l'impact dans les Sign-in logs Entra (onglet Conditional Access)
#   3. Activer avec "enabled" une fois l'impact validé — zéro surprise utilisateur
#
# Ce script simule l'étape 3 — passage de Report-Only à Enabled —
# puis repasse en Report-Only pour ne pas impacter le tenant de lab.
#
# Ce que fait ce script :
#   1. Reset total de session
#   2. Récupère la politique CA001 par son nom
#   3. Affiche l'état actuel
#   4. Passe la politique en "enabled" (activation réelle)
#   5. Vérifie l'état depuis la source de vérité
#   6. Repasse en Report-Only (sécurité lab)
#   7. Vérifie l'état final
#   8. Ferme proprement toutes les sessions
#
# DÉCOUVERTE TECHNIQUE : Update-MgIdentityConditionalAccessPolicy avec -BodyParameter
# partiel fonctionne en mode PATCH HTTP — seules les propriétés fournies sont modifiées.
# Graph merge les modifications sans toucher aux autres propriétés de la politique
# (conditions, grant controls, etc.). Pas besoin de renvoyer l'objet complet.
#
# Module requis : Microsoft.Graph.Identity.SignIns
# Connexion     : Connect-MgGraph
# ========================================================================================

# --- OUVERTURE — RESET DE SESSION TOTAL ---
# Policy.ReadWrite.ConditionalAccess : lire et modifier des politiques CA.
# -ContextScope Process : bypasse le cache WAM (Windows Authentication Manager).
# REX : sans ce paramètre, WAM réutilise un token de session précédente avec des
# scopes insuffisants — cause la plus fréquente des 403 silencieux sur les scripts CA.
$Scopes = @(
    "Policy.ReadWrite.ConditionalAccess"
)

Disconnect-MgGraph
