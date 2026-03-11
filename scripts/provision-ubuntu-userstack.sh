#!/usr/bin/env bash
set -euo pipefail

# Script runs as root (via Packer)

USERSTACK_SRC="/tmp/capstone-userstack"
USERSTACK_DST="/opt/capstone-userstack"
BLUETEAM_AGENT_DST="/opt/capstone-blueteam-agent"
BLUETEAM_AGENT_REPO_URL="${BLUETEAM_AGENT_REPO_URL:-https://github.com/CyberSecN00bers/Blueteam-Agent-Minimal.git}"
BLUETEAM_AGENT_REPO_REF="${BLUETEAM_AGENT_REPO_REF:-main}"
export DEBIAN_FRONTEND=noninteractive

echo "[1/8] Update apt cache"
apt-get update -y >/dev/null

echo "[1.1/8] Ensure Universe repository"
apt-get install -y --no-install-recommends software-properties-common >/dev/null
if command -v add-apt-repository >/dev/null 2>&1; then
  add-apt-repository -y universe >/dev/null 2>&1 || true
  apt-get update -y >/dev/null
fi

echo "[2/8] Install base packages"
apt-get install -y --no-install-recommends \
  ca-certificates curl gnupg jq unzip npm \
  cloud-init git \
  nmap sqlmap nikto \
  openssh-server qemu-guest-agent >/dev/null

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

echo "[2.1/8] Ensure ubuntu login password"
if id ubuntu >/dev/null 2>&1; then
  echo "ubuntu:ubuntu" | chpasswd >/dev/null
  passwd -u ubuntu >/dev/null 2>&1 || true
  if [[ -d /home/ubuntu ]]; then
    chown -R ubuntu:ubuntu /home/ubuntu
  fi
else
  echo "Skipping password reset (user ubuntu not found)"
fi

echo "[2.2/8] Ensure researcher user (restricted)"
RESEARCHER_USER="researcher"
RESEARCHER_PASSWORD="${RESEARCHER_PASSWORD:-researcher}"
if ! id "${RESEARCHER_USER}" >/dev/null 2>&1; then
  useradd -m -s /bin/bash "${RESEARCHER_USER}"
fi
echo "${RESEARCHER_USER}:${RESEARCHER_PASSWORD}" | chpasswd >/dev/null
passwd -u "${RESEARCHER_USER}" >/dev/null 2>&1 || true
if getent group sudo >/dev/null 2>&1; then
  deluser "${RESEARCHER_USER}" sudo >/dev/null 2>&1 || true
fi
if getent group docker >/dev/null 2>&1; then
  gpasswd -d "${RESEARCHER_USER}" docker >/dev/null 2>&1 || true
fi

echo "[3/8] Install Docker CE"
# Docker CE (official)
DOCKER_CODENAME="$(. /etc/os-release && echo "${VERSION_CODENAME}")"
DOCKER_DISTRO="ubuntu"

apt-get remove -y docker.io docker-doc docker-compose podman-docker containerd runc >/dev/null 2>&1 || true
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/${DOCKER_DISTRO}/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${DOCKER_DISTRO} ${DOCKER_CODENAME} stable" > /etc/apt/sources.list.d/docker.list
apt-get update -y >/dev/null
apt-get install -y --no-install-recommends \
  docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >/dev/null

# Enable cloud-init units that exist
for svc in cloud-init-local.service cloud-init.service cloud-config.service cloud-final.service; do
  if systemctl list-unit-files "$svc" --no-legend 2>/dev/null | awk '{print $1}' | grep -qx "$svc"; then
    systemctl enable "$svc" >/dev/null
  else
    echo "Skipping enable $svc (unit not found)"
  fi
done

if command -v docker >/dev/null 2>&1; then
  systemctl enable --now docker >/dev/null
  # Allow 'ubuntu' user to run docker
  if id ubuntu >/dev/null 2>&1; then
    usermod -aG docker ubuntu || true
  fi
else
  echo "Skipping docker enable (docker not installed)"
fi

echo "[4/8] Install Wazuh agent"
WAZUH_AGENT_REPO_VERSION="${WAZUH_AGENT_REPO_VERSION:-4.x}"
if ! dpkg -s wazuh-agent >/dev/null 2>&1; then
  curl -fsSL https://packages.wazuh.com/key/GPG-KEY-WAZUH | gpg --dearmor -o /usr/share/keyrings/wazuh.gpg
  echo "deb [signed-by=/usr/share/keyrings/wazuh.gpg] https://packages.wazuh.com/${WAZUH_AGENT_REPO_VERSION}/apt/ stable main" > /etc/apt/sources.list.d/wazuh.list
  apt-get update -y >/dev/null
  apt-get install -y wazuh-agent >/dev/null
fi

