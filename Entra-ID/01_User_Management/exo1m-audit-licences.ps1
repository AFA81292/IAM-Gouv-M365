# ========================================================================================
# Exercice 1m : Entra ID — Audit des licences du tenant
# ========================================================================================
# Concept : La gouvernance des licences est un axe clé de l'IAM.
# Une licence non attribuée = coût inutile.
# Une licence attribuée à un compte inactif = double problème (coût + surface d'attaque).
# Un utilisateur avec plusieurs licences redondantes = surcoût à identifier.
#
# Ce script produit quatre angles d'analyse complémentaires :
#   A) Vue globale du tenant : SKUs disponibles, consommés, restants
#   B) Utilisateurs sans licence (comptes potentiellement orphelins ou guests)
#   C) Utilisateurs multi-licences (surcoût potentiel ou cas légitimes à valider)
#   D) Détail par SKU : qui détient quelle licence
#
# Ce que fait ce script :
#   1. Reset total de session
#   2. Inventaire des SKUs du tenant (capacité vs consommation)
#   3. Audit des utilisateurs sans licence
#   4. Audit des utilisateurs multi-licences
#   5. Détail des assignations par SKU
#   6. Résumé chiffré
#   7. Export CSV horodatés (4 fichiers)
#   8. Fermeture propre
#
# Note : ce script est en lecture seule — aucune modification du tenant.
#
# Fichiers CSV générés :
#   Licences_SKU_YYYYMMDD_HHmmss.csv          (vue globale SKUs)
#   Licences_SansLicence_YYYYMMDD_HHmmss.csv  (utilisateurs sans licence)
#   Licences_Multi_YYYYMMDD_HHmmss.csv        (utilisateurs multi-licences)
#   Licences_ParSKU_YYYYMMDD_HHmmss.csv       (détail assignations par SKU)
#
# Delta pédagogique vs exos 1c/1d/1i (attribution/retrait de licence) :
#   1c/1d → opérations d'écriture : attribuer une licence
#   1i    → opération d'écriture : retirer une licence
#   1m    → lecture seule : photographier l'état des licences pour audit/reporting
#
# Module requis : Microsoft.Graph.Users, Microsoft.Graph.Identity.DirectoryManagement
# Connexion     : Connect-MgGraph
# ========================================================================================

# --- OUVERTURE — RESET DE SESSION TOTAL ---
# User.Read.All      : lire les propriétés et licences de tous les utilisateurs
# Directory.Read.All : accéder aux SKUs du tenant (Get-MgSubscribedSku)
# Pas de -ContextScope Process requis : lecture seule, aucun scope d'écriture.
$Scopes = @(
    "User.Read.All",
    "Directory.Read.All"
)

Disconnect-MgGraph -ErrorAction SilentlyContinue
Connect-MgGraph -Scopes $Scopes -NoWelcome

# ========================================================================================
# ÉTAPE 1 : Inventaire des SKUs du tenant
# ========================================================================================
Write-Host "1. Récupération des SKUs du tenant..." -ForegroundColor Cyan

# Get-MgSubscribedSku retourne les licences souscrites au niveau tenant.
# Chaque SKU est une famille de licence (ex : ENTERPRISEPREMIUM = M365 E3,
# SPE_E5 = M365 E5, AAD_PREMIUM_P2 = Entra ID P2...).
#
# Propriétés clés :
#   SkuPartNumber          : nom court lisible (ex : "SPE_E5")
#   SkuId                  : GUID — utilisé dans les assignations utilisateur
#   PrepaidUnits.Enabled   : sièges achetés au total
#   ConsumedUnits          : sièges effectivement assignés
#   Restants (calculé)     : Enabled - ConsumedUnits = sièges disponibles
$AllSKUs = Get-MgSubscribedSku -All

