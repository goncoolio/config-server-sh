#!/bin/bash
# =========================================================
# SCRIPT 5a — Déployer une app Node.js (NestJS / Express / Next.js)
# Ubuntu 24.04 — HTIC-NETWORKS
# Usage : sudo bash 05a-deploy-node.sh
#
# Idempotent : relance sur une app existante pour mettre à jour
# la config (entry point, port, env, Caddy, etc.)
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
echo -e "${C}  HTIC-NETWORKS — Déployer App Node.js        ${N}"
echo -e "${C}===============================================${N}"
echo ""

# ─── État actuel du serveur (collisions de noms/ports) ────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -f "$SCRIPT_DIR/00-list-apps.sh" ] && bash "$SCRIPT_DIR/00-list-apps.sh" --short
echo ""

# ─── Framework ────────────────────────────────────────────
echo "Framework :"
echo "  1) NestJS   — entry typique: dist/main.js OU dist/src/main.js"
echo "  2) Express  — entry personnalisable (src/server.js, app.js, index.js, ...)"
echo "  3) Next.js  — démarrage via 'next start' (auto-détecté)"
read -rp "Choix [1-3] : " FW_CHOICE

case "$FW_CHOICE" in
  1) FRAMEWORK="nestjs";  DEFAULT_ENTRY="dist/main.js" ;;
  2) FRAMEWORK="express"; DEFAULT_ENTRY="src/server.js" ;;
  3) FRAMEWORK="nextjs";  DEFAULT_ENTRY="" ;;  # Next.js : géré via next start
  *) err "Choix invalide" ;;
esac

# ─── Questions ────────────────────────────────────────────
read -rp "Nom de l'app (ex: munipay-api) : " APP_NAME
[ -z "$APP_NAME" ] && err "Nom obligatoire"

APP_DIR="/opt/$APP_NAME"
IS_UPDATE=false
[ -d "$APP_DIR" ] && IS_UPDATE=true

if $IS_UPDATE; then
  warn "App $APP_NAME existe déjà → mode MISE À JOUR de la config"
fi

read -rp "Port d'écoute local (ex: 3002) : " APP_PORT
[ -z "$APP_PORT" ] && err "Port obligatoire"

if [ "$FRAMEWORK" = "nextjs" ]; then
  ENTRY=""  # next start gère tout
else
  echo ""
  echo "Entry point (chemin relatif à current/) — vérifié après le build."
  case "$FRAMEWORK" in
    nestjs)
      echo "  Possibilités courantes : dist/main.js, dist/src/main.js"
      echo "  (selon ta structure tsconfig — auto-détection de fallback à l'exécution)"
      ;;
    express)
      echo "  Possibilités courantes : src/server.js, src/app.js, src/index.js, app.js, index.js"
      ;;
  esac
  read -rp "Entry point [$DEFAULT_ENTRY] : " ENTRY
  ENTRY="${ENTRY:-$DEFAULT_ENTRY}"
fi

read -rp "DATABASE_URL (laisse vide pour ignorer) : " DB_URL

echo ""
echo "Commande de build à exécuter sur le serveur après npm ci (laisse vide si aucune)"
case "$FRAMEWORK" in
  nestjs)  DEFAULT_BUILD="npm run build" ;;
  nextjs)  DEFAULT_BUILD="npm run build" ;;
  express) DEFAULT_BUILD="" ;;
esac
read -rp "Commande [$DEFAULT_BUILD] : " BUILD_CMD
BUILD_CMD="${BUILD_CMD:-$DEFAULT_BUILD}"

echo ""
echo "Dossiers à PRÉSERVER entre les releases (uploads, fichiers utilisateurs, etc.)"
echo "Ils seront stockés dans /opt/$APP_NAME/shared/<dossier>/ et symlinkés à chaque deploy."
echo "Format : un par ligne (chemin relatif à current/), ligne vide pour terminer"
echo "Exemples : uploads, public/uploads, public/storage, files, attachments"
PERSISTENT_DIRS=()
while true; do
  read -rp "  > " LINE
  [ -z "$LINE" ] && break
  PERSISTENT_DIRS+=("$LINE")
done

echo ""
echo "DevDependencies à GARDER en production (séparés par des espaces, vide pour aucun)"
echo "Utile si une commande de seed/migration en prod nécessite des outils dev."
echo "Exemple Prisma+ts-node : ts-node typescript @types/node"
read -rp "Packages : " KEEP_DEV_DEPS

echo ""
echo "Variables d'env supplémentaires (optionnel)"
echo "Format : CLE=VALEUR — ligne vide pour terminer"
ENV_EXTRAS=()
while true; do
  read -rp "  > " LINE
  [ -z "$LINE" ] && break
  ENV_EXTRAS+=("$LINE")
done

echo ""
echo "ORM utilisé (génère un menu de commandes DB dédié) :"
echo "  1) Prisma"
echo "  2) Sequelize (sequelize-cli)"
echo "  3) TypeORM"
echo "  4) Knex"
echo "  5) Drizzle"
echo "  0) Aucun / autre"
read -rp "Choix [0-5] : " ORM_CHOICE

