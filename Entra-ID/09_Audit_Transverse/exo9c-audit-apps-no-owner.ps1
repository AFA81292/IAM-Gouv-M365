# ========================================================================================
# Exercice 9c : Entra ID — Audit transverse — Audit des applications sans propriétaire
# ========================================================================================
# Concept : La gouvernance des Enterprise Applications repose sur les owners —
# sans owner, une app n'a pas de responsable identifié pour son cycle de vie,
# ses permissions, ses secrets et ses certificats.
# En mission : une app sans owner est une dette de gouvernance immédiate.
#
# Ce script produit quatre angles d'analyse :
#   A) Apps sans aucun owner (hors Microsoft)
#   B) Apps avec plusieurs owners (risque de dilution de responsabilité)
#   C) Apps sans activité récente (candidates à la décommission)
#   D) Secrets et certificats expirant sous 30 jours (risque opérationnel)
#
# Ce que fait ce script :
#   1. Reset total de session
#   2. Chargement en cache des SPs, App Registrations et owners
#   3. Audit des apps sans owner
#   4. Audit des apps multi-owners
#   5. Audit des apps sans activité récente (créées il y a > 90 jours, jamais utilisées)
#   6. Audit des secrets et certificats à expiration imminente
#   7. Résumé chiffré
#   8. Export CSV horodatés (4 fichiers)
#   9. Fermeture propre
#
# Note : ce script est en lecture seule — aucune modification du tenant.
#
# Delta pédagogique vs exo 9b (audit Enterprise Apps global) :
#   9b → inventaire global + 4 angles dont sans owner en passant
#   9c → focus gouvernance exclusif : owner, multi-owner, inactivité, expiration secrets
#        granularité maximale — les 4 CSV 9c alimentent le Tenant Security Snapshot (9d)
#
# Fichiers CSV générés :
#   AppsGouv_SansOwner_YYYYMMDD_HHmmss.csv       (apps sans owner)
#   AppsGouv_MultiOwner_YYYYMMDD_HHmmss.csv      (apps avec plusieurs owners)
#   AppsGouv_Inactives_YYYYMMDD_HHmmss.csv       (apps sans activité récente)
#   AppsGouv_SecretsExpiration_YYYYMMDD_HHmmss.csv (secrets/certs expirant sous 30j)
#
# Module requis : Microsoft.Graph.Applications, Microsoft.Graph.Users
# Connexion     : Connect-MgGraph
# ========================================================================================

# --- OUVERTURE — RESET DE SESSION TOTAL ---
# Application.Read.All : lire les SPs, App Registrations, owners, secrets et certificats
# User.Read.All        : résoudre les owner IDs en DisplayName/UPN lisibles
#
# Pas de -ContextScope Process requis : lecture seule, aucun scope d'écriture.
$Scopes = @(
    "Application.Read.All",
    "User.Read.All"
)

Disconnect-MgGraph -ErrorAction SilentlyContinue
Connect-MgGraph -Scopes $Scopes -NoWelcome

# ========================================================================================
# ÉTAPE 1 : Chargement en cache
# ========================================================================================
Write-Host "1. Chargement des données sources en cache..." -ForegroundColor Cyan

$MicrosoftTenantId  = "f8cdef31-a31e-4b4a-93e4-5f571e91255a"
$InactivityDays     = 90    # Seuil inactivité : app créée il y a > N jours
$ExpirationDays     = 30    # Seuil expiration secrets/certs : expire dans < N jours
$InactivityThreshold  = (Get-Date).AddDays(-$InactivityDays)
$ExpirationThreshold  = (Get-Date).AddDays($ExpirationDays)

# Service Principals — vue tenant (toutes les apps, Microsoft inclus)
$AllSPs = Get-MgServicePrincipal -All `
    -Property "Id,DisplayName,AppId,AppOwnerOrganizationId,CreatedDateTime,AccountEnabled,ServicePrincipalType"

# App Registrations — uniquement les apps enregistrées localement
# Contiennent les secrets (PasswordCredentials) et certificats (KeyCredentials)
$AllAppRegs = Get-MgApplication -All `
    -Property "Id,DisplayName,AppId,CreatedDateTime,PasswordCredentials,KeyCredentials"

