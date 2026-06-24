# ========================================================================================
# Exercice 6a : Audit Retention Policy — Exchange Admin Activity (1 an)
# ========================================================================================
# Concept : l'Audit Retention Policy (ARP) agit sur les LOGS D'AUDIT uniquement —
# pas sur le contenu (emails, fichiers). Elle contrôle combien de temps les traces
# "qui a fait quoi, quand" sont conservées dans le journal d'audit unifié Purview.
#
# CONFUSION À ÉVITER — deux familles sans rapport :
#   Chapitre 05 → *-RetentionCompliancePolicy      : agit sur le CONTENU
#   Chapitre 06 → *-UnifiedAuditLogRetentionPolicy : agit sur les LOGS D'AUDIT
#   Même mot "Retention", objets complètement différents.
#
# Durées de rétention des logs sans ARP personnalisée :
#   Sans licence Audit Premium : 90 jours
#   Avec E5 (Audit Premium)    : 180 jours pour certaines activités
#   Avec ARP custom (ce script): jusqu'à 10 ans (TenYears nécessite add-on licence)
#
# RecordType ciblé : ExchangeAdmin
#   Couvre  : Add/Remove-MailboxPermission, New/Remove-TransportRule,
#             Set-OrganizationConfig, New-MoveRequest, etc.
#   Ne couvre PAS : ExchangeItem (lectures/envois d'emails),
#                   ExchangeItemGroup (opérations de boîte aux lettres)
#                   → ces RecordTypes distincts nécessiteraient leurs propres ARP.
#
# Valeurs -RetentionDuration acceptées (chaîne texte, pas un entier) :
#   "ThreeMonths" / "SixMonths" / "NineMonths" / "TwelveMonths" /
#   "ThreeYears" / "FiveYears" / "SevenYears" / "TenYears"
#
# Piège -Priority :
#   Obligatoire et UNIQUE sur tout le tenant. Si deux ARPs ont la même priorité,
#   la création est rejetée. On inventorie les priorités existantes en étape 1
#   avant de créer quoi que ce soit.
#
# Piège Get-UnifiedAuditLogRetentionPolicy :
#   Ne supporte PAS -Identity. Le lookup par nom n'existe pas nativement.
#   Seul filtre natif : -RecordType. Pour chercher par nom → Where-Object obligatoire.
#
# Delta pédagogique vs chapitre 05 :
#   5e/5f → Retention Policy : contrôle la durée de vie des emails, fichiers, messages
#   6a    → Audit Retention Policy : contrôle la durée de vie des TRACES d'activité
#           Les deux peuvent coexister — elles agissent sur des couches distinctes.
#
# Ce que fait ce script :
#   1. Reset total de session
#   2. Inventorie les priorités déjà utilisées et trouve un slot libre
#   3. Recherche un nom disponible (auto-incrément)
#   4. Crée l'Audit Retention Policy
#   5. Vérifie la création depuis la source de vérité
#   6. Affiche un résumé
#   7. Ferme proprement toutes les sessions
#
# Module requis : ExchangeOnlineManagement
# Connexion     : Connect-IPPSSession
# Licence       : Microsoft Purview Audit Premium (inclus E5)
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
# ÉTAPE 1 : Inventaire des priorités déjà utilisées
# ========================================================================================
Write-Host "1. Inventaire des priorités Audit Retention déjà en place..." -ForegroundColor Cyan
Start-Sleep -Seconds 30

# -Priority est OBLIGATOIRE et UNIQUE sur tout le tenant.
# Valeur 1 = priorité maximale (traitée en premier), 10000 = priorité minimale.
# On part de 100 pour laisser de la marge pour d'éventuelles ARPs plus prioritaires
# à créer ultérieurement (ex. une ARP GlobalAdmin en priorité 1).
# On incrémente jusqu'à trouver un slot libre.
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
    $ExistingARPs | Select-Object Name, RecordTypes, RetentionDuration, Priority |
        Format-Table -AutoSize
}

# ========================================================================================
# ÉTAPE 2 : Recherche d'un nom disponible (auto-incrément)
# ========================================================================================
Write-Host "2. Recherche d'un nom disponible..." -ForegroundColor Cyan

# "SpectreClearance" = habilitation des agents Spectre dans Mass Effect —
# approprié pour une policy qui surveille les actions à privilège élevé.
#
# Rappel piège : Get-UnifiedAuditLogRetentionPolicy ne supporte pas -Identity.
# La vérification d'existence passe donc par Where-Object sur le retour complet.
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
#   Référence complète des RecordTypes disponibles :
#   https://learn.microsoft.com/en-us/office/office-365-management-api/office-365-management-activity-api-schema
#
# -RetentionDuration "TwelveMonths" : chaîne texte obligatoire, pas un entier.
#   Voir liste complète des valeurs acceptées en en-tête.
#
# -Priority : valeur calculée à l'étape 1, garantie unique sur le tenant.
#
# Paramètres non utilisés ici (disponibles pour affinage) :
#   -Operations : filtrerait des opérations spécifiques dans le RecordType
#                 (ex. "Set-Mailbox" uniquement dans ExchangeAdmin)
#   -UserIds    : limiterait la rétention étendue à un utilisateur nommé
#                 (utile pour retenir les logs d'un compte à risque plus longtemps)
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
Write-Host "4. Vérification depuis le backend Purview..." -ForegroundColor Cyan

# Sleep 30s : latence de propagation standard après création d'une ARP.
# On relit depuis l'API plutôt que de se fier à $NewARP (peut être incomplet en cas de lag).
# Rappel : pas de -Identity → Where-Object obligatoire pour filtrer par nom.
Start-Sleep -Seconds 30

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
    PolicyCréée      = $ARPName
    RecordType       = "ExchangeAdmin"
    DuréeRétention   = "TwelveMonths (1 an)"
    Priorité         = $TargetPriority
    EffetSurContenu  = "Aucun — agit sur les logs d'audit uniquement"
    # Note visibilité GUI : les ARPs créées via PowerShell sur des RecordTypes hors tableau
    # de bord standard peuvent ne pas apparaître dans Purview portal > Audit > Audit retention
    # policies. Elles sont fonctionnelles côté backend — gestion exclusivement via PowerShell :
    # Get-/Set-/Remove-UnifiedAuditLogRetentionPolicy
    VisibilitéPortail = "Potentiellement absente du portail Purview (fonctionnelle backend — gestion via PowerShell uniquement)"
} | Format-List

# ========================================================================================
# NETTOYAGE MÉMOIRE
# ========================================================================================
Remove-Variable BaseARPName, ARPName, Counter, ExistingARPs, UsedPriorities,
                TargetPriority, NewARP, CheckARP `
                -ErrorAction SilentlyContinue

# ========================================================================================
# FERMETURE — RESET DE SESSION TOTAL
# ========================================================================================
Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
Get-PSSession | Remove-PSSession
Write-Host "Sessions fermées proprement." -ForegroundColor Magenta
