#!/bin/bash
# =========================================================
# SCRIPT 00 — Lister les apps, sites Caddy et ports utilisés
# Ubuntu 24.04 — HTIC-NETWORKS
#
# Usage :
#   sudo bash 00-list-apps.sh           # affichage complet
#   sudo bash 00-list-apps.sh --short   # résumé compact (pour inclusion)
#
# Appelé automatiquement au début des scripts 05* pour
# éviter les collisions de noms/ports.
# =========================================================
# Note : on utilise set -uo pipefail (sans -e) pour qu'un fail
# isolé sur un grep/ss n'arrête pas tout le diagnostic.
set -uo pipefail

G='\033[0;32m'; Y='\033[1;33m'; R='\033[0;31m'; C='\033[0;36m'; B='\033[1m'; N='\033[0m'

MODE="${1:-full}"

# =========================================================
# Indexation des process en écoute (cache par PID → port,prog)
# =========================================================
# Évite d'appeler ss N fois. On parse une seule fois.
# Format pipe-separé :  PID|PROG|PORT|PROTO|BIND
declare -a SS_INDEX=()

build_ss_index() {
  command -v ss &>/dev/null || return
  local line local_addr port bind proto proc_info prog pid
  while IFS= read -r line; do
    proto=$(echo "$line" | awk '{print $1}')
    [ "$proto" = "Netid" ] && continue   # header
    local_addr=$(echo "$line" | awk '{print $5}')
    port="${local_addr##*:}"
    bind="${local_addr%:*}"
    [[ "$port" =~ ^[0-9]+$ ]] || continue

    proc_info=$(echo "$line" | grep -oE 'users:\(\(.*' || true)
    if [ -n "$proc_info" ]; then
      prog=$(echo "$proc_info" | sed -nE 's/^users:\(\(\"([^\"]+)\".*/\1/p')
      pid=$(echo "$proc_info" | sed -nE 's/.*pid=([0-9]+).*/\1/p')
    else
      prog=""
      pid=""
    fi
    SS_INDEX+=("${pid:-?}|${prog:-?}|${port}|${proto}|${bind}")
  done < <(ss -tlnpH 2>/dev/null)
}

# Trouve le service systemd qui possède un PID donné
pid_to_service() {
  local pid="$1"
  [ -z "$pid" ] || [ "$pid" = "?" ] && return
  # systemctl status accepte un PID et affiche la première ligne avec le service
  local svc
  svc=$(systemctl status "$pid" 2>/dev/null | head -1 | grep -oE '[a-zA-Z0-9_-]+\.service' | head -1 | sed 's/\.service$//')
  echo "$svc"
}

# Trouve le port d'écoute d'un PID donné via le cache
pid_to_port() {
  local pid="$1"
  [ -z "$pid" ] || [ "$pid" = "?" ] && return
  for entry in "${SS_INDEX[@]}"; do
    if [ "${entry%%|*}" = "$pid" ]; then
      echo "$entry" | cut -d'|' -f3
      return
    fi
  done
}

# =========================================================
# DÉTECTION du framework et du port d'une app dans /opt
# =========================================================
detect_framework() {
  local dir="$1"
  # Essaye d'abord current/, sinon le dossier directement (legacy)
  local roots=("$dir/current" "$dir/src" "$dir")
  for root in "${roots[@]}"; do
    [ ! -e "$root" ] && continue
    if [ -f "$root/artisan" ]; then echo "laravel"; return; fi
    if [ -f "$root/next.config.js" ] || [ -f "$root/next.config.mjs" ] || [ -f "$root/next.config.ts" ]; then echo "nextjs"; return; fi
    if [ -f "$root/nest-cli.json" ]; then echo "nestjs"; return; fi
    if [ -f "$root/package.json" ] && grep -q '"@nestjs/core"' "$root/package.json" 2>/dev/null; then echo "nestjs"; return; fi
    if [ -f "$root/package.json" ]; then
      # Détection Express via dépendance
      if grep -qE '"express"\s*:' "$root/package.json" 2>/dev/null; then echo "express"; return; fi
      echo "node"; return
    fi
    if [ -f "$root/index.html" ]; then echo "static"; return; fi
    # Rust : binaire exécutable au niveau racine du dossier
    local bin
    bin=$(find "$root" -maxdepth 1 -type f -executable 2>/dev/null | grep -v '\.sh$' | head -1)
    if [ -n "$bin" ]; then echo "rust"; return; fi
  done
  echo "?"
}

