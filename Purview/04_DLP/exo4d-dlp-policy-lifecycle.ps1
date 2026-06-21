# ========================================================================================
# Exercice 4d : Cycle de vie d'une DLP policy — TestWithNotifications -> Enable -> Test
# ========================================================================================
# Concept : une DLP policy n'est jamais activée directement en prod. Le cycle standard est
# Test (observation sans blocage réel) -> Enable (blocage actif) -> retour Test si besoin
# de réajuster (faux positifs, règle trop large). Set-DlpCompliancePolicy -Mode pilote ce
# cycle sans recréer la policy ni perdre l'historique de matches.
# Miroir de l'exo 5d côté Conditional Access (Entra) : même logique de bascule progressive.
#
# Script autoporté : crée sa propre policy + règle simples (SIT Credit Card sur SharePoint/
# OneDrive) pour démontrer le cycle sans dépendre de l'état laissé par d'autres exos.
#
# Module requis : ExchangeOnlineManagement
# Connexion : Connect-IPPSSession
# ========================================================================================

# --- OUVERTURE ---
Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
Get-PSSession | Remove-PSSession
$env:MSAL_ENABLE_WAM = "0"
Connect-IPPSSession -UserPrincipalName GeptorAdmin@0n4mg.onmicrosoft.com

# --- ÉTAPE 1 : Recherche d'un nom disponible ---
# Thème Mass Effect : Cerberus teste puis active une politique de confinement.
Write-Host "1. Recherche d'un nom disponible..." -ForegroundColor Cyan

$BasePolicyName = "DLP-Cerberus-LifecycleDemo"
$PolicyName     = $BasePolicyName
$Counter        = 2
while (Get-DlpCompliancePolicy -Identity $PolicyName -ErrorAction SilentlyContinue) {
    $PolicyName = "$BasePolicyName-v$Counter"
    $Counter++
}

$RuleName = "RULE-Cerberus-LifecycleDemo"
Write-Host "-> Policy : '$PolicyName' / Règle : '$RuleName'`n" -ForegroundColor Green

# --- ÉTAPE 2 : Création de la policy en mode Test ---
# On démarre TOUJOURS en TestWithNotifications, jamais directement en Enable —
# c'est précisément le comportement qu'on démontre ici.
try {
    $NewPolicy = New-DlpCompliancePolicy `
        -Name               $PolicyName `
        -SharePointLocation "All" `
        -OneDriveLocation   "All" `
        -Mode               "TestWithNotifications" `
        -Comment            "Exo 4d — Démo cycle de vie. Détecte Credit Card Number." `
        -ErrorAction Stop

    New-DlpComplianceRule `
        -Name                          $RuleName `
        -Policy                        $PolicyName `
        -ContentContainsSensitiveInformation @{Name = "Credit Card Number"; minCount = "1"} `
        -BlockAccess                   $true `
        -NotifyUser                    "LastModifier" `
        -ErrorAction Stop | Out-Null

    Write-Host "2. Policy + règle créées en mode TestWithNotifications.`n" -ForegroundColor Green
}
catch {
    Write-Host "-> Échec création : $_" -ForegroundColor Red
    Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
    Get-PSSession | Remove-PSSession
    return
}

# --- ÉTAPE 3 : Vérification état Test ---
# Sleep 30s : la propagation d'un changement de Mode côté backend Purview n'est pas
# instantanée. Un délai court peut relire un état pas encore à jour côté API et faire
# croire à un échec de transition qui n'en est pas un. 30s = marge réaliste.
Start-Sleep -Seconds 30
$Check = Get-DlpCompliancePolicy -Identity $PolicyName
Write-Host "3. État actuel : $($Check.Mode)`n" -ForegroundColor Cyan

# --- ÉTAPE 4 : Transition Test -> Enable ---
# Mode Enable = blocage réellement actif. C'est la transition qu'on ferait après avoir
# validé en Test qu'il n'y a pas de faux positifs massifs sur le périmètre réel.
Write-Host "4. Transition vers Enable (activation du blocage réel)..." -ForegroundColor Cyan
Set-DlpCompliancePolicy -Identity $PolicyName -Mode "Enable" -Confirm:$false -ErrorAction Stop

Start-Sleep -Seconds 30
$Check = Get-DlpCompliancePolicy -Identity $PolicyName
Write-Host "-> État actuel : $($Check.Mode)`n" -ForegroundColor Green

# --- ÉTAPE 5 : Transition Enable -> retour Test ---
# Scénario réel : un faux positif remonte (ex. un cas légitime bloqué), l'admin repasse
# en Test le temps d'ajuster la règle, sans supprimer ni recréer la policy.
Write-Host "5. Retour vers TestWithNotifications (ajustement nécessaire)..." -ForegroundColor Cyan
Set-DlpCompliancePolicy -Identity $PolicyName -Mode "TestWithNotifications" -Confirm:$false -ErrorAction Stop

Start-Sleep -Seconds 30
$Check = Get-DlpCompliancePolicy -Identity $PolicyName
Write-Host "-> État actuel : $($Check.Mode)`n" -ForegroundColor Green

# --- RÉSUMÉ ---
Write-Host "=== RÉSUMÉ ===" -ForegroundColor Magenta
[PSCustomObject]@{
    Policy        = $PolicyName
    CycleParcouru = "TestWithNotifications -> Enable -> TestWithNotifications"
    ÉtatFinal     = $Check.Mode
} | Format-List

Write-Host "Nettoyage optionnel :" -ForegroundColor Yellow
Write-Host "Remove-DlpComplianceRule -Identity '$RuleName' -Confirm:`$false" -ForegroundColor Yellow
Write-Host "Remove-DlpCompliancePolicy -Identity '$PolicyName' -Confirm:`$false`n" -ForegroundColor Yellow

# --- NETTOYAGE MÉMOIRE ---
Remove-Variable BasePolicyName, PolicyName, RuleName, Counter, NewPolicy, Check `
                -ErrorAction SilentlyContinue

# --- FERMETURE ---
Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
Get-PSSession | Remove-PSSession
Write-Host "Sessions fermées proprement." -ForegroundColor Magenta
