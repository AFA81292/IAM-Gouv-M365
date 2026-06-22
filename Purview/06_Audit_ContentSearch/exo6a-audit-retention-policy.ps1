# ========================================================================================
# Exercice 6a : Audit Retention Policy — Exchange Admin Activity (1 an)
# ========================================================================================
# L'Audit Retention Policy (ARP) agit sur les LOGS D'AUDIT uniquement —
# pas sur le contenu (emails, fichiers). Elle contrôle combien de temps les traces
# "qui a fait quoi, quand" sont conservées dans le journal d'audit unifié Purview.
#
# Durées par défaut sans ARP personnalisée :
#   Sans licence Audit Premium : 90 jours
#   Avec E5 (Audit Premium)    : 180 jours pour certaines activités
#   Avec ARP custom (ce script): jusqu'à 10 ans
#
# CONFUSION À ÉVITER :
#   Retention Policy (chap. 05) ≠ Audit Retention Policy (ce script)
#   Chap. 05 → *-RetentionCompliancePolicy    : agit sur le CONTENU
#   Chap. 06 → *-UnifiedAuditLogRetentionPolicy : agit sur les LOGS D'AUDIT
#
# RecordType ciblé : ExchangeAdmin
#   Couvre : Add/Remove-MailboxPermission, New/Remove-TransportRule,
#            Set-OrganizationConfig, New-MoveRequest, etc.
#   Ne couvre pas : ExchangeItem (lectures/envois), ExchangeItemGroup (mailbox ops)
#   — ces RecordTypes distincts nécessiteraient leurs propres ARP.
#
# PIÈGE CMDLET : Get-UnifiedAuditLogRetentionPolicy ne supporte PAS -Identity.
#   Contrairement à la majorité des cmdlets Purview, le lookup par nom n'existe pas.
#   Seul filtre natif : -RecordType. Pour chercher par nom → Where-Object obligatoire.
#
# Module requis : ExchangeOnlineManagement
# Connexion     : Connect-IPPSSession
# Licence       : Microsoft Purview Audit Premium (inclus E5)
# ========================================================================================

# --- OUVERTURE — RESET DE SESSION TOTAL ---
Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
Get-PSSession | Remove-PSSession
$env:MSAL_ENABLE_WAM = "0"
Connect-IPPSSession -UserPrincipalName GeptorAdmin@0n4mg.onmicrosoft.com

# ========================================================================================
# ÉTAPE 1 : Détection des priorités déjà utilisées
# ========================================================================================
# -Priority est OBLIGATOIRE et UNIQUE sur tout le tenant.
# Valeur 1 = priorité max, 10000 = priorité min.
# On part de 100 (laisse de la marge pour d'éventuelles ARPs plus prioritaires)
# et on incrémente jusqu'à trouver un slot libre.
Write-Host "1. Inventaire des priorités Audit Retention déjà en place..." -ForegroundColor Cyan

$ExistingARPs   = Get-UnifiedAuditLogRetentionPolicy -ErrorAction SilentlyContinue
$UsedPriorities = if ($ExistingARPs) { $ExistingARPs | Select-Object -ExpandProperty Priority } else { @() }
$TargetPriority = 100

while ($UsedPriorities -contains $TargetPriority) {
    Write-Host "   Priorité $TargetPriority déjà prise — test $($TargetPriority + 1)..." -ForegroundColor Yellow
    $TargetPriority++
}

Write-Host "-> Priorité retenue : $TargetPriority`n" -ForegroundColor Green

if ($ExistingARPs) {
    Write-Host "   ARPs existantes sur le tenant :" -ForegroundColor Gray
    $ExistingARPs | Select-Object Name, RecordTypes, RetentionDuration, Priority | Format-Table -AutoSize
}

# ========================================================================================
# ÉTAPE 2 : Recherche d'un nom disponible (auto-incrément)
# ========================================================================================
# "SpectreClearance" = habilitation des agents Spectre dans Mass Effect —
# approprié pour une policy qui surveille les actions à privilège élevé.
Write-Host "2. Recherche d'un nom disponible..." -ForegroundColor Cyan

$BaseARPName = "ARP-SpectreClearance-ExchangeAdmin-1Y"
$ARPName     = $BaseARPName
$Counter     = 2

while (Get-UnifiedAuditLogRetentionPolicy -ErrorAction SilentlyContinue |
       Where-Object { $_.Name -eq $ARPName }) {
    Write-Host "   '$ARPName' déjà pris — test avec suffixe -v$Counter..." -ForegroundColor Yellow
    $ARPName = "$BaseARPName-v$Counter"
    $Counter++
}