case "$ORM_CHOICE" in
  1) ORM="prisma";    DEFAULT_MIGRATE="npx prisma migrate deploy" ;;
  2) ORM="sequelize"; DEFAULT_MIGRATE="npx sequelize-cli db:migrate --env production" ;;
  3) ORM="typeorm";   DEFAULT_MIGRATE="npx typeorm migration:run -d dist/data-source.js" ;;
  4) ORM="knex";      DEFAULT_MIGRATE="npx knex migrate:latest --env production" ;;
  5) ORM="drizzle";   DEFAULT_MIGRATE="npx drizzle-kit migrate" ;;
  *) ORM="none";      DEFAULT_MIGRATE="" ;;
esac

echo ""
echo "Commande de migration DB à exécuter avant chaque swap (laisse vide pour désactiver)"
[ -n "$DEFAULT_MIGRATE" ] && echo "Défaut : $DEFAULT_MIGRATE"
read -rp "Commande [$DEFAULT_MIGRATE] : " MIGRATION_CMD
MIGRATION_CMD="${MIGRATION_CMD:-$DEFAULT_MIGRATE}"

read -rp "Configurer un domaine Caddy maintenant ? (oui/non) : " SETUP_CADDY
CADDY_DOMAIN=""
if [ "$SETUP_CADDY" = "oui" ]; then
  read -rp "  Domaine complet (ex: api.exemple.com) : " CADDY_DOMAIN
fi

ENV_FILE="$APP_DIR/shared/.env"
RELEASES_DIR="$APP_DIR/releases"
CURRENT_LINK="$APP_DIR/current"

# ─── 1. Node.js 20 LTS ────────────────────────────────────
if ! command -v node &>/dev/null; then
  inf "Installation de Node.js 20 LTS..."
  curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
  apt-get install -y nodejs
  ok "Node.js $(node -v)"
else
  ok "Node.js déjà installé : $(node -v)"
fi

# ─── 2. Utilisateur système ───────────────────────────────
if ! id "$APP_NAME" &>/dev/null; then
  useradd -m -s /bin/bash -d "$APP_DIR" -c "Service $APP_NAME" "$APP_NAME"
  ok "Utilisateur $APP_NAME créé"
else
  ok "Utilisateur $APP_NAME existe"
fi

# ─── 3. Structure de répertoires (releases-based) ─────────
inf "Préparation de $APP_DIR..."
mkdir -p "$RELEASES_DIR" "$APP_DIR/shared" "$APP_DIR/logs"
chown -R "$APP_NAME":"$APP_NAME" "$APP_DIR"
chmod 750 "$APP_DIR"
ok "Structure prête : releases/, shared/, logs/, current→"

