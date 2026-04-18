#!/bin/bash
# =========================================================
# SCRIPT 5d — Déployer un site statique (HTML/CSS, SPA, Next export)
# Ubuntu 24.04 — HTIC-NETWORKS
# Usage : sudo bash 05d-deploy-static.sh
#
# Idempotent : relance pour mettre à jour la config Caddy.
# Types :
#   - html    : site statique HTML/CSS classique
#   - spa     : SPA React/Vue avec fallback index.html
#   - next    : export Next.js (`next export` → out/)
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
echo -e "${C}  HTIC-NETWORKS — Déployer Site Statique      ${N}"
echo -e "${C}===============================================${N}"
echo ""

# ─── État actuel du serveur (collisions de noms/ports) ────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -f "$SCRIPT_DIR/00-list-apps.sh" ] && bash "$SCRIPT_DIR/00-list-apps.sh" --short
echo ""

# ─── Questions ────────────────────────────────────────────
echo "Type de site :"
echo "  1) html — HTML/CSS classique"
echo "  2) spa  — SPA (React/Vue) — fallback /index.html"
echo "  3) next — Export Next.js (out/)"
read -rp "Choix [1-3] : " TYPE_CHOICE

case "$TYPE_CHOICE" in
  1) SITE_TYPE="html" ;;
  2) SITE_TYPE="spa" ;;
  3) SITE_TYPE="next" ;;
  *) err "Choix invalide" ;;
esac

read -rp "Nom du site (ex: vitrine, landing) : " APP_NAME
[ -z "$APP_NAME" ] && err "Nom obligatoire"

APP_DIR="/opt/$APP_NAME"
IS_UPDATE=false
[ -d "$APP_DIR" ] && IS_UPDATE=true
$IS_UPDATE && warn "Site $APP_NAME existe → MISE À JOUR de la config"

read -rp "Domaine complet (ex: www.exemple.com) : " CADDY_DOMAIN
[ -z "$CADDY_DOMAIN" ] && err "Domaine obligatoire"

RELEASES_DIR="$APP_DIR/releases"
CURRENT_LINK="$APP_DIR/current"

# ─── 1. Structure ─────────────────────────────────────────
inf "Préparation de $APP_DIR..."
mkdir -p "$RELEASES_DIR"
chown -R caddy:caddy "$APP_DIR"
chmod 755 "$APP_DIR"
ok "Structure prête"

# ─── 2. Script de déploiement ─────────────────────────────
mkdir -p /opt/shared/scripts
DEPLOY_SCRIPT="/opt/shared/scripts/deploy-$APP_NAME.sh"

cat > "$DEPLOY_SCRIPT" << DEPLOYEOF
#!/bin/bash
# Déployer une nouvelle version de $APP_NAME (site statique)
# Usage : sudo bash $DEPLOY_SCRIPT <source_dir>
# <source_dir> doit contenir les fichiers prêts à servir
#   (HTML : racine directe, SPA : contenu de dist/, Next : contenu de out/)
set -euo pipefail

SRC=\${1:-""}
[ -z "\$SRC" ] && { echo "Usage: \$0 <source_dir>"; exit 1; }
[ ! -d "\$SRC" ] && { echo "Dossier introuvable: \$SRC"; exit 1; }

APP_DIR="$APP_DIR"
RELEASES_DIR="\$APP_DIR/releases"
CURRENT_LINK="\$APP_DIR/current"

TS=\$(date +%Y%m%d_%H%M%S)
NEW_RELEASE="\$RELEASES_DIR/\$TS"

echo "→ Création de \$NEW_RELEASE"
mkdir -p "\$NEW_RELEASE"
cp -a "\$SRC"/. "\$NEW_RELEASE"/
chown -R caddy:caddy "\$NEW_RELEASE"

echo "→ Bascule du symlink current"
ln -sfn "\$NEW_RELEASE" "\$CURRENT_LINK"
chown -h caddy:caddy "\$CURRENT_LINK"

echo "→ Reload Caddy..."
systemctl reload caddy

echo "→ Purge des vieilles releases (garde 5)..."
cd "\$RELEASES_DIR"
ls -1t | tail -n +6 | xargs -r rm -rf

echo ""
echo "✓ Déploiement terminé — release \$TS active"
echo "  Rollback : sudo ln -sfn \$RELEASES_DIR/<ancien> \$CURRENT_LINK && sudo systemctl reload caddy"
DEPLOYEOF

