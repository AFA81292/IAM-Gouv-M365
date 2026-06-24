# ========================================================================================
# Exercice 3e : Purview — Message Encryption — Audit unifié du chiffrement automatique
# ========================================================================================
# Concept : Lister l'intégralité du chiffrement automatique configuré sur le tenant.
# Depuis l'exercice 3c, le chiffrement automatique vit dans deux types d'objets distincts :
#
#   Transport Rules (ETR)      → chiffrement par mot-clé ou scope (exos 3b, 3d)
#   DLP Compliance Rules (DLP) → chiffrement par classification SIT (exo 3c)
#
# Un audit qui n'interroge que Get-TransportRule manquerait silencieusement toutes les
# règles DLP de chiffrement — et inversement. Ce script normalise les deux sources
# dans une sortie unifiée pour un état des lieux complet en un seul passage.
#
# Ce que fait ce script :
#   1. Reset total de session (dual session IPPS + EXO)
#   2. Audite les Transport Rules avec action ApplyRightsProtectionTemplate
#   3. Audite les DLP Compliance Rules avec action EncryptRMSTemplate
#   4. Affiche la sortie unifiée
#   5. Ferme proprement toutes les sessions
#
# Association DLP Rule → Policy parente :
#   On ne suppose pas un champ "ParentPolicyName" fiable sur l'objet rule —
#   Get-DlpComplianceRule ne documente pas ce champ de manière stable.
#   On parcourt les policies via Get-DlpCompliancePolicy et on filtre leurs règles
#   via -Policy : syntaxe explicitement documentée par Microsoft.
#
# Dual session requise :
#   Connect-ExchangeOnline → Get-TransportRule (Transport Rules Exchange)
#   Connect-IPPSSession    → Get-DlpCompliancePolicy / Get-DlpComplianceRule (Purview)
#
# Module requis : ExchangeOnlineManagement
# ========================================================================================

# --- OUVERTURE — RESET DE SESSION TOTAL ---
# Get-PSSession | Remove-PSSession : ferme toute session résiduelle (IPPS ou EXO)
# héritée d'un script précédent du chapitre.
# $env:MSAL_ENABLE_WAM = "0" requis pour Connect-IPPSSession — contournement du
# cache WAM qui bloque l'authentification interactive sur certains environnements.
Get-PSSession | Remove-PSSession
$env:MSAL_ENABLE_WAM = "0"
Connect-IPPSSession  -UserPrincipalName GeptorAdmin@0n4mg.onmicrosoft.com -ShowBanner:$false
Connect-ExchangeOnline -UserPrincipalName GeptorAdmin@0n4mg.onmicrosoft.com -ShowBanner:$false

# Tableau de résultats normalisés — alimenté par les deux étapes d'audit.
$AuditResults = @()

# ========================================================================================
# ÉTAPE 1 : Audit des Transport Rules avec action de chiffrement
# ========================================================================================
Write-Host "1. Audit des Transport Rules..." -ForegroundColor Cyan

# Get-TransportRule retourne toutes les règles Exchange du tenant.
# On filtre sur la présence de la propriété ApplyRightsProtectionTemplate —
# c'est l'action qui déclenche le chiffrement OME dans une ETR.
# Les règles sans cette propriété (règles de routage, de disclaimer, etc.) sont ignorées.
$EncryptingTransportRules = Get-TransportRule |
    Where-Object { $_.ApplyRightsProtectionTemplate }

foreach ($Rule in $EncryptingTransportRules) {
    $AuditResults += [PSCustomObject]@{
        Type      = "TransportRule"
        Nom       = $Rule.Name
        # Mécanisme : ETR = condition sur mot-clé (SubjectOrBodyContainsWords)
        # ou sur scope (FromScope, SentToScope) — pas de SIT impliqué.
        Mecanisme = "Mot-clé / Scope (ETR)"
        # Mode : AuditAndNotify = test / Enforce = actif
        # State : Enabled = règle active / Disabled = règle désactivée
        Statut    = "$($Rule.Mode) / $($Rule.State)"
        Template  = $Rule.ApplyRightsProtectionTemplate
    }
}
Write-Host "-> $($EncryptingTransportRules.Count) Transport Rule(s) de chiffrement trouvée(s).`n" -ForegroundColor Green

