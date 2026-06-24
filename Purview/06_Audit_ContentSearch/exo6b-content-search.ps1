# ========================================================================================
# Exercice 6b : Content Search — mailbox ciblée, date range, mot-clé
# ========================================================================================
# Concept : Content Search est le moteur de recherche de contenu dans Microsoft Purview.
# Il permet d'interroger Exchange (mailboxes), SharePoint (sites), OneDrive (comptes)
# et Teams (messages) depuis une interface unifiée — sans accéder directement
# aux boîtes ou aux sites concernés.
#
# Ce script ne fait PAS d'export — il crée la recherche, la lance, attend la fin
# via une boucle de polling, et récupère les statistiques (nombre d'items, taille estimée).
# L'export nécessite une action séparée (New-ComplianceSearchAction -Export) et une
# licence eDiscovery Standard ou Premium selon le volume.
#
# Ce que fait ce script :
#   1. Reset total de session
#   2. Définit les paramètres de recherche (mailbox, mot-clé, plage de dates, query KQL)
#   3. Recherche un nom disponible (auto-incrément)
#   4. Crée la Content Search (sans la lancer)
#   5. Lance la recherche
#   6. Attend la fin via polling (boucle active, timeout 5 minutes)
#   7. Récupère et affiche les statistiques de résultat
#   8. Ferme proprement toutes les sessions
#
# PIÈGE TIMING : une Content Search n'est pas instantanée.
# Le script attend activement la fin avec une boucle de polling — sans ça,
# les stats sont vides car la recherche est encore en cours côté backend.
#
# Cas d'usage réels :
#   - Réponse à incident : "trouve tous les emails contenant CONFIDENTIEL
#     envoyés depuis cette boîte dans les 90 derniers jours"
#   - Préparation eDiscovery : collecte de preuves avant export légal
#   - Audit de fuite : vérification qu'un document sensible n'a pas été diffusé
#
# Module requis : ExchangeOnlineManagement
# Connexion     : Connect-IPPSSession
# Licence       : Microsoft Purview eDiscovery Standard (inclus E3/E5)
# ========================================================================================

# --- OUVERTURE — RESET DE SESSION TOTAL ---
# REX : des sessions fantômes restées ouvertes depuis un script précédent peuvent
# provoquer des erreurs silencieuses ou des authentifications croisées.
# On purge TOUT avant de commencer, sans exception.
#
# $env:MSAL_ENABLE_WAM = "0" : désactive le Windows Authentication Manager.
# Sans ce workaround, WAM peut réutiliser un token de session précédente avec
# des scopes insuffisants — cause fréquente d'erreurs silencieuses sur Connect-IPPSSession.
# Note : Connect-IPPSSession ne supporte pas -ShowBanner:$false — bandeau normal.
Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
Get-PSSession | Remove-PSSession
$env:MSAL_ENABLE_WAM = "0"
Connect-IPPSSession -UserPrincipalName GeptorAdmin@0n4mg.onmicrosoft.com

# ========================================================================================
# ÉTAPE 1 : Définition des paramètres de recherche
# ========================================================================================
Write-Host "1. Définition des paramètres de recherche..." -ForegroundColor Cyan

# Mailbox cible — doit exister sur le tenant.
# Si la mailbox n'existe pas, la search se crée sans erreur mais revient
# avec 0 résultats et Status "Completed" — indiscernable d'une vraie absence de résultats.
$TargetMailbox = "shepard@0n4mg.onmicrosoft.com"

# Mot-clé — syntaxe KQL (Keyword Query Language).
# Guillemets autour du terme pour une recherche exacte sur le mot complet.
# Opérateurs disponibles : AND, OR, NOT, NEAR, parenthèses.
# Ex. avancé : "CONFIDENTIEL AND (projet OR mission)"
$Keyword = "CONFIDENTIEL"

# Plage de dates — glissante sur les 90 derniers jours depuis aujourd'hui.
# Calculée dynamiquement pour que le script soit rejouable sans modifier les dates manuellement.
# Format attendu par ContentMatchQuery : MM/DD/YYYY (format US, pas FR).
$DateEnd      = Get-Date
$DateStart    = $DateEnd.AddDays(-90)
$DateStartStr = $DateStart.ToString("MM/dd/yyyy")
$DateEndStr   = $DateEnd.ToString("MM/dd/yyyy")

