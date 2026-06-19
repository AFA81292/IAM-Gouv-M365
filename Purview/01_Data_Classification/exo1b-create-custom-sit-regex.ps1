# ========================================================================================
# Exercice 1b : Data Classification — Création d'un SIT personnalisé par regex
# ========================================================================================
# Concept : Quand aucun SIT built-in ne couvre un besoin métier spécifique, on crée
# un SIT custom basé sur un pattern regex. Ici : numéro de badge interne fictif
# de la société Cerberus Corp, format GCORP-XXXXX (5 chiffres).
#
# Architecture d'un SIT custom — comprendre avant de lire le XML :
#
#   Purview ne permet pas de créer un SIT custom via une cmdlet simple avec des
#   paramètres. Il exige un fichier XML complet appelé "Rule Package" qui décrit
#   intégralement le SIT : son identifiant unique, ses patterns de détection,
#   ses niveaux de confiance, ses mots-clés corroborants, et ses métadonnées.
#
#   Ce XML est ensuite uploadé dans Purview via une cmdlet dédiée.
#   C'est verbeux, mais c'est le seul chemin pour du SIT custom en PowerShell.
#
# Logique de détection à deux niveaux de confiance :
#
#   Purview ne fait pas que "trouve ou trouve pas". Il évalue une confiance (0-100).
#   On définit deux scénarios :
#
#   → Confiance HAUTE (85) : le regex matche ET un mot-clé corroborant est présent
#     dans les 300 caractères autour du match (ex: "badge", "matricule").
#     Exemple : "Le badge de Shepard est GCORP-12345" → 85
#
#   → Confiance MOYENNE (75) : le regex matche seul, sans mot-clé autour.
#     Exemple : un fichier contient "GCORP-12345" sans contexte → 75
#
#   Dans une DLP policy, on choisira ensuite à partir de quel seuil déclencher
#   une action. C'est là que ces niveaux deviennent utiles opérationnellement.
#
# Cas d'usage réel :
#   - Détecter des identifiants internes propriétaires (matricules RH, numéros contrat)
#     qu'aucun SIT Microsoft ne couvre nativement
#   - Base indispensable avant de créer une DLP policy sur des données maison
#
# Module requis : ExchangeOnlineManagement
# Connexion : Connect-IPPSSession
# ========================================================================================

# --- OUVERTURE ---
# Fermeture de toutes les sessions PowerShell actives
# Get-PSSession | Remove-PSSession est préféré à Disconnect-ExchangeOnline -Confirm:$false
# car les versions récentes du module ExchangeOnlineManagement ignorent -Confirm:$false
# et affichent une confirmation interactive qui bloque le script.
# Get-PSSession récupère toutes les sessions PS actives (IPPS, ExchangeOnline, autres)
# et Remove-PSSession les ferme toutes proprement sans prompt.
Get-PSSession | Remove-PSSession
Connect-IPPSSession -UserPrincipalName GeptorAdmin@0n4mg.onmicrosoft.com -ShowBanner:$false

# --- ÉTAPE 1 : Génération des identifiants uniques ---
Write-Host "1. Génération des identifiants uniques..." -ForegroundColor Cyan

# Purview identifie chaque Rule Package et chaque SIT par un GUID unique.
# On les génère dynamiquement pour éviter les collisions si on recrée le script.
#
# IMPORTANT sur le format :
#   [guid]::NewGuid().ToString()      → "{xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx}" AVEC accolades
#   [guid]::NewGuid().ToString("D")   → "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"  SANS accolades
#
# Purview valide les GUIDs dans le XML contre un schéma strict (GuidType) qui
# INTERDIT les accolades. Sans le format "D", l'upload échoue avec une erreur
# de validation de schéma. D'où le ToString("D") explicite.
$RulePackageId = [guid]::NewGuid().ToString("D")
$EntityId      = [guid]::NewGuid().ToString("D")

$SITName        = "Cerberus Corp - Numéro de Badge Interne"
$SITDescription = "Détecte les numéros de badge internes Cerberus Corp au format GCORP-XXXXX"

Write-Host "-> RulePackageId : $RulePackageId" -ForegroundColor Green
Write-Host "-> EntityId      : $EntityId`n" -ForegroundColor Green

# --- ÉTAPE 2 : Construction du Rule Package XML ---
Write-Host "2. Construction du Rule Package XML..." -ForegroundColor Cyan

# Le Rule Package XML est structuré en deux grandes sections :
#
# SECTION 1 — RulePack : les métadonnées du package
#   Qui a créé ce package, quelle version, quel nom affiché dans Purview.
#   Le RulePack id et le Publisher id sont tous les deux le même GUID ($RulePackageId).
#   C'est une convention Microsoft — le publisher "s'identifie" avec le même ID que son package.
#
# SECTION 2 — Rules : le contenu technique du SIT
#   Entity      : le SIT lui-même, référencé par $EntityId
#   Pattern     : une combinaison de détection (regex + optionnellement keywords)
#   Regex       : le pattern de détection — ici GCORP- suivi de exactement 5 chiffres
#   Keyword     : les mots corroborants — leur présence près du match augmente la confiance
#   LocalizedStrings : le nom et la description affichés dans le portail Purview
#
# patternsProximity="300" : Purview cherche les keywords corroborants dans un rayon
#   de 300 caractères autour du match regex. Au-delà, le keyword est ignoré.

