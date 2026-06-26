# ========================================================================================
# Exercice 9a : Entra ID — Audit transverse — Audit MFA
# ========================================================================================
# Concept : Le MFA est la première ligne de défense contre la compromission de compte.
# Un utilisateur sans MFA enregistré = un mot de passe suffit pour prendre le compte.
# Sur un tenant sans MFA enforced par CA, l'exposition est totale.
#
# Ce script produit trois angles d'analyse :
#   A) Posture globale MFA : taux de couverture, méthodes enregistrées par type
#   B) Utilisateurs sans MFA : comptes exposés, avec priorisation par type de compte
#   C) Détail des méthodes par utilisateur : qui utilise quoi (Authenticator, SMS, FIDO2...)
#
# Ce que fait ce script :
#   1. Reset total de session
#   2. Récupération de tous les utilisateurs
#   3. Récupération des méthodes d'authentification par utilisateur
#   4. Classement : avec MFA / sans MFA / méthodes par type
#   5. Résumé chiffré + taux de couverture
#   6. Export CSV horodatés (3 fichiers)
#   7. Fermeture propre
#
# Note : ce script est en lecture seule — aucune modification du tenant.
#
# DÉCOUVERTE TECHNIQUE : Get-MgUserAuthenticationMethod retourne toutes les méthodes
# enregistrées pour un utilisateur, y compris le mot de passe.
# La présence de #microsoft.graph.passwordAuthenticationMethod dans la liste
# ne signifie PAS que le MFA est activé — c'est la méthode par défaut de tout compte.
# Un utilisateur "sans MFA" = aucune méthode autre que passwordAuthenticationMethod.
# Méthodes MFA valides :
#   #microsoft.graph.microsoftAuthenticatorAuthenticationMethod  → Microsoft Authenticator
#   #microsoft.graph.phoneAuthenticationMethod                   → SMS / appel
#   #microsoft.graph.fido2AuthenticationMethod                   → clé FIDO2 / passkey
#   #microsoft.graph.softwareOathAuthenticationMethod            → token OATH (Google Auth...)
#   #microsoft.graph.windowsHelloForBusinessAuthenticationMethod → Windows Hello
#   #microsoft.graph.emailAuthenticationMethod                   → email SSPR (pas MFA à proprement parler)
#   #microsoft.graph.temporaryAccessPassAuthenticationMethod     → TAP (accès temporaire)
#
# Fichiers CSV générés :
#   MFA_Detail_YYYYMMDD_HHmmss.csv      (détail méthodes par utilisateur)
#   MFA_SansMFA_YYYYMMDD_HHmmss.csv     (utilisateurs sans aucune méthode MFA)
#   MFA_Posture_YYYYMMDD_HHmmss.csv     (synthèse par méthode)
#
# Delta pédagogique vs exo 9d (Tenant Security Snapshot) :
#   9d → une passe multi-domaines, résultats agrégés — consomme les outputs de 9a
#   9a → focus MFA exclusif, granularité maximale par méthode et par utilisateur
#
# Module requis : Microsoft.Graph.Users, Microsoft.Graph.Identity.SignIns
# Connexion     : Connect-MgGraph
# ========================================================================================

# --- OUVERTURE — RESET DE SESSION TOTAL ---
# UserAuthenticationMethod.Read.All : lire les méthodes MFA de tous les utilisateurs
# User.Read.All                     : lire les propriétés utilisateurs (UPN, type, dept...)
#
# DÉCOUVERTE TECHNIQUE : UserAuthenticationMethod.Read.All est un scope sensible.
# Il expose les méthodes d'auth de tous les utilisateurs (numéros de téléphone,
# devices FIDO2, tokens OATH...). Nécessite Authentication Administrator ou Global Admin.
# Un compte standard avec consentement délégué ne suffit pas — 403 systématique.
# Sur tenant de dev E5, le compte GeptorAdmin dispose de ce droit sans config supplémentaire.
#
# Pas de -ContextScope Process requis : lecture seule, aucun scope d'écriture.
$Scopes = @(
    "UserAuthenticationMethod.Read.All",
    "User.Read.All"
)

Disconnect-MgGraph -ErrorAction SilentlyContinue
Connect-MgGraph -Scopes $Scopes -NoWelcome

# ========================================================================================
# ÉTAPE 1 : Récupération de tous les utilisateurs
# ========================================================================================
Write-Host "1. Récupération des utilisateurs..." -ForegroundColor Cyan

# On exclut les comptes de service et invités du calcul du taux MFA
# via les colonnes UserType et AccountEnabled — la décision de filtrer reste à l'analyste.
# Le script récupère tout et laisse le filtrage au CSV + commentaires.
$AllUsers = Get-MgUser -All `
    -Property "Id,DisplayName,UserPrincipalName,UserType,AccountEnabled,Department,JobTitle"

Write-Host "-> $($AllUsers.Count) utilisateur(s) récupéré(s).`n" -ForegroundColor Green