# Construction de la query KQL complète.
# sent>= : date d'envoi ou de création >= DateStart
# sent<= : date d'envoi ou de création <= DateEnd
# Les deux conditions combinées avec AND délimitent la fenêtre temporelle.
$ContentQuery = "$Keyword AND sent>=$DateStartStr AND sent<=$DateEndStr"

Write-Host "   Mailbox cible  : $TargetMailbox"                                      -ForegroundColor Gray
Write-Host "   Mot-clé        : $Keyword"                                             -ForegroundColor Gray
Write-Host "   Plage          : $DateStartStr → $DateEndStr (90 jours glissants)"    -ForegroundColor Gray
Write-Host "   Query KQL      : $ContentQuery`n"                                      -ForegroundColor Gray

# ========================================================================================
# ÉTAPE 2 : Recherche d'un nom disponible (auto-incrément)
# ========================================================================================
Write-Host "2. Recherche d'un nom disponible..." -ForegroundColor Cyan

# "NormandySR2" = le vaisseau de Shepard dans Mass Effect — convention de nommage du lab.
$BaseSearchName = "CS-NormandySR2-Shepard-CONFIDENTIEL-90d"
$SearchName     = $BaseSearchName
$Counter        = 2

while (Get-ComplianceSearch -Identity $SearchName -ErrorAction SilentlyContinue) {
    Write-Host "   '$SearchName' déjà pris — test avec suffixe -v$Counter..." -ForegroundColor Yellow
    $SearchName = "$BaseSearchName-v$Counter"
    $Counter++
}

Write-Host "-> Nom retenu : '$SearchName'`n" -ForegroundColor Green

# ========================================================================================
# ÉTAPE 3 : Création de la Content Search
# ========================================================================================
Write-Host "3. Création de la Content Search '$SearchName'..." -ForegroundColor Cyan

# New-ComplianceSearch crée la recherche mais ne la lance PAS automatiquement.
# Elle reste en état "NotStarted" jusqu'à un appel explicite à Start-ComplianceSearch.
# C'est intentionnel — permet de vérifier la configuration avant de consommer
# les ressources du backend (les grandes searches peuvent prendre plusieurs minutes).
try {
    $NewSearch = New-ComplianceSearch `
        -Name              $SearchName `
        -ExchangeLocation  $TargetMailbox `
        -ContentMatchQuery $ContentQuery `
        -Description       "Exo 6b — Search CONFIDENTIEL 90j sur mailbox Shepard. NormandySR2 recon." `
        -ErrorAction Stop

    Write-Host "-> Search créée : $($NewSearch.Name) [Status : $($NewSearch.Status)]`n" -ForegroundColor Green
}
catch {
    Write-Host "-> Échec de la création : $_" -ForegroundColor Red
    Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
    Get-PSSession | Remove-PSSession
    return
}

# ========================================================================================
# ÉTAPE 4 : Lancement de la recherche
# ========================================================================================
Write-Host "4. Lancement de la recherche..." -ForegroundColor Cyan

# Start-ComplianceSearch déclenche l'exécution côté backend Purview.
# La search passe de "NotStarted" → "Starting" → "InProgress" → "Completed".
try {
    Start-ComplianceSearch -Identity $SearchName -ErrorAction Stop
    Write-Host "-> Recherche lancée.`n" -ForegroundColor Green
}
catch {
    Write-Host "-> Échec du lancement : $_" -ForegroundColor Red
    Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
    Get-PSSession | Remove-PSSession
    return
}

# ========================================================================================
# ÉTAPE 5 : Attente de la fin (polling)
# ========================================================================================
Write-Host "5. Attente de la fin de la recherche (polling toutes les 30s, timeout 10min)..." -ForegroundColor Cyan

# Sans cette boucle, les stats sont vides — la search est encore en cours côté backend.
# On poll toutes les 30 secondes (seuil minimal fiable), timeout à 10 minutes (20 tentatives).
# Sur une mailbox de dev vide ou peu remplie, la search finit en 30-60 secondes.
# Sur une mailbox de prod avec 10 ans de données, compter plusieurs minutes.
$MaxAttempts = 20
$Attempt     = 0
$SearchDone  = $false

