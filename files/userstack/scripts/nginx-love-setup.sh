#!/usr/bin/env bash
set -Eeuo pipefail

STACK_DIR="${CAPSTONE_STACK_DIR:-/opt/capstone-userstack}"
ENV_FILE="${STACK_DIR}/.env"
ENV_EXAMPLE="${STACK_DIR}/.env.example"
BOOTSTRAP_SCRIPT="${STACK_DIR}/scripts/bootstrap-nginx_love.sh"
PROXY_CONTAINER_DEFAULT="nginx-love-backend"
DVWA_CONTAINER_DEFAULT="dvwa"

log() { echo "[*] $*" >&2; }
die() { echo "[!]" "$*" >&2; exit 1; }
usage() { echo "Usage: nginx-love-setup <public_host> <new_admin_password>" >&2; }

on_err() {
  local exit_code=$?
  log "ERROR: command failed (exit=$exit_code) at line ${BASH_LINENO[0]}: ${BASH_COMMAND}"
  exit "$exit_code"
}
trap on_err ERR

strip_quotes() {
  local v="$1"
  if [[ "$v" == \"*\" && "$v" == *\" ]]; then
    v="${v:1:${#v}-2}"
  elif [[ "$v" == \'*\' && "$v" == *\' ]]; then
    v="${v:1:${#v}-2}"
  fi
  printf '%s' "$v"
}

load_env() {
  [[ -f "$ENV_FILE" ]] || return 0

  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" ]] && continue
    [[ "$line" =~ ^[[:space:]]*# ]] && continue

    case "$line" in
      ADMIN_USERNAME=*|ADMIN_PASSWORD=*|NEW_ADMIN_PASSWORD=*|API_PORT=*|API_BASE=*)
        key="${line%%=*}"
        val="${line#*=}"
        val="$(strip_quotes "$val")"
        export "$key=$val"
        ;;
      *)
        ;;
    esac
  done < "$ENV_FILE"
}

escape_sed() {
  printf '%s' "$1" | sed -e 's/[|&\\]/\\&/g'
}

upsert_line() {
  local key="$1"
  local line="$2"
  local escaped
  escaped="$(escape_sed "$line")"

  if grep -qE "^${key}=" "$ENV_FILE"; then
    sed -i "s|^${key}=.*|${escaped}|" "$ENV_FILE"
  else
    echo "$line" >> "$ENV_FILE"
  fi
}

main() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "This script must be run as root"
  fi

  local public_host="${1:-}"
  local new_admin_password="${2:-}"

  if [[ -z "$public_host" ]]; then
    read -r -p "YOUR_PUBLIC_IP / domain (no scheme, no port): " public_host
  fi
  if [[ -z "$new_admin_password" ]]; then
    read -r -s -p "NEW_ADMIN_PASSWORD: " new_admin_password
    echo
  fi

  public_host="${public_host#http://}"
  public_host="${public_host#https://}"
  public_host="${public_host%%/}"

  [[ -n "$public_host" ]] || die "Public host is required."
  if [[ "$public_host" == *:* ]]; then
    die "Public host must not include a port."
  fi
  [[ -n "$new_admin_password" ]] || die "NEW_ADMIN_PASSWORD is required."

  if [[ ! -f "$ENV_FILE" && -f "$ENV_EXAMPLE" ]]; then
    cp "$ENV_EXAMPLE" "$ENV_FILE"
  fi
  [[ -f "$ENV_FILE" ]] || die "Missing ${ENV_FILE}. Please create it from .env.example."

  local cors_line vite_line pass_line
  cors_line="CORS_ORIGIN=\"http://localhost:8080,http://localhost:5173,http://${public_host}:8080\""
  vite_line="VITE_API_URL=http://${public_host}:3001/api"
  pass_line="NEW_ADMIN_PASSWORD=${new_admin_password}"

  upsert_line "CORS_ORIGIN" "$cors_line"
  upsert_line "VITE_API_URL" "$vite_line"
  upsert_line "NEW_ADMIN_PASSWORD" "$pass_line"

  if command -v docker >/dev/null 2>&1; then
    cd "$STACK_DIR"
    log "Restarting docker compose (with build) to apply .env changes..."
    docker compose up -d --build >/dev/null 2>&1 || log "docker compose up failed."
  else
    log "Docker not installed; skipping compose restart."
  fi

  if [[ -x "$BOOTSTRAP_SCRIPT" ]]; then
    load_env
    ADMIN_USERNAME="${ADMIN_USERNAME:-admin}"
    API_PORT="${API_PORT:-3001}"
    API_BASE="${API_BASE:-http://127.0.0.1:${API_PORT}/api}"
    PROXY_CONTAINER="${PROXY_CONTAINER:-$PROXY_CONTAINER_DEFAULT}"
    DVWA_CONTAINER="${DVWA_CONTAINER:-$DVWA_CONTAINER_DEFAULT}"
    log "Running bootstrap-nginx_love.sh for password update flow..."
    tmp_bootstrap="$(mktemp)"
    sed -e 's/\r$//' "$BOOTSTRAP_SCRIPT" > "$tmp_bootstrap"
    chmod +x "$tmp_bootstrap"
    ADMIN_USERNAME="$ADMIN_USERNAME" \
    ADMIN_PASSWORD="${ADMIN_PASSWORD:-}" \
    NEW_ADMIN_PASSWORD="$new_admin_password" \
    API_BASE="$API_BASE" \
    PROXY_CONTAINER="$PROXY_CONTAINER" \
    DVWA_CONTAINER="$DVWA_CONTAINER" \
    bash "$tmp_bootstrap" || log "bootstrap-nginx_love.sh failed."
    rm -f "$tmp_bootstrap"
  else
    log "Missing bootstrap script at ${BOOTSTRAP_SCRIPT}; skipping password update flow."
  fi
}

main "$@"