echo "[4.1/8] Install goreplay"
GOREPLAY_VERSION="${GOREPLAY_VERSION:-1.3.3}"
GOREPLAY_TARBALL="/tmp/goreplay-${GOREPLAY_VERSION}.tar.gz"
GOREPLAY_SRC_DIR="/tmp/goreplay-${GOREPLAY_VERSION}"
apt-get update -y >/dev/null
apt-get install -y --no-install-recommends build-essential golang-go libpcap-dev >/dev/null
rm -rf "$GOREPLAY_SRC_DIR" "$GOREPLAY_TARBALL"
curl -fL -o "$GOREPLAY_TARBALL" "https://github.com/buger/goreplay/archive/refs/tags/${GOREPLAY_VERSION}.tar.gz"
tar -xzf "$GOREPLAY_TARBALL" -C /tmp
pushd "$GOREPLAY_SRC_DIR" >/dev/null
go build -o gor
install -d -m 0755 /usr/local/bin
install -m 0755 gor /usr/local/bin/gor
popd >/dev/null
rm -rf "$GOREPLAY_SRC_DIR" "$GOREPLAY_TARBALL"

echo "[5/8] Install capstone userstack files"
if [[ ! -d "$USERSTACK_SRC" ]]; then
  echo "Missing $USERSTACK_SRC" >&2
  exit 1
fi
rm -rf "$USERSTACK_DST"
mkdir -p "$USERSTACK_DST"
cp -a "$USERSTACK_SRC"/. "$USERSTACK_DST"/

mkdir -p \
  "$USERSTACK_DST/logs/nginx" \
  "$USERSTACK_DST/logs/modsecurity" \
  "$USERSTACK_DST/logs/postgres"

if [[ -f "$USERSTACK_DST/.env.example" && ! -f "$USERSTACK_DST/.env" ]]; then
  cp "$USERSTACK_DST/.env.example" "$USERSTACK_DST/.env"
fi

