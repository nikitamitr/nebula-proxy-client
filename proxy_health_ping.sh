#!/usr/bin/env bash
# Periodic health ping for Nebula Proxy mesh nodes.
# Called by systemd timer every 5 minutes.
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

ENROLL_BASE_URL="${ENROLL_BASE_URL:-}"
SECRET1="${SECRET1:-}"
SECRET2="${SECRET2:-}"

if [[ -z "${ENROLL_BASE_URL}" || -z "${SECRET1}" || -z "${SECRET2}" ]]; then
  echo "[!] Missing ENROLL_BASE_URL, SECRET1, or SECRET2 in config."
  exit 1
fi

# Prefer calling over Nebula if LIGHTHOUSE_NEBULA_IP is available
LIGHTHOUSE_API_PORT="${LIGHTHOUSE_API_PORT:-9999}"
if [[ -n "${LIGHTHOUSE_NEBULA_IP:-}" ]]; then
  PING_URL="http://${LIGHTHOUSE_NEBULA_IP}:${LIGHTHOUSE_API_PORT}/proxy/health/ping"
else
  PING_URL="${ENROLL_BASE_URL}/proxy/health/ping"
fi

ASSIGNED_NEBULA_IP="${ASSIGNED_NEBULA_IP:-}"
PING_BODY="{}"
if [[ -n "${ASSIGNED_NEBULA_IP}" ]]; then
  PING_BODY="{\"nebula_ip\": \"${ASSIGNED_NEBULA_IP}\"}"
fi

curl -fsS -X POST "${PING_URL}" \
  -H "X-Secret-1: ${SECRET1}" \
  -H "X-Secret-2: ${SECRET2}" \
  -H "Content-Type: application/json" \
  -d "${PING_BODY}" >/dev/null 2>&1 || echo "[!] Health ping failed"
