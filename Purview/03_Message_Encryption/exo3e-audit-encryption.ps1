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
#   5. Affiche un résumé chiffré
#   6. Exporte la vue unifiée en CSV horodaté
#   7. Ferme proprement toutes les sessions
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
# Note : ce script est en lecture seule — aucune modification du tenant.
#
# Fichiers CSV générés :
#   ENC_AuditUnifie_YYYYMMDD_HHmmss.csv
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
Connect-IPPSSession    -UserPrincipalName GeptorAdmin@0n4mg.onmicrosoft.com -ShowBanner:$false
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
        # Colonnes ETR disponibles non exportées dans la collection commune :
        #   Conditions détaillées (mots-clés, scope) :
        #     $Rule.SubjectOrBodyContainsWords -join "|"
        #     $Rule.FromScope / $Rule.SentToScope
        #   Priority : ordre d'évaluation des règles — $Rule.Priority
        #   Comments : commentaire admin — $Rule.Comments
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
                # Colonnes DLP disponibles non exportées dans la collection commune :
                #   Policy parente : $Policy.Name (déjà présent dans Statut)
                #   SITs déclencheurs (JSON compact) :
                #     ($Rule.ContentContainsSensitiveInformation | ConvertTo-Json -Compress)
                #   Seuil de confiance et occurrences min : dans ContentContainsSensitiveInformation
                #   NotifyUser : destinataires de la notification — $Rule.NotifyUser -join "|"
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
# EXPORT CSV
# ========================================================================================
Write-Host "Export CSV en cours..." -ForegroundColor Cyan

# EN LABO / Local :
$ExportPath = "D:\Documents\ScriptsPowerShell\Exports\"
# EN PRODUCTION :
# $ExportPath = "$PSScriptRoot\Exports\"

New-Item -ItemType Directory -Force -Path $ExportPath | Out-Null
$Timestamp = Get-Date -Format "yyyyMMdd_HHmmss"

# --- CSV unique : vue unifiée ETR + DLP ---
# Colonnes exportées : Type, Nom, Mecanisme, Statut, Template
# C'est le livrable central de cet exo : une vue multi-sources homogène,
# directement exploitable pour un rapport de gouvernance chiffrement.
#
# Type     : "TransportRule" vs "DlpComplianceRule" — permet de filtrer par source dans Excel.
# Mecanisme: distingue le déclencheur (mot-clé/scope ETR vs classification SIT DLP).
# Statut   : encode Mode + State (ETR) ou Mode policy + Disabled rule (DLP).
#            Une règle "Enforce / Enabled" ou "Policy:Enable / Disabled:False" = active en prod.
# Template : nom du template RMS appliqué — "Encrypt-Only", "Do Not Forward", ou template custom AME.
#
# Colonnes disponibles non exportées (communes) :
#   Pour aller plus loin sur les ETR : SubjectOrBodyContainsWords, FromScope, SentToScope, Priority
#   Pour aller plus loin sur les DLP : ContentContainsSensitiveInformation (JSON), NotifyUser
#   Ces colonnes nécessiteraient soit un second CSV dédié ETR, soit un second CSV dédié DLP,
#   car leur structure est hétérogène entre les deux types de règles.
if ($AuditResults.Count -gt 0) {
    $AuditResults | Export-Csv `
        -Path "$ExportPath\ENC_AuditUnifie_$Timestamp.csv" `
        -Encoding UTF8 -NoTypeInformation
    Write-Host "-> Audit unifié : $($AuditResults.Count) ligne(s) — ENC_AuditUnifie_$Timestamp.csv" -ForegroundColor Green
} else {
    Write-Host "-> Audit unifié : aucune règle de chiffrement trouvée — pas d'export." -ForegroundColor Yellow
}

Write-Host "-> Export terminé dans : $ExportPath`n" -ForegroundColor Green

# ========================================================================================
# NETTOYAGE MÉMOIRE
# ========================================================================================
Remove-Variable AuditResults, EncryptingTransportRules, AllDlpPolicies,
                DlpCount, Policy, PolicyRules, Rule,
                ExportPath, Timestamp `
                -ErrorAction SilentlyContinue

# ========================================================================================
# FERMETURE — RESET DE SESSION TOTAL
# ========================================================================================
Get-PSSession | Remove-PSSession
Write-Host "Sessions IPPS et Exchange Online fermées proprement." -ForegroundColor Magenta
