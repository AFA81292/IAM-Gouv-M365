# ========================================================================================
# Exercice 2a : Sensitivity Labels — Création d'un label group et d'un premier sublabel
# ========================================================================================
# Concept : Dans Purview, un "label group" n'est pas un type d'objet distinct —
# c'est un label standard auquel on ajoute manuellement la propriété islabelgroup="True".
# Cette propriété indique à Purview que le label servira de conteneur parent.
#
# Deux propriétés à distinguer :
#   islabelgroup = "True"  → posée manuellement en AdvancedSettings à la création.
#                            Signal que ce label est un conteneur.
#   isparent     = "True"  → calculée automatiquement par Purview dès qu'un sublabel
#                            le référence via -ParentId. On ne peut PAS la forcer.
#
# Ordre logique obligatoire :
#   1. Créer le label group (conteneur vide)
#   2. Créer un sublabel qui pointe vers ce groupe via -ParentId
#   → Purview positionne alors isparent=True automatiquement sur le groupe.
#
# Ce que fait ce script :
#   1. Reset total de session
#   2. Recherche un nom disponible pour le label group (auto-incrément)
#   3. Crée le label group avec islabelgroup="True"
#   4. Crée un premier sublabel rattaché au groupe
#   5. Vérifie la création et confirme isparent=True sur le groupe
#   6. Ferme proprement toutes les sessions
#
# Module requis : ExchangeOnlineManagement
# Connexion     : Connect-IPPSSession
# ========================================================================================

# --- OUVERTURE — RESET DE SESSION TOTAL ---
# REX : des sessions fantômes restées ouvertes depuis un script précédent peuvent
# provoquer des erreurs silencieuses ou des authentifications croisées.
# On purge TOUT avant de commencer, sans exception.
#
# Ordre : Disconnect-ExchangeOnline → Remove-PSSession → workaround WAM → reconnexion.
# Note : Connect-IPPSSession ne supporte pas -ShowBanner:$false — bandeau normal.
Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
Get-PSSession | Remove-PSSession
$env:MSAL_ENABLE_WAM = "0"
Connect-IPPSSession -UserPrincipalName GeptorAdmin@0n4mg.onmicrosoft.com

# ========================================================================================
# ÉTAPE 1 : Recherche d'un nom disponible pour le label group (auto-incrément)
# ========================================================================================
Write-Host "1. Recherche d'un nom disponible pour le label group..." -ForegroundColor Cyan

# Convention de nommage : "NormandySR2" = préfixe projet sur ce tenant de dev.
# L'incrément évite les conflits si l'exo est rejoué sans nettoyage préalable.
$BaseGroupName = "NormandySR2 - Confidentiel"
$GroupName     = $BaseGroupName
$Counter       = 2
while (Get-Label -Identity $GroupName -ErrorAction SilentlyContinue) {
    Write-Host "   '$GroupName' déjà pris — test avec suffixe -v$Counter..." -ForegroundColor Yellow
    $GroupName = "$BaseGroupName-v$Counter"
    $Counter++
}
Write-Host "-> Nom retenu pour le label group : '$GroupName'`n" -ForegroundColor Green

# Même logique pour le sublabel — nommage cohérent avec le groupe parent.
$BaseSubName = "NormandySR2 - Interne"
$SubName     = $BaseSubName
$Counter     = 2
while (Get-Label -Identity $SubName -ErrorAction SilentlyContinue) {
    Write-Host "   '$SubName' déjà pris — test avec suffixe -v$Counter..." -ForegroundColor Yellow
    $SubName = "$BaseSubName-v$Counter"
    $Counter++
}
Write-Host "-> Nom retenu pour le sublabel : '$SubName'`n" -ForegroundColor Green

# ========================================================================================
# ÉTAPE 2 : Création du label group
# ========================================================================================
Write-Host "2. Création du label group '$GroupName'..." -ForegroundColor Cyan

# -AdvancedSettings @{islabelgroup="True"} :
#   C'est le seul paramètre qui distingue un label group d'un label ordinaire.
#   Sans cette propriété, Purview traite l'objet comme un label standard —
#   il ne peut pas contenir de sublabels.
#   PIÈGE : la casse compte. "islabelgroup" en minuscules, valeur "True" avec majuscule.
#
# -Tooltip : texte affiché à l'utilisateur dans les apps Office/M365 quand il survole
#            le label. Doit être explicite sur la nature du contenu concerné.
#
# -Comment : note interne visible uniquement dans le portail Purview et via PowerShell.
#            Sert à documenter l'origine et le contexte du label — non visible utilisateur.
try {
    $LabelGroup = New-Label `
        -Name             $GroupName `
        -DisplayName      $GroupName `
        -Tooltip          "Documents confidentiels Cerberus Corp — groupe de classification" `
        -Comment          "Label group créé en PowerShell. Cerberus Corp IAM Lab." `
        -AdvancedSettings @{islabelgroup="True"} `
        -ErrorAction Stop

    Write-Host "-> Label group créé : $($LabelGroup.Name) [Guid : $($LabelGroup.Guid)]`n" -ForegroundColor Green
}
catch {
    Write-Host "-> Échec de la création du label group : $_" -ForegroundColor Red
    Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
    Get-PSSession | Remove-PSSession
    return
}

# Vérification intermédiaire avant de créer le sublabel.
# Si le label group n'est pas répliqué, le rattachement via -ParentId échouera.
# 30 secondes couvrent la latence de propagation Purview pour les objets labels.
Write-Host "   Attente de réplication avant création du sublabel (30s)..." -ForegroundColor Gray
Start-Sleep -Seconds 30

