# ========================================================================================
# Exercice 3d : Purview — Message Encryption — Transport Rule Do Not Forward
#               (mails vers destinataires externes)
# ========================================================================================
# Concept : Appliquer automatiquement le template "Do Not Forward" sur tout mail envoyé
# vers un destinataire extérieur au tenant. Contrairement à 3b/3c où la condition
# portait sur l'EXPÉDITEUR (FromScope), ici la condition porte sur le DESTINATAIRE :
# SentToScope "NotInOrganization".
#
# Ce que fait ce script :
#   1. Reset total de session
#   2. Vérifie que RMS est actif (prérequis 3a)
#   3. Résout le template Do Not Forward (EN + FR, ou override manuel)
#   4. Recherche un nom de règle disponible (auto-incrément)
#   5. Crée la règle en mode AuditAndNotify (test)
#   6. Vérifie la règle créée
#   7. Bascule en mode Enforce
#   8. Vérifie l'état final
#   9. Ferme proprement toutes les sessions
#
# Pourquoi une Transport Rule (pas une DLP Rule comme en 3c) ?
#   SentToScope "NotInOrganization" est un prédicat de flux de messagerie Exchange —
#   pas un prédicat DLP-related. Il n'est pas concerné par la dépréciation de
#   MessageContainsDataClassifications dans les ETR (aka.ms/NoDLPinETRs).
#   Une seule session Exchange Online suffit — pas besoin de Connect-IPPSSession.
#
# Do Not Forward vs Encrypt-Only (3b) :
#   Encrypt-Only / Chiffrer   : chiffrement seul — le destinataire PEUT transférer,
#                                copier, imprimer. Protection en transit uniquement.
#   Do Not Forward / Ne pas transférer : chiffrement + restrictions — le destinataire
#                                NE PEUT PAS transférer, copier ni imprimer.
#                                La protection suit le mail où qu'il aille.
#                                Posture standard pour les échanges externes sensibles.
#
# Choix pédagogique assumé : pas de condition de contenu (mot-clé ou SIT) —
# la règle s'applique à TOUT mail externe, sans filtrage. Agressif pour un exo
# de démonstration ; en production, on la combinerait avec une condition de contenu
# (SubjectOrBodyContainsWords ou SIT) pour éviter de chiffrer de la correspondance anodine.
#
# Module requis : ExchangeOnlineManagement
# Connexion     : Connect-ExchangeOnline (session unique — pas de dual session requise)
# ========================================================================================

# --- OUVERTURE — RESET DE SESSION TOTAL ---
# Get-PSSession | Remove-PSSession : ferme toute session résiduelle (IPPS ou EXO)
# héritée d'un script précédent. On utilise ce pattern plutôt que
# Disconnect-ExchangeOnline seul pour couvrir le cas où une session IPPS
# résiduelle de 3c serait encore ouverte.
Get-PSSession | Remove-PSSession
Connect-ExchangeOnline -UserPrincipalName GeptorAdmin@0n4mg.onmicrosoft.com -ShowBanner:$false

# ========================================================================================
# ÉTAPE 0 : Variables à confirmer avant exécution
# ========================================================================================
# $TemplateNameOverride : si renseigné, saute toute résolution automatique EN/FR.
# Renseigner uniquement si l'heuristique de l'étape 2 échoue sur ce tenant.
# Exemple : $TemplateNameOverride = "Do Not Forward"
$TemplateNameOverride = $null

# ========================================================================================
# ÉTAPE 1 : Garde-fou — RMS doit être actif
# ========================================================================================
Write-Host "1. Vérification du prérequis RMS..." -ForegroundColor Cyan

$IRMConfig = Get-IRMConfiguration
if (-not $IRMConfig.AzureRMSLicensingEnabled) {
    Write-Host "-> ARRÊT : RMS non actif sur le tenant (voir exercice 3a)." -ForegroundColor Red
    Write-Host "   Activer via : Set-IRMConfiguration -AzureRMSLicensingEnabled `$true" -ForegroundColor Yellow
    Get-PSSession | Remove-PSSession
    return
}
Write-Host "-> OK : RMS actif.`n" -ForegroundColor Green