Write-Host "-> Nom retenu : '$ARPName'`n" -ForegroundColor Green

# ========================================================================================
# ÉTAPE 3 : Création de l'Audit Retention Policy
# ========================================================================================
Write-Host "3. Création de l'Audit Retention Policy '$ARPName'..." -ForegroundColor Cyan

# -RecordTypes "ExchangeAdmin" : catégorie d'activité dans le journal d'audit unifié.
#   Liste complète : https://learn.microsoft.com/en-us/office/office-365-management-api/office-365-management-activity-api-schema
#
# -RetentionDuration : chaîne texte obligatoire, pas un entier.
#   "ThreeMonths" / "SixMonths" / "NineMonths" / "TwelveMonths" / "ThreeYears" /
#   "FiveYears" / "SevenYears" / "TenYears" (TenYears nécessite add-on licence)
#
# -Priority : valeur calculée à l'étape 1, garantie unique sur le tenant.
#
# -Operations (non utilisé ici) : filtrerait des opérations spécifiques dans le RecordType.
# -UserIds   (non utilisé ici) : limiterait à un utilisateur nommé.
try {
    $NewARP = New-UnifiedAuditLogRetentionPolicy `
        -Name              $ARPName `
        -Description       "Exo 6a — Rétention 1 an des logs ExchangeAdmin. SpectreClearance audit trail." `
        -RecordTypes       "ExchangeAdmin" `
        -RetentionDuration "TwelveMonths" `
        -Priority          $TargetPriority `
        -ErrorAction Stop

    Write-Host "-> ARP créée : $($NewARP.Name)`n" -ForegroundColor Green
}
catch {
    Write-Host "-> Échec de la création de l'ARP : $_" -ForegroundColor Red
    Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
    Get-PSSession | Remove-PSSession
    return
}

# ========================================================================================
# ÉTAPE 4 : Vérification depuis la source de vérité
# ========================================================================================
# On ne fait pas confiance à $NewARP retourné par New- (peut être incomplet en cas de lag).
# On relit depuis l'API. Pas de -Identity → Where-Object obligatoire (voir en-tête).
Write-Host "4. Vérification depuis le backend Purview..." -ForegroundColor Cyan
Start-Sleep -Seconds 3

$CheckARP = Get-UnifiedAuditLogRetentionPolicy -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -eq $ARPName }

if ($CheckARP) {
    Write-Host "-> ARP confirmée :" -ForegroundColor Green
    [PSCustomObject]@{
        Nom            = $CheckARP.Name
        RecordTypes    = ($CheckARP.RecordTypes -join ", ")
        DuréeRétention = $CheckARP.RetentionDuration
        Priorité       = $CheckARP.Priority
        Description    = $CheckARP.Description
    } | Format-List
} else {
    Write-Host "-> ATTENTION : ARP non trouvée lors de la vérification." -ForegroundColor Red
    Write-Host "   Vérifier manuellement : Get-UnifiedAuditLogRetentionPolicy | Sort-Object Priority" -ForegroundColor Yellow
}

# ========================================================================================
# ÉTAPE 5 : Résumé
# ========================================================================================
Write-Host "=== RÉSUMÉ ===" -ForegroundColor Magenta

[PSCustomObject]@{
    PolicyCréée     = $ARPName
    RecordType      = "ExchangeAdmin"
    DuréeRétention  = "TwelveMonths (1 an)"
    Priorité        = $TargetPriority
    EffetSurContenu = "Aucun — agit sur les logs d'audit uniquement"
    VisibilitéGUI   = "Potentiellement absente du portail Purview (voir note en en-tête)"
} | Format-List

# Note visibilité GUI : les ARPs créées via PowerShell sur des RecordTypes hors tableau
# de bord standard n'apparaissent pas dans Purview portal > Audit > Audit retention policies.
# Elles sont fonctionnelles côté backend. Gestion exclusivement via PowerShell :
#   Get-/Set-/Remove-UnifiedAuditLogRetentionPolicy
Write-Host "Note : si absente du portail Purview, ce n'est pas un bug — voir commentaire en en-tête." -ForegroundColor Yellow

# ========================================================================================
# NETTOYAGE MÉMOIRE
# ========================================================================================
Remove-Variable BaseARPName, ARPName, Counter, ExistingARPs, UsedPriorities,
                TargetPriority, NewARP, CheckARP `
                -ErrorAction SilentlyContinue

# --- FERMETURE — RESET DE SESSION TOTAL ---
Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
Get-PSSession | Remove-PSSession
Write-Host "Sessions fermées proprement." -ForegroundColor Magenta