$SKURows = @()
foreach ($SKU in $AllSKUs) {
    $Restants = $SKU.PrepaidUnits.Enabled - $SKU.ConsumedUnits

    $SKURows += [PSCustomObject]@{
        SKU          = $SKU.SkuPartNumber
        SkuId        = $SKU.SkuId
        Achetes      = $SKU.PrepaidUnits.Enabled
        Consommes    = $SKU.ConsumedUnits
        Restants     = $Restants
        # Alerte si moins de 10% de sièges restants
        Alerte       = if ($SKU.PrepaidUnits.Enabled -gt 0 -and
                           ($Restants / $SKU.PrepaidUnits.Enabled) -lt 0.10) {
                           "CAPACITE FAIBLE"
                       } else { "" }
        # Colonnes disponibles non exportées :
        #   $SKU.CapabilityStatus         : état du SKU ("Enabled", "Suspended", "Warning")
        #   $SKU.PrepaidUnits.Suspended   : sièges suspendus (impayés ou résiliation en cours)
        #   $SKU.PrepaidUnits.Warning     : sièges en période de grâce
        #   $SKU.ServicePlans             : liste des services inclus dans le SKU (Exchange, Teams...)
    }
}

Write-Host "-> $($SKURows.Count) SKU(s) trouvés dans le tenant.`n" -ForegroundColor Green
$SKURows | Select-Object SKU, Achetes, Consommes, Restants, Alerte | Format-Table -AutoSize

# ========================================================================================
# ÉTAPE 2 : Audit des utilisateurs sans licence
# ========================================================================================
Write-Host "2. Audit des utilisateurs sans licence..." -ForegroundColor Cyan

# DÉCOUVERTE TECHNIQUE : AssignedLicenses est une propriété qui n'est pas retournée
# par défaut dans Get-MgUser -All. Elle doit être demandée explicitement via -Property.
# Sans ce paramètre, AssignedLicenses.Count vaut toujours 0 même si des licences existent.
#
# Variante filtre Graph direct (plus performant sur grands tenants) :
#   Get-MgUser -All -Filter "assignedLicenses/$count eq 0" `
#       -ConsistencyLevel eventual -CountVariable NbSansLicence
# Avantage : le filtre est évalué côté serveur — pas de rapatriement de tous les objets.
# Inconvénient : nécessite ConsistencyLevel eventual (index pas toujours à jour).
# Le filtre Where-Object local ci-dessous est plus sûr sur un tenant de dev.
$AllUsers = Get-MgUser -All -Property "Id,DisplayName,UserPrincipalName,UserType,AccountEnabled,AssignedLicenses,Department"

$NoLicenceRows = @()
foreach ($User in $AllUsers) {
    if ($User.AssignedLicenses.Count -eq 0) {
        $NoLicenceRows += [PSCustomObject]@{
            DisplayName       = $User.DisplayName
            UPN               = $User.UserPrincipalName
            TypeCompte        = $User.UserType   # Member ou Guest
            CompteActif       = $User.AccountEnabled
            Departement       = $User.Department
            # Colonnes disponibles non exportées :
            #   $User.Id              : ObjectId Entra
            #   $User.CreatedDateTime : date de création du compte
            #   $User.SignInActivity  : dernière connexion (scope AuditLog.Read.All requis)
        }
    }
}

Write-Host "-> $($NoLicenceRows.Count) utilisateur(s) sans licence.`n" -ForegroundColor $(
    if ($NoLicenceRows.Count -gt 0) { "Yellow" } else { "Green" }
)

if ($NoLicenceRows.Count -gt 0) {
    $NoLicenceRows | Select-Object DisplayName, UPN, TypeCompte, CompteActif, Departement |
        Format-Table -AutoSize
}

# ========================================================================================
# ÉTAPE 3 : Audit des utilisateurs multi-licences
# ========================================================================================
Write-Host "3. Audit des utilisateurs multi-licences..." -ForegroundColor Cyan

