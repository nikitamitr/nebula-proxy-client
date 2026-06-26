#!/usr/bin/env bash
set -euo pipefail

CONF_FILE="${1:-}"
if [[ -z "${CONF_FILE}" || ! -f "${CONF_FILE}" ]]; then
  echo "Usage: $0 /path/to/nebula-proxy-enroll.conf"
  exit 1
fi

# Load config
set -a
# shellcheck disable=SC1090
source "${CONF_FILE}"
set +a

require() {
  local var="$1"
  if [[ -z "${!var:-}" ]]; then
    echo "Missing required config: ${var}"
    exit 1
  fi
}

require ENROLL_BASE_URL
require SECRET1
require SECRET2
require NEBULA_CIDR
require LIGHTHOUSE_NEBULA_IP
require UNDERLAY_MODE
require NEBULA_LISTEN_PORT
require NODE_TYPE

# Auto-detect machine identity if not provided in config
AUTO_IDENTITY="$(whoami)@$(hostname)"
NAME="${NAME:-$AUTO_IDENTITY}"
MACHINE_ID="${MACHINE_ID:-$AUTO_IDENTITY}"

if [[ "${NODE_TYPE}" != "proxy" && "${NODE_TYPE}" != "scraper" && "${NODE_TYPE}" != "proxy+ssh" && "${NODE_TYPE}" != "open" && "${NODE_TYPE}" != "open+ssh" ]]; then
  echo "Error: NODE_TYPE must be 'proxy', 'scraper', 'proxy+ssh', 'open', or 'open+ssh'"
  exit 1
fi

if [[ "${UNDERLAY_MODE}" == "public" ]]; then
  require LIGHTHOUSE_PUBLIC_HOST
  LIGHTHOUSE_UNDERLAY_ADDR="${LIGHTHOUSE_PUBLIC_HOST}:${NEBULA_LISTEN_PORT}"
else
  require LIGHTHOUSE_PRIVATE_IP
  LIGHTHOUSE_UNDERLAY_ADDR="${LIGHTHOUSE_PRIVATE_IP}:${NEBULA_LISTEN_PORT}"
fi

# Auto-detect arch
if [[ -z "${ARCH:-}" ]]; then
  m="$(uname -m)"
  case "${m}" in
    x86_64) ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    *) echo "Unsupported architecture '${m}'"; exit 1 ;;
  esac
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 is required to parse JSON responses."
  exit 1
fi

NEBULA_DIR="/etc/nebula_proxy"
NEBULA_BIN="/etc/nebula/nebula"
NEBULA_CERT_BIN="/etc/nebula/nebula-cert"
CONFIG_PATH="${NEBULA_DIR}/proxy_config.yaml"
PKI_PATH="${NEBULA_DIR}/pki"
SERVICE_PATH="/etc/systemd/system/nebula-proxy.service"

sudo mkdir -p "${NEBULA_DIR}"
sudo mkdir -p "${PKI_PATH}"

# 1) Submit enroll request to new /proxy endpoints
echo "[*] Submitting enrollment request to proxy subsystem..."

req_body="$(cat <<JSON
{
  "machine_id": "${MACHINE_ID}",
  "requested_last_octet": null,
  "requested_name": "${NAME}",
  "node_type": "${NODE_TYPE}"
}
JSON
)"

# Notice the updated /proxy/enroll path suffix
resp="$(
  curl -fsS -X POST "${ENROLL_BASE_URL}/proxy/enroll/request" \
    -H "Content-Type: application/json" \
    -H "X-Secret-1: ${SECRET1}" \
    -H "X-Secret-2: ${SECRET2}" \
    -d "${req_body}"
)"

poll_token="$(printf '%s' "${resp}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["poll_token"])')"
request_id="$(printf '%s' "${resp}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["request_id"])')"

echo "[*] Request ID: ${request_id}"