# ========================================================================================
# ÉTAPE 2 : Résolution du template Do Not Forward
# ========================================================================================
Write-Host "2. Résolution du template Do Not Forward..." -ForegroundColor Cyan

if ($TemplateNameOverride) {
    $Template = $TemplateNameOverride
    Write-Host "-> Override manuel utilisé : '$Template'`n" -ForegroundColor Yellow
}
else {
    $AllTemplates = Get-RMSTemplate

    # Inverse du filtre de 3b/3c : on CHERCHE "Forward" ou "transférer"
    # au lieu de les exclure. Un seul template correspond sur un tenant standard.
    # Limite documentée : tenant dans une 3e langue → renseigner $TemplateNameOverride.
    $DnfTemplate = $AllTemplates |
        Where-Object { $_.Name -match "Forward|transférer" } |
        Select-Object -First 1

    if (-not $DnfTemplate) {
        Write-Host "-> ARRÊT : aucun template Do Not Forward résolu automatiquement (heuristique EN/FR)." -ForegroundColor Red
        Write-Host "   Templates disponibles sur ce tenant :" -ForegroundColor Yellow
        $AllTemplates | Select-Object Name | Format-Table -AutoSize
        Write-Host "   -> Renseigner `$TemplateNameOverride en ÉTAPE 0 avec le nom exact." -ForegroundColor Yellow
        Get-PSSession | Remove-PSSession
        return
    }
    $Template = $DnfTemplate.Name
    Write-Host "-> Template résolu automatiquement : '$Template'`n" -ForegroundColor Green
}

# ========================================================================================
# ÉTAPE 3 : Recherche d'un nom de règle disponible (auto-incrément)
# ========================================================================================
Write-Host "3. Recherche d'un nom de règle disponible..." -ForegroundColor Cyan

# Les Transport Rules n'ont pas la même propagation asynchrone de 24h que les objets
# Purview (DLP Policy, labels, SIT). Mais on conserve la même stratégie d'auto-incrément
# par cohérence avec le reste du chapitre — une seule approche dans tous les exercices,
# sans hypothèse non vérifiée sur la rapidité de suppression d'une règle Exchange.
$BaseRuleName = "OME-N7-DoNotForward-Externe"
$RuleName     = $BaseRuleName
$Counter      = 2

while (Get-TransportRule -Identity $RuleName -ErrorAction SilentlyContinue) {
    Write-Host "   '$RuleName' déjà pris — test avec suffixe -v$Counter..." -ForegroundColor Yellow
    $RuleName = "$BaseRuleName-v$Counter"
    $Counter++
}
Write-Host "-> Nom retenu pour la règle : '$RuleName'`n" -ForegroundColor Green

# ========================================================================================
# ÉTAPE 4 : Paramètres de la règle
# ========================================================================================
Write-Host "4. Paramètres de la règle..." -ForegroundColor Cyan
Write-Host "   Nom      : $RuleName" -ForegroundColor Gray
Write-Host "   Portée   : SentToScope NotInOrganization (destinataire externe)" -ForegroundColor Gray
Write-Host "   Template : $Template`n" -ForegroundColor Gray

# SentToScope "NotInOrganization" : la règle se déclenche uniquement si au moins
# un destinataire est externe au tenant. Les mails internes (To: interne uniquement)
# ne sont pas impactés — même si l'expéditeur est interne.
# Attention : un mail à plusieurs destinataires dont UN seul est externe matchera
# la règle — tout le message sera chiffré Do Not Forward, y compris pour les
# destinataires internes.
$RuleParams = @{
    Name                          = $RuleName
    Comments                      = "Exo 3d — Chiffre avec restriction de transfert les mails envoyés à des destinataires externes. Voir GitHub Purview/03_Message_Encryption."
    SentToScope                   = "NotInOrganization"
    ApplyRightsProtectionTemplate = $Template
    Mode                          = "AuditAndNotify"
}