# Un utilisateur avec plusieurs licences n'est pas forcément anormal :
#   - M365 E5 + Entra ID P2 standalone : peut être redondant (E5 inclut déjà P2)
#   - M365 E3 + Power BI Pro : légitime si le service n'est pas inclus dans E3
#   - M365 E5 + M365 E3 : quasi toujours un doublon — économie possible
#
# Ce bloc identifie les cas — la décision de conserver ou retirer reste humaine.
$MultiLicenceRows = @()
foreach ($User in $AllUsers) {
    if ($User.AssignedLicenses.Count -ge 2) {

        # Résolution lisible : boucle explicite pour éviter l'ambiguïté $_ dans les pipelines imbriqués
        # Variante alternative si un SKU n'est pas résolu (hors liste Get-MgSubscribedSku) :
        #   retourner le GUID brut $AssignedLic.SkuId pour investigation manuelle.
        $LicenceList = @()
        foreach ($AssignedLic in $User.AssignedLicenses) {
            $Match = $AllSKUs | Where-Object { $_.SkuId -eq $AssignedLic.SkuId }
            if ($Match) {
                $LicenceList += $Match.SkuPartNumber
            } else {
                # SKU non résolu : on retourne le GUID brut pour investigation
                $LicenceList += $AssignedLic.SkuId
            }
        }

        $MultiLicenceRows += [PSCustomObject]@{
            DisplayName   = $User.DisplayName
            UPN           = $User.UserPrincipalName
            NbLicences    = $User.AssignedLicenses.Count
            Licences      = $LicenceList -join " | "
            CompteActif   = $User.AccountEnabled
            # Colonnes disponibles non exportées :
            #   $User.Id          : ObjectId Entra (utile pour Set-MgUserLicense en correction)
            #   $User.Department  : département — aide à contextualiser si le multi-licence est légitime
            #   $User.UserType    : Member ou Guest — un Guest avec plusieurs licences est inhabituel
        }
    }
}

Write-Host "-> $($MultiLicenceRows.Count) utilisateur(s) avec 2 licences ou plus.`n" -ForegroundColor $(
    if ($MultiLicenceRows.Count -gt 0) { "Yellow" } else { "Green" }
)

if ($MultiLicenceRows.Count -gt 0) {
    $MultiLicenceRows | Select-Object DisplayName, UPN, NbLicences, Licences, CompteActif |
        Format-Table -AutoSize
}

# ========================================================================================
# ÉTAPE 4 : Détail des assignations par SKU
# ========================================================================================
Write-Host "4. Détail des assignations par SKU..." -ForegroundColor Cyan

# On inverse la lecture : au lieu de partir de l'utilisateur vers ses licences,
# on part de chaque SKU pour lister qui le détient.
# Utile pour : "donne-moi la liste de tous les utilisateurs avec une licence E5"
# sans passer par l'interface graphique.
$PerSKURows = @()

foreach ($SKU in $AllSKUs) {
    $Holders = $AllUsers | Where-Object {
        $_.AssignedLicenses.SkuId -contains $SKU.SkuId
    }

    foreach ($Holder in $Holders) {
        $PerSKURows += [PSCustomObject]@{
            SKU           = $SKU.SkuPartNumber
            SkuId         = $SKU.SkuId
            DisplayName   = $Holder.DisplayName
            UPN           = $Holder.UserPrincipalName
            TypeCompte    = $Holder.UserType
            CompteActif   = $Holder.AccountEnabled
            Departement   = $Holder.Department
            # Colonnes disponibles non exportées :
            #   $Holder.Id                   : ObjectId — utile pour cibler Set-MgUserLicense
            #   $SKU.PrepaidUnits.Enabled    : nombre de sièges achetés pour ce SKU
            #   $SKU.ConsumedUnits           : total consommé tenant-wide pour ce SKU
        }
    }
}

Write-Host "-> $($PerSKURows.Count) ligne(s) d'assignation détaillée(s) (1 ligne = 1 user x 1 SKU).`n" -ForegroundColor Green

# Variante : afficher uniquement les assignations pour un SKU spécifique
# $CibleSKU = "SPE_E5"
# $PerSKURows | Where-Object { $_.SKU -eq $CibleSKU } | Format-Table -AutoSize

$PerSKURows | Select-Object SKU, DisplayName, UPN, TypeCompte, CompteActif, Departement |
    Sort-Object SKU, DisplayName |
    Format-Table -AutoSize

