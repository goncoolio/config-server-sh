#!/bin/bash
# =========================================================
# SCRIPT 3 — Installation de bases de données (menu)
# Ubuntu 24.04 — HTIC-NETWORKS
# Usage : sudo bash 03-install-database.sh
#
# Bases supportées :
#   1) PostgreSQL   (versions 13 à 17)
#   2) MySQL        (versions 8.0, 8.4 LTS)
#   3) MariaDB      (versions 10.6, 10.11, 11.4 LTS)
#   4) MongoDB      (versions 6.0, 7.0, 8.0)
#   5) Redis        (versions 6.x, 7.x)
#   6) Supabase     (Postgres + Auth/Realtime/Storage via Docker)
#
# Toutes les bases peuvent COEXISTER sur le même serveur.
# Backups quotidiens automatiques (rotation 7j + 4 semaines).
# Web UI optionnelles (Adminer/phpMyAdmin/Mongo Express/RedisInsight).
# =========================================================
set -uo pipefail

G='\033[0;32m'; Y='\033[1;33m'; R='\033[0;31m'; C='\033[0;36m'; B='\033[1m'; N='\033[0m'
ok()  { echo -e "${G}[OK]${N} $1"; }
warn(){ echo -e "${Y}[AVERT]${N} $1"; }
err() { echo -e "${R}[ERREUR]${N} $1"; exit 1; }
inf() { echo -e "${C}----> $1${N}"; }

[ "$EUID" -ne 0 ] && err "Lance avec sudo : sudo bash $0"

CREDS_DIR="/root/db-credentials"
mkdir -p "$CREDS_DIR"
chmod 700 "$CREDS_DIR"

BACKUPS_BASE="/var/backups"

# =========================================================
# HELPERS COMMUNS
# =========================================================

# Demande Y/N avec défaut
confirm() {
  local prompt="$1"
  local default="${2:-y}"
  local hint="[Y/n]"
  [ "$default" = "n" ] && hint="[y/N]"
  read -rp "  $prompt $hint : " R
  R="${R:-$default}"
  [[ "$R" =~ ^[YyOo]$ ]] || [ "$R" = "oui" ]
}

# Génère un mot de passe aléatoire
gen_password() {
  tr -dc 'A-Za-z0-9' </dev/urandom | head -c "${1:-24}"
}

# Sauvegarde des credentials dans un fichier dédié
save_creds() {
  local dbname="$1"
  shift
  local file="$CREDS_DIR/${dbname}-$(date +%Y%m%d_%H%M%S).txt"
  {
    echo "# $dbname — HTIC-NETWORKS — $(date)"
    echo "# À supprimer après avoir noté !"
    echo ""
    echo "$@"
  } > "$file"
  chmod 600 "$file"
  echo ""
  warn "Credentials sauvegardés : $file"
  echo "  → Note-les dans ton gestionnaire de mots de passe puis supprime ce fichier"
}

# Configure un cron de backup quotidien (rotation 7j + 4 semaines)
# Usage : setup_backup_cron <dbname> <commande_dump> <extension>
setup_backup_cron() {
  local dbname="$1"
  local dump_cmd="$2"
  local ext="${3:-sql.gz}"
  local backup_dir="$BACKUPS_BASE/$dbname"

  mkdir -p "$backup_dir"
  chmod 750 "$backup_dir"

  local script="/usr/local/bin/backup-$dbname.sh"
  cat > "$script" << EOF
#!/bin/bash
# Backup automatique $dbname — HTIC-NETWORKS
set -uo pipefail

BACKUP_DIR="$backup_dir"
DATE=\$(date +%Y%m%d_%H%M%S)
DOW=\$(date +%u)   # 1=lundi, 7=dimanche
DOM=\$(date +%d)   # jour du mois

mkdir -p "\$BACKUP_DIR/daily" "\$BACKUP_DIR/weekly"

# Backup quotidien
DAILY_FILE="\$BACKUP_DIR/daily/${dbname}-\$DATE.${ext}"
$dump_cmd > "\$DAILY_FILE" 2>>"\$BACKUP_DIR/backup.log"

if [ -s "\$DAILY_FILE" ]; then
  chmod 600 "\$DAILY_FILE"
  echo "[\$(date '+%Y-%m-%d %H:%M:%S')] OK — \$DAILY_FILE (\$(du -h "\$DAILY_FILE" | cut -f1))" >> "\$BACKUP_DIR/backup.log"
else
  echo "[\$(date '+%Y-%m-%d %H:%M:%S')] ERREUR — \$DAILY_FILE vide" >> "\$BACKUP_DIR/backup.log"
  rm -f "\$DAILY_FILE"
  exit 1
fi

# Backup hebdomadaire (dimanche → snapshot)
if [ "\$DOW" = "7" ]; then
  cp "\$DAILY_FILE" "\$BACKUP_DIR/weekly/${dbname}-week-\$(date +%Y-W%V).${ext}"
fi

# Rotation : garder 7 backups quotidiens, 4 hebdomadaires
find "\$BACKUP_DIR/daily/" -type f -name "${dbname}-*.${ext}" -mtime +7 -delete
find "\$BACKUP_DIR/weekly/" -type f -name "${dbname}-week-*.${ext}" -mtime +28 -delete
EOF
  chmod +x "$script"

  # Cron : tous les jours à 3h
  cat > "/etc/cron.d/backup-$dbname" << EOF
# Backup automatique $dbname — HTIC-NETWORKS
0 3 * * * root $script
EOF
  chmod 644 "/etc/cron.d/backup-$dbname"

  ok "Backup cron configuré : $script (3h00 quotidien, $backup_dir/)"
}

