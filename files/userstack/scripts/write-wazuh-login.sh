#!/usr/bin/env bash
set -euo pipefail

KEYFILE="/var/ossec/etc/client.keys"
DEFAULT_PASSWORD="${DEFAULT_PASSWORD:-CyR4ng3_123}"
OUTPUT_TARGETS=()
if [[ -d /home/ubuntu ]]; then
  OUTPUT_TARGETS+=("ubuntu:/home/ubuntu/wazuh-login.txt")
fi
if [[ -d /home/researcher ]]; then
  OUTPUT_TARGETS+=("researcher:/home/researcher/wazuh-login.txt")
fi
if [[ ${#OUTPUT_TARGETS[@]} -eq 0 ]]; then
  OUTPUT_TARGETS+=("root:/root/wazuh-login.txt")
fi

if [[ ! -s "$KEYFILE" ]]; then
  echo "[wazuh-login] Missing or empty $KEYFILE; skipping" >&2
  exit 0
fi

read -r agent_id agent_name _ < "$KEYFILE"

raw_user="${agent_name}"
username="$(printf '%s' "$raw_user" | tr -c 'A-Za-z0-9._-' '-' | sed 's/--*/-/g; s/^-//; s/-$//')"

for entry in "${OUTPUT_TARGETS[@]}"; do
  TARGET_USER="${entry%%:*}"
  OUT_FILE="${entry#*:}"

  cat > "$OUT_FILE" <<EOF
username: $username
password: $DEFAULT_PASSWORD
agent_id: $agent_id
agent_name: $agent_name
EOF

  chmod 600 "$OUT_FILE"
  if [[ "$TARGET_USER" != "root" ]]; then
    chown "$TARGET_USER:$TARGET_USER" "$OUT_FILE"
  fi
done
