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
set -euo pipefail

G='\033[0;32m'; Y='\033[1;33m'; R='\033[0;31m'; C='\033[0;36m'; B='\033[1m'; N='\033[0m'

MODE="${1:-full}"

# ─── Détection du framework d'une app dans /opt ───────────
detect_framework() {
  local dir="$1"
  local current="$dir/current"
  [ ! -e "$current" ] && { echo "?"; return; }
  if [ -f "$current/artisan" ]; then echo "laravel"
  elif [ -f "$current/next.config.js" ] || [ -f "$current/next.config.mjs" ]; then echo "nextjs"
  elif [ -f "$current/nest-cli.json" ] || { [ -f "$current/package.json" ] && grep -q '"@nestjs/core"' "$current/package.json" 2>/dev/null; }; then echo "nestjs"
  elif [ -f "$current/package.json" ]; then echo "node"
  elif [ -f "$current/index.html" ]; then echo "static"
  else
    # Rust : binaire exécutable au niveau racine
    local bin=$(find "$current" -maxdepth 1 -type f -executable 2>/dev/null | head -1)
    [ -n "$bin" ] && echo "rust" || echo "?"
  fi
}

# ─── Extraire le port depuis .env ─────────────────────────
get_port() {
  local env_file="$1/shared/.env"
  [ ! -f "$env_file" ] && { echo "-"; return; }
  grep -E '^PORT=' "$env_file" 2>/dev/null | head -1 | cut -d= -f2 || echo "-"
}

# ─── 1. Apps dans /opt ────────────────────────────────────
print_apps() {
  if [ ! -d /opt ] || ! ls -d /opt/*/ 2>/dev/null | grep -qv '/opt/shared'; then
    echo "  (aucune app déployée)"
    return
  fi

  printf "  ${B}%-20s %-10s %-8s %-12s %s${N}\n" "NOM" "FRAMEWORK" "PORT" "SERVICE" "RELEASES"
  printf "  %-20s %-10s %-8s %-12s %s\n" "---" "---------" "----" "-------" "--------"

  for d in /opt/*/; do
    local name=$(basename "$d")
    [ "$name" = "shared" ] && continue

    local fw=$(detect_framework "$d")
    local port=$(get_port "$d")
    local releases=0
    [ -d "$d/releases" ] && releases=$(ls -1 "$d/releases" 2>/dev/null | wc -l | tr -d ' ')

    local svc_status="—"
    if systemctl list-unit-files "$name.service" 2>/dev/null | grep -q "$name.service"; then
      if systemctl is-active --quiet "$name" 2>/dev/null; then
        svc_status="${G}active${N}"
      else
        svc_status="${R}inactive${N}"
      fi
    fi

    printf "  %-20s %-10s %-8s " "$name" "$fw" "$port"
    echo -ne "$svc_status"
    # Padding manuel (echo -e compte les codes ANSI)
    local pad=$((12 - ${#svc_status} ))
    printf "%${pad}s %s\n" "" "$releases"
  done
}

# ─── 2. Sites Caddy ───────────────────────────────────────
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
    local domain=$(basename "$f" .caddy)
    local target=""
    if grep -q "reverse_proxy" "$f"; then
      target="reverse_proxy → $(grep 'reverse_proxy' "$f" | head -1 | awk '{print $2}')"
    elif grep -q "php_fastcgi" "$f"; then
      target="php_fastcgi ($(grep 'root \*' "$f" | head -1 | awk '{print $3}'))"
    elif grep -q "file_server" "$f"; then
      target="static ($(grep 'root \*' "$f" | head -1 | awk '{print $3}'))"
    fi
    printf "  %-40s %s\n" "$domain" "$target"
  done
}

# ─── 3. Ports locaux occupés ──────────────────────────────
print_ports() {
  if ! command -v ss &>/dev/null; then
    echo "  (ss non disponible)"
    return
  fi

  printf "  ${B}%-8s %-8s %s${N}\n" "PORT" "PROTO" "PROCESSUS"
  printf "  %-8s %-8s %s\n" "----" "-----" "---------"

  ss -tlnp 2>/dev/null \
    | awk 'NR>1 && $4 ~ /127\.0\.0\.1:|0\.0\.0\.0:|\*:|\[::\]:/ {
        split($4, a, ":");
        port = a[length(a)];
        proc = "";
        for (i=7; i<=NF; i++) proc = proc " " $i;
        print port "\t" $1 "\t" proc
      }' \
    | sort -u -k1,1n \
    | while IFS=$'\t' read -r port proto proc; do
        printf "  %-8s %-8s %s\n" "$port" "$proto" "$proc"
      done
}

# ─── 4. Services systemd liés à /opt ──────────────────────
print_services() {
  local services=$(systemctl list-unit-files --type=service --no-legend 2>/dev/null \
    | awk '{print $1}' \
    | while read svc; do
        local name="${svc%.service}"
        if [ -d "/opt/$name" ] || systemctl cat "$svc" 2>/dev/null | grep -q "/opt/"; then
          echo "$svc"
        fi
      done)

  if [ -z "$services" ]; then
    echo "  (aucun service lié à /opt)"
    return
  fi

  printf "  ${B}%-30s %-10s %s${N}\n" "SERVICE" "ÉTAT" "DEPUIS"
  printf "  %-30s %-10s %s\n" "-------" "-----" "------"

  for svc in $services; do
    local state="inactive"
    local since=""
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
      state="${G}active${N}"
      since=$(systemctl show "$svc" -p ActiveEnterTimestamp --value 2>/dev/null | cut -d' ' -f2-3)
    else
      state="${R}inactive${N}"
    fi
    printf "  %-30s " "$svc"
    echo -ne "$state"
    local pad=$((10 - ${#state} ))
    printf "%${pad}s %s\n" "" "$since"
  done
}

# ─── MODE --short (inclusion dans 05*) ────────────────────
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

# ─── MODE complet ─────────────────────────────────────────
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
