# ========================================================================================
# Exercice 2f : Sensitivity Labels — Audit des labels et policies
# ========================================================================================
# Concept : Exo de lecture pure — aucune création, aucune modification.
# On boucle la section Sensitivity Labels en listant tout ce qui a été créé :
#   - Labels (groupe parent + sublabels rattachés)
#   - Label Policies de publication (2d)
#   - Policies d'auto-labeling (2e)
#
# Cas d'usage réel : un consultant IAM arrive en mission et veut une vue d'ensemble
# immédiate de l'état des labels sur le tenant, sans naviguer dans le portail Purview.
# Ce script donne un inventaire lisible en quelques secondes.
# Utile aussi pour soi-même après une pause : repartir d'une vue d'ensemble plutôt
# que de fouiller dans le portail pour retrouver ce qui a été configuré.
#
# Points techniques notables :
#
# -IncludeDetailedLabelActions (Get-Label) :
#   Sans ce paramètre, EncryptionEnabled ressort toujours $false même sur un label
#   réellement chiffré. Get-Label seul retourne un résumé allégé — pas l'état complet
#   des actions de protection. Toujours l'inclure pour un audit fiable.
#
# IsParent (propriété native de Get-Label) :
#   Exposée directement comme propriété de l'objet — pas besoin de fouiller dans
#   Settings (qui est une ArrayList de paires positionnelles, pas un objet avec des
#   propriétés .Name/.Value accessibles directement). IsParent = $true signifie
#   "ce label est un conteneur avec au moins un sublabel".
#
# Filtrage des sublabels custom vs labels système Microsoft :
#   On ne filtre pas simplement sur ParentId -ne $null, car les labels système
#   Microsoft natifs ont eux aussi un ParentId (vers leurs propres groupes natifs).
#   On filtre sur les GUIDs de NOS label groups uniquement — ce qui exclut proprement
#   les labels système sans avoir à les lister explicitement.
#
# Ce que fait ce script :
#   1. Reset total de session
#   2. Audite les labels (groupe parent + sublabels custom)
#   3. Audite les Label Policies de publication
#   4. Audite les policies d'auto-labeling et leurs règles associées
#   5. Affiche un récapitulatif chiffré
#   6. Exporte les quatre jeux de données en CSV horodatés
#   7. Ferme proprement toutes les sessions
#
# Note : ce script est en lecture seule — aucune modification du tenant.
#
# Fichiers CSV générés :
#   SL_LabelGroups_YYYYMMDD_HHmmss.csv
#   SL_Sublabels_YYYYMMDD_HHmmss.csv
#   SL_LabelPolicies_YYYYMMDD_HHmmss.csv
#   SL_AutoLabelingPolicies_YYYYMMDD_HHmmss.csv
#
# Module requis : ExchangeOnlineManagement
# Connexion     : Connect-IPPSSession
# ========================================================================================

# --- OUVERTURE — RESET DE SESSION TOTAL ---
# REX : des sessions fantômes restées ouvertes depuis un script précédent peuvent
# provoquer des erreurs silencieuses ou des authentifications croisées.
# On purge TOUT avant de commencer, sans exception.
#
# Note : Connect-IPPSSession ne supporte pas -ShowBanner:$false — bandeau normal.
# $env:MSAL_ENABLE_WAM = "0" non nécessaire ici : script de lecture seule,
# pas de risque d'interférence WAM sur un Connect-IPPSSession simple.
Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
Get-PSSession | Remove-PSSession
Connect-IPPSSession -UserPrincipalName GeptorAdmin@0n4mg.onmicrosoft.com

# ========================================================================================
# ÉTAPE 1 : Audit des labels (groupe parent + sublabels)
# ========================================================================================
Write-Host "1. Audit des labels existants sur le tenant..." -ForegroundColor Cyan

# -IncludeDetailedLabelActions : obligatoire pour avoir EncryptionEnabled fiable.
# Sans ce paramètre, la propriété est toujours $false même sur un label chiffré.
$AllLabels = Get-Label -IncludeDetailedLabelActions

