#!/usr/bin/env bash
set -Eeuo pipefail

# ==============================
# Configuration
# ==============================
API_BASE="${API_BASE:-http://localhost:3001/api}"

ADMIN_USERNAME="${ADMIN_USERNAME:-admin}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-admin123}"

NEW_ADMIN_PASSWORD="${NEW_ADMIN_PASSWORD:-Changeme123!}"
TOTP_CODE="${TOTP_CODE:-}"

log() { echo "[*] $*" >&2; }
die() { echo "[!]" "$*" >&2; exit 1; }

on_err() {
  local exit_code=$?
  log "ERROR: command failed (exit=$exit_code) at line ${BASH_LINENO[0]}: ${BASH_COMMAND}"
  exit "$exit_code"
}
trap on_err ERR

require_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"; }

# ==============================
# HTTP helpers
# ==============================
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

curl_auth_get() {
  local url="$1"
  local token="$2"
  curl -sS -H "Authorization: Bearer $token" "$url"
}

disable_all_crs_rules() {
  local token="$1"
  log "Disabling all enabled CRS rules..."

  local resp
  resp="$(curl_auth_get "$API_BASE/modsec/crs/rules" "$token")" || {
    log "Failed to fetch CRS rules"
    return 1
  }

  echo "$resp" | jq . >/dev/null 2>&1 || {
    log "CRS rules response is not valid JSON"
    printf '%s\n' "$resp" >&2
    return 1
  }

  local rule_files
  rule_files="$(echo "$resp" | jq -r '.data[] | select(.enabled == true) | .ruleFile')"

  if [[ -z "$rule_files" ]]; then
    log "No enabled CRS rules found."
    return 0
  fi

  while IFS= read -r rule_file; do
    [[ -z "$rule_file" ]] && continue
    log "Disabling CRS rule: $rule_file"
    curl_json "PATCH" "$API_BASE/modsec/crs/rules/$rule_file/toggle" '{}' "$token" >/dev/null
  done <<< "$rule_files"

  log "All CRS rules disabled."
}

disable_all_custom_rules() {
  local token="$1"
  log "Disabling all enabled custom ModSecurity rules..."

  local resp
  resp="$(curl_auth_get "$API_BASE/modsec/rules" "$token")" || {
    log "Failed to fetch custom rules"
    return 1
  }

  echo "$resp" | jq . >/dev/null 2>&1 || {
    log "Custom rules response is not valid JSON"
    printf '%s\n' "$resp" >&2
    return 1
  }

  local rule_ids
  rule_ids="$(echo "$resp" | jq -r '.data[] | select(.enabled == true) | .id')"

  if [[ -z "$rule_ids" ]]; then
    log "No enabled custom rules found."
    return 0
  fi

  while IFS= read -r rule_id; do
    [[ -z "$rule_id" ]] && continue
    log "Disabling custom rule: $rule_id"
    curl_json "PATCH" "$API_BASE/modsec/rules/$rule_id/toggle" '{}' "$token" >/dev/null
  done <<< "$rule_ids"

  log "All custom rules disabled."
}

# ==============================
# Auth flow
# ==============================
change_password_first_login() {
  local user_id="$1" temp_token="$2" new_password="$3"
  log "Changing admin password via FIRST-LOGIN endpoint..."

  local body resp
  body="$(jq -n --arg u "$user_id" --arg t "$temp_token" --arg n "$new_password" '{userId:$u,tempToken:$t,newPassword:$n}')"
  resp="$(curl_json "POST" "$API_BASE/auth/first-login/change-password" "$body")" || return 1

  echo "$resp" | jq . >/dev/null 2>&1 || {
    log "First-login password change response is not valid JSON:"
    printf '%s\n' "$resp" >&2
    return 1
  }

  local ok
  ok="$(echo "$resp" | jq -r '.success // false' 2>/dev/null || echo false)"
  [[ "$ok" == "true" ]] || {
    log "First-login password change returned success=false:"
    echo "$resp" | jq . >&2 || true
    return 1
  }

  log "First-login password change succeeded."
  return 0
}

login_once() {
  # Returns raw JSON response (stdout). Non-zero if HTTP not 2xx.
  local username="$1" password="$2"
  local login_body
  if [[ -n "$TOTP_CODE" ]]; then
    login_body="$(jq -n --arg u "$username" --arg p "$password" --arg t "$TOTP_CODE" '{username:$u,password:$p,totpCode:$t}')"
  else
    login_body="$(jq -n --arg u "$username" --arg p "$password" '{username:$u,password:$p}')"
  fi
  curl_json "POST" "$API_BASE/auth/login" "$login_body"
}

login() {
  # Returns access token on stdout; non-zero on failure (does NOT exit)
  local username="$1" password="$2"
  log "Logging in as user: $username"

  local resp require_change
  resp="$(login_once "$username" "$password")" || {
    log "Login HTTP failed."
    return 1
  }

  require_change="$(echo "$resp" | jq -r '.data.requirePasswordChange // false' 2>/dev/null || echo false)"
  if [[ "$require_change" == "true" ]]; then
    log "Server requires first-time password change (requirePasswordChange=true)."

    local user_id temp_token
    user_id="$(echo "$resp" | jq -r '.data.userId // empty')"
    temp_token="$(echo "$resp" | jq -r '.data.tempToken // empty')"

    if [[ -z "$user_id" || -z "$temp_token" || "$user_id" == "null" || "$temp_token" == "null" ]]; then
      log "requirePasswordChange=true but userId/tempToken missing. Raw response:"
      printf '%s\n' "$resp" >&2
      return 1
    fi

    [[ -n "$NEW_ADMIN_PASSWORD" ]] || {
      log "NEW_ADMIN_PASSWORD is empty but password change is required."
      return 1
    }

    change_password_first_login "$user_id" "$temp_token" "$NEW_ADMIN_PASSWORD" || return 1

    log "Re-logging in with NEW_ADMIN_PASSWORD..."
    resp="$(login_once "$username" "$NEW_ADMIN_PASSWORD")" || return 1
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

main() {
  require_cmd curl
  require_cmd jq

  [[ -n "${ADMIN_PASSWORD:-}" ]] || die "ADMIN_PASSWORD is required (set it in .env or environment)."
  if [[ -z "${NEW_ADMIN_PASSWORD:-}" ]]; then
    NEW_ADMIN_PASSWORD="$ADMIN_PASSWORD"
  fi

  log "=== Step 1: Login & (if required) change admin password ==="
  local token
  token="$(login_with_fallback)"
  log "Access token acquired."

  log "=== Step 2: Disable all ModSecurity rules ==="
  disable_all_crs_rules "$token"
  disable_all_custom_rules "$token"

  log "Bootstrap completed."
}

main "$@"
