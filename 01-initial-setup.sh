#!/bin/bash
# =========================================================
# SCRIPT 1/6 — Sécurisation de base
# Ubuntu 24.04 — HTIC-NETWORKS
# Usage : sudo bash 01-initial-setup.sh
# =========================================================
set -euo pipefail

# Couleurs
G='\033[0;32m'; Y='\033[1;33m'; R='\033[0;31m'; C='\033[0;36m'; N='\033[0m'
ok()  { echo -e "${G}[OK]${N} $1"; }
err() { echo -e "${R}[ERREUR]${N} $1"; exit 1; }
inf() { echo -e "${C}----> $1${N}"; }

[ "$EUID" -ne 0 ] && err "Lance avec sudo : sudo bash $0"

# ─── Questions ────────────────────────────────────────────
echo ""
echo -e "${C}======================================${N}"
echo -e "${C}  HTIC-NETWORKS — Setup initial       ${N}"
echo -e "${C}======================================${N}"
echo ""

read -rp "Nom de l'utilisateur admin (ex: deploy) : " ADMIN_USER
read -rp "Port SSH (ex: 2222) : " SSH_PORT
echo "Colle ta clé publique SSH (contenu de ~/.ssh/id_ed25519.pub sur ton PC) :"
read -rp "> " SSH_KEY

[ -z "$ADMIN_USER" ] && err "Nom utilisateur requis"
[ -z "$SSH_PORT" ]   && err "Port SSH requis"
[ -z "$SSH_KEY" ]    && err "Clé SSH requise"

# ─── 1. Mise à jour système ───────────────────────────────
inf "Mise à jour du système..."
apt-get update -qq
apt-get upgrade -y -qq
apt-get install -y -qq \
  curl wget git htop unzip ufw fail2ban \
  build-essential pkg-config libssl-dev \
  ca-certificates gnupg lsb-release \
  logrotate cron net-tools
ok "Système à jour"

# ─── 1b. Swap (éviter OOM sur petites VM) ─────────────────
if ! swapon --show | grep -q "/swapfile"; then
  TOTAL_RAM_MB=$(free -m | awk '/^Mem:/{print $2}')
  # Swap = 2x RAM si RAM < 2GB, sinon 2GB fixe, min 1GB max 4GB
  if [ "$TOTAL_RAM_MB" -lt 2048 ]; then
    SWAP_SIZE_GB=2
  else
    SWAP_SIZE_GB=2
  fi
  inf "Création d'un swap de ${SWAP_SIZE_GB}GB (RAM détectée : ${TOTAL_RAM_MB}MB)..."
  fallocate -l ${SWAP_SIZE_GB}G /swapfile
  chmod 600 /swapfile
  mkswap /swapfile > /dev/null
  swapon /swapfile
  if ! grep -q "/swapfile" /etc/fstab; then
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
  fi
  # Tuning : swappiness bas pour favoriser la RAM
  echo "vm.swappiness=10" > /etc/sysctl.d/99-swap.conf
  sysctl -p /etc/sysctl.d/99-swap.conf > /dev/null
  ok "Swap ${SWAP_SIZE_GB}GB actif (swappiness=10)"
else
  ok "Swap déjà configuré"
fi

# ─── 2. Créer utilisateur admin ───────────────────────────
inf "Création de l'utilisateur $ADMIN_USER..."
if ! id "$ADMIN_USER" &>/dev/null; then
  useradd -m -s /bin/bash "$ADMIN_USER"
  usermod -aG sudo "$ADMIN_USER"
  # Sudo sans mot de passe
  echo "$ADMIN_USER ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/"$ADMIN_USER"
  chmod 0440 /etc/sudoers.d/"$ADMIN_USER"
  ok "Utilisateur $ADMIN_USER créé"
else
  ok "Utilisateur $ADMIN_USER existe déjà"
fi

# Ajouter la clé SSH
mkdir -p /home/"$ADMIN_USER"/.ssh
echo "$SSH_KEY" > /home/"$ADMIN_USER"/.ssh/authorized_keys
chmod 700  /home/"$ADMIN_USER"/.ssh
chmod 600  /home/"$ADMIN_USER"/.ssh/authorized_keys
chown -R "$ADMIN_USER":"$ADMIN_USER" /home/"$ADMIN_USER"/.ssh
ok "Clé SSH ajoutée pour $ADMIN_USER"

# ─── 3. Sécuriser SSH ────────────────────────────────────
inf "Configuration SSH..."
cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak

cat > /etc/ssh/sshd_config << EOF
Port $SSH_PORT
AddressFamily inet
ListenAddress 0.0.0.0

PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
PermitEmptyPasswords no

X11Forwarding no
AllowTcpForwarding no
MaxAuthTries 3
MaxSessions 5
LoginGraceTime 30

AllowUsers $ADMIN_USER

UsePAM yes
AcceptEnv LANG LC_*
Subsystem sftp /usr/lib/openssh/sftp-server
EOF

systemctl restart ssh
ok "SSH sécurisé sur le port $SSH_PORT"

# ─── 4. Firewall UFW ──────────────────────────────────────
inf "Configuration du firewall UFW..."
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow "$SSH_PORT"/tcp  comment "SSH"
ufw allow 80/tcp           comment "HTTP"
ufw allow 443/tcp          comment "HTTPS"
ufw --force enable
ok "UFW actif — ports ouverts : $SSH_PORT, 80, 443"

# ─── 5. Fail2ban ──────────────────────────────────────────
inf "Configuration Fail2ban..."
cat > /etc/fail2ban/jail.local << EOF
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 3

[sshd]
enabled  = true
port     = $SSH_PORT
maxretry = 3
bantime  = 24h
EOF

systemctl enable fail2ban
systemctl restart fail2ban
ok "Fail2ban actif"

# ─── 6. Structure des dossiers ────────────────────────────
inf "Création de la structure /opt..."
mkdir -p /opt/shared/{scripts,logs,backups}

# Créer les dossiers pour 3 apps possibles
for app in app1 app2 app3; do
  mkdir -p /opt/$app/{logs,tmp}
  # Créer un utilisateur système dédié par app
  if ! id "$app" &>/dev/null; then
    useradd -r -s /bin/false -d /opt/$app "$app"
  fi
  chown -R "$app":"$app" /opt/$app
done

ok "Dossiers /opt/app1, /opt/app2, /opt/app3 créés"

# ─── Résumé ───────────────────────────────────────────────
echo ""
echo -e "${G}============================================${N}"
echo -e "${G}  SCRIPT 1 TERMINÉ                         ${N}"
echo -e "${G}============================================${N}"
echo ""
echo "  Utilisateur admin : $ADMIN_USER"
echo "  Port SSH          : $SSH_PORT"
echo "  Firewall UFW      : actif"
echo "  Fail2ban          : actif"
echo ""
echo -e "${Y}IMPORTANT : Ouvre un NOUVEAU terminal et teste :${N}"
echo -e "${Y}  ssh -p $SSH_PORT $ADMIN_USER@<IP_SERVEUR>${N}"
echo -e "${Y}Ne ferme l'ancienne session qu'après confirmation !${N}"
echo ""
echo "Quand c'est bon → lance le script suivant :"
echo "  sudo bash 02-install-caddy.sh"
