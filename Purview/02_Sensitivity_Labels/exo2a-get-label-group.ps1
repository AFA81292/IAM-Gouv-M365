# ========================================================================================
# Exercice 2a : Sensitivity Labels — Récupération d'un label group créé via GUI
# ========================================================================================
# Concept : Sur le schéma moderne de labels Purview (actif par défaut sur tout tenant
# créé après le 01/10/2025), la création d'un LABEL GROUP n'est PAS possible via
# PowerShell — confirmé par l'absence de toute cmdlet *LabelGroup* dans
# ExchangeOnlineManagement et Microsoft.Graph.Security (vérifié via Get-Command).
# Cette opération est exclusivement disponible via le portail Purview
# (Information Protection > Sensitivity labels > Create a label).
#
# Le label group "NSR2 - Confidentiel" a donc été créé manuellement via le portail Purview,
# avec uniquement nom/description — les label groups ne supportent que nom, description,
# couleur et priorité, aucun marquage ni chiffrement (ces réglages vivent au niveau sublabel).
#
# Ce script récupère ce label group par son nom et stocke son Guid en variable,
# réutilisable comme -ParentId pour créer des sublabels (voir 2b, 2c).
#
# Cas d'usage réel :
#   - Démontrer la compréhension d'une limitation API actuelle et savoir documenter
#     un contournement légitime (étape manuelle + automatisation de ce qui suit)
#   - Pattern réutilisable : "récupérer un objet existant, stocker son identifiant,
#     l'utiliser comme référence dans les opérations suivantes"
#
# Module requis : ExchangeOnlineManagement
# Connexion : Connect-IPPSSession
# ========================================================================================

# --- OUVERTURE ---
Get-PSSession | Remove-PSSession
Connect-IPPSSession -UserPrincipalName GeptorAdmin@0n4mg.onmicrosoft.com -ShowBanner:$false

# --- ÉTAPE 1 : Récupération du label group ---
# Le label group a été créé manuellement via le portail Purview (étape obligatoire,
# aucune cmdlet PowerShell équivalente n'existe à ce jour).
Write-Host "1. Récupération du label group 'NSR2 - Confidentiel'..." -ForegroundColor Cyan

$ParentGroup = Get-Label -Identity "NSR2 - Confidentiel" -ErrorAction Stop

Write-Host "-> Label group trouvé." -ForegroundColor Green
Write-Host "-> Nom  : $($ParentGroup.DisplayName)" -ForegroundColor Green
Write-Host "-> Guid : $($ParentGroup.Guid)`n" -ForegroundColor Green

# --- ÉTAPE 2 : Vérification — aucun sublabel pour l'instant ---
Write-Host "2. Sublabels existants sous ce groupe..." -ForegroundColor Cyan

$ExistingSublabels = Get-Label | Where-Object { $_.ParentId -eq $ParentGroup.Guid }

if ($ExistingSublabels) {
    $ExistingSublabels | Select-Object DisplayName | Format-Table -AutoSize
} else {
    Write-Host "-> Aucun sublabel pour l'instant — normal, ils seront créés en 2b et 2c.`n" -ForegroundColor Yellow
}

# --- NETTOYAGE MÉMOIRE ---
# ParentGroup.Guid sera récupéré à nouveau en 2b/2c via le même pattern Get-Label
Remove-Variable ParentGroup, ExistingSublabels -ErrorAction SilentlyContinue

# --- FERMETURE ---
Get-PSSession | Remove-PSSession
Write-Host "`nSession fermée." -ForegroundColor Magenta
