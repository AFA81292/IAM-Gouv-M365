# ========================================================================================
# Exercice 5d : Conditional Access — Modifier l'état d'une politique existante
# ========================================================================================
# Concept : Cycle de vie d'une politique CA.
# En prod, on ne passe jamais directement de "disabled" à "enabled".
# Le workflow standard :
#   1. Créer en "disabled" ou "enabledForReportingButNotEnforced" (Report-Only)
#   2. Observer l'impact dans les logs Sign-in
#   3. Activer avec "enabled" une fois l'impact validé
#
# Ce script simule l'étape 3 — passage de Report-Only à Enabled.
# On repassera en Report-Only à la fin pour ne pas impacter le tenant de lab.
#
# Astuce technique : -ContextScope Process bypasse le cache WAM.
# ========================================================================================

# --- ÉTAPE 1 : Connexion à Microsoft Graph ---
# Policy.ReadWrite.ConditionalAccess : modifier des politiques CA
# -ContextScope Process : session isolée — bypasse le cache WAM
$Scopes = @(
    "Policy.ReadWrite.ConditionalAccess"
)

Disconnect-MgGraph -ErrorAction SilentlyContinue
Connect-MgGraph -Scopes $Scopes -ContextScope Process

# --- ÉTAPE 2 : Définition des variables ---
# On cible CA001 — la politique MFA créée à l'exo 5b
$PolicyName = "CA001 - Require MFA for All Users"

# --- ÉTAPE 3 : Récupération de la politique existante ---
# On cherche par nom — retourne l'objet complet avec son ID
Write-Host "1. Récupération de la politique '$PolicyName'..." -ForegroundColor Cyan

$Policy = Get-MgIdentityConditionalAccessPolicy -All |
    Where-Object { $_.DisplayName -eq $PolicyName }

if (-not $Policy) {
    Write-Error "Politique '$PolicyName' introuvable."
    return
}

Write-Host "-> Politique trouvée : $($Policy.Id)" -ForegroundColor Green
Write-Host "-> State actuel : $($Policy.State)`n" -ForegroundColor Yellow

# --- ÉTAPE 4 : Passage en Enabled ---
# -BodyParameter @{ State = "enabled" } — on passe uniquement le paramètre à modifier
# Pas besoin de renvoyer tout l'objet — Graph merge les modifications
Write-Host "2. Activation de la politique (Report-Only → Enabled)..." -ForegroundColor Cyan

try {
    Update-MgIdentityConditionalAccessPolicy `
        -ConditionalAccessPolicyId $Policy.Id `
        -BodyParameter @{ State = "enabled" } `
        -ErrorAction Stop
    Write-Host "-> Succès : Politique activée." -ForegroundColor Green
}
catch {
    Write-Host "-> Échec de la modification : $_" -ForegroundColor Red
    return
}

# --- ÉTAPE 5 : Vérification ---
# Réplication CA lente — 15 secondes minimum
Write-Host "3. Vérification depuis Entra (source de vérité, attente 15s)..." -ForegroundColor Cyan
Start-Sleep -Seconds 15

Get-MgIdentityConditionalAccessPolicy -ConditionalAccessPolicyId $Policy.Id |
    Select-Object Id, DisplayName, State

# --- ÉTAPE 6 : Retour en Report-Only ---
# On repasse en Report-Only pour ne pas impacter le tenant de lab
# En prod — on laisserait en "enabled" après validation
Write-Host "`n4. Retour en Report-Only (sécurité lab)..." -ForegroundColor Cyan

try {
    Update-MgIdentityConditionalAccessPolicy `
        -ConditionalAccessPolicyId $Policy.Id `
        -BodyParameter @{ State = "enabledForReportingButNotEnforced" } `
        -ErrorAction Stop
    Write-Host "-> Succès : Politique repassée en Report-Only." -ForegroundColor Green
}
catch {
    Write-Host "-> Échec du retour en Report-Only : $_" -ForegroundColor Red
}

# --- ÉTAPE 7 : Vérification finale ---
Write-Host "5. Vérification finale (attente 15s)..." -ForegroundColor Cyan
Start-Sleep -Seconds 15

Get-MgIdentityConditionalAccessPolicy -ConditionalAccessPolicyId $Policy.Id |
    Select-Object Id, DisplayName, State

# --- ÉTAPE 8 : Nettoyage ---
Remove-Variable Scopes, PolicyName, Policy -ErrorAction SilentlyContinue

Write-Host "`nMémoire locale nettoyée. Session Microsoft Graph toujours active." -ForegroundColor Magenta
