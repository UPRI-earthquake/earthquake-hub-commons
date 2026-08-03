# earthquake-hub-commons
This repository integrates all the essential programs necessary for hosting a citizen science network of ground motion sensors (such as but not limited to raspberryshakes). It enables data transmission, archiving, and allows feeding the network data to earthquake detection software(such as but not limited to SeisComP).

Admin operational references:

- [Admin backend dep-test runbook](docs/admin-backend/runbook.md)
- [Admin backend production read-only runbook](docs/admin-backend/production-read-only-runbook.md)
- [Actual-server Admin Console deployment test](docs/admin-backend/deployment-server-test.md)
- [Admin deployment environment reference](docs/admin-backend/environment-reference.md)
- [Admin Console release-safety runbook](docs/admin-backend/release-safety-runbook.md)
- [Admin operational snapshot contract](docs/admin-backend/operational-snapshot-contract.md)
- [Admin audit retention runbook](docs/admin-backend/audit-retention-runbook.md)
- [Admin incident retention runbook](docs/admin-backend/incident-retention-runbook.md)
- [Legacy session rollout runbook](docs/admin-backend/legacy-session-rollout.md)
- [Admin backend release checklist](docs/admin-backend/release-checklist.md)
- Service contracts live with `earthquake-hub-admin-backend/docs/`.

## RShake Alert Endpoint
- Nginx allows only `POST /api/messaging/restricted/rshake-alert` from the restricted messaging namespace.
- Other `/api/messaging/restricted/*` paths remain denied at the proxy layer.
- Optional shared-secret auth is supported via `RSHAKE_ALERT_SHARED_SECRET`.

### Shared Secret Wiring
- Sender devices can receive device-scoped alert credentials automatically after linking and use them for `X-RShake-Alert-Secret`.
- `RSHAKE_ALERT_SHARED_SECRET` remains available in the hub backend environment (compose `.env`) as an optional static global fallback.
- If the backend global secret is unset, per-device credentials still work and legacy proxy-only access remains backward compatible for devices that have not synced a credential yet.

