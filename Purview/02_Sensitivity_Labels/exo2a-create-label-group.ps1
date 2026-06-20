# ========================================================================================
# Exercice 2a : Sensitivity Labels — Création d'un label group via PowerShell
# ========================================================================================
# Concept : Sur le schéma moderne de labels Purview (actif par défaut sur tout tenant
# créé après le 01/10/2025), un "label group" n'est PAS un objet distinct côté API.
# C'est un label normal dont deux propriétés de settings sont positionnées :
#   - islabelgroup : déclare l'intention "ce label sert de conteneur organisationnel"
#   - isparent     : calculée AUTOMATIQUEMENT par le service Purview, PAS settable
#                     manuellement. Elle passe à True dès qu'au moins un sublabel
#                     référence ce label comme parent via -ParentId.
#
# Découverte par investigation directe (documentée ici car contre-intuitive) :
#   1. New-Label -AdvancedSettings @{islabelgroup="True"} crée le conteneur
#   2. New-Label -ParentId <Guid-du-groupe> crée un sublabel rattaché
#   3. Le service met alors isparent=True sur le groupe, en retour, sans action admin
#   Tenté et rejeté : passer isparent="True" directement à la création ou via Set-Label
#   après coup — toujours resté à False. Ce n'est pas un paramètre, c'est un état dérivé.
#
# Pourquoi ce comportement a du sens côté Microsoft :
#   Un label group "vide" sans aucun sublabel ne sert à rien dans l'UI Office —
#   le système ne le considère donc "parent" qu'une fois qu'il a réellement un enfant.
#
# Ce script crée le label group "NSR2 - Confidentiel" PUIS son premier sublabel
# "NSR2 - Interne" (sans chiffrement à ce stade — le chiffrement arrive en 2b
# sur ce même sublabel via Set-Label, pour rester dans l'esprit 1 action = 1 étape).
#
# Module requis : ExchangeOnlineManagement
# Connexion : Connect-IPPSSession
# ========================================================================================

# --- OUVERTURE ---
Get-PSSession | Remove-PSSession
Connect-IPPSSession -UserPrincipalName GeptorAdmin@0n4mg.onmicrosoft.com -ShowBanner:$false

# --- ÉTAPE 1 : Création du label group ---
# -AdvancedSettings @{islabelgroup="True"} est la seule clé nécessaire à la création.
# isparent se positionnera tout seul à l'étape 2.
Write-Host "1. Création du label group 'NSR2 - Confidentiel'..." -ForegroundColor Cyan

try {
    $LabelGroup = New-Label `
        -Name "NSR2 - Confidentiel" `
        -DisplayName "NSR2 - Confidentiel" `
        -Tooltip "Documents confidentiels Cerberus Corp — groupe de classification" `
        -Comment "Label group créé en PowerShell. Cerberus Corp IAM Lab." `
        -AdvancedSettings @{islabelgroup="True"} `
        -ErrorAction Stop

    Write-Host "-> Label group créé. Guid : $($LabelGroup.Guid)`n" -ForegroundColor Green
}
catch {
    Write-Host "-> Échec création label group : $_" -ForegroundColor Red
    return
}

# --- ÉTAPE 2 : Création du premier sublabel rattaché ---
# -ParentId utilise le Guid récupéré à l'étape 1. C'est cette opération qui va
# automatiquement faire passer isparent=True sur le label group parent.
Write-Host "2. Création du premier sublabel 'NSR2 - Interne'..." -ForegroundColor Cyan

try {
    $SubLabel = New-Label `
        -Name "NSR2 - Interne" `
        -DisplayName "NSR2 - Interne" `
        -ParentId $LabelGroup.Guid `
        -Tooltip "Document confidentiel à usage interne uniquement" `
        -Comment "Sublabel sans chiffrement à ce stade — chiffrement ajouté en exo 2b." `
        -ErrorAction Stop

    Write-Host "-> Sublabel créé. Guid : $($SubLabel.Guid)`n" -ForegroundColor Green
}
catch {
    Write-Host "-> Échec création sublabel : $_" -ForegroundColor Red
    return
}

# --- ÉTAPE 3 : Vérification — isparent doit être passé à True ---
Write-Host "3. Vérification (propagation ~20s)..." -ForegroundColor Cyan
Start-Sleep -Seconds 20

$CheckGroup = Get-Label -Identity "NSR2 - Confidentiel"

Write-Host "-> Settings du label group :" -ForegroundColor Green
$CheckGroup.Settings | Format-Table -AutoSize

# Recherche dans Settings via Where-Object plutôt qu'une indexation directe —
# Settings n'est pas une hashtable .NET classique, l'indexation ["clé"] échoue
# silencieusement et retourne $null même quand la valeur existe réellement.
$IsParentEntry = $CheckGroup.Settings | Where-Object { $_.Name -eq "isparent" }

if ($IsParentEntry.Value -eq "True") {
    Write-Host "-> Confirmé : isparent=True — le label group est fonctionnel.`n" -ForegroundColor Green
} else {
    Write-Host "-> isparent toujours False — réplication possiblement en cours.`n" -ForegroundColor Yellow
}

# --- NETTOYAGE MÉMOIRE ---
Remove-Variable LabelGroup, SubLabel, CheckGroup -ErrorAction SilentlyContinue

# --- FERMETURE ---
Get-PSSession | Remove-PSSession
Write-Host "`nSession fermée." -ForegroundColor Magenta