$VerifyGroup = Get-Label -Identity $GroupName -ErrorAction SilentlyContinue
if (-not $VerifyGroup) {
    Write-Host "-> ÉCHEC : le label group '$GroupName' n'est pas retrouvable après création." -ForegroundColor Red
    Write-Host "   Arrêt du script — vérifier manuellement dans le portail Purview." -ForegroundColor Red
    Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
    Get-PSSession | Remove-PSSession
    return
}
Write-Host "-> Label group confirmé présent dans Purview.`n" -ForegroundColor Green

# ========================================================================================
# ÉTAPE 3 : Création du premier sublabel rattaché au groupe
# ========================================================================================
Write-Host "3. Création du sublabel '$SubName'..." -ForegroundColor Cyan

# -ParentId $LabelGroup.Guid :
#   C'est ce paramètre qui déclenche le mécanisme isparent.
#   En pointant ce sublabel vers le Guid du label group, Purview :
#     1. Rattache le sublabel sous le groupe dans l'arborescence
#     2. Pose automatiquement isparent="True" sur le label group parent
#   On utilise le Guid (et non le nom) pour éviter toute ambiguïté de résolution.
#
# Pas de chiffrement sur ce sublabel à ce stade.
# Le chiffrement (Azure RMS / protection) sera ajouté en exercice 2b.
# L'objectif ici est uniquement de valider la structure groupe/sublabel.
try {
    $SubLabel = New-Label `
        -Name        $SubName `
        -DisplayName $SubName `
        -ParentId    $LabelGroup.Guid `
        -Tooltip     "Document confidentiel à usage interne uniquement" `
        -Comment     "Sublabel sans chiffrement à ce stade — chiffrement ajouté en exo 2b." `
        -ErrorAction Stop

    Write-Host "-> Sublabel créé : $($SubLabel.Name) [Guid : $($SubLabel.Guid)]`n" -ForegroundColor Green
}
catch {
    Write-Host "-> Échec de la création du sublabel : $_" -ForegroundColor Red
    Write-Host "   Le label group '$GroupName' a été créé mais reste sans sublabel." -ForegroundColor Yellow
    Write-Host "   Supprimer via : Remove-Label -Identity '$GroupName' -Confirm:`$false" -ForegroundColor Yellow
    Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
    Get-PSSession | Remove-PSSession
    return
}

# ========================================================================================
# ÉTAPE 4 : Vérification finale — sublabel ET isparent sur le groupe
# ========================================================================================
Write-Host "4. Vérification finale depuis le backend Purview..." -ForegroundColor Cyan

# 30 secondes supplémentaires pour la propagation du sublabel et la mise à jour
# automatique de isparent sur le groupe parent.
Start-Sleep -Seconds 30

$VerifySubLabel = Get-Label -Identity $SubName -ErrorAction SilentlyContinue
if (-not $VerifySubLabel) {
    Write-Host "-> ÉCHEC : le sublabel '$SubName' n'est pas retrouvable après création." -ForegroundColor Red
    Write-Host "   Vérifier manuellement dans le portail Purview avant de continuer." -ForegroundColor Red
    Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
    Get-PSSession | Remove-PSSession
    return
}
Write-Host "-> Sublabel confirmé présent dans Purview." -ForegroundColor Green

# Vérification de isparent sur le label group.
# .Settings est une collection de paires clé/valeur — on filtre sur le nom "isparent".
# Si isparent=True : le rattachement via -ParentId a bien déclenché le mécanisme Purview.
# Si isparent est absent ou False : la réplication est encore en cours.
$CheckGroup    = Get-Label -Identity $GroupName -ErrorAction SilentlyContinue
$IsParentEntry = $CheckGroup.Settings | Where-Object { $_.Name -eq "isparent" }

if ($IsParentEntry.Value -eq "True") {
    Write-Host "-> Confirmé : isparent=True — le label group est pleinement fonctionnel.`n" -ForegroundColor Green
} else {
    Write-Host "-> ATTENTION : isparent toujours False malgré la présence du sublabel." -ForegroundColor Yellow
    Write-Host "   Réplication possiblement encore en cours — revérifier dans quelques minutes.`n" -ForegroundColor Yellow
}

# ========================================================================================
# ÉTAPE 5 : Résumé
# ========================================================================================
Write-Host "=== RÉSUMÉ ===" -ForegroundColor Magenta
[PSCustomObject]@{
    LabelGroup       = $VerifyGroup.DisplayName
    LabelGroupGuid   = $VerifyGroup.Guid
    IsLabelGroup     = "True (posé manuellement en AdvancedSettings)"
    IsParent         = if ($IsParentEntry.Value -eq "True") { "True (calculé automatiquement par Purview)" } else { "En attente de réplication" }
    Sublabel         = $VerifySubLabel.DisplayName
    SublabelGuid     = $VerifySubLabel.Guid
    SublabelParentId = $VerifySubLabel.ParentId
    Chiffrement      = "Non — à ajouter en exo 2b"
} | Format-List

# ========================================================================================
# NETTOYAGE MÉMOIRE
# ========================================================================================
Remove-Variable BaseGroupName, GroupName, BaseSubName, SubName, Counter,
                LabelGroup, SubLabel, VerifyGroup, VerifySubLabel,
                CheckGroup, IsParentEntry `
                -ErrorAction SilentlyContinue

# ========================================================================================
# FERMETURE — RESET DE SESSION TOTAL
# ========================================================================================
Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
Get-PSSession | Remove-PSSession
Write-Host "Sessions fermées proprement." -ForegroundColor Magenta
