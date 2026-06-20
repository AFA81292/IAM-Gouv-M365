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
# POURQUOI LA CONCATENATION + ET PAS L'INTERPOLATION ${var}:DONOTFORWARD ?
#   PowerShell interprète le ":" après "}" comme un séparateur de drive provider
#   (ex : Env:, HKLM:, etc.) dans certains contextes d'interpolation. Résultat :
#   crash silencieux sans message d'erreur. La concaténation avec + est sans ambiguïté.
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
# Microsoft dit "n'importe quel utilisateur avec un compte Azure AD".
# Il est identique sur tous les tenants, on ne l'invente pas.
$TenantDomain     = "0n4mg.onmicrosoft.com"
$AllStaffIdentity = "AllStaff-7184AB3F-CCD1-46F3-8233-3E09E9CF0E66@" + $TenantDomain

# DONOTFORWARD est le droit composite RMS pour Do Not Forward.
# Il autorise VIEW, REPLY, REPLYALL — et bloque FORWARD, PRINT, EXTRACT, EDIT.
# IMPORTANT : concaténation avec + obligatoire ici (voir note en en-tête du script).
$RightsDefinitionsString = $AllStaffIdentity + ":DONOTFORWARD"
Write-Host "-> Chaîne droits : $RightsDefinitionsString`n" -ForegroundColor DarkGray

# --- ÉTAPE 3 : Création du sublabel ---
Write-Host "3. Création du sublabel '$SubLabelName'..." -ForegroundColor Cyan

try {
    $SubLabelExterne = New-Label `
        -Name                                        $SubLabelName `
        -DisplayName                                 $SubLabelName `
        -ParentId                                    $ParentGroup.Guid `
        -Tooltip                                     "Email confidentiel destiné à l'externe — transfert et impression bloqués" `
        -Comment                                     "Sublabel Do Not Forward — protège les communications sortantes du tenant." `
        -EncryptionEnabled                           $true `
        -EncryptionProtectionType                    "Template" `
        -EncryptionRightsDefinitions                 $RightsDefinitionsString `
        -EncryptionContentExpiredOnDateInDaysOrNever "Never" `
        -EncryptionOfflineAccessDays                 0 `
        -ErrorAction Stop

    # OfflineAccessDays = 0 : Do Not Forward est pensé pour une lecture en ligne
    # uniquement — pas d'accès hors connexion, cohérent avec l'objectif de contrôle.

    Write-Host "-> Sublabel créé. Guid : $($SubLabelExterne.Guid)`n" -ForegroundColor Green
}
catch {
    Write-Host "-> Échec création : $_" -ForegroundColor Red
    Get-PSSession | Remove-PSSession
    return
}

# --- ÉTAPE 4 : Vérification ---
Write-Host "4. Vérification (propagation 30s)..." -ForegroundColor Cyan
Start-Sleep -Seconds 30

$CheckLabel = Get-Label -Identity $SubLabelName -IncludeDetailedLabelActions -ErrorAction SilentlyContinue

if (-not $CheckLabel) {
    Write-Host "-> ATTENTION : label introuvable après vérification." -ForegroundColor Yellow
}
elseif (-not $CheckLabel.EncryptionEnabled) {
    Write-Host "-> ATTENTION : chiffrement non confirmé." -ForegroundColor Yellow
}
else {
    Write-Host "-> Sublabel confirmé :" -ForegroundColor Green

    # Note : la propriété EncryptionDoNotForward reste vide sur certaines versions
    # du module — c'est normal. La vraie preuve est dans DroitsDefinis ci-dessous,
    # qui doit afficher "AllStaff-...@0n4mg.onmicrosoft.com:DONOTFORWARD".
    [PSCustomObject]@{
        Nom               = $CheckLabel.DisplayName
        ChiffrementActif  = [bool]$CheckLabel.EncryptionEnabled
        TypeProtection    = $CheckLabel.EncryptionProtectionType
        DroitsDefinis     = $CheckLabel.EncryptionRightsDefinitions
        OfflineAccesJours = $CheckLabel.EncryptionOfflineAccessDays
        ParentGuid        = $CheckLabel.ParentId
    } | Format-List
}

# --- NETTOYAGE MÉMOIRE ---
Remove-Variable BaseName, SubLabelName, Counter, ParentGroupName, ParentGroup, `
                TenantDomain, AllStaffIdentity, RightsDefinitionsString, `
                SubLabelExterne, CheckLabel -ErrorAction SilentlyContinue

# --- FERMETURE ---
Get-PSSession | Remove-PSSession
Write-Host "`nSession fermée." -ForegroundColor Magenta
