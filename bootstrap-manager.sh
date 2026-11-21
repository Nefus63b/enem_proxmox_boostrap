#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# CONFIGURATION À ADAPTER
# ==============================================================================
UBUNTU_VERSION="26.04"     # Version Ubuntu LTS souhaitée (ex: 24.04, 26.04, 28.04)
CT_ID="110"
CT_HOSTNAME="manager"
CT_IP="192.168.1.4/24"
CT_GW="192.168.1.1"
CT_DNS="192.168.1.1"
CT_BRIDGE="vmbr0"
CT_STORAGE="local-lvm"     # Stockage pour le disque du conteneur
TEMPLATE_STORAGE="local"   # Stockage pour le template vztmpl
CT_CORES="1"
CT_MEMORY="1024"           # En Mo
CT_DISK="6"               # En Go
SSH_PUB_KEY_PATH="/root/.ssh/id_ed25519.pub" # Clé publique à autoriser sur le manager
ADMIN_USER="srvadmin"
# ==============================================================================

echo "1. Vérifications préalables de l'environnement..."

# 1.1 Vérification que l'on est bien sur un nœud Proxmox VE
if ! command -v pveversion >/dev/null 2>&1 || ! command -v pct >/dev/null 2>&1; then
    echo "Erreur : Ce script doit être exécuté directement sur un serveur Proxmox VE."
    exit 1
fi

# 1.2 Vérification des droits root
if [ "$EUID" -ne 0 ]; then
    echo "Erreur : Ce script doit être exécuté en tant que root (utilisez sudo ou connectez-vous en root)."
    exit 1
fi

# 1.3 Vérification de la clé SSH publique
if [ ! -f "$SSH_PUB_KEY_PATH" ]; then
    PRIV_KEY_PATH="${SSH_PUB_KEY_PATH%.pub}"
    echo "Erreur : La clé publique '$SSH_PUB_KEY_PATH' est introuvable."
    echo "Pour la générer maintenant sans passphrase, exécutez :"
    echo "  ssh-keygen -t ed25519 -f \"$PRIV_KEY_PATH\" -N \"\""
    exit 1
fi

# 1.4 Vérification si l'ID est déjà utilisé par une VM QEMU (sécurité)
if qm status "$CT_ID" >/dev/null 2>&1; then
    echo "Erreur : L'ID $CT_ID est déjà utilisé par une VM (QEMU). Choisissez un autre CT_ID."
    exit 1
fi

# 1.5 Vérification si le conteneur LXC existe déjà
if pct status "$CT_ID" >/dev/null 2>&1; then
    echo "Attention : Le conteneur LXC $CT_ID existe déjà."
    read -r -p "Voulez-vous le supprimer et le recréer ? [y/N] : " RESPONSE
    case "$RESPONSE" in
        [yY]|[yY][eE][sS]|[oO]|[oO][uU][iI])
            echo "Arrêt et suppression du conteneur $CT_ID en cours..."
            pct stop "$CT_ID" 2>/dev/null || true
            pct destroy "$CT_ID" --purge
            echo "Conteneur $CT_ID supprimé."
            ;;
        *)
            echo "Opération annulée. Aucune modification effectuée."
            exit 0
            ;;
    esac
fi

echo "2. Recherche et téléchargement du dernier template officiel Ubuntu ${UBUNTU_VERSION}..."
pveam update
TEMPLATE_NAME=$(pveam available --section system | awk -v ver="ubuntu-${UBUNTU_VERSION}-standard" 'index($2, ver) == 1 {print $2}' | tail -n 1)

if [ -z "$TEMPLATE_NAME" ]; then
    echo "Erreur : Impossible de trouver le template Ubuntu 26.04 dans pveam."
    exit 1
fi

if [ ! -f "/var/lib/vz/template/cache/$TEMPLATE_NAME" ]; then
    pveam download "$TEMPLATE_STORAGE" "$TEMPLATE_NAME"
else
    echo "Template $TEMPLATE_NAME déjà présent en local."
fi

echo "3. Création du conteneur LXC $CT_ID ($CT_HOSTNAME)..."
pct create "$CT_ID" "${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE_NAME}" \
    --hostname "$CT_HOSTNAME" \
    --cores "$CT_CORES" \
    --memory "$CT_MEMORY" \
    --swap 512 \
    --storage "$CT_STORAGE" \
    --rootfs "${CT_STORAGE}:${CT_DISK}" \
    --net0 "name=eth0,bridge=${CT_BRIDGE},ip=${CT_IP},gw=${CT_GW}" \
    --nameserver "$CT_DNS" \
    --ssh-public-keys "$SSH_PUB_KEY_PATH" \
    --unprivileged 1 \
    --features nesting=1 \
    --onboot 1 \
    --tags "mgmt"

echo "3.5 Suppression de l'image temporaire du template pour libérer de l'espace disque..."
if [ -f "/var/lib/vz/template/cache/$TEMPLATE_NAME" ]; then
    rm -f "/var/lib/vz/template/cache/$TEMPLATE_NAME"
    echo "Template $TEMPLATE_NAME supprimé du cache local."
fi

