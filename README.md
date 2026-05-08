# PowerShell
#Liste de commandes en tas, SC401 + SC300 + PowerShell de base

# montre moi
Get- 

# modifie
Set- 

# crée
New- 

# supprime
Remove- 

# vérifie
Test- 




# Data Loo Prevention
Dlp 

# Etiquette de sensibilité
Label 

# Publication d'etiquette
LabelPolicy 

# Retention des données
Retention 

# Message Encryption
OME 

# Branding Mail. (Logo, couleurs du portail).	Chiffrement
OMEConfiguration

# Information Rights Management
IRM 

# Chiffrement Global. (Le bouton ON/OFF).
IRMConfiguration

# Rights MAnagement Service
RMS 

# Modèles de droits. (Permissions Lecture/Copie).
RMSTemplate

# SIT
SentitiveInformationType 


# Logins
# 1. Purview (Compliance / Labels / DLP)
Connect-IPPSSession

# 2. Exchange Online (Mail / OME)
Connect-ExchangeOnline

# 3. Microsoft Graph (Users / Groups / SC-300)
Connect-MgGraph -Scopes "User.Read.All", "Group.ReadWrite.All"

# 4. NETTOYAGE (En cas de bug ou fin de session)
Get-PSSession | Remove-PSSession # Ferme les tuyaux ouverts
Disconnect-ExchangeOnline      # Déconnexion propre

