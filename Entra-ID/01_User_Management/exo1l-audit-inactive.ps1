# ========================================================================================
# Exercice 1k : Entra ID — Audit des comptes invités (Guest Users)
# ========================================================================================
# Concept : Les comptes invités (userType = "Guest") sont créés via B2B Invitation —
# ils donnent accès à des ressources du tenant à des utilisateurs externes
# (partenaires, prestataires, clients). Mal gouvernés, ils constituent un vecteur
# de fuite de données : accès jamais révoqués, invités jamais connectés, comptes
# dormants depuis des mois.
#
# Ce script identifie 4 populations à risque :
#   - Les invités jamais connectés         → invitation envoyée, jamais honorée
#   - Les invités inactifs (> 90 jours)    → accès toujours ouvert, inutilisé
#   - Les invités en attente d'invitation  → inviteAcceptedStatus = "Pending"
#   - La vue d'ensemble complète           → tous les invités, triés par dernière connexion
#
# Delta pédagogique vs exercice 1j (audit global) :
#   1j → inventaire global de TOUS les comptes (membres + invités, actifs + désactivés)
#   1k → focus exclusif sur les invités, avec 4 angles d'analyse sécurité distincts
#        et export dédié pour transmission au RSSI ou revue d'accès externe
#
# Ce que fait ce script :
#   1. Reset total de session
#   2. Récupère tous les comptes invités du tenant
#   3. Identifie les invités jamais connectés
#   4. Identifie les invités inactifs depuis > 90 jours
#   5. Identifie les invités en attente d'acceptation
#   6. Affiche la vue d'ensemble complète
#   7. Affiche un résumé chiffré
#   8. Exporte les résultats en CSV horodatés
#   9. Ferme proprement toutes les sessions
#
# Note : ce script est en lecture seule — aucune modification du tenant.
#
# Fichiers CSV générés :
#   Guests_Overview_YYYYMMDD_HHmmss.csv       → tous les invités
#   Guests_NeverConnected_YYYYMMDD_HHmmss.csv → jamais connectés
#   Guests_Inactive90_YYYYMMDD_HHmmss.csv     → inactifs > 90 jours
#   Guests_Pending_YYYYMMDD_HHmmss.csv        → en attente d'acceptation
#
# Prérequis licence : aucune licence P1/P2 requise pour la lecture des invités.
# La propriété SignInActivity (dernière connexion) nécessite en revanche
# que le compte connecté dispose du rôle Reports Reader, Security Reader,
# ou Global Admin — elle n'est pas accessible aux comptes standards.
#
# Module requis : Microsoft.Graph.Users
# Connexion     : Connect-MgGraph
# ========================================================================================

# --- OUVERTURE — RESET DE SESSION TOTAL ---
# User.Read.All    : lire tous les utilisateurs du tenant, y compris les invités
# AuditLog.Read.All : accéder à la propriété SignInActivity (dernière connexion interactive)
#
# REX : SignInActivity N'EST PAS retournée par défaut avec Get-MgUser -All.
# Elle doit être explicitement demandée via -Property "signInActivity".
# Sans AuditLog.Read.All, la propriété revient null pour tous les utilisateurs —
# même avec User.Read.All, même en Global Admin.
$Scopes = @(
    "User.Read.All",
    "AuditLog.Read.All"
)

Disconnect-MgGraph -ErrorAction SilentlyContinue
Connect-MgGraph -Scopes $Scopes -NoWelcome

# ========================================================================================
# ÉTAPE 1 : Définition des variables
# ========================================================================================
Write-Host "1. Définition des variables..." -ForegroundColor Cyan

# Seuil d'inactivité — ajustable selon la politique de l'organisation.
# 90 jours est la valeur courante dans les politiques de revue d'accès externe.
# Variantes courantes selon les référentiels sécurité :
#   30 jours  → politique stricte (partenaires à courte durée)
#   90 jours  → standard recommandé Microsoft / CIS Benchmark
#   180 jours → politique large (partenaires récurrents tolérés)
$InactivityThresholdDays = 90
$InactivityCutoff        = (Get-Date).AddDays(-$InactivityThresholdDays)

