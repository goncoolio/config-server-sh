#!/bin/bash
# =========================================================
# SCRIPT 5b — Déployer une app Rust (systemd)
# Ubuntu 24.04 — HTIC-NETWORKS
# Usage : sudo bash 05b-deploy-rust.sh
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
echo -e "${C}======================================${N}"
echo -e "${C}  HTIC-NETWORKS — Déployer App Rust   ${N}"
echo -e "${C}======================================${N}"
echo ""

# ─── État actuel du serveur (collisions de noms/ports) ────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -f "$SCRIPT_DIR/00-list-apps.sh" ] && bash "$SCRIPT_DIR/00-list-apps.sh" --short
echo ""

# ─── Questions ────────────────────────────────────────────
read -rp "Nom de l'app (ex: sosagri-api) : " APP_NAME
[ -z "$APP_NAME" ] && err "Nom obligatoire"

APP_DIR="/opt/$APP_NAME"
IS_UPDATE=false
[ -d "$APP_DIR" ] && IS_UPDATE=true
$IS_UPDATE && warn "App $APP_NAME existe → MISE À JOUR de la config"

read -rp "Nom du binaire compilé (défaut: $APP_NAME) : " BINARY_NAME
BINARY_NAME="${BINARY_NAME:-$APP_NAME}"

read -rp "Port d'écoute local (ex: 3001) : " APP_PORT
[ -z "$APP_PORT" ] && err "Port obligatoire"

read -rp "DATABASE_URL (laisse vide pour ignorer) : " DB_URL

echo ""
echo "Dossiers à PRÉSERVER entre les releases (uploads, fichiers utilisateurs, etc.)"
echo "Stockés dans /opt/$APP_NAME/shared/<dossier>/ et symlinkés à chaque deploy."
echo "Format : un par ligne (chemin relatif à current/), ligne vide pour terminer"
echo "Exemples : uploads, data, attachments"
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

echo ""
echo "Commande de migration DB à exécuter avant chaque swap (laisse vide pour désactiver)"
echo "Exemples courants :"
echo "  sqlx-cli   : sqlx migrate run"
echo "  refinery   : ./\$BINARY_NAME migrate"
echo "  sea-orm    : sea-orm-cli migrate up"
read -rp "Commande (exécutée depuis le dossier de la release) : " MIGRATION_CMD

read -rp "Configurer un domaine Caddy maintenant ? (oui/non) : " SETUP_CADDY
CADDY_DOMAIN=""
if [ "$SETUP_CADDY" = "oui" ]; then
  read -rp "  Domaine complet (ex: api.exemple.com) : " CADDY_DOMAIN
fi

RELEASES_DIR="$APP_DIR/releases"
CURRENT_LINK="$APP_DIR/current"
ENV_FILE="$APP_DIR/shared/.env"
BINARY_PATH="$CURRENT_LINK/$BINARY_NAME"

# ─── 1. Utilisateur système ───────────────────────────────
if ! id "$APP_NAME" &>/dev/null; then
  useradd -r -s /bin/false -d "$APP_DIR" -c "Service $APP_NAME" "$APP_NAME"
  ok "Utilisateur $APP_NAME créé"
else
  ok "Utilisateur $APP_NAME existe"
fi

# ─── 2. Structure ─────────────────────────────────────────
inf "Préparation de $APP_DIR..."
mkdir -p "$RELEASES_DIR" "$APP_DIR/shared" "$APP_DIR/logs" "$APP_DIR/tmp"
chown -R "$APP_NAME":"$APP_NAME" "$APP_DIR"
chmod 750 "$APP_DIR"
ok "Structure prête"

