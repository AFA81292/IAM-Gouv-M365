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
#   9. Ferme proprement toutes les sessions
#
# Note : ce script est en lecture seule — aucune modification du tenant.
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
        @{ N = "Type";          E = { if ($_.RetentionRuleTypes -contains "ComplianceTagRetention") { "Label Policy" } else { "Retention Policy (fond)" } } },
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
foreach ($Policy in $ClassicPolicies) {
    $Rules = Get-RetentionComplianceRule -Policy $Policy.Name -ErrorAction SilentlyContinue
    if (-not $Rules) {
        Write-Host "   ATTENTION : '$($Policy.Name)' — aucune règle associée (orpheline)." -ForegroundColor Red
        Write-Host "   Nettoyage : Remove-RetentionCompliancePolicy -Identity '$($Policy.Name)' -Confirm:`$false" -ForegroundColor Yellow
        $OrphanClassicCount++
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
    RetentionLabels      = if ($AllLabels)      { $AllLabels.Count      } else { 0 }
    PoliciesClassiques   = if ($ClassicPolicies) { $ClassicPolicies.Count } else { 0 }
    AppRetentionPolicies = if ($AppPolicies)     { $AppPolicies.Count     } else { 0 }
    AdaptiveScopes       = if ($AllScopes)       { $AllScopes.Count       } else { 0 }
    PoliciesOrphelines   = $OrphanClassicCount + $OrphanAppCount
    Scope                = "Lecture seule — aucune modification du tenant"
    PointAttentionAudit  = "Get-RetentionCompliancePolicy seul ne voit PAS les policies Teams — toujours interroger les deux familles"
} | Format-List

# ========================================================================================
# NETTOYAGE MÉMOIRE
# ========================================================================================
Remove-Variable AllLabels, ClassicPolicies, AppPolicies, AllScopes,
                Policy, Rules, OrphanClassicCount, OrphanAppCount `
                -ErrorAction SilentlyContinue

# ========================================================================================
# FERMETURE — RESET DE SESSION TOTAL
# ========================================================================================
Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
Get-PSSession | Remove-PSSession
Write-Host "Sessions fermées proprement." -ForegroundColor Magenta
