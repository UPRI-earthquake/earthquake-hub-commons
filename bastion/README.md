# Bastion Device Tunnel Registry (Server-Owned)

This directory is the server-side owner of reverse SSH bastion registration.

Scripts:
- `bastion.sh` (command dispatcher)
- `setup-host.sh` (one-time host bootstrap)
- `register-device.sh`
- `revoke-device.sh`
- `list-devices.sh`
- `connect-device.sh`
- `resolve-device.sh`
- `check-wstunnel.sh`
- `print-bastion-host-key.sh`
- `print-wstunnel-config.sh`

Registry source of truth:
- `/etc/upri/rshake-tunnels/devices.csv`

## Security and ownership model
- Device registrations are enforced server-side.
- Active entries are collision-safe:
  - unique active `device_id`
  - unique active `bastion_user`
  - unique active `remote_port`
- Tunnel users are forwarding-only via `authorized_keys` options:
  - `restrict`
  - `port-forwarding`
  - no PTY / X11 / agent forwarding
  - `permitlisten="127.0.0.1:<assigned_port>"`

## Idempotency
- Re-running `register-device.sh` for the same active device is safe.
- Re-running `revoke-device.sh` for an already revoked device is safe.

## Ownership
This directory is the canonical location for bastion tunnel registration scripts.

## Why `bastion/ssh` Exists on Deployment Host but Not in Git
- `bastion/ssh/` stores runtime secrets/material (`tunnel-admin` key, operator shell key, known_hosts).
- It is intentionally not versioned and is ignored by git (`.gitignore` has `bastion/ssh/`).
- On a fresh clone, this directory appears only after setup generates/copies the files.

## One-Time Setup (Recommended)
Run once on the deployment host:

```bash
cd /path/to/earthquake-hub-commons
sudo ./bastion/setup-host.sh
```

This bootstraps:
- `/opt/upri/bastion` scripts
- `/usr/local/bin/bastion-tunnel` launcher
- `tunnel-admin` account + sudoers policy
- `upri-bastion-ops` group for non-root LIST/CONNECT commands
- `tunnel-admin` is added to `upri-bastion-ops` (when ops-group setup is enabled)
- `/opt/upri/bastion/ssh/{tunnel-admin_id_ed25519,operator-shell_id_ed25519,operator-remote-actions_id_ed25519,known_hosts}`
- `/etc/upri/rshake-tunnels/devices.csv` (if missing)
- key ownership/mode checks, including remote-actions key readability by `tunnel-admin`

When `setup-host.sh` is run from this repository, it also syncs SSH material to `./bastion/ssh` so Docker Compose bind-mounts (`./bastion -> /opt/upri/bastion`) can read the keys without extra manual copy steps.
Default synced ownership is `1000:1000` (backend container `node` user). Override when needed:
- `sudo ./bastion/setup-host.sh --backend-container-uid <uid> --backend-container-gid <gid>`
`setup-host.sh` also writes both plain-host and `[host]:port` entries into `known_hosts` to avoid strict-host-checking mismatches.

### Verify backend SSH access

When the web UI reports `tunnel-admin@host.docker.internal: Permission denied (publickey)`, the backend container reached the host SSH server but the host rejected the mounted private key. Re-run or verify the host bootstrap before debugging WSTunnel:

```bash
cd /path/to/earthquake-hub-commons
sudo ./bastion/setup-host.sh
sudo test -s /opt/upri/bastion/ssh/tunnel-admin_id_ed25519
sudo grep -Fx "$(sudo cat /opt/upri/bastion/ssh/tunnel-admin_id_ed25519.pub)" /home/tunnel-admin/.ssh/authorized_keys
sudo -u tunnel-admin sudo -n /opt/upri/bastion/resolve-device.sh --version
ls -l ./bastion/ssh/tunnel-admin_id_ed25519 ./bastion/ssh/known_hosts
docker compose exec ehub-backend sh -lc 'test -r /opt/upri/bastion/ssh/tunnel-admin_id_ed25519 && test -r /opt/upri/bastion/ssh/known_hosts'
docker compose up -d ehub-backend
```