# ========================================================================================
# ÉTAPE 2 : Récupération et analyse des méthodes d'authentification
# ========================================================================================
Write-Host "2. Analyse des méthodes d'authentification..." -ForegroundColor Cyan
Write-Host "   (1 appel Graph par utilisateur — patience sur grands tenants)`n" -ForegroundColor Gray

# Compteurs par méthode pour la posture globale
$CountAuthenticator = 0
$CountPhone         = 0
$CountFIDO2         = 0
$CountSoftwareOATH  = 0
$CountWindowsHello  = 0
$CountEmail         = 0
$CountTAP           = 0
$CountSansMFA       = 0
$CountAvecMFA       = 0

$DetailRows  = @()
$NoMFARows   = @()

foreach ($User in $AllUsers) {

    $Methods = Get-MgUserAuthenticationMethod -UserId $User.Id -ErrorAction SilentlyContinue

    # Filtrage des méthodes MFA valides — on exclut passwordAuthenticationMethod
    # qui est présente sur tous les comptes et ne constitue pas un second facteur.
    $MFAMethods = $Methods | Where-Object {
        $_.AdditionalProperties["@odata.type"] -ne "#microsoft.graph.passwordAuthenticationMethod"
    }

    # Détection par type — AdditionalProperties["@odata.type"] contient le type Graph
    $HasAuthenticator  = $MFAMethods | Where-Object { $_.AdditionalProperties["@odata.type"] -eq "#microsoft.graph.microsoftAuthenticatorAuthenticationMethod" }
    $HasPhone          = $MFAMethods | Where-Object { $_.AdditionalProperties["@odata.type"] -eq "#microsoft.graph.phoneAuthenticationMethod" }
    $HasFIDO2          = $MFAMethods | Where-Object { $_.AdditionalProperties["@odata.type"] -eq "#microsoft.graph.fido2AuthenticationMethod" }
    $HasSoftwareOATH   = $MFAMethods | Where-Object { $_.AdditionalProperties["@odata.type"] -eq "#microsoft.graph.softwareOathAuthenticationMethod" }
    $HasWindowsHello   = $MFAMethods | Where-Object { $_.AdditionalProperties["@odata.type"] -eq "#microsoft.graph.windowsHelloForBusinessAuthenticationMethod" }
    $HasEmail          = $MFAMethods | Where-Object { $_.AdditionalProperties["@odata.type"] -eq "#microsoft.graph.emailAuthenticationMethod" }
    $HasTAP            = $MFAMethods | Where-Object { $_.AdditionalProperties["@odata.type"] -eq "#microsoft.graph.temporaryAccessPassAuthenticationMethod" }

    # Incrémentation des compteurs globaux
    if ($HasAuthenticator) { $CountAuthenticator++ }
    if ($HasPhone)         { $CountPhone++ }
    if ($HasFIDO2)         { $CountFIDO2++ }
    if ($HasSoftwareOATH)  { $CountSoftwareOATH++ }
    if ($HasWindowsHello)  { $CountWindowsHello++ }
    if ($HasEmail)         { $CountEmail++ }
    if ($HasTAP)           { $CountTAP++ }

    $AVecMFA = $MFAMethods.Count -gt 0

    if ($AVecMFA) { $CountAvecMFA++ } else { $CountSansMFA++ }

    # Niveau de risque pour les comptes sans MFA :
    #   CRITIQUE → compte actif de type Member (employé) sans aucune méthode MFA
    #   MOYEN    → compte actif de type Guest sans MFA (exposition externe)
    #   INFO     → compte désactivé sans MFA (risque moindre mais à documenter)
    $NiveauRisque = ""
    if (-not $AVecMFA) {
        $NiveauRisque = if (-not $User.AccountEnabled) { "INFO" }
                        elseif ($User.UserType -eq "Guest") { "MOYEN" }
                        else { "CRITIQUE" }
    }

    # Ligne détail — une ligne par utilisateur
    $DetailRows += [PSCustomObject]@{
        DisplayName       = $User.DisplayName
        UPN               = $User.UserPrincipalName
        TypeCompte        = $User.UserType
        CompteActif       = $User.AccountEnabled
        Departement       = $User.Department
        AvecMFA           = $AVecMFA
        NbMethodesMFA     = $MFAMethods.Count
        NiveauRisque      = $NiveauRisque
        Authenticator     = [bool]$HasAuthenticator
        Phone_SMS         = [bool]$HasPhone
        FIDO2             = [bool]$HasFIDO2
        SoftwareOATH      = [bool]$HasSoftwareOATH
        WindowsHello      = [bool]$HasWindowsHello
        Email             = [bool]$HasEmail
        TAP               = [bool]$HasTAP
        # Colonnes disponibles non exportées :
        #   $User.Id          : ObjectId Entra
        #   $User.JobTitle    : intitulé de poste
        #   $Methods.Count    : nombre total de méthodes (password inclus)
        #   Pour le numéro de téléphone enregistré (SMS) :
        #     ($HasPhone | Select-Object -First 1).AdditionalProperties["phoneNumber"]
        #   Pour le modèle de l'appareil FIDO2 :
        #     ($HasFIDO2 | Select-Object -First 1).AdditionalProperties["model"]
    }

    # Ligne sans MFA — sous-ensemble pour CSV dédié
    if (-not $AVecMFA) {
        $NoMFARows += [PSCustomObject]@{
            DisplayName  = $User.DisplayName
            UPN          = $User.UserPrincipalName
            TypeCompte   = $User.UserType
            CompteActif  = $User.AccountEnabled
            Departement  = $User.Department
            NiveauRisque = $NiveauRisque
            # Colonnes disponibles non exportées :
            #   $User.Id       : ObjectId pour cibler un Reset-MgUserAuthenticationMethod
            #   $User.JobTitle : utile pour prioriser (C-level sans MFA = priorité absolue)
            #   $User.Manager  : nécessite Get-MgUserManager — scope supplémentaire requis
        }
    }
}

