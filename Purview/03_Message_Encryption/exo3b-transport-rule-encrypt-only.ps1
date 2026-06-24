# ========================================================================================
# Exercice 3b : Purview — Message Encryption — Transport Rule OME automatique
#               (mot-clé CONFIDENTIEL)
# ========================================================================================
# Concept : Une Transport Rule (règle de flux de messagerie Exchange) peut déclencher
# automatiquement le chiffrement OME sur les mails sortants selon des conditions.
# Ici : tout mail interne contenant "CONFIDENTIEL" dans le sujet ou le corps
# est automatiquement chiffré avec le template "Encrypt-Only" / "Chiffrer".
#
# Ce que fait ce script :
#   1. Reset total de session
#   2. Vérifie que RMS est actif (prérequis 3a)
#   3. Résout le nom du template de chiffrement simple (EN + FR, ou override manuel)
#   4. Recherche un nom de règle disponible (auto-incrément)
#   5. Crée la règle en mode AuditAndNotify (test)
#   6. Vérifie la règle créée
#   7. Bascule en mode Enforce (actif)
#   8. Vérifie l'état final
#   9. Ferme proprement toutes les sessions
#
# Cycle Audit → Enforce :
#   AuditAndNotify = règle évaluée, mail traçé dans les logs, action OME NON appliquée.
#                    Permet de valider que la règle matche les bons messages
#                    avant de chiffrer réellement.
#   Enforce        = règle active, chiffrement OME appliqué sur chaque match.
#
# FromScope vs SentToScope :
#   FromScope = "InOrganization"  → la règle se déclenche uniquement si l'expéditeur
#                                   est un utilisateur interne du tenant.
#                                   Évite de traiter les mails entrants externes.
#   SentToScope = "NotInOrganization" → la règle se déclenche uniquement si le
#                                       destinataire est externe. Non utilisé ici —
#                                       on chiffre aussi les échanges internes.
#
# DÉCOUVERTE TECHNIQUE : le nom des templates RMS built-in dépend de la langue
# d'affichage du tenant. Sur un tenant FR : "Chiffrer" et "Ne pas transférer".
# Sur un tenant EN : "Encrypt-Only" et "Do Not Forward". Les GUIDs sont stables
# mais Get-RMSTemplate n'expose pas le GUID de manière utilisable directement dans
# -ApplyRightsProtectionTemplate. On filtre par mots-clés EN + FR avec exclusion
# des templates "Do Not Forward". Un override manuel est disponible si l'heuristique
# échoue sur un tenant dans une autre langue.
#
# Module requis : ExchangeOnlineManagement
# Connexion     : Connect-ExchangeOnline
# ========================================================================================

# --- OUVERTURE — RESET DE SESSION TOTAL ---
# REX : des sessions Exchange Online résiduelles causent des erreurs silencieuses
# sur les cmdlets Transport Rules si le token est expiré.
# -ShowBanner:$false supprime le bandeau de connexion pour un output plus lisible.
Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
Connect-ExchangeOnline -UserPrincipalName GeptorAdmin@0n4mg.onmicrosoft.com -ShowBanner:$false

# ========================================================================================
# ÉTAPE 0 : Override manuel du nom de template (optionnel)
# ========================================================================================
# Si renseigné, toute la résolution automatique EN/FR est sautée — ce nom est utilisé
# tel quel dans -ApplyRightsProtectionTemplate.
# Renseigner uniquement si l'heuristique de l'étape 2 échoue sur ce tenant.
# Exemple : $TemplateNameOverride = "Chiffrer"
$TemplateNameOverride = $null

# ========================================================================================
# ÉTAPE 1 : Garde-fou — vérification du prérequis RMS
# ========================================================================================
Write-Host "1. Vérification du prérequis RMS..." -ForegroundColor Cyan

