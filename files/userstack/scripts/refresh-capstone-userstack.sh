#!/usr/bin/env bash
set -euo pipefail

STACK_DIR="${CAPSTONE_STACK_DIR:-/opt/capstone-userstack}"
COMPOSE_FILE="${STACK_DIR}/docker-compose.yml"

if [[ "${EUID}" -ne 0 ]]; then
  echo "This script must be run as root" >&2
  exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "Docker not installed; skipping refresh" >&2
  exit 0
fi

if [[ ! -f "${COMPOSE_FILE}" ]]; then
  echo "Missing ${COMPOSE_FILE}; skipping refresh" >&2
  exit 0
fi

if systemctl list-unit-files docker.service --no-legend 2>/dev/null | awk '{print $1}' | grep -qx docker.service; then
  systemctl start docker.service >/dev/null 2>&1 || true
fi

if [[ -x "${STACK_DIR}/scripts/update-capstone-userstack-env.sh" ]]; then
  "${STACK_DIR}/scripts/update-capstone-userstack-env.sh" >/dev/null 2>&1 || true
fi

cd "${STACK_DIR}"
docker compose down -v >/dev/null 2>&1 || true

if ! docker compose up -d --build >/dev/null 2>&1; then
  echo "Warning: docker compose up failed; skipping" >&2
fi
