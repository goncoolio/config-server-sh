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
echo "  1) NestJS   — entry: dist/main.js"
echo "  2) Express  — entry personnalisable (ex: src/server.js, api.js)"
echo "  3) Next.js  — entry: node_modules/next/dist/bin/next (start)"
read -rp "Choix [1-3] : " FW_CHOICE

case "$FW_CHOICE" in
  1) FRAMEWORK="nestjs";  DEFAULT_ENTRY="dist/main.js" ;;
  2) FRAMEWORK="express"; DEFAULT_ENTRY="src/server.js" ;;
  3) FRAMEWORK="nextjs";  DEFAULT_ENTRY="node_modules/next/dist/bin/next" ;;
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

if [ "$FRAMEWORK" = "express" ]; then
  read -rp "Entry point (relatif à current/, défaut: $DEFAULT_ENTRY) : " ENTRY
  ENTRY="${ENTRY:-$DEFAULT_ENTRY}"
else
  ENTRY="$DEFAULT_ENTRY"
fi

read -rp "DATABASE_URL (laisse vide pour ignorer) : " DB_URL
read -rp "Node managera via 'npm start' ? (oui/non, défaut: non pour NestJS/Express, oui pour Next.js) : " USE_NPM_START
if [ -z "$USE_NPM_START" ]; then
  [ "$FRAMEWORK" = "nextjs" ] && USE_NPM_START="oui" || USE_NPM_START="non"
fi

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

# ─── 2. PM2 ───────────────────────────────────────────────
if ! command -v pm2 &>/dev/null; then
  inf "Installation de PM2..."
  npm install -g pm2
  ok "PM2 $(pm2 -v)"
else
  ok "PM2 déjà installé"
fi

# ─── 3. Utilisateur système ───────────────────────────────
if ! id "$APP_NAME" &>/dev/null; then
  useradd -m -s /bin/bash -d "$APP_DIR" -c "Service $APP_NAME" "$APP_NAME"
  ok "Utilisateur $APP_NAME créé"
else
  ok "Utilisateur $APP_NAME existe"
fi

# ─── 4. Structure de répertoires (releases-based) ─────────
inf "Préparation de $APP_DIR..."
mkdir -p "$RELEASES_DIR" "$APP_DIR/shared" "$APP_DIR/logs"
chown -R "$APP_NAME":"$APP_NAME" "$APP_DIR"
chmod 750 "$APP_DIR"
ok "Structure prête : releases/, shared/, logs/, current→"

# ─── 5. Fichier .env (shared, persiste entre releases) ────
inf "Génération de $ENV_FILE..."
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
chown root:"$APP_NAME" "$ENV_FILE"
chmod 640 "$ENV_FILE"
ok ".env créé (chmod 640)"

# ─── 6. ecosystem.config.js (dans shared/, référence current/) ─
PM2_CONFIG="$APP_DIR/shared/ecosystem.config.js"

# Construire la section script/args selon le framework
if [ "$USE_NPM_START" = "oui" ]; then
  SCRIPT_LINE="script: 'npm',"
  ARGS_LINE="args: 'start',"
elif [ "$FRAMEWORK" = "nextjs" ]; then
  SCRIPT_LINE="script: './$ENTRY',"
  ARGS_LINE="args: 'start -p $APP_PORT',"
else
  SCRIPT_LINE="script: './$ENTRY',"
  ARGS_LINE=""
fi