# Prérequis validé en exercice 3a. On revérifie ici avant toute création de règle —
# une règle avec -ApplyRightsProtectionTemplate créée sur un tenant sans RMS actif
# s'enregistre sans erreur mais ne chiffre rien (échec silencieux à l'exécution).
$IRMConfig = Get-IRMConfiguration
if (-not $IRMConfig.AzureRMSLicensingEnabled) {
    Write-Host "-> ARRÊT : RMS non actif sur le tenant." -ForegroundColor Red
    Write-Host "   Activer via : Set-IRMConfiguration -AzureRMSLicensingEnabled `$true" -ForegroundColor Yellow
    Write-Host "   Puis relancer l'exercice 3a pour valider." -ForegroundColor Yellow
    Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
    return
}
Write-Host "-> OK : RMS actif.`n" -ForegroundColor Green

# ========================================================================================
# ÉTAPE 2 : Résolution du template de chiffrement simple
# ========================================================================================
Write-Host "2. Résolution du template RMS de chiffrement simple..." -ForegroundColor Cyan

if ($TemplateNameOverride) {
    # Override manuel : on fait confiance à ce que l'opérateur a saisi.
    # Si le nom est incorrect, l'étape 5 (New-TransportRule) retournera une erreur explicite.
    $Template = $TemplateNameOverride
    Write-Host "-> Override manuel utilisé : '$Template'`n" -ForegroundColor Yellow
}
else {
    $AllTemplates = Get-RMSTemplate

    # Heuristique EN + FR :
    # On cherche un template dont le nom contient "Encrypt" ou "Chiffrer" (chiffrement simple)
    # ET qui ne contient pas "Forward" ou "transférer" (Do Not Forward — template différent).
    # Limite documentée : un tenant dans une 3e langue (DE, ES, NL...) pourrait ne pas matcher.
    # Solution dans ce cas : renseigner $TemplateNameOverride avec le nom exact vu en étape 3a.
    $PositiveKeywords = "Encrypt|Chiffrer"
    $NegativeKeywords = "Forward|transférer"

    $EncryptTemplate = $AllTemplates | Where-Object {
        $_.Name -match $PositiveKeywords -and $_.Name -notmatch $NegativeKeywords
    } | Select-Object -First 1

    if (-not $EncryptTemplate) {
        Write-Host "-> ARRÊT : aucun template résolu automatiquement (heuristique EN/FR)." -ForegroundColor Red
        Write-Host "   Templates disponibles sur ce tenant :" -ForegroundColor Yellow
        $AllTemplates | Select-Object Name | Format-Table -AutoSize
        Write-Host "   -> Renseigner `$TemplateNameOverride en ÉTAPE 0 avec le nom exact." -ForegroundColor Yellow
        Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
        return
    }

    $Template = $EncryptTemplate.Name
    Write-Host "-> Template résolu automatiquement : '$Template'`n" -ForegroundColor Green
}

# ========================================================================================
# ÉTAPE 3 : Définition des variables et auto-incrément
# ========================================================================================
Write-Host "3. Recherche d'un nom de règle disponible..." -ForegroundColor Cyan

$RuleBaseName = "OME-N7-Confidentiel-Sortant"
$Keyword      = "CONFIDENTIEL"

# DÉCOUVERTE TECHNIQUE : contrairement aux objets Purview (DLP, labels), les Transport
# Rules Exchange n'acceptent pas les noms dupliqués — erreur explicite à la création.
# L'auto-incrément évite ce conflit sur le tenant de dev après plusieurs exécutions.
$RuleName = $RuleBaseName
$Counter  = 2
while (Get-TransportRule -Identity $RuleName -ErrorAction SilentlyContinue) {
    Write-Host "   '$RuleName' déjà pris — test avec suffixe -v$Counter..." -ForegroundColor Yellow
    $RuleName = "$RuleBaseName-v$Counter"
    $Counter++
}
Write-Host "-> Nom retenu pour la règle : '$RuleName'" -ForegroundColor Green
Write-Host "   Mot-clé  : $Keyword (sujet OU corps du message)" -ForegroundColor Gray
Write-Host "   Template : $Template`n" -ForegroundColor Gray

# ========================================================================================
# ÉTAPE 4 : Création de la règle en mode AuditAndNotify
# ========================================================================================
Write-Host "4. Création de la règle '$RuleName' en mode AuditAndNotify..." -ForegroundColor Cyan

