# ========================================================================================
# Exercice 4b : DLP — Policy avec règle de blocage, seuil et notification utilisateur
# ========================================================================================
# Concept : Cet exercice est le pendant de 4a en mode enforcement réel.
# En 4a : mode Test, détection seule, aucun impact utilisateur.
# Ici    : mode Enable, blocage actif dès 1 occurrence, notification utilisateur
#          avec possibilité de justification métier (override).
#
# Delta pédagogique vs 4a :
#   - Policy créée en mode Enable (pas TestWithNotifications)
#   - Règle avec -BlockAccess $true : le partage/envoi est bloqué
#   - -NotifyUser avec message de conseil à l'utilisateur
#   - -BlockAccessScope "PerUser" : blocage ciblé sur l'utilisateur contrevenant,
#     pas sur tout le fichier (les autres collaborateurs conservent l'accès)
#   - -AllowOverride : l'utilisateur peut passer outre avec une justification
#     (comportement typique en production — on informe et on responsabilise,
#      on ne bloque pas aveuglément sans sortie de secours)
#
# Ce que fait ce script :
#   1. Reset total de session
#   2. Recherche un nom disponible (auto-incrément)
#   3. Crée la DLP policy en mode Enable sur Exchange + SharePoint + OneDrive
#   4. Crée la règle avec blocage + notification + override possible
#   5. Vérifie la création depuis la source de vérité
#   6. Ferme proprement toutes les sessions
#
# Prérequis : SIT built-in "Credit Card Number" (natif, aucune création nécessaire)
#
# Module requis : ExchangeOnlineManagement
# Connexion : Connect-IPPSSession
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
# ÉTAPE 1 : Recherche d'un nom disponible (auto-incrément)
# ========================================================================================
Write-Host "1. Recherche d'un nom disponible..." -ForegroundColor Cyan

$BasePolicyName = "DLP-Citadelle-CreditCard-Block"
$PolicyName     = $BasePolicyName
$Counter        = 2
while (Get-DlpCompliancePolicy -Identity $PolicyName -ErrorAction SilentlyContinue) {
    Write-Host "   '$PolicyName' déjà pris — test avec suffixe -v$Counter..." -ForegroundColor Yellow
    $PolicyName = "$BasePolicyName-v$Counter"
    $Counter++
}
Write-Host "-> Nom retenu pour la policy : '$PolicyName'" -ForegroundColor Green

$BaseRuleName = "RULE-Citadelle-CreditCard-Block"
$RuleName     = $BaseRuleName
$Counter      = 2
while (Get-DlpComplianceRule -Identity $RuleName -ErrorAction SilentlyContinue) {
    Write-Host "   '$RuleName' déjà pris — test avec suffixe -v$Counter..." -ForegroundColor Yellow
    $RuleName = "$BaseRuleName-v$Counter"
    $Counter++
}
Write-Host "-> Nom retenu pour la règle : '$RuleName'`n" -ForegroundColor Green

# ========================================================================================
# ÉTAPE 2 : Création de la DLP policy en mode Enable
# ========================================================================================
Write-Host "2. Création de la DLP policy '$PolicyName' en mode Enable..." -ForegroundColor Cyan

# Différence clé vs 4a : -Mode "Enable"
# En mode Enable, les actions définies dans les règles s'appliquent réellement.
# Un blocage reste un blocage — pas de simulation. À utiliser en connaissance de cause.
# Sur un tenant de dev sans utilisateurs actifs, le risque est nul.
# En production, on passe toujours par TestWithNotifications avant Enable.
try {
    $NewPolicy = New-DlpCompliancePolicy `
        -Name               $PolicyName `
        -ExchangeLocation   "All" `
        -SharePointLocation "All" `
        -OneDriveLocation   "All" `
        -Mode               "Enable" `
        -Comment            "Exo 4b — DLP protection CB avec blocage actif. Mode Enable." `
        -ErrorAction Stop

    Write-Host "-> Policy créée : $($NewPolicy.Name) [Mode : $($NewPolicy.Mode)]`n" -ForegroundColor Green
}
catch {
    Write-Host "-> Échec de la création de la policy : $_" -ForegroundColor Red
    Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
    Get-PSSession | Remove-PSSession
    return
}

