# ========================================================================================
# Exercice 2c : Sensitivity Labels — Sublabel Do Not Forward pour usage externe
# ========================================================================================
# Concept : Ce sublabel protège les emails envoyés hors du tenant via le droit RMS
# composite DONOTFORWARD. Le destinataire peut lire et répondre, mais ne peut ni
# transférer, ni imprimer, ni copier le contenu. Les pièces jointes Office héritent
# automatiquement de la même protection.
#
# Pourquoi pas -EncryptionDoNotForward ?
#   Ce paramètre existe dans la documentation Microsoft mais son comportement est
#   incohérent selon la version du module — ignoré silencieusement ou mal appliqué.
#   La méthode fiable, celle qu'utilise le portail Purview en interne, est de passer
#   le droit spécial DONOTFORWARD directement dans -EncryptionRightsDefinitions.
#
# Pièges documentés :
#   1. Ne pas utiliser -EncryptionDoNotForward — préférer DONOTFORWARD dans
#      -EncryptionRightsDefinitions (méthode interne Purview, comportement fiable).
#   2. Concaténer avec + plutôt qu'interpoler "${var}:DONOTFORWARD".
#      PowerShell peut interpréter ":" après "}" comme un séparateur de drive
#      (Env:, HKLM:...) et planter sans message d'erreur explicite.
#   3. Le GUID AllStaff (AllStaff-7184AB3F-CCD1-46F3-8233-3E09E9CF0E66) est une
#      identité réservée Azure RMS — identique sur tous les tenants Microsoft.
#      Il signifie "tout utilisateur avec un compte Azure AD".
#   4. EncryptionOfflineAccessDays = 0 est intentionnel pour Do Not Forward :
#      le scénario est une lecture en ligne uniquement — pas d'accès hors connexion.
#
# Ce que fait ce script :
#   1. Reset total de session
#   2. Vérifie que le label group parent (créé en 2a) est présent
#   3. Recherche un nom disponible pour le sublabel (auto-incrément)
#   4. Construit la chaîne de droits DONOTFORWARD
#   5. Crée le sublabel avec chiffrement et rattachement au groupe parent
#   6. Vérifie la création depuis la source de vérité
#   7. Ferme proprement toutes les sessions
#
# Prérequis : exo 2a exécuté — label group "NormandySR2 - Confidentiel" doit exister
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
# ÉTAPE 1 : Vérification préalable — le label group parent doit exister
# ========================================================================================
Write-Host "1. Vérification du label group parent..." -ForegroundColor Cyan

# Ce sublabel doit être rattaché au groupe créé en 2a via -ParentId.
# Si le groupe est absent, la création échouera avec une erreur de résolution de Guid.
# On contrôle explicitement avant de continuer.
$ParentGroupName = "NormandySR2 - Confidentiel"
$ParentGroup     = Get-Label -Identity $ParentGroupName -ErrorAction SilentlyContinue

if (-not $ParentGroup) {
    Write-Host "-> ÉCHEC : '$ParentGroupName' introuvable." -ForegroundColor Red
    Write-Host "   Exécuter l'exo 2a au préalable pour créer le label group parent." -ForegroundColor Yellow
    Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
    Get-PSSession | Remove-PSSession
    return
}
Write-Host "-> Label group parent confirmé. Guid : $($ParentGroup.Guid)`n" -ForegroundColor Green

# ========================================================================================
# ÉTAPE 2 : Recherche d'un nom disponible (auto-incrément)
# ========================================================================================
Write-Host "2. Recherche d'un nom disponible pour le sublabel..." -ForegroundColor Cyan

# Sur un tenant de dev, on reteste souvent le même script sans attendre que la
# suppression précédente se propage côté backend (quelques minutes même après
# un Remove-Label réussi). L'auto-incrément évite le blocage : on cherche
# le premier nom libre parmi "NormandySR2 - Externe", "-v2", "-v3", etc.
$BaseName     = "NormandySR2 - Externe"
$SubLabelName = $BaseName
$Counter      = 2

while (Get-Label -Identity $SubLabelName -ErrorAction SilentlyContinue) {
    Write-Host "   '$SubLabelName' déjà pris — test avec suffixe -v$Counter..." -ForegroundColor Yellow
    $SubLabelName = "$BaseName-v$Counter"
    $Counter++
}
Write-Host "-> Nom retenu pour le sublabel : '$SubLabelName'`n" -ForegroundColor Green

# ========================================================================================
# ÉTAPE 3 : Construction de la chaîne de droits DONOTFORWARD
# ========================================================================================
Write-Host "3. Construction de la chaîne de droits DONOTFORWARD..." -ForegroundColor Cyan

# AllStaff-7184AB3F-CCD1-46F3-8233-3E09E9CF0E66 :
#   GUID réservé Azure RMS, identique sur tous les tenants Microsoft.
#   Signifie "tout utilisateur authentifié avec un compte Azure AD".
#   On le suffixe avec le domaine du tenant pour former une identité RMS valide.
$TenantDomain     = "0n4mg.onmicrosoft.com"
$AllStaffIdentity = "AllStaff-7184AB3F-CCD1-46F3-8233-3E09E9CF0E66@" + $TenantDomain