# ========================================================================================
# ÉTAPE 5 : Résumé chiffré
# ========================================================================================
Write-Host "`n=== RÉSUMÉ ===" -ForegroundColor Magenta
[PSCustomObject]@{
    TotalUtilisateurs      = $AllUsers.Count
    UtilisateursSansLicence = $NoLicenceRows.Count
    UtilisateursMultiLicence = $MultiLicenceRows.Count
    SKUsTenant             = $SKURows.Count
    LignesAssignationTotal = $PerSKURows.Count
    Scope                  = "User.Read.All + Directory.Read.All (lecture seule)"
    PointAttentionAudit    = "Sans licence = compte potentiellement orphelin | Multi-licence = surcoût potentiel"
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

# --- CSV 1 : Vue globale SKUs ---
# Colonnes exportées : SKU, SkuId, Achetes, Consommes, Restants, Alerte
# Colonnes disponibles non exportées :
#   CapabilityStatus, PrepaidUnits.Suspended, PrepaidUnits.Warning, ServicePlans
$SKURows | Export-Csv `
    -Path "$ExportPath\Licences_SKU_$Timestamp.csv" `
    -Encoding UTF8 -NoTypeInformation
Write-Host "-> SKUs : $($SKURows.Count) ligne(s) — Licences_SKU_$Timestamp.csv" -ForegroundColor Green

# --- CSV 2 : Utilisateurs sans licence ---
# Colonnes exportées : DisplayName, UPN, TypeCompte, CompteActif, Departement
# Colonnes disponibles non exportées :
#   Id, CreatedDateTime, SignInActivity (nécessite AuditLog.Read.All)
if ($NoLicenceRows.Count -gt 0) {
    $NoLicenceRows | Export-Csv `
        -Path "$ExportPath\Licences_SansLicence_$Timestamp.csv" `
        -Encoding UTF8 -NoTypeInformation
    Write-Host "-> Sans licence : $($NoLicenceRows.Count) ligne(s) — Licences_SansLicence_$Timestamp.csv" -ForegroundColor Green
} else {
    Write-Host "-> Sans licence : aucune donnée à exporter." -ForegroundColor Yellow
}

# --- CSV 3 : Utilisateurs multi-licences ---
# Colonnes exportées : DisplayName, UPN, NbLicences, Licences, CompteActif
# Colonnes disponibles non exportées :
#   Id (pour cibler Set-MgUserLicense), Department, UserType
# Ce CSV est le point de départ d'un chantier d'optimisation des coûts de licences.
if ($MultiLicenceRows.Count -gt 0) {
    $MultiLicenceRows | Export-Csv `
        -Path "$ExportPath\Licences_Multi_$Timestamp.csv" `
        -Encoding UTF8 -NoTypeInformation
    Write-Host "-> Multi-licences : $($MultiLicenceRows.Count) ligne(s) — Licences_Multi_$Timestamp.csv" -ForegroundColor Green
} else {
    Write-Host "-> Multi-licences : aucune donnée à exporter." -ForegroundColor Yellow
}

# --- CSV 4 : Détail par SKU ---
# Colonnes exportées : SKU, SkuId, DisplayName, UPN, TypeCompte, CompteActif, Departement
# Colonnes disponibles non exportées :
#   Holder.Id (ObjectId Entra), SKU.PrepaidUnits.Enabled, SKU.ConsumedUnits
# Ce CSV est le livrable principal pour un rapport d'audit licences complet :
# filtrer dans Excel par colonne SKU pour isoler chaque famille de licences.
$PerSKURows | Sort-Object SKU, DisplayName | Export-Csv `
    -Path "$ExportPath\Licences_ParSKU_$Timestamp.csv" `
    -Encoding UTF8 -NoTypeInformation
Write-Host "-> Par SKU : $($PerSKURows.Count) ligne(s) — Licences_ParSKU_$Timestamp.csv" -ForegroundColor Green

Write-Host "-> Export terminé dans : $ExportPath`n" -ForegroundColor Green

# ========================================================================================
# NETTOYAGE MÉMOIRE
# ========================================================================================
Remove-Variable Scopes, AllSKUs, SKURows, AllUsers, NoLicenceRows, MultiLicenceRows,
                PerSKURows, SKU, User, Holder, Holders, Restants, LicenceList,
                AssignedLic, Match, ExportPath, Timestamp `
                -ErrorAction SilentlyContinue

# ========================================================================================
# FERMETURE — RESET DE SESSION TOTAL
# ========================================================================================
Disconnect-MgGraph -ErrorAction SilentlyContinue
Write-Host "Session MgGraph fermée proprement." -ForegroundColor Magenta
