#!/bin/bash
# =========================================================
# SCRIPT 5c — Déployer une app Laravel (PHP-FPM + Caddy)
# Ubuntu 24.04 — HTIC-NETWORKS
# Usage : sudo bash 05c-deploy-laravel.sh
#
# Idempotent : relance sur une app existante pour mettre à jour.
# =========================================================
set -euo pipefail

G='\033[0;32m'; Y='\033[1;33m'; R='\033[0;31m'; C='\033[0;36m'; N='\033[0m'
ok()  { echo -e "${G}[OK]${N} $1"; }
warn(){ echo -e "${Y}[AVERT]${N} $1"; }
err() { echo -e "${R}[ERREUR]${N} $1"; exit 1; }
inf() { echo -e "${C}----> $1${N}"; }

[ "$EUID" -ne 0 ] && err "Lance avec sudo : sudo bash $0"

echo ""
echo -e "${C}===============================================${N}"
echo -e "${C}  HTIC-NETWORKS — Déployer App Laravel        ${N}"
echo -e "${C}===============================================${N}"
echo ""

# ─── État actuel du serveur (collisions de noms/ports) ────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -f "$SCRIPT_DIR/00-list-apps.sh" ] && bash "$SCRIPT_DIR/00-list-apps.sh" --short
echo ""

# ─── Vérifier PHP-FPM ─────────────────────────────────────
if command -v php-fpm8.3 &>/dev/null; then
  PHP_VERSION="8.3"
elif command -v php-fpm8.2 &>/dev/null; then
  PHP_VERSION="8.2"
else
  err "PHP-FPM non installé. Relance 02-install-caddy.sh"
fi
PHP_SOCK="unix//run/php/php${PHP_VERSION}-fpm.sock"
ok "PHP $PHP_VERSION détecté"

# ─── Questions ────────────────────────────────────────────
read -rp "Nom de l'app (ex: monsite) : " APP_NAME
[ -z "$APP_NAME" ] && err "Nom obligatoire"

APP_DIR="/opt/$APP_NAME"
IS_UPDATE=false
[ -d "$APP_DIR" ] && IS_UPDATE=true
$IS_UPDATE && warn "App $APP_NAME existe → MISE À JOUR de la config"

read -rp "APP_KEY Laravel (format base64:..., laisse vide pour générer plus tard) : " APP_KEY
read -rp "APP_URL (ex: https://monsite.com) : " APP_URL
read -rp "DATABASE_URL OU DB_CONNECTION + DB_HOST... (laisse vide pour configurer plus tard) : " DB_URL

echo ""
echo "Dossiers à PRÉSERVER en plus de storage/ et bootstrap/cache/ (déjà gérés)"
echo "Stockés dans /opt/$APP_NAME/shared/<dossier>/ et symlinkés à chaque deploy."
echo "Format : un par ligne, ligne vide pour terminer"
echo "Exemples : public/uploads, public/storage, public/files, .env.backup"
PERSISTENT_DIRS=()
while true; do
  read -rp "  > " LINE
  [ -z "$LINE" ] && break
  PERSISTENT_DIRS+=("$LINE")
done

echo ""
echo "Variables d'env supplémentaires (format: CLE=VALEUR, ligne vide pour finir)"
ENV_EXTRAS=()
while true; do
  read -rp "  > " LINE
  [ -z "$LINE" ] && break
  ENV_EXTRAS+=("$LINE")
done

read -rp "Configurer un domaine Caddy maintenant ? (oui/non) : " SETUP_CADDY
CADDY_DOMAIN=""
if [ "$SETUP_CADDY" = "oui" ]; then
  read -rp "  Domaine complet (ex: monsite.com) : " CADDY_DOMAIN
fi

RELEASES_DIR="$APP_DIR/releases"
CURRENT_LINK="$APP_DIR/current"
SHARED_DIR="$APP_DIR/shared"
ENV_FILE="$SHARED_DIR/.env"

# ─── 1. Utilisateur système ───────────────────────────────
# Laravel tourne sous www-data (compatible PHP-FPM standard)
if ! id "$APP_NAME" &>/dev/null; then
  useradd -r -s /bin/bash -d "$APP_DIR" -g www-data -c "Service $APP_NAME" "$APP_NAME"
  ok "Utilisateur $APP_NAME créé (groupe www-data)"
else
  ok "Utilisateur $APP_NAME existe"
fi

# ─── 2. Structure ─────────────────────────────────────────
inf "Préparation de $APP_DIR..."
mkdir -p "$RELEASES_DIR" "$SHARED_DIR/storage" "$SHARED_DIR/bootstrap/cache" "$APP_DIR/logs"
chown -R "$APP_NAME":www-data "$APP_DIR"
chmod 750 "$APP_DIR"
chmod -R 775 "$SHARED_DIR/storage" "$SHARED_DIR/bootstrap"
ok "Structure prête (releases/ shared/storage shared/bootstrap/cache)"