# ========================================================================================
# ÉTAPE 3 : Création de la règle avec blocage
# ========================================================================================
Write-Host "3. Création de la règle '$RuleName' avec blocage actif..." -ForegroundColor Cyan

# --- CONDITION ---
# Même SIT que 4a, même syntaxe (clés minuscules, confidencelevel textuel).
# Seuil : 1 occurrence suffit pour déclencher le blocage (mincount = "1").
$SITCondition = @(
    @{
        name            = "Credit Card Number"
        mincount        = "1"
        confidencelevel = "Medium"
    }
)

# --- ACTIONS ---
# Plusieurs actions complémentaires sur cette règle — détail ci-dessous.
#
# -BlockAccess $true :
#   L'action principale. Bloque l'accès au contenu détecté.
#   Pour Exchange : l'email n'est pas envoyé, l'expéditeur reçoit un NDR.
#   Pour SharePoint/OneDrive : le partage externe est bloqué.
#
# -BlockAccessScope "PerUser" :
#   Définit la portée du blocage sur SPO/ODfB.
#   "PerUser"  : seul l'utilisateur contrevenant est bloqué — les autres
#                collaborateurs du fichier conservent leur accès. C'est la
#                posture la moins disruptive en production.
#   "All"      : tout accès au fichier est bloqué pour tout le monde.
#   Note : ce paramètre s'applique SPO/ODfB uniquement, pas à Exchange.
#
# -NotifyUser "LastModifier" :
#   Envoie une notification à l'utilisateur qui a déclenché la règle.
#   Le message explique pourquoi son action a été bloquée.
#   Valeur "LastModifier" = celui qui a modifié/partagé/envoyé le contenu.
#   RAPPEL PIÈGE : "LastModifiedBy" (doc officielle) est INVALIDE — "LastModifier".
#
# -NotifyUserType "NotifyOnly" :
#   Détermine la nature de la notification utilisateur.
#   "NotifyOnly"     : information seule, aucune action possible côté utilisateur.
#   "BlockWithOverride" : voir -AllowOverride ci-dessous.
#   Note : ce paramètre interagit avec -AllowOverride.
#
# -AllowOverride "WithoutJustification" (optionnel — décommenté si souhaité) :
#   Permet à l'utilisateur de passer outre le blocage.
#   Valeurs :
#     "WithoutJustification" : override libre, sans saisie de raison
#     "WithJustification"    : l'utilisateur doit saisir une justification métier
#                              (la justification est loggée dans l'audit Purview)
#   En production, "WithJustification" est la posture standard pour les données
#   financières — on responsabilise sans bloquer aveuglément.
#   Ici on laisse en commentaire pour garder un blocage strict sur le tenant dev.
#
# -GenerateIncidentReport "SiteAdmin" + -IncidentReportContent @("All") :
#   Même comportement que 4a — rapport d'incident envoyé à l'admin.
#   En mode Enable, le rapport inclut aussi les détails du blocage appliqué.
try {
    $NewRule = New-DlpComplianceRule `
        -Name                                $RuleName `
        -Policy                              $PolicyName `
        -ContentContainsSensitiveInformation $SITCondition `
        -AccessScope                         "NotInOrganization" `
        -BlockAccess                         $true `
        -BlockAccessScope                    "PerUser" `
        -NotifyUser                          "LastModifier" `
        -GenerateIncidentReport              "SiteAdmin" `
        -IncidentReportContent               @("All") `
        -Comment                             "Exo 4b — Blocage CB (Medium, 1+), notification LastModifier, rapport SiteAdmin." `
        -ErrorAction Stop

    Write-Host "-> Règle créée : $($NewRule.Name)" -ForegroundColor Green
    Write-Host "   Policy parente : $($NewRule.ParentPolicyName)`n" -ForegroundColor Gray
}
catch {
    Write-Host "-> Échec de la création de la règle : $_" -ForegroundColor Red
    Write-Host "   La policy '$PolicyName' a été créée mais reste sans règle." -ForegroundColor Yellow
    Write-Host "   Supprimer via : Remove-DlpCompliancePolicy -Identity '$PolicyName' -Confirm:`$false" -ForegroundColor Yellow
    Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
    Get-PSSession | Remove-PSSession
    return
}

