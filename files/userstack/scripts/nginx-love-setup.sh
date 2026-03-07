#!/usr/bin/env bash
set -Eeuo pipefail

STACK_DIR="${CAPSTONE_STACK_DIR:-/opt/capstone-userstack}"
ENV_FILE="${STACK_DIR}/.env"
ENV_EXAMPLE="${STACK_DIR}/.env.example"
BOOTSTRAP_SCRIPT="${STACK_DIR}/scripts/bootstrap-nginx_love.sh"

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

retry() {
  local attempts="$1"
  local delay="$2"
  shift 2
  local i=1

  while true; do
    if "$@"; then
      return 0
    fi
    if (( i >= attempts )); then
      return 1
    fi
    sleep "$delay"
    i=$((i + 1))
    delay=$((delay * 2))
  done
}

wait_for_docker() {
  local timeout="${1:-60}"
  local start now
  start="$(date +%s)"
  while true; do
    if docker info >/dev/null 2>&1; then
      return 0
    fi
    now="$(date +%s)"
    if (( now - start >= timeout )); then
      return 1
    fi
    sleep 2
  done
}

wait_for_api() {
  local url="$1"
  local timeout="${2:-180}"
  local interval="${3:-3}"
  local start now
  start="$(date +%s)"
  while true; do
    if curl -fsS "$url" >/dev/null 2>&1; then
      return 0
    fi
    now="$(date +%s)"
    if (( now - start >= timeout )); then
      return 1
    fi
    sleep "$interval"
  done
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

  load_env
  ADMIN_USERNAME="${ADMIN_USERNAME:-admin}"
  API_PORT="${API_PORT:-3001}"
  API_BASE="${API_BASE:-http://127.0.0.1:${API_PORT}/api}"

  local current_admin_password current_new_password
  current_admin_password="${ADMIN_PASSWORD:-}"
  current_new_password="${NEW_ADMIN_PASSWORD:-}"

  if [[ -z "$current_admin_password" && -z "$current_new_password" ]]; then
    die "ADMIN_PASSWORD or NEW_ADMIN_PASSWORD is required in ${ENV_FILE}"
  fi
  if [[ -z "$current_admin_password" ]]; then
    current_admin_password="$current_new_password"
  fi

  local cors_line vite_line
  cors_line="CORS_ORIGIN=\"http://localhost:8080,http://localhost:5173,http://${public_host}:8080\""
  vite_line="VITE_API_URL=http://${public_host}:3001/api"

  upsert_line "CORS_ORIGIN" "$cors_line"
  upsert_line "VITE_API_URL" "$vite_line"

  COMPOSE_RETRY_ATTEMPTS="${COMPOSE_RETRY_ATTEMPTS:-3}"
  COMPOSE_RETRY_DELAY="${COMPOSE_RETRY_DELAY:-10}"
  DOCKER_WAIT_TIMEOUT="${DOCKER_WAIT_TIMEOUT:-60}"
  API_WAIT_TIMEOUT="${API_WAIT_TIMEOUT:-180}"
  API_WAIT_INTERVAL="${API_WAIT_INTERVAL:-3}"

  if command -v docker >/dev/null 2>&1; then
    if ! wait_for_docker "$DOCKER_WAIT_TIMEOUT"; then
      die "Docker daemon not ready after ${DOCKER_WAIT_TIMEOUT}s"
    fi
    cd "$STACK_DIR"
    log "Starting docker compose (with build) to apply .env changes..."
    if ! retry "$COMPOSE_RETRY_ATTEMPTS" "$COMPOSE_RETRY_DELAY" docker compose up -d --build; then
      die "docker compose up failed after ${COMPOSE_RETRY_ATTEMPTS} attempts"
    fi
    log "Waiting for API health: ${API_BASE}/health"
    if ! wait_for_api "${API_BASE}/health" "$API_WAIT_TIMEOUT" "$API_WAIT_INTERVAL"; then
      die "API not ready after ${API_WAIT_TIMEOUT}s"
    fi
  else
    die "Docker not installed; cannot proceed."
  fi

  if [[ -x "$BOOTSTRAP_SCRIPT" ]]; then
    log "Running bootstrap-nginx_love.sh for password update flow..."
    tmp_bootstrap="$(mktemp)"
    sed -e 's/\r$//' "$BOOTSTRAP_SCRIPT" > "$tmp_bootstrap"
    chmod +x "$tmp_bootstrap"

    BOOTSTRAP_RETRY_ATTEMPTS="${BOOTSTRAP_RETRY_ATTEMPTS:-3}"
    BOOTSTRAP_RETRY_DELAY="${BOOTSTRAP_RETRY_DELAY:-5}"

    run_bootstrap() {
      ADMIN_USERNAME="$ADMIN_USERNAME" \
        ADMIN_PASSWORD="$current_admin_password" \
        NEW_ADMIN_PASSWORD="$new_admin_password" \
        API_BASE="$API_BASE" \
        bash "$tmp_bootstrap"
    }

    if retry "$BOOTSTRAP_RETRY_ATTEMPTS" "$BOOTSTRAP_RETRY_DELAY" run_bootstrap; then
      log "Password updated; syncing credentials in .env"
      upsert_line "ADMIN_PASSWORD" "ADMIN_PASSWORD=${new_admin_password}"
      upsert_line "NEW_ADMIN_PASSWORD" "NEW_ADMIN_PASSWORD=${new_admin_password}"
    else
      log "bootstrap-nginx_love.sh failed after ${BOOTSTRAP_RETRY_ATTEMPTS} attempts."
    fi
    rm -f "$tmp_bootstrap"
  else
    log "Missing bootstrap script at ${BOOTSTRAP_SCRIPT}; skipping password update flow."
  fi
}

main "$@"
