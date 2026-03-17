#!/usr/bin/env bash
set -euo pipefail

SCRIPT_VERSION="2026-03-17.2"
REGISTRY_FILE_DEFAULT="/etc/upri/rshake-tunnels/devices.csv"
PORT_RANGE_START_DEFAULT=22000
PORT_RANGE_END_DEFAULT=22999
DEFAULT_BASTION_PORT="${TUNNEL_BASTION_PORT:-22}"
DEFAULT_LOCAL_HOST="127.0.0.1"
DEFAULT_LOCAL_PORT=22
DEFAULT_KEY_PATH="/etc/upri/remote-tunnel/id_ed25519"
DEFAULT_WSS_URL="${TUNNEL_WSS_URL:-}"
DEFAULT_WSS_PATH_PREFIX="$(echo "${TUNNEL_WSS_PATH_PREFIX:-}" | sed 's#^/*##; s#/*$##')"

REGISTRY_HEADER="device_id,bastion_user,remote_port,status,key_fingerprint,created_at,revoked_at"

device_id=""
bastion_host=""
bastion_port="$DEFAULT_BASTION_PORT"
bastion_user=""
remote_port=""
registry_file="$REGISTRY_FILE_DEFAULT"
port_range_start="$PORT_RANGE_START_DEFAULT"
port_range_end="$PORT_RANGE_END_DEFAULT"
public_key_raw=""
public_key_file=""

usage() {
  cat <<EOF_USAGE
Usage: sudo $(basename "$0") --device-id <id> --bastion-host <host> [options]

Required:
  --device-id <id>          Stable device identifier (e.g., NET_STN or UUID)
  --bastion-host <host>     Public bastion domain used by devices
  --public-key <key>        SSH public key content for this device tunnel
  --public-key-file <path>  SSH public key file for this device tunnel

Optional:
  --bastion-user <user>     Per-device bastion user (default: rt-<sanitized-device-id>)
  --bastion-port <port>     SSH port devices use to connect to bastion (default: $DEFAULT_BASTION_PORT)
  --remote-port <port>      Fixed reverse tunnel port (default: auto-allocate)
  --registry-file <path>    Registry CSV path (default: $REGISTRY_FILE_DEFAULT)
  --port-start <port>       Auto-allocation range start (default: $PORT_RANGE_START_DEFAULT)
  --port-end <port>         Auto-allocation range end (default: $PORT_RANGE_END_DEFAULT)
  --version                 Print script version
  -h, --help                Show this help text
EOF_USAGE
}

fail() {
  echo "[FAILED] $*" >&2
  exit 1
}

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    fail "Run as root (sudo)."
  fi
}

sanitize_token() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9._-]/-/g; s/^-*//; s/-*$//'
}

validate_port() {
  local value="$1"
  [[ "$value" =~ ^[0-9]+$ ]] || return 1
  (( value >= 1 && value <= 65535 )) || return 1
  return 0
}

validate_bastion_user() {
  local value="$1"
  [[ "$value" =~ ^[a-z_][a-z0-9._-]{0,31}$ ]]
}

ensure_registry_file() {
  local dir
  dir="$(dirname "$registry_file")"
  mkdir -p "$dir"
  if [[ ! -f "$registry_file" ]]; then
    printf '%s\n' "$REGISTRY_HEADER" > "$registry_file"
    chmod 0640 "$registry_file"
    return 0
  fi

  local header
  header="$(head -n 1 "$registry_file" | tr -d '\r')"
  if [[ "$header" != "$REGISTRY_HEADER" ]]; then
    fail "Registry header mismatch in $registry_file"
  fi
  chmod 0640 "$registry_file"
}

registry_get_row_by_device() {
  awk -F, -v id="$device_id" 'NR > 1 && $1 == id {print; exit}' "$registry_file"
}

registry_port_in_use_by_active_excluding_device() {
  local candidate="$1"
  awk -F, -v p="$candidate" -v id="$device_id" '
    NR > 1 && $4 == "active" && $3 == p && $1 != id {found=1}
    END {exit(found ? 0 : 1)}
  ' "$registry_file"
}

registry_user_in_use_by_active_excluding_device() {
  local candidate="$1"
  awk -F, -v u="$candidate" -v id="$device_id" '
    NR > 1 && $4 == "active" && $2 == u && $1 != id {found=1}
    END {exit(found ? 0 : 1)}
  ' "$registry_file"
}

port_currently_listening() {
  local candidate="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -lnt "sport = :$candidate" 2>/dev/null | awk 'NR > 1 {print}' | grep -q .
    return $?
  fi
  return 1
}