# Cache utilisateurs pour résolution des owner IDs
$AllUsers = Get-MgUser -All -Property "Id,DisplayName,UserPrincipalName"

# Index AppId → AppReg pour lookup rapide dans les boucles
$AppRegIndex = @{}
foreach ($AppReg in $AllAppRegs) { $AppRegIndex[$AppReg.AppId] = $AppReg }

# On exclut les apps Microsoft de l'audit gouvernance :
# elles n'ont pas d'owner par design et leur cycle de vie est géré par Microsoft
$NonMicrosoftSPs = $AllSPs | Where-Object {
    $_.AppOwnerOrganizationId -ne $MicrosoftTenantId
}

Write-Host "-> SPs total             : $($AllSPs.Count)" -ForegroundColor Green
Write-Host "-> SPs hors Microsoft    : $($NonMicrosoftSPs.Count)" -ForegroundColor Green
Write-Host "-> App Registrations     : $($AllAppRegs.Count)" -ForegroundColor Green
Write-Host "-> Seuil inactivité      : $InactivityDays jours" -ForegroundColor Gray
Write-Host "-> Seuil expiration      : $ExpirationDays jours`n" -ForegroundColor Gray

# ========================================================================================
# ÉTAPE 2 : Audit des apps sans owner
# ========================================================================================
Write-Host "2. Audit des apps sans owner..." -ForegroundColor Cyan

# Owner d'une Enterprise App = utilisateur (ou SP) responsable du cycle de vie.
# Sans owner : personne à notifier en cas d'expiration de secret, de compromission
# ou de demande de décommission. Risque de gouvernance immédiat.
#
# Note : on audite les owners via Get-MgServicePrincipalOwner (vue SP dans le tenant).
# Les owners peuvent aussi être définis sur l'App Registration — les deux sont distincts.
# En pratique, l'owner sur le SP est celui visible dans Entra Admin Center > Enterprise Apps.
$NoOwnerRows = @()
$OwnerCache  = @{}   # Cache : SPId → liste owners — réutilisé en étape 3

foreach ($SP in $NonMicrosoftSPs) {
    $Owners = Get-MgServicePrincipalOwner -ServicePrincipalId $SP.Id -ErrorAction SilentlyContinue
    $OwnerCache[$SP.Id] = $Owners

    if ($Owners.Count -eq 0) {
        $NoOwnerRows += [PSCustomObject]@{
            DisplayName  = $SP.DisplayName
            AppId        = $SP.AppId
            TypeSP       = $SP.ServicePrincipalType
            Actif        = $SP.AccountEnabled
            CreeLe       = $SP.CreatedDateTime
            AppRegLocale = $AppRegIndex.ContainsKey($SP.AppId)
            # Colonnes disponibles non exportées :
            #   $SP.Id              : ObjectId SP (pour New-MgServicePrincipalOwnerByRef)
            #   $SP.Tags            : tags Entra
            #   $SP.Homepage        : URL homepage
        }
    }
}

Write-Host "-> $($NoOwnerRows.Count) app(s) sans owner (hors Microsoft).`n" -ForegroundColor $(
    if ($NoOwnerRows.Count -gt 0) { "Yellow" } else { "Green" }
)

# ========================================================================================
# ÉTAPE 3 : Audit des apps multi-owners
# ========================================================================================
Write-Host "3. Audit des apps avec plusieurs owners..." -ForegroundColor Cyan

# Plusieurs owners = responsabilité diluée.
# En théorie : redondance utile (si un owner quitte, l'autre prend le relais).
# En pratique : souvent le résultat d'ajouts successifs sans revue — personne
# ne sait réellement qui est l'owner "référent". À documenter et à rationaliser.
# Seuil : 2+ owners → signaler pour revue. Pas nécessairement un problème, mais à valider.
$MultiOwnerRows = @()

