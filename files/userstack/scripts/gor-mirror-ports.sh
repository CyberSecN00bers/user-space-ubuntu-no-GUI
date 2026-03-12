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
RAW_BPF_FILTER="${GOR_BPF_FILTER:-}"
AUTO_BPF="${GOR_AUTO_BPF:-1}"
AUTO_DETECT_DOCKER="${GOR_AUTO_DETECT_DOCKER:-1}"
AUTO_DETECT_DOCKER_PORTS="${GOR_AUTO_DETECT_DOCKER_PORTS:-all}"
RAW_PROMISC="${GOR_RAW_PROMISC:-0}"
LISTEN_HOST_EXPLICIT="${GOR_LISTEN_HOST+x}"
RAW_INTERFACE_EXPLICIT="${GOR_RAW_INTERFACE+x}"
RAW_BPF_FILTER_EXPLICIT="${GOR_BPF_FILTER+x}"
SPEC_SEP=$'\x1f'
PROCESS_SPECS=()
RESOLVED_ENDPOINT_HOST=""
RESOLVED_CAPTURE_PORT=""
RESOLVED_BPF_MODE=""
RESOLVED_BPF_FILTER=""
RESOLVED_LABEL=""

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
  - By default, Docker auto-detection is applied to all Docker-published ports.

Overrides:
  - GOR_TARGET_URL     (default: http://127.0.0.1:60085)
  - GOR_LISTEN_HOST    (default: any)
  - GOR_RAW_INTERFACE  (default: empty; used when GOR_LISTEN_HOST is empty)
  - GOR_BPF_FILTER     (default: auto when GOR_RAW_INTERFACE is set)
  - GOR_AUTO_BPF       (default: 1; build `tcp and (dst port ...)` for GOR_RAW_INTERFACE)
  - GOR_AUTO_DETECT_DOCKER (default: 1; detect Docker-published ports and use the bridge interface automatically)
  - GOR_AUTO_DETECT_DOCKER_PORTS (default: all)
  - GOR_RAW_PROMISC    (default: 0)
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

has_command() {
  command -v "$1" >/dev/null 2>&1
}

csv_contains() {
  local needle="$1"
  local haystack="${2// /}"
  [[ "$haystack" == "all" || "$haystack" == "*" ]] && return 0
  case ",${haystack}," in
    *,"$needle",*) return 0 ;;
    *) return 1 ;;
  esac
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

pid_file_lines() {
  [[ -f "$PID_FILE" ]] || return 0
  sed '/^[[:space:]]*$/d' "$PID_FILE"
}

extract_pid() {
  local line="$1"
  IFS=$'\t' read -r pid _ <<<"$line"
  printf '%s\n' "$pid"
}

is_running() {
  local line pid
  while IFS= read -r line; do
    pid="$(extract_pid "$line")"
    if [[ -n "$pid" ]] && kill -0 "$pid" >/dev/null 2>&1; then
      return 0
    fi
  done < <(pid_file_lines)
  return 1
}

stop_running() {
  local line pid waited
  local -a pids=()

  while IFS= read -r line; do
    pid="$(extract_pid "$line")"
    [[ -n "$pid" ]] && pids+=("$pid")
  done < <(pid_file_lines)

  if [[ "${#pids[@]}" -eq 0 ]]; then
    rm -f "$PID_FILE"
    return 0
  fi

  log "Stopping gor mirror pids: ${pids[*]}"
  kill "${pids[@]}" >/dev/null 2>&1 || true

  waited=0
  while :; do
    local alive=0
    for pid in "${pids[@]}"; do
      if kill -0 "$pid" >/dev/null 2>&1; then
        alive=1
        break
      fi
    done

    if (( alive == 0 )); then
      break
    fi

    if (( waited >= 10 )); then
      die "gor did not stop cleanly (pids=${pids[*]})"
    fi
    sleep 1
    waited=$((waited + 1))
  done

  rm -f "$PID_FILE"
}

build_default_bpf_filter() {
  local port filter=""
  for port in "$@"; do
    if [[ -n "$filter" ]]; then
      filter+=" or "
    fi
    filter+="dst port $port"
  done

  printf 'tcp and (%s)' "$filter"
}

