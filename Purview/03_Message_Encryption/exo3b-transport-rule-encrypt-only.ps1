# ========================================================================================
# Exercice 3b : Message Encryption — Transport Rule OME Encrypt-Only
# ========================================================================================
# Concept : Une Transport Rule (règle de flux de messagerie) est une règle côté serveur
# Exchange qui s'applique automatiquement à tous les mails qui transitent, sans
# intervention de l'utilisateur. C'est l'opposé d'un label de sensibilité appliqué
# manuellement dans Outlook.
#
# Ici on crée une règle qui détecte un mot-clé dans l'objet ou le corps du mail,
# et applique automatiquement le template OME "Chiffrer" (Encrypt-Only).
#
# Encrypt-Only vs Do Not Forward :
#   Encrypt-Only  : le contenu est chiffré en transit et au repos, mais le destinataire
#                   peut transférer, copier, imprimer librement une fois déchiffré.
#                   Utile pour la confidentialité en transit — on protège l'interception,
#                   pas l'usage final.
#
#   Do Not Forward : le contenu est chiffré ET les droits sont restreints — le destinataire
#                    ne peut pas transférer, copier ni imprimer. La protection suit le mail.
#                    Exo 3c.
#
# ATTENTION — Noms des templates localisés :
#   Sur un tenant configuré en français, les templates built-in s'appellent :
#     "Chiffrer"          = Encrypt-Only en anglais
#     "Ne pas transférer" = Do Not Forward en anglais
#   Sur un tenant en anglais (prod internationale, tenant client) :
#     "Encrypt-Only"
#     "Do Not Forward"
#   Le nom passé à -ApplyRightsProtectionTemplate DOIT correspondre exactement
#   au nom retourné par Get-RMSTemplate sur CE tenant.
#   Vérifier toujours avec : Get-RMSTemplate | Select-Object Name
#   avant de créer une rule sur un tenant inconnu — sinon la rule est créée
#   mais le chiffrement ne s'applique pas (erreur silencieuse).
#
# Ce que fait ce script :
#   1. Vérifie que le template "Chiffrer" existe sur le tenant
#   2. Crée la Transport Rule avec détection du mot-clé CONFIDENTIEL
#   3. Vérifie la création et affiche l'état
#
# Module requis : ExchangeOnlineManagement
# Connexion : Connect-ExchangeOnline
# Licence requise : Microsoft Purview Message Encryption (inclus E3/E5)
# ========================================================================================

# --- OUVERTURE ---
Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
Connect-ExchangeOnline -UserPrincipalName GeptorAdmin@0n4mg.onmicrosoft.com -ShowBanner:$false

# --- VARIABLES DU LAB ---
# Le nom du template tel que retourné par Get-RMSTemplate sur CE tenant (FR).
# Sur un tenant EN, remplacer par "Encrypt-Only".
$TemplateName = "Chiffrer"

# Le mot-clé déclencheur — détecté dans l'objet ET le corps du mail.
# En prod on utilise souvent plusieurs mots-clés, ou un SIT, ou un label de sensibilité
# comme condition. Ici on garde simple pour l'exercice.
$Keyword      = "CONFIDENTIEL"

$RuleName     = "OME-EncryptOnly-MotCle-Confidentiel"

# --- ÉTAPE 1 : Vérification du template ---
Write-Host "1. Vérification du template RMS '$TemplateName'..." -ForegroundColor Cyan

$Template = Get-RMSTemplate | Where-Object { $_.Name -eq $TemplateName }

if (-not $Template) {
    Write-Host "-> ÉCHEC : template '$TemplateName' introuvable." -ForegroundColor Red
    Write-Host "   Lister les templates disponibles : Get-RMSTemplate | Select-Object Name" -ForegroundColor Yellow
    Write-Host "   Sur tenant EN, le nom est 'Encrypt-Only'." -ForegroundColor Yellow
    Disconnect-ExchangeOnline -Confirm:$false
    return
}
Write-Host "-> OK : template '$TemplateName' trouvé (Guid : $($Template.Guid))`n" -ForegroundColor Green

# --- ÉTAPE 2 : Vérification qu'une rule du même nom n'existe pas déjà ---
Write-Host "2. Vérification du nom de la rule..." -ForegroundColor Cyan