echo "4. Démarrage du conteneur..."
pct start "$CT_ID"

echo "5. Attente de l'initialisation réseau du conteneur..."
sleep 5

echo "6. Installation des outils dans le conteneur..."
pct exec "$CT_ID" -- bash -s << 'EOF'
    set -e
    export DEBIAN_FRONTEND=noninteractive

    apt-get update
    apt-get install -y git ansible curl unzip python3 python3-pip python3-virtualenv ca-certificates sshpass locales whois pass gnupg2 gnupg software-properties-common wget

    locale-gen fr_FR.UTF-8
    export LC_ALL=fr_FR.UTF-8 LANG=fr_FR.UTF-8
    update-locale LANG=fr_FR.UTF-8
    update-ca-certificates

    wget -O- https://apt.releases.hashicorp.com/gpg | gpg --dearmor --yes -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(grep -oP '(?<=UBUNTU_CODENAME=).*' /etc/os-release || lsb_release -cs) main" > /etc/apt/sources.list.d/hashicorp.list

    apt-get update
    apt-get install -y terraform

    echo "=============================================================================="
    echo "Git:       $(git --version 2>/dev/null || echo 'non installé')"
    echo "Terraform: $(terraform --version 2>/dev/null | head -n1 || echo 'non installé')"
    echo "Ansible:   $(ansible --version 2>/dev/null | head -n1 || echo 'non installé')"
    echo "Python3:   $(python3 --version 2>/dev/null || echo 'non installé')"
    echo "pip3:      $(pip3 --version 2>/dev/null || echo 'non installé')"
    echo "=============================================================================="
EOF

echo "7. Création de l'utilisateur '${ADMIN_USER}' et configuration des clés SSH..."

# 7.1 Autoriser proprement la clé publique sur Proxmox (avec saut de ligne garanti)
mkdir -p /root/.ssh && chmod 700 /root/.ssh
touch /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys
if ! grep -qxF "$(cat "$SSH_PUB_KEY_PATH")" /root/.ssh/authorized_keys; then
    printf "\n%s\n" "$(cat "$SSH_PUB_KEY_PATH")" >> /root/.ssh/authorized_keys
    # Nettoyage des éventuelles lignes vides
    sed -i '/^$/d' /root/.ssh/authorized_keys
fi

# 7.2 Créer l'utilisateur dans le conteneur
pct exec "$CT_ID" -- bash -s "$ADMIN_USER" << 'EOF'
    set -e
    ADMIN_USER="$1"
    id -u "$ADMIN_USER" >/dev/null 2>&1 || useradd -m -s /bin/bash -G sudo "$ADMIN_USER"
    echo "${ADMIN_USER} ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/${ADMIN_USER}"
    chmod 0440 "/etc/sudoers.d/${ADMIN_USER}"
    mkdir -p "/home/${ADMIN_USER}/.ssh"
EOF

# 7.3 Pousser les clés SSH et pré-remplir le known_hosts avec l'empreinte exacte de ce nœud Proxmox
PRIV_KEY_PATH="${SSH_PUB_KEY_PATH%.pub}"
PVE_IP=$(hostname -I | awk '{print $1}')
TMP_KNOWN_HOSTS=$(mktemp)
ssh-keyscan -H "$PVE_IP" > "$TMP_KNOWN_HOSTS" 2>/dev/null

pct push "$CT_ID" "$PRIV_KEY_PATH" "/home/${ADMIN_USER}/.ssh/id_ed25519"
pct push "$CT_ID" "$SSH_PUB_KEY_PATH" "/home/${ADMIN_USER}/.ssh/id_ed25519.pub"
pct push "$CT_ID" "$TMP_KNOWN_HOSTS" "/home/${ADMIN_USER}/.ssh/known_hosts"
rm -f "$TMP_KNOWN_HOSTS"

# 7.4 Finaliser authorized_keys et appliquer les permissions SSH strictes
pct exec "$CT_ID" -- bash -s "$ADMIN_USER" << 'EOF'
    set -e
    ADMIN_USER="$1"
    cp "/home/${ADMIN_USER}/.ssh/id_ed25519.pub" "/home/${ADMIN_USER}/.ssh/authorized_keys"
    chown -R "${ADMIN_USER}:${ADMIN_USER}" "/home/${ADMIN_USER}/.ssh"
    chmod 700 "/home/${ADMIN_USER}/.ssh"
    chmod 600 "/home/${ADMIN_USER}/.ssh/id_ed25519" "/home/${ADMIN_USER}/.ssh/authorized_keys" "/home/${ADMIN_USER}/.ssh/known_hosts"
    chmod 644 "/home/${ADMIN_USER}/.ssh/id_ed25519.pub"
EOF

# 7.5 Définir le mot de passe en interactif
echo "Veuillez définir le mot de passe pour '${ADMIN_USER}' :"
pct exec "$CT_ID" -- passwd "$ADMIN_USER"

echo "=============================================================================="
echo "Terminé ! Le conteneur '$CT_HOSTNAME' (ID: $CT_ID) est prêt."
echo "Connexion : ssh ${ADMIN_USER}@${CT_IP%/*}"
echo "=============================================================================="