chmod +x "$DEPLOY_SCRIPT"
ok "Script de déploiement : $DEPLOY_SCRIPT"

# ─── 3. Caddy ─────────────────────────────────────────────
inf "Configuration Caddy pour $CADDY_DOMAIN..."
SITE_FILE="/etc/caddy/sites-enabled/${CADDY_DOMAIN}.caddy"
LOG_NAME=$(echo "$CADDY_DOMAIN" | tr '.' '_')

case "$SITE_TYPE" in
  spa)
    TRY_FILES="try_files {path} /index.html"
    ;;
  next)
    # Next export : try_files avec fallback sur fichiers HTML générés
    TRY_FILES="try_files {path} {path}.html {path}/index.html =404"
    ;;
  html)
    TRY_FILES=""
    ;;
esac

cat > "$SITE_FILE" << EOF
# Site $CADDY_DOMAIN → $APP_NAME ($SITE_TYPE) — généré le $(date)
$CADDY_DOMAIN {
    import security-headers
    import site-log $LOG_NAME
    encode gzip zstd

    root * $CURRENT_LINK
$([ -n "$TRY_FILES" ] && echo "    $TRY_FILES")
    file_server

    # Cache agressif pour assets versionnés
    @assets path *.css *.js *.woff2 *.png *.jpg *.jpeg *.svg *.webp *.avif *.ico
    header @assets Cache-Control "public, max-age=31536000, immutable"

    # Pas de cache pour HTML
    @html path *.html /
    header @html Cache-Control "no-cache, must-revalidate"
}
EOF

if caddy validate --config /etc/caddy/Caddyfile 2>/dev/null; then
  systemctl reload caddy
  ok "Caddy : https://$CADDY_DOMAIN"
else
  warn "Caddyfile invalide, vérifie $SITE_FILE"
fi

# ─── 4. Placeholder si première install ───────────────────
if [ ! -L "$CURRENT_LINK" ]; then
  PLACEHOLDER="$RELEASES_DIR/initial"
  mkdir -p "$PLACEHOLDER"
  cat > "$PLACEHOLDER/index.html" << EOF
<!doctype html>
<html lang="fr">
<head><meta charset="utf-8"><title>$APP_NAME</title></head>
<body style="font-family:system-ui;padding:4rem;text-align:center">
  <h1>$APP_NAME</h1>
  <p>Site en attente de déploiement.</p>
  <code>sudo bash $DEPLOY_SCRIPT /chemin/vers/build</code>
</body>
</html>
EOF
  chown -R caddy:caddy "$PLACEHOLDER"
  ln -sfn "$PLACEHOLDER" "$CURRENT_LINK"
  chown -h caddy:caddy "$CURRENT_LINK"
  ok "Placeholder initial créé"
fi

# ─── Résumé ───────────────────────────────────────────────
echo ""
echo -e "${G}===============================================${N}"
echo -e "${G}  $APP_NAME ($SITE_TYPE) configuré             ${N}"
echo -e "${G}===============================================${N}"
echo ""
echo "  Type         : $SITE_TYPE"
echo "  Dossier      : $APP_DIR"
echo "  URL publique : https://$CADDY_DOMAIN"
echo ""
echo -e "${Y}Pour déployer :${N}"
case "$SITE_TYPE" in
  html)
    echo "  # Sur ta machine :"
    echo "  scp -P <PORT> -r /chemin/site/* admin@<IP>:/tmp/$APP_NAME/"
    ;;
  spa)
    echo "  # Sur ta machine :"
    echo "  npm run build"
    echo "  scp -P <PORT> -r dist/* admin@<IP>:/tmp/$APP_NAME/"
    ;;
  next)
    echo "  # Sur ta machine :"
    echo "  npm run build && npm run export"
    echo "  scp -P <PORT> -r out/* admin@<IP>:/tmp/$APP_NAME/"
    ;;
esac
echo ""
echo "  # Sur le serveur :"
echo "  sudo bash $DEPLOY_SCRIPT /tmp/$APP_NAME"
echo ""
echo "Commandes utiles :"
echo "  systemctl reload caddy"
echo "  tail -f /var/log/caddy/${LOG_NAME}.log"
echo "  ls -lt $RELEASES_DIR/   # releases disponibles"
