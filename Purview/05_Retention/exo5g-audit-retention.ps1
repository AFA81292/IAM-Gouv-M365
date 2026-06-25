# ========================================================================================
# Exercice 5g : Audit des labels et policies de rétention — vue d'ensemble du tenant
# ========================================================================================
# Concept : exo de lecture pure, miroir de 4e côté rétention.
# Couvre TROIS familles d'objets distinctes — leçon directe de 5e/5f :
#   *-RetentionCompliance*    → Exchange, SharePoint, OneDrive, Adaptive Scopes
#   *-AppRetentionCompliance* → Teams canaux, Teams chats (scenario groups séparés)
#   Get-ComplianceTag         → les labels eux-mêmes (5a/5b), indépendants des policies
#
# Un audit qui n'interroge que Get-RetentionCompliancePolicy manquerait silencieusement
# toutes les policies Teams — erreur classique à documenter.
#
# Delta pédagogique vs 4e :
#   4e → audit DLP : une seule famille de cmdlets (*-DlpCompliance*)
#   5g → audit rétention : trois familles à interroger séparément, plus les labels
#        et les scopes adaptatifs — plus complexe, même logique de détection d'orphelines
#
# Ce que fait ce script :
#   1. Reset total de session
#   2. Audite les Retention Labels (5a/5b)
#   3. Audite les Retention Policies classiques (Exchange/SharePoint — 5e/5f)
#      avec distinction Label Policy (5c) vs Retention Policy de fond (5e/5f)
#   4. Audite les App Retention Policies (Teams — 5e)
#   5. Vérifie les règles des policies classiques (détection orphelines)
#   6. Vérifie les règles des App Retention Policies (détection orphelines)
#   7. Audite les Adaptive Scopes (5d)
#   8. Affiche un résumé chiffré
#   9. Exporte cinq CSV horodatés
#  10. Ferme proprement toutes les sessions
#
# Note : ce script est en lecture seule — aucune modification du tenant.
#
# Fichiers CSV générés :
#   RET_Labels_YYYYMMDD_HHmmss.csv                  — inventaire des Retention Labels
#   RET_PoliciesClassiques_YYYYMMDD_HHmmss.csv      — policies Exchange/SharePoint/OneDrive
#   RET_AppPolicies_YYYYMMDD_HHmmss.csv             — policies Teams/Viva Engage
#   RET_Orphelines_YYYYMMDD_HHmmss.csv              — policies sans règle associée (les deux familles)
#   RET_AdaptiveScopes_YYYYMMDD_HHmmss.csv          — scopes dynamiques
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
# ÉTAPE 1 : Retention Labels
# ========================================================================================
Write-Host "1. Retention Labels du tenant..." -ForegroundColor Cyan
Start-Sleep -Seconds 30

# Get-ComplianceTag retourne tous les labels de rétention du tenant — built-in et custom.
# Un label existe indépendamment des policies qui le publient ou l'auto-appliquent.
# Colonne "Review" : ReviewerEmail non nul → disposition review configurée (cf. 5b).
# RetentionDuration en jours — diviser par 365 pour une lecture en années.
$AllLabels = Get-ComplianceTag

if ($AllLabels) {
    $AllLabels | Select-Object Name, RetentionAction, RetentionDuration, RetentionType,
        @{ N = "Review"; E = { if ($_.ReviewerEmail) { "Oui" } else { "Non" } } } |
        Format-Table -AutoSize
    Write-Host "-> $($AllLabels.Count) label(s) trouvé(s).`n" -ForegroundColor Green
} else {
    Write-Host "-> Aucun Retention Label trouvé.`n" -ForegroundColor Yellow
}

# ========================================================================================
# ÉTAPE 2 : Retention Policies classiques (Exchange/SharePoint/OneDrive — 5e/5f)
# ========================================================================================
Write-Host "2. Retention Policies classiques (*-RetentionCompliance*)..." -ForegroundColor Cyan

# -RetentionRuleTypes : force le retour de la propriété RetentionRuleTypes dans la réponse.
# Sans ce flag, la propriété peut être vide même si des règles existent.
#
# Distinction Label Policy vs Retention Policy de fond :
#   RetentionRuleTypes contient "ComplianceTagRetention" → Label Policy (publie un label, cf. 5c)
#   Autrement                                            → Retention Policy de fond (cf. 5e/5f)
#   Les deux coexistent dans la même famille de cmdlets — ce filtre les différencie.
#
# ScopeAdaptatif : AdaptiveScopeLocation non nul → policy consomme un scope dynamique (5f)
#                  Nul                           → périmètre statique "All" (5e)
$ClassicPolicies = Get-RetentionCompliancePolicy -RetentionRuleTypes