allocate_remote_port() {
  local port
  for ((port=port_range_start; port<=port_range_end; port++)); do
    if registry_port_in_use_by_active_excluding_device "$port"; then
      continue
    fi
    if port_currently_listening "$port"; then
      continue
    fi
    echo "$port"
    return 0
  done
  return 1
}

update_or_insert_registry_row() {
  local new_row="$1"
  local tmp_file
  local registry_dir
  registry_dir="$(dirname "$registry_file")"
  tmp_file="$(mktemp "${registry_dir}/devices.csv.tmp.XXXXXX")"
  awk -F, -v id="$device_id" -v row="$new_row" '
    BEGIN { replaced=0 }
    NR == 1 { print; next }
    $1 == id {
      if (!replaced) {
        print row
        replaced=1
      }
      next
    }
    { print }
    END {
      if (!replaced) print row
    }
  ' "$registry_file" > "$tmp_file"
  chmod 0640 "$tmp_file"
  mv "$tmp_file" "$registry_file"
  chmod 0640 "$registry_file"
}

create_or_update_tunnel_user() {
  local user_home
  local no_login_shell
  local auth_keys_path
  local key_options

  no_login_shell="$(command -v nologin || true)"
  if [[ -z "$no_login_shell" ]]; then
    no_login_shell="/usr/sbin/nologin"
  fi

  if ! id -u "$bastion_user" >/dev/null 2>&1; then
    useradd --create-home --shell "$no_login_shell" "$bastion_user"
  fi

  usermod -s "$no_login_shell" "$bastion_user" >/dev/null 2>&1 || true
  usermod -U "$bastion_user" >/dev/null 2>&1 || true

  user_home="$(getent passwd "$bastion_user" | cut -d: -f6)"
  [[ -n "$user_home" ]] || fail "Unable to resolve home for user $bastion_user"
  mkdir -p "$user_home/.ssh"
  chmod 0700 "$user_home/.ssh"
  auth_keys_path="$user_home/.ssh/authorized_keys"

  key_options="restrict,port-forwarding,no-pty,no-agent-forwarding,no-X11-forwarding,permitlisten=\"127.0.0.1:${remote_port}\""
  printf '%s %s\n' "$key_options" "$public_key_raw" > "$auth_keys_path"
  chmod 0600 "$auth_keys_path"
  chown -R "$bastion_user:$bastion_user" "$user_home/.ssh"
}

load_public_key() {
  local tmp_key

  if [[ -n "$public_key_file" ]]; then
    [[ -r "$public_key_file" ]] || fail "Public key file is not readable: $public_key_file"
    public_key_raw="$(head -n 1 "$public_key_file" | tr -d '\r')"
  fi
  [[ -n "$public_key_raw" ]] || fail "Provide --public-key or --public-key-file."

  tmp_key="$(mktemp /tmp/rshake-pubkey.XXXXXX)"
  printf '%s\n' "$public_key_raw" > "$tmp_key"
  if ! ssh-keygen -lf "$tmp_key" >/dev/null 2>&1; then
    rm -f "$tmp_key"
    fail "Invalid SSH public key."
  fi
  rm -f "$tmp_key"
}

emit_device_env_snippet() {
  cat <<EOF_ENV
REMOTE_TUNNEL_ENABLED=true
REMOTE_TUNNEL_DEVICE_ID=${device_id}
REMOTE_TUNNEL_BASTION_HOST=${bastion_host}
REMOTE_TUNNEL_BASTION_PORT=${bastion_port}
REMOTE_TUNNEL_BASTION_USER=${bastion_user}
REMOTE_TUNNEL_REMOTE_PORT=${remote_port}
REMOTE_TUNNEL_LOCAL_HOST=${DEFAULT_LOCAL_HOST}
REMOTE_TUNNEL_LOCAL_PORT=${DEFAULT_LOCAL_PORT}
REMOTE_TUNNEL_KEY_PATH=${DEFAULT_KEY_PATH}
REMOTE_TUNNEL_WSS_URL=${DEFAULT_WSS_URL}
REMOTE_TUNNEL_WSS_PATH_PREFIX=${DEFAULT_WSS_PATH_PREFIX}
REMOTE_TUNNEL_STATE_FILE=/var/lib/upri-sender/remote-tunnel-state.json
EOF_ENV
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --device-id)
        device_id="${2:-}"; shift 2 ;;
      --bastion-host)
        bastion_host="${2:-}"; shift 2 ;;
      --bastion-port)
        bastion_port="${2:-}"; shift 2 ;;
      --bastion-user)
        bastion_user="${2:-}"; shift 2 ;;
      --remote-port)
        remote_port="${2:-}"; shift 2 ;;
      --public-key)
        public_key_raw="${2:-}"; shift 2 ;;
      --public-key-file)
        public_key_file="${2:-}"; shift 2 ;;
      --registry-file)
        registry_file="${2:-}"; shift 2 ;;
      --port-start)
        port_range_start="${2:-}"; shift 2 ;;
      --port-end)
        port_range_end="${2:-}"; shift 2 ;;
      --version)
        echo "$(basename "$0") $SCRIPT_VERSION"; exit 0 ;;
      -h|--help)
        usage; exit 0 ;;
      *)
        fail "Unknown option: $1" ;;
    esac
  done
}

