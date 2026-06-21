# ========================================================================================
# Exercice 3e : Message Encryption — Audit unifié du chiffrement automatique du tenant
# ========================================================================================
# Concept : Lister TOUT le chiffrement automatique configuré sur le tenant. Depuis 3c, ce
# n'est plus un seul type d'objet : le chiffrement par mot-clé/scope vit dans les Transport
# Rules (3b, 3d), le chiffrement par classification vit dans les DLP Compliance Rules (3c).
# Un audit qui n'interroge que Get-TransportRule manquerait silencieusement la moitié de la
# configuration réelle — ce script normalise les deux dans une sortie unique.
#
# Association DLP Rule -> Policy parente : on ne suppose pas un nom de propriété sur l'objet
# rule (Get-DlpComplianceRule ne documente pas de champ "ParentPolicyName" fiable) — on
# parcourt les policies et on filtre via -Policy, syntaxe explicitement documentée par
# Microsoft pour récupérer les règles d'une policy donnée.
#
# Module requis : ExchangeOnlineManagement
# Connexion : Connect-ExchangeOnline (Transport Rules) + Connect-IPPSSession (DLP)
# ========================================================================================

# --- OUVERTURE ---
Get-PSSession | Remove-PSSession
Connect-IPPSSession -UserPrincipalName GeptorAdmin@0n4mg.onmicrosoft.com -ShowBanner:$false
Connect-ExchangeOnline -UserPrincipalName GeptorAdmin@0n4mg.onmicrosoft.com -ShowBanner:$false

$AuditResults = @()

# --- ÉTAPE 1 : Transport Rules avec action de chiffrement ---
Write-Host "1. Audit des Transport Rules..." -ForegroundColor Cyan

$EncryptingTransportRules = Get-TransportRule | Where-Object { $_.ApplyRightsProtectionTemplate }

foreach ($Rule in $EncryptingTransportRules) {
    $AuditResults += [PSCustomObject]@{
        Type      = "TransportRule"
        Nom       = $Rule.Name
        Mecanisme = "Mot-clé / Scope (ETR)"
        Statut    = "$($Rule.Mode) / $($Rule.State)"
        Template  = $Rule.ApplyRightsProtectionTemplate
    }
}
Write-Host "-> $($EncryptingTransportRules.Count) Transport Rule(s) trouvée(s).`n" -ForegroundColor Green

# --- ÉTAPE 2 : DLP Compliance Rules avec action de chiffrement ---
Write-Host "2. Audit des DLP Compliance Rules..." -ForegroundColor Cyan

$AllDlpPolicies = Get-DlpCompliancePolicy
$DlpCount = 0

foreach ($Policy in $AllDlpPolicies) {
    # -Policy : syntaxe documentée pour récupérer les règles d'une policy donnée.
    $PolicyRules = Get-DlpComplianceRule -Policy $Policy.Name -ErrorAction SilentlyContinue

    foreach ($Rule in $PolicyRules) {
        if ($Rule.EncryptRMSTemplate) {
            $DlpCount++
            $AuditResults += [PSCustomObject]@{
                Type      = "DlpComplianceRule"
                Nom       = $Rule.Name
                Mecanisme = "Classification SIT (DLP)"
                Statut    = "Policy:$($Policy.Mode) / Disabled:$($Rule.Disabled)"
                Template  = $Rule.EncryptRMSTemplate
            }
        }
    }
}
Write-Host "-> $DlpCount DLP Compliance Rule(s) de chiffrement trouvée(s).`n" -ForegroundColor Green

# --- ÉTAPE 3 : Sortie unifiée ---
Write-Host "=== AUDIT COMPLET — CHIFFREMENT AUTOMATIQUE DU TENANT ===" -ForegroundColor Magenta
$AuditResults | Format-Table -AutoSize

if ($AuditResults.Count -eq 0) {
    Write-Host "-> Aucune règle de chiffrement automatique trouvée sur ce tenant." -ForegroundColor Yellow
} else {
    Write-Host "-> $($AuditResults.Count) règle(s) de chiffrement au total ($($EncryptingTransportRules.Count) ETR + $DlpCount DLP).`n" -ForegroundColor Green
}

# --- NETTOYAGE / FERMETURE ---
Remove-Variable AuditResults, EncryptingTransportRules, AllDlpPolicies, DlpCount, `
    PolicyRules -ErrorAction SilentlyContinue
Get-PSSession | Remove-PSSession
Write-Host "`nSessions fermées." -ForegroundColor Magenta