if ($ClassicPolicies) {
    $ClassicPolicies | Select-Object Name,
        @{ N = "Type";           E = { if ($_.RetentionRuleTypes -contains "ComplianceTagRetention") { "Label Policy" } else { "Retention Policy (fond)" } } },
        @{ N = "ScopeAdaptatif"; E = { if ($_.AdaptiveScopeLocation) { "Oui" } else { "Non (statique)" } } },
        DistributionStatus |
        Format-Table -AutoSize
    Write-Host "-> $($ClassicPolicies.Count) policy(ies) classique(s) trouvée(s).`n" -ForegroundColor Green
} else {
    Write-Host "-> Aucune Retention Policy classique trouvée.`n" -ForegroundColor Yellow
}

# ========================================================================================
# ÉTAPE 3 : App Retention Policies (Teams canaux/chats — 5e Teams)
# ========================================================================================
Write-Host "3. App Retention Policies (*-AppRetentionCompliance*)..." -ForegroundColor Cyan

# Get-AppRetentionCompliancePolicy couvre Teams canaux, Teams chats, Viva Engage,
# et d'autres workloads modernes migrés hors de l'ancienne famille de cmdlets.
# Ces policies sont INVISIBLES depuis Get-RetentionCompliancePolicy — d'où l'importance
# d'interroger les deux familles séparément dans un audit complet.
$AppPolicies = Get-AppRetentionCompliancePolicy

if ($AppPolicies) {
    $AppPolicies | Select-Object Name,
        @{ N = "Applications"; E = { $_.Applications -join ", " } } |
        Format-Table -AutoSize
    Write-Host "-> $($AppPolicies.Count) App Retention Policy(ies) trouvée(s).`n" -ForegroundColor Green
} else {
    Write-Host "-> Aucune App Retention Policy trouvée.`n" -ForegroundColor Yellow
}

# ========================================================================================
# ÉTAPE 4 : Règles des Retention Policies classiques (détection orphelines)
# ========================================================================================
Write-Host "4. Règles des policies classiques..." -ForegroundColor Cyan

# Une policy sans règle = objet "mort" — créé mais inopérant.
# Même piège documenté en 4c/4e côté DLP : la création de la règle peut échouer
# après celle de la policy, laissant une policy orpheline sur le tenant.
# Commande de nettoyage affichée inline pour faciliter le traitement immédiat.
$OrphanClassicCount = 0
$OrphelineRows      = @()

foreach ($Policy in $ClassicPolicies) {
    $Rules = Get-RetentionComplianceRule -Policy $Policy.Name -ErrorAction SilentlyContinue
    if (-not $Rules) {
        Write-Host "   ATTENTION : '$($Policy.Name)' — aucune règle associée (orpheline)." -ForegroundColor Red
        Write-Host "   Nettoyage : Remove-RetentionCompliancePolicy -Identity '$($Policy.Name)' -Confirm:`$false" -ForegroundColor Yellow
        $OrphanClassicCount++
        $OrphelineRows += [PSCustomObject]@{
            Famille   = "RetentionCompliance"
            PolicyNom = $Policy.Name
            Type      = if ($Policy.RetentionRuleTypes -contains "ComplianceTagRetention") { "Label Policy" } else { "Retention Policy (fond)" }
            # Commande de nettoyage incluse dans le CSV — directement exploitable.
            Nettoyage = "Remove-RetentionCompliancePolicy -Identity '$($Policy.Name)' -Confirm:`$false"
        }
    } else {
        Write-Host "   OK : '$($Policy.Name)' — $($Rules.Count) règle(s)." -ForegroundColor Gray
    }
}
Write-Host ""

# ========================================================================================
# ÉTAPE 5 : Règles des App Retention Policies (détection orphelines)
# ========================================================================================
Write-Host "5. Règles des App Retention Policies..." -ForegroundColor Cyan

# Même logique qu'étape 4, mais avec Get-AppRetentionComplianceRule —
# les deux familles ont leurs propres cmdlets de règles, non interchangeables.
$OrphanAppCount = 0

foreach ($Policy in $AppPolicies) {
    $Rules = Get-AppRetentionComplianceRule -Policy $Policy.Name -ErrorAction SilentlyContinue
    if (-not $Rules) {
        Write-Host "   ATTENTION : '$($Policy.Name)' — aucune règle associée (orpheline)." -ForegroundColor Red
        Write-Host "   Nettoyage : Remove-AppRetentionCompliancePolicy -Identity '$($Policy.Name)' -Confirm:`$false" -ForegroundColor Yellow
        $OrphanAppCount++
        $OrphelineRows += [PSCustomObject]@{
            Famille   = "AppRetentionCompliance"
            PolicyNom = $Policy.Name
            Type      = "App Retention Policy"
            Nettoyage = "Remove-AppRetentionCompliancePolicy -Identity '$($Policy.Name)' -Confirm:`$false"
        }
    } else {
        Write-Host "   OK : '$($Policy.Name)' — $($Rules.Count) règle(s)." -ForegroundColor Gray
    }
}
Write-Host ""

