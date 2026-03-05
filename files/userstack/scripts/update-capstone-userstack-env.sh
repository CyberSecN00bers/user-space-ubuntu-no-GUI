#!/usr/bin/env bash
set -euo pipefail

STACK_DIR="${CAPSTONE_STACK_DIR:-/opt/capstone-userstack}"
ENV_FILE="${STACK_DIR}/.env"
ENV_EXAMPLE="${STACK_DIR}/.env.example"
HOSTS_FILE="/etc/hosts"

if [[ "${EUID}" -ne 0 ]]; then
  echo "This script must be run as root" >&2
  exit 1
fi

if [[ -f "${ENV_EXAMPLE}" && ! -f "${ENV_FILE}" ]]; then
  cp "${ENV_EXAMPLE}" "${ENV_FILE}"
fi

get_primary_ip() {
  local ip
  ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '/src/ {for (i=1;i<=NF;i++) if ($i==\"src\") {print $(i+1); exit}}')" || true
  if [[ -z "$ip" ]]; then
    ip="$(ip -4 addr show scope global 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1 | head -n1)" || true
  fi
  echo "$ip"
}

PRIMARY_IP="$(get_primary_ip)"
if [[ -n "${PRIMARY_IP}" && -f "${ENV_FILE}" ]]; then
  CORS_ORIGIN_VALUE="CORS_ORIGIN=\"http://localhost:8080,http://localhost:5173,http://${PRIMARY_IP}:8080\""
  VITE_API_URL_VALUE="VITE_API_URL=http://${PRIMARY_IP}:3001/api"

  if grep -q '^CORS_ORIGIN=' "${ENV_FILE}"; then
    sed -i "s|^CORS_ORIGIN=.*|${CORS_ORIGIN_VALUE}|" "${ENV_FILE}"
  else
    echo "${CORS_ORIGIN_VALUE}" >> "${ENV_FILE}"
  fi

  if grep -q '^VITE_API_URL=' "${ENV_FILE}"; then
    sed -i "s|^VITE_API_URL=.*|${VITE_API_URL_VALUE}|" "${ENV_FILE}"
  else
    echo "${VITE_API_URL_VALUE}" >> "${ENV_FILE}"
  fi
fi

touch "${HOSTS_FILE}"

ensure_host() {
  local host="$1"
  if ! grep -qE "(^|[[:space:]])${host}([[:space:]]|$)" "${HOSTS_FILE}"; then
    echo "127.0.0.1 ${host}" >> "${HOSTS_FILE}"
  fi
}

ensure_host "dvwa.local"