chmod +x "$USERSTACK_DST/scripts"/*.sh || true

install -d -m 0755 /usr/local/bin
if [[ -f "$USERSTACK_DST/scripts/addweb.sh" ]]; then
  ln -sf "$USERSTACK_DST/scripts/addweb.sh" /usr/local/bin/addweb
  chmod +x /usr/local/bin/addweb || true
fi
if [[ -f "$USERSTACK_DST/scripts/nginx-love-setup.sh" ]]; then
  ln -sf "$USERSTACK_DST/scripts/nginx-love-setup.sh" /usr/local/bin/nginx-love-setup
  chmod +x /usr/local/bin/nginx-love-setup || true
fi
if [[ -f "$USERSTACK_DST/scripts/gor-mirror-ports.sh" ]]; then
  ln -sf "$USERSTACK_DST/scripts/gor-mirror-ports.sh" /usr/local/bin/gor-mirror-ports
  ln -sf "$USERSTACK_DST/scripts/gor-mirror-ports.sh" /usr/local/bin/addport
  chmod +x /usr/local/bin/gor-mirror-ports /usr/local/bin/addport || true
fi
if [[ -f "$USERSTACK_DST/scripts/refresh-capstone-blueteam-agent.sh" ]]; then
  ln -sf "$USERSTACK_DST/scripts/refresh-capstone-blueteam-agent.sh" /usr/local/bin/refresh-blueteam-agent
  chmod +x /usr/local/bin/refresh-blueteam-agent || true
fi

echo "[5.1/8] Clone blueteam agent repository"
rm -rf "$BLUETEAM_AGENT_DST"
BLUETEAM_AGENT_GIT_ATTEMPTS="${BLUETEAM_AGENT_GIT_ATTEMPTS:-3}"
BLUETEAM_AGENT_GIT_DELAY="${BLUETEAM_AGENT_GIT_DELAY:-10}"
if ! retry "$BLUETEAM_AGENT_GIT_ATTEMPTS" "$BLUETEAM_AGENT_GIT_DELAY" \
  git clone --depth 1 --branch "$BLUETEAM_AGENT_REPO_REF" --single-branch "$BLUETEAM_AGENT_REPO_URL" "$BLUETEAM_AGENT_DST"; then
  echo "Blueteam agent git clone failed after ${BLUETEAM_AGENT_GIT_ATTEMPTS} attempts" >&2
  exit 1
fi

mkdir -p \
  "$BLUETEAM_AGENT_DST/data" \
  "$BLUETEAM_AGENT_DST/logs"

if [[ -f "$BLUETEAM_AGENT_DST/.env.example" && ! -f "$BLUETEAM_AGENT_DST/.env" ]]; then
  cp "$BLUETEAM_AGENT_DST/.env.example" "$BLUETEAM_AGENT_DST/.env"
fi

echo "[5.2/8] Configure Wazuh agent auto-enroll"
WAZUH_CONF="/var/ossec/etc/ossec.conf"
USERSTACK_WAZUH_CONF="${USERSTACK_DST}/config/ossec.conf"
if [[ -f "$USERSTACK_WAZUH_CONF" ]]; then
  install -m 0644 "$USERSTACK_WAZUH_CONF" "$WAZUH_CONF"
fi

rm -f /var/ossec/etc/client.keys >/dev/null 2>&1 || true
rm -f /usr/local/bin/wazuh-set-manager >/dev/null 2>&1 || true

if command -v systemctl >/dev/null 2>&1; then
  install -d /etc/systemd/system/wazuh-agent.service.d

  cat > /etc/systemd/system/capstone-wazuh-bootstrap.service <<EOF
[Unit]
Description=Bootstrap Wazuh agent registration
Wants=network-online.target
After=network-online.target
ConditionPathExists=${USERSTACK_DST}/scripts/bootstrap-wazuh-agent.sh

[Service]
Type=oneshot
ExecStart=${USERSTACK_DST}/scripts/bootstrap-wazuh-agent.sh

[Install]
WantedBy=multi-user.target
EOF

  cat > /etc/systemd/system/wazuh-agent.service.d/override.conf <<EOF
[Unit]
Requires=capstone-wazuh-bootstrap.service
After=capstone-wazuh-bootstrap.service
EOF

  cat > /etc/systemd/system/capstone-wazuh-login.service <<EOF
[Unit]
Description=Write Wazuh dashboard login info
Requires=capstone-wazuh-bootstrap.service
After=capstone-wazuh-bootstrap.service
ConditionPathExists=${USERSTACK_DST}/scripts/write-wazuh-login.sh
ConditionPathExists=/var/ossec/etc/client.keys

[Service]
Type=oneshot
ExecStart=${USERSTACK_DST}/scripts/write-wazuh-login.sh

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload >/dev/null
  systemctl enable capstone-wazuh-bootstrap.service >/dev/null
  systemctl enable wazuh-agent >/dev/null
  systemctl enable capstone-wazuh-login.service >/dev/null
else
  echo "Skipping Wazuh bootstrap service (systemd not available)"
fi

if command -v systemctl >/dev/null 2>&1; then
  if systemctl list-unit-files capstone-userstack-env.service --no-legend 2>/dev/null | awk '{print $1}' | grep -qx capstone-userstack-env.service; then
    systemctl disable capstone-userstack-env.service >/dev/null 2>&1 || true
  fi

  if systemctl list-unit-files capstone-userstack-refresh.service --no-legend 2>/dev/null | awk '{print $1}' | grep -qx capstone-userstack-refresh.service; then
    systemctl disable capstone-userstack-refresh.service >/dev/null 2>&1 || true
  fi

  cat > /etc/systemd/system/capstone-userstack-up.service <<EOF
[Unit]
Description=Start capstone userstack docker compose on boot
Wants=network-online.target docker.service
After=network-online.target docker.service
ConditionPathExists=${USERSTACK_DST}/scripts/start-capstone-userstack.sh
ConditionPathExists=${USERSTACK_DST}/docker-compose.yml

[Service]
Type=oneshot
Environment=CAPSTONE_STACK_DIR=${USERSTACK_DST}
ExecStart=${USERSTACK_DST}/scripts/start-capstone-userstack.sh
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload >/dev/null
  # Do not enable by default; allow user to enable after clone
else
  echo "Skipping capstone userstack refresh service (systemd not available)"
fi

echo "[6/8] Pre-pull capstone userstack images"
if command -v docker >/dev/null 2>&1; then
  if systemctl list-unit-files docker.service --no-legend 2>/dev/null | awk '{print $1}' | grep -qx docker.service; then
    systemctl start docker.service >/dev/null 2>&1 || true
  fi
  COMPOSE_PULL_ATTEMPTS="${COMPOSE_PULL_ATTEMPTS:-3}"
  COMPOSE_PULL_DELAY="${COMPOSE_PULL_DELAY:-10}"
  cd "$USERSTACK_DST"
  if ! retry "$COMPOSE_PULL_ATTEMPTS" "$COMPOSE_PULL_DELAY" docker compose pull; then
    echo "Docker compose pull failed after ${COMPOSE_PULL_ATTEMPTS} attempts" >&2
    exit 1
  fi

  echo "[6.1/8] Pre-pull blueteam agent images"
  cd "$BLUETEAM_AGENT_DST"
  if ! retry "$COMPOSE_PULL_ATTEMPTS" "$COMPOSE_PULL_DELAY" docker compose pull; then
    echo "Blueteam agent docker compose pull failed after ${COMPOSE_PULL_ATTEMPTS} attempts" >&2
    exit 1
  fi
else
  echo "Skipping docker compose pull (docker not installed)"
fi

echo "[7/8] Optional: inject SSH public key"
if [[ -n "${PACKER_SSH_PUBLIC_KEY:-}" && -d /home/ubuntu ]]; then
  install -d -m 0700 -o ubuntu -g ubuntu /home/ubuntu/.ssh
  echo "$PACKER_SSH_PUBLIC_KEY" > /home/ubuntu/.ssh/authorized_keys
  chown ubuntu:ubuntu /home/ubuntu/.ssh/authorized_keys
  chmod 0600 /home/ubuntu/.ssh/authorized_keys
fi

echo "[8/8] Reset machine-id for cloning"
truncate -s 0 /etc/machine-id
rm -f /var/lib/dbus/machine-id
ln -sf /etc/machine-id /var/lib/dbus/machine-id

echo "[DONE] Cleanup"
rm -rf /tmp/capstone-userstack /tmp/scripts || true
apt-get autoremove -y >/dev/null 2>&1 || true
apt-get clean >/dev/null 2>&1
rm -rf /var/lib/apt/lists/* || true
