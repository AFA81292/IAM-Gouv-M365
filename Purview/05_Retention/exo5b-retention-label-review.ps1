# ========================================================================================
# Exercice 5b : Retention Label avec disposition review — 7 ans depuis création
# ========================================================================================
# Concept : contrairement à 5a (suppression silencieuse), ici un humain doit valider la
# suppression à l'expiration. RetentionAction "KeepAndDelete" + ReviewerEmail rempli =
# le contenu est gelé à l'expiration et apparaît dans la file de disposition review du
# reviewer désigné, qui choisit : approuver la suppression, prolonger, ou relabelliser.
#
# RetentionAction "Delete" simple n'accepte PAS de review humaine malgré ce qu'on pourrait
# penser — ReviewerEmail n'a d'effet que combiné à "KeepAndDelete" (ou "Keep", mais Keep
# seul ne supprime jamais rien, donc pas de disposition à reviewer). C'est "KeepAndDelete"
# qui porte la sémantique "garder jusqu'à décision humaine, puis supprimer si approuvé".
#
# RetentionType "CreationAgeInDays" : le compteur démarre à la création du contenu, pas
# sa dernière modification (contrairement à 5a) — pertinent pour des archives figées dont
# la date de référence est leur dépôt initial, pas une modification ultérieure.
#
# Le reviewer doit être un compte existant sur le tenant, membre d'un rôle incluant
# Disposition Management + View-Only Audit Logs (Organization Management les a par défaut).
#
# Thème Mass Effect : un Spectre valide la destruction des archives classifiées avant
# leur purge définitive — rien n'est détruit sans accord humain.
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

$BaseLabelName = "RET-Citadel-7ans-Creation-Review"
$LabelName     = $BaseLabelName
$Counter       = 2
while (Get-ComplianceTag -Identity $LabelName -ErrorAction SilentlyContinue) {
    $LabelName = "$BaseLabelName-v$Counter"
    $Counter++
}
Write-Host "-> Nom retenu : '$LabelName'`n" -ForegroundColor Green

# --- ÉTAPE 2 : Création du label ---
# 7 ans = 2555 jours.
# Reviewer : GeptorAdmin lui-même sur ce tenant dev (Organization Management a les rôles
# nécessaires par défaut). En production, ce serait un compte dédié, pas l'admin global.
$ReviewerUPN = "GeptorAdmin@0n4mg.onmicrosoft.com"

try {
    $NewLabel = New-ComplianceTag `
        -Name             $LabelName `
        -RetentionAction  "KeepAndDelete" `
        -RetentionDuration 2555 `
        -RetentionType    "CreationAgeInDays" `
        -ReviewerEmail    $ReviewerUPN `
        -Comment          "Exo 5b — Disposition review obligatoire 7 ans après création." `
        -ErrorAction Stop

    Write-Host "2. Label créé : $($NewLabel.Name)`n" -ForegroundColor Green
}
catch {
    Write-Host "-> Échec création : $_" -ForegroundColor Red
    Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
    Get-PSSession | Remove-PSSession
    return
}

# --- ÉTAPE 3 : Vérification depuis la source de vérité ---
Write-Host "3. Vérification..." -ForegroundColor Cyan
Start-Sleep -Seconds 30

$CheckLabel = Get-ComplianceTag -Identity $LabelName -ErrorAction SilentlyContinue

if ($CheckLabel) {
    [PSCustomObject]@{
        Nom               = $CheckLabel.Name
        Action            = $CheckLabel.RetentionAction
        DuréeJours        = $CheckLabel.RetentionDuration
        DuréeApprox       = "{0:N1} ans" -f ($CheckLabel.RetentionDuration / 365)
        Type              = $CheckLabel.RetentionType
        Reviewer          = ($CheckLabel.ReviewerEmail -join ", ")
        DispositionReview = if ($CheckLabel.ReviewerEmail) { "Oui" } else { "Non" }
    } | Format-List
} else {
    Write-Host "-> ATTENTION : label non trouvé lors de la vérification." -ForegroundColor Red
}

# --- RÉSUMÉ ---
Write-Host "=== RÉSUMÉ ===" -ForegroundColor Magenta
Write-Host "Label '$LabelName' créé, non publié — invisible des utilisateurs pour l'instant." -ForegroundColor Yellow
Write-Host "Publication via Label Policy : cf. exo 5c.`n" -ForegroundColor Yellow

# --- NETTOYAGE MÉMOIRE ---
Remove-Variable BaseLabelName, LabelName, Counter, ReviewerUPN, NewLabel, CheckLabel `
                -ErrorAction SilentlyContinue

# --- FERMETURE ---
Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
Get-PSSession | Remove-PSSession
Write-Host "Sessions fermées proprement." -ForegroundColor Magenta
