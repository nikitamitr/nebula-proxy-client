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

require SECRET1
require SECRET2

# For refresh, you MUST call the server via Nebula IP (so server sees Nebula source IP).
# Prefer LIGHTHOUSE_NEBULA_IP. Fallback: ENROLL_BASE_URL if user insists, but that may route over public internet.
LIGHTHOUSE_API_PORT="${LIGHTHOUSE_API_PORT:-9999}"
if [[ -n "${LIGHTHOUSE_NEBULA_IP:-}" ]]; then
  ENROLLER_URL="http://${LIGHTHOUSE_NEBULA_IP}:${LIGHTHOUSE_API_PORT}"
else
  require ENROLL_BASE_URL
  ENROLLER_URL="${ENROLL_BASE_URL}"
fi

NEBULA_DIR="/etc/nebula_proxy"
PKI_DIR="${NEBULA_DIR}/pki"
CONFIG_PATH="${NEBULA_DIR}/proxy_config.yaml"

if [[ ! -d "${NEBULA_DIR}" || ! -f "${CONFIG_PATH}" ]]; then
  echo "[!] ${NEBULA_DIR} and/or ${CONFIG_PATH} not found."
  echo "    This machine does not look like it has Nebula Proxy installed/configured."
  exit 2
fi

sudo mkdir -p "${PKI_DIR}"

HEALTH_URL="${ENROLLER_URL}/healthz"
REFRESH_URL="${ENROLLER_URL}/proxy/cert/refresh"

echo "[*] Checking enroller reachability: ${HEALTH_URL}"
set +e
health_out="$(curl -sS -m 5 -i "${HEALTH_URL}" 2>&1)"
health_rc=$?
set -e
if [[ ${health_rc} -ne 0 ]]; then
  echo "[!] Cannot reach enroller at ${HEALTH_URL}"
  echo "    curl output:"
  echo "${health_out}"
  echo
  echo "Most common causes:"
  echo "  - Not connected to Nebula (you must reach the enroller via Nebula)."
  echo "  - Port ${LIGHTHOUSE_API_PORT} not allowed over Nebula to the lighthouse."
  exit 3
fi
echo "[+] Enroller reachable."

echo
echo "[*] Requesting refreshed cert bundle from ${REFRESH_URL} ..."
bundle_path="$(mktemp -t nebula_refresh.XXXXXX.tar.gz)"
tmp_extract="$(mktemp -d)"
cleanup() {
  rm -f "${bundle_path}" || true
  rm -rf "${tmp_extract}" || true
}
trap cleanup EXIT

set +e
curl_out="$(
  curl -sS -f -X POST "${REFRESH_URL}" \
    -H "X-Secret-1: ${SECRET1}" \
    -H "X-Secret-2: ${SECRET2}" \
    -o "${bundle_path}" 2>&1
)"
rc=$?
set -e

if [[ $rc -ne 0 ]]; then
  echo "[!] Refresh request failed."
  echo "    curl output:"
  echo "${curl_out}"
  echo
  echo "Common causes:"
  echo "  - Server rejected refresh because request did not come from Nebula IP (403)."
  echo "  - Wrong secrets (401)."
  echo "  - Enroller internal error (500)."
  exit 4
fi

echo "[+] Bundle downloaded to ${bundle_path}"

tar -xzf "${bundle_path}" -C "${tmp_extract}"

# Expected in bundle:
# - ca.crt
# - host.crt
# - host.key
# optionally: <octet>.crt / <octet>.key
if [[ ! -f "${tmp_extract}/ca.crt" || ! -f "${tmp_extract}/host.crt" || ! -f "${tmp_extract}/host.key" ]]; then
  echo "[!] Bundle missing required files (ca.crt/host.crt/host.key)."
  echo "    Files present:"
  ls -la "${tmp_extract}"
  exit 5
fi

octet_file="$(
  ls -1 "${tmp_extract}" 2>/dev/null | sed -n 's/^\([0-9][0-9]*\)\.crt$/\1/p' | head -n 1 || true
)"

echo
echo "[*] Backing up existing PKI (if any) ..."
backup_dir="$(mktemp -d -t nebula_pki_backup.XXXXXX)"
if [[ -d "${PKI_DIR}" ]]; then
  # Copy current pki content for rollback
  sudo cp -a "${PKI_DIR}/." "${backup_dir}/" 2>/dev/null || true
fi
echo "[+] Backup at: ${backup_dir}"

echo
echo "[*] Installing refreshed certs into ${PKI_DIR} ..."
sudo cp -f "${tmp_extract}/ca.crt"   "${PKI_DIR}/ca.crt"
sudo cp -f "${tmp_extract}/host.crt" "${PKI_DIR}/host.crt"
sudo cp -f "${tmp_extract}/host.key" "${PKI_DIR}/host.key"
sudo chmod 0644 "${PKI_DIR}/ca.crt" "${PKI_DIR}/host.crt"
sudo chmod 0600 "${PKI_DIR}/host.key"

if [[ -n "${octet_file}" && -f "${tmp_extract}/${octet_file}.key" ]]; then
  sudo cp -f "${tmp_extract}/${octet_file}.crt" "${PKI_DIR}/${octet_file}.crt"
  sudo cp -f "${tmp_extract}/${octet_file}.key" "${PKI_DIR}/${octet_file}.key"
  sudo chmod 0644 "${PKI_DIR}/${octet_file}.crt"
  sudo chmod 0600 "${PKI_DIR}/${octet_file}.key"
  echo "[+] Also installed ${octet_file}.crt/.key"
fi

echo
echo "[*] Reloading/restarting Nebula Proxy ..."
if systemctl list-units --type=service --all 2>/dev/null | grep -q '^nebula-proxy\.service'; then
  sudo systemctl restart nebula-proxy.service
  echo "[+] nebula-proxy.service restarted."
else
  echo "[!] nebula-proxy.service not found. Attempting to locate any nebula*.service units ..."
  mapfile -t neb_units < <(systemctl list-units --type=service --all 2>/dev/null | awk '{print $1}' | grep -E '^nebula(-proxy)?(@.*)?\.service$' || true)
  if [[ ${#neb_units[@]} -gt 0 ]]; then
    echo "    Restarting: ${neb_units[*]}"
    for u in "${neb_units[@]}"; do
      sudo systemctl restart "${u}" || true
    done
    echo "[+] Restart attempted."
  else
    echo "    No systemd unit found. You may be running nebula manually."
    echo "    Start example:"
    echo "      sudo ${NEBULA_BIN:-/etc/nebula/nebula} -config ${CONFIG_PATH}"
  fi
fi

echo
echo "[*] Verifying nebula proxy interface ..."
if command -v ip >/dev/null 2>&1; then
  ip -4 addr show dev neb_prox 2>/dev/null || true
fi

echo
echo "[DONE] Certificate refresh completed."
echo "       Backup of previous PKI: ${backup_dir}"