Write-Host "-> Analyse terminée.`n" -ForegroundColor Green

# ========================================================================================
# ÉTAPE 3 : Construction de la posture globale par méthode
# ========================================================================================
Write-Host "3. Calcul de la posture MFA globale..." -ForegroundColor Cyan

$TauxCouverture = if ($AllUsers.Count -gt 0) {
    [math]::Round(($CountAvecMFA / $AllUsers.Count) * 100, 1)
} else { 0 }

# Ligne de posture par méthode — pour CSV 3
$PostureRows = @(
    [PSCustomObject]@{ Methode = "Microsoft Authenticator" ; NbUtilisateurs = $CountAuthenticator ; PourcentageTenant = [math]::Round(($CountAuthenticator / $AllUsers.Count) * 100, 1) }
    [PSCustomObject]@{ Methode = "Phone / SMS"             ; NbUtilisateurs = $CountPhone         ; PourcentageTenant = [math]::Round(($CountPhone         / $AllUsers.Count) * 100, 1) }
    [PSCustomObject]@{ Methode = "FIDO2 / Passkey"         ; NbUtilisateurs = $CountFIDO2         ; PourcentageTenant = [math]::Round(($CountFIDO2         / $AllUsers.Count) * 100, 1) }
    [PSCustomObject]@{ Methode = "Software OATH"           ; NbUtilisateurs = $CountSoftwareOATH  ; PourcentageTenant = [math]::Round(($CountSoftwareOATH  / $AllUsers.Count) * 100, 1) }
    [PSCustomObject]@{ Methode = "Windows Hello"           ; NbUtilisateurs = $CountWindowsHello  ; PourcentageTenant = [math]::Round(($CountWindowsHello  / $AllUsers.Count) * 100, 1) }
    [PSCustomObject]@{ Methode = "Email (SSPR)"            ; NbUtilisateurs = $CountEmail         ; PourcentageTenant = [math]::Round(($CountEmail         / $AllUsers.Count) * 100, 1) }
    [PSCustomObject]@{ Methode = "Temporary Access Pass"   ; NbUtilisateurs = $CountTAP           ; PourcentageTenant = [math]::Round(($CountTAP           / $AllUsers.Count) * 100, 1) }
)

$PostureRows | Format-Table -AutoSize

# ========================================================================================
# ÉTAPE 4 : Résumé chiffré
# ========================================================================================
$NbCritique = ($NoMFARows | Where-Object { $_.NiveauRisque -eq "CRITIQUE" }).Count
$NbMoyen    = ($NoMFARows | Where-Object { $_.NiveauRisque -eq "MOYEN" }).Count
$NbInfo     = ($NoMFARows | Where-Object { $_.NiveauRisque -eq "INFO" }).Count

