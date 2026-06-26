#!/usr/bin/env bash
set -euo pipefail

CONF_FILE="${1:-}"
if [[ -z "${CONF_FILE}" || ! -f "${CONF_FILE}" ]]; then
  echo "Usage: $0 /path/to/nebula-enroll.conf"
  exit 1
fi

# ----------------------------
# Load config (simple key=value)
# ----------------------------
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

require LIGHTHOUSE_NEBULA_IP
require SECRET1
require SECRET2

LIGHTHOUSE_API_PORT="${LIGHTHOUSE_API_PORT:-9999}"

NEBULA_DIR="/etc/nebula_proxy"
PKI_DIR="${NEBULA_DIR}/pki"

# ----------------------------
# Determine last octet
# Priority:
#   1) REQUESTED_LAST_OCTET from conf (if set)
#   2) infer from /etc/nebula_proxy/pki/<octet>.crt
#   3) infer from assigned IP of nebula proxy interface (neb_prox)
# ----------------------------
OCTET="${REQUESTED_LAST_OCTET:-}"

if [[ -z "${OCTET}" ]]; then
  if [[ -d "${PKI_DIR}" ]]; then
    inferred="$(
      ls -1 "${PKI_DIR}" 2>/dev/null \
        | sed -n 's/^\([0-9][0-9]*\)\.crt$/\1/p' \
        | head -n 1 || true
    )"
    if [[ -n "${inferred}" ]]; then
      OCTET="${inferred}"
    fi
  fi
fi

if [[ -z "${OCTET}" ]]; then
  if command -v ip >/dev/null 2>&1; then
    neb_ip="$(ip -4 addr show dev neb_prox 2>/dev/null | awk '/inet /{print $2}' | head -n 1 | cut -d/ -f1 || true)"
    if [[ -n "${neb_ip}" ]]; then
      OCTET="$(printf '%s' "${neb_ip}" | awk -F. '{print $4}' || true)"
    fi
  fi
fi

if [[ -z "${OCTET}" ]]; then
  echo "[!] Could not determine OCTET."
  echo "    Set REQUESTED_LAST_OCTET in your conf, or ensure ${PKI_DIR}/<octet>.crt exists,"
  echo "    or ensure nebula interface 'nebula1' is up with an IP."
  exit 2
fi

if ! [[ "${OCTET}" =~ ^[0-9]+$ ]]; then
  echo "[!] OCTET is not numeric: ${OCTET}"
  exit 2
fi

if [[ "${OCTET}" -lt 2 || "${OCTET}" -gt 254 ]]; then
  echo "[!] OCTET out of expected range (2-254): ${OCTET}"
  exit 2
fi

DELETE_URL="http://${LIGHTHOUSE_NEBULA_IP}:${LIGHTHOUSE_API_PORT}/admin/delete/ip/${OCTET}"
HEALTH_URL="http://${LIGHTHOUSE_NEBULA_IP}:${LIGHTHOUSE_API_PORT}/healthz"

echo "[*] Verifying lighthouse API reachable over Nebula: ${HEALTH_URL}"
set +e
health_out="$(curl -sS -m 5 -i "${HEALTH_URL}" 2>&1)"
health_rc=$?
set -e
if [[ ${health_rc} -ne 0 ]]; then
  echo "[!] Could not reach lighthouse API over Nebula."
  echo "    curl output:"
  echo "${health_out}"
  echo
  echo "Continuing anyway (will still stop local nebula + remove files)."
else
  echo "[+] Lighthouse API reachable."
fi

echo
echo "[*] Attempting server-side delete for octet=${OCTET} via:"
echo "    ${DELETE_URL}"

set +e
delete_out="$(
  curl -sS -f -X POST "${DELETE_URL}" \
    -H "X-Secret-1: ${SECRET1}" \
    -H "X-Secret-2: ${SECRET2}" \
    -H "Content-Type: application/json" 2>&1
)"
delete_rc=$?
set -e

if [[ ${delete_rc} -ne 0 ]]; then
  echo "[!] Server delete call failed (continuing with local cleanup)."
  echo "    curl output:"
  echo "${delete_out}"
else
  echo "[+] Server delete response:"
  echo "${delete_out}"
fi

echo
echo "[*] Stopping Nebula Proxy services (even if unit files are missing) ..."