# 2) Poll for approval
echo "[*] Polling proxy router for approval assignment..."
while true; do
  status_resp="$(
    curl -fsS -X POST "${ENROLL_BASE_URL}/proxy/enroll/status" \
      -H "Content-Type: application/json" \
      -d "$(printf '{"poll_token":"%s"}' "${poll_token}")"
  )"

  status="$(printf '%s' "${status_resp}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["status"])')"
  assigned_ip="$(printf '%s' "${status_resp}" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("assigned_ip",""))')"

  echo "  - status=${status} assigned_ip=${assigned_ip}"

  if [[ "${status}" == "APPROVED" ]]; then
    break
  fi
  if [[ "${status}" == "DENIED" || "${status}" == "EXPIRED" ]]; then
    echo "[!] Enrollment ${status}. Exiting."
    exit 2
  fi

  sleep 30
done

OCTET="$(printf '%s' "${assigned_ip}" | awk -F. '{print $4}')"

# 3) Issue bundle
echo "[*] Approved. Downloading bundle..."
bundle_path="$(mktemp -t nebula_bundle.XXXXXX.tar.gz)"
tmp_extract="$(mktemp -d)"
cleanup() {
  rm -f "${bundle_path}" || true
  rm -rf "${tmp_extract}" || true
}
trap cleanup EXIT

curl -fLsS -X POST "${ENROLL_BASE_URL}/proxy/enroll/issue" \
  -H "Content-Type: application/json" \
  -H "X-Secret-1: ${SECRET1}" \
  -H "X-Secret-2: ${SECRET2}" \
  -d "$(printf '{"poll_token":"%s"}' "${poll_token}")" \
  -o "${bundle_path}"

# 4) Extract and install
tar -xzf "${bundle_path}" -C "${tmp_extract}"

sudo cp -f "${tmp_extract}/ca.crt" "${PKI_PATH}/ca.crt"
sudo cp -f "${tmp_extract}/host.crt" "${PKI_PATH}/host.crt"
sudo cp -f "${tmp_extract}/host.key" "${PKI_PATH}/host.key"
sudo chmod 0644 "${PKI_PATH}/ca.crt" "${PKI_PATH}/host.crt"
sudo chmod 0600 "${PKI_PATH}/host.key"

# 5) SAVE ASSIGNED PARAMETERS BACK TO YOUR CONF FILE
echo "[*] Saving lease details back to ${CONF_FILE}..."
# Strip out existing placeholder lines to avoid duplication
sed -i '/^ASSIGNED_NEBULA_IP=/d' "${CONF_FILE}"
sed -i '/^ASSIGNED_OCTET=/d' "${CONF_FILE}"
sed -i '/^NAME=/d' "${CONF_FILE}"
sed -i '/^MACHINE_ID=/d' "${CONF_FILE}"
# Append the real variables
echo "NAME=${NAME}" >> "${CONF_FILE}"
echo "MACHINE_ID=${MACHINE_ID}" >> "${CONF_FILE}"
echo "ASSIGNED_NEBULA_IP=${assigned_ip}" >> "${CONF_FILE}"
echo "ASSIGNED_OCTET=${OCTET}" >> "${CONF_FILE}"

# 6) Log targeted node initialize operations
if [[ "${NODE_TYPE}" == "scraper" ]]; then
  echo "[+] Initializing Scraper: 100% Locked-Down Inbound Firewall Configured."
elif [[ "${NODE_TYPE}" == "proxy+ssh" ]]; then
  require MASTER_SCRAPER_NEBULA_IP
  echo "[+] Initializing Proxy+SSH Node: Port 1080 (SOCKS) + Port 22 (SSH)."
elif [[ "${NODE_TYPE}" == "open" ]]; then
  echo "[+] Initializing Open Node: All ports open inbound."
elif [[ "${NODE_TYPE}" == "open+ssh" ]]; then
  echo "[+] Initializing Open+SSH Node: All ports open, SSH key installed."
else
  require MASTER_SCRAPER_NEBULA_IP
  echo "[+] Initializing Proxy Node: Binding port 1080 access strictly to Scraper Pool."
fi

