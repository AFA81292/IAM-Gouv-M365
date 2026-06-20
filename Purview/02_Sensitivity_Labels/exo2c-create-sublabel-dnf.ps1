# ========================================================================================
# Exercice 2c : Sensitivity Labels — Sublabel Do Not Forward pour usage externe
# ========================================================================================
# Concept : Ce sublabel protège les emails envoyés hors du tenant.
# Le destinataire peut lire et répondre, mais ne peut ni transférer, ni imprimer,
# ni copier le contenu. Les pièces jointes Office héritent de la même protection.
#
# POURQUOI PAS -EncryptionDoNotForward ?
#   Ce paramètre existe dans la doc Microsoft mais son comportement est incohérent
#   selon la version du module — il est ignoré silencieusement ou mal appliqué.
#   La méthode fiable (celle qu'utilise le portail Purview en interne) : passer le
#   droit spécial DONOTFORWARD dans -EncryptionRightsDefinitions.
#
# Module requis : ExchangeOnlineManagement
# Connexion : Connect-IPPSSession
# ========================================================================================

# --- OUVERTURE ---
Get-PSSession | Remove-PSSession
Connect-IPPSSession -UserPrincipalName GeptorAdmin@0n4mg.onmicrosoft.com -ShowBanner:$false

# --- ÉTAPE 0 : Vérification du label group parent ---
$ParentGroupName = "NormandySR2 - Confidentiel"
$ParentGroup = Get-Label -Identity $ParentGroupName -ErrorAction SilentlyContinue

if (-not $ParentGroup) {
    Write-Host "-> ÉCHEC : '$ParentGroupName' introuvable. Exécuter l'exo 2a au préalable." -ForegroundColor Red
    Get-PSSession | Remove-PSSession
    return
}
Write-Host "Label group parent confirmé — Guid : $($ParentGroup.Guid)`n" -ForegroundColor Green

# --- ÉTAPE 1 : Recherche d'un nom disponible (auto-incrément) ---
Write-Host "1. Recherche d'un nom disponible..." -ForegroundColor Cyan

# Sur un tenant de dev on reteste souvent le même script sans attendre que la
# suppression précédente soit propagée (ça peut prendre 2 à 5 minutes côté backend
# Purview même après un Remove-Label réussi). L'auto-incrément évite le blocage :
# on cherche le premier nom libre parmi "NormandySR2 - Externe", "-v2", "-v3", etc.
$BaseName     = "NormandySR2 - Externe"
$SubLabelName = $BaseName
$Counter      = 2

while (Get-Label -Identity $SubLabelName -ErrorAction SilentlyContinue) {
    Write-Host "   '$SubLabelName' déjà pris — test avec suffixe -v$Counter..." -ForegroundColor Yellow
    $SubLabelName = "$BaseName-v$Counter"
    $Counter++
}

Write-Host "-> Nom retenu : '$SubLabelName'`n" -ForegroundColor Green

# --- ÉTAPE 2 : Construction de la chaîne de droits ---
Write-Host "2. Construction des droits Do Not Forward..." -ForegroundColor Cyan

# Ce GUID bizarre est une identité réservée Azure RMS — c'est la façon dont
# Microsoft dit "n'importe quel utilisateur avec un