cat > "$PM2_CONFIG" << EOF
// Config PM2 pour $APP_NAME ($FRAMEWORK) — HTIC-NETWORKS
module.exports = {
  apps: [{
    name: '$APP_NAME',
    cwd: '$CURRENT_LINK',
    $SCRIPT_LINE
    $ARGS_LINE

    instances: 1,
    exec_mode: 'fork',

    env_file: '$ENV_FILE',
    env: {
      NODE_ENV: 'production',
      PORT: $APP_PORT,
    },

    watch: false,
    autorestart: true,
    max_restarts: 10,
    restart_delay: 5000,
    min_uptime: '10s',

    out_file: '$APP_DIR/logs/out.log',
    error_file: '$APP_DIR/logs/err.log',
    log_date_format: 'YYYY-MM-DD HH:mm:ss',
    merge_logs: true,

    max_memory_restart: '512M',
    kill_timeout: 5000,
    listen_timeout: 3000,
  }]
}
EOF
chown "$APP_NAME":"$APP_NAME" "$PM2_CONFIG"
ok "Config PM2 générée"

# ─── 7. Service systemd ───────────────────────────────────
inf "Configuration de systemd..."
cat > "/etc/systemd/system/$APP_NAME.service" << EOF
[Unit]
Description=$APP_NAME — $FRAMEWORK via PM2
After=network-online.target postgresql.service
Wants=network-online.target

[Service]
Type=forking
User=$APP_NAME
Group=$APP_NAME
WorkingDirectory=$APP_DIR

Environment=PM2_HOME=$APP_DIR/.pm2
ExecStart=$(which pm2) start $PM2_CONFIG --env production
ExecReload=$(which pm2) reload $APP_NAME
ExecStop=$(which pm2) stop $APP_NAME

Restart=on-failure
RestartSec=10s

StandardOutput=append:$APP_DIR/logs/systemd.log
StandardError=append:$APP_DIR/logs/systemd-err.log

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable "$APP_NAME"
ok "Service systemd $APP_NAME activé"