Write-Host "-> Seuil d'inactivité : $InactivityThresholdDays jours (avant le $($InactivityCutoff.ToString('dd/MM/yyyy')))" -ForegroundColor Green

# ========================================================================================
# ÉTAPE 2 : Récupération de tous les comptes invités
# ========================================================================================
Write-Host "`n2. Récupération des comptes invités..." -ForegroundColor Cyan

# Filtre OData côté API : userType eq 'Guest' — plus efficace que de récupérer
# tous les users et filtrer en PowerShell. Graph gère le filtre serveur-side.
#
# -Property : on demande explicitement les colonnes nécessaires.
# REX : sans -Property explicite, SignInActivity n'est JAMAIS retournée.
# La liste doit inclure chaque champ qu'on veut exploiter — Graph n'envoie
# que ce qu'on demande pour optimiser les transferts.
#
# Propriétés demandées :
#   Id, DisplayName, UserPrincipalName : identification standard
#   Mail                               : adresse email externe de l'invité
#   CreatedDateTime                    : date de création du compte B2B
#   AccountEnabled                     : compte actif ou désactivé
#   ExternalUserState                  : "Accepted" / "PendingAcceptance" / null
#   ExternalUserStateChangeDateTime    : date du dernier changement d'état
#   SignInActivity                     : LastSignInDateTime + LastNonInteractiveSignInDateTime
#
# Variante sans filtre côté API (moins efficace, utile si filtre OData pose problème) :
#   $AllGuests = Get-MgUser -All -Property "..." | Where-Object { $_.UserType -eq "Guest" }
$AllGuests = Get-MgUser -All `
    -Filter "userType eq 'Guest'" `
    -Property "Id, DisplayName, UserPrincipalName, Mail, CreatedDateTime,
               AccountEnabled, ExternalUserState, ExternalUserStateChangeDateTime,
               SignInActivity" `
    -ErrorAction Stop

Write-Host "-> $($AllGuests.Count) invité(s) trouvé(s) dans le tenant.`n" -ForegroundColor Green

# Sortie anticipée si aucun invité — évite les erreurs de traitement sur collection vide.
if ($AllGuests.Count -eq 0) {
    Write-Host "Aucun invité à analyser. Fin du script." -ForegroundColor Yellow
    Disconnect-MgGraph -ErrorAction SilentlyContinue
    return
}

# ========================================================================================
# ÉTAPE 3 : Construction de la vue d'ensemble normalisée
# ========================================================================================
Write-Host "3. Construction de la vue d'ensemble..." -ForegroundColor Cyan

# On construit une collection d'objets normalisés une seule fois,
# puis on la réutilise pour toutes les analyses suivantes.
# Evite de boucler plusieurs fois sur $AllGuests.
$GuestRows = foreach ($Guest in $AllGuests) {

    # Résolution de la dernière connexion interactive.
    # SignInActivity.LastSignInDateTime = dernière connexion avec interaction utilisateur
    # (saisie de credentials, MFA prompt, etc.)
    #
    # SignInActivity.LastNonInteractiveSignInDateTime = dernière connexion silencieuse
    # (refresh token, application accédant en arrière-plan, etc.)
    # Cette valeur est souvent plus récente — utile pour détecter les apps actives
    # même quand l'utilisateur ne se connecte plus manuellement.
    $LastSignIn = $Guest.SignInActivity.LastSignInDateTime

    # Calcul du nombre de jours depuis la dernière connexion.
    # $null → jamais connecté → on retourne $null pour le distinguer de "0 jours"
    $DaysSinceSignIn = if ($LastSignIn) {
        [int]((Get-Date) - [datetime]$LastSignIn).TotalDays
    } else { $null }

    [PSCustomObject]@{
        DisplayName                    = $Guest.DisplayName
        UPN                            = $Guest.UserPrincipalName
        Mail                           = $Guest.Mail
        AccountEnabled                 = $Guest.AccountEnabled
        # ExternalUserState : statut de l'invitation B2B
        #   "Accepted"          → l'invité a cliqué le lien et accepté
        #   "PendingAcceptance" → invitation envoyée, pas encore acceptée
        #   $null               → invité créé programmatiquement (sans invitation email)
        ExternalUserState              = $Guest.ExternalUserState
        ExternalUserStateChangeDate    = $Guest.ExternalUserStateChangeDateTime
        CreatedDateTime                = $Guest.CreatedDateTime
        LastSignInDateTime             = $LastSignIn
        LastNonInteractiveSignInDate   = $Guest.SignInActivity.LastNonInteractiveSignInDateTime
        DaysSinceLastSignIn            = $DaysSinceSignIn
        Id                             = $Guest.Id
    }
}

