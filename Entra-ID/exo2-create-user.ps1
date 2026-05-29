# Connexion avec les privilèges requis pour la gestion des comptes
Connect-MgGraph -Scopes "User.ReadWrite.All"

# 1. Configuration du profil de mot de passe
$PasswordProfile = @{
    Password                      = "Compl3xP@ssw0rd!2026"
    ForceChangePasswordNextSignIn = $true
}

# 2. Construction du dictionnaire de paramètres (Splatting)
$UserParams = @{
    DisplayName       = "Geralt de Riv"
    MailNickName      = "geralt"
    UserPrincipalName = "geralt@0n4mg.onmicrosoft.com"
    AccountEnabled    = $true
    PasswordProfile   = $PasswordProfile
}

# 3. Exécution et création de l'utilisateur dans Entra ID
$NewUser = New-MgUser @UserParams

# 4. Vérification et affichage du GUID généré par Azure
$NewUser | Select-Object Id, DisplayName, UserPrincipalName

# 5. Nettoyage de la session
Remove-Variable PasswordProfile, UserParams, NewUser
