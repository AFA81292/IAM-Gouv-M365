# ========================================================================================
# Exercice 5a : Retention Label simple — 3 ans depuis modification, sans review
# ========================================================================================
# Concept : un Retention Label seul (New-ComplianceTag) n'a aucun effet tant qu'il n'est
# pas publié via une Label Policy (exo 5c). Cet exo crée juste l'objet label.
#
# RetentionAction "Delete" : suppression automatique et silencieuse à l'expiration —
# pas de "KeepAndDelete" (qui ajoute un coffre-fort consultable) et pas de reviewer
# (cf. 5b pour la variante avec disposition review).
# RetentionType "ModificationAgeInDays" : le compteur démarre à la dernière modification
# du contenu, pas à sa création — pertinent pour des documents vivants (vs des archives
# figées à la création, cf. 5b).
#
# Thème Mass Effect : la Citadelle purge ses archives après 3 ans d'inactivité.
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

$BaseLabelName = "RET-Citadel-3ans-Modification"
$LabelName     = $BaseLabelName
$Counter       = 2
while (Get-ComplianceTag -Identity $LabelName -ErrorAction SilentlyContinue) {
    $LabelName = "$BaseLabelName-v$Counter"
    $Counter++
}
Write-Host "-> Nom retenu : '$LabelName'`n" -ForegroundColor Green

# --- ÉTAPE 2 : Création du label ---
# 3 ans = 1095 jours. RetentionDuration attend un nombre de jours, pas une unité Year/Month.
try {
    $NewLabel = New-ComplianceTag `
        -Name             $LabelName `
        -RetentionAction  "Delete" `
        -RetentionDuration 1095 `
        -RetentionType    "ModificationAgeInDays" `
        -Comment          "Exo 5a — Purge silencieuse 3 ans après dernière modification." `
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
        Nom              = $CheckLabel.Name
        Action           = $CheckLabel.RetentionAction
        DuréeJours       = $CheckLabel.RetentionDuration
        DuréeApprox      = "{0:N1} ans" -f ($CheckLabel.RetentionDuration / 365)
        Type             = $CheckLabel.RetentionType
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
Remove-Variable BaseLabelName, LabelName, Counter, NewLabel, CheckLabel -ErrorAction SilentlyContinue

# --- FERMETURE ---
Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
Get-PSSession | Remove-PSSession
Write-Host "Sessions fermées proprement." -ForegroundColor Magenta
