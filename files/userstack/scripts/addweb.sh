#!/usr/bin/env bash
set -Eeuo pipefail

ENV_FILE="/opt/capstone-userstack/.env"

log() { echo "[*] $*" >&2; }
die() { echo "[!]" "$*" >&2; exit 1; }
usage() { echo "Usage: addweb <domain> <port>  (or addweb <domain>:<port> for systemd template)" >&2; }

on_err() {
  local exit_code=$?
  log "ERROR: command failed (exit=$exit_code) at line ${BASH_LINENO[0]}: ${BASH_COMMAND}"
  exit "$exit_code"
}
trap on_err ERR

require_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"; }

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
  [[ -f "$ENV_FILE" ]] || die "Missing ${ENV_FILE}. Please create it from .env.example."

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

get_primary_ip() {
  local ip
  ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '/src/ {for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}')" || true
  if [[ -z "$ip" ]]; then
    ip="$(ip -4 addr show scope global 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1 | head -n1)" || true
  fi
  echo "$ip"
}

curl_json() {
  # Usage: curl_json METHOD URL JSON_BODY [TOKEN]
  local method="$1"
  local url="$2"
  local body="${3:-}"
  local token="${4:-}"

  local out http_code
  if [[ -n "$token" ]]; then
    out="$(curl -sS -X "$method" -H "Content-Type: application/json" -H "Authorization: Bearer $token" -d "$body" -w $'\n__HTTP_CODE__:%{http_code}\n' "$url" 2>&1)" || true
  else
    out="$(curl -sS -X "$method" -H "Content-Type: application/json" -d "$body" -w $'\n__HTTP_CODE__:%{http_code}\n' "$url" 2>&1)" || true
  fi

  http_code="$(printf '%s' "$out" | awk -F: '/__HTTP_CODE__:/ {print $2}' | tail -n 1 | tr -d '\r')"
  out="$(printf '%s' "$out" | sed '/__HTTP_CODE__:/d')"

  if [[ -z "$http_code" ]]; then
    log "curl failed (no HTTP code). Output:"
    printf '%s\n' "$out" >&2
    return 1
  fi

  if [[ "$http_code" -lt 200 || "$http_code" -ge 300 ]]; then
    log "HTTP $http_code from $method $url"
    log "Response:"
    printf '%s\n' "$out" >&2
    return 1
  fi

  printf '%s' "$out"
}

build_domain_payload() {
  local domain_name="$1" upstream_ip="$2" upstream_port="$3"

  jq -n --arg name "$domain_name" --arg host "$upstream_ip" --argjson port "$upstream_port" '
  {
    name: $name,
    status: "active",
    modsecEnabled: true,
    upstreams: [
      {
        host: $host,
        port: $port,
        protocol: "http",
        sslVerify: false,
        weight: 1,
        maxFails: 3,
        failTimeout: 30
      }
    ],
    loadBalancer: {
      algorithm: "round_robin",
      healthCheckEnabled: true,
      healthCheckInterval: 30,
      healthCheckTimeout: 5,
      healthCheckPath: "/"
    },
    realIpConfig: {
      realIpEnabled: false,
      realIpCloudflare: false,
      realIpCustomCidrs: []
    },
    advancedConfig: {
      hstsEnabled: false,
      http2Enabled: true,
      grpcEnabled: false,
      clientMaxBodySize: 100,
      customLocations: []
    }
  }'
}

login_once() {
  local username="$1" password="$2"
  local login_body
  login_body="$(jq -n --arg u "$username" --arg p "$password" '{username:$u,password:$p}')"
  curl_json "POST" "$API_BASE/auth/login" "$login_body"
}

login() {
  local username="$1" password="$2"
  log "Logging in as user: $username"

  local resp require_change
  resp="$(login_once "$username" "$password")" || {
    log "Login HTTP failed."
    return 1
  }

  require_change="$(echo "$resp" | jq -r '.data.requirePasswordChange // false' 2>/dev/null || echo false)"
  if [[ "$require_change" == "true" ]]; then
    die "Password change required for admin. Run bootstrap-nginx_love.sh or change password in UI; addweb will not change it."
  fi

  local token
  token="$(echo "$resp" | jq -r '.data.accessToken // .accessToken // empty' 2>/dev/null || true)"
  if [[ -z "$token" || "$token" == "null" ]]; then
    log "Cannot extract access token from login response. Raw response:"
    printf '%s\n' "$resp" >&2
    return 1
  fi

  printf '%s' "$token"
  return 0
}