append_assoc_csv_unique() {
  local -n assoc_ref="$1"
  local key="$2"
  local value="$3"
  local current="${assoc_ref[$key]-}"

  case ",${current}," in
    *,"$value",*)
      return 0
      ;;
  esac

  if [[ -n "$current" ]]; then
    assoc_ref[$key]="${current},${value}"
  else
    assoc_ref[$key]="$value"
  fi
}

format_endpoint() {
  local endpoint_host="$1"
  local capture_ports_csv="$2"
  if [[ -n "$endpoint_host" ]]; then
    printf '%s:%s' "$endpoint_host" "$capture_ports_csv"
  else
    printf ':%s' "$capture_ports_csv"
  fi
}

route_interface_for_ip() {
  local ip_addr="$1"
  ip route get "$ip_addr" 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i == "dev") {print $(i+1); exit}}'
}

docker_container_ips() {
  local container_id="$1"
  docker inspect -f '{{if .NetworkSettings.IPAddress}}{{println .NetworkSettings.IPAddress}}{{end}}{{range $name, $cfg := .NetworkSettings.Networks}}{{if $cfg.IPAddress}}{{println $cfg.IPAddress}}{{end}}{{end}}' "$container_id" 2>/dev/null | awk 'NF {print $1}' | sort -u
}

docker_container_networks() {
  local container_id="$1"
  docker inspect -f '{{range $name, $cfg := .NetworkSettings.Networks}}{{println $name}}{{end}}' "$container_id" 2>/dev/null | awk 'NF {print $1}' | sort -u
}

docker_bridge_name_for_network() {
  local network_name="$1"
  local bridge_name network_id

  bridge_name="$(docker network inspect "$network_name" --format '{{index .Options "com.docker.network.bridge.name"}}' 2>/dev/null | awk 'NF {print $1; exit}')"
  if [[ -n "$bridge_name" && "$bridge_name" != "<no" ]]; then
    printf '%s\n' "$bridge_name"
    return 0
  fi

  network_id="$(docker network inspect "$network_name" --format '{{.Id}}' 2>/dev/null | awk 'NF {print $1; exit}')"
  if [[ -n "$network_id" ]]; then
    bridge_name="br-${network_id:0:12}"
    if ip link show "$bridge_name" >/dev/null 2>&1; then
      printf '%s\n' "$bridge_name"
      return 0
    fi
  fi

  return 1
}

choose_preferred_interface() {
  local candidate
  local -a candidates=("$@")

  [[ "${#candidates[@]}" -gt 0 ]] || return 1

  for candidate in "${candidates[@]}"; do
    [[ "$candidate" =~ ^br- ]] && { printf '%s\n' "$candidate"; return 0; }
  done

  for candidate in "${candidates[@]}"; do
    [[ "$candidate" == "docker0" ]] && { printf '%s\n' "$candidate"; return 0; }
  done

  printf '%s\n' "${candidates[0]}"
}

docker_capture_interface_for_container() {
  local container_id="$1"
  local ip_addr iface network_name
  local -a candidates=()
  local -A seen=()

  while IFS= read -r ip_addr; do
    iface="$(route_interface_for_ip "$ip_addr")"
    if [[ -n "$iface" && -z "${seen[$iface]+x}" ]]; then
      seen[$iface]=1
      candidates+=("$iface")
    fi
  done < <(docker_container_ips "$container_id")

  if [[ "${#candidates[@]}" -eq 0 ]]; then
    while IFS= read -r network_name; do
      iface="$(docker_bridge_name_for_network "$network_name")"
      if [[ -n "$iface" && -z "${seen[$iface]+x}" ]]; then
        seen[$iface]=1
        candidates+=("$iface")
      fi
    done < <(docker_container_networks "$container_id")
  fi

  choose_preferred_interface "${candidates[@]}"
}

docker_container_name() {
  local container_id="$1"
  docker inspect -f '{{.Name}}' "$container_id" 2>/dev/null | sed 's#^/##'
}

docker_container_port_for_host_port() {
  local container_id="$1"
  local host_port="$2"
  local line container_port published_port

  while IFS= read -r line; do
    [[ "$line" == */tcp* ]] || continue
    container_port="${line%%/*}"
    published_port="${line##* }"
    if [[ "$published_port" == "$host_port" ]]; then
      printf '%s\n' "$container_port"
      return 0
    fi
  done < <(docker inspect -f '{{range $port, $bindings := .NetworkSettings.Ports}}{{if $bindings}}{{range $bindings}}{{println $port .HostPort}}{{end}}{{end}}{{end}}' "$container_id" 2>/dev/null || true)

  return 1
}