# Identification des label groups (parents) :
# IsParent est une propriété native de l'objet retourné par Get-Label.
# Un label group ne peut pas être appliqué directement — il sert de conteneur
# organisationnel pour regrouper des sublabels dans le client (Word, Outlook, Teams).
$LabelGroups = $AllLabels | Where-Object { $_.IsParent -eq $true }

Write-Host "`n-- Label groups (parents) --" -ForegroundColor Yellow
if ($LabelGroups) {
    $LabelGroups | Select-Object DisplayName, Guid | Format-Table -AutoSize
} else {
    Write-Host "   Aucun label group trouvé sur ce tenant." -ForegroundColor Gray
}

# Identification des sublabels custom :
# On filtre sur ParentId appartenant aux GUIDs de NOS label groups — pas un simple
# -ne $null qui inclurait les labels système Microsoft natifs (qui ont eux aussi un ParentId).
$GroupGuids = $LabelGroups.Guid
$SubLabels  = $AllLabels | Where-Object {
    $_.ParentId -and ($GroupGuids -contains $_.ParentId)
}

Write-Host "`n-- Sublabels (rattachés aux label groups identifiés ci-dessus) --" -ForegroundColor Yellow
if ($SubLabels) {
    $SubLabels | Select-Object DisplayName, ParentId,
        @{ N = "Chiffré" ; E = { [bool]$_.EncryptionEnabled } } |
        Format-Table -AutoSize
} else {
    Write-Host "   Aucun sublabel custom trouvé." -ForegroundColor Gray
}

# ========================================================================================
# ÉTAPE 2 : Audit des Label Policies de publication
# ========================================================================================
Write-Host "`n2. Audit des Label Policies de publication (exo 2d)..." -ForegroundColor Cyan

# Get-LabelPolicy retourne toutes les policies de publication du tenant.
# DistributionStatus "Pending" = distribution en cours vers les workloads.
# "Success" = labels visibles dans les clients (Word, Outlook, Teams) pour les destinataires.
$AllLabelPolicies = Get-LabelPolicy

if ($AllLabelPolicies) {
    $AllLabelPolicies | Select-Object Name,
        @{ N = "Labels" ; E = { $_.Labels -join ", " } },
        DistributionStatus |
        Format-Table -AutoSize
} else {
    Write-Host "   Aucune Label Policy de publication trouvée." -ForegroundColor Gray
}

# ========================================================================================
# ÉTAPE 3 : Audit des policies d'auto-labeling
# ========================================================================================
Write-Host "`n3. Audit des policies d'auto-labeling (exo 2e)..." -ForegroundColor Cyan

# Get-AutoSensitivityLabelPolicy retourne les policies d'auto-labeling côté service.
# Différent des Label Policies de publication : ici c'est Purview qui applique
# le label automatiquement, sans action utilisateur.
$AllAutoPolicies = Get-AutoSensitivityLabelPolicy
$AllAutoRules    = $null

if ($AllAutoPolicies) {
    $AllAutoPolicies | Select-Object Name, Mode, ApplySensitivityLabel,
        @{ N = "Exchange"   ; E = { ($_.ExchangeLocation   -join ", ") } },
        @{ N = "SharePoint" ; E = { ($_.SharePointLocation -join ", ") } } |
        Format-Table -AutoSize

    # Les règles sont des objets séparés de leur policy — on les liste en complément.
    # Une règle contient la condition de détection (SIT, seuil) ; la policy contient
    # le label à appliquer et le mode. Les deux sont nécessaires pour que le scan fonctionne.
    Write-Host "`n-- Règles d'auto-labeling associées --" -ForegroundColor Yellow
    $AllAutoRules = Get-AutoSensitivityLabelRule
    $AllAutoRules | Select-Object Name, ParentPolicyName, Workload, Disabled |
        Format-Table -AutoSize
} else {
    Write-Host "   Aucune Auto-Labeling Policy trouvée." -ForegroundColor Gray
}

# ========================================================================================
# RÉSUMÉ
# ========================================================================================
Write-Host "`n=== RÉSUMÉ ===" -ForegroundColor Magenta
[PSCustomObject]@{
    LabelGroups          = if ($LabelGroups)     { $LabelGroups.Count     } else { 0 }
    SublabelsCustom      = if ($SubLabels)        { $SubLabels.Count        } else { 0 }
    LabelPolicies        = if ($AllLabelPolicies) { $AllLabelPolicies.Count } else { 0 }
    AutoLabelingPolicies = if ($AllAutoPolicies)  { $AllAutoPolicies.Count  } else { 0 }
    Scope                = "Lecture seule — aucune création, aucune modification"
} | Format-List