# Vérifie qu'un port est libre, propose une alternative sinon
ensure_port_free() {
  local default_port="$1"
  local label="$2"
  local port="$default_port"

  if ss -tlnp 2>/dev/null | grep -q ":$port "; then
    warn "Port $port déjà occupé — propose un autre"
    while ss -tlnp 2>/dev/null | grep -q ":$port "; do
      port=$((port + 1))
    done
    read -rp "  Port pour $label [$port] : " UP
    port="${UP:-$port}"
  fi
  echo "$port"
}

# Génère un bloc Caddy pour une UI web protégée par basic auth
ensure_caddy_ui() {
  local domain="$1"
  local upstream_port="$2"
  local label="$3"

  if ! command -v caddy &>/dev/null; then
    warn "Caddy non installé — ignore la configuration HTTPS pour $label"
    return
  fi

  read -rp "  Identifiant pour $label : " UI_USER
  read -rsp "  Mot de passe pour $label : " UI_PASS
  echo ""

  local hash
  hash=$(caddy hash-password --plaintext "$UI_PASS")

  local site_file="/etc/caddy/sites-enabled/${domain}.caddy"
  local log_name
  log_name=$(echo "$domain" | tr '.' '_')

  cat > "$site_file" << EOF
# $label — $domain — généré le $(date)
$domain {
    import security-headers
    import site-log $log_name

    basicauth /* {
        $UI_USER $hash
    }

    reverse_proxy localhost:$upstream_port
}
EOF

  if caddy validate --config /etc/caddy/Caddyfile 2>/dev/null; then
    systemctl reload caddy
    ok "Caddy : https://$domain → localhost:$upstream_port (Basic Auth)"
  else
    warn "Caddyfile invalide, vérifie $site_file"
  fi
}

# =========================================================
# POSTGRESQL
# =========================================================
install_postgresql() {
  echo ""
  echo -e "${B}━━ Installation PostgreSQL ━━${N}"

  echo "Versions disponibles : 13, 14, 15, 16, 17"
  read -rp "Version PostgreSQL [16] : " PG_VER
  PG_VER="${PG_VER:-16}"
  case "$PG_VER" in
    13|14|15|16|17) ;;
    *) err "Version invalide : $PG_VER" ;;
  esac

  # Dépôt PGDG
  inf "Ajout du dépôt PGDG (PostgreSQL Global Development Group)..."
  apt-get install -y -qq curl ca-certificates gnupg lsb-release
  install -d /usr/share/postgresql-common/pgdg
  curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
    -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc
  echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] \
https://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" \
    > /etc/apt/sources.list.d/pgdg.list
  apt-get update -qq
  apt-get install -y "postgresql-$PG_VER" "postgresql-client-$PG_VER" "postgresql-contrib-$PG_VER"
  ok "PostgreSQL $PG_VER installé"

  # Tuning automatique
  RAM_MB=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
  SHARED_MB=$((RAM_MB / 4))
  CACHE_MB=$((RAM_MB * 3 / 4))
  PG_CONF="/etc/postgresql/$PG_VER/main/postgresql.conf"

  if ! grep -q "Tuning HTIC-NETWORKS" "$PG_CONF"; then
    cp "$PG_CONF" "${PG_CONF}.bak"
    cat >> "$PG_CONF" << EOF

# ── Tuning HTIC-NETWORKS ────────────────────────────────
shared_buffers            = ${SHARED_MB}MB
effective_cache_size      = ${CACHE_MB}MB
work_mem                  = 16MB
maintenance_work_mem      = 64MB
max_connections           = 100
wal_buffers               = 16MB
checkpoint_completion_target = 0.9
log_min_duration_statement = 1000
log_lock_waits            = on
password_encryption       = scram-sha-256
ssl                       = on
EOF
    ok "Tuning appliqué (RAM=${RAM_MB}MB, shared_buffers=${SHARED_MB}MB)"
  fi

  # Sécurisation pg_hba (localhost uniquement)
  HBA="/etc/postgresql/$PG_VER/main/pg_hba.conf"
  if ! grep -q "Sécurisé HTIC" "$HBA"; then
    cp "$HBA" "${HBA}.bak"
    cat > "$HBA" << 'EOF'
# Sécurisé HTIC-NETWORKS — localhost uniquement
local    all        postgres                   peer
local    all        all                        scram-sha-256
host     all        all        127.0.0.1/32    scram-sha-256
host     all        all        ::1/128         scram-sha-256
EOF
    ok "pg_hba.conf sécurisé (localhost + socket Unix)"
  fi

  systemctl enable postgresql
  systemctl restart postgresql
  ok "PostgreSQL démarré"

  # Création des bases applicatives
  echo ""
  read -rp "Combien de bases à créer maintenant ? [0] : " NB
  NB="${NB:-0}"

  CREDS_LINES=""
  for i in $(seq 1 "$NB" 2>/dev/null); do
    [ "$NB" = "0" ] && break
    echo ""
    echo -e "${C}--- Base #$i ---${N}"
    read -rp "  Nom du rôle (user)  : " PG_ROLE
    read -rp "  Nom de la base      : " PG_DB
    read -rsp "  Mot de passe        : " PG_PASS
    echo ""

    sudo -u postgres psql << SQL
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '$PG_ROLE') THEN
    CREATE ROLE "$PG_ROLE" LOGIN PASSWORD '$PG_PASS';
  ELSE
    ALTER ROLE "$PG_ROLE" PASSWORD '$PG_PASS';
  END IF;
END
\$\$;

SELECT 'CREATE DATABASE "$PG_DB" OWNER "$PG_ROLE" ENCODING ''UTF8'''
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '$PG_DB')\gexec

GRANT ALL ON DATABASE "$PG_DB" TO "$PG_ROLE";
REVOKE ALL ON DATABASE "$PG_DB" FROM PUBLIC;
SQL

    sudo -u postgres psql -d "$PG_DB" << SQL
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";
CREATE EXTENSION IF NOT EXISTS "pg_trgm";
CREATE EXTENSION IF NOT EXISTS "unaccent";
SQL

    ok "Base $PG_DB créée (rôle: $PG_ROLE, extensions activées)"
    CREDS_LINES="$CREDS_LINES
DATABASE_URL=postgresql://$PG_ROLE:$PG_PASS@127.0.0.1:5432/$PG_DB"
  done

  [ -n "$CREDS_LINES" ] && save_creds "postgresql" "$CREDS_LINES"

  # Backup cron
  echo ""
  if confirm "Activer les backups automatiques quotidiens ?" "y"; then
    setup_backup_cron "postgresql" \
      "sudo -u postgres pg_dumpall | gzip" \
      "sql.gz"
  fi

  # Web UI : Adminer (déjà installé via 06-adminer-hardening.sh)
  echo ""
  if confirm "Installer Adminer (UI web pour PG/MySQL/MariaDB/SQLite) ?" "y"; then
    install_adminer
  fi

  ok "PostgreSQL prêt (port 5432)"
}

# =========================================================
# MYSQL (Oracle)
# =========================================================
install_mysql() {
  echo ""
  echo -e "${B}━━ Installation MySQL ━━${N}"

  if command -v mariadbd &>/dev/null || dpkg -l mariadb-server 2>/dev/null | grep -q '^ii'; then
    err "MariaDB est déjà installé — incompatible avec MySQL sur le port 3306. Annule."
  fi

  echo "Versions disponibles : 8.0, 8.4 (LTS)"
  read -rp "Version MySQL [8.4] : " MY_VER
  MY_VER="${MY_VER:-8.4}"
  case "$MY_VER" in
    8.0|8.4) ;;
    *) err "Version invalide : $MY_VER" ;;
  esac

  # Dépôt officiel MySQL
  inf "Ajout du dépôt officiel Oracle MySQL..."
  apt-get install -y -qq curl gnupg lsb-release wget

  # Récupérer la version courante du paquet de configuration MySQL APT
  TMP_DEB=$(mktemp --suffix=.deb)
  wget -q "https://dev.mysql.com/get/mysql-apt-config_0.8.32-1_all.deb" -O "$TMP_DEB"

  # Pré-configuration debconf pour automatiser le choix de version
  echo "mysql-apt-config mysql-apt-config/select-server select mysql-${MY_VER}-lts" \
    | debconf-set-selections
  echo "mysql-apt-config mysql-apt-config/select-product select Ok" \
    | debconf-set-selections

  DEBIAN_FRONTEND=noninteractive dpkg -i "$TMP_DEB" || true
  rm -f "$TMP_DEB"
  apt-get update -qq

  # Mot de passe root
  ROOT_PASS=$(gen_password 32)
  echo "mysql-community-server mysql-community-server/root-pass password $ROOT_PASS" \
    | debconf-set-selections
  echo "mysql-community-server mysql-community-server/re-root-pass password $ROOT_PASS" \
    | debconf-set-selections
  echo "mysql-community-server mysql-community-server/default-auth-override select Use Strong Password Encryption (RECOMMENDED)" \
    | debconf-set-selections

  DEBIAN_FRONTEND=noninteractive apt-get install -y mysql-server mysql-client
  ok "MySQL $MY_VER installé"

  # Bind localhost
  cat > /etc/mysql/mysql.conf.d/zz-htic.cnf << 'EOF'
# Hardening HTIC-NETWORKS
[mysqld]
bind-address              = 127.0.0.1
max_connections           = 100
default_authentication_plugin = caching_sha2_password
log_error                 = /var/log/mysql/error.log
slow_query_log            = 1
long_query_time           = 2

[mysql]
default-character-set     = utf8mb4

[client]
default-character-set     = utf8mb4
EOF

  systemctl enable mysql
  systemctl restart mysql
  ok "MySQL démarré (bind 127.0.0.1)"

  # Bases applicatives
  echo ""
  read -rp "Combien de bases à créer maintenant ? [0] : " NB
  NB="${NB:-0}"

  CREDS_LINES="ROOT_PASSWORD=$ROOT_PASS
ROOT_HOST=127.0.0.1
ROOT_PORT=3306
"
  for i in $(seq 1 "$NB" 2>/dev/null); do
    [ "$NB" = "0" ] && break
    echo ""
    echo -e "${C}--- Base #$i ---${N}"
    read -rp "  Nom du user      : " MY_USER
    read -rp "  Nom de la base   : " MY_DB
    read -rsp "  Mot de passe     : " MY_PASS
    echo ""

    mysql -u root -p"$ROOT_PASS" << SQL
CREATE DATABASE IF NOT EXISTS \`$MY_DB\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '$MY_USER'@'localhost' IDENTIFIED BY '$MY_PASS';
ALTER USER '$MY_USER'@'localhost' IDENTIFIED BY '$MY_PASS';
GRANT ALL PRIVILEGES ON \`$MY_DB\`.* TO '$MY_USER'@'localhost';
FLUSH PRIVILEGES;
SQL
    ok "Base $MY_DB créée (user: $MY_USER)"
    CREDS_LINES="$CREDS_LINES
DATABASE_URL=mysql://$MY_USER:$MY_PASS@127.0.0.1:3306/$MY_DB"
  done

  save_creds "mysql" "$CREDS_LINES"

  # Backup cron
  echo ""
  if confirm "Activer les backups automatiques quotidiens ?" "y"; then
    # Stocker le mot de passe root dans /root/.my.cnf pour le cron
    cat > /root/.my.cnf << EOF
[client]
user=root
password=$ROOT_PASS
host=127.0.0.1
EOF
    chmod 600 /root/.my.cnf

    setup_backup_cron "mysql" \
      "mysqldump --defaults-file=/root/.my.cnf --all-databases --single-transaction --routines --triggers --events | gzip" \
      "sql.gz"
  fi

  echo ""
  if confirm "Installer Adminer (supporte MySQL nativement) ?" "y"; then
    install_adminer
  fi

  echo ""
  if confirm "Installer phpMyAdmin (UI dédiée MySQL) ?" "n"; then
    install_phpmyadmin
  fi

  ok "MySQL prêt (port 3306)"
}

# =========================================================
# MARIADB
# =========================================================
install_mariadb() {
  echo ""
  echo -e "${B}━━ Installation MariaDB ━━${N}"

  if command -v mysqld &>/dev/null && ! command -v mariadbd &>/dev/null; then
    err "MySQL Oracle est déjà installé — incompatible avec MariaDB sur 3306. Annule."
  fi

  echo "Versions disponibles : 10.6 (LTS), 10.11 (LTS), 11.4 (LTS)"
  read -rp "Version MariaDB [11.4] : " MD_VER
  MD_VER="${MD_VER:-11.4}"
  case "$MD_VER" in
    10.6|10.11|11.4) ;;
    *) err "Version invalide : $MD_VER" ;;
  esac

  inf "Ajout du dépôt officiel MariaDB..."
  apt-get install -y -qq curl gnupg
  curl -fsSL https://mariadb.org/mariadb_release_signing_key.asc \
    | gpg --dearmor -o /usr/share/keyrings/mariadb-keyring.gpg
  echo "deb [signed-by=/usr/share/keyrings/mariadb-keyring.gpg] \
https://deb.mariadb.org/$MD_VER/ubuntu $(lsb_release -cs) main" \
    > /etc/apt/sources.list.d/mariadb.list
  apt-get update -qq

  ROOT_PASS=$(gen_password 32)
  echo "mariadb-server mariadb-server/root_password password $ROOT_PASS" \
    | debconf-set-selections
  echo "mariadb-server mariadb-server/root_password_again password $ROOT_PASS" \
    | debconf-set-selections

  DEBIAN_FRONTEND=noninteractive apt-get install -y mariadb-server mariadb-client
  ok "MariaDB $MD_VER installé"

  # Bind localhost
  cat > /etc/mysql/mariadb.conf.d/99-htic.cnf << 'EOF'
# Hardening HTIC-NETWORKS
[mysqld]
bind-address              = 127.0.0.1
max_connections           = 100
log_error                 = /var/log/mysql/error.log
slow_query_log            = 1
long_query_time           = 2
character-set-server      = utf8mb4
collation-server          = utf8mb4_unicode_ci

[client]
default-character-set     = utf8mb4
EOF

  systemctl enable mariadb
  systemctl restart mariadb

  # Définir le password root via socket (MariaDB 10.4+ utilise unix_socket par défaut)
  mysql -u root << SQL
ALTER USER 'root'@'localhost' IDENTIFIED BY '$ROOT_PASS';
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
DROP DATABASE IF EXISTS test;
FLUSH PRIVILEGES;
SQL
  ok "MariaDB démarré (bind 127.0.0.1, root sécurisé)"

  echo ""
  read -rp "Combien de bases à créer maintenant ? [0] : " NB
  NB="${NB:-0}"

  CREDS_LINES="ROOT_PASSWORD=$ROOT_PASS
ROOT_HOST=127.0.0.1
ROOT_PORT=3306
"
  for i in $(seq 1 "$NB" 2>/dev/null); do
    [ "$NB" = "0" ] && break
    echo ""
    echo -e "${C}--- Base #$i ---${N}"
    read -rp "  Nom du user      : " MD_USER
    read -rp "  Nom de la base   : " MD_DB
    read -rsp "  Mot de passe     : " MD_PASS
    echo ""

    mysql -u root -p"$ROOT_PASS" << SQL
CREATE DATABASE IF NOT EXISTS \`$MD_DB\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '$MD_USER'@'localhost' IDENTIFIED BY '$MD_PASS';
ALTER USER '$MD_USER'@'localhost' IDENTIFIED BY '$MD_PASS';
GRANT ALL PRIVILEGES ON \`$MD_DB\`.* TO '$MD_USER'@'localhost';
FLUSH PRIVILEGES;
SQL
    ok "Base $MD_DB créée (user: $MD_USER)"
    CREDS_LINES="$CREDS_LINES
DATABASE_URL=mysql://$MD_USER:$MD_PASS@127.0.0.1:3306/$MD_DB"
  done

  save_creds "mariadb" "$CREDS_LINES"

  echo ""
  if confirm "Activer les backups automatiques quotidiens ?" "y"; then
    cat > /root/.my.cnf << EOF
[client]
user=root
password=$ROOT_PASS
host=127.0.0.1
EOF
    chmod 600 /root/.my.cnf
    setup_backup_cron "mariadb" \
      "mariadb-dump --defaults-file=/root/.my.cnf --all-databases --single-transaction --routines --triggers --events | gzip" \
      "sql.gz"
  fi

  echo ""
  if confirm "Installer Adminer (supporte MariaDB nativement) ?" "y"; then
    install_adminer
  fi

  echo ""
  if confirm "Installer phpMyAdmin (UI dédiée) ?" "n"; then
    install_phpmyadmin
  fi

  ok "MariaDB prêt (port 3306)"
}

# =========================================================
# MONGODB
# =========================================================
install_mongodb() {
  echo ""
  echo -e "${B}━━ Installation MongoDB ━━${N}"

  echo "Versions disponibles : 6.0, 7.0, 8.0"
  read -rp "Version MongoDB [8.0] : " MG_VER
  MG_VER="${MG_VER:-8.0}"
  case "$MG_VER" in
    6.0|7.0|8.0) ;;
    *) err "Version invalide : $MG_VER" ;;
  esac

  inf "Ajout du dépôt officiel MongoDB..."
  apt-get install -y -qq curl gnupg ca-certificates
  curl -fsSL "https://www.mongodb.org/static/pgp/server-${MG_VER}.asc" \
    | gpg --dearmor -o "/usr/share/keyrings/mongodb-server-${MG_VER}.gpg"

  # MongoDB ne supporte pas encore officiellement Ubuntu 24.04 noble pour toutes les versions
  # On utilise jammy (22.04) qui est compatible
  UBUNTU_CODENAME=$(lsb_release -cs)
  case "$UBUNTU_CODENAME" in
    noble|mantic) MG_REPO="jammy" ;;  # fallback compatible
    *) MG_REPO="$UBUNTU_CODENAME" ;;
  esac

  echo "deb [signed-by=/usr/share/keyrings/mongodb-server-${MG_VER}.gpg] \
https://repo.mongodb.org/apt/ubuntu $MG_REPO/mongodb-org/${MG_VER} multiverse" \
    > "/etc/apt/sources.list.d/mongodb-org-${MG_VER}.list"

  apt-get update -qq
  apt-get install -y mongodb-org
  ok "MongoDB $MG_VER installé"

  # Bind localhost + auth
  cat > /etc/mongod.conf << 'EOF'
storage:
  dbPath: /var/lib/mongodb
systemLog:
  destination: file
  logAppend: true
  path: /var/log/mongodb/mongod.log
net:
  port: 27017
  bindIp: 127.0.0.1
processManagement:
  timeZoneInfo: /usr/share/zoneinfo
security:
  authorization: disabled  # désactivé temporairement pour créer l'admin
EOF

  systemctl enable mongod
  systemctl restart mongod
  sleep 3

  # Créer l'utilisateur admin
  ROOT_PASS=$(gen_password 32)
  inf "Création de l'utilisateur admin MongoDB..."
  mongosh --quiet << EOF
use admin
db.createUser({
  user: "admin",
  pwd: "$ROOT_PASS",
  roles: [ { role: "root", db: "admin" } ]
})
EOF

  # Activer l'authentification
  sed -i 's/authorization: disabled/authorization: enabled/' /etc/mongod.conf
  systemctl restart mongod
  sleep 2
  ok "Auth MongoDB activée (user admin créé)"

  # Bases applicatives
  echo ""
  read -rp "Combien de bases à créer maintenant ? [0] : " NB
  NB="${NB:-0}"

  CREDS_LINES="ADMIN_USER=admin
ADMIN_PASSWORD=$ROOT_PASS
ADMIN_HOST=127.0.0.1
ADMIN_PORT=27017
"
  for i in $(seq 1 "$NB" 2>/dev/null); do
    [ "$NB" = "0" ] && break
    echo ""
    echo -e "${C}--- Base #$i ---${N}"
    read -rp "  Nom de la base       : " MG_DB
    read -rp "  Nom du user          : " MG_USER
    read -rsp "  Mot de passe         : " MG_PASS
    echo ""

    mongosh --quiet -u admin -p "$ROOT_PASS" --authenticationDatabase admin << EOF
use $MG_DB
db.createUser({
  user: "$MG_USER",
  pwd: "$MG_PASS",
  roles: [ { role: "readWrite", db: "$MG_DB" }, { role: "dbAdmin", db: "$MG_DB" } ]
})
EOF
    ok "Base $MG_DB créée (user: $MG_USER)"
    CREDS_LINES="$CREDS_LINES
DATABASE_URL=mongodb://$MG_USER:$MG_PASS@127.0.0.1:27017/$MG_DB?authSource=$MG_DB"
  done

  save_creds "mongodb" "$CREDS_LINES"

  echo ""
  if confirm "Activer les backups automatiques quotidiens ?" "y"; then
    setup_backup_cron "mongodb" \
      "mongodump --uri='mongodb://admin:$ROOT_PASS@127.0.0.1:27017/?authSource=admin' --archive --gzip" \
      "archive.gz"
  fi

  echo ""
  if confirm "Installer Mongo Express (UI web pour MongoDB) ?" "n"; then
    install_mongo_express "$ROOT_PASS"
  fi

  ok "MongoDB prêt (port 27017)"
}

# =========================================================
# REDIS
# =========================================================
install_redis() {
  echo ""
  echo -e "${B}━━ Installation Redis ━━${N}"

  echo "Versions disponibles : 7 (recommandée), 6 (legacy)"
  read -rp "Version Redis [7] : " RD_VER
  RD_VER="${RD_VER:-7}"
  case "$RD_VER" in
    6|7) ;;
    *) err "Version invalide : $RD_VER" ;;
  esac

  inf "Ajout du dépôt officiel Redis..."
  apt-get install -y -qq curl gnupg ca-certificates lsb-release
  curl -fsSL https://packages.redis.io/gpg | gpg --dearmor -o /usr/share/keyrings/redis-archive-keyring.gpg
  echo "deb [signed-by=/usr/share/keyrings/redis-archive-keyring.gpg] \
https://packages.redis.io/deb $(lsb_release -cs) main" \
    > /etc/apt/sources.list.d/redis.list

  apt-get update -qq
  apt-get install -y redis
  ok "Redis installé : $(redis-server --version | awk '{print $3}')"

  # Sécurisation : bind localhost + password
  ROOT_PASS=$(gen_password 32)
  CONF="/etc/redis/redis.conf"
  cp "$CONF" "${CONF}.bak"

  sed -i "s/^bind .*/bind 127.0.0.1 ::1/" "$CONF"
  sed -i "s/^# requirepass .*/requirepass $ROOT_PASS/" "$CONF"
  sed -i "s/^requirepass .*/requirepass $ROOT_PASS/" "$CONF"
  if ! grep -q "^requirepass" "$CONF"; then
    echo "requirepass $ROOT_PASS" >> "$CONF"
  fi

  # Activer la persistance AOF
  sed -i "s/^appendonly no/appendonly yes/" "$CONF"

  # Renommer les commandes dangereuses
  cat >> "$CONF" << 'EOF'

# Hardening HTIC-NETWORKS
rename-command FLUSHALL ""
rename-command FLUSHDB ""
rename-command CONFIG "CONFIG_HTIC_ADMIN"
rename-command DEBUG ""
EOF

  systemctl enable redis-server
  systemctl restart redis-server
  ok "Redis démarré (bind 127.0.0.1, password requis, AOF activé)"

  # Test
  if redis-cli -a "$ROOT_PASS" --no-auth-warning ping | grep -q PONG; then
    ok "Connexion Redis OK"
  else
    warn "Connexion Redis échouée — vérifie /etc/redis/redis.conf"
  fi

  CREDS_LINES="REDIS_PASSWORD=$ROOT_PASS
REDIS_HOST=127.0.0.1
REDIS_PORT=6379
REDIS_URL=redis://default:$ROOT_PASS@127.0.0.1:6379"

  save_creds "redis" "$CREDS_LINES"

  echo ""
  if confirm "Activer les backups automatiques quotidiens ?" "y"; then
    # Snapshot du fichier dump.rdb (Redis le génère via SAVE / BGSAVE)
    setup_backup_cron "redis" \
      "redis-cli -a '$ROOT_PASS' --no-auth-warning BGSAVE >/dev/null && sleep 5 && cat /var/lib/redis/dump.rdb | gzip" \
      "rdb.gz"
  fi

  echo ""
  if confirm "Installer RedisInsight (UI web pour Redis) ?" "n"; then
    install_redisinsight
  fi

  ok "Redis prêt (port 6379)"
}

# =========================================================
# SUPABASE (self-hosted via Docker Compose)
# =========================================================
install_supabase() {
  echo ""
  echo -e "${B}━━ Installation Supabase (self-hosted) ━━${N}"
  echo ""
  warn "Supabase self-hosted utilise Docker Compose et démarre ~10 conteneurs"
  warn "(postgres, kong, gotrue, postgrest, realtime, storage, studio, meta, ...)"
  warn "RAM minimum recommandée : 2 GB"
  echo ""
  if ! confirm "Continuer ?" "n"; then
    return
  fi

  # Docker
  if ! command -v docker &>/dev/null; then
    inf "Installation de Docker..."
    apt-get install -y -qq ca-certificates curl gnupg
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
      | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
      > /etc/apt/sources.list.d/docker.list
    apt-get update -qq
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    systemctl enable --now docker
    ok "Docker installé"
  else
    ok "Docker déjà installé"
  fi

  SUPABASE_DIR="/opt/supabase"
  if [ -d "$SUPABASE_DIR" ]; then
    warn "$SUPABASE_DIR existe déjà"
    if ! confirm "Réinstaller (drop données) ?" "n"; then
      return
    fi
    cd "$SUPABASE_DIR" && docker compose down -v 2>/dev/null || true
    rm -rf "$SUPABASE_DIR"
  fi

  # Cloner le repo Supabase
  inf "Clonage du repo Supabase officiel..."
  apt-get install -y -qq git
  git clone --depth 1 https://github.com/supabase/supabase "$SUPABASE_DIR/repo"

  mkdir -p "$SUPABASE_DIR/data"
  cp -a "$SUPABASE_DIR/repo/docker/." "$SUPABASE_DIR/"
  cp "$SUPABASE_DIR/.env.example" "$SUPABASE_DIR/.env"

  # Génération des secrets
  POSTGRES_PASS=$(gen_password 32)
  JWT_SECRET=$(gen_password 64)
  ANON_KEY="eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJyb2xlIjoiYW5vbiIsImlzcyI6InN1cGFiYXNlIiwiaWF0IjoxNzAwMDAwMDAwLCJleHAiOjE5MDAwMDAwMDB9.placeholder-regenerate"
  SERVICE_ROLE_KEY="eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJyb2xlIjoic2VydmljZV9yb2xlIiwiaXNzIjoic3VwYWJhc2UiLCJpYXQiOjE3MDAwMDAwMDAsImV4cCI6MTkwMDAwMDAwMH0.placeholder-regenerate"
  DASHBOARD_USER="supabase"
  DASHBOARD_PASS=$(gen_password 24)

  warn "ANON_KEY et SERVICE_ROLE_KEY sont des placeholders — génère-les via :"
  warn "  https://supabase.com/docs/guides/self-hosting/docker#generate-api-keys"

  # Patch .env
  sed -i "s|^POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=$POSTGRES_PASS|" "$SUPABASE_DIR/.env"
  sed -i "s|^JWT_SECRET=.*|JWT_SECRET=$JWT_SECRET|" "$SUPABASE_DIR/.env"
  sed -i "s|^ANON_KEY=.*|ANON_KEY=$ANON_KEY|" "$SUPABASE_DIR/.env"
  sed -i "s|^SERVICE_ROLE_KEY=.*|SERVICE_ROLE_KEY=$SERVICE_ROLE_KEY|" "$SUPABASE_DIR/.env"
  sed -i "s|^DASHBOARD_USERNAME=.*|DASHBOARD_USERNAME=$DASHBOARD_USER|" "$SUPABASE_DIR/.env"
  sed -i "s|^DASHBOARD_PASSWORD=.*|DASHBOARD_PASSWORD=$DASHBOARD_PASS|" "$SUPABASE_DIR/.env"

  # Démarrage
  inf "Démarrage des conteneurs Supabase (peut prendre quelques minutes)..."
  cd "$SUPABASE_DIR"
  docker compose pull
  docker compose up -d
  sleep 10

  ok "Supabase démarré"
  docker compose ps

  CREDS_LINES="POSTGRES_PASSWORD=$POSTGRES_PASS
JWT_SECRET=$JWT_SECRET
DASHBOARD_USER=$DASHBOARD_USER
DASHBOARD_PASSWORD=$DASHBOARD_PASS

# Studio (UI) :  http://127.0.0.1:8000
# REST API   :  http://127.0.0.1:8000/rest/v1/
# Postgres   :  postgresql://postgres:$POSTGRES_PASS@127.0.0.1:5433/postgres
# (Supabase Postgres écoute sur 5433 pour ne pas conflit avec PG natif)

# IMPORTANT : régénère ANON_KEY et SERVICE_ROLE_KEY via l'outil officiel :
# https://supabase.com/docs/guides/self-hosting/docker#generate-api-keys"

  save_creds "supabase" "$CREDS_LINES"

  # Backup : dump du Postgres Supabase
  echo ""
  if confirm "Activer les backups automatiques quotidiens ?" "y"; then
    setup_backup_cron "supabase" \
      "docker exec supabase-db pg_dumpall -U postgres | gzip" \
      "sql.gz"
  fi

  echo ""
  ok "Supabase prêt (Studio sur :8000, expose via Caddy si besoin)"
  echo ""
  warn "Étapes manuelles obligatoires :"
  warn "1. Génère ANON_KEY et SERVICE_ROLE_KEY (voir credentials)"
  warn "2. Édite $SUPABASE_DIR/.env avec les vraies clés"
  warn "3. cd $SUPABASE_DIR && docker compose restart"
  warn "4. (Optionnel) Configure Caddy : sudo bash 02b-add-caddy-site.sh studio.exemple.com"
}

# =========================================================
# WEB UIs
# =========================================================

install_adminer() {
  inf "Installation d'Adminer..."
  apt-get install -y -qq adminer

  # Active la config Apache/Nginx en désactivant — on sert via Caddy + PHP-FPM
  if [ ! -d /var/www/adminer ]; then
    mkdir -p /var/www/adminer
    cp /usr/share/adminer/adminer.php /var/www/adminer/index.php
    chown -R caddy:caddy /var/www/adminer 2>/dev/null || chown -R www-data:www-data /var/www/adminer
  fi

  PORT=$(ensure_port_free 8080 "Adminer")

  # Service systemd PHP intégré (sans Apache)
  cat > /etc/systemd/system/adminer.service << EOF
[Unit]
Description=Adminer DB UI (PHP built-in server)
After=network.target

[Service]
Type=simple
User=www-data
Group=www-data
WorkingDirectory=/var/www/adminer
ExecStart=/usr/bin/php -S 127.0.0.1:$PORT -t /var/www/adminer
Restart=always

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now adminer
  ok "Adminer démarré sur 127.0.0.1:$PORT"

  echo ""
  if confirm "Exposer via Caddy avec basic auth ?" "y"; then
    read -rp "  Domaine (ex: db.exemple.com) : " DOMAIN
    [ -n "$DOMAIN" ] && ensure_caddy_ui "$DOMAIN" "$PORT" "Adminer"
  fi
}

install_phpmyadmin() {
  inf "Installation de phpMyAdmin..."
  echo "phpmyadmin phpmyadmin/dbconfig-install boolean false" | debconf-set-selections
  echo "phpmyadmin phpmyadmin/reconfigure-webserver multiselect" | debconf-set-selections

  DEBIAN_FRONTEND=noninteractive apt-get install -y phpmyadmin

  PORT=$(ensure_port_free 8081 "phpMyAdmin")

  cat > /etc/systemd/system/phpmyadmin.service << EOF
[Unit]
Description=phpMyAdmin (PHP built-in server)
After=network.target

[Service]
Type=simple
User=www-data
Group=www-data
WorkingDirectory=/usr/share/phpmyadmin
ExecStart=/usr/bin/php -S 127.0.0.1:$PORT -t /usr/share/phpmyadmin
Restart=always

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now phpmyadmin
  ok "phpMyAdmin démarré sur 127.0.0.1:$PORT"

  echo ""
  if confirm "Exposer via Caddy avec basic auth ?" "y"; then
    read -rp "  Domaine (ex: phpmyadmin.exemple.com) : " DOMAIN
    [ -n "$DOMAIN" ] && ensure_caddy_ui "$DOMAIN" "$PORT" "phpMyAdmin"
  fi
}

install_mongo_express() {
  local mongo_admin_pass="$1"
  inf "Installation de Mongo Express (Docker)..."

  if ! command -v docker &>/dev/null; then
    err "Docker requis. Installe-le ou choisis Supabase qui l'installe."
  fi

  PORT=$(ensure_port_free 8083 "Mongo Express")
  ME_USER="admin"
  ME_PASS=$(gen_password 16)

  docker run -d --name mongo-express \
    --restart unless-stopped \
    --network host \
    -e ME_CONFIG_MONGODB_ADMINUSERNAME=admin \
    -e ME_CONFIG_MONGODB_ADMINPASSWORD="$mongo_admin_pass" \
    -e ME_CONFIG_MONGODB_URL="mongodb://admin:${mongo_admin_pass}@127.0.0.1:27017/?authSource=admin" \
    -e ME_CONFIG_BASICAUTH_USERNAME="$ME_USER" \
    -e ME_CONFIG_BASICAUTH_PASSWORD="$ME_PASS" \
    -e ME_CONFIG_SITE_BASEURL="/" \
    -e VCAP_APP_PORT="$PORT" \
    -e PORT="$PORT" \
    mongo-express:latest

  save_creds "mongo-express" "USER=$ME_USER
PASSWORD=$ME_PASS
URL=http://127.0.0.1:$PORT"

  ok "Mongo Express démarré sur 127.0.0.1:$PORT (auth: $ME_USER)"

  echo ""
  if confirm "Exposer via Caddy avec basic auth ?" "y"; then
    read -rp "  Domaine (ex: mongo.exemple.com) : " DOMAIN
    [ -n "$DOMAIN" ] && ensure_caddy_ui "$DOMAIN" "$PORT" "Mongo Express"
  fi
}

install_redisinsight() {
  inf "Installation de RedisInsight (Docker)..."

  if ! command -v docker &>/dev/null; then
    err "Docker requis. Installe Supabase d'abord ou Docker manuellement."
  fi

  PORT=$(ensure_port_free 8084 "RedisInsight")

  mkdir -p /var/lib/redisinsight
  chown 1000:1000 /var/lib/redisinsight

  docker run -d --name redisinsight \
    --restart unless-stopped \
    --network host \
    -e RI_APP_PORT="$PORT" \
    -e RI_APP_HOST="127.0.0.1" \
    -v /var/lib/redisinsight:/data \
    redis/redisinsight:latest

  ok "RedisInsight démarré sur 127.0.0.1:$PORT"

  echo ""
  if confirm "Exposer via Caddy avec basic auth ?" "y"; then
    read -rp "  Domaine (ex: redis.exemple.com) : " DOMAIN
    [ -n "$DOMAIN" ] && ensure_caddy_ui "$DOMAIN" "$PORT" "RedisInsight"
  fi
}

# =========================================================
# MENU PRINCIPAL
# =========================================================

show_menu() {
  clear
  echo ""
  echo -e "${C}═══════════════════════════════════════════════${N}"
  echo -e "${C}  HTIC-NETWORKS — Installation de bases       ${N}"
  echo -e "${C}═══════════════════════════════════════════════${N}"
  echo ""
  echo -e "  ${B}BASES SQL${N}"
  echo "    1) PostgreSQL    (versions 13, 14, 15, 16, 17)"
  echo "    2) MySQL         (versions 8.0, 8.4 LTS) — Oracle"
  echo "    3) MariaDB       (versions 10.6, 10.11, 11.4 LTS)"
  echo ""
  echo -e "  ${B}BASES NoSQL${N}"
  echo "    4) MongoDB       (versions 6.0, 7.0, 8.0)"
  echo "    5) Redis         (versions 6, 7) — cache/queues"
  echo ""
  echo -e "  ${B}STACK BaaS${N}"
  echo "    6) Supabase      (Postgres + Auth/Realtime/Storage via Docker)"
  echo ""
  echo -e "  ${B}INFOS${N}"
  echo "    s) Statut des bases déjà installées"
  echo "    q) Quitter"
  echo ""
}

show_status() {
  echo ""
  echo -e "${B}État des bases installées :${N}"
  echo ""
  for svc in postgresql mysql mariadb mongod redis-server docker; do
    if systemctl list-unit-files "$svc.service" 2>/dev/null | grep -q "$svc.service"; then
      if systemctl is-active --quiet "$svc"; then
        printf "  %-20s %s\n" "$svc" "$(echo -e ${G}✓ active${N})"
      else
        printf "  %-20s %s\n" "$svc" "$(echo -e ${R}✗ inactive${N})"
      fi
    fi
  done
  echo ""
  if [ -d "$CREDS_DIR" ] && [ "$(ls -A "$CREDS_DIR" 2>/dev/null)" ]; then
    echo -e "${Y}Fichiers de credentials non purgés :${N}"
    ls -la "$CREDS_DIR/"
  fi
  echo ""
  read -rp "Entrée pour revenir au menu..." _
}

# Affiche l'état au démarrage
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -f "$SCRIPT_DIR/00-list-apps.sh" ] && bash "$SCRIPT_DIR/00-list-apps.sh" --short

while true; do
  show_menu
  read -rp "Ton choix : " CHOICE
  case "$CHOICE" in
    1) install_postgresql ;;
    2) install_mysql ;;
    3) install_mariadb ;;
    4) install_mongodb ;;
    5) install_redis ;;
    6) install_supabase ;;
    s|S) show_status ;;
    q|Q) echo "Bye 👋"; exit 0 ;;
    *) echo "Choix invalide" ;;
  esac
  echo ""
  read -rp "Appuie sur Entrée pour revenir au menu..." _
done