# 7) Write Nebula proxy_config.yaml (Inbound block evaluates natively to handle spacing)
sudo tee "${CONFIG_PATH}" >/dev/null <<YAML
pki:
  ca: ${PKI_PATH}/ca.crt
  cert: ${PKI_PATH}/host.crt
  key: ${PKI_PATH}/host.key

static_host_map:
  "${LIGHTHOUSE_NEBULA_IP}": ["${LIGHTHOUSE_UNDERLAY_ADDR}"]

lighthouse:
  am_lighthouse: false
  interval: 60
  hosts:
    - "${LIGHTHOUSE_NEBULA_IP}"

listen:
  host: 0.0.0.0
  port: ${NEBULA_LISTEN_PORT}

punchy:
  punch: true

relay:
  relays:
    - "${LIGHTHOUSE_NEBULA_IP}"
  am_relay: false
  use_relays: true

tun:
  disabled: false
  dev: neb_prox
  drop_local_broadcast: false
  drop_multicast: false
  tx_queue: 500
  mtu: 1300

logging:
  level: info
  format: text

firewall:
  conntrack:
    tcp_timeout: 12m
    udp_timeout: 3m
    default_timeout: 10m

  outbound:
    - port: any
      proto: any
      host: any

  inbound:
$(if [[ "${NODE_TYPE}" == "scraper" ]]; then
    echo "    []"
  elif [[ "${NODE_TYPE}" == "proxy+ssh" ]]; then
    echo "    - port: 1080"
    echo "      proto: tcp"
    echo "      group: ScraperNodes"
    echo "    - port: 22"
    echo "      proto: tcp"
    echo "      host: any"
  elif [[ "${NODE_TYPE}" == "open" || "${NODE_TYPE}" == "open+ssh" ]]; then
    echo "    - port: any"
    echo "      proto: any"
    echo "      host: any"
  else
    echo "    - port: 1080"
    echo "      proto: tcp"
    echo "      group: ScraperNodes"
  fi)
YAML

# 7b) Install SSH server and public key for remote access (proxy+ssh / open+ssh)
if [[ "${NODE_TYPE}" == "proxy+ssh" || "${NODE_TYPE}" == "open+ssh" ]]; then
  echo "[*] Ensuring SSH server is installed..."
  if command -v apt-get >/dev/null 2>&1; then
    sudo apt-get update -qq && sudo apt-get install -y -qq openssh-server
  elif command -v yum >/dev/null 2>&1; then
    sudo yum install -y -q openssh-server
  elif command -v dnf >/dev/null 2>&1; then
    sudo dnf install -y -q openssh-server
  elif command -v pacman >/dev/null 2>&1; then
    sudo pacman -S --noconfirm openssh
  elif command -v zypper >/dev/null 2>&1; then
    sudo zypper install -y openssh
  else
    echo "[!] Could not detect package manager — please ensure openssh-server is installed manually."
  fi
  sudo systemctl enable --now sshd 2>/dev/null || sudo systemctl enable --now ssh 2>/dev/null || echo "[!] Could not start SSH service (check sshd/ssh unit name)."

  echo "[*] Installing SSH access key for remote management..."
  SSH_KEY_SRC="$(dirname "$(readlink -f "$0")")/id_proxy_access_key.pub"
  if [[ -s "${SSH_KEY_SRC}" ]]; then
    sudo mkdir -p /root/.ssh
    cat "${SSH_KEY_SRC}" | sudo tee -a /root/.ssh/authorized_keys >/dev/null
    sudo chmod 0700 /root/.ssh
    sudo chmod 0600 /root/.ssh/authorized_keys
    echo "[+] SSH public key installed for root."
  else
    echo "[!] id_proxy_access_key.pub is empty or missing -- SSH key not installed."
  fi
fi

# 8) Create systemd service
sudo tee "${SERVICE_PATH}" >/dev/null <<UNIT
[Unit]
Description=Nebula Proxy Overlay Network Mesh Service
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
ExecStart=${NEBULA_BIN} -config ${CONFIG_PATH}
Restart=always
RestartSec=3
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
UNIT

