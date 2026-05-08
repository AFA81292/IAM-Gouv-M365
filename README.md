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
# Purview (Compliance / Labels / DLP)
Connect-IPPSSession

# Exchange Online (Mail / OME)
Connect-ExchangeOnline

# Microsoft Graph (Users / Groups / SC-300)
Connect-MgGraph -Scopes "User.Read.All", "Group.ReadWrite.All"

# NETTOYAGE (En cas de bug ou fin de session)
Get-PSSession | Remove-PSSession # Ferme les tuyaux ouverts
Disconnect-ExchangeOnline      # Déconnexion propre

# Activer l'audit pour un utilisateur spécifique (Essentiel pour voir les actions des délégués)
Set-Mailbox -Identity "User1" -AuditEnabled $true

# Vérifier si l'audit est bien activé sur une boîte
Get-Mailbox -Identity "User1" | Select-Object AuditEnabled

# Chercher qui a supprimé des messages dans la boîte de User1
Search-MailboxAuditLog -Identity "User1" -Operations SoftDelete, HardDelete

# Chercher qui s'est connecté à la boîte (Sign-in)
Search-MailboxAuditLog -Identity "User1" -Operations Logon

