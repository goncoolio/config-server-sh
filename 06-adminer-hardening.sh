#!/bin/bash
# =========================================================
# SCRIPT 6/6 — Adminer + Hardening final
# Ubuntu 24.04 — HTIC-NETWORKS
# Usage : sudo bash 06-adminer-hardening.sh
# =========================================================
set -euo pipefail

G='\033[0;32m'; Y='\033[1;33m'; R='\033[0;31m'; C='\033[0;36m'; N='\033[0m'
ok()  { echo -e "${G}[OK]${N} $1"; }
warn(){ echo -e "${Y}[AVERT]${N} $1"; }
err() { echo -e "${R}[ERREUR]${N} $1"; exit 1; }
inf() { echo -e "${C}----> $1${N}"; }
chk() { echo -e "  ${G}✔${N} $1"; }
nok() { echo -e "  ${R}✘${N} $1"; }

[ "$EUID" -ne 0 ] && err "Lance avec sudo : sudo bash $0"

echo ""
echo -e "${C}======================================${N}"
echo -e "${C}  HTIC-NETWORKS — Finalisation        ${N}"
echo -e "${C}======================================${N}"
echo ""

# ─── 1. Installer Adminer ────────────────────────────────
inf "Installation d'Adminer (interface web PostgreSQL)..."
apt-get install -y -qq php-cli php-pgsql php-mbstring php-json

ADMINER_DIR="/opt/adminer"
mkdir -p "$ADMINER_DIR"

curl -fsSL \
  "https://github.com/vrana/adminer/releases/download/v4.8.1/adminer-4.8.1-postgresql.php" \
  -o "$ADMINER_DIR/index.php"

# Utilisateur dédié
if ! id adminer &>/dev/null; then
  useradd -r -s /bin/false -d "$ADMINER_DIR" adminer
fi
chown -R adminer:adminer "$ADMINER_DIR"

# Service systemd pour Adminer
cat > /etc/systemd/system/adminer.service << 'EOF'
[Unit]
Description=Adminer — Interface PostgreSQL
After=network.target postgresql.service

[Service]
Type=simple
User=adminer
Group=adminer
WorkingDirectory=/opt/adminer
ExecStart=/usr/bin/php -S 127.0.0.1:8080 -t /opt/adminer
Restart=on-failure
NoNewPrivileges=true
ProtectSystem=strict
ReadWritePaths=/opt/adminer
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable adminer
systemctl start adminer
ok "Adminer démarré sur localhost:8080"

# ─── 2. Hardening réseau (sysctl) ────────────────────────
inf "Hardening réseau kernel..."
cat > /etc/sysctl.d/99-htic.conf << 'EOF'
# HTIC-NETWORKS — Hardening
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 2048
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.conf.all.log_martians = 1
net.ipv4.tcp_fin_timeout = 15
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
EOF
sysctl -p /etc/sysctl.d/99-htic.conf > /dev/null
ok "Paramètres réseau appliqués"

# ─── 3. Mises à jour automatiques de sécurité ────────────
inf "Activation des mises à jour sécurité automatiques..."
apt-get install -y -qq unattended-upgrades

cat > /etc/apt/apt.conf.d/20auto-upgrades << 'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF

systemctl enable unattended-upgrades
ok "Mises à jour sécurité automatiques activées"

# ─── 4. Sauvegardes PostgreSQL automatiques ───────────────
inf "Configuration des sauvegardes PostgreSQL..."
mkdir -p /opt/shared/{backups,logs}
chown postgres:postgres /opt/shared/backups

cat > /opt/shared/scripts/pg-backup.sh << 'BACKUP'
#!/bin/bash
# Sauvegarde PostgreSQL quotidienne — HTIC-NETWORKS
BACKUP_DIR="/opt/shared/backups"
DATE=$(date +%Y%m%d_%H%M)
RETENTION=7  # jours

DBS=$(sudo -u postgres psql -t -c \
  "SELECT datname FROM pg_database WHERE datistemplate=false AND datname != 'postgres';" \
  | tr -d ' ' | grep -v '^$')

for DB in $DBS; do
  FILE="$BACKUP_DIR/${DB}_${DATE}.sql.gz"
  sudo -u postgres pg_dump "$DB" | gzip > "$FILE"
  chmod 600 "$FILE"
  echo "[$(date)] Backup $DB → $(du -sh "$FILE" | cut -f1)"
done

# Supprimer les sauvegardes de plus de $RETENTION jours
find "$BACKUP_DIR" -name "*.sql.gz" -mtime +$RETENTION -delete
echo "[$(date)] Nettoyage : anciennes sauvegardes supprimées"
BACKUP

chmod +x /opt/shared/scripts/pg-backup.sh

# Cron : tous les jours à 3h du matin
(crontab -l 2>/dev/null | grep -v pg-backup; \
  echo "0 3 * * * /opt/shared/scripts/pg-backup.sh >> /opt/shared/logs/pg-backup.log 2>&1") \
  | crontab -
ok "Sauvegardes PostgreSQL : quotidien à 3h → /opt/shared/backups"

# ─── 5. Commande server-status ───────────────────────────
inf "Création de la commande server-status..."
cat > /usr/local/bin/server-status << 'STATUS'
#!/bin/bash
C='\033[0;36m'; G='\033[0;32m'; R='\033[0;31m'; Y='\033[1;33m'; N='\033[0m'