# ─── 2b. Dossiers persistants additionnels (uploads, etc.) ─
if [ ${#PERSISTENT_DIRS[@]} -gt 0 ]; then
  inf "Création des dossiers persistants additionnels..."
  for D in "${PERSISTENT_DIRS[@]}"; do
    PERSIST_PATH="$SHARED_DIR/$D"
    if [ ! -d "$PERSIST_PATH" ]; then
      mkdir -p "$PERSIST_PATH"
      chown -R "$APP_NAME":www-data "$PERSIST_PATH"
      chmod -R 775 "$PERSIST_PATH"
      ok "  shared/$D créé"
    else
      ok "  shared/$D existe (préservé)"
    fi
  done
fi

# ─── 3. Fichier .env ──────────────────────────────────────
inf "Génération de $ENV_FILE..."
{
  echo "# Laravel $APP_NAME — $(date)"
  echo "APP_NAME=$APP_NAME"
  echo "APP_ENV=production"
  echo "APP_DEBUG=false"
  echo "APP_KEY=$APP_KEY"
  echo "APP_URL=$APP_URL"
  echo ""
  echo "LOG_CHANNEL=stack"
  echo "LOG_LEVEL=warning"
  echo ""
  [ -n "$DB_URL" ] && echo "DATABASE_URL=$DB_URL"
  echo ""
  for VAR in "${ENV_EXTRAS[@]}"; do
    echo "$VAR"
  done
} > "$ENV_FILE"
chown "$APP_NAME":www-data "$ENV_FILE"
chmod 640 "$ENV_FILE"
ok ".env créé"

# ─── 4. Script de déploiement ─────────────────────────────
mkdir -p /opt/shared/scripts
DEPLOY_SCRIPT="/opt/shared/scripts/deploy-$APP_NAME.sh"

cat > "$DEPLOY_SCRIPT" << DEPLOYEOF
#!/bin/bash
# Déployer une nouvelle version de $APP_NAME (Laravel)
# Usage : sudo bash $DEPLOY_SCRIPT <source_dir>
# <source_dir> = dossier Laravel complet (le même que tu develop en local)
set -euo pipefail

SRC=\${1:-""}
[ -z "\$SRC" ] && { echo "Usage: \$0 <source_dir>"; exit 1; }
[ ! -d "\$SRC" ] && { echo "Dossier introuvable: \$SRC"; exit 1; }
[ ! -f "\$SRC/artisan" ] && { echo "artisan absent → pas un projet Laravel"; exit 1; }

APP_NAME="$APP_NAME"
APP_DIR="$APP_DIR"
RELEASES_DIR="\$APP_DIR/releases"
CURRENT_LINK="\$APP_DIR/current"
SHARED_DIR="\$APP_DIR/shared"

TS=\$(date +%Y%m%d_%H%M%S)
NEW_RELEASE="\$RELEASES_DIR/\$TS"

echo "→ Création de \$NEW_RELEASE"
mkdir -p "\$NEW_RELEASE"
cp -a "\$SRC"/. "\$NEW_RELEASE"/

# Liens symboliques vers shared (données persistantes entre releases)
rm -rf "\$NEW_RELEASE/storage" "\$NEW_RELEASE/bootstrap/cache"
ln -sfn "\$SHARED_DIR/storage" "\$NEW_RELEASE/storage"
ln -sfn "\$SHARED_DIR/bootstrap/cache" "\$NEW_RELEASE/bootstrap/cache"
ln -sfn "\$SHARED_DIR/.env" "\$NEW_RELEASE/.env"

# Dossiers persistants additionnels (uploads utilisateurs, etc.)
PERSISTENT_DIRS_RAW="$(printf '%s\n' "${PERSISTENT_DIRS[@]:-}")"
if [ -n "\$PERSISTENT_DIRS_RAW" ]; then
  echo "→ Symlinks dossiers persistants additionnels..."
  while IFS= read -r D; do
    [ -z "\$D" ] && continue
    SHARED_PATH="\$SHARED_DIR/\$D"
    REL_PATH="\$NEW_RELEASE/\$D"
    if [ ! -d "\$SHARED_PATH" ]; then
      mkdir -p "\$SHARED_PATH"
      chown -R \$APP_NAME:www-data "\$SHARED_PATH"
      chmod -R 775 "\$SHARED_PATH"
    fi
    # Migrer le contenu de la première release dans shared/ si shared est vide
    if [ -d "\$REL_PATH" ] && [ ! -L "\$REL_PATH" ]; then
      if [ -z "\$(ls -A "\$SHARED_PATH" 2>/dev/null)" ]; then
        echo "    → Migration initiale : \$REL_PATH → shared/"
        cp -a "\$REL_PATH"/. "\$SHARED_PATH"/ 2>/dev/null || true
        chown -R \$APP_NAME:www-data "\$SHARED_PATH"
      fi
      rm -rf "\$REL_PATH"
    fi
    mkdir -p "\$(dirname "\$REL_PATH")"
    ln -sfn "\$SHARED_PATH" "\$REL_PATH"
    echo "    \$D → shared/\$D"
  done <<< "\$PERSISTENT_DIRS_RAW"
fi

chown -R \$APP_NAME:www-data "\$NEW_RELEASE"

echo "→ Composer install --no-dev..."
su -s /bin/bash \$APP_NAME -c "cd \$NEW_RELEASE && composer install --no-dev --optimize-autoloader --no-interaction"

echo "→ Caches Laravel..."
su -s /bin/bash \$APP_NAME -c "cd \$NEW_RELEASE && php artisan config:cache && php artisan route:cache && php artisan view:cache"

echo "→ Migrations DB..."
su -s /bin/bash \$APP_NAME -c "cd \$NEW_RELEASE && php artisan migrate --force"

echo "→ Bascule du symlink current"
ln -sfn "\$NEW_RELEASE" "\$CURRENT_LINK"
chown -h \$APP_NAME:www-data "\$CURRENT_LINK"

echo "→ Reload PHP-FPM (zero-downtime)..."
systemctl reload php${PHP_VERSION}-fpm

echo "→ Purge des vieilles releases (garde 5)..."
cd "\$RELEASES_DIR"
ls -1t | tail -n +6 | xargs -r rm -rf

echo ""
echo "✓ Déploiement terminé — release \$TS active"
echo "  Rollback : sudo ln -sfn \$RELEASES_DIR/<ancien> \$CURRENT_LINK && sudo systemctl reload php${PHP_VERSION}-fpm"
DEPLOYEOF

chmod +x "$DEPLOY_SCRIPT"
ok "Script de déploiement : $DEPLOY_SCRIPT"

# ─── 5. Caddy (optionnel) ─────────────────────────────────
if [ -n "$CADDY_DOMAIN" ]; then
  inf "Configuration Caddy pour $CADDY_DOMAIN..."
  SITE_FILE="/etc/caddy/sites-enabled/${CADDY_DOMAIN}.caddy"
  LOG_NAME=$(echo "$CADDY_DOMAIN" | tr '.' '_')

  cat > "$SITE_FILE" << EOF
# Site $CADDY_DOMAIN → Laravel $APP_NAME — généré le $(date)
$CADDY_DOMAIN {
    import security-headers
    import site-log $LOG_NAME
    encode gzip zstd

    root * $CURRENT_LINK/public
    php_fastcgi $PHP_SOCK
    file_server
}
EOF
  if caddy validate --config /etc/caddy/Caddyfile 2>/dev/null; then
    systemctl reload caddy
    ok "Caddy : https://$CADDY_DOMAIN → Laravel $APP_NAME"
  else
    warn "Caddyfile invalide, vérifie $SITE_FILE"
  fi
fi

# ─── 6. Queue worker systemd (optionnel) ──────────────────
read -rp "Activer un worker de queue Laravel ? (oui/non) : " USE_QUEUE
if [ "$USE_QUEUE" = "oui" ]; then
  cat > "/etc/systemd/system/$APP_NAME-queue.service" << EOF
[Unit]
Description=$APP_NAME — Laravel Queue Worker
After=network.target

[Service]
Type=simple
User=$APP_NAME
Group=www-data
WorkingDirectory=$CURRENT_LINK
ExecStart=/usr/bin/php artisan queue:work --sleep=3 --tries=3 --timeout=90
Restart=always
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable "$APP_NAME-queue"
  ok "Service queue $APP_NAME-queue activé (démarre après 1er deploy)"
fi

# ─── Résumé ───────────────────────────────────────────────
echo ""
echo -e "${G}===============================================${N}"
echo -e "${G}  $APP_NAME (Laravel) configuré                ${N}"
echo -e "${G}===============================================${N}"
echo ""
echo "  Dossier       : $APP_DIR"
echo "  PHP           : $PHP_VERSION (FPM)"
echo "  Utilisateur   : $APP_NAME (groupe www-data)"
echo "  Env           : $ENV_FILE"
echo "  Storage       : $SHARED_DIR/storage (partagé entre releases)"
[ -n "$CADDY_DOMAIN" ] && echo "  URL publique  : https://$CADDY_DOMAIN"
echo ""
echo -e "${Y}Pour déployer :${N}"
echo "  # Sur ta machine de dev :"
echo "  rsync -av --exclude node_modules --exclude .git . admin@<IP>:/tmp/$APP_NAME/"
echo ""
echo "  # Sur le serveur :"
echo "  sudo bash $DEPLOY_SCRIPT /tmp/$APP_NAME"
echo ""
if [ -z "$APP_KEY" ]; then
  echo -e "${Y}⚠ APP_KEY vide — après premier deploy :${N}"
  echo "  sudo -u $APP_NAME php $CURRENT_LINK/artisan key:generate --show"
  echo "  puis mets la valeur dans $ENV_FILE"
  echo ""
fi
echo "Commandes utiles :"
echo "  sudo -u $APP_NAME php $CURRENT_LINK/artisan <commande>"
echo "  tail -f $SHARED_DIR/storage/logs/laravel.log"
echo "  systemctl reload php${PHP_VERSION}-fpm"