Write-Host "`n=== RÉSUMÉ ===" -ForegroundColor Magenta
[PSCustomObject]@{
    TotalUtilisateurs    = $AllUsers.Count
    AvecMFA              = $CountAvecMFA
    SansMFA              = $CountSansMFA
    TauxCouvertureMFA    = "$TauxCouverture %"
    "Sans MFA CRITIQUE"  = $NbCritique
    "Sans MFA MOYEN"     = $NbMoyen
    "Sans MFA INFO"      = $NbInfo
    MethodePrincipale    = ($PostureRows | Sort-Object NbUtilisateurs -Descending | Select-Object -First 1).Methode
    Scope                = "UserAuthenticationMethod.Read.All (lecture seule)"
    PointAttentionAudit  = "Filtrer NiveauRisque = CRITIQUE pour prioriser les actions d'enrôlement MFA"
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

# --- CSV 1 : Détail méthodes par utilisateur ---
# Colonnes : DisplayName, UPN, TypeCompte, CompteActif, Departement, AvecMFA,
#            NbMethodesMFA, NiveauRisque, Authenticator, Phone_SMS, FIDO2,
#            SoftwareOATH, WindowsHello, Email, TAP
# Colonnes disponibles non exportées : Id, JobTitle, numéro téléphone, modèle FIDO2
# Ce CSV est le livrable principal : une ligne par utilisateur, toutes méthodes en colonnes.
# Dans Excel : filtrer AvecMFA = FALSE pour isoler les exposés, trier NiveauRisque pour prioriser.
# Utile pour le RSSI : vue exhaustive de la posture MFA tenant en une passe.
$DetailRows | Sort-Object NiveauRisque, TypeCompte | Export-Csv `
    -Path "$ExportPath\MFA_Detail_$Timestamp.csv" `
    -Encoding UTF8 -NoTypeInformation
Write-Host "-> Détail      : $($DetailRows.Count) ligne(s) — MFA_Detail_$Timestamp.csv" -ForegroundColor Green

# --- CSV 2 : Utilisateurs sans MFA ---
# Colonnes : DisplayName, UPN, TypeCompte, CompteActif, Departement, NiveauRisque
# Colonnes disponibles non exportées : Id (pour cibler l'enrôlement), JobTitle, Manager
# Sous-ensemble du CSV 1 — uniquement les utilisateurs sans aucune méthode MFA enregistrée.
# Trié par NiveauRisque : CRITIQUE en premier (Member actif), puis MOYEN (Guest actif),
# puis INFO (comptes désactivés). Livrable opérationnel pour campagne d'enrôlement MFA.
if ($NoMFARows.Count -gt 0) {
    $NoMFARows | Sort-Object NiveauRisque | Export-Csv `
        -Path "$ExportPath\MFA_SansMFA_$Timestamp.csv" `
        -Encoding UTF8 -NoTypeInformation
    Write-Host "-> Sans MFA    : $($NoMFARows.Count) ligne(s) — MFA_SansMFA_$Timestamp.csv" -ForegroundColor $(
        if ($NbCritique -gt 0) { "Red" } else { "Yellow" }
    )
} else {
    Write-Host "-> Sans MFA    : aucun utilisateur sans MFA — posture saine." -ForegroundColor Green
}

# --- CSV 3 : Posture globale par méthode ---
# Colonnes : Methode, NbUtilisateurs, PourcentageTenant
# Vue agrégée — une ligne par type de méthode MFA.
# Utile pour identifier la méthode dominante et détecter les méthodes faibles
# (SMS/Phone = moins sécurisé que Authenticator ou FIDO2 — susceptible au SIM swapping).
# Ce CSV est consommé par le Tenant Security Snapshot (exo 9d) pour le Summary.txt.
$PostureRows | Export-Csv `
    -Path "$ExportPath\MFA_Posture_$Timestamp.csv" `
    -Encoding UTF8 -NoTypeInformation
Write-Host "-> Posture     : $($PostureRows.Count) ligne(s) — MFA_Posture_$Timestamp.csv" -ForegroundColor Green

Write-Host "-> Export terminé dans : $ExportPath`n" -ForegroundColor Green

# ========================================================================================
# NETTOYAGE MÉMOIRE
# ========================================================================================
Remove-Variable Scopes, AllUsers, Methods, MFAMethods, HasAuthenticator, HasPhone,
                HasFIDO2, HasSoftwareOATH, HasWindowsHello, HasEmail, HasTAP,
                CountAuthenticator, CountPhone, CountFIDO2, CountSoftwareOATH,
                CountWindowsHello, CountEmail, CountTAP, CountSansMFA, CountAvecMFA,
                DetailRows, NoMFARows, PostureRows, AVecMFA, NiveauRisque,
                TauxCouverture, NbCritique, NbMoyen, NbInfo, User,
                ExportPath, Timestamp `
                -ErrorAction SilentlyContinue

# ========================================================================================
# FERMETURE — RESET DE SESSION TOTAL
# ========================================================================================
Disconnect-MgGraph -ErrorAction SilentlyContinue
Write-Host "Session MgGraph fermée proprement." -ForegroundColor Magenta
