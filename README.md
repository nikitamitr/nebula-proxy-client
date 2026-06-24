# Nebula Enroll Client Scripts

This directory contains **client-side scripts** to:

1. **Enroll** a machine with the Nebula enrollment server, install Nebula locally, and start it as a systemd service.
2. **Refresh** (renew) the machine certificate on-demand (3‑month certs) and restart Nebula to load new credentials.
3. **Unenroll + remove** Nebula locally and delete the server-side IP allocation/records.

All scripts are run as:

```bash
./<script>.sh ./nebula-enroll.conf
```

---

## Contents

- `nebula-enroll.conf` — per-machine configuration (secrets, IDs, lighthouse settings).
- `install_and_enroll_nebula.sh` — install Nebula (if missing), enroll, download bundle, write `/etc/nebula/config.yaml`, create `nebula.service`, start Nebula.
- `renew_and_reload_nebula.sh` — call the server refresh route, install updated certs to `/etc/nebula/pki`, restart Nebula.
- `unenroll_and_remove_nebula.sh` — delete server-side octet/IP record, stop/kill Nebula, delete `nebula1` interface, remove `/etc/nebula`, remove unit files.

---

## 1) Configuration: `nebula-enroll.conf`

This file is sourced by the scripts (`source ./nebula-enroll.conf`). It is simple `KEY=value` format.

Example (edit as needed):

```bash
# Enrollment server (FastAPI)
ENROLL_BASE_URL=http://lighthouse1.njpresearch.com:9999

# Two shared secrets expected by the FastAPI server
SECRET1=REPLACE_ME_SECRET_1
SECRET2=REPLACE_ME_SECRET_2

# Node identity
NAME=Desktop111
MACHINE_ID=Desktop111

# Desired last octet (set empty for auto)
REQUESTED_LAST_OCTET=111

# Nebula network details
NEBULA_CIDR=10.43.0.0/16
LIGHTHOUSE_NEBULA_IP=10.43.0.1

# Underlay preference for contacting lighthouse
# - public: use LIGHTHOUSE_PUBLIC_HOST (DNS)
# - private: use LIGHTHOUSE_PRIVATE_IP (useful if running inside same VPC/EC2)
UNDERLAY_MODE=public
LIGHTHOUSE_PUBLIC_HOST=lighthouse1.njpresearch.com
LIGHTHOUSE_PRIVATE_IP=172.31.8.94

# Nebula listen port (default 4242)
NEBULA_LISTEN_PORT=4242

# Architecture override (leave empty to auto-detect)
# Valid: amd64, arm64
ARCH=amd64
```

### Security note
This file contains shared secrets. Recommended:

```bash
chmod 600 nebula-enroll.conf
```

---

## 2) `install_and_enroll_nebula.sh` (first-time install + enroll)

### What it does
1. Installs Nebula binaries into `/etc/nebula/` **if missing**:
   - `/etc/nebula/nebula`
   - `/etc/nebula/nebula-cert`
2. Calls the enrollment API:
   - `POST /enroll/request` (requires `X-Secret-1` and `X-Secret-2`)
   - Polls `POST /enroll/status` every 30 seconds until status is `APPROVED`
   - Downloads the cert bundle via `POST /enroll/issue`
3. Extracts the bundle and installs certs to `/etc/nebula/pki`:
   - `ca.crt`
   - `host.crt`
   - `host.key`
   - also keeps `<octet>.crt` + `<octet>.key` (example: `111.crt` / `111.key`)
4. Writes `/etc/nebula/config.yaml` (static host map + lighthouse config).
5. Writes `/etc/systemd/system/nebula.service`, enables and starts it.

### Run
```bash
./install_and_enroll_nebula.sh ./nebula-enroll.conf
```

### Verify
```bash
ip -4 addr show dev nebula1
systemctl status nebula.service --no-pager
```

---

## 3) `renew_and_reload_nebula.sh` (refresh/renew cert + restart)

### Server-side behavior assumed
- The refresh endpoint is called as:
  - `POST /cert/refresh`
- It is typically restricted to requests **originating from Nebula IPs** (server checks source IP in `NEBULA_CIDR`).
- It always returns a **new 3-month certificate bundle** for the caller’s Nebula IP.

### What it does
1. Connects to the enroller **via Nebula IP** (preferred):
   - `http://$LIGHTHOUSE_NEBULA_IP:9999`
