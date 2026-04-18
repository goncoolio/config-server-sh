#!/bin/bash
# =========================================================
# SCRIPT 3/6 — Installation PostgreSQL 16
# Ubuntu 24.04 — HTIC-NETWORKS
# Usage : sudo bash 03-install-postgresql.sh
# =========================================================
set -euo pipefail

G='\033[0;32m'; Y='\033[1;33m'; R='\033[0;31m'; C='\033[0;36m'; N='\033[0m'
ok()  { echo -e "${G}[OK]${N} $1"; }
err() { echo -e "${R}[ERREUR]${N} $1"; exit 1; }
inf() { echo -e "${C}----> $1${N}"; }

[ "$EUID" -ne 0 ] && err "Lance avec sudo : sudo bash $0"

echo ""
echo -e "${C}======================================${N}"
echo -e "${C}  HTIC-NETWORKS — PostgreSQL 16       ${N}"
echo -e "${C}======================================${N}"
echo ""

# ─── Questions : combien d'apps ? ─────────────────────────
read -rp "Combien d'apps auront une base de données ? (1, 2 ou 3) : " NB

APPS_CONFIG=()
for i in $(seq 1 "$NB"); do
  echo ""
  echo -e "${C}--- Configurer la base pour l'app $i ---${N}"
  read -rp "  Nom du rôle PostgreSQL  (ex: app1_user) : " PG_ROLE
  read -rp "  Nom de la base          (ex: app1_db)   : " PG_DB
  read -rsp "  Mot de passe du rôle                    : " PG_PASS
  echo ""
  APPS_CONFIG+=("$PG_ROLE|$PG_DB|$PG_PASS")
done

# ─── 1. Installer PostgreSQL 16 depuis le dépôt officiel ──
inf "Ajout du dépôt officiel PostgreSQL..."
apt-get install -y -qq curl ca-certificates

install -d /usr/share/postgresql-common/pgdg
curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
  -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc

echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] \
https://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" \
  > /etc/apt/sources.list.d/pgdg.list

apt-get update -qq
apt-get install -y postgresql-16 postgresql-client-16 postgresql-contrib-16
ok "PostgreSQL installé : $(psql --version | head -1)"

# ─── 2. Tuning automatique selon la RAM ───────────────────
inf "Tuning PostgreSQL selon la RAM disponible..."
RAM_MB=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
SHARED_MB=$((RAM_MB / 4))
CACHE_MB=$((RAM_MB * 3 / 4))

inf "RAM détectée : ${RAM_MB}MB → shared_buffers=${SHARED_MB}MB"

PG_CONF="/etc/postgresql/16/main/postgresql.conf"
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

# Logging
log_min_duration_statement = 1000
log_lock_waits            = on

# Sécurité
password_encryption       = scram-sha-256
ssl                       = on

# Localisation
timezone                  = 'Africa/Abidjan'
EOF

ok "Tuning appliqué"

# ─── 3. Sécuriser pg_hba.conf ────────────────────────────
inf "Sécurisation pg_hba.conf..."
HBA="/etc/postgresql/16/main/pg_hba.conf"
cp "$HBA" "${HBA}.bak"

cat > "$HBA" << 'EOF'
# pg_hba.conf sécurisé — HTIC-NETWORKS
# TYPE   DATABASE   USER       ADDRESS         METHOD

# postgres via socket Unix (administration locale)
local    all        postgres                   peer

# Toutes les apps : socket Unix avec mot de passe
local    all        all                        scram-sha-256

# Connexions TCP : localhost uniquement
host     all        all        127.0.0.1/32    scram-sha-256
host     all        all        ::1/128         scram-sha-256

# AUCUNE connexion depuis l'extérieur
EOF

ok "pg_hba.conf sécurisé (localhost + socket Unix uniquement)"

# ─── 4. Activer la locale française ───────────────────────
inf "Configuration de la locale..."
locale-gen fr_FR.UTF-8 || true
ok "Locale fr_FR.UTF-8 configurée"

# ─── 5. Redémarrer PostgreSQL ─────────────────────────────
systemctl enable postgresql
systemctl restart postgresql
ok "PostgreSQL démarré"

# ─── 6. Créer les rôles et bases de données ───────────────
inf "Création des bases de données..."
CREDS_FILE="/root/pg-credentials-$(date +%Y%m%d).txt"
echo "# PostgreSQL — HTIC-NETWORKS — $(date)" > "$CREDS_FILE"
echo "# À supprimer après avoir noté !" >> "$CREDS_FILE"
echo "" >> "$CREDS_FILE"

for ENTRY in "${APPS_CONFIG[@]}"; do
  IFS='|' read -r PG_ROLE PG_DB PG_PASS <<< "$ENTRY"

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

  # Extensions utiles
  sudo -u postgres psql -d "$PG_DB" << SQL
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";
CREATE EXTENSION IF NOT EXISTS "pg_trgm";
CREATE EXTENSION IF NOT EXISTS "unaccent";
SQL

  ok "Base $PG_DB créée (rôle: $PG_ROLE)"

  # Sauvegarder les credentials
  {
    echo "# App : $PG_DB"
    echo "DATABASE_URL=postgresql://$PG_ROLE:$PG_PASS@127.0.0.1:5432/$PG_DB"
    echo "# Via socket Unix :"
    echo "DATABASE_URL=postgresql://$PG_ROLE:$PG_PASS@%2Fvar%2Frun%2Fpostgresql/$PG_DB"
    echo ""
  } >> "$CREDS_FILE"
done

chmod 600 "$CREDS_FILE"
ok "Credentials sauvegardés dans $CREDS_FILE"

# ─── Résumé ───────────────────────────────────────────────
echo ""
echo -e "${G}============================================${N}"
echo -e "${G}  SCRIPT 3 TERMINÉ                         ${N}"
echo -e "${G}============================================${N}"
echo ""
echo "Bases créées :"
for ENTRY in "${APPS_CONFIG[@]}"; do
  IFS='|' read -r PG_ROLE PG_DB PG_PASS <<< "$ENTRY"
  echo "  $PG_DB  →  rôle: $PG_ROLE"
done
echo ""
echo -e "${Y}Lis et note les DATABASE_URL dans $CREDS_FILE${N}"
echo -e "${Y}Puis supprime ce fichier : rm $CREDS_FILE${N}"
echo ""
echo "Commandes utiles :"
echo "  sudo -u postgres psql            # console admin"
echo "  sudo -u postgres psql -d app_db  # connexion à une base"
echo "  systemctl status postgresql      # statut"
echo ""
echo "Étape suivante :"
echo "  Si tu as une app Rust   → sudo bash 04-deploy-rust-app.sh"
echo "  Si tu as une app NestJS → sudo bash 05-deploy-node-app.sh"
echo "  Les deux                → lance les deux scripts"