# Cherche le PORT dans plusieurs endroits possibles
get_port() {
  local dir="$1"
  local app
  app=$(basename "$dir")
  local port=""

  # 1. shared/.env (architecture nouvelle)
  for envf in "$dir/shared/.env" "$dir/.env" "$dir/src/.env" "$dir/current/.env"; do
    if [ -f "$envf" ]; then
      port=$(grep -E '^PORT=' "$envf" 2>/dev/null | head -1 | cut -d= -f2 | tr -d ' "')
      [ -n "$port" ] && { echo "$port"; return; }
    fi
  done

  # 2. Service systemd : Environment=PORT=
  if systemctl cat "$app.service" >/dev/null 2>&1; then
    port=$(systemctl show "$app" -p Environment --value 2>/dev/null | tr ' ' '\n' | grep -E '^PORT=' | head -1 | cut -d= -f2)
    [ -n "$port" ] && { echo "$port"; return; }

    # Lire EnvironmentFile s'il y en a un
    local env_file
    env_file=$(systemctl show "$app" -p EnvironmentFiles --value 2>/dev/null | awk '{print $1}' | head -1)
    if [ -n "$env_file" ] && [ -f "$env_file" ]; then
      port=$(grep -E '^PORT=' "$env_file" 2>/dev/null | head -1 | cut -d= -f2 | tr -d ' "')
      [ -n "$port" ] && { echo "$port"; return; }
    fi
  fi

  # 3. Cross-référence : si le service tourne, regarde son PID et trouve le port d'écoute
  if systemctl is-active --quiet "$app" 2>/dev/null; then
    local pid
    pid=$(systemctl show "$app" -p MainPID --value 2>/dev/null)
    if [ -n "$pid" ] && [ "$pid" != "0" ]; then
      port=$(pid_to_port "$pid")
      [ -n "$port" ] && { echo "$port"; return; }
    fi
  fi

  # 4. ecosystem.config.js (PM2 legacy)
  for pm2f in "$dir/ecosystem.config.js" "$dir/shared/ecosystem.config.js"; do
    if [ -f "$pm2f" ]; then
      port=$(grep -oE 'PORT[: =]+[0-9]+' "$pm2f" 2>/dev/null | head -1 | grep -oE '[0-9]+')
      [ -n "$port" ] && { echo "$port"; return; }
    fi
  done

  echo "-"
}

# Statut systemd robuste
get_service_status() {
  local app="$1"
  if systemctl cat "$app.service" >/dev/null 2>&1; then
    if systemctl is-active --quiet "$app" 2>/dev/null; then
      echo "active"
    elif systemctl is-failed --quiet "$app" 2>/dev/null; then
      echo "failed"
    else
      echo "inactive"
    fi
  else
    echo "—"
  fi
}

# Helper : print avec couleur pour le statut
color_status() {
  case "$1" in
    active)   echo -e "${G}active${N}" ;;
    failed)   echo -e "${R}failed${N}" ;;
    inactive) echo -e "${R}inactive${N}" ;;
    *)        echo "$1" ;;
  esac
}