resolve_docker_capture() {
  local requested_port="$1"
  local container_id network_mode container_port iface container_name
  local -a matches=()

  [[ "$AUTO_DETECT_DOCKER" != "0" ]] || return 1
  csv_contains "$requested_port" "$AUTO_DETECT_DOCKER_PORTS" || return 1
  has_command docker || return 1
  has_command ip || return 1

  while IFS= read -r container_id; do
    [[ -n "$container_id" ]] || continue
    network_mode="$(docker inspect -f '{{.HostConfig.NetworkMode}}' "$container_id" 2>/dev/null || true)"
    [[ "$network_mode" == "host" ]] && continue

    if ! container_port="$(docker_container_port_for_host_port "$container_id" "$requested_port")"; then
      continue
    fi

    iface="$(docker_capture_interface_for_container "$container_id" || true)"
    [[ -n "$iface" ]] || continue

    container_name="$(docker_container_name "$container_id")"
    matches+=("${container_id}:${container_name}:${iface}:${container_port}")
  done < <(docker ps -q 2>/dev/null || true)

  [[ "${#matches[@]}" -gt 0 ]] || return 1
  if [[ "${#matches[@]}" -gt 1 ]]; then
    log "Multiple Docker matches found for port ${requested_port}; using first: ${matches[0]}"
  fi

  IFS=':' read -r _ container_name iface container_port <<<"${matches[0]}"
  RESOLVED_ENDPOINT_HOST="$iface"
  RESOLVED_CAPTURE_PORT="$container_port"
  RESOLVED_BPF_MODE="auto"
  RESOLVED_BPF_FILTER=""
  RESOLVED_LABEL="docker container=${container_name} host_port=${requested_port} via=${iface} container_port=${container_port}"
  return 0
}

resolve_manual_capture() {
  local requested_port="$1"

  if [[ -n "$LISTEN_HOST" ]]; then
    RESOLVED_ENDPOINT_HOST="$LISTEN_HOST"
    RESOLVED_LABEL="listen_host=${LISTEN_HOST}"
  elif [[ -n "$RAW_INTERFACE" ]]; then
    RESOLVED_ENDPOINT_HOST="$RAW_INTERFACE"
    RESOLVED_LABEL="raw_interface=${RAW_INTERFACE}"
  else
    RESOLVED_ENDPOINT_HOST=""
    RESOLVED_LABEL="listen_host=<empty>"
  fi

  RESOLVED_CAPTURE_PORT="$requested_port"
  RESOLVED_BPF_FILTER="$RAW_BPF_FILTER"
  if [[ -n "$RAW_BPF_FILTER" ]]; then
    RESOLVED_BPF_MODE="custom"
  elif [[ "$AUTO_BPF" != "0" && -z "$LISTEN_HOST" && -n "$RAW_INTERFACE" ]]; then
    RESOLVED_BPF_MODE="auto"
  else
    RESOLVED_BPF_MODE="none"
  fi
}

resolve_default_capture() {
  local requested_port="$1"

  RESOLVED_ENDPOINT_HOST="$LISTEN_HOST"
  RESOLVED_CAPTURE_PORT="$requested_port"
  RESOLVED_BPF_MODE="none"
  RESOLVED_BPF_FILTER=""
  RESOLVED_LABEL="listen_host=${LISTEN_HOST}"
}

resolve_port_capture() {
  local requested_port="$1"

  if [[ -n "$LISTEN_HOST_EXPLICIT" || -n "$RAW_INTERFACE_EXPLICIT" || -n "$RAW_BPF_FILTER_EXPLICIT" ]]; then
    resolve_manual_capture "$requested_port"
    return 0
  fi

  if resolve_docker_capture "$requested_port"; then
    return 0
  fi

  resolve_default_capture "$requested_port"
}