# ========================================================================================
# ÉTAPE 6 : Adaptive Scopes
# ========================================================================================
Write-Host "6. Adaptive Scopes du tenant..." -ForegroundColor Cyan

# Get-AdaptiveScope retourne tous les scopes dynamiques définis sur le tenant.
# Un scope sans policy qui le consomme est inoffensif (contrairement aux policies
# orphelines) — mais il mérite d'être documenté pour éviter une accumulation inutile.
# LocationType "User" / "Site" / "UnifiedGroup" — cf. 5d pour le détail.
$AllScopes = Get-AdaptiveScope

if ($AllScopes) {
    $AllScopes | Select-Object Name, LocationType, RawQuery | Format-Table -AutoSize
    Write-Host "-> $($AllScopes.Count) scope(s) trouvé(s).`n" -ForegroundColor Green
} else {
    Write-Host "-> Aucun Adaptive Scope trouvé.`n" -ForegroundColor Yellow
}

# ========================================================================================
# RÉSUMÉ
# ========================================================================================
Write-Host "=== RÉSUMÉ ===" -ForegroundColor Magenta
[PSCustomObject]@{
    RetentionLabels      = if ($AllLabels)       { $AllLabels.Count       } else { 0 }
    PoliciesClassiques   = if ($ClassicPolicies) { $ClassicPolicies.Count } else { 0 }
    AppRetentionPolicies = if ($AppPolicies)     { $AppPolicies.Count     } else { 0 }
    AdaptiveScopes       = if ($AllScopes)       { $AllScopes.Count       } else { 0 }
    PoliciesOrphelines   = $OrphanClassicCount + $OrphanAppCount
    Scope                = "Lecture seule — aucune modification du tenant"
    PointAttentionAudit  = "Get-RetentionCompliancePolicy seul ne voit PAS les policies Teams — toujours interroger les deux familles"
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

# --- CSV 1 : Retention Labels ---
# Colonnes exportées : Name, RetentionAction, RetentionDuration, RetentionType, Review
# RetentionAction  : "Keep" / "Delete" / "KeepAndDelete" — action appliquée au contenu.
# RetentionDuration : en jours — diviser par 365 pour lire en années.
# RetentionType    : "CreationAgeInDays" / "ModificationAgeInDays" / "EventAgeInDays"
#                    → à partir de quand le compteur commence.
# Review           : "Oui" si une disposition review est configurée (ReviewerEmail non nul).
# Colonnes disponibles non exportées :
#   ReviewerEmail  : adresse(s) du ou des reviewers — appeler via $_.ReviewerEmail -join "|"
#   IsRecordLabel  : $true si le label déclare le contenu comme Record immuable
#                    appeler via $_.IsRecordLabel
#   RetentionId    : GUID stable du label — appeler via $_.Guid
if ($AllLabels) {
    $AllLabels | Select-Object Name, RetentionAction, RetentionDuration, RetentionType,
        @{ N = "Review"; E = { if ($_.ReviewerEmail) { "Oui" } else { "Non" } } } |
        Export-Csv `
            -Path "$ExportPath\RET_Labels_$Timestamp.csv" `
            -Encoding UTF8 -NoTypeInformation
    Write-Host "-> Labels              : $($AllLabels.Count) ligne(s) — RET_Labels_$Timestamp.csv" -ForegroundColor Green
} else {
    Write-Host "-> Labels              : aucun label trouvé — pas d'export." -ForegroundColor Yellow
}

# --- CSV 2 : Retention Policies classiques ---
# Colonnes exportées : Name, Type, ScopeAdaptatif, DistributionStatus
# Type            : "Label Policy" (publie un label) vs "Retention Policy (fond)"
#                   distinction critique — les deux cohabitent dans la même famille de cmdlets.
# ScopeAdaptatif  : "Oui" = périmètre dynamique via Adaptive Scope (5f)
#                   "Non (statique)" = périmètre statique "All" (5e)
# DistributionStatus : "Pending" = propagation en cours | "Success" = active
# Colonnes disponibles non exportées :
#   SharePointLocation / OneDriveLocation / ExchangeLocation : périmètre statique détaillé
#     appeler via $_.SharePointLocation -join "|"
#   AdaptiveScopeLocation : nom du scope dynamique consommé — appeler via $_.AdaptiveScopeLocation
if ($ClassicPolicies) {
    $ClassicPolicies | Select-Object Name,
        @{ N = "Type";           E = { if ($_.RetentionRuleTypes -contains "ComplianceTagRetention") { "Label Policy" } else { "Retention Policy (fond)" } } },
        @{ N = "ScopeAdaptatif"; E = { if ($_.AdaptiveScopeLocation) { "Oui" } else { "Non (statique)" } } },
        DistributionStatus |
        Export-Csv `
            -Path "$ExportPath\RET_PoliciesClassiques_$Timestamp.csv" `
            -Encoding UTF8 -NoTypeInformation
    Write-Host "-> Policies classiques : $($ClassicPolicies.Count) ligne(s) — RET_PoliciesClassiques_$Timestamp.csv" -ForegroundColor Green
} else {
    Write-Host "-> Policies classiques : aucune policy trouvée — pas d'export." -ForegroundColor Yellow
}

# --- CSV 3 : App Retention Policies ---
# Colonnes exportées : Name, Applications (pipe-séparées)
# Applications : liste des workloads couverts par la policy
#   ("TeamsChannelMessages", "TeamsChatMessages", "VivaEngage"...).
#   Pipe-séparés pour rester lisible dans Excel.
# Colonnes disponibles non exportées :
#   DistributionStatus : état de propagation — appeler via $_.DistributionStatus
#   Comment            : commentaire admin — appeler via $_.Comment
if ($AppPolicies) {
    $AppPolicies | Select-Object Name,
        @{ N = "Applications"; E = { $_.Applications -join "|" } } |
        Export-Csv `
            -Path "$ExportPath\RET_AppPolicies_$Timestamp.csv" `
            -Encoding UTF8 -NoTypeInformation
    Write-Host "-> App Policies        : $($AppPolicies.Count) ligne(s) — RET_AppPolicies_$Timestamp.csv" -ForegroundColor Green
} else {
    Write-Host "-> App Policies        : aucune App Policy trouvée — pas d'export." -ForegroundColor Yellow
}

# --- CSV 4 : Policies orphelines (toutes familles confondues) ---
# Colonnes exportées : Famille, PolicyNom, Type, Nettoyage
# Famille   : "RetentionCompliance" ou "AppRetentionCompliance" — indique quelle cmdlet utiliser.
# Nettoyage : commande Remove-* pré-remplie — copier-coller direct pour le nettoyage.
# Ce CSV est le livrable opérationnel : chaque ligne = une action corrective à prendre.
if ($OrphelineRows.Count -gt 0) {
    $OrphelineRows | Export-Csv `
        -Path "$ExportPath\RET_Orphelines_$Timestamp.csv" `
        -Encoding UTF8 -NoTypeInformation
    Write-Host "-> Orphelines          : $($OrphelineRows.Count) ligne(s) — RET_Orphelines_$Timestamp.csv" -ForegroundColor Green
} else {
    Write-Host "-> Orphelines          : aucune policy orpheline — pas d'export." -ForegroundColor Yellow
}

# --- CSV 5 : Adaptive Scopes ---
# Colonnes exportées : Name, LocationType, RawQuery
# LocationType : "User" / "Site" / "UnifiedGroup" — type d'objet ciblé par le scope.
# RawQuery     : filtre KQL définissant le périmètre dynamique du scope.
#                Exemple : "Department -eq 'Finance'" pour cibler les boîtes du département Finance.
# Colonnes disponibles non exportées :
#   Guid         : identifiant stable du scope — appeler via $_.Guid
#   Status       : état de propagation du scope — appeler via $_.Status
if ($AllScopes) {
    $AllScopes | Select-Object Name, LocationType, RawQuery |
        Export-Csv `
            -Path "$ExportPath\RET_AdaptiveScopes_$Timestamp.csv" `
            -Encoding UTF8 -NoTypeInformation
    Write-Host "-> Adaptive Scopes     : $($AllScopes.Count) ligne(s) — RET_AdaptiveScopes_$Timestamp.csv" -ForegroundColor Green
} else {
    Write-Host "-> Adaptive Scopes     : aucun scope trouvé — pas d'export." -ForegroundColor Yellow
}

Write-Host "-> Export terminé dans : $ExportPath`n" -ForegroundColor Green

# ========================================================================================
# NETTOYAGE MÉMOIRE
# ========================================================================================
Remove-Variable AllLabels, ClassicPolicies, AppPolicies, AllScopes,
                Policy, Rules, OrphanClassicCount, OrphanAppCount,
                OrphelineRows, ExportPath, Timestamp `
                -ErrorAction SilentlyContinue

# ========================================================================================
# FERMETURE — RESET DE SESSION TOTAL
# ========================================================================================
Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
Get-PSSession | Remove-PSSession
Write-Host "Sessions fermées proprement." -ForegroundColor Magenta
