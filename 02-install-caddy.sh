#!/bin/bash
# =========================================================
# SCRIPT 2/6 — Installation Caddy (reverse proxy HTTPS)
# Ubuntu 24.04 — HTIC-NETWORKS
# Usage : sudo bash 02-install-caddy.sh
#
# Installe Caddy uniquement. Les sites s'ajoutent ensuite
# via le script 02b-add-caddy-site.sh.
# =========================================================
set -euo pipefail

G='\033[0;32m'; Y='\033[1;33m'; R='\033[0;31m'; C='\033[0;36m'; N='\033[0m'
ok()  { echo -e "${G}[OK]${N} $1"; }
warn(){ echo -e "${Y}[AVERT]${N} $1"; }
err() { echo -e "${R}[ERREUR]${N} $1"; exit 1; }
inf() { echo -e "${C}----> $1${N}"; }

[ "$EUID" -ne 0 ] && err "Lance avec sudo : sudo bash $0"

echo ""
echo -e "${C}======================================${N}"
echo -e "${C}  HTIC-NETWORKS — Installation Caddy  ${N}"
echo -e "${C}======================================${N}"
echo ""

# ─── 1. Installer Caddy (si pas déjà fait) ────────────────
if ! command -v caddy &>/dev/null; then
  inf "Installation de Caddy..."
  apt-get install -y -qq debian-keyring debian-archive-keyring apt-transport-https

  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
    | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg

  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
    | tee /etc/apt/sources.list.d/caddy-stable.list

  apt-get update -qq
  apt-get install -y caddy
  ok "Caddy installé : $(caddy version)"
else
  ok "Caddy déjà installé : $(caddy version)"
fi

# ─── 2. Installer PHP-FPM (pour Laravel) ──────────────────
if ! command -v php-fpm8.3 &>/dev/null && ! command -v php-fpm8.2 &>/dev/null; then
  inf "Installation de PHP 8.3 + FPM (pour futures apps Laravel)..."
  apt-get install -y -qq software-properties-common
  add-apt-repository -y ppa:ondrej/php
  apt-get update -qq
  apt-get install -y php8.3-fpm php8.3-cli php8.3-mbstring php8.3-xml \
    php8.3-curl php8.3-zip php8.3-bcmath php8.3-intl php8.3-pgsql php8.3-mysql \
    php8.3-gd php8.3-redis composer
  systemctl enable --now php8.3-fpm
  ok "PHP 8.3-FPM installé"
else
  ok "PHP-FPM déjà présent"
fi

# ─── 3. Structure des répertoires Caddy ───────────────────
inf "Préparation de la structure Caddy..."
mkdir -p /etc/caddy/sites-enabled
mkdir -p /etc/caddy/snippets
mkdir -p /var/log/caddy
chown caddy:caddy /var/log/caddy

# ─── 4. Snippets réutilisables ────────────────────────────
cat > /etc/caddy/snippets/security-headers.caddy << 'EOF'
(security-headers) {
    header {
        Strict-Transport-Security "max-age=31536000; includeSubDomains; preload"
        X-Content-Type-Options nosniff
        X-Frame-Options DENY
        Referrer-Policy strict-origin-when-cross-origin
        Permissions-Policy "camera=(), microphone=(), geolocation=()"
        -Server
    }
}
EOF

cat > /etc/caddy/snippets/logging.caddy << 'EOF'
(site-log) {
    log {
        output file /var/log/caddy/{args[0]}.log {
            roll_size 50MiB
            roll_keep 10
        }
        format json
    }
}
EOF

# ─── 5. Caddyfile principal ───────────────────────────────
# Idempotent : on écrase uniquement si absent, sinon on préserve
if [ ! -f /etc/caddy/Caddyfile ] || ! grep -q "sites-enabled" /etc/caddy/Caddyfile 2>/dev/null; then
  inf "Génération du Caddyfile principal..."
  cat > /etc/caddy/Caddyfile << 'EOF'
# Caddyfile principal — HTIC-NETWORKS
# Les sites individuels sont dans /etc/caddy/sites-enabled/*.caddy
# Ajoute/modifie un site via : sudo bash 02b-add-caddy-site.sh

{
    # Options globales
    email admin@localhost
    admin off
}

# Importer les snippets réutilisables
import /etc/caddy/snippets/*.caddy

# Importer tous les sites activés
import /etc/caddy/sites-enabled/*.caddy
EOF
  ok "Caddyfile principal créé"
else
  ok "Caddyfile principal déjà présent (conservé)"
fi

# ─── 6. Demander l'email Let's Encrypt ────────────────────
read -rp "Email pour Let's Encrypt (certificats SSL) : " LE_EMAIL
if [ -n "$LE_EMAIL" ]; then
  sed -i "s|email admin@localhost|email $LE_EMAIL|" /etc/caddy/Caddyfile
  ok "Email Let's Encrypt : $LE_EMAIL"
fi

# ─── 7. Valider et démarrer ───────────────────────────────
caddy validate --config /etc/caddy/Caddyfile && ok "Caddyfile valide"
systemctl enable caddy
systemctl restart caddy
ok "Caddy démarré"

# ─── Résumé ───────────────────────────────────────────────
echo ""
echo -e "${G}============================================${N}"
echo -e "${G}  SCRIPT 2 TERMINÉ                         ${N}"
echo -e "${G}============================================${N}"
echo ""
echo "Caddy est installé, aucun site configuré pour l'instant."
echo ""
echo -e "${Y}Pour ajouter un site :${N}"
echo "  sudo bash 02b-add-caddy-site.sh"
echo ""
echo "Structure :"
echo "  /etc/caddy/Caddyfile               # config principale"
echo "  /etc/caddy/sites-enabled/*.caddy   # un fichier par site"
echo "  /etc/caddy/snippets/*.caddy        # snippets réutilisables"
echo "  /var/log/caddy/                    # logs par site"
echo ""
echo "Étape suivante → sudo bash 03-install-postgresql.sh"