build_process_specs() {
  local requested_port group_key endpoint_host capture_port capture_ports_csv requested_ports_csv bpf_mode bpf_filter label
  local -a group_order=()
  local -A group_capture_ports=()
  local -A group_requested_ports=()
  local -A group_bpf_modes=()
  local -A group_bpf_filters=()
  local -A group_labels=()

  PROCESS_SPECS=()
  for requested_port in "$@"; do
    resolve_port_capture "$requested_port"
    endpoint_host="$RESOLVED_ENDPOINT_HOST"
    capture_port="$RESOLVED_CAPTURE_PORT"
    bpf_mode="$RESOLVED_BPF_MODE"
    bpf_filter="$RESOLVED_BPF_FILTER"
    label="$RESOLVED_LABEL"

    group_key="${endpoint_host}${SPEC_SEP}${bpf_mode}${SPEC_SEP}${bpf_filter}${SPEC_SEP}${label}"
    if [[ -z "${group_bpf_modes[$group_key]+x}" ]]; then
      group_order+=("$group_key")
      group_bpf_modes[$group_key]="$bpf_mode"
      group_bpf_filters[$group_key]="$bpf_filter"
      group_labels[$group_key]="$label"
    fi

    append_assoc_csv_unique group_capture_ports "$group_key" "$capture_port"
    append_assoc_csv_unique group_requested_ports "$group_key" "$requested_port"
  done

  for group_key in "${group_order[@]}"; do
    IFS="$SPEC_SEP" read -r endpoint_host bpf_mode bpf_filter label <<<"$group_key"
    capture_ports_csv="${group_capture_ports[$group_key]}"
    requested_ports_csv="${group_requested_ports[$group_key]}"

    if [[ "$bpf_mode" == "auto" ]]; then
      IFS=',' read -r -a capture_port_array <<<"$capture_ports_csv"
      bpf_filter="$(build_default_bpf_filter "${capture_port_array[@]}")"
    fi

    PROCESS_SPECS+=("${endpoint_host}${SPEC_SEP}${capture_ports_csv}${SPEC_SEP}${requested_ports_csv}${SPEC_SEP}${bpf_filter}${SPEC_SEP}${label}")
  done
}

build_gor_args_for_spec() {
  local endpoint_host="$1"
  local capture_ports_csv="$2"
  local bpf_filter="$3"
  local endpoint

  GOR_ARGS=(
    --http-original-host
    --input-raw-engine "$RAW_ENGINE"
    --output-http "$TARGET_URL"
  )

  if [[ "$RAW_PROMISC" == "1" ]]; then
    GOR_ARGS+=(--input-raw-promisc)
  fi

  endpoint="$(format_endpoint "$endpoint_host" "$capture_ports_csv")"
  GOR_ARGS+=(--input-raw "$endpoint")

  if [[ -n "$bpf_filter" ]]; then
    GOR_ARGS+=(--input-raw-bpf-filter "$bpf_filter")
  fi
}

start_background() {
  local ports=("$@")
  local endpoint_host capture_ports_csv requested_ports_csv bpf_filter label endpoint pid line
  local -a started_pids=()
  [[ "${#ports[@]}" -gt 0 ]] || die "At least one port is required."

  build_process_specs "${ports[@]}"
  mkdir -p "$(dirname "$LOG_FILE")"
  : > "$LOG_FILE"
  : > "$PID_FILE"

  log "Starting gor mirror for ports: ${ports[*]}"
  for line in "${PROCESS_SPECS[@]}"; do
    IFS="$SPEC_SEP" read -r endpoint_host capture_ports_csv requested_ports_csv bpf_filter label <<<"$line"
    endpoint="$(format_endpoint "$endpoint_host" "$capture_ports_csv")"
    build_gor_args_for_spec "$endpoint_host" "$capture_ports_csv" "$bpf_filter"
    log "Starting capture requested_ports=${requested_ports_csv} endpoint=${endpoint} mode=${label}"
    if [[ -n "$bpf_filter" ]]; then
      log "Using BPF filter: $bpf_filter"
    fi
    nohup gor "${GOR_ARGS[@]}" >>"$LOG_FILE" 2>&1 &
    pid=$!
    started_pids+=("$pid")
    printf '%s\t%s\t%s\t%s\t%s\n' "$pid" "$endpoint" "$capture_ports_csv" "$requested_ports_csv" "${bpf_filter:-gor-default}" >>"$PID_FILE"
  done

  sleep 1
  for pid in "${started_pids[@]}"; do
    if ! kill -0 "$pid" >/dev/null 2>&1; then
      stop_running || true
      die "gor failed to start. Check $LOG_FILE"
    fi
  done

  log "Forwarding traffic to $TARGET_URL"
}