do {
    Start-Sleep -Seconds 30
    $Attempt++
    $CurrentStatus = (Get-ComplianceSearch -Identity $SearchName).Status
    Write-Host "   Tentative $Attempt/$MaxAttempts — Status : $CurrentStatus" -ForegroundColor Gray

    if ($CurrentStatus -eq "Completed") {
        $SearchDone = $true
    }
} while (-not $SearchDone -and $Attempt -lt $MaxAttempts)

if (-not $SearchDone) {
    Write-Host "-> TIMEOUT : la recherche n'a pas terminé dans les 10 minutes." -ForegroundColor Red
    Write-Host "   Vérifier manuellement : Get-ComplianceSearch -Identity '$SearchName' | Format-List Status, Items, Size" -ForegroundColor Yellow
    Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
    Get-PSSession | Remove-PSSession
    return
}

Write-Host "-> Recherche terminée.`n" -ForegroundColor Green

# ========================================================================================
# ÉTAPE 6 : Récupération des statistiques
# ========================================================================================
Write-Host "6. Récupération des statistiques..." -ForegroundColor Cyan

# Items : nombre d'éléments trouvés correspondant à la query.
# Size  : taille estimée en octets (estimation backend — pas encore exporté).
# SuccessResults : détail par source (mailbox, site) — utile pour les searches multi-location.
$FinalSearch = Get-ComplianceSearch -Identity $SearchName

# Conversion de la taille brute en octets vers Ko ou Mo pour la lisibilité.
$SizeBytes   = $FinalSearch.Size
$SizeDisplay = if ($SizeBytes -ge 1MB) {
    "$([math]::Round($SizeBytes / 1MB, 2)) Mo"
} elseif ($SizeBytes -ge 1KB) {
    "$([math]::Round($SizeBytes / 1KB, 2)) Ko"
} else {
    "$SizeBytes octets"
}

Write-Host "-> Résultats :" -ForegroundColor Green
[PSCustomObject]@{
    Nom           = $FinalSearch.Name
    Status        = $FinalSearch.Status
    ItemsTrouvés  = $FinalSearch.Items
    TailleEstimée = $SizeDisplay
    Query         = $FinalSearch.ContentMatchQuery
    Mailbox       = $TargetMailbox
} | Format-List

if ($FinalSearch.SuccessResults) {
    Write-Host "   Détail par source :" -ForegroundColor Gray
    Write-Host $FinalSearch.SuccessResults -ForegroundColor Gray
}

# ========================================================================================
# RÉSUMÉ
# ========================================================================================
Write-Host "=== RÉSUMÉ ===" -ForegroundColor Magenta
[PSCustomObject]@{
    SearchCréée    = $SearchName
    Mailbox        = $TargetMailbox
    MotClé         = $Keyword
    Plage          = "$DateStartStr → $DateEndStr"
    ItemsTrouvés   = $FinalSearch.Items
    TailleEstimée  = $SizeDisplay
    ExportPossible = "Oui — via portail Purview ou New-ComplianceSearchAction -Export (non couvert ici)"
} | Format-List

Write-Host "Note : 0 résultat ne signifie pas forcément une erreur." -ForegroundColor Yellow
Write-Host "Si la mailbox existe mais ne contient pas le mot-clé dans la plage, c'est normal.`n" -ForegroundColor Yellow

# ========================================================================================
# NETTOYAGE MÉMOIRE
# ========================================================================================
Remove-Variable TargetMailbox, Keyword, DateEnd, DateStart, DateStartStr, DateEndStr, `
                ContentQuery, BaseSearchName, SearchName, Counter, NewSearch, `
                MaxAttempts, Attempt, SearchDone, CurrentStatus, FinalSearch, `
                SizeBytes, SizeDisplay `
                -ErrorAction SilentlyContinue

# ========================================================================================
# FERMETURE — RESET DE SESSION TOTAL
# ========================================================================================
Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
Get-PSSession | Remove-PSSession
Write-Host "Sessions fermées proprement." -ForegroundColor Magenta
