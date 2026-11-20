# enem_proxmox_boostrap

Ce dépôt fournit `bootstrap-manager.sh`, un script Bash conçu pour créer automatiquement sur Proxmox VE un conteneur LXC Ubuntu destiné à servir de poste de gestion (Terraform, Ansible, Git, Python et outils associés).

> Vérifiez et adaptez la section `CONFIGURATION À ADAPTER` avant exécution.

## Fonctionnalités

- Vérifie que le script est exécuté sur un nœud Proxmox VE avec les droits `root`.
- Vérifie l’existence de la clé publique SSH configurée.
- Refuse de remplacer un ID déjà utilisé par une VM QEMU.
- Propose la suppression d’un conteneur LXC portant déjà l’ID choisi.
- Télécharge le dernier template Ubuntu correspondant à la version configurée.
- Crée un conteneur LXC non privilégié avec réseau statique et démarrage automatique.
- Installe Git, Ansible, Terraform, Python 3 et les outils associés.
- Configure la locale française `fr_FR.UTF-8`.
- Crée un utilisateur administrateur avec accès `sudo`.
- Configure les clés SSH, `authorized_keys` et `known_hosts`.
- Demande de façon interactive le mot de passe de l’utilisateur administrateur.

## Configuration par défaut

| Élément | Valeur |
|---|---|
| Template Ubuntu | 26.04 |
| ID du conteneur | `110` |
| Nom d’hôte | `manager` |
| Adresse IP | `192.168.1.9/24` |
| Passerelle | `192.168.1.1` |
| DNS | `192.168.1.1` |
| Pont réseau | `vmbr0` |
| Stockage du conteneur | `local-lvm` |
| Stockage des templates | `local` |
| CPU | 1 cœur |
| Mémoire | 1024 Mo |
| Swap | 512 Mo |
| Disque racine | 6 Go |
| Utilisateur | `srvadmin` |
| Clé publique | `/root/.ssh/id_ed25519.pub` |
| Tag | `mgmt` |

## Prérequis

- Un serveur Proxmox VE avec les commandes `pveam`, `pct` et `qm`.
- Une exécution en tant que `root`.
- Une clé SSH Ed25519 sur le nœud Proxmox.
- Le stockage configuré pour les templates `vztmpl` et les disques LXC.
- Un accès réseau aux dépôts Ubuntu, Ansible, GitHub et HashiCorp.

## Préparation

Générez une clé Ed25519 si nécessaire :

```bash
ssh-keygen -t ed25519 -f /root/.ssh/id_ed25519 -N ""
```

Rendez le script exécutable :

```bash
chmod +x bootstrap-manager.sh
```

## Utilisation

Modifiez les variables situées en tête de `bootstrap-manager.sh`, puis lancez :

```bash
./bootstrap-manager.sh
```

Le script met à jour les templates disponibles, télécharge le template Ubuntu configuré si nécessaire, crée le conteneur, installe les outils et demande ensuite le mot de passe de l’utilisateur administrateur.

Si l’ID configuré appartient déjà à un conteneur LXC, le script demande confirmation avant de l’arrêter et de le supprimer avec `--purge`.

Avec la configuration par défaut, connectez-vous avec :

```bash
ssh srvadmin@192.168.1.9
```

## Outils installés

- Git
- Ansible
- Terraform
- Python 3 et pip
- virtualenv
- curl, wget et unzip
- sshpass
- CA certificates
- locales
- GnuPG
- logiciels supplémentaires des dépôts Ubuntu

## Sécurité

- Le conteneur est créé en mode **non privilégié**.
- La fonction `nesting=1` est activée.
- L’utilisateur appartient au groupe `sudo` avec une règle `NOPASSWD` dédiée.
- Les permissions du répertoire `.ssh` et des clés sont restreintes.
- La clé privée de l’administrateur est copiée dans le conteneur.
- L’empreinte du nœud Proxmox est ajoutée à `known_hosts`.

Utilisez une clé privée protégée et limitez les règles `NOPASSWD` selon les besoins de votre environnement.

## Dépannage

### Script hors de Proxmox

Exécutez-le directement sur un nœud où `pveversion` et `pct` sont disponibles.

### Clé publique introuvable

Vérifiez `SSH_PUB_KEY_PATH` ou créez la clé :

```bash
ssh-keygen -t ed25519 -f /root/.ssh/id_ed25519 -N ""
```

### Aucun template Ubuntu trouvé

Vérifiez `UBUNTU_VERSION`, puis exécutez :

```bash
pveam update
pveam available --section system
```
