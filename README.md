# Capstone Userstack (nginx-love)

This repo builds a VM template that ships a pre-pulled nginx-love stack and a small set of helper scripts to configure it on first boot.

**What is included**
- Docker Compose stack at `/opt/capstone-userstack` (backend, frontend, postgres).
- Helper scripts:
  - `nginx-love-setup` (configure domain + admin password, then start stack).
  - `addweb` (create a new domain upstream via API).
  - `addport` / `gor-mirror-ports` (start or update GoReplay port mirroring to `http://127.0.0.1:60085`).
  - `start-capstone-userstack.sh` (start compose on boot when service is enabled).

DVWA has been removed from the stack.

## Quick Start (Clone VM)

1. Boot the VM.
2. Run setup once:
   ```bash
   sudo nginx-love-setup <public_domain> <new_admin_password>
   ```
   Example:
   ```bash
   sudo nginx-love-setup modsec.example.com Change123!
   ```
3. Access the UI at `http://<public_domain>`.

## What `nginx-love-setup` Does

The script runs in this order:
- Ensures `/opt/capstone-userstack/.env` exists (copied from `.env.example`).
- Writes:
  - `CORS_ORIGIN="http://localhost:8080,http://localhost:5173,http://<public_domain>"`
  - `VITE_API_URL=http://<public_domain>/api`
- Starts `docker compose up -d --build` with retries.
- Waits for `http://127.0.0.1:3001/api/health` to be ready.
- Runs `bootstrap-nginx_love.sh` to change the admin password and disable ModSecurity rules.
- If password change succeeds, it **syncs** `.env`:
  - `ADMIN_PASSWORD=<new_admin_password>`
  - `NEW_ADMIN_PASSWORD=<new_admin_password>`
- Enables `capstone-userstack-up.service` so the stack auto-starts on reboot.

### Tuning timeouts/retries
You can override these if the VM is slow:
- `COMPOSE_RETRY_ATTEMPTS` (default `3`)
- `COMPOSE_RETRY_DELAY` (default `10`)
- `DOCKER_WAIT_TIMEOUT` (default `60`)
- `API_WAIT_TIMEOUT` (default `180`)
- `API_WAIT_INTERVAL` (default `3`)
- `BOOTSTRAP_RETRY_ATTEMPTS` (default `3`)
- `BOOTSTRAP_RETRY_DELAY` (default `5`)

Example:
```bash
sudo COMPOSE_RETRY_ATTEMPTS=5 API_WAIT_TIMEOUT=300 nginx-love-setup modsec.example.com Change123!
```

## Password Rules (nginx-love)

The admin password must satisfy:
- At least **8 characters**.
- At least **1 uppercase**, **1 lowercase**, **1 number**, and **1 special** character.
- Recommended: use ASCII characters only (avoid accents) for compatibility.

Example: `Change123!`

## addweb (create domain upstream)

Usage:
```bash
addweb <domain> <port>
```
Or:
```bash
addweb <domain>:<port>
```

Notes:
- `addweb` reads `ADMIN_PASSWORD` / `NEW_ADMIN_PASSWORD` from `/opt/capstone-userstack/.env`.
- Run `sudo nginx-love-setup` first to ensure credentials are valid.

## addport / gor-mirror-ports (GoReplay helper)

Usage:
```bash
sudo addport 8080 3001
```

This merges the provided ports into the saved list, restarts `gor` in the background, and forwards captured HTTP traffic to `http://127.0.0.1:60085`.

Other commands:
```bash
sudo addport 8081
sudo addport start 80 8080 3000
sudo addport remove 3001
sudo addport status
sudo addport stop
```

Notes:
- Default capture scope is loopback only: `GOR_LISTEN_HOST=localhost`.
- To capture traffic from a real NIC instead, use `GOR_LISTEN_HOST=` with `GOR_RAW_INTERFACE=<iface>`, for example `sudo GOR_LISTEN_HOST= GOR_RAW_INTERFACE=eth0 addport 80 8080`.
- Override `GOR_TARGET_URL`, `GOR_LISTEN_HOST`, or `GOR_RAW_INTERFACE` if you need a different replay target or capture scope.
- The helper only forwards traffic. Nothing in the current stack needs to listen on port `60085` yet.

## Auto-start on Boot

The build creates a systemd unit:
- `capstone-userstack-up.service`

This unit runs:
- `/opt/capstone-userstack/scripts/start-capstone-userstack.sh` → `docker compose up -d`