echo -e "${C}════════════════════════════════════════${N}"
echo -e "${C}  HTIC-NETWORKS — Statut Serveur        ${N}"
echo -e "${C}  $(date)                               ${N}"
echo -e "${C}════════════════════════════════════════${N}"

echo -e "\n${Y}Ressources :${N}"
echo "  RAM   : $(free -h | awk '/Mem/ {print $3"/"$2}')"
echo "  Disque: $(df -h / | awk 'NR==2{print $3"/"$2" ("$5")"}')"
LOAD=$(uptime | awk -F'load average:' '{print $2}')
echo "  Charge: $LOAD"

echo -e "\n${Y}Services :${N}"
for SVC in caddy postgresql fail2ban adminer unattended-upgrades; do
  if systemctl is-active --quiet "$SVC" 2>/dev/null; then
    echo -e "  ${G}✔${N} $SVC"
  else
    echo -e "  ${R}✘${N} $SVC"
  fi
done

echo -e "\n${Y}Apps déployées :${N}"
for DIR in /opt/*/; do
  APP=$(basename "$DIR")
  [[ "$APP" =~ ^(adminer|shared)$ ]] && continue
  if systemctl is-active --quiet "$APP" 2>/dev/null; then
    PORT=$(grep -oP 'PORT=\K[0-9]+' "$DIR/.env" 2>/dev/null || echo "?")
    echo -e "  ${G}✔${N} $APP  (port: $PORT)"
  else
    echo -e "  ${R}✘${N} $APP  (inactif)"
  fi
done

echo -e "\n${Y}Connexions PostgreSQL :${N}"
sudo -u postgres psql -t -c \
  "SELECT datname||': '||count(*)||' connexions' FROM pg_stat_activity WHERE datname IS NOT NULL GROUP BY datname;" \
  2>/dev/null | grep -v '^$' | sed 's/^/  /'

echo -e "\n${Y}Ports en écoute :${N}"
ss -tlnp | awk 'NR>1{print "  "$4}' | sort
echo ""
STATUS

chmod +x /usr/local/bin/server-status
ok "Commande 'server-status' disponible"

# ─── 6. MOTD ──────────────────────────────────────────────
cat > /etc/motd << 'MOTD'

  ╔══════════════════════════════════════╗
  ║     HTIC-NETWORKS — Serveur API      ║
  ║     Ubuntu 24.04 — Accès restreint   ║
  ╚══════════════════════════════════════╝
  → Tape 'server-status' pour le statut

MOTD

# ─── 7. Vérification globale ─────────────────────────────
echo ""
echo -e "${C}── Vérification de sécurité ──────────────${N}"

# SSH
if grep -q "PermitRootLogin no" /etc/ssh/sshd_config; then
  chk "Root login SSH désactivé"
else
  nok "Root login SSH encore actif !"
fi

if grep -q "PasswordAuthentication no" /etc/ssh/sshd_config; then
  chk "Auth par mot de passe SSH désactivée"
else
  nok "Auth par mot de passe SSH encore active !"
fi

# UFW
if ufw status | grep -q "Status: active"; then
  chk "UFW actif"
else
  nok "UFW inactif !"
fi

# PostgreSQL pas exposé
if ss -tlnp | grep -q "5432" && ss -tlnp | grep "5432" | grep -qv "127.0.0.1"; then
  nok "PostgreSQL exposé sur l'extérieur !"
else
  chk "PostgreSQL non exposé sur l'extérieur"
fi

# Caddy
if systemctl is-active --quiet caddy; then
  chk "Caddy actif"
else
  nok "Caddy inactif !"
fi

# Fail2ban
if systemctl is-active --quiet fail2ban; then
  chk "Fail2ban actif"
else
  nok "Fail2ban inactif !"
fi

# Adminer
if systemctl is-active --quiet adminer; then
  chk "Adminer actif sur localhost:8080"
else
  nok "Adminer inactif"
fi

# ─── Résumé final ─────────────────────────────────────────
echo ""
echo -e "${G}============================================${N}"
echo -e "${G}  INSTALLATION TERMINÉE !                  ${N}"
echo -e "${G}============================================${N}"
echo ""
echo "  Reverse proxy : Caddy (HTTPS auto)"
echo "  Base de données : PostgreSQL 16"
echo "  Admin DB : Adminer → https://<ton-sous-domaine-admin>"
echo "  Sauvegardes : quotidien 3h → /opt/shared/backups"
echo "  Mises à jour sécurité : automatique"
echo ""
echo -e "${C}Commandes du quotidien :${N}"
echo "  server-status                    # statut global"
echo "  journalctl -u <app> -f           # logs d'une app"
echo "  sudo -u postgres psql            # console PostgreSQL"
echo "  sudo bash /opt/shared/scripts/pg-backup.sh   # backup manuel"
echo ""
echo -e "${Y}Prochaines étapes :${N}"
echo "  1. Vérifier que tes DNS pointent vers ce serveur"
echo "  2. Déployer tes apps via /opt/shared/scripts/deploy-<app>.sh"
echo "  3. Accéder à Adminer via ton sous-domaine admin"