# ========================================================================================
# ÉTAPE 5 : Création de la règle en mode AuditAndNotify
# ========================================================================================
Write-Host "5. Création de la règle '$RuleName' en mode AuditAndNotify..." -ForegroundColor Cyan

try {
    New-TransportRule @RuleParams -ErrorAction Stop | Out-Null
    Write-Host "-> Règle créée en mode AuditAndNotify.`n" -ForegroundColor Green
}
catch {
    Write-Host "-> Échec de la création : $_`n" -ForegroundColor Red
    Get-PSSession | Remove-PSSession
    return
}

# ========================================================================================
# ÉTAPE 6 : Vérification en mode test
# ========================================================================================
Write-Host "6. Vérification de la règle créée..." -ForegroundColor Cyan

# REX : la propagation des Transport Rules dans Exchange Online n'est pas instantanée.
# 30 secondes couvrent la latence de réplication Exchange.
Start-Sleep -Seconds 30

Get-TransportRule -Identity $RuleName |
    Select-Object Name, Mode, State, SentToScope |
    Format-List

# ========================================================================================
# ÉTAPE 7 : Bascule en mode Enforce
# ========================================================================================
Write-Host "7. Bascule de la règle en mode Enforce..." -ForegroundColor Cyan

try {
    Set-TransportRule -Identity $RuleName -Mode Enforce -ErrorAction Stop
    Write-Host "-> Règle basculée en mode Enforce.`n" -ForegroundColor Green
}
catch {
    Write-Host "-> Échec de la bascule : $_`n" -ForegroundColor Red
}

# ========================================================================================
# ÉTAPE 8 : Vérification finale
# ========================================================================================
Write-Host "8. Vérification de l'état final..." -ForegroundColor Cyan

Start-Sleep -Seconds 30

$FinalRule = Get-TransportRule -Identity $RuleName -ErrorAction SilentlyContinue

if ($FinalRule) {
    $FinalRule | Select-Object Name, Mode, State, Priority | Format-List

    if ($FinalRule.Mode -eq "Enforce" -and $FinalRule.State -eq "Enabled") {
        Write-Host "-> OK : règle active en mode Enforce.`n" -ForegroundColor Green
    } else {
        Write-Host "-> ATTENTION : état inattendu — vérifier Mode/State ci-dessus.`n" -ForegroundColor Yellow
    }
} else {
    Write-Host "-> ATTENTION : règle non trouvée lors de la vérification finale." -ForegroundColor Red
}

# ========================================================================================
# RÉSUMÉ
# ========================================================================================
Write-Host "=== RÉSUMÉ ===" -ForegroundColor Magenta
[PSCustomObject]@{
    RègleCréée   = if ($FinalRule) { $FinalRule.Name  } else { $RuleName }
    Mode         = if ($FinalRule) { $FinalRule.Mode  } else { "Non vérifié" }
    État         = if ($FinalRule) { $FinalRule.State } else { "Non vérifié" }
    Portée       = "SentToScope: NotInOrganization (tout destinataire externe)"
    Template     = $Template
    Restriction  = "Do Not Forward : pas de transfert, copie ni impression possible"
    TestManuel   = "Envoyer depuis Shepard@ vers une adresse externe — vérifier via Message Trace que la règle '$RuleName' s'est déclenchée."
    NoteProduction = "En prod : combiner avec une condition de contenu (SubjectOrBodyContainsWords ou SIT) pour éviter de chiffrer toute correspondance externe anodine."
} | Format-List

# ========================================================================================
# NETTOYAGE MÉMOIRE
# ========================================================================================
Remove-Variable TemplateNameOverride, IRMConfig, AllTemplates, DnfTemplate, Template,
                BaseRuleName, RuleName, Counter, RuleParams, FinalRule `
                -ErrorAction SilentlyContinue

# ========================================================================================
# FERMETURE — RESET DE SESSION TOTAL
# ========================================================================================
Get-PSSession | Remove-PSSession
Write-Host "Session Exchange Online fermée proprement." -ForegroundColor Magenta
