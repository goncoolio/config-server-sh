#!/bin/bash
# =========================================================
# SCRIPT 2b — Ajouter/mettre à jour un site Caddy
# Ubuntu 24.04 — HTIC-NETWORKS
# Usage : sudo bash 02b-add-caddy-site.sh [domaine]
#
# Crée ou remplace un bloc Caddy pour un domaine donné.
# Types supportés : api | spa | static | laravel
# =========================================================
set -euo pipefail

G='\033[0;32m'; Y='\033[1;33m'; R='\033[0;31m'; C='\033[0;36m'; N='\033[0m'
ok()  { echo -e "${G}[OK]${N} $1"; }
warn(){ echo -e "${Y}[AVERT]${N} $1"; }
err() { echo -e "${R}[ERREUR]${N} $1"; exit 1; }
inf() { echo -e "${C}----> $1${N}"; }

[ "$EUID" -ne 0 ] && err "Lance avec sudo : sudo bash $0"
command -v caddy &>/dev/null || err "Caddy non installé. Lance d'abord 02-install-caddy.sh"

SITES_DIR="/etc/caddy/sites-enabled"
mkdir -p "$SITES_DIR"

echo ""
echo -e "${C}======================================${N}"
echo -e "${C}  HTIC-NETWORKS — Ajouter site Caddy  ${N}"
echo -e "${C}======================================${N}"
echo ""

# ─── État actuel (sites/apps existants) ───────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -f "$SCRIPT_DIR/00-list-apps.sh" ] && bash "$SCRIPT_DIR/00-list-apps.sh" --short
echo ""

# ─── Arguments / questions ────────────────────────────────
DOMAIN="${1:-}"
[ -z "$DOMAIN" ] && read -rp "Nom de domaine complet (ex: api.exemple.com) : " DOMAIN
[ -z "$DOMAIN" ] && err "Domaine obligatoire"

SITE_FILE="$SITES_DIR/${DOMAIN}.caddy"

if [ -f "$SITE_FILE" ]; then
  warn "Le site $DOMAIN existe déjà — il sera REMPLACÉ"
  read -rp "Continuer ? (oui/non) : " CONF
  [ "$CONF" != "oui" ] && { echo "Annulé."; exit 0; }
fi

echo ""
echo "Type de site :"
echo "  1) api      — Reverse proxy vers une API locale (Node, Rust, etc.)"
echo "  2) spa      — SPA (React/Vue/Next export) — fichiers statiques + fallback index.html"
echo "  3) static   — Site HTML/CSS statique"
echo "  4) laravel  — Site Laravel (PHP-FPM + Caddy)"
echo "  5) nextjs   — Next.js SSR (reverse proxy comme api)"
read -rp "Choix [1-5] : " TYPE_CHOICE

case "$TYPE_CHOICE" in
  1) SITE_TYPE="api" ;;
  2) SITE_TYPE="spa" ;;
  3) SITE_TYPE="static" ;;
  4) SITE_TYPE="laravel" ;;
  5) SITE_TYPE="nextjs" ;;
  *) err "Choix invalide" ;;
esac

# ─── Questions spécifiques au type ────────────────────────
UPSTREAM_PORT=""
DOC_ROOT=""
PHP_SOCK=""

case "$SITE_TYPE" in
  api|nextjs)
    read -rp "Port local de l'app (ex: 3001) : " UPSTREAM_PORT
    [ -z "$UPSTREAM_PORT" ] && err "Port obligatoire"
    ;;
  spa|static)
    read -rp "Chemin racine des fichiers (défaut: /var/www/$DOMAIN) : " DOC_ROOT
    DOC_ROOT="${DOC_ROOT:-/var/www/$DOMAIN}"
    mkdir -p "$DOC_ROOT"
    chown -R caddy:caddy "$DOC_ROOT"
    ;;
  laravel)
    read -rp "Chemin du dossier public Laravel (ex: /opt/monapp/current/public) : " DOC_ROOT
    [ -z "$DOC_ROOT" ] && err "Chemin obligatoire"
    # Détecter la version de PHP-FPM
    if [ -S /run/php/php8.3-fpm.sock ]; then
      PHP_SOCK="unix//run/php/php8.3-fpm.sock"
    elif [ -S /run/php/php8.2-fpm.sock ]; then
      PHP_SOCK="unix//run/php/php8.2-fpm.sock"
    else
      err "Aucun PHP-FPM détecté. Installe PHP via 02-install-caddy.sh"
    fi
    ;;