$ExistingRule = Get-TransportRule -Identity $RuleName -ErrorAction SilentlyContinue
if ($ExistingRule) {
    Write-Host "-> Une rule '$RuleName' existe déjà (State : $($ExistingRule.State))." -ForegroundColor Yellow
    Write-Host "   Suppression de l'ancienne rule avant recréation..." -ForegroundColor Yellow
    Remove-TransportRule -Identity $RuleName -Confirm:$false
    Start-Sleep -Seconds 3
    Write-Host "-> Ancienne rule supprimée.`n" -ForegroundColor Green
} else {
    Write-Host "-> Nom disponible.`n" -ForegroundColor Green
}

# --- ÉTAPE 3 : Création de la Transport Rule ---
Write-Host "3. Création de la Transport Rule '$RuleName'..." -ForegroundColor Cyan

# Paramètres de la rule — explication de chaque paramètre :
#
#   -Name : identifiant unique de la rule dans Exchange.
#
#   -SentToScope NotInOrganization : condition — s'applique uniquement aux mails
#     sortants vers l'extérieur du tenant. "InOrganization" = interne seulement,
#     "NotInOrganization" = externe seulement, pas de paramètre = tous les mails.
#     Ici on chiffre les mails SORTANTS contenant CONFIDENTIEL — logique.
#
#   -SubjectOrBodyContainsWords : condition — détecte le mot-clé dans l'objet
#     ou le corps du mail. Accepte un tableau de mots-clés (@("mot1","mot2")).
#     Insensible à la casse par défaut.
#
#   -ApplyRightsProtectionTemplate : action — applique le template RMS spécifié.
#     C'est cette action qui déclenche le chiffrement OME.
#     Le nom doit correspondre EXACTEMENT à Get-RMSTemplate (cf. note en-tête).
#
#   -Priority : ordre d'évaluation des rules. 0 = évaluée en premier.
#     En prod, les rules sont évaluées dans l'ordre de priorité et s'arrêtent
#     à la première correspondance par défaut (sauf si StopRuleProcessing = $false).
#
#   -Comments : description affichée dans EAC — toujours renseigner en prod
#     pour la traçabilité et la gestion des changements.
try {
    $NewRule = New-TransportRule `
        -Name                         $RuleName `
        -SentToScope                  NotInOrganization `
        -SubjectOrBodyContainsWords   $Keyword `
        -ApplyRightsProtectionTemplate $TemplateName `
        -Priority                     0 `
        -Comments                     "OME Lab 3b — Chiffrement Encrypt-Only automatique sur mails sortants contenant '$Keyword'." `
        -ErrorAction Stop

    Write-Host "-> Rule créée. Guid : $($NewRule.Guid)`n" -ForegroundColor Green
}
catch {
    Write-Host "-> Échec création : $_" -ForegroundColor Red
    Disconnect-ExchangeOnline -Confirm:$false
    return
}

# --- ÉTAPE 4 : Vérification ---
Write-Host "4. Vérification (attente 15s propagation)..." -ForegroundColor Cyan
Start-Sleep -Seconds 15

$CheckRule = Get-TransportRule -Identity $RuleName -ErrorAction SilentlyContinue

if (-not $CheckRule) {
    Write-Host "-> ATTENTION : rule introuvable après vérification." -ForegroundColor Yellow
} else {
    Write-Host "-> Rule confirmée :" -ForegroundColor Green

    # State : "Enabled" = active immédiatement après création.
    # Contrairement aux DLP policies qui démarrent en mode Test, les Transport Rules
    # sont actives dès la création — pas de mode simulation natif.
    # Pour tester sans impact : désactiver avec Disable-TransportRule après vérification.
    [PSCustomObject]@{
        Nom           = $CheckRule.Name
        Etat          = $CheckRule.State
        Priorite      = $CheckRule.Priority
        Condition     = "Objet/Corps contient '$Keyword' + destinataire externe"
        Action        = "Appliquer template RMS : $TemplateName"
        Commentaire   = $CheckRule.Comments
    } | Format-List
}

# --- NOTE IMPORTANTE ---
Write-Host "-> INFO : La rule est active immédiatement." -ForegroundColor Yellow
Write-Host "   Pour désactiver sans supprimer : Disable-TransportRule -Identity '$RuleName'" -ForegroundColor Yellow

# --- NETTOYAGE MÉMOIRE ---
Remove-Variable TemplateName, Keyword, RuleName, Template, ExistingRule, NewRule, CheckRule `
    -ErrorAction SilentlyContinue

# --- FERMETURE ---
Disconnect-ExchangeOnline -Confirm:$false
Write-Host "`nSession Exchange Online fermée." -ForegroundColor Magenta
