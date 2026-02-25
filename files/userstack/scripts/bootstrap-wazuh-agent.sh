#!/usr/bin/env bash
set -euo pipefail

OSSEC_CONF="/var/ossec/etc/ossec.conf"
CLIENT_KEYS="/var/ossec/etc/client.keys"
AGENT_AUTH="/var/ossec/bin/agent-auth"
AUTH_PORT="1515"

log() { echo "[wazuh-bootstrap] $*" >&2; }

if [[ "${EUID}" -ne 0 ]]; then
  log "This script must be run as root"
  exit 0
fi

if [[ ! -x "$AGENT_AUTH" ]]; then
  log "agent-auth not found; skipping"
  exit 0
fi

if [[ ! -f "$OSSEC_CONF" ]]; then
  log "Missing $OSSEC_CONF; skipping"
  exit 0
fi

MANAGER_ADDR="$(awk -F'[<>]' '/<address>/{print $3; exit}' "$OSSEC_CONF" | tr -d '[:space:]')"
if [[ -z "$MANAGER_ADDR" ]]; then
  log "Manager address not set; skipping"
  exit 0
fi

HOST_SHORT="$(hostname -s 2>/dev/null || hostname)"
BASE_NAME="$(printf '%s' "$HOST_SHORT" | tr -c 'A-Za-z0-9._-' '-')"
AGENT_NAME="$BASE_NAME"

if [[ -f "$CLIENT_KEYS" ]]; then
  if grep -qE "^[0-9]+[[:space:]]+${AGENT_NAME}[[:space:]]" "$CLIENT_KEYS"; then
    log "Agent already registered as ${AGENT_NAME}"
    exit 0
  fi
fi

rm -f "$CLIENT_KEYS" >/dev/null 2>&1 || true

out="$("$AGENT_AUTH" -m "$MANAGER_ADDR" -p "$AUTH_PORT" -A "$AGENT_NAME" 2>&1)" && {
  log "Enrolled agent as ${AGENT_NAME}"
  exit 0
}

if echo "$out" | grep -qi "Duplicate agent name"; then
  log "Duplicate agent name ${AGENT_NAME}; skipping"
  exit 0
fi

log "agent-auth failed: ${out}"
exit 0