2. Checks `GET /healthz`.
3. Requests a bundle via `POST /cert/refresh` (sends secrets in headers).
4. Backs up current `/etc/nebula/pki` to a temp directory.
5. Installs new:
   - `ca.crt`, `host.crt`, `host.key`
   - plus `<octet>.crt/.key` if included in the bundle
6. Restarts Nebula (tries `nebula.service` and any matching `nebula*.service` unit).

### Run
```bash
./renew_and_reload_nebula.sh ./nebula-enroll.conf
```

### Verify
```bash
systemctl status nebula.service --no-pager
ip -4 addr show dev nebula1
```

### Common failures
- **403 Forbidden**: you are not reaching the server from a Nebula IP (not connected to Nebula, wrong URL, wrong routing).
- **401 Unauthorized**: secrets are wrong.
- **500**: server-side signing failure; check server logs.

---

## 4) `unenroll_and_remove_nebula.sh` (server delete + full local wipe)

### What it does
1. Determines the assigned last octet (priority order):
   - `REQUESTED_LAST_OCTET` in conf
   - or `/etc/nebula/pki/<octet>.crt`
   - or IP on `nebula1` interface
2. Calls server-side delete (best effort) **over Nebula**:
   - `POST http://$LIGHTHOUSE_NEBULA_IP:9999/admin/delete/ip/$OCTET`
   - Requires secrets
   - Requires Nebula source IP (server restriction)
3. Stops and disables any `nebula*.service` units (even “not-found active running” states).
4. Kills any remaining Nebula processes (`pkill`, then SIGKILL fallback).
5. Deletes the `nebula1` interface if still present.
6. Removes systemd unit files and reloads systemd.
7. Removes `/etc/nebula` completely.

### Run
```bash
./unenroll_and_remove_nebula.sh ./nebula-enroll.conf
```

### Verify cleanup
```bash
ps aux | grep -i '[n]ebula' || true
ip link show nebula1 2>/dev/null || echo "nebula1 interface removed"
ls -ld /etc/nebula 2>/dev/null || echo "/etc/nebula removed"
```

---

## API endpoints used (reference)

### Enrollment flow
- `POST /enroll/request` (requires `X-Secret-1`, `X-Secret-2`)
- `POST /enroll/status` (poll token in JSON body)
- `POST /enroll/issue` (requires `X-Secret-1`, `X-Secret-2`)

### Refresh flow
- `POST /cert/refresh` (requires `X-Secret-1`, `X-Secret-2`; typically Nebula-source only)

### Admin delete
- `POST /admin/delete/ip/{octet}` (requires `X-Secret-1`, `X-Secret-2`; Nebula-source only)

Optional diagnostics:
- `GET /healthz`
- `GET /whoami` (Nebula-source only)

---

## Requirements on the client machine

- `bash`
- `curl`
- `sudo`
- `python3` (used in `install_and_enroll_nebula.sh` to parse JSON)
- `systemd` (for running `nebula.service`)
- `ip` (recommended, from `iproute2`)

---

## Troubleshooting quick checks

### Can I reach the enroller over Nebula?
```bash
curl -v http://10.43.0.1:9999/healthz
curl -v http://10.43.0.1:9999/whoami
```

### Is Nebula running?
```bash
systemctl status nebula.service --no-pager
ps aux | grep -i '[n]ebula'
ip -4 addr show dev nebula1
```

### Refresh fails with 403
Most likely: you are not making the request from a Nebula IP.

- Ensure Nebula is up and `nebula1` has `10.43.*` assigned.
- Ensure the refresh script is targeting `http://$LIGHTHOUSE_NEBULA_IP:9999` (Nebula overlay), not the public DNS.

---

## Notes / assumptions

- The server is configured to issue **3-month certificates** (or the server stores `issued_at_utc` as “now” and `expires_at_utc` as “now + 3 months”).
- The install script writes a permissive firewall config in `config.yaml` (allow all inbound/outbound).
- The uninstall script is intentionally aggressive in cleaning up “stuck” Nebula processes and interfaces.
# nebula-client



#quick commands
chmod +x install_and_enroll_nebula.sh
./install_and_enroll_nebula.sh ./nebula-enroll.conf


chmod +x renew_and_reload_nebula.sh
./renew_and_reload_nebula.sh ./nebula-enroll.conf

chmod +x unenroll_and_remove_nebula.sh
./unenroll_and_remove_nebula.sh ./nebula-enroll.conf


# nebula-proxy-client
