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
require NAME
require MACHINE_ID
require NEBULA_CIDR
require LIGHTHOUSE_NEBULA_IP
require UNDERLAY_MODE
require NEBULA_LISTEN_PORT
require NODE_TYPE

if [[ "${NODE_TYPE}" != "proxy" && "${NODE_TYPE}" != "scraper" ]]; then
  echo "Error: NODE_TYPE must be 'proxy' or 'scraper'"
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
# Append the real variables
echo "ASSIGNED_NEBULA_IP=${assigned_ip}" >> "${CONF_FILE}"
echo "ASSIGNED_OCTET=${OCTET}" >> "${CONF_FILE}"

# 6) Build Isolated Firewalls
FIREWALL_INBOUND_STANZA=""
if [[ "${NODE_TYPE}" == "scraper" ]]; then
  FIREWALL_INBOUND_STANZA="inbound: []"
  echo "[+] Initializing Scraper: 100% Locked-Down Inbound Firewall Configured."
else
  require MASTER_SCRAPER_NEBULA_IP
  FIREWALL_INBOUND_STANZA=$(cat <<YAML
  inbound:
    - port: 1080
      proto: tcp
      host: ${MASTER_SCRAPER_NEBULA_IP}
YAML
)
  echo "[+] Initializing Proxy Node: Binding port 1080 access strictly to Scraper Pool."
fi

# 7) Write Nebula proxy_config.yaml
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
  dev: nebula_proxies
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

  ${FIREWALL_INBOUND_STANZA}
YAML

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

echo "[DONE] Enrolled as [${NODE_TYPE^^}]. Local configuration records updated."