main() {
  local sanitized_device
  local existing_row
  local existing_status
  local existing_user
  local existing_port
  local existing_created_at
  local key_fingerprint
  local created_at
  local registry_row

  parse_args "$@"
  require_root
  [[ -n "$device_id" ]] || fail "--device-id is required."
  [[ -n "$bastion_host" ]] || fail "--bastion-host is required."
  validate_port "$bastion_port" || fail "--bastion-port must be between 1 and 65535."
  [[ "$port_range_start" =~ ^[0-9]+$ ]] || fail "--port-start must be numeric."
  [[ "$port_range_end" =~ ^[0-9]+$ ]] || fail "--port-end must be numeric."
  (( port_range_start <= port_range_end )) || fail "--port-start must be <= --port-end."

  load_public_key
  ensure_registry_file

  existing_row="$(registry_get_row_by_device || true)"
  existing_status=""
  existing_user=""
  existing_port=""
  existing_created_at=""
  if [[ -n "$existing_row" ]]; then
    existing_status="$(echo "$existing_row" | awk -F, '{print $4}')"
    existing_user="$(echo "$existing_row" | awk -F, '{print $2}')"
    existing_port="$(echo "$existing_row" | awk -F, '{print $3}')"
    existing_created_at="$(echo "$existing_row" | awk -F, '{print $6}')"
  fi

  sanitized_device="$(sanitize_token "$device_id")"
  [[ -n "$sanitized_device" ]] || fail "Unable to derive a valid bastion user from device ID."

  if [[ -z "$bastion_user" ]]; then
    if [[ "$existing_status" == "active" && -n "$existing_user" ]]; then
      bastion_user="$existing_user"
    else
      bastion_user="rt-${sanitized_device}"
    fi
  fi
  validate_bastion_user "$bastion_user" || fail "Invalid --bastion-user value: $bastion_user"

  if [[ -n "$remote_port" ]]; then
    validate_port "$remote_port" || fail "--remote-port must be between 1 and 65535."
  elif [[ "$existing_status" == "active" && -n "$existing_port" ]]; then
    remote_port="$existing_port"
  else
    remote_port="$(allocate_remote_port)" || fail "No free port in range $port_range_start-$port_range_end"
  fi

  if [[ "$existing_status" == "active" ]]; then
    if [[ -n "$existing_user" && "$bastion_user" != "$existing_user" ]]; then
      fail "Device already active with bastion user $existing_user; refusing reassignment."
    fi
    if [[ -n "$existing_port" && "$remote_port" != "$existing_port" ]]; then
      fail "Device already active on remote port $existing_port; refusing reassignment."
    fi
  fi

  if registry_user_in_use_by_active_excluding_device "$bastion_user"; then
    fail "Bastion user already mapped to another active device: $bastion_user"
  fi
  if registry_port_in_use_by_active_excluding_device "$remote_port"; then
    fail "Remote port already assigned in registry: $remote_port"
  fi
  if [[ "$existing_port" != "$remote_port" ]] && port_currently_listening "$remote_port"; then
    fail "Remote port is already listening on bastion: $remote_port"
  fi

  create_or_update_tunnel_user
  key_fingerprint="$(printf '%s\n' "$public_key_raw" | ssh-keygen -lf - | awk '{print $2}')"

  if [[ -n "$existing_created_at" ]]; then
    created_at="$existing_created_at"
  else
    created_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  fi

  registry_row="${device_id},${bastion_user},${remote_port},active,${key_fingerprint},${created_at},"
  update_or_insert_registry_row "$registry_row"

  echo "[OK] Registered device $device_id -> $bastion_user on reverse port $remote_port"
  echo
  echo "# Place these values in /etc/upri/sender-remote-tunnel.env on the device:"
  emit_device_env_snippet
}

main "$@"
