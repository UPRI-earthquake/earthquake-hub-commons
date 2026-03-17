# earthquake-hub-commons
This repository integrates all the essential programs necessary for hosting a citizen science network of ground motion sensors (such as but not limited to raspberryshakes). It enables data transmission, archiving, and allows feeding the network data to earthquake detection software(such as but not limited to SeisComP).

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
2. Use command wrapper for operations:
   - `bastion-tunnel LIST_DEVICES`
   - `sudo bastion-tunnel REGISTER_DEVICE ...`
   - `sudo bastion-tunnel REVOKE_DEVICE ...`
   - `sudo bastion-tunnel REVOKE_DEVICE --device-id <id> --terminate-active` (optional immediate cutoff)
   - `bastion-tunnel CONNECT_DEVICE --device-id <id>`
   - Re-login once after setup to apply `upri-bastion-ops` group membership.
3. Set `.env` values:
   - `TUNNEL_SCRIPT_EXEC_MODE=ssh`
   - `TUNNEL_SCRIPT_SSH_HOST=host.docker.internal`
   - `TUNNEL_SCRIPT_SSH_USER=tunnel-admin`
   - `TUNNEL_SCRIPT_SSH_KEY_PATH=/opt/upri/bastion/ssh/tunnel-admin_id_ed25519`
   - `TUNNEL_SCRIPT_SSH_KNOWN_HOSTS_PATH=/opt/upri/bastion/ssh/known_hosts`
   - `TUNNEL_SCRIPT_SSH_REMOTE_PREFIX=sudo -n`
   - `TUNNEL_WSS_URL=wss://earthquake.science.upd.edu.ph`
   - `TUNNEL_WSS_PATH_PREFIX=api/ws-tunnel/<secret>`
   - `WSTUNNEL_SERVER_VERSION=v10.5.2`
4. Restart backend container.

## WSTunnel Edge Hardening

- The deployment compose stack includes `wstunnel-server` behind nginx at `/api/ws-tunnel/`.
- `wstunnel-server` image tag is controlled by `WSTUNNEL_SERVER_VERSION` (default `v10.5.2`).
- Keep `TUNNEL_WSS_PATH_PREFIX` aligned across:
  - `wstunnel-server` (`--restrict-http-upgrade-path-prefix`)
  - sender clients (`REMOTE_TUNNEL_WSS_PATH_PREFIX`)
- Use a long random `<secret>` suffix and rotate it if exposure is suspected.
