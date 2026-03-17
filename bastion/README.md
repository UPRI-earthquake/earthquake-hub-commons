# Bastion Device Tunnel Registry (Server-Owned)

This directory is the server-side owner of reverse SSH bastion registration.

Scripts:
- `bastion.sh` (command dispatcher)
- `setup-host.sh` (one-time host bootstrap)
- `register-device.sh`
- `revoke-device.sh`
- `list-devices.sh`
- `connect-device.sh`

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
- `bastion/ssh/` stores runtime secrets/material (`tunnel-admin` private key, known_hosts).
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
- `/opt/upri/bastion/ssh/{tunnel-admin_id_ed25519,known_hosts}`
- `/etc/upri/rshake-tunnels/devices.csv` (if missing)

## Command Wrapper (Sender-like Flow)
After setup, use sender-style command dispatch:

```bash
bastion-tunnel LIST_DEVICES
sudo bastion-tunnel REGISTER_DEVICE --device-id AM_RF47F --bastion-host earthquake.science.upd.edu.ph --public-key-file /etc/upri/remote-tunnel/id_ed25519.pub
sudo bastion-tunnel REVOKE_DEVICE --device-id AM_RF47F
bastion-tunnel CONNECT_DEVICE --device-id AM_RF47F
```

Note:
- `REGISTER_DEVICE` and `REVOKE_DEVICE` remain privileged operations (`sudo` required).
- `LIST_DEVICES` and `CONNECT_DEVICE` are non-root after setup configures group access.
- Re-login once after setup to pick up new group membership.

`CONNECT_DEVICE` is a convenience wrapper that resolves the registered `remote_port` and executes:

```bash
ssh -p <remote_port> myshake@127.0.0.1
```

## Containerized backend integration (recommended)

If `ehub-backend` runs in Docker, configure the backend to execute these scripts over SSH on the bastion host.

Suggested host setup:

1. Create a restricted operator user:
   - `sudo useradd --create-home --shell /bin/bash tunnel-admin`
2. Add backend public key to `/home/tunnel-admin/.ssh/authorized_keys`.
3. Add sudoers rule (`visudo -f /etc/sudoers.d/tunnel-admin-upri`):
   - `tunnel-admin ALL=(root) NOPASSWD: /opt/upri/bastion/register-device.sh, /opt/upri/bastion/revoke-device.sh`
4. Verify from host:
   - `sudo -u tunnel-admin sudo -n /opt/upri/bastion/register-device.sh --version`

Then set backend env vars:
- `TUNNEL_SCRIPT_EXEC_MODE=ssh`
- `TUNNEL_SCRIPT_SSH_HOST=host.docker.internal`
- `TUNNEL_SCRIPT_SSH_USER=tunnel-admin`
- `TUNNEL_SCRIPT_SSH_REMOTE_PREFIX=sudo -n`