`TUNNEL_BASTION_HOST_KEY` and `TUNNEL_WSS_PATH_PREFIX` are still required for successful device enrollment and tunnel transport, but they do not cause this host-side `publickey` rejection.

## Command Wrapper (Sender-like Flow)
After setup, use sender-style command dispatch:

```bash
bastion-tunnel LIST_DEVICES
sudo bastion-tunnel REGISTER_DEVICE --device-id AM_RF47F --bastion-host earthquake.up.edu.ph --public-key-file /etc/upri/remote-tunnel/id_ed25519.pub
sudo bastion-tunnel REVOKE_DEVICE --device-id AM_RF47F
sudo bastion-tunnel REVOKE_DEVICE --device-id AM_RF47F --terminate-active
bastion-tunnel RESOLVE_DEVICE --device-id AM_RF47F
bastion-tunnel CONNECT_DEVICE --device-id AM_RF47F
bastion-tunnel CHECK_WSTUNNEL --compose-dir /path/to/earthquake-hub-commons --remote-port 22000
bastion-tunnel PRINT_HOST_KEY --public-bastion-host earthquake.up.edu.ph
bastion-tunnel PRINT_WSTUNNEL_CONFIG
```

Note:
- `REGISTER_DEVICE` and `REVOKE_DEVICE` remain privileged operations (`sudo` required).
- `LIST_DEVICES` and `CONNECT_DEVICE` are non-root after setup configures group access.
- `RESOLVE_DEVICE` is also available for non-root operators after setup.
- `CHECK_WSTUNNEL` is read-only. It checks local templates, nginx runtime config, nginx-to-WSTunnel reachability, recent WSTunnel restriction errors, optional assigned listener state, and UFW visibility when allowed.
- Re-login once after setup to pick up new group membership.
- `REVOKE_DEVICE --terminate-active` additionally tries to kill an already-established tunnel listener on the assigned port.

`CONNECT_DEVICE` is a convenience wrapper that resolves the registered `remote_port` and executes:

```bash
ssh -p <remote_port> \
  -i /opt/upri/bastion/ssh/operator-shell_id_ed25519 \
  -o BatchMode=yes \
  -o IdentitiesOnly=yes \
  -o StrictHostKeyChecking=accept-new \
  myshake@127.0.0.1
```

The operator key public part is sent to devices as `REMOTE_TUNNEL_OPERATOR_SSH_PUBLIC_KEY` during tunnel enrollment, so bastion operators no longer need the device password.

Remote actions use a separate forced-command key (`REMOTE_TUNNEL_OPERATOR_PUBLIC_KEY`) generated by setup:
- `/opt/upri/bastion/ssh/operator-remote-actions_id_ed25519`
- `/opt/upri/bastion/ssh/operator-remote-actions_id_ed25519.pub`

## Containerized backend integration (recommended)

If `ehub-backend` runs in Docker, configure the backend to execute these scripts over SSH on the bastion host.

Suggested host setup:

1. Create a restricted operator user:
   - `sudo useradd --create-home --shell /bin/bash tunnel-admin`
2. Add backend public key to `/home/tunnel-admin/.ssh/authorized_keys`.
3. Add sudoers rule (`visudo -f /etc/sudoers.d/tunnel-admin-upri`):
   - `tunnel-admin ALL=(root) NOPASSWD: /opt/upri/bastion/register-device.sh, /opt/upri/bastion/revoke-device.sh, /opt/upri/bastion/list-devices.sh, /opt/upri/bastion/resolve-device.sh`
4. Verify from host:
   - `sudo -u tunnel-admin sudo -n /opt/upri/bastion/register-device.sh --version`

Then set backend env vars:
- `TUNNEL_BASTION_HOST=<bastion-hostname>`
- `TUNNEL_BASTION_PORT=22` (SSH metadata port emitted during enrollment; tunnel transport still uses `TUNNEL_WSS_URL`)
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
- `TUNNEL_REGISTER_SCRIPT=/opt/upri/bastion/register-device.sh`
- `TUNNEL_REVOKE_SCRIPT=/opt/upri/bastion/revoke-device.sh`
- `TUNNEL_RESOLVE_SCRIPT=/opt/upri/bastion/resolve-device.sh`
