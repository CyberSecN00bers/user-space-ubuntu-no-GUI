#!/usr/bin/env bash
set -Eeuo pipefail

STACK_DIR="${CAPSTONE_STACK_DIR:-/opt/capstone-userstack}"
STATE_DIR="${STACK_DIR}/runtime"
PORTS_FILE="${GOR_PORTS_FILE:-${STATE_DIR}/gor-mirror-ports.txt}"
PID_FILE="${GOR_PID_FILE:-/run/capstone-gor-mirror.pid}"
LOG_FILE="${GOR_LOG_FILE:-/var/log/capstone-gor-mirror.log}"
TARGET_URL="${GOR_TARGET_URL:-http://127.0.0.1:60085}"
LISTEN_HOST="${GOR_LISTEN_HOST:-any}"
RAW_ENGINE="${GOR_RAW_ENGINE:-libpcap}"
RAW_INTERFACE="${GOR_RAW_INTERFACE:-}"

log() { echo "[*] $*" >&2; }
die() { echo "[!]" "$*" >&2; exit 1; }

usage() {
  cat >&2 <<'EOF'
Usage:
  addport <port> [port ...]
  addport start <port> [port ...]
  addport remove <port> [port ...]
  addport list
  addport status
  addport stop
  addport run <port> [port ...]

Behavior:
  - `addport <port> ...` merges ports into the saved list, restarts gor in background, and forwards to http://127.0.0.1:60085.
  - `start` replaces the saved port list, then restarts gor.
  - `remove` deletes ports from the saved list, then restarts gor if any ports remain.
  - `run` starts gor in the foreground without changing the saved list.

Overrides:
  - GOR_TARGET_URL     (default: http://127.0.0.1:60085)
  - GOR_LISTEN_HOST    (default: any)
  - GOR_RAW_INTERFACE  (default: empty; used when GOR_LISTEN_HOST is empty)
  - GOR_RAW_ENGINE     (default: libpcap)
EOF
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "This script must be run as root."
  fi
}

require_gor() {
  command -v gor >/dev/null 2>&1 || die "gor is not installed or not in PATH."
}

ensure_state_dir() {
  mkdir -p "$STATE_DIR"
}

validate_port() {
  local port="$1"
  [[ "$port" =~ ^[0-9]+$ ]] || die "Port must be numeric: $port"
  (( port >= 1 && port <= 65535 )) || die "Port out of range: $port"
}

normalize_ports() {
  local token port
  for token in "$@"; do
    token="${token//,/ }"
    for port in $token; do
      validate_port "$port"
      printf '%s\n' "$port"
    done
  done | sort -n -u
}

load_saved_ports() {
  [[ -f "$PORTS_FILE" ]] || return 0
  awk '/^[0-9]+$/' "$PORTS_FILE" | sort -n -u
}

save_ports() {
  ensure_state_dir
  if [[ "$#" -eq 0 ]]; then
    rm -f "$PORTS_FILE"
    return 0
  fi
  printf '%s\n' "$@" > "$PORTS_FILE"
}

is_running() {
  [[ -f "$PID_FILE" ]] || return 1

  local pid
  pid="$(<"$PID_FILE")"
  [[ -n "$pid" ]] || return 1
  kill -0 "$pid" >/dev/null 2>&1
}

stop_running() {
  if ! is_running; then
    rm -f "$PID_FILE"
    return 0
  fi

  local pid
  pid="$(<"$PID_FILE")"
  log "Stopping gor mirror (pid=$pid)"
  kill "$pid" >/dev/null 2>&1 || true

  local waited=0
  while kill -0 "$pid" >/dev/null 2>&1; do
    if (( waited >= 10 )); then
      die "gor did not stop cleanly (pid=$pid)"
    fi
    sleep 1
    waited=$((waited + 1))
  done

  rm -f "$PID_FILE"
}

build_gor_args() {
  local port endpoint
  GOR_ARGS=(
    --input-raw-engine "$RAW_ENGINE"
    --output-http "$TARGET_URL"
  )

  for port in "$@"; do
    if [[ -n "$LISTEN_HOST" ]]; then
      endpoint="${LISTEN_HOST}:${port}"
    elif [[ -n "$RAW_INTERFACE" ]]; then
      endpoint="${RAW_INTERFACE}:${port}"
    else
      endpoint=":${port}"
    fi
    GOR_ARGS+=(--input-raw "$endpoint")
  done
}

start_background() {
  local ports=("$@")
  [[ "${#ports[@]}" -gt 0 ]] || die "At least one port is required."

  build_gor_args "${ports[@]}"
  mkdir -p "$(dirname "$LOG_FILE")"
  : > "$LOG_FILE"

  log "Starting gor mirror for ports: ${ports[*]}"
  nohup gor "${GOR_ARGS[@]}" >>"$LOG_FILE" 2>&1 &
  echo $! > "$PID_FILE"
  sleep 1

  if ! is_running; then
    rm -f "$PID_FILE"
    die "gor failed to start. Check $LOG_FILE"
  fi

  log "Forwarding traffic to $TARGET_URL"
}

run_foreground() {
  local ports=("$@")
  [[ "${#ports[@]}" -gt 0 ]] || die "At least one port is required."

  build_gor_args "${ports[@]}"
  log "Running gor in foreground for ports: ${ports[*]}"
  exec gor "${GOR_ARGS[@]}"
}

cmd_start() {
  local ports=("$@")
  [[ "${#ports[@]}" -gt 0 ]] || die "No ports provided."

  stop_running
  save_ports "${ports[@]}"
  start_background "${ports[@]}"
}

cmd_add() {
  local existing new_ports merged
  mapfile -t existing < <(load_saved_ports)
  mapfile -t new_ports < <(normalize_ports "$@")
  [[ "${#new_ports[@]}" -gt 0 ]] || die "No ports provided."

  mapfile -t merged < <(printf '%s\n' "${existing[@]}" "${new_ports[@]}" | sed '/^$/d' | sort -n -u)
  stop_running
  save_ports "${merged[@]}"
  start_background "${merged[@]}"
}

cmd_remove() {
  local current to_remove remaining port removed skip
  mapfile -t current < <(load_saved_ports)
  [[ "${#current[@]}" -gt 0 ]] || die "No saved ports to remove."

  mapfile -t to_remove < <(normalize_ports "$@")
  [[ "${#to_remove[@]}" -gt 0 ]] || die "No ports provided."

  remaining=()
  for port in "${current[@]}"; do
    skip=0
    for removed in "${to_remove[@]}"; do
      if [[ "$port" == "$removed" ]]; then
        skip=1
        break
      fi
    done
    if (( skip == 0 )); then
      remaining+=("$port")
    fi
  done

  stop_running
  if [[ "${#remaining[@]}" -eq 0 ]]; then
    save_ports
    log "No ports remain. gor mirror stopped."
    return 0
  fi

  save_ports "${remaining[@]}"
  start_background "${remaining[@]}"
}

cmd_list() {
  local current
  mapfile -t current < <(load_saved_ports)
  if [[ "${#current[@]}" -eq 0 ]]; then
    echo "No saved ports."
    return 0
  fi
  printf '%s\n' "${current[@]}"
}

cmd_status() {
  local current pid
  mapfile -t current < <(load_saved_ports)
  if is_running; then
    pid="$(<"$PID_FILE")"
    echo "running pid=$pid target=$TARGET_URL ports=${current[*]:-none}"
  else
    echo "stopped target=$TARGET_URL ports=${current[*]:-none}"
  fi
}

main() {
  require_root
  require_gor
  local command ports

  command="${1:-add}"
  case "$command" in
    start|add|remove|run|list|status|stop)
      shift || true
      ;;
    -h|--help|help)
      usage
      exit 0
      ;;
    *)
      command="add"
      ;;
  esac

  case "$command" in
    start)
      mapfile -t ports < <(normalize_ports "$@")
      cmd_start "${ports[@]}"
      ;;
    add)
      cmd_add "$@"
      ;;
    remove)
      cmd_remove "$@"
      ;;
    run)
      mapfile -t ports < <(normalize_ports "$@")
      run_foreground "${ports[@]}"
      ;;
    list)
      cmd_list
      ;;
    status)
      cmd_status
      ;;
    stop)
      stop_running
      ;;
  esac
}

main "$@"