Write-Host "-> Vue d'ensemble construite ($($GuestRows.Count) lignes).`n" -ForegroundColor Green

# ========================================================================================
# ÉTAPE 4 : Invités jamais connectés
# ========================================================================================
Write-Host "4. Invités jamais connectés..." -ForegroundColor Cyan
Write-Host "`n=== INVITÉS JAMAIS CONNECTÉS ===" -ForegroundColor Red
Write-Host "Invitation envoyée mais aucune connexion enregistrée :`n" -ForegroundColor Gray

# DaysSinceLastSignIn -eq $null → SignInActivity.LastSignInDateTime est null
# = Graph n'a aucune trace de connexion interactive pour cet invité.
#
# Attention : cette valeur peut aussi être null si le tenant n'a pas activé
# la collecte des logs de connexion (rare en E5, mais possible si la licence
# est récente ou si le diagnostic setting n'est pas configuré).
$NeverConnected = $GuestRows | Where-Object { $_.DaysSinceLastSignIn -eq $null }

if ($NeverConnected.Count -gt 0) {
    $NeverConnected |
        Sort-Object CreatedDateTime |
        Select-Object DisplayName, UPN, Mail, ExternalUserState, CreatedDateTime |
        Format-Table -AutoSize
} else {
    Write-Host "-> Aucun invité sans connexion.`n" -ForegroundColor Green
}

# ========================================================================================
# ÉTAPE 5 : Invités inactifs > seuil
# ========================================================================================
Write-Host "5. Invités inactifs depuis > $InactivityThresholdDays jours..." -ForegroundColor Cyan
Write-Host "`n=== INVITÉS INACTIFS (> $InactivityThresholdDays JOURS) ===" -ForegroundColor Yellow
Write-Host "Accès toujours actif mais aucune connexion récente :`n" -ForegroundColor Gray

# Double condition :
#   $_.DaysSinceLastSignIn -ne $null → on exclut les "jamais connectés" (déjà traités étape 4)
#   [datetime]$_.LastSignInDateTime -lt $InactivityCutoff → dernière connexion avant le seuil
#
# Variante avec DaysSinceLastSignIn directement :
#   $_.DaysSinceLastSignIn -gt $InactivityThresholdDays
# Les deux approches donnent le même résultat — la variante datetime est plus robuste
# en cas de changement d'heure système entre la collecte et le filtre.
$Inactive = $GuestRows | Where-Object {
    $_.DaysSinceLastSignIn -ne $null -and
    [datetime]$_.LastSignInDateTime -lt $InactivityCutoff
}

if ($Inactive.Count -gt 0) {
    $Inactive |
        Sort-Object DaysSinceLastSignIn -Descending |
        Select-Object DisplayName, UPN, Mail, DaysSinceLastSignIn, LastSignInDateTime, AccountEnabled |
        Format-Table -AutoSize
} else {
    Write-Host "-> Aucun invité inactif au-delà du seuil.`n" -ForegroundColor Green
}