# ========================================================================================
# ÉTAPE 4 : Vérification depuis la source de vérité
# ========================================================================================
Write-Host "4. Vérification depuis le backend Purview..." -ForegroundColor Cyan
Start-Sleep -Seconds 3

$CheckPolicy = Get-DlpCompliancePolicy -Identity $PolicyName -ErrorAction SilentlyContinue
$CheckRule   = Get-DlpComplianceRule   -Policy   $PolicyName -ErrorAction SilentlyContinue

if ($CheckPolicy) {
    Write-Host "-> Policy confirmée :" -ForegroundColor Green
    [PSCustomObject]@{
        Nom           = $CheckPolicy.Name
        Mode          = $CheckPolicy.Mode
        Exchange      = if ($CheckPolicy.ExchangeLocation)   { "All" } else { "Non configuré" }
        SharePoint    = if ($CheckPolicy.SharePointLocation) { "All" } else { "Non configuré" }
        OneDrive      = if ($CheckPolicy.OneDriveLocation)   { "All" } else { "Non configuré" }
        DistribStatus = $CheckPolicy.DistributionStatus
    } | Format-List
} else {
    Write-Host "-> ATTENTION : policy non trouvée lors de la vérification." -ForegroundColor Red
}

if ($CheckRule) {
    Write-Host "-> Règle confirmée :" -ForegroundColor Green
    [PSCustomObject]@{
        Nom              = $CheckRule.Name
        PolicyParente    = $CheckRule.ParentPolicyName
        Désactivée       = $CheckRule.Disabled
        AccessScope      = $CheckRule.AccessScope
        BlocageActif     = $CheckRule.BlockAccess
        PortéeBlocage    = $CheckRule.BlockAccessScope
        NotifUser        = ($CheckRule.NotifyUser -join ", ")
        RapportIncident  = "SiteAdmin"
    } | Format-List
} else {
    Write-Host "-> ATTENTION : règle non trouvée lors de la vérification." -ForegroundColor Red
}

# ========================================================================================
# ÉTAPE 5 : Résumé
# ========================================================================================
Write-Host "=== RÉSUMÉ ===" -ForegroundColor Magenta

# Rappel architecture DLP 4a vs 4b :
#
#   4a (TestWithNotifications) : détecte → notifie → logge → ne bloque pas
#   4b (Enable + BlockAccess)  : détecte → bloque → notifie → logge → rapport
#
# Les deux policies coexistent sur le tenant. Si un email contient un numéro de CB
# et part vers l'extérieur, les DEUX règles se déclenchent — mais c'est la règle
# avec la priorité la plus haute (numéro le plus bas) qui gagne sur le blocage.
# La précédence des policies DLP est abordée en exo 4e (audit).
[PSCustomObject]@{
    PolicyCréée      = $PolicyName
    RègleCréée       = $RuleName
    Mode             = "Enable (enforcement réel)"
    SITSurveillé     = "Credit Card Number (Medium, 1+ occurrence)"
    Workloads        = "Exchange, SharePoint, OneDrive"
    ActionBlocage    = "Oui — BlockAccess PerUser"
    RapportIncident  = "Oui (SiteAdmin)"
    NotifUtilisateur = "Oui (LastModifier)"
    DistribStatus    = if ($CheckPolicy) { $CheckPolicy.DistributionStatus } else { "Non vérifié" }
} | Format-List

Write-Host "Info : DistributionStatus 'Pending' est normal à la création." -ForegroundColor Yellow
Write-Host "La propagation vers Exchange/SPO/ODfB prend quelques minutes.`n" -ForegroundColor Yellow

# ========================================================================================
# NETTOYAGE MÉMOIRE
# ========================================================================================
Remove-Variable BasePolicyName, PolicyName, BaseRuleName, RuleName, Counter,
                NewPolicy, NewRule, SITCondition, CheckPolicy, CheckRule `
                -ErrorAction SilentlyContinue

# ========================================================================================
# FERMETURE — RESET DE SESSION TOTAL
# ========================================================================================
Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
Get-PSSession | Remove-PSSession
Write-Host "Sessions fermées proprement." -ForegroundColor Magenta