# Stop any running units that match nebula* (including nebula-proxy.service)
mapfile -t neb_units < <(systemctl list-units --type=service --all 2>/dev/null | awk '{print $1}' | grep -E '^nebula(-proxy)?(@.*)?\.service$' || true)
for u in "${neb_units[@]:-}"; do
  [[ -z "${u}" ]] && continue
  echo "    - stopping ${u}"
  sudo systemctl stop "${u}" 2>/dev/null || true
done

# Disable any installed unit files that match nebula*
mapfile -t neb_unit_files < <(systemctl list-unit-files 2>/dev/null | awk '{print $1}' | grep -E '^nebula(-proxy)?(@.*)?\.service$' || true)
for u in "${neb_unit_files[@]:-}"; do
  [[ -z "${u}" ]] && continue
  echo "    - disabling ${u}"
  sudo systemctl disable "${u}" 2>/dev/null || true
done

echo
echo "[*] Killing any remaining nebula processes ..."
# Broad match: kill any process whose command contains '/nebula ' or ends with '/nebula'
sudo pkill -f '(^|/)(nebula)(\s|$)' 2>/dev/null || true
sudo pkill -f 'nebula -config' 2>/dev/null || true

echo "[*] Waiting briefly for processes to exit ..."
sleep 1

if ps aux | grep -i '[n]ebula' >/dev/null 2>&1; then
  echo "[!] Nebula process still appears to be running. Showing matches:"
  ps aux | grep -i '[n]ebula' || true
  echo
  echo "[*] Attempting SIGKILL on remaining nebula processes ..."
  # Extract PIDs from any remaining matches and kill -9
  pids="$(ps aux | grep -i '[n]ebula' | awk '{print $2}' | tr '\n' ' ' || true)"
  if [[ -n "${pids}" ]]; then
    # shellcheck disable=SC2086
    sudo kill -9 ${pids} 2>/dev/null || true
  fi
fi

echo
echo "[*] Removing neb_prox interface if present ..."
if command -v ip >/dev/null 2>&1; then
  sudo ip link delete neb_prox 2>/dev/null || sudo ip link set neb_prox down 2>/dev/null || true
fi

echo
echo "[*] Stopping and removing health ping & auto-renew timers ..."
sudo systemctl stop nebula-proxy-health-ping.timer 2>/dev/null || true
sudo systemctl disable nebula-proxy-health-ping.timer 2>/dev/null || true
sudo rm -f /etc/systemd/system/nebula-proxy-health-ping.timer 2>/dev/null || true
sudo rm -f /etc/systemd/system/nebula-proxy-health-ping.service 2>/dev/null || true
sudo systemctl stop nebula-proxy-auto-renew.timer 2>/dev/null || true
sudo systemctl disable nebula-proxy-auto-renew.timer 2>/dev/null || true
sudo rm -f /etc/systemd/system/nebula-proxy-auto-renew.timer 2>/dev/null || true
sudo rm -f /etc/systemd/system/nebula-proxy-auto-renew.service 2>/dev/null || true

echo
echo "[*] Removing systemd unit files (common locations) ..."
# Remove explicit nebula-proxy.service if present
sudo systemctl stop nebula-proxy.service 2>/dev/null || true
sudo systemctl disable nebula-proxy.service 2>/dev/null || true
sudo rm -f /etc/systemd/system/nebula-proxy.service 2>/dev/null || true
# Also remove any legacy nebula.service if present
sudo rm -f /etc/systemd/system/nebula.service 2>/dev/null || true
# Also remove any nebula@.service templates if present
sudo rm -f /etc/systemd/system/nebula@.service 2>/dev/null || true
# Reload systemd state
sudo systemctl daemon-reload 2>/dev/null || true
sudo systemctl reset-failed 2>/dev/null || true

echo
echo "[*] Removing ${NEBULA_DIR} ..."
if [[ -d "${NEBULA_DIR}" ]]; then
  sudo rm -rf "${NEBULA_DIR}"
  echo "[+] Removed ${NEBULA_DIR}"
else
  echo "    (${NEBULA_DIR} does not exist; nothing to remove)"
fi

echo
echo "[DONE] Cleanup complete."
echo "       - Attempted server delete for octet=${OCTET} via ${DELETE_URL}"
echo "       - Stopped/disabled nebula-proxy services (including not-found running units)"
echo "       - Stopped/disabled health ping & auto-renew timers"
echo "       - Killed remaining nebula processes (if any)"
echo "       - Removed neb_prox interface (if present)"
echo "       - Local Nebula Proxy removed: ${NEBULA_DIR}"