# ========================================================================================
# ÉTAPE 2 : Audit des DLP Compliance Rules avec action de chiffrement
# ========================================================================================
Write-Host "2. Audit des DLP Compliance Rules..." -ForegroundColor Cyan

# Stratégie d'association Rule → Policy :
#   On itère sur toutes les policies via Get-DlpCompliancePolicy,
#   puis on récupère les règles de chaque policy via -Policy $Policy.Name.
#   C'est la syntaxe documentée Microsoft — plus fiable que de chercher un champ
#   "ParentPolicyName" qui n'est pas garanti sur l'objet rule.
$AllDlpPolicies = Get-DlpCompliancePolicy
$DlpCount       = 0

foreach ($Policy in $AllDlpPolicies) {
    # -ErrorAction SilentlyContinue : certaines policies peuvent être en cours de
    # suppression asynchrone (propagation 24h) — on ignore les erreurs de lecture.
    $PolicyRules = Get-DlpComplianceRule -Policy $Policy.Name -ErrorAction SilentlyContinue

    foreach ($Rule in $PolicyRules) {
        # On filtre sur EncryptRMSTemplate — propriété présente uniquement sur les règles
        # DLP configurées avec une action de chiffrement (exercice 3c).
        # Les règles DLP sans chiffrement (blocage, notification, rapport) sont ignorées.
        if ($Rule.EncryptRMSTemplate) {
            $DlpCount++
            $AuditResults += [PSCustomObject]@{
                Type      = "DlpComplianceRule"
                Nom       = $Rule.Name
                # Mécanisme : DLP = condition sur SIT (ContentContainsSensitiveInformation)
                # déclenché par classification automatique du contenu.
                Mecanisme = "Classification SIT (DLP)"
                # Statut combine le Mode de la Policy parente et l'état Disabled de la Rule.
                # Une rule Disabled:False sur une Policy en mode Enable = règle active.
                # Une rule Disabled:True = règle désactivée indépendamment de la policy.
                Statut    = "Policy:$($Policy.Mode) / Disabled:$($Rule.Disabled)"
                Template  = $Rule.EncryptRMSTemplate
            }
        }
    }
}
Write-Host "-> $DlpCount DLP Compliance Rule(s) de chiffrement trouvée(s).`n" -ForegroundColor Green

# ========================================================================================
# ÉTAPE 3 : Sortie unifiée
# ========================================================================================
Write-Host "=== AUDIT COMPLET — CHIFFREMENT AUTOMATIQUE DU TENANT ===" -ForegroundColor Magenta

if ($AuditResults.Count -eq 0) {
    Write-Host "-> Aucune règle de chiffrement automatique trouvée sur ce tenant." -ForegroundColor Yellow
    Write-Host "   Vérifier que les exercices 3b, 3c, 3d ont bien été exécutés." -ForegroundColor Yellow
} else {
    $AuditResults | Format-Table -AutoSize
    Write-Host "-> $($AuditResults.Count) règle(s) de chiffrement au total :" -ForegroundColor Green
    Write-Host "   $($EncryptingTransportRules.Count) Transport Rule(s) ETR" -ForegroundColor Green
    Write-Host "   $DlpCount DLP Compliance Rule(s)`n" -ForegroundColor Green
}

# ========================================================================================
# RÉSUMÉ
# ========================================================================================
Write-Host "=== RÉSUMÉ ===" -ForegroundColor Magenta
[PSCustomObject]@{
    TotalRègles        = $AuditResults.Count
    TransportRules     = $EncryptingTransportRules.Count
    DLPComplianceRules = $DlpCount
    Sources            = "Get-TransportRule (EXO) + Get-DlpComplianceRule (IPPS)"
    Remarque           = "Un audit sur une seule source manquerait silencieusement l'autre type de règle."
} | Format-List

# ========================================================================================
# NETTOYAGE MÉMOIRE
# ========================================================================================
Remove-Variable AuditResults, EncryptingTransportRules, AllDlpPolicies,
                DlpCount, Policy, PolicyRules, Rule `
                -ErrorAction SilentlyContinue

# ========================================================================================
# FERMETURE — RESET DE SESSION TOTAL
# ========================================================================================
Get-PSSession | Remove-PSSession
Write-Host "Sessions IPPS et Exchange Online fermées proprement." -ForegroundColor Magenta