esac

# ─── Auth basic (optionnelle) ─────────────────────────────
AUTH_BLOCK=""
read -rp "Protéger par Basic Auth ? (oui/non, défaut: non) : " AUTH_CHOICE
if [ "$AUTH_CHOICE" = "oui" ]; then
  read -rp "  Identifiant : " AUTH_USER
  read -rsp "  Mot de passe : " AUTH_PASS
  echo ""
  HASH=$(caddy hash-password --plaintext "$AUTH_PASS")
  AUTH_BLOCK=$(cat << EOF

    basicauth /* {
        $AUTH_USER $HASH
    }
EOF
)
fi

# ─── Génération du fichier de site ────────────────────────
LOG_NAME=$(echo "$DOMAIN" | tr '.' '_')

inf "Génération de $SITE_FILE..."

case "$SITE_TYPE" in
  api|nextjs)
    cat > "$SITE_FILE" << EOF
# Site $DOMAIN — type: $SITE_TYPE — généré le $(date)
$DOMAIN {
    import security-headers
    import site-log $LOG_NAME
    encode gzip zstd
$AUTH_BLOCK

    reverse_proxy localhost:$UPSTREAM_PORT {
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-For {remote_host}
        header_up X-Forwarded-Proto {scheme}
        header_up Host {host}
    }
}
EOF
    ;;

  spa)
    cat > "$SITE_FILE" << EOF
# Site $DOMAIN — type: spa — généré le $(date)
$DOMAIN {
    import security-headers
    import site-log $LOG_NAME
    encode gzip zstd
$AUTH_BLOCK

    root * $DOC_ROOT
    try_files {path} /index.html
    file_server
}
EOF
    ;;

  static)
    cat > "$SITE_FILE" << EOF
# Site $DOMAIN — type: static — généré le $(date)
$DOMAIN {
    import security-headers
    import site-log $LOG_NAME
    encode gzip zstd
$AUTH_BLOCK

    root * $DOC_ROOT
    file_server
}
EOF
    ;;

  laravel)
    cat > "$SITE_FILE" << EOF
# Site $DOMAIN — type: laravel — généré le $(date)
$DOMAIN {
    import security-headers
    import site-log $LOG_NAME
    encode gzip zstd
$AUTH_BLOCK

    root * $DOC_ROOT
    php_fastcgi $PHP_SOCK
    file_server
}
EOF
    ;;
esac

chmod 644 "$SITE_FILE"
ok "Fichier site créé"

# ─── Valider et recharger Caddy ───────────────────────────
if ! caddy validate --config /etc/caddy/Caddyfile; then
  err "Caddyfile invalide — $SITE_FILE à corriger"
fi
ok "Caddyfile valide"

systemctl reload caddy
ok "Caddy rechargé"

# ─── Résumé ───────────────────────────────────────────────
echo ""
echo -e "${G}============================================${N}"
echo -e "${G}  Site $DOMAIN configuré                   ${N}"
echo -e "${G}============================================${N}"
echo ""
echo "  Type     : $SITE_TYPE"
case "$SITE_TYPE" in
  api|nextjs)  echo "  Upstream : localhost:$UPSTREAM_PORT" ;;
  spa|static)  echo "  Racine   : $DOC_ROOT" ;;
  laravel)     echo "  Racine   : $DOC_ROOT (PHP-FPM : $PHP_SOCK)" ;;
esac
echo "  Fichier  : $SITE_FILE"
echo "  Logs     : /var/log/caddy/${LOG_NAME}.log"
echo ""
echo -e "${Y}Certificat SSL obtenu automatiquement au premier accès à https://$DOMAIN${N}"
echo ""
echo "Pour supprimer : sudo rm $SITE_FILE && sudo systemctl reload caddy"
echo "Pour modifier  : sudo nano $SITE_FILE && sudo systemctl reload caddy"
echo "                 ou relance : sudo bash 02b-add-caddy-site.sh $DOMAIN"