foreach ($SP in $NonMicrosoftSPs) {
    # Réutilisation du cache owners construit à l'étape précédente
    # Évite un deuxième appel Graph par SP
    $Owners = if ($OwnerCache.ContainsKey($SP.Id)) {
        $OwnerCache[$SP.Id]
    } else {
        Get-MgServicePrincipalOwner -ServicePrincipalId $SP.Id -ErrorAction SilentlyContinue
    }

    if ($Owners.Count -ge 2) {
        # Résolution des owners en noms lisibles
        $OwnerNames = @()
        foreach ($Owner in $Owners) {
            $OwnerUser = $AllUsers | Where-Object { $_.Id -eq $Owner.Id } | Select-Object -First 1
            $OwnerNames += if ($OwnerUser) { $OwnerUser.DisplayName } else { $Owner.Id }
        }

        $MultiOwnerRows += [PSCustomObject]@{
            DisplayName  = $SP.DisplayName
            AppId        = $SP.AppId
            TypeSP       = $SP.ServicePrincipalType
            Actif        = $SP.AccountEnabled
            NbOwners     = $Owners.Count
            Owners       = $OwnerNames -join " | "
            CreeLe       = $SP.CreatedDateTime
            # Colonnes disponibles non exportées :
            #   $SP.Id              : ObjectId SP
            #   $Owner.Id           : ObjectId de chaque owner (pour Remove-MgServicePrincipalOwnerByRef)
        }
    }
}

Write-Host "-> $($MultiOwnerRows.Count) app(s) avec 2 owners ou plus.`n" -ForegroundColor $(
    if ($MultiOwnerRows.Count -gt 0) { "Yellow" } else { "Green" }
)

# ========================================================================================
# ÉTAPE 4 : Audit des apps sans activité récente
# ========================================================================================
Write-Host "4. Audit des apps sans activité récente (> $InactivityDays jours)..." -ForegroundColor Cyan

# DÉCOUVERTE TECHNIQUE : SignInActivity sur les Service Principals nécessite
# le scope AuditLog.Read.All en plus — non inclus ici pour garder le script simple.
# Contournement : on utilise CreatedDateTime comme proxy d'inactivité.
# Une app créée il y a > 90 jours sans jamais avoir été utilisée est candidate
# à la décommission — à confirmer avec les équipes métier.
#
# En mission avec AuditLog.Read.All disponible :
#   $SP.SignInActivity.LastSignInDateTime → date de dernière utilisation réelle
#   Remplacer le filtre CreatedDateTime par SignInActivity pour plus de précision.
$InactiveRows = @()

