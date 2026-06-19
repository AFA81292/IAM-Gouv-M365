# ========================================================================================
# Exercice 1b : Data Classification — Création d'un SIT personnalisé par regex
# ========================================================================================
# Concept : Quand aucun SIT built-in ne couvre un besoin métier spécifique, on crée
# un SIT custom basé sur un pattern regex. Ici : numéro de badge interne fictif
# de la société Cerberus Corp, format GCORP-XXXXX (5 chiffres).
#
# Architecture d'un SIT custom :
#   - Un Rule Package XML : contient le pattern regex, les niveaux de confiance,
#     les éléments corroborants (keywords), et les métadonnées du SIT
#   - Le Rule Package est uploadé dans Purview via New-DlpSensitiveInformationTypeRulePackage
#   - Purview enregistre ensuite le SIT, visible via Get-DlpSensitiveInformationType
#
# Cas d'usage réel :
#   - Détecter des identifiants internes propriétaires (matricules RH, numéros de contrat)
#     qu'aucun SIT Microsoft ne couvre nativement
#   - Base indispensable avant de créer une DLP policy sur des données maison
#
# Module requis : ExchangeOnlineManagement
# Connexion : Connect-IPPSSession
# ========================================================================================

# --- OUVERTURE ---
Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
Connect-IPPSSession -UserPrincipalName GeptorAdmin@0n4mg.onmicrosoft.com

# --- ÉTAPE 1 : Définition des variables ---
Write-Host "1. Définition du SIT custom..." -ForegroundColor Cyan

# Ces GUIDs doivent être uniques dans ton tenant — on les génère dynamiquement
# RulePackageId : identifie le package entier
# EntityId      : identifie le SIT spécifique à l'intérieur du package
$RulePackageId = [guid]::NewGuid().ToString()
$EntityId      = [guid]::NewGuid().ToString()

$SITName        = "Cerberus Corp - Numéro de Badge Interne"
$SITDescription = "Détecte les numéros de badge internes Cerberus Corp au format GCORP-XXXXX"

Write-Host "-> RulePackageId : $RulePackageId" -ForegroundColor Green
Write-Host "-> EntityId      : $EntityId`n" -ForegroundColor Green

# --- ÉTAPE 2 : Construction du Rule Package XML ---
# Le XML est le format natif de Purview pour les SIT custom.
# Structure clé :
#   - Pattern       : le regex qui détecte le numéro de badge
#   - ConfidenceLevel High (85) : pattern seul + keyword corroborant
#   - ConfidenceLevel Medium (75) : pattern seul sans corroboration
#   - Keywords      : mots-clés qui renforcent la détection (éléments corroborants)
#     Si le regex matche ET qu'un keyword est présent → High confidence
#     Si le regex matche seul                         → Medium confidence
Write-Host "2. Construction du Rule Package XML..." -ForegroundColor Cyan

$RulePackageXml = @"
<?xml version="1.0" encoding="utf-8"?>
<RulePackage xmlns="http://schemas.microsoft.com/office/2011/mce">
  <RulePack id="{$RulePackageId}">
    <Version major="1" minor="0" build="0" revision="0"/>
    <Publisher id="{$RulePackageId}"/>
    <Details defaultLangCode="fr">
      <LocalizedDetails langcode="fr">
        <PublisherName>Cerberus Corp IAM Lab</PublisherName>
        <Name>Cerberus Corp Rule Package</Name>
        <Description>Package de règles pour les identifiants internes Cerberus Corp</Description>
      </LocalizedDetails>
    </Details>
  </RulePack>
  <Rules>
    <Entity id="{$EntityId}" patternsProximity="300" recommendedConfidence="75">
      <Pattern confidenceLevel="85">
        <!-- Regex principal : GCORP- suivi de 5 chiffres exactement -->
        <IdMatch idRef="Regex_CerberusBadge"/>
        <!-- Keyword corroborant : si le mot "badge" ou "matricule" est dans
             les 300 caractères autour du match → confiance passe à 85 -->
        <Match idRef="Keywords_CerberusBadge"/>
      </Pattern>
      <Pattern confidenceLevel="75">
        <!-- Pattern seul sans corroboration — confiance medium -->
        <IdMatch idRef="Regex_CerberusBadge"/>
      </Pattern>
    </Entity>
    <Regex id="Regex_CerberusBadge">GCORP-[0-9]{5}</Regex>
    <Keyword id="Keywords_CerberusBadge">
      <Group matchStyle="word">
        <Term>badge</Term>
        <Term>matricule</Term>
        <Term>identifiant</Term>
        <Term>cerberus</Term>
      </Group>
    </Keyword>
    <LocalizedStrings>
      <Resource idRef="{$EntityId}">
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
    # UTF-8 sans BOM — seul encoding accepté par Purview pour les rule packages
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
Remove-Variable RulePackageId, EntityId, SITName, SITDescription, RulePackageXml, XmlBytes, NewSIT `
    -ErrorAction SilentlyContinue

# --- FERMETURE ---
Disconnect-ExchangeOnline -Confirm:$false
Write-Host "`nSession fermée. Mémoire locale nettoyée." -ForegroundColor Magenta