Write-Host "=== FIN DE L'AUDIT SENSITIVITY LABELS ===" -ForegroundColor Green

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

# --- CSV 1 : Label Groups (parents) ---
# Colonnes exportées : DisplayName, Guid, Priority, IsParent
# Priority : ordre d'affichage des labels dans les clients (plus le chiffre est bas,
# plus le label apparaît en haut de la liste). Utile pour auditer l'ordre de présentation.
# Colonnes disponibles non exportées :
#   Comment         : commentaire admin interne — appeler via $_.Comment
#   ContentType     : workloads cibles (File, Email...) — appeler via $_.ContentType -join "|"
#   CreatedBy / WhenCreated : traçabilité de création — appeler via $_.CreatedBy, $_.WhenCreated
if ($LabelGroups) {
    $LabelGroups | Select-Object DisplayName, Guid, Priority, IsParent |
        Export-Csv `
            -Path "$ExportPath\SL_LabelGroups_$Timestamp.csv" `
            -Encoding UTF8 -NoTypeInformation
    Write-Host "-> Label Groups : $($LabelGroups.Count) ligne(s) — SL_LabelGroups_$Timestamp.csv" -ForegroundColor Green
} else {
    Write-Host "-> Label Groups : aucun groupe trouvé — pas d'export." -ForegroundColor Yellow
}

# --- CSV 2 : Sublabels custom ---
# Colonnes exportées : DisplayName, Guid, ParentId, Priority, EncryptionEnabled, ContentMarkingEnabled
# EncryptionEnabled    : indique si une action de chiffrement est associée au label
#                        (fiable uniquement avec -IncludeDetailedLabelActions).
# ContentMarkingEnabled : header/footer/watermark activé sur le label.
# Colonnes disponibles non exportées :
#   SiteAndGroupProtectionEnabled : protection SharePoint/Teams activée
#                                   appeler via $_.SiteAndGroupProtectionEnabled
#   AutoLabelingEnabled : label appliqué automatiquement côté client
#                         appeler via $_.AutoLabelingEnabled
#   Comment / ContentType / CreatedBy : cf. CSV 1
if ($SubLabels) {
    $SubLabels | Select-Object DisplayName, Guid, ParentId, Priority,
        @{ N = "EncryptionEnabled"     ; E = { [bool]$_.EncryptionEnabled     } },
        @{ N = "ContentMarkingEnabled" ; E = { [bool]$_.ContentMarkingEnabled } } |
        Export-Csv `
            -Path "$ExportPath\SL_Sublabels_$Timestamp.csv" `
            -Encoding UTF8 -NoTypeInformation
    Write-Host "-> Sublabels : $($SubLabels.Count) ligne(s) — SL_Sublabels_$Timestamp.csv" -ForegroundColor Green
} else {
    Write-Host "-> Sublabels : aucun sublabel custom trouvé — pas d'export." -ForegroundColor Yellow
}

# --- CSV 3 : Label Policies de publication ---
# Colonnes exportées : Name, DistributionStatus, Labels (concaténés)
# DistributionStatus : "Pending" = propagation en cours | "Success" = actif dans les clients.
# Labels (concaténés) : liste des GUIDs ou noms de labels publiés par cette policy.
# Colonnes disponibles non exportées :
#   Settings        : paramètres avancés (label par défaut, justification obligatoire...)
#                     appeler via $_.Settings — retourne une ArrayList de paires clé/valeur
#   ExchangeLocation / SharePointLocation : périmètre de la policy
#                     appeler via $_.ExchangeLocation -join "|"
#   CreatedBy / WhenCreated : traçabilité — appeler via $_.CreatedBy, $_.WhenCreated
if ($AllLabelPolicies) {
    $AllLabelPolicies | Select-Object Name, DistributionStatus,
        @{ N = "Labels" ; E = { $_.Labels -join "|" } } |
        Export-Csv `
            -Path "$ExportPath\SL_LabelPolicies_$Timestamp.csv" `
            -Encoding UTF8 -NoTypeInformation
    Write-Host "-> Label Policies : $($AllLabelPolicies.Count) ligne(s) — SL_LabelPolicies_$Timestamp.csv" -ForegroundColor Green
} else {
    Write-Host "-> Label Policies : aucune policy trouvée — pas d'export." -ForegroundColor Yellow
}