foreach ($SP in $NonMicrosoftSPs) {
    # DÉCOUVERTE TECHNIQUE — dates Graph et PowerShell : trois pièges distincts
    #
    # PIÈGE 1 : Graph retourne les dates en string ISO 8601, pas en [DateTime].
    #   Conséquence : une soustraction arithmétique "date - date" explose avec
    #   MethodException "Cannot find an overload for op_Subtraction" si on ne caste pas.
    #   PowerShell 7 fait parfois le cast implicitement sur les comparaisons -gt/-lt,
    #   mais JAMAIS sur les soustractions. Règle : tout $objet.XxxDateTime utilisé
    #   dans un calcul → [DateTime]$objet.XxxDateTime.
    #   Exemple ligne 215 : (Get-Date) - [DateTime]$SP.CreatedDateTime
    #
    # PIÈGE 2 : CreatedDateTime peut être $null sur certains types de SP.
    #   Les Managed Identities (identités managées Azure pour VMs, Function Apps...)
    #   ne renseignent pas toujours CreatedDateTime — le champ revient $null.
    #   Caster $null en [DateTime] lève InvalidArgument "Cannot convert null to System.DateTime".
    #   Solution : garde-fou $SP.CreatedDateTime -and [DateTime]$SP.CreatedDateTime
    #   Le -and court-circuite : si $null, PowerShell n'évalue pas le cast.
    #
    # PIÈGE 3 (rappel général, non reproductible ici) : return if (...) est invalide en PS.
    #   PowerShell n'accepte pas "return if (condition) { X } else { Y }".
    #   Syntaxe correcte : if (condition) { return X } else { return Y }
    #   Ce pattern C#/Python lève "The term 'if' is not recognized as a cmdlet".
    #   Voir correction fonction Resolve-ScopeLabel dans exo8f.
    if ($SP.CreatedDateTime -and [DateTime]$SP.CreatedDateTime -lt $InactivityThreshold) {

        $Owners = if ($OwnerCache.ContainsKey($SP.Id)) {
            $OwnerCache[$SP.Id]
        } else {
            Get-MgServicePrincipalOwner -ServicePrincipalId $SP.Id -ErrorAction SilentlyContinue
        }

        $OwnerNames = @()
        foreach ($Owner in $Owners) {
            $OwnerUser = $AllUsers | Where-Object { $_.Id -eq $Owner.Id } | Select-Object -First 1
            $OwnerNames += if ($OwnerUser) { $OwnerUser.DisplayName } else { $Owner.Id }
        }

        # Cast [DateTime] obligatoire — voir PIÈGE 1 ci-dessus.
        # Sans le cast : MethodException "op_Subtraction" car Graph retourne une string.
        # Le null est déjà exclu par le garde-fou du if parent (PIÈGE 2).
        $JoursDepuisCreation = [math]::Round(((Get-Date) - [DateTime]$SP.CreatedDateTime).TotalDays)

        $InactiveRows += [PSCustomObject]@{
            DisplayName          = $SP.DisplayName
            AppId                = $SP.AppId
            TypeSP               = $SP.ServicePrincipalType
            Actif                = $SP.AccountEnabled
            CreeLe               = $SP.CreatedDateTime
            JoursDepuisCreation  = $JoursDepuisCreation
            NbOwners             = $Owners.Count
            Owners               = if ($OwnerNames.Count -gt 0) { $OwnerNames -join " | " } else { "SANS OWNER" }
            AppRegLocale         = $AppRegIndex.ContainsKey($SP.AppId)
            # Colonnes disponibles non exportées :
            #   $SP.Id                              : ObjectId SP
            #   $SP.SignInActivity.LastSignInDateTime : nécessite AuditLog.Read.All
            #   Variante production avec SignInActivity :
            #     if ($SP.SignInActivity.LastSignInDateTime -lt $InactivityThreshold) { ... }
        }
    }
}

# Tri par ancienneté décroissante : les plus vieilles apps en premier
$InactiveRows = $InactiveRows | Sort-Object JoursDepuisCreation -Descending

Write-Host "-> $($InactiveRows.Count) app(s) créée(s) il y a plus de $InactivityDays jours.`n" -ForegroundColor $(
    if ($InactiveRows.Count -gt 0) { "Yellow" } else { "Green" }
)

# ========================================================================================
# ÉTAPE 5 : Audit des secrets et certificats à expiration imminente
# ========================================================================================
Write-Host "5. Audit des secrets et certificats expirant sous $ExpirationDays jours..." -ForegroundColor Cyan

# Les secrets (PasswordCredentials) et certificats (KeyCredentials) sont définis
# sur les App Registrations, pas sur les Service Principals.
# Leur expiration = l'app ne peut plus s'authentifier → coupure de service.
# En mission : livrable hebdomadaire critique pour éviter les incidents prod.
#
# PasswordCredentials : secrets générés dans Entra (client secrets)
# KeyCredentials      : certificats uploadés (thumbprint, dates de validité)
$SecretExpirationRows = @()

