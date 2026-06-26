#!/usr/bin/env bash
set -euo pipefail

SCRIPT_VERSION="2026-03-19.4"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

INSTALL_DIR_DEFAULT="/opt/upri/bastion"
LAUNCHER_PATH_DEFAULT="/usr/local/bin/bastion-tunnel"
TUNNEL_ADMIN_USER_DEFAULT="tunnel-admin"
SSH_HOST_ALIAS_DEFAULT="host.docker.internal"
SSH_PORT_DEFAULT="22"
BACKEND_CONTAINER_UID_DEFAULT="1000"
BACKEND_CONTAINER_GID_DEFAULT="1000"
REGISTRY_FILE_DEFAULT="/etc/upri/rshake-tunnels/devices.csv"
OPS_GROUP_DEFAULT="upri-bastion-ops"
REGISTRY_HEADER="device_id,bastion_user,remote_port,status,key_fingerprint,created_at,revoked_at"

install_dir="$INSTALL_DIR_DEFAULT"
launcher_path="$LAUNCHER_PATH_DEFAULT"
tunnel_admin_user="$TUNNEL_ADMIN_USER_DEFAULT"
ssh_host_alias="$SSH_HOST_ALIAS_DEFAULT"
ssh_port="$SSH_PORT_DEFAULT"
backend_container_uid="$BACKEND_CONTAINER_UID_DEFAULT"
backend_container_gid="$BACKEND_CONTAINER_GID_DEFAULT"
registry_file="$REGISTRY_FILE_DEFAULT"
ops_group="$OPS_GROUP_DEFAULT"
skip_tunnel_admin="false"
skip_sudoers="false"
skip_ssh_material="false"
skip_ops_group="false"

usage() {
  cat <<EOF_USAGE
Usage: sudo $(basename "$0") [options]

Options:
  --install-dir <path>         Install bastion scripts to this directory (default: $INSTALL_DIR_DEFAULT)
  --launcher-path <path>       Install launcher wrapper here (default: $LAUNCHER_PATH_DEFAULT)
  --tunnel-admin-user <user>   SSH operator user for backend script execution (default: $TUNNEL_ADMIN_USER_DEFAULT)
  --ssh-host-alias <host>      Host alias written to known_hosts (default: $SSH_HOST_ALIAS_DEFAULT)
  --ssh-port <port>            SSH port for known_hosts entries (default: $SSH_PORT_DEFAULT)
  --backend-container-uid <id> UID used by backend container for reading bind-mounted SSH keys (default: $BACKEND_CONTAINER_UID_DEFAULT)
  --backend-container-gid <id> GID used by backend container for reading bind-mounted SSH keys (default: $BACKEND_CONTAINER_GID_DEFAULT)
  --registry-file <path>       Tunnel registry CSV path (default: $REGISTRY_FILE_DEFAULT)
  --ops-group <group>          Group for non-root LIST/CONNECT access (default: $OPS_GROUP_DEFAULT)
  --skip-tunnel-admin          Do not create/manage tunnel-admin user
  --skip-sudoers               Do not create/update sudoers rule
  --skip-ssh-material          Do not create /opt/upri/bastion/ssh keys + known_hosts
  --skip-ops-group             Do not configure registry operator group access
  --version                    Print version
  -h, --help                   Show this help
EOF_USAGE
}

fail() {
  echo "[FAILED] $*" >&2
  exit 1
}

warn() {
  echo "[WARN] $*" >&2
}

can_user_read_file() {
  local user_name="$1"
  local file_path="$2"

  if command -v runuser >/dev/null 2>&1; then
    runuser -u "$user_name" -- test -r "$file_path"
    return $?
  fi
  su -s /bin/sh -c "test -r \"$file_path\"" "$user_name"
}

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    fail "Run as root (sudo)."
  fi
}