# --- CSV 4 : Auto-Labeling Policies + règles ---
# Colonnes exportées : Name, Mode, ApplySensitivityLabel, Exchange (périmètre),
#                      SharePoint (périmètre), Workload (depuis les règles), Disabled
# Mode : "TestWithNotifications" / "TestWithoutNotifications" / "Enable"
#   → une policy en mode Test ne labellise pas réellement — point d'attention en audit.
# ApplySensitivityLabel : GUID du label appliqué automatiquement par cette policy.
# Colonnes disponibles non exportées (policy) :
#   OneDriveLocation     : périmètre OneDrive — appeler via $_.OneDriveLocation -join "|"
#   WhenCreated / WhenChanged : traçabilité — appeler via $_.WhenCreated, $_.WhenChanged
# Colonnes disponibles non exportées (règles) :
#   ContentContainsSensitiveInformation : SITs et seuils de confiance configurés dans la règle
#     — appeler via ($_.ContentContainsSensitiveInformation | ConvertTo-Json -Compress)
if ($AllAutoPolicies) {
    # On construit une table aplatie policy + règles pour un CSV lisible.
    # Chaque ligne = une règle, avec le nom et le mode de sa policy parente.
    $AutoPolicyRows = foreach ($Policy in $AllAutoPolicies) {
        $Rules = if ($AllAutoRules) {
            $AllAutoRules | Where-Object { $_.ParentPolicyName -eq $Policy.Name }
        } else { @() }

        if ($Rules) {
            foreach ($Rule in $Rules) {
                [PSCustomObject]@{
                    PolicyName           = $Policy.Name
                    Mode                 = $Policy.Mode
                    ApplySensitivityLabel = $Policy.ApplySensitivityLabel
                    Exchange             = $Policy.ExchangeLocation   -join "|"
                    SharePoint           = $Policy.SharePointLocation -join "|"
                    RuleName             = $Rule.Name
                    Workload             = $Rule.Workload
                    RuleDisabled         = $Rule.Disabled
                }
            }
        } else {
            # Policy sans règle associée — on l'exporte quand même pour ne pas la perdre.
            [PSCustomObject]@{
                PolicyName            = $Policy.Name
                Mode                  = $Policy.Mode
                ApplySensitivityLabel = $Policy.ApplySensitivityLabel
                Exchange              = $Policy.ExchangeLocation   -join "|"
                SharePoint            = $Policy.SharePointLocation -join "|"
                RuleName              = "(aucune règle)"
                Workload              = $null
                RuleDisabled          = $null
            }
        }
    }

    $AutoPolicyRows | Export-Csv `
        -Path "$ExportPath\SL_AutoLabelingPolicies_$Timestamp.csv" `
        -Encoding UTF8 -NoTypeInformation
    Write-Host "-> Auto-Labeling Policies : $($AutoPolicyRows.Count) ligne(s) — SL_AutoLabelingPolicies_$Timestamp.csv" -ForegroundColor Green
} else {
    Write-Host "-> Auto-Labeling Policies : aucune policy trouvée — pas d'export." -ForegroundColor Yellow
}

Write-Host "-> Export terminé dans : $ExportPath`n" -ForegroundColor Green

# ========================================================================================
# NETTOYAGE MÉMOIRE
# ========================================================================================
Remove-Variable AllLabels, LabelGroups, GroupGuids, SubLabels,
                AllLabelPolicies, AllAutoPolicies, AllAutoRules,
                AutoPolicyRows, Policy, Rules, Rule,
                ExportPath, Timestamp `
                -ErrorAction SilentlyContinue

# ========================================================================================
# FERMETURE — RESET DE SESSION TOTAL
# ========================================================================================
Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
Get-PSSession | Remove-PSSession
Write-Host "Sessions fermées proprement." -ForegroundColor Magenta