foreach ($AppReg in $AllAppRegs) {

    # Vérification des secrets
    foreach ($Secret in $AppReg.PasswordCredentials) {
        if ($null -eq $Secret.EndDateTime) { continue }
        if ([DateTime]$Secret.EndDateTime -gt $ExpirationThreshold) { continue }

        $JoursRestants = [math]::Round(([DateTime]$Secret.EndDateTime - (Get-Date)).TotalDays)

        # Résolution des owners depuis le SP correspondant
        $CorrespondingSP = $AllSPs | Where-Object { $_.AppId -eq $AppReg.AppId } | Select-Object -First 1
        $SPOwners = if ($CorrespondingSP -and $OwnerCache.ContainsKey($CorrespondingSP.Id)) {
            $OwnerCache[$CorrespondingSP.Id]
        } else { @() }

        $OwnerNames = @()
        foreach ($Owner in $SPOwners) {
            $OwnerUser = $AllUsers | Where-Object { $_.Id -eq $Owner.Id } | Select-Object -First 1
            $OwnerNames += if ($OwnerUser) { $OwnerUser.DisplayName } else { $Owner.Id }
        }

        $SecretExpirationRows += [PSCustomObject]@{
            AppDisplayName   = $AppReg.DisplayName
            AppId            = $AppReg.AppId
            TypeCredential   = "Secret"
            NomCredential    = $Secret.DisplayName
            Expiration       = $Secret.EndDateTime
            JoursRestants    = $JoursRestants
            Alerte           = if ($JoursRestants -le 0) { "EXPIRE" }
                               elseif ($JoursRestants -le 7) { "CRITIQUE" }
                               else { "ATTENTION" }
            Owners           = if ($OwnerNames.Count -gt 0) { $OwnerNames -join " | " } else { "SANS OWNER" }
            # Colonnes disponibles non exportées :
            #   $Secret.KeyId       : identifiant unique du secret (pour rotation ciblée)
            #   $Secret.StartDateTime : date de début de validité
            #   $AppReg.Id          : ObjectId de l'App Registration
        }
    }

    # Vérification des certificats
    foreach ($Cert in $AppReg.KeyCredentials) {
        if ($null -eq $Cert.EndDateTime) { continue }
        if ([DateTime]$Cert.EndDateTime -gt $ExpirationThreshold) { continue }

        $JoursRestants = [math]::Round(([DateTime]$Cert.EndDateTime - (Get-Date)).TotalDays)

        $CorrespondingSP = $AllSPs | Where-Object { $_.AppId -eq $AppReg.AppId } | Select-Object -First 1
        $SPOwners = if ($CorrespondingSP -and $OwnerCache.ContainsKey($CorrespondingSP.Id)) {
            $OwnerCache[$CorrespondingSP.Id]
        } else { @() }

        $OwnerNames = @()
        foreach ($Owner in $SPOwners) {
            $OwnerUser = $AllUsers | Where-Object { $_.Id -eq $Owner.Id } | Select-Object -First 1
            $OwnerNames += if ($OwnerUser) { $OwnerUser.DisplayName } else { $Owner.Id }
        }

        $SecretExpirationRows += [PSCustomObject]@{
            AppDisplayName   = $AppReg.DisplayName
            AppId            = $AppReg.AppId
            TypeCredential   = "Certificat"
            NomCredential    = $Cert.DisplayName
            Expiration       = $Cert.EndDateTime
            JoursRestants    = $JoursRestants
            Alerte           = if ($JoursRestants -le 0) { "EXPIRE" }
                               elseif ($JoursRestants -le 7) { "CRITIQUE" }
                               else { "ATTENTION" }
            Owners           = if ($OwnerNames.Count -gt 0) { $OwnerNames -join " | " } else { "SANS OWNER" }
            # Colonnes disponibles non exportées :
            #   $Cert.KeyId         : identifiant unique du certificat
            #   $Cert.Thumbprint    : thumbprint pour vérification
            #   $Cert.StartDateTime : date de début de validité
            #   $Cert.Type          : type de clé (AsymmetricX509Cert, etc.)
        }
    }
}

