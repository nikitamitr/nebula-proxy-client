#!/usr/bin/env bash
# Auto-renew check for Nebula Proxy certificates.
# Called by systemd timer daily. If the host certificate expires within 7 days,
# automatically runs the renew script.
set -euo pipefail

CONF_FILE="${1:-/etc/nebula_proxy/proxy_config.env}"
if [[ ! -f "${CONF_FILE}" ]]; then
  echo "[!] Config not found: ${CONF_FILE}"
  exit 1
fi

# Load config
set -a
# shellcheck disable=SC1090
source "${CONF_FILE}"
set +a

NEBULA_DIR="/etc/nebula_proxy"
PKI_DIR="${NEBULA_DIR}/pki"
HOST_CRT="${PKI_DIR}/host.crt"
NEBULA_CERT_BIN="${NEBULA_CERT_BIN:-/etc/nebula/nebula-cert}"

if [[ ! -f "${HOST_CRT}" ]]; then
  echo "[!] Host certificate not found at ${HOST_CRT}"
  exit 2
fi

if [[ ! -x "${NEBULA_CERT_BIN}" ]]; then
  echo "[!] nebula-cert not found at ${NEBULA_CERT_BIN}"
  exit 2
fi

# Parse certificate expiry
CERT_JSON="$("${NEBULA_CERT_BIN}" print -json -path "${HOST_CRT}" 2>/dev/null)" || {
  echo "[!] Failed to parse certificate"
  exit 3
}

NOT_AFTER="$(printf '%s' "${CERT_JSON}" | python3 -c '
import json, sys
data = json.load(sys.stdin)
# Handle both list and object output formats
if isinstance(data, list):
    data = data[0]
print(data.get("NotAfter", ""))
')"

if [[ -z "${NOT_AFTER}" || "${NOT_AFTER}" == "None" ]]; then
  echo "[!] Could not determine certificate expiry"
  exit 3
fi

# Calculate days until expiry
NOW_EPOCH="$(date +%s)"
EXPIRY_EPOCH="$(date -d "${NOT_AFTER}" +%s 2>/dev/null)" || {
  echo "[!] Failed to parse expiry date: ${NOT_AFTER}"
  exit 3
}

DAYS_LEFT=$(( (EXPIRY_EPOCH - NOW_EPOCH) / 86400 ))

echo "[*] Certificate expires: ${NOT_AFTER} (${DAYS_LEFT} days left)"

if [[ ${DAYS_LEFT} -le 0 ]]; then
  echo "[!] Certificate has already expired!"
  exit 4
fi

if [[ ${DAYS_LEFT} -ge 7 ]]; then
  echo "[+] Certificate is still valid for ${DAYS_LEFT} days — no renewal needed."
  exit 0
fi

echo "[*] Certificate expires in ${DAYS_LEFT} days (< 7) — triggering auto-renewal..."

RENEW_SCRIPT="$(dirname "$(readlink -f "$0")")/renew_and_reload_nebula.sh"
if [[ ! -f "${RENEW_SCRIPT}" ]]; then
  RENEW_SCRIPT="${NEBULA_DIR}/renew_and_reload_nebula.sh"
fi

if [[ ! -f "${RENEW_SCRIPT}" ]]; then
  echo "[!] renew_and_reload_nebula.sh not found — cannot auto-renew"
  exit 5
fi

# Pass the env file directly — it has all vars the renew script needs (SECRET1/2, etc.)
bash "${RENEW_SCRIPT}" "${CONF_FILE}"
echo "[DONE] Auto-renewal completed."