# ─── 3b. Dossiers persistants (uploads, etc.) ─────────────
if [ ${#PERSISTENT_DIRS[@]} -gt 0 ]; then
  inf "Création des dossiers persistants dans shared/..."
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

# ─── 5. Fichier .env (shared, persiste entre releases) ────
# Comportement intelligent :
#   - Première install (.env absent)            → génère
#   - Update sans nouvelles vars                 → conserve l'existant + met à jour PORT seulement
#   - Update avec DB_URL ou ENV_EXTRAS fournis  → backup + merge (les nouvelles écrasent, les autres restent)
mkdir -p "$(dirname "$ENV_FILE")"

NEW_VARS_PROVIDED=false
[ -n "$DB_URL" ] && NEW_VARS_PROVIDED=true
[ ${#ENV_EXTRAS[@]} -gt 0 ] && NEW_VARS_PROVIDED=true

if [ ! -f "$ENV_FILE" ]; then
  # Première install : générer
  inf "Génération initiale de $ENV_FILE..."
  {
    echo "# Environnement $APP_NAME — $(date)"
    echo "NODE_ENV=production"
    echo "PORT=$APP_PORT"
    echo "HOST=127.0.0.1"
    [ -n "$DB_URL" ] && echo "DATABASE_URL=$DB_URL"
    for VAR in "${ENV_EXTRAS[@]}"; do
      echo "$VAR"
    done
  } > "$ENV_FILE"
  ok ".env créé"
else
  # Update : merge prudent
  inf "$ENV_FILE existe — merge intelligent..."
  cp -p "$ENV_FILE" "${ENV_FILE}.bak.$(date +%Y%m%d_%H%M%S)"

  # Construire la nouvelle valeur clé par clé en gardant les anciennes
  TMP_ENV=$(mktemp)
  cp "$ENV_FILE" "$TMP_ENV"

  # Helper : update_or_add KEY=VALUE dans $TMP_ENV
  update_var() {
    local key="${1%%=*}"
    local val="${1#*=}"
    if grep -q "^${key}=" "$TMP_ENV" 2>/dev/null; then
      # Existe déjà → remplacer (sed préserve l'ordre)
      sed -i "s|^${key}=.*|${key}=${val}|" "$TMP_ENV"
    else
      echo "${key}=${val}" >> "$TMP_ENV"
    fi
  }

  # Toujours rafraîchir PORT, NODE_ENV, HOST (valeurs structurelles)
  update_var "NODE_ENV=production"
  update_var "PORT=$APP_PORT"
  update_var "HOST=127.0.0.1"

  # DATABASE_URL et ENV_EXTRAS uniquement si fournis
  [ -n "$DB_URL" ] && update_var "DATABASE_URL=$DB_URL"
  for VAR in "${ENV_EXTRAS[@]}"; do
    update_var "$VAR"
  done

  mv "$TMP_ENV" "$ENV_FILE"

  if $NEW_VARS_PROVIDED; then
    ok ".env mis à jour (backup : ${ENV_FILE}.bak.*)"
  else
    ok ".env conservé (PORT/NODE_ENV/HOST rafraîchis, autres vars intactes)"
  fi
fi

chown root:"$APP_NAME" "$ENV_FILE"
chmod 640 "$ENV_FILE"

# ─── 6. Service systemd direct (sans PM2) ─────────────────
# systemd est l'unique superviseur — PM2 supprimé pour éviter
# la double gestion (cf. diagnostic api-wii-saas).
inf "Configuration de systemd (Type=simple, node direct)..."

# Construire ExecStart selon le framework
case "$FRAMEWORK" in
  nextjs)
    # Next.js : on utilise le bin de next dans node_modules/
    EXEC_START="/usr/bin/node $CURRENT_LINK/node_modules/next/dist/bin/next start -p $APP_PORT"
    ;;
  *)
    # NestJS / Express : node directement sur l'entry point
    EXEC_START="/usr/bin/node $CURRENT_LINK/$ENTRY"
    ;;
esac

cat > "/etc/systemd/system/$APP_NAME.service" << EOF
[Unit]
Description=$APP_NAME — $FRAMEWORK (node direct)
After=network-online.target postgresql.service
Wants=network-online.target

[Service]
Type=simple
User=$APP_NAME
Group=$APP_NAME
WorkingDirectory=$CURRENT_LINK

Environment=HOME=$APP_DIR
Environment=NODE_ENV=production
Environment=PORT=$APP_PORT
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/bin
EnvironmentFile=$ENV_FILE

ExecStart=$EXEC_START

Restart=always
RestartSec=10s
LimitNOFILE=65536

StandardOutput=append:$APP_DIR/logs/systemd.log
StandardError=append:$APP_DIR/logs/systemd-err.log

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable "$APP_NAME"
ok "Service systemd $APP_NAME activé (Type=simple, node direct)"

# ─── 7. Logrotate ─────────────────────────────────────────
cat > "/etc/logrotate.d/$APP_NAME" << EOF
$APP_DIR/logs/*.log {
    daily
    rotate 14
    compress
    missingok
    notifempty
    create 640 $APP_NAME $APP_NAME
    copytruncate
}
EOF

# ─── 9. Script de déploiement (releases + symlink) ────────
mkdir -p /opt/shared/scripts
DEPLOY_SCRIPT="/opt/shared/scripts/deploy-$APP_NAME.sh"

# Encoder la liste des dossiers persistants pour l'embarquer dans le script généré
PERSIST_DIRS_STR="$(printf '%s\n' "${PERSISTENT_DIRS[@]:-}")"

cat > "$DEPLOY_SCRIPT" << DEPLOYEOF
#!/bin/bash
# Déployer une nouvelle version de $APP_NAME ($FRAMEWORK)
# Usage : sudo bash $DEPLOY_SCRIPT <source_dir>
#
# <source_dir> = code source complet (sans dist/, .next/, node_modules/, .git/)
# Tout est construit sur le serveur.
#
# Pipeline :
#   1. Copie source dans releases/<timestamp>/
#   2. Symlink des dossiers persistants (uploads, etc.) depuis shared/
#   3. npm ci --include=dev (toutes les deps pour permettre le build)
#   4. Build (si framework nécessite)
#   5. Migrations DB (si configurées)
#   6. npm prune --omit=dev (retire devDependencies)
#   7. Réinstalle les devDeps marquées "à garder en prod" (ts-node, etc.)
#   8. Vérification que l'entry point existe (auto-fallback NestJS)
#   9. Bascule atomique du symlink current
#  10. Restart systemd + health check (rollback auto si KO)
#  11. Purge les vieilles releases (garde 5)
set -uo pipefail

SRC=\${1:-""}
[ -z "\$SRC" ] && { echo "Usage: \$0 <source_dir>"; exit 1; }
[ ! -d "\$SRC" ] && { echo "Dossier introuvable: \$SRC"; exit 1; }
[ ! -f "\$SRC/package.json" ] && { echo "package.json absent de \$SRC"; exit 1; }

APP_NAME="$APP_NAME"
APP_DIR="$APP_DIR"
FRAMEWORK="$FRAMEWORK"
ENTRY="$ENTRY"
BUILD_CMD="$BUILD_CMD"
MIGRATION_CMD="$MIGRATION_CMD"
KEEP_DEV_DEPS="$KEEP_DEV_DEPS"
RELEASES_DIR="\$APP_DIR/releases"
CURRENT_LINK="\$APP_DIR/current"

# Liste des dossiers persistants (un par ligne)
PERSISTENT_DIRS_RAW="$PERSIST_DIRS_STR"

# Capturer la release courante AVANT le swap, pour rollback en cas d'échec
PREV_RELEASE=""
[ -L "\$CURRENT_LINK" ] && PREV_RELEASE=\$(readlink -f "\$CURRENT_LINK")

TS=\$(date +%Y%m%d_%H%M%S)
NEW_RELEASE="\$RELEASES_DIR/\$TS"

abort() {
  echo "✗ \$1"
  echo "  Release ratée conservée pour debug : \$NEW_RELEASE"
  exit 1
}

echo "→ Création de \$NEW_RELEASE"
mkdir -p "\$NEW_RELEASE" || abort "mkdir échoué"
cp -a "\$SRC"/. "\$NEW_RELEASE"/ || abort "Copie source échouée"
# Sécurité : purger les artefacts envoyés par erreur (jamais utiliser ceux du dev)
rm -rf "\$NEW_RELEASE/node_modules" "\$NEW_RELEASE/dist" "\$NEW_RELEASE/.next"
chown -R \$APP_NAME:\$APP_NAME "\$NEW_RELEASE"

echo "→ Symlink shared/.env → \$NEW_RELEASE/.env"
ln -sfn "\$APP_DIR/shared/.env" "\$NEW_RELEASE/.env"

# Symlinks des dossiers persistants (uploads, etc.)
if [ -n "\$PERSISTENT_DIRS_RAW" ]; then
  echo "→ Symlinks des dossiers persistants depuis shared/..."
  while IFS= read -r D; do
    [ -z "\$D" ] && continue
    SHARED_PATH="\$APP_DIR/shared/\$D"
    REL_PATH="\$NEW_RELEASE/\$D"
    # Créer le dossier shared si absent (1ère fois)
    if [ ! -d "\$SHARED_PATH" ]; then
      mkdir -p "\$SHARED_PATH"
      chown -R \$APP_NAME:\$APP_NAME "\$SHARED_PATH"
    fi
    # Si la release contient déjà ce dossier (ex: public/uploads/ avec contenu défaut),
    # le déplacer dans shared/ uniquement la première fois
    if [ -d "\$REL_PATH" ] && [ ! -L "\$REL_PATH" ]; then
      if [ -z "\$(ls -A "\$SHARED_PATH" 2>/dev/null)" ]; then
        echo "    → Migration initiale : \$REL_PATH → shared/"
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

# Limite RAM Node (évite OOM sur petites VM)
NPM_ENV="NODE_OPTIONS=--max-old-space-size=1024"

echo "→ Installation des dépendances (devDependencies incluses pour le build)..."
if [ -f "\$NEW_RELEASE/package-lock.json" ]; then
  if ! su -s /bin/bash \$APP_NAME -c "cd \$NEW_RELEASE && \$NPM_ENV npm ci --include=dev --no-audit --no-fund"; then
    echo "  ⚠ npm ci échoué — fallback sur npm install"
    echo "     (lock file probablement désynchronisé entre OS/arch dev et serveur)"
    su -s /bin/bash \$APP_NAME -c "cd \$NEW_RELEASE && \$NPM_ENV npm install --include=dev --no-audit --no-fund" \\
      || abort "npm install échoué"
  fi
else
  echo "  ⚠ package-lock.json absent — npm install (moins reproductible)"
  su -s /bin/bash \$APP_NAME -c "cd \$NEW_RELEASE && \$NPM_ENV npm install --include=dev --no-audit --no-fund" \\
    || abort "npm install échoué"
fi

if [ -n "\$BUILD_CMD" ]; then
  echo "→ Build : \$BUILD_CMD"
  su -s /bin/bash \$APP_NAME -c "cd \$NEW_RELEASE && set -a && . \$APP_DIR/shared/.env && set +a && \$NPM_ENV \$BUILD_CMD" \\
    || abort "Build échoué"
fi

if [ -n "\$MIGRATION_CMD" ]; then
  echo "→ Migrations DB : \$MIGRATION_CMD"
  su -s /bin/bash \$APP_NAME -c "cd \$NEW_RELEASE && set -a && . \$APP_DIR/shared/.env && set +a && \$NPM_ENV \$MIGRATION_CMD" \\
    || abort "Migration échouée"
fi

echo "→ Suppression des devDependencies..."
su -s /bin/bash \$APP_NAME -c "cd \$NEW_RELEASE && \$NPM_ENV npm prune --omit=dev" || abort "npm prune échoué"

if [ -n "\$KEEP_DEV_DEPS" ]; then
  echo "→ Réinstallation des devDeps à garder en prod : \$KEEP_DEV_DEPS"
  su -s /bin/bash \$APP_NAME -c "cd \$NEW_RELEASE && \$NPM_ENV npm install --no-save --no-audit --no-fund \$KEEP_DEV_DEPS" \\
    || abort "Réinstallation des devDeps échouée"
fi

# Nettoyage framework-spécifique : DÉSACTIVÉ par défaut
# Raisons de garder src/ + tsconfig + test/ :
#   - Les seeds Prisma utilisant ts-node importent depuis ../src/...
#   - Source maps debug
#   - Re-build incrémental possible
#   - Coût disque négligeable (quelques MB)
# Pour activer un cleanup agressif, exporte AGGRESSIVE_CLEANUP=1 avant d'appeler ce script.
if [ "\${AGGRESSIVE_CLEANUP:-0}" = "1" ]; then
  case "\$FRAMEWORK" in
    nestjs)
      rm -rf "\$NEW_RELEASE/src" "\$NEW_RELEASE/test" "\$NEW_RELEASE/tsconfig"*.json "\$NEW_RELEASE/nest-cli.json" 2>/dev/null || true
      ;;
  esac
fi

# ─── Auto-détection de l'entry point (NestJS / Express) ───
if [ "\$FRAMEWORK" != "nextjs" ]; then
  if [ ! -f "\$NEW_RELEASE/\$ENTRY" ]; then
    echo "  ⚠ Entry point '\$ENTRY' introuvable — recherche d'un fallback..."
    FOUND=""
    for C in dist/main.js dist/src/main.js dist/index.js dist/app.js src/main.js src/server.js src/app.js src/index.js server.js app.js index.js; do
      if [ -f "\$NEW_RELEASE/\$C" ]; then
        FOUND="\$C"
        break
      fi
    done
    if [ -z "\$FOUND" ]; then
      abort "Aucun entry point trouvé dans : dist/main.js, dist/src/main.js, src/server.js, ..."
    fi
    echo "  ✓ Fallback trouvé : \$FOUND"
    ENTRY="\$FOUND"
    # Mise à jour systemd avec le bon chemin
    NEW_EXEC="/usr/bin/node \$CURRENT_LINK/\$ENTRY"
    sed -i "s|^ExecStart=.*|ExecStart=\$NEW_EXEC|" "/etc/systemd/system/\$APP_NAME.service"
    systemctl daemon-reload
    echo "  → systemd ExecStart mis à jour : \$NEW_EXEC"
  fi
fi

echo "→ Bascule du symlink current"
ln -sfn "\$NEW_RELEASE" "\$CURRENT_LINK"
chown -h \$APP_NAME:\$APP_NAME "\$CURRENT_LINK"

echo "→ Restart systemd..."
systemctl restart "\$APP_NAME"

# ─── Health check + rollback automatique ──────────────────
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
    sleep 3
    systemctl status "\$APP_NAME" --no-pager -l | head -20
  else
    echo "  ⚠ Aucune release précédente pour rollback"
    systemctl status "\$APP_NAME" --no-pager -l | head -20
  fi
  echo ""
  echo "Logs erreur :"
  journalctl -u "\$APP_NAME" -n 30 --no-pager
  exit 1
fi

systemctl status "\$APP_NAME" --no-pager -l | head -10

echo "→ Purge des vieilles releases (garde 5)..."
cd "\$RELEASES_DIR"
ls -1t | tail -n +6 | xargs -r rm -rf

echo ""
echo "✓ Déploiement réussi — release \$TS active"
echo "  Logs : journalctl -u \$APP_NAME -f"
echo "  Rollback manuel : sudo ln -sfn \$RELEASES_DIR/<ancien> \$CURRENT_LINK && sudo systemctl restart \$APP_NAME"
DEPLOYEOF

chmod +x "$DEPLOY_SCRIPT"
ok "Script de déploiement : $DEPLOY_SCRIPT"

# ─── 9b. DB Manager (menu interactif par ORM) ─────────────
if [ "$ORM" != "none" ]; then
  DB_SCRIPT="/opt/shared/scripts/$APP_NAME-db.sh"
  inf "Génération du DB Manager ($ORM) : $DB_SCRIPT"

  cat > "$DB_SCRIPT" << DBEOF
#!/bin/bash
# DB Manager — $APP_NAME ($ORM)
# Usage : sudo bash $DB_SCRIPT
#
# Menu interactif numéroté pour exécuter les commandes ORM.
# Toutes les commandes tournent en tant qu'utilisateur \$APP_NAME,
# depuis \$CURRENT, avec les variables d'env de \$ENV_FILE chargées.
set -uo pipefail

APP_NAME="$APP_NAME"
APP_DIR="$APP_DIR"
ORM="$ORM"
CURRENT="\$APP_DIR/current"
ENV_FILE="\$APP_DIR/shared/.env"

G='\033[0;32m'; Y='\033[1;33m'; R='\033[0;31m'; C='\033[0;36m'; B='\033[1m'; N='\033[0m'

[ "\$EUID" -ne 0 ] && { echo "Lance avec sudo : sudo bash \$0"; exit 1; }
[ ! -L "\$CURRENT" ] && { echo "\$CURRENT n'existe pas — déploie l'app d'abord"; exit 1; }

# Exécuter une commande en tant qu'app, env chargé
run_as_app() {
  su -s /bin/bash "\$APP_NAME" -c "cd '\$CURRENT' && set -a && . '\$ENV_FILE' && set +a && NODE_OPTIONS=--max-old-space-size=1024 \$*"
}

# Sélection d'un fichier dans un dossier (sous-menu seeds, etc.)
# Usage : pick_file <dossier> <pattern>
# Retour stdout : "__ALL__" pour tous, ou chemin complet, ou vide si annulé
pick_file() {
  local dir="\$1"
  local pattern="\$2"   # peut être "*.js" ou "*.js,*.ts" (multi-patterns séparés par virgule)
  local files=()
  if [ ! -d "\$dir" ]; then
    echo "" >&2
    echo -e "\${R}Dossier introuvable : \$dir\${N}" >&2
    return 1
  fi
  # Construit l'expression find pour multi-patterns
  local find_args=()
  IFS=',' read -ra PATTERNS <<< "\$pattern"
  local first=true
  for p in "\${PATTERNS[@]}"; do
    if \$first; then
      find_args+=(-name "\$p")
      first=false
    else
      find_args+=(-o -name "\$p")
    fi
  done
  while IFS= read -r f; do
    files+=("\$f")
  done < <(find "\$dir" -maxdepth 2 -type f \\( "\${find_args[@]}" \\) 2>/dev/null | sort)

  if [ \${#files[@]} -eq 0 ]; then
    echo "" >&2
    echo -e "\${R}Aucun fichier '\$pattern' dans \$dir\${N}" >&2
    return 1
  fi

  echo "" >&2
  echo -e "\${B}Choisis un fichier :\${N}" >&2
  echo "   0) ⭐ Tous (exécution séquentielle)" >&2
  local i=1
  for f in "\${files[@]}"; do
    echo "   \$i) \$(basename "\$f")" >&2
    i=\$((i+1))
  done
  echo "" >&2
  read -rp "  Choix : " CHOICE
  if [ "\$CHOICE" = "0" ]; then
    echo "__ALL__"
    return 0
  fi
  local idx=\$((CHOICE-1))
  if [ -z "\${files[\$idx]:-}" ]; then
    echo -e "\${R}Choix invalide\${N}" >&2
    return 1
  fi
  echo "\${files[\$idx]}"
}

# Affiche le menu principal selon l'ORM
show_menu() {
  clear
  echo -e "\${C}════════════════════════════════════════════════\${N}"
  echo -e "\${C}  DB Manager — \$APP_NAME (\$ORM)\${N}"
  echo -e "\${C}════════════════════════════════════════════════\${N}"
  echo ""
  case "\$ORM" in
    prisma)
      echo -e "  \${B}MIGRATIONS\${N}"
      echo "   1) migrate deploy       (appliquer les migrations en prod)"
      echo "   2) migrate status       (voir l'état des migrations)"
      echo "   3) migrate resolve      (marquer une migration comme appliquée)"
      echo ""
      echo -e "  \${B}SEEDS\${N}"
      echo "   4) db seed              (exécute prisma db seed)"
      echo ""
      echo -e "  \${B}CLIENT & UTILS\${N}"
      echo "   5) generate             (régénérer le client Prisma)"
      echo "   6) studio               (Prisma Studio sur :5555 — temporaire)"
      echo "   7) db pull              (introspection schéma DB → schema.prisma)"
      echo ""
      echo -e "  \${R}DESTRUCTIF (confirmation requise)\${N}"
      echo "   8) migrate reset        (drop DB + replay migrations + seed)"
      ;;
    sequelize)
      echo -e "  \${B}MIGRATIONS\${N}"
      echo "   1) db:migrate           (exécuter les migrations en attente)"
      echo "   2) db:migrate:status    (voir l'état)"
      echo "   3) db:migrate:undo      (rollback la dernière)"
      echo "   4) db:migrate:undo:all  (rollback toutes — DESTRUCTIF)"
      echo ""
      echo -e "  \${B}SEEDS\${N}"
      echo "   5) db:seed              (choisir : tous ou un seul)"
      echo "   6) db:seed:undo         (rollback dernier seed)"
      echo "   7) db:seed:undo:all     (rollback tous les seeds)"
      echo ""
      echo -e "  \${B}MODÈLES\${N}"
      echo "   8) model:generate       (générer un nouveau modèle — interactif)"
      ;;
    typeorm)
      echo -e "  \${B}MIGRATIONS\${N}"
      echo "   1) migration:run        (exécuter les migrations en attente)"
      echo "   2) migration:show       (lister les migrations)"
      echo "   3) migration:revert     (rollback la dernière)"
      echo "   4) migration:generate   (générer depuis les entités — interactif)"
      echo ""
      echo -e "  \${B}SEEDS\${N}"
      echo "   5) Exécuter un script de seed (dossier dist/seeds/ ou dist/database/seeds/)"
      echo ""
      echo -e "  \${B}SCHEMA\${N}"
      echo "   6) schema:log           (voir le SQL généré par sync — sans exécuter)"
      ;;
    knex)
      echo -e "  \${B}MIGRATIONS\${N}"
      echo "   1) migrate:latest       (appliquer toutes les migrations en attente)"
      echo "   2) migrate:status       (voir l'état)"
      echo "   3) migrate:rollback     (rollback dernier batch)"
      echo "   4) migrate:down         (rollback une seule)"
      echo ""
      echo -e "  \${B}SEEDS\${N}"
      echo "   5) seed:run             (choisir : tous ou un seul)"
      ;;
    drizzle)
      echo -e "  \${B}MIGRATIONS\${N}"
      echo "   1) drizzle-kit migrate  (appliquer les migrations en prod)"
      echo "   2) drizzle-kit generate (générer une nouvelle migration)"
      echo "   3) drizzle-kit push     (push direct du schema — dev uniquement)"
      echo "   4) drizzle-kit pull     (introspection DB → schema)"
      echo ""
      echo -e "  \${B}SEEDS & STUDIO\${N}"
      echo "   5) Exécuter un script de seed (dans src/seeds/, db/seeds/, etc.)"
      echo "   6) drizzle-kit studio   (Drizzle Studio en local)"
      ;;
  esac
  echo ""
  echo "   c) Commande npm script personnalisée (cat package.json | scripts)"
  echo "   r) Recharger l'app (systemctl reload \$APP_NAME)"
  echo "   l) Voir les logs récents (journalctl -u \$APP_NAME)"
  echo "   q) Quitter"
  echo ""
}

# Confirmation explicite pour opérations destructives
confirm_destructive() {
  echo ""
  echo -e "\${R}⚠ OPÉRATION DESTRUCTIVE\${N}"
  read -rp "  Tape 'CONFIRMER' pour continuer : " CONF
  [ "\$CONF" = "CONFIRMER" ]
}

# Exécution des commandes
exec_choice() {
  local choice="\$1"
  case "\$ORM-\$choice" in
    # ─── Prisma ───
    prisma-1) run_as_app "npx prisma migrate deploy" ;;
    prisma-2) run_as_app "npx prisma migrate status" ;;
    prisma-3)
      read -rp "  Nom de la migration à marquer : " M
      run_as_app "npx prisma migrate resolve --applied '\$M'"
      ;;
    prisma-4) run_as_app "npx prisma db seed" ;;
    prisma-5) run_as_app "npx prisma generate" ;;
    prisma-6) run_as_app "npx prisma studio --port 5555" ;;
    prisma-7) run_as_app "npx prisma db pull" ;;
    prisma-8) confirm_destructive && run_as_app "npx prisma migrate reset --force" ;;

    # ─── Sequelize ───
    sequelize-1) run_as_app "npx sequelize-cli db:migrate --env production" ;;
    sequelize-2) run_as_app "npx sequelize-cli db:migrate:status --env production" ;;
    sequelize-3) run_as_app "npx sequelize-cli db:migrate:undo --env production" ;;
    sequelize-4) confirm_destructive && run_as_app "npx sequelize-cli db:migrate:undo:all --env production" ;;
    sequelize-5)
      F=\$(pick_file "\$CURRENT/seeders" "*.js")
      [ -z "\$F" ] && return
      if [ "\$F" = "__ALL__" ]; then
        run_as_app "npx sequelize-cli db:seed:all --env production"
      else
        run_as_app "npx sequelize-cli db:seed --seed '\$(basename "\$F")' --env production"
      fi
      ;;
    sequelize-6) run_as_app "npx sequelize-cli db:seed:undo --env production" ;;
    sequelize-7) confirm_destructive && run_as_app "npx sequelize-cli db:seed:undo:all --env production" ;;
    sequelize-8)
      read -rp "  Nom du modèle (PascalCase) : " M
      read -rp "  Attributs (ex: name:string,email:string) : " A
      run_as_app "npx sequelize-cli model:generate --name '\$M' --attributes '\$A'"
      ;;

    # ─── TypeORM ───
    typeorm-1) run_as_app "npx typeorm migration:run -d dist/data-source.js" ;;
    typeorm-2) run_as_app "npx typeorm migration:show -d dist/data-source.js" ;;
    typeorm-3) run_as_app "npx typeorm migration:revert -d dist/data-source.js" ;;
    typeorm-4)
      read -rp "  Nom de la migration : " M
      run_as_app "npx typeorm migration:generate -d dist/data-source.js src/migrations/\$M"
      ;;
    typeorm-5)
      # Cherche dans plusieurs emplacements typiques
      F=""
      SEEDS_DIR=""
      for d in dist/seeds dist/database/seeds dist/db/seeds; do
        if [ -d "\$CURRENT/\$d" ]; then
          SEEDS_DIR="\$CURRENT/\$d"
          F=\$(pick_file "\$SEEDS_DIR" "*.js")
          break
        fi
      done
      [ -z "\$F" ] && { echo "Aucun dossier seeds trouvé (essaye dist/seeds/, dist/database/seeds/)"; return; }
      if [ "\$F" = "__ALL__" ]; then
        shopt -s nullglob
        for s in "\$SEEDS_DIR"/*.js; do
          [ -f "\$s" ] && run_as_app "node '\$s'"
        done
        shopt -u nullglob
      else
        run_as_app "node '\$F'"
      fi
      ;;
    typeorm-6) run_as_app "npx typeorm schema:log -d dist/data-source.js" ;;

    # ─── Knex ───
    knex-1) run_as_app "npx knex migrate:latest --env production" ;;
    knex-2) run_as_app "npx knex migrate:status --env production" ;;
    knex-3) run_as_app "npx knex migrate:rollback --env production" ;;
    knex-4) run_as_app "npx knex migrate:down --env production" ;;
    knex-5)
      F=""
      for d in seeds db/seeds database/seeds; do
        if [ -d "\$CURRENT/\$d" ]; then
          F=\$(pick_file "\$CURRENT/\$d" "*.js")
          break
        fi
      done
      [ -z "\$F" ] && return
      if [ "\$F" = "__ALL__" ]; then
        run_as_app "npx knex seed:run --env production"
      else
        run_as_app "npx knex seed:run --env production --specific '\$(basename "\$F")'"
      fi
      ;;

    # ─── Drizzle ───
    drizzle-1) run_as_app "npx drizzle-kit migrate" ;;
    drizzle-2)
      read -rp "  Nom (optionnel) : " M
      [ -n "\$M" ] && run_as_app "npx drizzle-kit generate --name '\$M'" || run_as_app "npx drizzle-kit generate"
      ;;
    drizzle-3) confirm_destructive && run_as_app "npx drizzle-kit push" ;;
    drizzle-4) run_as_app "npx drizzle-kit pull" ;;
    drizzle-5)
      F=""
      SEEDS_DIR=""
      for d in src/seeds db/seeds database/seeds dist/seeds; do
        if [ -d "\$CURRENT/\$d" ]; then
          SEEDS_DIR="\$CURRENT/\$d"
          F=\$(pick_file "\$SEEDS_DIR" "*.js,*.ts")
          break
        fi
      done
      [ -z "\$F" ] && { echo "Aucun dossier seeds trouvé"; return; }
      if [ "\$F" = "__ALL__" ]; then
        shopt -s nullglob
        for s in "\$SEEDS_DIR"/*.js "\$SEEDS_DIR"/*.ts; do
          [ -f "\$s" ] && run_as_app "(npx tsx '\$s' 2>/dev/null || node '\$s')"
        done
        shopt -u nullglob
      else
        run_as_app "(npx tsx '\$F' 2>/dev/null || node '\$F')"
      fi
      ;;

    # ─── Commun ───
    *-c)
      echo ""
      echo "Scripts npm disponibles :"
      su -s /bin/bash "\$APP_NAME" -c "cd '\$CURRENT' && cat package.json | grep -A 100 '\"scripts\"' | grep -E '^\\s+\"' | head -30"
      echo ""
      read -rp "  Nom du script (sans 'npm run ') : " S
      [ -n "\$S" ] && run_as_app "npm run '\$S'"
      ;;
    *-r) systemctl reload "\$APP_NAME" && echo "✓ \$APP_NAME rechargé" ;;
    *-l) journalctl -u "\$APP_NAME" -n 50 --no-pager ;;
    *-q) exit 0 ;;

    *) echo -e "\${R}Choix invalide : \$choice\${N}" ;;
  esac
}

# Boucle principale
while true; do
  show_menu
  read -rp "Ton choix : " CHOICE
  exec_choice "\$CHOICE"
  echo ""
  read -rp "Appuie sur Entrée pour revenir au menu..." _
done
DBEOF

  chmod +x "$DB_SCRIPT"
  ok "DB Manager : $DB_SCRIPT"
fi

# ─── 10. Caddy (optionnel) ────────────────────────────────
if [ -n "$CADDY_DOMAIN" ]; then
  inf "Configuration Caddy pour $CADDY_DOMAIN..."
  CADDY_TYPE="api"
  [ "$FRAMEWORK" = "nextjs" ] && CADDY_TYPE="nextjs"
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

# ─── Health check : si en mode update et release existe, redémarrer + tester ─
if $IS_UPDATE && [ -L "$CURRENT_LINK" ] && [ -d "$(readlink -f "$CURRENT_LINK")" ]; then
  inf "Mode update : redémarrage du service avec la nouvelle config..."
  systemctl restart "$APP_NAME"
  sleep 3
  if systemctl is-active --quiet "$APP_NAME"; then
    ok "Service $APP_NAME actif après redémarrage"
  else
    warn "Service $APP_NAME inactif après redémarrage — vérifie les logs :"
    echo "    journalctl -u $APP_NAME -n 50 --no-pager"
    echo ""
    journalctl -u "$APP_NAME" -n 20 --no-pager
  fi
fi

echo ""
echo -e "${G}===============================================${N}"
echo -e "${G}  $APP_NAME ($FRAMEWORK) configuré             ${N}"
echo -e "${G}===============================================${N}"
echo ""
echo "  Dossier      : $APP_DIR"
echo "  Port         : $APP_PORT"
[ -n "$ENTRY" ] && echo "  Entry point  : $ENTRY"
echo "  Utilisateur  : $APP_NAME"
echo "  Env          : $ENV_FILE"
echo "  Superviseur  : systemd direct (pas de PM2)"
echo "  Releases     : $RELEASES_DIR/"
echo "  ORM          : $ORM"
if [ ${#PERSISTENT_DIRS[@]} -gt 0 ]; then
  echo "  Persistants  : ${PERSISTENT_DIRS[*]}"
fi
[ -n "$KEEP_DEV_DEPS" ] && echo "  DevDeps prod : $KEEP_DEV_DEPS"
[ -n "$CADDY_DOMAIN" ] && echo "  URL publique : https://$CADDY_DOMAIN"
[ "$ORM" != "none" ] && echo "  DB Manager   : sudo bash /opt/shared/scripts/$APP_NAME-db.sh"
echo ""
echo -e "${Y}Pour déployer ton app :${N}"
echo ""
echo "  # 1. Envoie le CODE SOURCE complet (sans build artifacts)"
echo "  # Sur ta machine de dev :"
echo "  rsync -avz --delete \\"
echo "    --exclude 'node_modules' \\"
echo "    --exclude 'dist' \\"
echo "    --exclude '.next' \\"
echo "    --exclude '.git' \\"
echo "    --exclude '.env*' \\"
echo "    -e 'ssh -p <PORT>' \\"
echo "    ./ admin@<IP>:/tmp/$APP_NAME-src/"
echo ""
echo "  # 2. Sur le serveur, le script installe les deps + build + migre"
echo "  sudo bash $DEPLOY_SCRIPT /tmp/$APP_NAME-src"
echo ""
echo "  Le serveur exécute dans l'ordre :"
echo "    npm ci --include=dev   (full deps)"
if [ -n "$BUILD_CMD" ]; then
  echo "    $BUILD_CMD"
fi
if [ -n "$MIGRATION_CMD" ]; then
  echo "    $MIGRATION_CMD"
fi
echo "    npm prune --omit=dev   (retire devDependencies)"
[ -n "$KEEP_DEV_DEPS" ] && echo "    npm install --no-save $KEEP_DEV_DEPS   (devDeps à garder en prod)"
echo "    swap current → nouvelle release"
echo "    systemctl restart + health check (rollback auto si KO)"
echo ""
echo "Commandes utiles :"
echo "  systemctl start|stop|restart|status $APP_NAME"
echo "  journalctl -u $APP_NAME -f       # logs systemd"
echo "  tail -f $APP_DIR/logs/systemd.log"
echo "  ls -lt $RELEASES_DIR/             # releases disponibles"
if [ "$ORM" != "none" ]; then
  echo ""
  echo -e "${Y}DB Manager (menu interactif) :${N}"
  echo "  sudo bash /opt/shared/scripts/$APP_NAME-db.sh"
  echo "  → menu numéroté pour migrations, seeds (tous ou un seul), studio, etc."
fi