# ─── 2b. Dossiers persistants ─────────────────────────────
if [ ${#PERSISTENT_DIRS[@]} -gt 0 ]; then
  inf "Création des dossiers persistants..."
  for D in "${PERSISTENT_DIRS[@]}"; do
    PERSIST_PATH="$APP_DIR/shared/$D"
    if [ ! -d "$PERSIST_PATH" ]; then
      mkdir -p "$PERSIST_PATH"
      chown -R "$APP_NAME":"$APP_NAME" "$PERSIST_PATH"
      ok "  shared/$D créé"
    else
      ok "  shared/$D existe (préservé)"
    fi
  done
fi

# ─── 3. Fichier .env ──────────────────────────────────────
{
  echo "# Environnement $APP_NAME — $(date)"
  echo "PORT=$APP_PORT"
  echo "HOST=127.0.0.1"
  [ -n "$DB_URL" ] && echo "DATABASE_URL=$DB_URL"
  echo "RUST_LOG=info"
  for VAR in "${ENV_EXTRAS[@]}"; do
    echo "$VAR"
  done
} > "$ENV_FILE"
chown root:"$APP_NAME" "$ENV_FILE"
chmod 640 "$ENV_FILE"
ok ".env créé"

# ─── 4. Service systemd ───────────────────────────────────
inf "Configuration de systemd..."
cat > "/etc/systemd/system/$APP_NAME.service" << EOF
[Unit]
Description=$APP_NAME — API Rust
After=network-online.target postgresql.service
Wants=network-online.target

[Service]
Type=simple
User=$APP_NAME
Group=$APP_NAME
WorkingDirectory=$CURRENT_LINK

ExecStart=$BINARY_PATH
Restart=on-failure
RestartSec=5s

EnvironmentFile=$ENV_FILE

StandardOutput=append:$APP_DIR/logs/out.log
StandardError=append:$APP_DIR/logs/err.log
SyslogIdentifier=$APP_NAME

# Sandbox
NoNewPrivileges=true
ProtectSystem=strict
ReadWritePaths=$APP_DIR/logs $APP_DIR/tmp
ProtectHome=true
PrivateTmp=true
PrivateDevices=true
ProtectKernelModules=true
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable "$APP_NAME"
ok "Service systemd activé"

# ─── 5. Logrotate ─────────────────────────────────────────
cat > "/etc/logrotate.d/$APP_NAME" << EOF
$APP_DIR/logs/*.log {
    daily
    rotate 14
    compress
    missingok
    notifempty
    create 640 $APP_NAME $APP_NAME
}
EOF

# ─── 6. Script de déploiement ─────────────────────────────
mkdir -p /opt/shared/scripts
DEPLOY_SCRIPT="/opt/shared/scripts/deploy-$APP_NAME.sh"

PERSIST_DIRS_STR="$(printf '%s\n' "${PERSISTENT_DIRS[@]:-}")"

cat > "$DEPLOY_SCRIPT" << DEPLOYEOF
#!/bin/bash
# Déployer une nouvelle version de $APP_NAME (Rust)
# Usage :
#   sudo bash $DEPLOY_SCRIPT <chemin_binaire>            # binaire seul
#   sudo bash $DEPLOY_SCRIPT <dossier> --with-assets     # binaire + assets
set -uo pipefail

SRC=\${1:-""}
MODE=\${2:-"binary"}
[ -z "\$SRC" ] && { echo "Usage: \$0 <binaire_ou_dossier> [--with-assets]"; exit 1; }

APP_NAME="$APP_NAME"
APP_DIR="$APP_DIR"
BINARY_NAME="$BINARY_NAME"
PERSISTENT_DIRS_RAW="$PERSIST_DIRS_STR"
RELEASES_DIR="\$APP_DIR/releases"
CURRENT_LINK="\$APP_DIR/current"

PREV_RELEASE=""
[ -L "\$CURRENT_LINK" ] && PREV_RELEASE=\$(readlink -f "\$CURRENT_LINK")

TS=\$(date +%Y%m%d_%H%M%S)
NEW_RELEASE="\$RELEASES_DIR/\$TS"

abort() {
  echo "✗ \$1"
  echo "  Release ratée conservée : \$NEW_RELEASE"
  exit 1
}

echo "→ Création de \$NEW_RELEASE"
mkdir -p "\$NEW_RELEASE"

if [ "\$MODE" = "--with-assets" ]; then
  [ ! -d "\$SRC" ] && abort "Dossier introuvable: \$SRC"
  cp -a "\$SRC"/. "\$NEW_RELEASE"/
  [ ! -f "\$NEW_RELEASE/\$BINARY_NAME" ] && abort "Binaire \$BINARY_NAME absent de \$SRC"
else
  [ ! -f "\$SRC" ] && abort "Binaire introuvable: \$SRC"
  cp "\$SRC" "\$NEW_RELEASE/\$BINARY_NAME"
fi

chown -R \$APP_NAME:\$APP_NAME "\$NEW_RELEASE"
chmod 750 "\$NEW_RELEASE/\$BINARY_NAME"

# Symlinks dossiers persistants (uploads, etc.)
if [ -n "\$PERSISTENT_DIRS_RAW" ]; then
  echo "→ Symlinks dossiers persistants depuis shared/..."
  while IFS= read -r D; do
    [ -z "\$D" ] && continue
    SHARED_PATH="\$APP_DIR/shared/\$D"
    REL_PATH="\$NEW_RELEASE/\$D"
    if [ ! -d "\$SHARED_PATH" ]; then
      mkdir -p "\$SHARED_PATH"
      chown -R \$APP_NAME:\$APP_NAME "\$SHARED_PATH"
    fi
    if [ -d "\$REL_PATH" ] && [ ! -L "\$REL_PATH" ]; then
      if [ -z "\$(ls -A "\$SHARED_PATH" 2>/dev/null)" ]; then
        cp -a "\$REL_PATH"/. "\$SHARED_PATH"/ 2>/dev/null || true
        chown -R \$APP_NAME:\$APP_NAME "\$SHARED_PATH"
      fi
      rm -rf "\$REL_PATH"
    fi
    mkdir -p "\$(dirname "\$REL_PATH")"
    ln -sfn "\$SHARED_PATH" "\$REL_PATH"
    echo "    \$D → shared/\$D"
  done <<< "\$PERSISTENT_DIRS_RAW"
fi

MIGRATION_CMD="$MIGRATION_CMD"
if [ -n "\$MIGRATION_CMD" ]; then
  echo "→ Migrations DB : \$MIGRATION_CMD"
  su -s /bin/bash \$APP_NAME -c "cd \$NEW_RELEASE && set -a && . \$APP_DIR/shared/.env && set +a && \$MIGRATION_CMD" \\
    || abort "Migration échouée"
fi

echo "→ Bascule du symlink current"
systemctl stop \$APP_NAME 2>/dev/null || true
ln -sfn "\$NEW_RELEASE" "\$CURRENT_LINK"
chown -h \$APP_NAME:\$APP_NAME "\$CURRENT_LINK"

echo "→ Démarrage de \$APP_NAME..."
systemctl start \$APP_NAME

# Health check + rollback automatique
echo "→ Health check (10s)..."
sleep 5
HEALTHY=true
for i in 1 2 3; do
  if ! systemctl is-active --quiet "\$APP_NAME"; then
    HEALTHY=false
    break
  fi
  sleep 2
done

if ! \$HEALTHY; then
  echo ""
  echo "✗ Service inactif après restart — ROLLBACK automatique"
  if [ -n "\$PREV_RELEASE" ] && [ -d "\$PREV_RELEASE" ]; then
    ln -sfn "\$PREV_RELEASE" "\$CURRENT_LINK"
    chown -h \$APP_NAME:\$APP_NAME "\$CURRENT_LINK"
    systemctl restart "\$APP_NAME"
    echo "  → Rollback vers \$(basename "\$PREV_RELEASE")"
  fi
  echo ""
  journalctl -u "\$APP_NAME" -n 30 --no-pager
  exit 1
fi

systemctl status \$APP_NAME --no-pager -l | head -10

echo "→ Purge des vieilles releases (garde 5)..."
cd "\$RELEASES_DIR"
ls -1t | tail -n +6 | xargs -r rm -rf

echo ""
echo "✓ Déploiement terminé — release \$TS active"
echo "  Rollback : sudo ln -sfn \$RELEASES_DIR/<ancien> \$CURRENT_LINK && sudo systemctl restart \$APP_NAME"
DEPLOYEOF

chmod +x "$DEPLOY_SCRIPT"
ok "Script de déploiement : $DEPLOY_SCRIPT"

# ─── 7. Caddy (optionnel) ─────────────────────────────────
if [ -n "$CADDY_DOMAIN" ]; then
  inf "Configuration Caddy pour $CADDY_DOMAIN..."
  SITE_FILE="/etc/caddy/sites-enabled/${CADDY_DOMAIN}.caddy"
  LOG_NAME=$(echo "$CADDY_DOMAIN" | tr '.' '_')

  cat > "$SITE_FILE" << EOF
# Site $CADDY_DOMAIN → $APP_NAME:$APP_PORT — généré le $(date)
$CADDY_DOMAIN {
    import security-headers
    import site-log $LOG_NAME
    encode gzip zstd

    reverse_proxy localhost:$APP_PORT {
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-For {remote_host}
        header_up X-Forwarded-Proto {scheme}
        header_up Host {host}
    }
}
EOF
  if caddy validate --config /etc/caddy/Caddyfile 2>/dev/null; then
    systemctl reload caddy
    ok "Caddy : https://$CADDY_DOMAIN → localhost:$APP_PORT"
  else
    warn "Caddyfile invalide, vérifie $SITE_FILE"
  fi
fi

# ─── Résumé ───────────────────────────────────────────────
echo ""
echo -e "${G}============================================${N}"
echo -e "${G}  $APP_NAME (Rust) configuré                ${N}"
echo -e "${G}============================================${N}"
echo ""
echo "  Dossier       : $APP_DIR"
echo "  Port          : $APP_PORT"
echo "  Binaire       : $BINARY_PATH"
echo "  Utilisateur   : $APP_NAME"
echo "  Env           : $ENV_FILE"
[ -n "$CADDY_DOMAIN" ] && echo "  URL publique  : https://$CADDY_DOMAIN"
echo ""
echo -e "${Y}Pour déployer ton binaire :${N}"
echo "  # Sur ta machine de dev :"
echo "  cargo build --release"
echo "  scp -P <PORT> target/release/$BINARY_NAME admin@<IP>:/tmp/"
echo ""
echo "  # Sur le serveur :"
echo "  sudo bash $DEPLOY_SCRIPT /tmp/$BINARY_NAME"
echo ""
echo "  # Avec migrations/assets :"
echo "  sudo bash $DEPLOY_SCRIPT /tmp/build-folder --with-assets"
echo ""
echo "Commandes utiles :"
echo "  systemctl start|status|restart $APP_NAME"
echo "  journalctl -u $APP_NAME -f"
echo "  tail -f $APP_DIR/logs/err.log"
