# 🛡️ M365 Security & Identity - Engineering Repository

Référentiel de scripts, notes de révision et Proof of Concepts (POC) pour les certifications **SC-300** et **SC-401**.

## 🧭 Structure du dépôt
*   📁 **[Entra-ID](./Entra-ID/)** : Gestion des identités, rôles et annuaire (SC-300).
*   📁 **[Purview-Compliance](./Purview-Compliance/)** : Conformité, DLP et classification des données (SC-401).
*   📁 **[Exchange-Security](./Exchange-Security/)** : Sécurité des mails, chiffrement et logs d'audit.

---

## 🎯 Rappel : La Grammaire PowerShell

| Verbe | Action |
| :--- | :--- |
| `Get-` | **Montre** (Audit de l'existant) |
| `Set-` | **Modifie** (Durcissement de configuration) |
| `New-` | **Crée** (Déploiement d'une règle/rôle) |
| `Remove-` | **Supprime** (Révocation) |
| `Test-` | **Vérifie** (Diagnostic et santé système) |
| `Search-` | **Recherche** (Analyse de logs / Forensics) |


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

# Recherche ce qui a été fait
Search- 



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

# Activer la surveillance globale des actions des Admins (Tenant-wide)
Set-AdminAuditLogConfig -AdminAuditLogEnabled $true

# Surveiller uniquement les commandes liées aux boîtes mails (Filtre)
Set-AdminAuditLogConfig -AdminAuditLogCmdlets *Mailbox*

# Surveiller uniquement les commandes liées au transport (Mail Flow)
Set-AdminAuditLogConfig -AdminAuditLogCmdlets *TransportRule*

# Activer la surveillance utilisateur sur une boite mail
Set-Mailbox -AuditEnabled $true

# Activer la surveillance utilisateur sur toutes les boites mail du tenant
Set-AuditConfig -Workload Exchange


# --- TESTS DE SANTÉ DU SYSTÈME (DIAGNOSTICS) ---

# Vérifier la configuration globale du chiffrement (IRM/OME) et les templates
Test-IRMConfiguration -Sender user1@contoso.com

# Tester si le flux de messagerie de base est opérationnel
Test-Mailflow -TargetEmailAddress partner@fabrikam.com

# Vérifier la connectivité OAuth (Indispensable pour le chiffrement en mode hybride)
Test-OAuthConnectivity -Service EWS -TargetUri https://outlook.office365.com/ews/exchange.asmx

# --- GESTION DU CHIFFREMENT (OME) ---

# Créer un nouveau template de marque pour une filiale (Branding)
New-OMEConfiguration -Identity "Filiale_Luxe" -Image (Get-Content "C:\Logos\Luxe.png" -Encoding byte)

# Configurer l'expiration automatique des mails chiffrés (ex: 7 jours)
Set-OMEConfiguration -Identity "Filiale_Luxe" -ExternalMailExpiryInDays 7

# Révoquer manuellement un mail chiffré envoyé à un destinataire externe (Social ID)
Set-OMEMessageRevocation -Revoke $true -MessageId "<ID_DU_MESSAGE>"