# =========================================================
# 1. Apps dans /opt
# =========================================================
print_apps() {
  local has_apps=false
  for d in /opt/*/; do
    local n
    n=$(basename "$d")
    [ "$n" = "shared" ] && continue
    has_apps=true
    break
  done

  if ! $has_apps; then
    echo "  (aucune app déployée)"
    return
  fi

  printf "  ${B}%-22s %-10s %-7s %-10s %s${N}\n" "NOM" "FRAMEWORK" "PORT" "SERVICE" "RELEASES"
  printf "  %-22s %-10s %-7s %-10s %s\n" "---" "---------" "----" "-------" "--------"

  for d in /opt/*/; do
    local name fw port releases status status_colored
    name=$(basename "$d")
    [ "$name" = "shared" ] && continue

    fw=$(detect_framework "$d")
    port=$(get_port "$d")
    releases=0
    [ -d "$d/releases" ] && releases=$(ls -1 "$d/releases" 2>/dev/null | wc -l | tr -d ' ')
    status=$(get_service_status "$name")
    status_colored=$(color_status "$status")

    # printf ne gère pas les codes ANSI dans %-Xs → on padding manuellement
    printf "  %-22s %-10s %-7s " "$name" "$fw" "$port"
    echo -ne "$status_colored"
    local visible_len=${#status}
    local pad=$((10 - visible_len))
    [ $pad -lt 1 ] && pad=1
    printf "%${pad}s %s\n" "" "$releases"
  done
}

# =========================================================
# 2. Sites Caddy
# =========================================================
print_caddy_sites() {
  local dir="/etc/caddy/sites-enabled"
  if [ ! -d "$dir" ] || [ -z "$(ls -A "$dir" 2>/dev/null)" ]; then
    echo "  (aucun site Caddy configuré)"
    return
  fi

  printf "  ${B}%-40s %s${N}\n" "DOMAINE" "CIBLE"
  printf "  %-40s %s\n" "-------" "-----"

  for f in "$dir"/*.caddy; do
    [ ! -f "$f" ] && continue
    local domain target
    domain=$(basename "$f" .caddy)
    target=""
    if grep -q "reverse_proxy" "$f"; then
      target="proxy → $(grep 'reverse_proxy' "$f" | head -1 | awk '{print $2}')"
    elif grep -q "php_fastcgi" "$f"; then
      target="php → $(grep 'root \*' "$f" | head -1 | awk '{print $3}')"
    elif grep -q "file_server" "$f"; then
      target="static → $(grep 'root \*' "$f" | head -1 | awk '{print $3}')"
    fi
    printf "  %-40s %s\n" "$domain" "$target"
  done
}

# =========================================================
# 3. Ports locaux occupés (avec mapping vers service systemd)
# =========================================================
print_ports() {
  if ! command -v ss &>/dev/null; then
    echo "  (ss non disponible)"
    return
  fi
  if [ "$EUID" -ne 0 ]; then
    echo "  (lance en sudo pour voir les processus)"
  fi

  printf "  ${B}%-7s %-6s %-7s %-15s %s${N}\n" "PORT" "PROTO" "PID" "PROCESSUS" "SERVICE SYSTEMD"
  printf "  %-7s %-6s %-7s %-15s %s\n" "----" "-----" "---" "---------" "---------------"

  # Affiche le contenu trié par port
  local entry pid prog port proto bind svc display_pid
  declare -A seen=()

  # Tri par port numérique
  printf '%s\n' "${SS_INDEX[@]}" | sort -t'|' -k3,3n | while IFS='|' read -r pid prog port proto bind; do
    # Dédoublonnage par port (un port peut apparaître sur 0.0.0.0 et ::)
    [ -n "${seen[$port]:-}" ] && continue
    seen[$port]=1

    svc=""
    if [ -n "$pid" ] && [ "$pid" != "?" ]; then
      svc=$(pid_to_service "$pid")
    fi

    display_pid="${pid:-?}"
    printf "  %-7s %-6s %-7s %-15s %s\n" "$port" "$proto" "$display_pid" "${prog:-?}" "${svc:-—}"
  done
}

# =========================================================
# 4. Services systemd liés à /opt
# =========================================================
print_services() {
  local services=""
  while IFS= read -r unit; do
    local name="${unit%.service}"
    if [ -d "/opt/$name" ] || systemctl cat "$unit" 2>/dev/null | grep -q "WorkingDirectory=/opt/"; then
      services="$services $unit"
    fi
  done < <(systemctl list-unit-files --type=service --no-legend 2>/dev/null | awk '{print $1}')

  if [ -z "$services" ]; then
    echo "  (aucun service lié à /opt)"
    return
  fi

  printf "  ${B}%-30s %-10s %s${N}\n" "SERVICE" "ÉTAT" "DEPUIS"
  printf "  %-30s %-10s %s\n" "-------" "-----" "------"

  for svc in $services; do
    local app="${svc%.service}"
    local state since state_colored visible_len pad
    state=$(get_service_status "$app")
    state_colored=$(color_status "$state")
    since=""
    if [ "$state" = "active" ]; then
      since=$(systemctl show "$svc" -p ActiveEnterTimestamp --value 2>/dev/null | cut -d' ' -f2-3)
    fi
    printf "  %-30s " "$svc"
    echo -ne "$state_colored"
    visible_len=${#state}
    pad=$((10 - visible_len))
    [ $pad -lt 1 ] && pad=1
    printf "%${pad}s %s\n" "" "$since"
  done
}

# =========================================================
# Construction de l'index ss en avance
# =========================================================
build_ss_index

# =========================================================
# MODE --short (inclusion dans 05*)
# =========================================================
if [ "$MODE" = "--short" ]; then
  echo -e "${C}━━ Apps déjà déployées ━━${N}"
  print_apps
  echo ""
  echo -e "${C}━━ Sites Caddy actifs ━━${N}"
  print_caddy_sites
  echo ""
  echo -e "${C}━━ Ports locaux occupés ━━${N}"
  print_ports
  echo ""
  exit 0
fi

# =========================================================
# MODE complet
# =========================================================
echo ""
echo -e "${C}═══════════════════════════════════════════════${N}"
echo -e "${C}  HTIC-NETWORKS — État du serveur              ${N}"
echo -e "${C}═══════════════════════════════════════════════${N}"
echo ""

echo -e "${B}▸ Apps déployées dans /opt${N}"
print_apps
echo ""

echo -e "${B}▸ Sites Caddy (/etc/caddy/sites-enabled/)${N}"
print_caddy_sites
echo ""

echo -e "${B}▸ Services systemd liés à /opt${N}"
print_services
echo ""

echo -e "${B}▸ Ports locaux en écoute${N}"
print_ports
echo ""

echo -e "${C}═══════════════════════════════════════════════${N}"
echo "Scripts de déploiement disponibles dans /opt/shared/scripts/ :"
ls -1 /opt/shared/scripts/ 2>/dev/null | sed 's/^/  /' || echo "  (aucun)"
echo ""