# -FromScope "InOrganization" : la règle se déclenche uniquement si l'expéditeur
# est un utilisateur interne du tenant. Sans ce filtre, la règle s'appliquerait aussi
# aux mails entrants de l'extérieur contenant "CONFIDENTIEL" — comportement non souhaité.
#
# -SubjectOrBodyContainsWords : condition textuelle — correspond si le mot-clé est présent
# dans le sujet OU dans le corps du message (logique OR native de la cmdlet).
#
# -ApplyRightsProtectionTemplate : action principale — applique le template RMS résolu.
# Sur Exchange, cette action déclenche le chiffrement OME au niveau du transport,
# avant que le mail ne quitte le serveur Exchange.
#
# -Mode "AuditAndNotify" : évalue la règle et trace dans les logs, mais N'APPLIQUE PAS
# l'action de chiffrement. Permet de valider les matches avant enforcement.
$RuleParams = @{
    Name                          = $RuleName
    Comments                      = "Exo 3b — Chiffre automatiquement les mails internes contenant CONFIDENTIEL. Créé par script — voir GitHub Purview/03_Message_Encryption."
    FromScope                     = "InOrganization"
    SubjectOrBodyContainsWords    = $Keyword
    ApplyRightsProtectionTemplate = $Template
    Mode                          = "AuditAndNotify"
}

try {
    New-TransportRule @RuleParams -ErrorAction Stop | Out-Null
    Write-Host "-> Règle créée en mode AuditAndNotify.`n" -ForegroundColor Green
}
catch {
    Write-Host "-> Échec de la création : $_`n" -ForegroundColor Red
    Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
    return
}

# ========================================================================================
# ÉTAPE 5 : Vérification de la règle en mode test
# ========================================================================================
Write-Host "5. Vérification de la règle créée..." -ForegroundColor Cyan

# REX : la propagation des Transport Rules dans Exchange Online n'est pas instantanée.
# Get-TransportRule relu immédiatement après New-TransportRule peut retourner un état
# incomplet. 30 secondes couvrent la latence de réplication Exchange.
Start-Sleep -Seconds 30

Get-TransportRule -Identity $RuleName |
    Select-Object Name, Mode, State, FromScope, SubjectOrBodyContainsWords |
    Format-List

# ========================================================================================
# ÉTAPE 6 : Bascule en mode Enforce
# ========================================================================================
Write-Host "6. Bascule de la règle en mode Enforce..." -ForegroundColor Cyan

# Mode Enforce = la règle est active et applique réellement le chiffrement OME.
# À n'activer qu'après validation des logs en mode AuditAndNotify.
# Sur le tenant de dev sans trafic mail réel, le risque est nul.
try {
    Set-TransportRule -Identity $RuleName -Mode Enforce -ErrorAction Stop
    Write-Host "-> Règle basculée en mode Enforce.`n" -ForegroundColor Green
}
catch {
    Write-Host "-> Échec de la bascule : $_`n" -ForegroundColor Red
}

# ========================================================================================
# ÉTAPE 7 : Vérification finale
# ========================================================================================
Write-Host "7. Vérification de l'état final..." -ForegroundColor Cyan

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
    RègleCréée  = if ($FinalRule) { $FinalRule.Name  } else { $RuleName }
    Mode        = if ($FinalRule) { $FinalRule.Mode  } else { "Non vérifié" }
    État        = if ($FinalRule) { $FinalRule.State } else { "Non vérifié" }
    Portée      = "FromScope: InOrganization (expéditeurs internes uniquement)"
    MotClé      = $Keyword
    Template    = $Template
    TestManuel  = "Envoyer depuis Shepard@ vers Liara@ avec '$Keyword' dans le sujet."
    Vérification = "Exchange Admin Center > Mail flow > Message trace — vérifier action OME appliquée."
} | Format-List

# ========================================================================================
# NETTOYAGE MÉMOIRE
# ========================================================================================
Remove-Variable IRMConfig, AllTemplates, EncryptTemplate, Template, TemplateNameOverride,
                RuleBaseName, RuleName, Keyword, Counter, RuleParams, FinalRule `
                -ErrorAction SilentlyContinue

# ========================================================================================
# FERMETURE — RESET DE SESSION TOTAL
# ========================================================================================
Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
Write-Host "Session Exchange Online fermée proprement." -ForegroundColor Magenta