# ========================================================================================
# ÉTAPE 6 : Invités en attente d'acceptation
# ========================================================================================
Write-Host "6. Invités en attente d'acceptation..." -ForegroundColor Cyan
Write-Host "`n=== INVITÉS EN ATTENTE (PENDING) ===" -ForegroundColor Yellow
Write-Host "Invitation envoyée, lien pas encore cliqué :`n" -ForegroundColor Gray

# ExternalUserState = "PendingAcceptance" → le compte B2B existe dans Entra,
# l'email d'invitation a été envoyé, mais l'invité n'a pas encore cliqué le lien
# de validation. Un compte en Pending ne peut pas accéder aux ressources.
#
# Distinction importante :
#   "PendingAcceptance" → invitation standard via email, pas encore acceptée
#   $null               → compte créé via API sans flux d'invitation (déjà "actif")
#   "Accepted"          → invitation acceptée, accès possible
$Pending = $GuestRows | Where-Object { $_.ExternalUserState -eq "PendingAcceptance" }

if ($Pending.Count -gt 0) {
    $Pending |
        Sort-Object CreatedDateTime |
        Select-Object DisplayName, UPN, Mail, CreatedDateTime, ExternalUserStateChangeDate |
        Format-Table -AutoSize
} else {
    Write-Host "-> Aucun invité en attente.`n" -ForegroundColor Green
}

# ========================================================================================
# ÉTAPE 7 : Vue d'ensemble — tous les invités
# ========================================================================================
Write-Host "7. Vue d'ensemble complète..." -ForegroundColor Cyan
Write-Host "`n=== VUE D'ENSEMBLE — TOUS LES INVITÉS ===" -ForegroundColor Cyan
Write-Host "Triés par dernière connexion (plus ancienne en premier) :`n" -ForegroundColor Gray

# On trie les jamais-connectés ($null) en dernier via un champ de tri calculé.
# Sort-Object ne trie pas $null de manière prévisible selon les versions PowerShell —
# on force un entier très élevé pour les "jamais connectés" afin qu'ils remontent
# en bas de tableau (cas à traiter en dernier lors d'une revue, ou en premier selon préférence).
#
# Variante tri jamais-connectés EN PREMIER (risque le plus élevé en tête) :
#   $SortKey = if ($null -eq $_.DaysSinceLastSignIn) { [int]::MaxValue } else { $_.DaysSinceLastSignIn }
#   $GuestRows | Sort-Object { ... } -Descending
$GuestRows |
    Sort-Object {
        if ($null -eq $_.DaysSinceLastSignIn) { -1 } else { $_.DaysSinceLastSignIn }
    } -Descending |
    Select-Object DisplayName, UPN, Mail, AccountEnabled,
                  ExternalUserState, DaysSinceLastSignIn, LastSignInDateTime |
    Format-Table -AutoSize

# ========================================================================================
# ÉTAPE 8 : Résumé chiffré
# ========================================================================================
Write-Host "`n=== RÉSUMÉ ===" -ForegroundColor Magenta

# Calcul du nombre d'invités avec connexion récente (actifs au sens large)
$RecentlyActive = ($GuestRows | Where-Object {
    $_.DaysSinceLastSignIn -ne $null -and $_.DaysSinceLastSignIn -le $InactivityThresholdDays
}).Count

[PSCustomObject]@{
    TotalInvités              = $AllGuests.Count
    JamaisConnectés           = $NeverConnected.Count
    "Inactifs_>_$($InactivityThresholdDays)j" = $Inactive.Count
    EnAttente                 = $Pending.Count
    ActifsRécemment           = $RecentlyActive
    SeuilInactivité           = "$InactivityThresholdDays jours"
    Scope                     = "User.Read.All + AuditLog.Read.All (lecture seule)"
} | Format-List

Write-Host "=== FIN DE L'AUDIT INVITÉS ===" -ForegroundColor Green

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