# ─── 8. Logrotate ─────────────────────────────────────────
cat > "/etc/logrotate.d/$APP_NAME" << EOF
$APP_DIR/logs/*.log {
    daily
    rotate 14
    compress
    missingok
    notifempty
    create 640 $APP_NAME $APP_NAME
    postrotate
        su -s /bin/bash $APP_NAME -c "pm2 reloadLogs" 2>/dev/null || true
    endscript
}
EOF

# ─── 9. Script de déploiement (releases + symlink) ────────
mkdir -p /opt/shared/scripts
DEPLOY_SCRIPT="/opt/shared/scripts/deploy-$APP_NAME.sh"

cat > "$DEPLOY_SCRIPT" << DEPLOYEOF
#!/bin/bash
# Déployer une nouvelle version de $APP_NAME ($FRAMEWORK)
# Usage : sudo bash $DEPLOY_SCRIPT <source_dir>
#
# <source_dir> doit contenir le CODE SOURCE complet (envoyé sans
# dist/, .next/, node_modules/, .git/) — tout est construit sur le serveur.
#
# Pipeline :
#   1. Copie source dans releases/<timestamp>/
#   2. npm ci  (toutes les deps, devDependencies incluses)
#   3. npm run build (si framework nécessite)
#   4. Migrations DB (si configurées)
#   5. npm prune --omit=dev  (supprime les devDependencies)
#   6. Bascule atomique du symlink current
#   7. Reload PM2 (zero-downtime)
#   8. Purge les vieilles releases (garde 5)
set -euo pipefail

SRC=\${1:-""}
[ -z "\$SRC" ] && { echo "Usage: \$0 <source_dir>"; exit 1; }
[ ! -d "\$SRC" ] && { echo "Dossier introuvable: \$SRC"; exit 1; }
[ ! -f "\$SRC/package.json" ] && { echo "package.json absent de \$SRC"; exit 1; }

APP_NAME="$APP_NAME"
APP_DIR="$APP_DIR"
FRAMEWORK="$FRAMEWORK"
BUILD_CMD="$BUILD_CMD"
MIGRATION_CMD="$MIGRATION_CMD"
RELEASES_DIR="\$APP_DIR/releases"
CURRENT_LINK="\$APP_DIR/current"

TS=\$(date +%Y%m%d_%H%M%S)
NEW_RELEASE="\$RELEASES_DIR/\$TS"

echo "→ Création de \$NEW_RELEASE"
mkdir -p "\$NEW_RELEASE"
cp -a "\$SRC"/. "\$NEW_RELEASE"/
# Sécurité : purger les artefacts de build envoyés par erreur
rm -rf "\$NEW_RELEASE/node_modules" "\$NEW_RELEASE/dist" "\$NEW_RELEASE/.next"
chown -R \$APP_NAME:\$APP_NAME "\$NEW_RELEASE"

echo "→ Lien symbolique shared/.env → \$NEW_RELEASE/.env"
ln -sfn "\$APP_DIR/shared/.env" "\$NEW_RELEASE/.env"

# Limite la RAM Node pour éviter l'OOM sur petites VM
NPM_ENV="NODE_OPTIONS=--max-old-space-size=1024"

echo "→ Installation des dépendances (devDependencies incluses pour le build)..."
if [ -f "\$NEW_RELEASE/package-lock.json" ]; then
  if ! su -s /bin/bash \$APP_NAME -c "cd \$NEW_RELEASE && \$NPM_ENV npm ci --include=dev --no-audit --no-fund"; then
    echo ""
    echo "  ⚠ npm ci échoué — fallback sur npm install"
    echo "     Cause probable : lock file généré sur autre OS/arch (deps optionnelles manquantes)"
    echo "     Fix long-terme côté dev : rm -rf node_modules package-lock.json && npm install"
    echo ""
    su -s /bin/bash \$APP_NAME -c "cd \$NEW_RELEASE && \$NPM_ENV npm install --include=dev --no-audit --no-fund"
  fi
else
  echo "  ⚠ package-lock.json absent — npm install (moins reproductible)"
  su -s /bin/bash \$APP_NAME -c "cd \$NEW_RELEASE && \$NPM_ENV npm install --include=dev --no-audit --no-fund"
fi

if [ -n "\$BUILD_CMD" ]; then
  echo "→ Build : \$BUILD_CMD"
  if ! su -s /bin/bash \$APP_NAME -c "cd \$NEW_RELEASE && set -a && . \$APP_DIR/shared/.env && set +a && \$NPM_ENV \$BUILD_CMD"; then
    echo "✗ Build échoué — swap annulé (release ratée : \$NEW_RELEASE)"
    exit 1
  fi
fi

if [ -n "\$MIGRATION_CMD" ]; then
  echo "→ Migrations DB : \$MIGRATION_CMD"
  if ! su -s /bin/bash \$APP_NAME -c "cd \$NEW_RELEASE && set -a && . \$APP_DIR/shared/.env && set +a && \$NPM_ENV \$MIGRATION_CMD"; then
    echo "✗ Migration échouée — swap annulé (release ratée : \$NEW_RELEASE)"
    exit 1
  fi
fi

echo "→ Suppression des devDependencies..."
su -s /bin/bash \$APP_NAME -c "cd \$NEW_RELEASE && \$NPM_ENV npm prune --omit=dev"

# Nettoyage spécifique au framework : sources TS inutiles à l'exécution
case "\$FRAMEWORK" in
  nestjs)
    # dist/ suffit pour le runtime
    rm -rf "\$NEW_RELEASE/src" "\$NEW_RELEASE/test" "\$NEW_RELEASE/tsconfig"*.json "\$NEW_RELEASE/nest-cli.json" 2>/dev/null || true
    ;;
  nextjs)
    # .next/ + public/ + next.config + node_modules prod suffisent
    # Garder app/ ou pages/ pour les API routes runtime ? Next.js 13+ n'en a pas besoin.
    # On laisse pour éviter les surprises.
    :
    ;;
esac

echo "→ Bascule du symlink current"
ln -sfn "\$NEW_RELEASE" "\$CURRENT_LINK"
chown -h \$APP_NAME:\$APP_NAME "\$CURRENT_LINK"

echo "→ Reload PM2 (zero-downtime)..."
if systemctl is-active --quiet \$APP_NAME; then
  su -s /bin/bash \$APP_NAME -c "pm2 reload \$APP_NAME" || systemctl restart \$APP_NAME
else
  systemctl start \$APP_NAME
fi

sleep 2
systemctl status \$APP_NAME --no-pager -l | head -15

echo "→ Purge des vieilles releases (garde 5)..."
cd "\$RELEASES_DIR"
ls -1t | tail -n +6 | xargs -r rm -rf

echo ""
echo "✓ Déploiement terminé — release \$TS active"
echo "  Rollback : sudo ln -sfn \$RELEASES_DIR/<ancien> \$CURRENT_LINK && sudo systemctl reload \$APP_NAME"
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
  local pattern="\$2"
  local files=()
  if [ ! -d "\$dir" ]; then
    echo "" >&2
    echo -e "\${R}Dossier introuvable : \$dir\${N}" >&2
    return 1
  fi
  while IFS= read -r f; do
    files+=("\$f")
  done < <(find "\$dir" -maxdepth 2 -type f \\( -name "\$pattern" \\) 2>/dev/null | sort)

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
      for d in dist/seeds dist/database/seeds dist/db/seeds; do
        if [ -d "\$CURRENT/\$d" ]; then
          F=\$(pick_file "\$CURRENT/\$d" "*.js")
          break
        fi
      done
      [ -z "\$F" ] && { echo "Aucun dossier seeds trouvé (essaye dist/seeds/, dist/database/seeds/)"; return; }
      if [ "\$F" = "__ALL__" ]; then
        for s in "\$CURRENT"/dist/seeds/*.js "\$CURRENT"/dist/database/seeds/*.js 2>/dev/null; do
          [ -f "\$s" ] && run_as_app "node '\$s'"
        done
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
      for d in src/seeds db/seeds database/seeds dist/seeds; do
        if [ -d "\$CURRENT/\$d" ]; then
          F=\$(pick_file "\$CURRENT/\$d" "*.{js,ts}")
          break
        fi
      done
      [ -z "\$F" ] && return
      if [ "\$F" = "__ALL__" ]; then
        for s in "\$CURRENT"/src/seeds/* "\$CURRENT"/db/seeds/* "\$CURRENT"/database/seeds/* "\$CURRENT"/dist/seeds/* 2>/dev/null; do
          [ -f "\$s" ] && run_as_app "npx tsx '\$s' || node '\$s'"
        done
      else
        run_as_app "npx tsx '\$F' || node '\$F'"
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
echo -e "${G}===============================================${N}"
echo -e "${G}  $APP_NAME ($FRAMEWORK) configuré             ${N}"
echo -e "${G}===============================================${N}"
echo ""
echo "  Dossier      : $APP_DIR"
echo "  Port         : $APP_PORT"
echo "  Entry point  : $ENTRY"
echo "  Utilisateur  : $APP_NAME"
echo "  Env          : $ENV_FILE"
echo "  PM2 config   : $PM2_CONFIG"
echo "  Releases     : $RELEASES_DIR/"
echo "  ORM          : $ORM"
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
echo "    swap current → nouvelle release + reload PM2"
echo ""
echo "Commandes utiles :"
echo "  systemctl start|status|reload $APP_NAME"
echo "  su -s /bin/bash $APP_NAME -c 'pm2 list'"
echo "  tail -f $APP_DIR/logs/err.log"
echo "  ls -lt $RELEASES_DIR/   # releases disponibles"
if [ "$ORM" != "none" ]; then
  echo ""
  echo -e "${Y}DB Manager (menu interactif) :${N}"
  echo "  sudo bash /opt/shared/scripts/$APP_NAME-db.sh"
  echo "  → menu numéroté pour migrations, seeds (tous ou un seul), studio, etc."
fi