$SecretExpirationRows = $SecretExpirationRows | Sort-Object JoursRestants

Write-Host "-> $($SecretExpirationRows.Count) secret(s)/certificat(s) expirant dans les $ExpirationDays prochains jours.`n" -ForegroundColor $(
    if (($SecretExpirationRows | Where-Object { $_.Alerte -in @("EXPIRE","CRITIQUE") }).Count -gt 0) { "Red" }
    elseif ($SecretExpirationRows.Count -gt 0) { "Yellow" }
    else { "Green" }
)

if ($SecretExpirationRows.Count -gt 0) {
    $SecretExpirationRows |
        Select-Object AppDisplayName, TypeCredential, NomCredential, Expiration, JoursRestants, Alerte, Owners |
        Format-Table -AutoSize
}

# ========================================================================================
# ÉTAPE 6 : Résumé chiffré
# ========================================================================================
Write-Host "`n=== RÉSUMÉ ===" -ForegroundColor Magenta
[PSCustomObject]@{
    "SPs hors Microsoft"           = $NonMicrosoftSPs.Count
    "Sans owner"                   = $NoOwnerRows.Count
    "Multi-owners (2+)"            = $MultiOwnerRows.Count
    "Sans activité > $($InactivityDays)j"  = $InactiveRows.Count
    "Secrets/Certs expirant < $($ExpirationDays)j" = $SecretExpirationRows.Count
    "Dont EXPIRES ou CRITIQUES"    = ($SecretExpirationRows | Where-Object { $_.Alerte -in @("EXPIRE","CRITIQUE") }).Count
    Scope                          = "Application.Read.All + User.Read.All (lecture seule)"
    PointAttentionAudit            = "Sans owner + secret CRITIQUE = risque opérationnel et sécurité combinés"
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

# --- CSV 1 : Apps sans owner ---
# Colonnes : DisplayName, AppId, TypeSP, Actif, CreeLe, AppRegLocale
# Colonnes disponibles non exportées : Id (pour New-MgServicePrincipalOwnerByRef)
# Action corrective : assigner un owner via Entra Admin Center ou
#   New-MgServicePrincipalOwnerByRef -ServicePrincipalId {id} -BodyParameter @{"@odata.id"="..."}
# AppRegLocale = TRUE → app interne avec App Registration locale → owner obligatoire
if ($NoOwnerRows.Count -gt 0) {
    $NoOwnerRows | Sort-Object CreeLe | Export-Csv `
        -Path "$ExportPath\AppsGouv_SansOwner_$Timestamp.csv" `
        -Encoding UTF8 -NoTypeInformation
    Write-Host "-> Sans owner       : $($NoOwnerRows.Count) ligne(s) — AppsGouv_SansOwner_$Timestamp.csv" -ForegroundColor Yellow
} else {
    Write-Host "-> Sans owner       : aucune app sans owner." -ForegroundColor Green
}

# --- CSV 2 : Apps multi-owners ---
# Colonnes : DisplayName, AppId, TypeSP, Actif, NbOwners, Owners, CreeLe
# Colonnes disponibles non exportées : Owner.Id (pour Remove-MgServicePrincipalOwnerByRef)
# Ce CSV est le support d'une revue de gouvernance : valider avec les équipes
# quel owner est le référent et retirer les autres si redondants.
if ($MultiOwnerRows.Count -gt 0) {
    $MultiOwnerRows | Sort-Object NbOwners -Descending | Export-Csv `
        -Path "$ExportPath\AppsGouv_MultiOwner_$Timestamp.csv" `
        -Encoding UTF8 -NoTypeInformation
    Write-Host "-> Multi-owners     : $($MultiOwnerRows.Count) ligne(s) — AppsGouv_MultiOwner_$Timestamp.csv" -ForegroundColor Yellow
} else {
    Write-Host "-> Multi-owners     : aucune app avec plusieurs owners." -ForegroundColor Green
}

# --- CSV 3 : Apps sans activité récente ---
# Colonnes : DisplayName, AppId, TypeSP, Actif, CreeLe, JoursDepuisCreation, NbOwners, Owners, AppRegLocale
# Proxy inactivité basé sur CreatedDateTime — voir note DÉCOUVERTE TECHNIQUE étape 4.
# En production avec AuditLog.Read.All : remplacer CreatedDateTime par SignInActivity.LastSignInDateTime.
# Trié par JoursDepuisCreation DESC : les plus anciennes apps en premier.
# Ce CSV est le support d'une campagne de décommission : valider avec le métier
# avant toute suppression via Remove-MgServicePrincipal.
if ($InactiveRows.Count -gt 0) {
    $InactiveRows | Export-Csv `
        -Path "$ExportPath\AppsGouv_Inactives_$Timestamp.csv" `
        -Encoding UTF8 -NoTypeInformation
    Write-Host "-> Inactives        : $($InactiveRows.Count) ligne(s) — AppsGouv_Inactives_$Timestamp.csv" -ForegroundColor Yellow
} else {
    Write-Host "-> Inactives        : aucune app ancienne détectée." -ForegroundColor Green
}

# --- CSV 4 : Secrets et certificats à expiration imminente ---
# Colonnes : AppDisplayName, AppId, TypeCredential, NomCredential, Expiration,
#            JoursRestants, Alerte, Owners
# Colonnes disponibles non exportées : KeyId (pour rotation ciblée), Thumbprint (certs)
# Trié par JoursRestants ASC : les plus urgents en premier.
# Niveaux d'alerte :
#   EXPIRE   → déjà expiré — coupure de service possible ou déjà en cours
#   CRITIQUE → expire dans 7 jours ou moins — action immédiate requise
#   ATTENTION → expire dans 8 à 30 jours — planifier la rotation
# Livrable hebdomadaire pour les équipes IAM et dev — rotation des secrets via
#   Add-MgApplicationPassword (nouveau secret) puis Remove-MgApplicationPassword (ancien)
if ($SecretExpirationRows.Count -gt 0) {
    $SecretExpirationRows | Export-Csv `
        -Path "$ExportPath\AppsGouv_SecretsExpiration_$Timestamp.csv" `
        -Encoding UTF8 -NoTypeInformation
    Write-Host "-> Secrets/Certs    : $($SecretExpirationRows.Count) ligne(s) — AppsGouv_SecretsExpiration_$Timestamp.csv" -ForegroundColor $(
        if (($SecretExpirationRows | Where-Object { $_.Alerte -in @("EXPIRE","CRITIQUE") }).Count -gt 0) { "Red" } else { "Yellow" }
    )
} else {
    Write-Host "-> Secrets/Certs    : aucune expiration imminente." -ForegroundColor Green
}

Write-Host "-> Export terminé dans : $ExportPath`n" -ForegroundColor Green

# ========================================================================================
# NETTOYAGE MÉMOIRE
# ========================================================================================
Remove-Variable Scopes, MicrosoftTenantId, InactivityDays, ExpirationDays,
                InactivityThreshold, ExpirationThreshold, AllSPs, AllAppRegs,
                AllUsers, AppRegIndex, NonMicrosoftSPs, OwnerCache,
                NoOwnerRows, MultiOwnerRows, InactiveRows, SecretExpirationRows,
                SP, Owners, Owner, OwnerUser, OwnerNames, AppReg, Secret, Cert,
                CorrespondingSP, SPOwners, JoursRestants, JoursDepuisCreation,
                NbOwners, ExportPath, Timestamp `
                -ErrorAction SilentlyContinue

# ========================================================================================
# FERMETURE — RESET DE SESSION TOTAL
# ========================================================================================
Disconnect-MgGraph -ErrorAction SilentlyContinue
Write-Host "Session MgGraph fermée proprement." -ForegroundColor Magenta