## Deployment Testing
Follow the instructions on Server Deployment via Docker Compose in our [documentation](https://upri-earthquake.github.io/ehub-commons).

### Admin Console Dep-Test

The dep-test compose file is the preferred local integration path for the admin console. It serves the admin frontend through nginx at `/admin/` and proxies admin API calls through `/api/admin/`.

```bash
COMPOSE_BAKE=false docker compose --env-file .dep-test.env \
  -f docker-compose.dep-test.yml \
  up --build -d nginx-proxy-dep-test
```

Open:

```txt
https://ehub.local/admin/login
```

Expected smoke checks:

```bash
curl -k -I https://ehub.local/admin/
curl -k -i https://ehub.local/api/admin/profile
```

Before login, `/api/admin/profile` should return `401 Unauthorized`. A `404` means nginx or the backend admin route is not wired correctly.

For the complete authenticated route, cookie, login, and logout check, provide a disposable dep-test account with the `admin` role and run:

```bash
ADMIN_SMOKE_IDENTIFIER=<admin-username-or-email> \
ADMIN_SMOKE_PASSWORD=<admin-password> \
./scripts/admin-dep-test-smoke.sh
```

The smoke script is read-only after login: it verifies all admin SPA routes and each page's read API. It does not invoke approval, moderation, device, tunnel, or other state-changing actions.

Dep-test uses an isolated Docker subnet, `172.24.0.0/16`, to avoid clashing with the normal local compose network.

### Admin Console Production Exposure

Do not expose the admin console publicly.

Production `/admin/` and `/api/admin/` are tracked with fail-closed `deny all`
behavior. Do not edit the tracked nginx file with a host-specific address. Use
`scripts/configure-admin-access.sh` to generate validated `allow` directives
only after an approved VPN/internal CIDR is known, then follow the release-safety
runbook.

The private `admin-backend` is not a browser-facing API and is independent of
the `/admin/` exposure decision. Production Compose can start its read-only
telemetry service under the `admin` profile after mTLS material and narrow
filesystem markers are prepared. Follow the production read-only runbook; never
route port 5100 through public nginx.

For point-in-time WSTunnel listener evidence, the production runbook adds an
optional host-native collector. It runs as a dedicated systemd identity, serves
only a group-protected Unix socket, and reports only loopback listener ports in
the fixed WSTunnel range. A registry mapping and an observed listener are
separate facts; neither one proves latency, packet delivery, or continuous
availability.

## Email Branding Variables
- `ehub-backend` now supports branded HTML email logo settings:
  - `EMAIL_LOGO_URL`
  - `EMAIL_LOGO_PATH`
  - `EMAIL_LOGO_PUBLIC_FILE`
  - `EMAIL_FRONTEND_PUBLIC_DIR`
- In containerized deployment, prefer `EMAIL_LOGO_URL` so clients can load the logo without relying on host file paths.

## Reverse SSH Bastion Registry

Server-owned bastion registration scripts now live in:

- `bastion/bastion.sh`
- `bastion/setup-host.sh`
- `bastion/register-device.sh`
- `bastion/revoke-device.sh`
- `bastion/list-devices.sh`
- `bastion/connect-device.sh`

Source of truth remains:
- `/etc/upri/rshake-tunnels/devices.csv`

Sender-side bastion scripts are no longer used; this commons directory is the canonical server-side location.

### Containerized Backend: Recommended SSH Execution Mode

When `ehub-backend` runs in Docker, execute tunnel scripts on the bastion host via SSH instead of running scripts inside the container.

1. Run one-time bootstrap on host:
   - `sudo ./bastion/setup-host.sh`
   - This now also syncs generated SSH material into `./bastion/ssh` for Compose bind-mount compatibility.
   - It writes both `host` and `[host]:port` `known_hosts` formats for strict SSH checking compatibility.
   - If backend container UID/GID is not `1000:1000`, run:
     - `sudo ./bastion/setup-host.sh --backend-container-uid <uid> --backend-container-gid <gid>`
2. Use command wrapper for operations:
   - `bastion-tunnel LIST_DEVICES`
   - `sudo bastion-tunnel REGISTER_DEVICE ...`
   - `sudo bastion-tunnel REVOKE_DEVICE ...`
   - `sudo bastion-tunnel REVOKE_DEVICE --device-id <id> --terminate-active` (optional immediate cutoff)
   - `bastion-tunnel CONNECT_DEVICE --device-id <id>`
   - Re-login once after setup to apply `upri-bastion-ops` group membership.
3. Set `.env` values:
   - `TUNNEL_BASTION_HOST=<bastion-hostname>`
   - `TUNNEL_BASTION_PORT=22` (SSH metadata port for enrollment output; wstunnel transport is controlled by `TUNNEL_WSS_URL`)
   - `TUNNEL_SCRIPT_EXEC_MODE=ssh`
   - `TUNNEL_RESOLVE_SCRIPT=/opt/upri/bastion/resolve-device.sh`
   - `TUNNEL_SCRIPT_SSH_HOST=host.docker.internal`
   - `TUNNEL_SCRIPT_SSH_PORT=22`
   - `TUNNEL_SCRIPT_SSH_USER=tunnel-admin`
   - `TUNNEL_SCRIPT_SSH_KEY_PATH=/opt/upri/bastion/ssh/tunnel-admin_id_ed25519`
   - `TUNNEL_SCRIPT_SSH_KNOWN_HOSTS_PATH=/opt/upri/bastion/ssh/known_hosts`
   - `TUNNEL_SCRIPT_TIMEOUT_MS=15000`
   - `TUNNEL_SCRIPT_SSH_REMOTE_PREFIX=sudo -n`
   - `TUNNEL_REMOTE_ACTION_EXEC_MODE=relay`
   - `TUNNEL_REMOTE_ACTION_TARGET_SSH_HOST=127.0.0.1`
   - `TUNNEL_REMOTE_ACTION_RELAY_SSH_REMOTE_PREFIX=` (keep empty in normal setup)
   - `TUNNEL_REMOTE_ACTION_SSH_HOST=host.docker.internal`
   - `TUNNEL_REMOTE_ACTION_SSH_USER=myshake`
   - `TUNNEL_REMOTE_ACTION_SSH_KEY_PATH=/opt/upri/bastion/ssh/operator-remote-actions_id_ed25519`
   - `TUNNEL_REMOTE_ACTION_SSH_KNOWN_HOSTS_PATH=/opt/upri/bastion/ssh/known_hosts`
   - `TUNNEL_REMOTE_ACTION_SSH_STRICT_HOST_KEY=false`
   - `TUNNEL_REMOTE_ACTION_TIMEOUT_MS=20000`
   - `TUNNEL_OPERATOR_SSH_PUBLIC_KEY=<optional fallback>`
   - `TUNNEL_REMOTE_ACTIONS_OPERATOR_PUBLIC_KEY=<optional fallback>`
   - `TUNNEL_WSS_URL=wss://earthquake.up.edu.ph`
   - `TUNNEL_WSS_PATH_PREFIX=api/ws-tunnel/<secret>`
   - `WSTUNNEL_SERVER_VERSION=v10.5.2`
4. Restart backend container.

### New Server Tunnel Setup Checklist

On a fresh deployment host, complete these checks before testing device remote actions from the web UI:

1. Bootstrap the host-side bastion assets:
   - `cd /path/to/earthquake-hub-commons`
   - `sudo ./bastion/setup-host.sh`
   - If the backend container does not run as `1000:1000`, rerun with `--backend-container-uid <uid> --backend-container-gid <gid>`.
2. Confirm the backend SSH key can authenticate as `tunnel-admin` on the host:
   - `sudo test -s /opt/upri/bastion/ssh/tunnel-admin_id_ed25519`
   - `sudo grep -Fx "$(sudo cat /opt/upri/bastion/ssh/tunnel-admin_id_ed25519.pub)" /home/tunnel-admin/.ssh/authorized_keys`
   - `sudo -u tunnel-admin sudo -n /opt/upri/bastion/resolve-device.sh --version`
3. Confirm Compose can mount the synced SSH material into `ehub-backend`:
   - `ls -l ./bastion/ssh/tunnel-admin_id_ed25519 ./bastion/ssh/known_hosts`
   - `docker compose exec ehub-backend sh -lc 'test -r /opt/upri/bastion/ssh/tunnel-admin_id_ed25519 && test -r /opt/upri/bastion/ssh/known_hosts'`
4. Restart `ehub-backend` after any bastion SSH material or `.env` change:
   - `docker compose up -d ehub-backend`
5. Set enrollment metadata returned to sender devices:
   - `TUNNEL_BASTION_HOST=<public bastion host>`
   - `TUNNEL_BASTION_PORT=22`
   - `TUNNEL_BASTION_HOST_KEY=<known_hosts line for the public bastion host>`
   - Generate `TUNNEL_BASTION_HOST_KEY` on the bastion host:
     - `bastion-tunnel PRINT_HOST_KEY --public-bastion-host <public bastion host>`
   - Remote fallback: `ssh-keyscan -t ed25519 <public bastion host>` (verify this out-of-band before trusting it).
6. Keep the WSTunnel prefix aligned between backend enrollment metadata and nginx:
   - `.env`: `TUNNEL_WSS_PATH_PREFIX=api/ws-tunnel/<secret>`
   - nginx: `location ^~ /api/ws-tunnel/<secret>/`
   - To generate a suggested secret and matching guidance:
     - `bastion-tunnel PRINT_WSTUNNEL_CONFIG`
7. Check the WSTunnel edge path after changing nginx, firewall, or tunnel settings:
   - `bastion-tunnel CHECK_WSTUNNEL --compose-dir <earthquake-hub-commons> --remote-port <assigned-port>`

If the UI shows `tunnel-admin@host.docker.internal: Permission denied (publickey)`, fix checklist items 1-4 first. That error happens before WSTunnel is involved and before the sender receives `TUNNEL_BASTION_HOST_KEY`.

## WSTunnel Edge Hardening

- The deployment compose stack includes `wstunnel-server` behind nginx at `/api/ws-tunnel/`.
- `wstunnel-server` image tag is controlled by `WSTUNNEL_SERVER_VERSION` (default `v10.5.2`).
- Keep `TUNNEL_WSS_PATH_PREFIX` aligned across:
  - backend enrollment metadata (`TUNNEL_WSS_PATH_PREFIX`)
  - sender clients (`REMOTE_TUNNEL_WSS_PATH_PREFIX`)
  - nginx tunnel location path
- Path-prefix secrecy is enforced by the nginx `location ^~ /api/ws-tunnel/<secret>/` block.
- `wstunnel-restrictions.yaml` is mounted with `--restrict-config` to allow only expected reverse tunnel listeners:
  - match: `!Any` after nginx has routed the secret path
  - protocol: `Tcp`
  - server bind CIDR: `127.0.0.1/32`, `::1/128`
  - remote port range: `22000..22999`
- Use a long random `<secret>` suffix and rotate it if exposure is suspected.

### WSTunnel Troubleshooting Map

- `Invalid status code: 404` on the sender usually means nginx did not match the configured `/api/ws-tunnel/<secret>/` path.
- `Invalid status code: 504` usually means nginx matched the path but could not reach `wstunnel-server` on host port `7001`.
- `Invalid status code: 400` with WSTunnel logs showing `not allowed destination` means `wstunnel-restrictions.yaml` rejected the reverse tunnel destination.
- `Invalid status code: 429` means nginx rate limiting is active, usually after a reconnect loop. Fix the root cause, restart the sender tunnel, or wait for the limit window to clear.
- `bastion-tunnel LIST_DEVICES` showing `LISTENER down` means no listener exists yet on the assigned bastion port, for example `127.0.0.1:22000`.
- `LISTENER up` means WSTunnel created the reverse listener and `CONNECT_DEVICE` can try SSH.

Useful checks:

```bash
bastion-tunnel CHECK_WSTUNNEL --compose-dir <earthquake-hub-commons> --remote-port <assigned-port>
docker logs --tail 80 wstunnel-server
docker exec nginx-proxy nginx -t
docker exec nginx-proxy nginx -T | grep -n 'ws-tunnel'
docker exec nginx-proxy sh -lc 'curl -v --connect-timeout 5 http://host.docker.internal:7001/ || true'
ss -lnt "sport = :<assigned-port>"
```

The plain `curl` to `host.docker.internal:7001` should usually return `HTTP 400` with an `Invalid protocol request` body. That is expected because WSTunnel requires a WebSocket upgrade; it still proves nginx can reach the WSTunnel server.

If the host firewall uses a default-drop input policy, allow the nginx Docker bridge/subnet to reach WSTunnel on host port `7001`. Example:

```bash
sudo ufw allow in on <docker-bridge> proto tcp from <docker-subnet> to any port 7001
```
