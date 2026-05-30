# Entra ID - Gestion des Identités (SC-300)

Notes de révision et scripts de validation pour les modules d'identité Microsoft.

## Prérequis
Le module Microsoft Graph PowerShell doit être installé :
```powershell
Install-Module Microsoft.Graph -Scope CurrentUser
```

## Index des Exercices (1 fichier = 1 exo)

### 01_User_Management
* [Exo 1 : Création d'un rôle personnalisé](./01_User_Management/exo1-custom-role.ps1)
  * Objectif : Déploiement d'un rôle RBAC granulaire pour la création d'applications.
  * Licence requise : Entra ID P1/P2.
* [Exo 2 : Création unitaire d'un utilisateur](./01_User_Management/exo2-create-user.ps1)
  * Objectif : Provisioning unitaire d'un utilisateur via Graph API.
* [Exo 2bis : Création d'utilisateurs en masse](./01_User_Management/exo2bis-bulk-create-users.ps1)
  * Objectif : Injection d'utilisateurs en masse via parsing du fichier [utilisateurs.csv](./01_User_Management/utilisateurs.csv).

### 02_Administrative_Units
* [Exo 3a : AU statique et droits scopés](./02_Administrative_Units/exo3a-static-au-delegation.ps1)
  * Objectif : Création d'une Administrative Unit statique, assignation de membres et délégation de rôle scopé au chef.
* [Exo 3b : AU dynamique](./02_Administrative_Units/exo3b-dynamic-au-delegation.ps1)
  * Objectif : Création d'une Administrative Unit dynamique via règle d'appartenance.
  * Licence requise : Entra ID P1/P2.

### 03_Group_Management
* [Exo 4a : Security Group statique](./03_Group_Management/exo4a-static-security-group.ps1)
  * Objectif : Création d'un Security Group statique avec owner et peuplement de membres via fichier CSV.
* [Exo 4b : Security Group dynamique](./03_Group_Management/exo4b-dynamic-security-group.ps1)
  * Objectif : Création d'un Security Group dynamique avec règle de membership automatique basée sur l'attribut département.
  * Licence requise : Entra ID P1/P2.