# --- CSV 1 : Vue d'ensemble de tous les invités ---
# Colonnes exportées : DisplayName, UPN, Mail, AccountEnabled, ExternalUserState,
#                      ExternalUserStateChangeDate, CreatedDateTime, LastSignInDateTime,
#                      LastNonInteractiveSignInDate, DaysSinceLastSignIn, Id
# Colonnes disponibles non exportées :
#   $Guest.CompanyName        : société de l'invité si renseignée dans le profil B2B
#   $Guest.JobTitle           : titre du poste de l'invité
#   $Guest.Department         : département si renseigné
#   $Guest.Country            : pays si renseigné
#   SignInActivity.LastNonInteractiveSignInDateTime : déjà dans $GuestRows si besoin
#
# Ce CSV est le livrable principal pour une revue d'accès externe —
# couvre tous les invités avec leur statut et activité.
$GuestRows |
    Sort-Object DaysSinceLastSignIn -Descending |
    Export-Csv -Path "$ExportPath\Guests_Overview_$Timestamp.csv" `
               -Encoding UTF8 -NoTypeInformation
Write-Host "-> Vue d'ensemble : $($GuestRows.Count) ligne(s) — Guests_Overview_$Timestamp.csv" -ForegroundColor Green

# --- CSV 2 : Jamais connectés ---
# Focus sur les invitations sans suite — candidats à la suppression ou re-invitation.
if ($NeverConnected.Count -gt 0) {
    $NeverConnected |
        Sort-Object CreatedDateTime |
        Export-Csv -Path "$ExportPath\Guests_NeverConnected_$Timestamp.csv" `
                   -Encoding UTF8 -NoTypeInformation
    Write-Host "-> Jamais connectés : $($NeverConnected.Count) ligne(s) — Guests_NeverConnected_$Timestamp.csv" -ForegroundColor Green
} else {
    Write-Host "-> Jamais connectés : aucune donnée à exporter." -ForegroundColor Yellow
}

# --- CSV 3 : Inactifs > seuil ---
# Candidats à la révocation ou à l'Access Review — accès dormant.
if ($Inactive.Count -gt 0) {
    $Inactive |
        Sort-Object DaysSinceLastSignIn -Descending |
        Export-Csv -Path "$ExportPath\Guests_Inactive${InactivityThresholdDays}_$Timestamp.csv" `
                   -Encoding UTF8 -NoTypeInformation
    Write-Host "-> Inactifs > $InactivityThresholdDays j : $($Inactive.Count) ligne(s) — Guests_Inactive${InactivityThresholdDays}_$Timestamp.csv" -ForegroundColor Green
} else {
    Write-Host "-> Inactifs > $InactivityThresholdDays j : aucune donnée à exporter." -ForegroundColor Yellow
}

# --- CSV 4 : En attente d'acceptation ---
# Invitations non honorées — à re-envoyer ou à supprimer si expirées.
# Note : les invitations B2B expirent après 30 jours sans acceptation par défaut.
if ($Pending.Count -gt 0) {
    $Pending |
        Sort-Object CreatedDateTime |
        Export-Csv -Path "$ExportPath\Guests_Pending_$Timestamp.csv" `
                   -Encoding UTF8 -NoTypeInformation
    Write-Host "-> En attente : $($Pending.Count) ligne(s) — Guests_Pending_$Timestamp.csv" -ForegroundColor Green
} else {
    Write-Host "-> En attente : aucune donnée à exporter." -ForegroundColor Yellow
}

Write-Host "-> Export terminé dans : $ExportPath`n" -ForegroundColor Green

# ========================================================================================
# NETTOYAGE MÉMOIRE
# ========================================================================================
Remove-Variable Scopes, InactivityThresholdDays, InactivityCutoff,
                AllGuests, GuestRows, Guest, LastSignIn, DaysSinceSignIn,
                NeverConnected, Inactive, Pending, RecentlyActive,
                ExportPath, Timestamp `
                -ErrorAction SilentlyContinue

# ========================================================================================
# FERMETURE — RESET DE SESSION TOTAL
# ========================================================================================
Disconnect-MgGraph -ErrorAction SilentlyContinue
Write-Host "Session MgGraph fermée proprement." -ForegroundColor Magenta