run_foreground() {
  local ports=("$@")
  local endpoint_host capture_ports_csv requested_ports_csv bpf_filter label endpoint line
  local -a pids=()
  [[ "${#ports[@]}" -gt 0 ]] || die "At least one port is required."

  build_process_specs "${ports[@]}"
  if [[ "${#PROCESS_SPECS[@]}" -eq 1 ]]; then
    IFS="$SPEC_SEP" read -r endpoint_host capture_ports_csv requested_ports_csv bpf_filter label <<<"${PROCESS_SPECS[0]}"
    endpoint="$(format_endpoint "$endpoint_host" "$capture_ports_csv")"
    build_gor_args_for_spec "$endpoint_host" "$capture_ports_csv" "$bpf_filter"
    log "Running gor in foreground for requested_ports=${requested_ports_csv} endpoint=${endpoint} mode=${label}"
    if [[ -n "$bpf_filter" ]]; then
      log "Using BPF filter: $bpf_filter"
    fi
    exec gor "${GOR_ARGS[@]}"
  fi

  trap 'for pid in "${pids[@]}"; do kill "$pid" >/dev/null 2>&1 || true; done' EXIT INT TERM
  for line in "${PROCESS_SPECS[@]}"; do
    IFS="$SPEC_SEP" read -r endpoint_host capture_ports_csv requested_ports_csv bpf_filter label <<<"$line"
    endpoint="$(format_endpoint "$endpoint_host" "$capture_ports_csv")"
    build_gor_args_for_spec "$endpoint_host" "$capture_ports_csv" "$bpf_filter"
    log "Running gor in foreground for requested_ports=${requested_ports_csv} endpoint=${endpoint} mode=${label}"
    if [[ -n "$bpf_filter" ]]; then
      log "Using BPF filter: $bpf_filter"
    fi
    gor "${GOR_ARGS[@]}" &
    pids+=("$!")
  done

  wait
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
  local current line endpoint_host capture_ports_csv requested_ports_csv bpf_filter label endpoint key
  local pid pid_endpoint pid_capture_ports_csv pid_requested_ports_csv pid_bpf_filter
  local -A live_pids=()
  mapfile -t current < <(load_saved_ports)

  while IFS= read -r line; do
    IFS=$'\t' read -r pid pid_endpoint pid_capture_ports_csv pid_requested_ports_csv pid_bpf_filter <<<"$line"
    if [[ -n "$pid" ]] && kill -0 "$pid" >/dev/null 2>&1; then
      live_pids["${pid_endpoint}"$'\t'"${pid_capture_ports_csv}"]="$pid"
    fi
  done < <(pid_file_lines)

  if [[ "${#current[@]}" -eq 0 ]]; then
    if (( ${#live_pids[@]} == 0 )); then
      echo "stopped target=$TARGET_URL ports=none"
    else
      for key in "${!live_pids[@]}"; do
        IFS=$'\t' read -r pid_endpoint pid_capture_ports_csv <<<"$key"
        echo "running pid=${live_pids[$key]} target=$TARGET_URL ports=none endpoint=$pid_endpoint capture_ports=$pid_capture_ports_csv"
      done
    fi
    return 0
  fi

  build_process_specs "${current[@]}"
  for line in "${PROCESS_SPECS[@]}"; do
    IFS="$SPEC_SEP" read -r endpoint_host capture_ports_csv requested_ports_csv bpf_filter label <<<"$line"
    endpoint="$(format_endpoint "$endpoint_host" "$capture_ports_csv")"
    key="${endpoint}"$'\t'"${capture_ports_csv}"
    if [[ -n "${live_pids[$key]+x}" ]]; then
      echo "running pid=${live_pids[$key]} target=$TARGET_URL requested_ports=${requested_ports_csv} endpoint=${endpoint} bpf=${bpf_filter:-gor-default} mode=${label}"
    else
      echo "stopped target=$TARGET_URL requested_ports=${requested_ports_csv} endpoint=${endpoint} bpf=${bpf_filter:-gor-default} mode=${label}"
    fi
  done
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