sudo systemctl daemon-reload
sudo systemctl enable --now nebula-proxy.service
sudo systemctl restart nebula-proxy.service

# 9) Install health ping timer for node monitoring
echo "[*] Setting up health ping timer..."
# Save a minimal env file so the health ping script can find secrets
PROXY_ENV_PATH="${NEBULA_DIR}/proxy_config.env"
sudo tee "${PROXY_ENV_PATH}" >/dev/null <<ENV
ENROLL_BASE_URL=${ENROLL_BASE_URL}
SECRET1=${SECRET1}
SECRET2=${SECRET2}
LIGHTHOUSE_NEBULA_IP=${LIGHTHOUSE_NEBULA_IP}
LIGHTHOUSE_API_PORT=${LIGHTHOUSE_API_PORT:-9999}
NAME=${NAME}
MACHINE_ID=${MACHINE_ID}
NODE_TYPE=${NODE_TYPE}
ASSIGNED_NEBULA_IP=${assigned_ip}
ASSIGNED_OCTET=${OCTET}
ENV

# Copy the health ping script
PING_SCRIPT_SRC="$(dirname "$(readlink -f "$0")")/proxy_health_ping.sh"
if [[ -f "${PING_SCRIPT_SRC}" ]]; then
  sudo cp -f "${PING_SCRIPT_SRC}" "${NEBULA_DIR}/proxy_health_ping.sh"
  sudo chmod 0755 "${NEBULA_DIR}/proxy_health_ping.sh"
else
  echo "[!] proxy_health_ping.sh not found next to install script — skipping health timer."
fi

# Create systemd service unit for the health ping
PING_SERVICE_PATH="/etc/systemd/system/nebula-proxy-health-ping.service"
sudo tee "${PING_SERVICE_PATH}" >/dev/null <<UNIT
[Unit]
Description=Nebula Proxy Health Ping
Wants=nebula-proxy.service
After=nebula-proxy.service

[Service]
Type=oneshot
ExecStart=${NEBULA_DIR}/proxy_health_ping.sh ${PROXY_ENV_PATH}
User=root
Group=root
UNIT

# Create systemd timer (every 5 minutes)
PING_TIMER_PATH="/etc/systemd/system/nebula-proxy-health-ping.timer"
sudo tee "${PING_TIMER_PATH}" >/dev/null <<TIMER
[Unit]
Description=Nebula Proxy Health Ping Timer (every 5 min)
Requires=nebula-proxy-health-ping.service

[Timer]
OnCalendar=*:0/5
Persistent=true

[Install]
WantedBy=timers.target
TIMER

sudo systemctl daemon-reload
sudo systemctl enable --now nebula-proxy-health-ping.timer

# 10) Install auto-renew timer (checks cert expiry daily, renews if < 7 days)
echo "[*] Setting up auto-renew timer..."
AUTO_RENEW_SCRIPT_SRC="$(dirname "$(readlink -f "$0")")/proxy_auto_renew.sh"
if [[ -f "${AUTO_RENEW_SCRIPT_SRC}" ]]; then
  sudo cp -f "${AUTO_RENEW_SCRIPT_SRC}" "${NEBULA_DIR}/proxy_auto_renew.sh"
  sudo chmod 0755 "${NEBULA_DIR}/proxy_auto_renew.sh"
  # Also copy the renew script so auto-renew can find it
  RENEW_SCRIPT_SRC="$(dirname "$(readlink -f "$0")")/renew_and_reload_nebula.sh"
  if [[ -f "${RENEW_SCRIPT_SRC}" ]]; then
    sudo cp -f "${RENEW_SCRIPT_SRC}" "${NEBULA_DIR}/renew_and_reload_nebula.sh"
    sudo chmod 0755 "${NEBULA_DIR}/renew_and_reload_nebula.sh"
  fi

  # Create systemd service unit
  RENEW_SERVICE_PATH="/etc/systemd/system/nebula-proxy-auto-renew.service"
  sudo tee "${RENEW_SERVICE_PATH}" >/dev/null <<UNIT