login_with_fallback() {
  local token=""
  if token="$(login "$ADMIN_USERNAME" "$ADMIN_PASSWORD")"; then
    echo "$token"
    return 0
  fi

  log "Login failed with ADMIN_PASSWORD. Trying NEW_ADMIN_PASSWORD..."
  if token="$(login "$ADMIN_USERNAME" "$NEW_ADMIN_PASSWORD")"; then
    echo "$token"
    return 0
  fi

  die "Login failed with both ADMIN_PASSWORD and NEW_ADMIN_PASSWORD."
}

create_domain() {
  local token="$1" payload="$2"
  local name resp ok msg

  name="$(echo "$payload" | jq -r '.name // "unknown"' 2>/dev/null || echo "unknown")"
  log "Creating domain '$name' via /domains ..."

  resp="$(curl_json "POST" "$API_BASE/domains" "$payload" "$token")" || return 1

  echo "$resp" | jq . >/dev/null 2>&1 || {
    log "Create domain response is not valid JSON:"
    printf '%s\n' "$resp" >&2
    return 1
  }

  ok="$(echo "$resp" | jq -r '.success // false' 2>/dev/null || echo false)"
  msg="$(echo "$resp" | jq -r '.message // ""' 2>/dev/null || echo "")"

  if [[ "$ok" == "true" ]]; then
    log "Domain '$name' created."
    echo "$resp" | jq .
    return 0
  fi

  if echo "$msg" | grep -Eqi 'already exists|exists|duplicate|unique'; then
    log "Domain '$name' already exists. Skipping."
    return 0
  fi

  log "Create domain failed. Response:"
  echo "$resp" | jq . >&2 || true
  return 1
}

parse_args() {
  local arg="$1"

  if [[ $# -eq 2 ]]; then
    echo "$1" "$2"
    return 0
  fi

  if [[ $# -eq 1 && "$arg" == *:* ]]; then
    echo "${arg%%:*}" "${arg##*:}"
    return 0
  fi

  return 1
}

main() {
  local domain port
  if ! read -r domain port < <(parse_args "$@"); then
    usage
    exit 1
  fi

  if [[ -z "$domain" ]]; then
    die "Domain is required."
  fi
  if ! [[ "$port" =~ ^[0-9]+$ ]]; then
    die "Port must be numeric: $port"
  fi
  if (( port < 1 || port > 65535 )); then
    die "Port out of range: $port"
  fi

  require_cmd curl
  require_cmd jq
  require_cmd ip

  load_env

  ADMIN_USERNAME="${ADMIN_USERNAME:-admin}"
  if [[ -z "${ADMIN_PASSWORD:-}" && -z "${NEW_ADMIN_PASSWORD:-}" ]]; then
    die "ADMIN_PASSWORD or NEW_ADMIN_PASSWORD is required (set it in ${ENV_FILE} or environment)."
  fi
  if [[ -z "${ADMIN_PASSWORD:-}" ]]; then
    ADMIN_PASSWORD="$NEW_ADMIN_PASSWORD"
  fi
  if [[ -z "${NEW_ADMIN_PASSWORD:-}" ]]; then
    NEW_ADMIN_PASSWORD="$ADMIN_PASSWORD"
  fi

  API_PORT="${API_PORT:-3001}"
  API_BASE="${API_BASE:-http://127.0.0.1:${API_PORT}/api}"

  local host_ip
  host_ip="$(get_primary_ip)"
  [[ -n "$host_ip" ]] || die "Could not determine host IP."

  log "Upstream: ${host_ip}:${port}"

  local payload token
  payload="$(build_domain_payload "$domain" "$host_ip" "$port")"

  token="$(login_with_fallback)"
  create_domain "$token" "$payload"
}

main "$@"