$RulePackageXml = @"
<?xml version="1.0" encoding="utf-8"?>
<RulePackage xmlns="http://schemas.microsoft.com/office/2011/mce">

  <!-- SECTION 1 : Métadonnées du package -->
  <RulePack id="$RulePackageId">
    <Version major="1" minor="0" build="0" revision="0"/>
    <!-- Le Publisher s'identifie avec le même GUID que le package — convention Microsoft -->
    <Publisher id="$RulePackageId"/>
    <Details defaultLangCode="fr">
      <LocalizedDetails langcode="fr">
        <PublisherName>Cerberus Corp IAM Lab</PublisherName>
        <Name>Cerberus Corp Rule Package</Name>
        <Description>Package de règles pour les identifiants internes Cerberus Corp</Description>
      </LocalizedDetails>
    </Details>
  </RulePack>

  <!-- SECTION 2 : Règles de détection -->
  <Rules>

    <!-- Entity = le SIT. Son id ($EntityId) est la clé de liaison avec LocalizedStrings -->
    <Entity id="$EntityId" patternsProximity="300" recommendedConfidence="75">

      <!-- Pattern HIGH (85) : regex + keyword corroborant dans les 300 caractères -->
      <Pattern confidenceLevel="85">
        <IdMatch idRef="Regex_CerberusBadge"/>
        <Match idRef="Keywords_CerberusBadge"/>
      </Pattern>

      <!-- Pattern MEDIUM (75) : regex seul, sans corroboration -->
      <Pattern confidenceLevel="75">
        <IdMatch idRef="Regex_CerberusBadge"/>
      </Pattern>

    </Entity>

    <!-- Le regex : GCORP- littéral, suivi de exactement 5 chiffres -->
    <!-- {5} = exactement 5 occurrences de [0-9] — ni 4, ni 6 -->
    <Regex id="Regex_CerberusBadge">GCORP-[0-9]{5}</Regex>

    <!-- Keywords corroborants — matchStyle="word" = correspondance sur mot entier -->
    <!-- "badge" matche, "badgeage" ne matche pas -->
    <Keyword id="Keywords_CerberusBadge">
      <Group matchStyle="word">
        <Term>badge</Term>
        <Term>matricule</Term>
        <Term>identifiant</Term>
        <Term>cerberus</Term>
      </Group>
    </Keyword>

    <!-- Nom et description affichés dans le portail Purview -->
    <!-- idRef doit pointer vers l'EntityId — c'est la liaison entre la règle et son affichage -->
    <LocalizedStrings>
      <Resource idRef="$EntityId">
        <Name default="true" langcode="fr">$SITName</Name>
        <Description default="true" langcode="fr">$SITDescription</Description>
      </Resource>
    </LocalizedStrings>

  </Rules>
</RulePackage>
"@

Write-Host "-> XML construit." -ForegroundColor Green

# --- ÉTAPE 3 : Upload du Rule Package dans Purview ---
Write-Host "`n3. Upload du Rule Package dans Purview..." -ForegroundColor Cyan

try {
    # Purview exige de l'UTF-8 SANS BOM (Byte Order Mark).
    # [System.Text.Encoding]::UTF8 inclut un BOM par défaut → Purview rejette avec 0x00 errors.
    # UTF8Encoding::new($false) : le paramètre $false = emitBOM:$false → pas de BOM.
    $Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    $XmlBytes  = $Utf8NoBom.GetBytes($RulePackageXml)
    New-DlpSensitiveInformationTypeRulePackage -FileData $XmlBytes -ErrorAction Stop
    Write-Host "-> Rule Package uploadé avec succès." -ForegroundColor Green
}
catch {
    Write-Host "-> Échec upload : $_" -ForegroundColor Red
    return
}

# --- ÉTAPE 4 : Vérification ---
# La propagation dans Purview prend environ 30 secondes après l'upload
Write-Host "`n4. Vérification (propagation ~30s)..." -ForegroundColor Cyan
Start-Sleep -Seconds 30

$NewSIT = Get-DlpSensitiveInformationType | Where-Object { $_.Name -eq $SITName }

if ($NewSIT) {
    Write-Host "-> SIT créé et visible dans Purview :" -ForegroundColor Green
    [PSCustomObject]@{
        Nom                   = $NewSIT.Name
        Editeur               = $NewSIT.Publisher
        ConfidenceRecommandee = $NewSIT.RecommendedConfidence
        OccurrencesMin        = $NewSIT.MinCount
        OccurrencesMax        = $NewSIT.MaxCount
    } | Format-List
} else {
    Write-Host "-> SIT pas encore visible — réplication en cours." -ForegroundColor Yellow
    Write-Host "-> Vérifie dans Purview portal > Data Classification > Sensitive info types." -ForegroundColor Yellow
}

# --- NETTOYAGE MÉMOIRE ---
Remove-Variable RulePackageId, EntityId, SITName, SITDescription, RulePackageXml, `
                Utf8NoBom, XmlBytes, NewSIT -ErrorAction SilentlyContinue

# --- FERMETURE ---
Get-PSSession | Remove-PSSession
Write-Host "`nSession fermée. Mémoire locale nettoyée." -ForegroundColor Magenta