# DONOTFORWARD : droit composite RMS.
#   Autorise : VIEW (lecture), REPLY (répondre), REPLYALL (répondre à tous)
#   Bloque   : FORWARD (transfert), PRINT (impression), EXTRACT (copier/coller), EDIT
#
# Concaténation avec + (pas d'interpolation "${var}:DONOTFORWARD") :
#   PowerShell interprète ":" après "}" comme un séparateur de drive PS (Env:, HKLM:...).
#   La concaténation évite cette ambiguïté et garantit la chaîne attendue.
$RightsDefinitionsString = $AllStaffIdentity + ":DONOTFORWARD"
Write-Host "-> Chaîne de droits construite :" -ForegroundColor Green
Write-Host "   $RightsDefinitionsString`n" -ForegroundColor DarkGray

# ========================================================================================
# ÉTAPE 4 : Création du sublabel avec chiffrement DONOTFORWARD
# ========================================================================================
Write-Host "4. Création du sublabel '$SubLabelName'..." -ForegroundColor Cyan

# -ParentId $ParentGroup.Guid :
#   Rattache ce sublabel au label group "NormandySR2 - Confidentiel".
#   Utilisation du Guid (pas du nom) pour éviter toute ambiguïté de résolution.
#
# -EncryptionEnabled $true :
#   Active le chiffrement RMS sur ce label.
#
# -EncryptionProtectionType "Template" :
#   Droits définis par l'admin (admin-defined) — identique à l'approche de l'exo 2b.
#
# -EncryptionRightsDefinitions $RightsDefinitionsString :
#   La chaîne AllStaff:DONOTFORWARD construite à l'étape 3.
#
# -EncryptionContentExpiredOnDateInDaysOrNever "Never" :
#   Pas d'expiration sur ce contenu — cohérent avec un usage externe ponctuel.
#
# -EncryptionOfflineAccessDays 0 :
#   Do Not Forward est conçu pour la lecture en ligne uniquement.
#   0 = connexion Azure RMS requise à chaque ouverture, pas de cache local.
#   Intentionnel : on ne veut pas qu'une copie reste lisible hors connexion.
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

    Write-Host "-> Sublabel créé : $($SubLabelExterne.Name) [Guid : $($SubLabelExterne.Guid)]`n" -ForegroundColor Green
}
catch {
    Write-Host "-> Échec de la création du sublabel : $_" -ForegroundColor Red
    Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
    Get-PSSession | Remove-PSSession
    return
}

# ========================================================================================
# ÉTAPE 5 : Vérification depuis la source de vérité
# ========================================================================================
Write-Host "5. Vérification depuis le backend Purview..." -ForegroundColor Cyan

# -IncludeDetailedLabelActions : requis pour exposer les propriétés de chiffrement.
# Sans ce switch, Get-Label retourne l'objet label sans les détails de protection.
Start-Sleep -Seconds 30

$CheckLabel = Get-Label -Identity $SubLabelName -IncludeDetailedLabelActions -ErrorAction SilentlyContinue

if (-not $CheckLabel) {
    Write-Host "-> ATTENTION : label introuvable après vérification." -ForegroundColor Yellow
    Write-Host "   Réplication possiblement encore en cours — revérifier dans quelques minutes." -ForegroundColor Yellow
} elseif (-not $CheckLabel.EncryptionEnabled) {
    Write-Host "-> ATTENTION : chiffrement non confirmé après vérification." -ForegroundColor Yellow
} else {
    Write-Host "-> Sublabel confirmé :" -ForegroundColor Green

    # Note sur EncryptionDoNotForward :
    #   Cette propriété reste parfois vide selon la version du module — comportement
    #   normal. La vraie preuve est dans DroitsDefinis, qui doit afficher
    #   "AllStaff-...@0n4mg.onmicrosoft.com:DONOTFORWARD".
    [PSCustomObject]@{
        Nom                = $CheckLabel.DisplayName
        ChiffrementActif   = [bool]$CheckLabel.EncryptionEnabled
        TypeProtection     = $CheckLabel.EncryptionProtectionType
        DroitsDefinis      = $CheckLabel.EncryptionRightsDefinitions
        OfflineAccessJours = $CheckLabel.EncryptionOfflineAccessDays
        ParentGuid         = $CheckLabel.ParentId
    } | Format-List
}

# ========================================================================================
# ÉTAPE 6 : Résumé
# ========================================================================================
Write-Host "=== RÉSUMÉ ===" -ForegroundColor Magenta
[PSCustomObject]@{
    SublabelCréé       = $SubLabelName
    GroupeParent       = $ParentGroupName
    ChiffrementRMS     = "Activé (admin-defined)"
    DroitAppliqué      = "DONOTFORWARD (VIEW + REPLY autorisés / FORWARD + PRINT + EXTRACT bloqués)"
    IdentitéCible      = "AllStaff (tout utilisateur Azure AD authentifié)"
    OfflineAccès       = "0 jours (lecture en ligne uniquement)"
    Expiration         = "Never"
    PiègesCmdlet       = "Concaténation + (pas interpolation) / DONOTFORWARD dans RightsDefinitions (pas -EncryptionDoNotForward)"
    SuiteLogique       = "Exo 2d — publication des labels via Label Policy"
} | Format-List

# ========================================================================================
# NETTOYAGE MÉMOIRE
# ========================================================================================
Remove-Variable ParentGroupName, ParentGroup, BaseName, SubLabelName, Counter,
                TenantDomain, AllStaffIdentity, RightsDefinitionsString,
                SubLabelExterne, CheckLabel `
                -ErrorAction SilentlyContinue

# ========================================================================================
# FERMETURE — RESET DE SESSION TOTAL
# ========================================================================================
Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
Get-PSSession | Remove-PSSession
Write-Host "Sessions fermées proprement." -ForegroundColor Magenta