validate_port() {
  local value="$1"
  [[ "$value" =~ ^[0-9]+$ ]] || return 1
  (( value >= 1 && value <= 65535 )) || return 1
  return 0
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --install-dir)
        install_dir="${2:-}"; shift 2 ;;
      --launcher-path)
        launcher_path="${2:-}"; shift 2 ;;
      --tunnel-admin-user)
        tunnel_admin_user="${2:-}"; shift 2 ;;
      --ssh-host-alias)
        ssh_host_alias="${2:-}"; shift 2 ;;
      --ssh-port)
        ssh_port="${2:-}"; shift 2 ;;
      --backend-container-uid)
        backend_container_uid="${2:-}"; shift 2 ;;
      --backend-container-gid)
        backend_container_gid="${2:-}"; shift 2 ;;
      --registry-file)
        registry_file="${2:-}"; shift 2 ;;
      --ops-group)
        ops_group="${2:-}"; shift 2 ;;
      --skip-tunnel-admin)
        skip_tunnel_admin="true"; shift ;;
      --skip-sudoers)
        skip_sudoers="true"; shift ;;
      --skip-ssh-material)
        skip_ssh_material="true"; shift ;;
      --skip-ops-group)
        skip_ops_group="true"; shift ;;
      --version)
        echo "$(basename "$0") $SCRIPT_VERSION"; exit 0 ;;
      -h|--help)
        usage; exit 0 ;;
      *)
        fail "Unknown option: $1" ;;
    esac
  done

  [[ -n "$install_dir" ]] || fail "--install-dir cannot be empty."
  [[ -n "$launcher_path" ]] || fail "--launcher-path cannot be empty."
  [[ -n "$tunnel_admin_user" ]] || fail "--tunnel-admin-user cannot be empty."
  [[ "$tunnel_admin_user" =~ ^[a-z_][a-z0-9._-]{0,31}$ ]] || fail "Invalid --tunnel-admin-user value: $tunnel_admin_user"
  [[ -n "$ssh_host_alias" ]] || fail "--ssh-host-alias cannot be empty."
  [[ -n "$ops_group" ]] || fail "--ops-group cannot be empty."
  [[ "$ops_group" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || fail "Invalid --ops-group value: $ops_group"
  validate_port "$ssh_port" || fail "--ssh-port must be between 1 and 65535."
  [[ "$backend_container_uid" =~ ^[0-9]+$ ]] || fail "--backend-container-uid must be numeric."
  [[ "$backend_container_gid" =~ ^[0-9]+$ ]] || fail "--backend-container-gid must be numeric."
}

install_scripts() {
  local src
  local dst
  local file
  local files=(
    "register-device.sh"
    "revoke-device.sh"
    "list-devices.sh"
    "connect-device.sh"
    "resolve-device.sh"
    "print-bastion-host-key.sh"
    "print-wstunnel-config.sh"
    "bastion.sh"
    "setup-host.sh"
  )

  mkdir -p "$install_dir"
  chmod 0755 "$install_dir"

  for file in "${files[@]}"; do
    src="$SCRIPT_DIR/$file"
    dst="$install_dir/$file"
    [[ -r "$src" ]] || fail "Missing source script: $src"
    install -m 0755 "$src" "$dst"
  done
}

install_launcher() {
  local tmp_file
  local launcher_dir

  launcher_dir="$(dirname "$launcher_path")"
  mkdir -p "$launcher_dir"

  tmp_file="$(mktemp /tmp/upri-bastion-launcher.XXXXXX)"
  cat <<EOF_WRAP > "$tmp_file"
#!/bin/sh
exec "$install_dir/bastion.sh" "\$@"
EOF_WRAP
  install -m 0755 "$tmp_file" "$launcher_path"
  rm -f "$tmp_file"
}

ensure_registry_file() {
  local reg_dir
  reg_dir="$(dirname "$registry_file")"
  mkdir -p "$reg_dir"
  if [[ ! -f "$registry_file" ]]; then
    printf '%s\n' "$REGISTRY_HEADER" > "$registry_file"
  fi
  chmod 0640 "$registry_file"
}

setup_ops_group_access() {
  local reg_dir
  local operator_user

  if [[ "$skip_ops_group" == "true" ]]; then
    return 0
  fi

  reg_dir="$(dirname "$registry_file")"
  groupadd -f "$ops_group"

  chgrp "$ops_group" "$reg_dir"
  chmod 2750 "$reg_dir"

  chgrp "$ops_group" "$registry_file"
  chmod 0640 "$registry_file"

  operator_user="${SUDO_USER:-}"
  if [[ -n "$operator_user" && "$operator_user" != "root" ]] && id -u "$operator_user" >/dev/null 2>&1; then
    usermod -aG "$ops_group" "$operator_user"
  else
    warn "No non-root sudo user detected; add operators manually: usermod -aG $ops_group <user>"
  fi
}

ensure_tunnel_admin_user() {
  local user_home

  if [[ "$skip_tunnel_admin" == "true" ]]; then
    return 0
  fi

  if ! id -u "$tunnel_admin_user" >/dev/null 2>&1; then
    useradd --create-home --shell /bin/bash "$tunnel_admin_user"
  fi

  user_home="$(getent passwd "$tunnel_admin_user" | cut -d: -f6)"
  [[ -n "$user_home" ]] || fail "Unable to resolve home for user: $tunnel_admin_user"
  mkdir -p "$user_home/.ssh"
  chmod 0700 "$user_home/.ssh"
  chown -R "$tunnel_admin_user:$tunnel_admin_user" "$user_home/.ssh"

  # Ensure tunnel-admin can traverse/read bastion SSH material when ops-group
  # access is enabled (ssh dir is group-owned and 0750).
  if [[ "$skip_ops_group" == "false" ]] && getent group "$ops_group" >/dev/null 2>&1; then
    usermod -aG "$ops_group" "$tunnel_admin_user"
  fi
}

append_unique_line() {
  local file_path="$1"
  local line="$2"
  touch "$file_path"
  if ! grep -Fxq "$line" "$file_path"; then
    printf '%s\n' "$line" >> "$file_path"
  fi
}

setup_ssh_material() {
  local ssh_dir
  local admin_key_path
  local admin_key_pub_path
  local operator_shell_key_path
  local operator_shell_key_pub_path
  local operator_actions_key_path
  local operator_actions_key_pub_path
  local known_hosts_path
  local host_key_file
  local key_type
  local key_data
  local user_home
  local auth_keys_path

  if [[ "$skip_ssh_material" == "true" ]]; then
    return 0
  fi

  ssh_dir="$install_dir/ssh"
  admin_key_path="$ssh_dir/tunnel-admin_id_ed25519"
  admin_key_pub_path="$admin_key_path.pub"
  operator_shell_key_path="$ssh_dir/operator-shell_id_ed25519"
  operator_shell_key_pub_path="$operator_shell_key_path.pub"
  operator_actions_key_path="$ssh_dir/operator-remote-actions_id_ed25519"
  operator_actions_key_pub_path="$operator_actions_key_path.pub"
  known_hosts_path="$ssh_dir/known_hosts"

  mkdir -p "$ssh_dir"
  if [[ "$skip_ops_group" == "false" ]] && getent group "$ops_group" >/dev/null 2>&1; then
    chgrp "$ops_group" "$ssh_dir"
    chmod 0750 "$ssh_dir"
  else
    chmod 0700 "$ssh_dir"
  fi

  if [[ ! -f "$admin_key_path" || ! -f "$admin_key_pub_path" ]]; then
    ssh-keygen -t ed25519 -N '' -f "$admin_key_path" >/dev/null
  fi
  if [[ ! -f "$operator_shell_key_path" || ! -f "$operator_shell_key_pub_path" ]]; then
    ssh-keygen -t ed25519 -N '' -f "$operator_shell_key_path" >/dev/null
  fi
  if [[ ! -f "$operator_actions_key_path" || ! -f "$operator_actions_key_pub_path" ]]; then
    ssh-keygen -t ed25519 -N '' -f "$operator_actions_key_path" >/dev/null
  fi

  chmod 0600 "$admin_key_path"
  chmod 0644 "$admin_key_pub_path"

  if [[ "$skip_ops_group" == "false" ]] && getent group "$ops_group" >/dev/null 2>&1; then
    chgrp "$ops_group" "$operator_shell_key_path" "$operator_shell_key_pub_path"
    chmod 0640 "$operator_shell_key_path"
    chmod 0644 "$operator_shell_key_pub_path"
  else
    chmod 0600 "$operator_shell_key_path"
    chmod 0644 "$operator_shell_key_pub_path"
  fi

  if [[ "$skip_tunnel_admin" == "false" ]] && id -u "$tunnel_admin_user" >/dev/null 2>&1; then
    chown "$tunnel_admin_user:$tunnel_admin_user" "$operator_actions_key_path" "$operator_actions_key_pub_path"
  elif [[ "$skip_ops_group" == "false" ]] && getent group "$ops_group" >/dev/null 2>&1; then
    chgrp "$ops_group" "$operator_actions_key_path" "$operator_actions_key_pub_path"
  fi
  chmod 0600 "$operator_actions_key_path"
  chmod 0644 "$operator_actions_key_pub_path"

  : > "$known_hosts_path"
  for host_key_file in /etc/ssh/ssh_host_ed25519_key.pub /etc/ssh/ssh_host_rsa_key.pub; do
    [[ -r "$host_key_file" ]] || continue
    read -r key_type key_data _ < "$host_key_file"
    [[ -n "${key_type:-}" && -n "${key_data:-}" ]] || continue
    # Include both plain-host and bracketed host:port formats.
    # Some SSH invocations match one or the other depending on how host/port is passed.
    printf '%s %s %s\n' "$ssh_host_alias" "$key_type" "$key_data" >> "$known_hosts_path"
    printf '[%s]:%s %s %s\n' "$ssh_host_alias" "$ssh_port" "$key_type" "$key_data" >> "$known_hosts_path"
    printf '127.0.0.1 %s %s\n' "$key_type" "$key_data" >> "$known_hosts_path"
    printf '[127.0.0.1]:%s %s %s\n' "$ssh_port" "$key_type" "$key_data" >> "$known_hosts_path"
  done
  chmod 0644 "$known_hosts_path"

  if [[ ! -s "$known_hosts_path" ]]; then
    warn "No local SSH host public keys were found under /etc/ssh. Populate $known_hosts_path manually."
  fi

  if [[ "$skip_tunnel_admin" == "false" ]] && id -u "$tunnel_admin_user" >/dev/null 2>&1; then
    user_home="$(getent passwd "$tunnel_admin_user" | cut -d: -f6)"
    auth_keys_path="$user_home/.ssh/authorized_keys"
    append_unique_line "$auth_keys_path" "$(cat "$admin_key_pub_path")"
    chmod 0600 "$auth_keys_path"
    chown "$tunnel_admin_user:$tunnel_admin_user" "$auth_keys_path"
  fi
}

verify_ssh_material_access() {
  local operator_actions_key_path

  if [[ "$skip_ssh_material" == "true" ]]; then
    return 0
  fi
  if [[ "$skip_tunnel_admin" == "true" ]]; then
    return 0
  fi
  if ! id -u "$tunnel_admin_user" >/dev/null 2>&1; then
    fail "Tunnel admin user is missing during SSH material verification: $tunnel_admin_user"
  fi

  operator_actions_key_path="$install_dir/ssh/operator-remote-actions_id_ed25519"
  [[ -r "$operator_actions_key_path" ]] || fail "Missing remote-actions private key: $operator_actions_key_path"

  if ! can_user_read_file "$tunnel_admin_user" "$operator_actions_key_path"; then
    fail "Remote-actions key is not readable by $tunnel_admin_user: $operator_actions_key_path"
  fi
}

sync_workspace_ssh_material() {
  local source_ssh_dir
  local target_ssh_dir

  if [[ "$skip_ssh_material" == "true" ]]; then
    return 0
  fi

  source_ssh_dir="$install_dir/ssh"
  target_ssh_dir="$SCRIPT_DIR/ssh"
  if [[ "$source_ssh_dir" == "$target_ssh_dir" ]]; then
    return 0
  fi

  if [[ ! -d "$source_ssh_dir" ]]; then
    warn "Source SSH material directory is missing: $source_ssh_dir"
    return 0
  fi

  install -d -m 0700 -o "$backend_container_uid" -g "$backend_container_gid" "$target_ssh_dir"

  install -m 0600 -o "$backend_container_uid" -g "$backend_container_gid" "$source_ssh_dir/tunnel-admin_id_ed25519" "$target_ssh_dir/tunnel-admin_id_ed25519"
  install -m 0644 -o "$backend_container_uid" -g "$backend_container_gid" "$source_ssh_dir/tunnel-admin_id_ed25519.pub" "$target_ssh_dir/tunnel-admin_id_ed25519.pub"
  install -m 0600 -o "$backend_container_uid" -g "$backend_container_gid" "$source_ssh_dir/operator-shell_id_ed25519" "$target_ssh_dir/operator-shell_id_ed25519"
  install -m 0644 -o "$backend_container_uid" -g "$backend_container_gid" "$source_ssh_dir/operator-shell_id_ed25519.pub" "$target_ssh_dir/operator-shell_id_ed25519.pub"
  install -m 0600 -o "$backend_container_uid" -g "$backend_container_gid" "$source_ssh_dir/operator-remote-actions_id_ed25519" "$target_ssh_dir/operator-remote-actions_id_ed25519"
  install -m 0644 -o "$backend_container_uid" -g "$backend_container_gid" "$source_ssh_dir/operator-remote-actions_id_ed25519.pub" "$target_ssh_dir/operator-remote-actions_id_ed25519.pub"
  install -m 0644 -o "$backend_container_uid" -g "$backend_container_gid" "$source_ssh_dir/known_hosts" "$target_ssh_dir/known_hosts"
}

setup_sudoers() {
  local tmp_file
  local sudoers_path

  if [[ "$skip_sudoers" == "true" ]]; then
    return 0
  fi
  if [[ "$skip_tunnel_admin" == "true" ]]; then
    warn "--skip-tunnel-admin is set; skipping sudoers setup."
    return 0
  fi

  sudoers_path="/etc/sudoers.d/tunnel-admin-upri"
  tmp_file="$(mktemp /tmp/upri-tunnel-admin-sudoers.XXXXXX)"

  cat <<EOF_SUDOERS > "$tmp_file"
Cmnd_Alias UPRI_BASTION_CMDS = $install_dir/register-device.sh, $install_dir/revoke-device.sh, $install_dir/list-devices.sh, $install_dir/resolve-device.sh
$tunnel_admin_user ALL=(root) NOPASSWD: UPRI_BASTION_CMDS
EOF_SUDOERS

  if command -v visudo >/dev/null 2>&1; then
    visudo -cf "$tmp_file" >/dev/null || {
      rm -f "$tmp_file"
      fail "Generated sudoers file failed validation."
    }
  fi

  install -m 0440 "$tmp_file" "$sudoers_path"
  rm -f "$tmp_file"
}

print_summary() {
  cat <<EOF_SUMMARY
[OK] Bastion setup completed.

Launcher:
  $launcher_path

Installed scripts:
  $install_dir/register-device.sh
  $install_dir/revoke-device.sh
  $install_dir/list-devices.sh
  $install_dir/connect-device.sh
  $install_dir/resolve-device.sh
  $install_dir/print-bastion-host-key.sh
  $install_dir/print-wstunnel-config.sh
  $install_dir/bastion.sh

Backend env recommendation:
  TUNNEL_SCRIPT_EXEC_MODE=ssh
  TUNNEL_RESOLVE_SCRIPT=$install_dir/resolve-device.sh
  TUNNEL_SCRIPT_SSH_HOST=$ssh_host_alias
  TUNNEL_SCRIPT_SSH_USER=$tunnel_admin_user
  TUNNEL_SCRIPT_SSH_KEY_PATH=$install_dir/ssh/tunnel-admin_id_ed25519
  TUNNEL_SCRIPT_SSH_KNOWN_HOSTS_PATH=$install_dir/ssh/known_hosts
  TUNNEL_SCRIPT_TIMEOUT_MS=15000
  TUNNEL_SCRIPT_SSH_REMOTE_PREFIX=sudo -n
  TUNNEL_REMOTE_ACTION_EXEC_MODE=relay
  TUNNEL_REMOTE_ACTION_TARGET_SSH_HOST=127.0.0.1
  TUNNEL_REMOTE_ACTION_RELAY_SSH_REMOTE_PREFIX=
  TUNNEL_REMOTE_ACTION_SSH_HOST=$ssh_host_alias
  TUNNEL_REMOTE_ACTION_SSH_USER=myshake
  TUNNEL_REMOTE_ACTION_SSH_KEY_PATH=$install_dir/ssh/operator-remote-actions_id_ed25519
  TUNNEL_REMOTE_ACTION_SSH_KNOWN_HOSTS_PATH=$install_dir/ssh/known_hosts
  TUNNEL_REMOTE_ACTION_SSH_STRICT_HOST_KEY=false
  TUNNEL_REMOTE_ACTION_TIMEOUT_MS=20000

Operator shell key (used by CONNECT_DEVICE):
  Private: $install_dir/ssh/operator-shell_id_ed25519
  Public:  $install_dir/ssh/operator-shell_id_ed25519.pub

Remote-actions key (used by /device/remote-actions/*):
  Private: $install_dir/ssh/operator-remote-actions_id_ed25519
  Public:  $install_dir/ssh/operator-remote-actions_id_ed25519.pub

EOF_SUMMARY

  if [[ "$install_dir/ssh" != "$SCRIPT_DIR/ssh" ]]; then
    cat <<EOF_SYNC
Docker bind-mount sync:
  Synced: $install_dir/ssh -> $SCRIPT_DIR/ssh
  Synced owner: ${backend_container_uid}:${backend_container_gid}
  (so containers mounting ./bastion can read the generated SSH material)

EOF_SYNC
  fi

  if [[ "$skip_ops_group" == "false" ]]; then
    echo
    echo "Registry operator group:"
    echo "  $ops_group"
    if [[ -n "${SUDO_USER:-}" && "${SUDO_USER:-}" != "root" ]]; then
      echo "  Added ${SUDO_USER} to $ops_group (re-login required to apply new group membership)."
    else
      echo "  Add operators manually: sudo usermod -aG $ops_group <user>"
    fi
  else
    echo
    echo "Registry operator group: skipped (--skip-ops-group)."
    echo "Non-root LIST/CONNECT may not work until registry permissions are configured."
  fi

  echo
  echo "Quick checks:"
  if [[ "$skip_ops_group" == "false" ]]; then
    echo "  $launcher_path LIST_DEVICES"
    echo "  $launcher_path CONNECT_DEVICE --device-id <id> --dry-run"
  else
    echo "  sudo $launcher_path LIST_DEVICES"
    echo "  sudo $launcher_path CONNECT_DEVICE --device-id <id> --dry-run"
  fi
  echo "  sudo -u $tunnel_admin_user sudo -n $install_dir/register-device.sh --version"
  echo "  $launcher_path PRINT_HOST_KEY --public-bastion-host <public-host>"
  echo "  $launcher_path PRINT_WSTUNNEL_CONFIG"
}

main() {
  parse_args "$@"
  require_root
  install_scripts
  install_launcher
  ensure_registry_file
  setup_ops_group_access
  ensure_tunnel_admin_user
  setup_ssh_material
  verify_ssh_material_access
  sync_workspace_ssh_material
  setup_sudoers
  print_summary
}

main "$@"