[Unit]
Description=Nebula Proxy Auto-Renew (check cert expiry)
Wants=nebula-proxy.service
After=nebula-proxy.service

[Service]
Type=oneshot
ExecStart=${NEBULA_DIR}/proxy_auto_renew.sh ${PROXY_ENV_PATH}
User=root
Group=root
UNIT

  # Create systemd timer (daily)
  RENEW_TIMER_PATH="/etc/systemd/system/nebula-proxy-auto-renew.timer"
  sudo tee "${RENEW_TIMER_PATH}" >/dev/null <<TIMER
[Unit]
Description=Nebula Proxy Auto-Renew Timer (daily)
Requires=nebula-proxy-auto-renew.service

[Timer]
OnCalendar=daily
Persistent=true
RandomizedDelaySec=3600

[Install]
WantedBy=timers.target
TIMER

  sudo systemctl daemon-reload
  sudo systemctl enable --now nebula-proxy-auto-renew.timer
  echo "[+] Auto-renew timer installed (runs daily, renews if < 7 days to expiry)."
else
  echo "[!] proxy_auto_renew.sh not found next to install script — skipping auto-renew timer."
fi

# 11) Install and configure Dante SOCKS5 Proxy Server (Only for non-scraper nodes)
if [[ "${NODE_TYPE}" != "scraper" ]]; then
  echo "[*] Node type is [${NODE_TYPE^^}], initializing Dante Server deployment..."
  
  # Ensure the package is installed
  if command -v apt-get >/dev/null 2>&1; then
    sudo apt-get update -qq && sudo apt-get install -y -qq dante-server
  elif command -v yum >/dev/null 2>&1; then
    sudo yum install -y -q dante-server
  elif command -v dnf >/dev/null 2>&1; then
    sudo dnf install -y -q dante-server
  else
    echo "[!] Package manager not supported for automated Dante setup — please install manually."
  fi

  # Dynamically determine the machine's primary external interface handling internet traffic
  EXT_IFACE=$(ip route | grep default | awk '{print $5}' | head -n1)
  if [[ -z "${EXT_IFACE}" ]]; then
    # Reliable fallback to pull active physical interfaces if routing table is complex
    EXT_IFACE=$(ip -o link show | awk -F': ' '{print $2}' | grep -E '^(en|wl|eth)' | head -n1 || echo "eth0")
  fi
  echo "[+] Auto-detected external internet interface: ${EXT_IFACE}"

  # Overwrite configuration with secure mesh-only definitions and syslog logging sandbox routing
  sudo tee /etc/danted.conf >/dev/null <<EOF
# Route log events straight to syslog to satisfy systemd sandboxing rules
logoutput: syslog

# Drops privileges safely after initialization
user.privileged: root
user.unprivileged: proxy

# Listen target (Explicit mesh IP binding avoids runtime timing issues)
internal: ${assigned_ip} port = 1080

# Outbound gateway
external: ${EXT_IFACE}

# Authentication
socksmethod: none
clientmethod: none

# Inbound Network Security Routing Policies
client pass {
    from: ${NEBULA_CIDR} to: 0.0.0.0/0
    log: connect disconnect error
}

client block {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    log: connect error
}

# Proxy Forwarding Data Tunnel Policies
socks pass {
    from: ${NEBULA_CIDR} to: 0.0.0.0/0
    log: connect disconnect error
}

socks block {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    log: connect error
}
EOF
  echo "[+] Dante SOCKS5 runtime configuration written to /etc/danted.conf."

  # Activate services across standard daemon unit name variations
  sudo systemctl daemon-reload
  sudo systemctl enable --now danted 2>/dev/null || sudo systemctl enable --now sockd 2>/dev/null
  sudo systemctl restart danted 2>/dev/null || sudo systemctl restart sockd 2>/dev/null
  echo "[+] Dante Proxy daemon launched successfully on port 1080."
fi

echo "[DONE] Enrolled as [${NODE_TYPE^^}]. Local configuration records updated."