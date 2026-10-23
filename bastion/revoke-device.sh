#!/usr/bin/env bash
set -euo pipefail

SCRIPT_VERSION="2026-03-17.3"
REGISTRY_FILE_DEFAULT="/etc/upri/rshake-tunnels/devices.csv"

device_id=""
registry_file="$REGISTRY_FILE_DEFAULT"
terminate_active="false"

usage() {
  cat <<EOF_USAGE
Usage: sudo $(basename "$0") --device-id <id> [--registry-file <path>] [--terminate-active]
       $(basename "$0") --version
EOF_USAGE
}

fail() {
  echo "[FAILED] $*" >&2
  exit 1
}

warn() {
  echo "[WARN] $*" >&2
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

registry_get_row_by_device() {
  awk -F, -v id="$device_id" 'NR > 1 && $1 == id {print; exit}' "$registry_file"
}

update_registry_row() {
  local new_row="$1"
  local tmp_file
  local registry_dir
  registry_dir="$(dirname "$registry_file")"
  tmp_file="$(mktemp "${registry_dir}/devices.csv.tmp.XXXXXX")"
  awk -F, -v id="$device_id" -v row="$new_row" '
    NR == 1 { print; next }
    $1 == id { print row; next }
    { print }
  ' "$registry_file" > "$tmp_file"
  chmod 0640 "$tmp_file"
  mv "$tmp_file" "$registry_file"
  chmod 0640 "$registry_file"
}

disable_tunnel_user_key() {
  local user_name="$1"
  local user_home
  local auth_keys_path

  if ! id -u "$user_name" >/dev/null 2>&1; then
    return 0
  fi

  user_home="$(getent passwd "$user_name" | cut -d: -f6)"
  if [[ -z "$user_home" ]]; then
    return 0
  fi

  auth_keys_path="$user_home/.ssh/authorized_keys"
  if [[ -f "$auth_keys_path" ]]; then
    : > "$auth_keys_path"
    chown "$user_name:$user_name" "$auth_keys_path"
    chmod 0600 "$auth_keys_path"
  fi

  usermod -L "$user_name" >/dev/null 2>&1 || true
}

terminate_active_listener_by_port() {
  local port="$1"
  local pid=""
  local killed=0
  local failed=0
  local check_line=""
  local -a pids=()

  if ! validate_port "$port"; then
    warn "Skipping active termination; invalid port: $port"
    return 1
  fi

  if ! command -v ss >/dev/null 2>&1; then
    warn "Skipping active termination for port $port; 'ss' not found."
    return 1
  fi

  mapfile -t pids < <(ss -lntp "sport = :$port" 2>/dev/null \
    | sed -n 's/.*pid=\([0-9][0-9]*\).*/\1/p' \
    | awk 'NF' \
    | sort -u)

  if [[ ${#pids[@]} -eq 0 ]]; then
    echo "[OK] No active listener found on port $port."
    return 0
  fi

  for pid in "${pids[@]}"; do
    [[ -n "$pid" ]] || continue
    if kill -TERM "$pid" >/dev/null 2>&1; then
      killed=$((killed + 1))
    else
      failed=$((failed + 1))
      continue
    fi

    sleep 1
    if kill -0 "$pid" >/dev/null 2>&1; then
      kill -KILL "$pid" >/dev/null 2>&1 || true
      sleep 1
      if kill -0 "$pid" >/dev/null 2>&1; then
        failed=$((failed + 1))
      fi
    fi
  done

  check_line="$(ss -lnt "sport = :$port" 2>/dev/null | awk 'NR > 1 {print; exit}')"
  if [[ -n "$check_line" ]]; then
    warn "Port $port still has an active listener after termination attempt."
    return 1
  fi

  if [[ $failed -gt 0 ]]; then
    warn "Termination on port $port completed with partial failures (killed=$killed failed=$failed)."
    return 1
  fi

  echo "[OK] Terminated active listener(s) on port $port (count=$killed)."
  return 0
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --device-id)
        device_id="${2:-}"; shift 2 ;;
      --registry-file)
        registry_file="${2:-}"; shift 2 ;;
      --terminate-active)
        terminate_active="true"; shift ;;
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
  local row
  local user_name
  local remote_port
  local status
  local key_fingerprint
  local created_at
  local revoked_at
  local updated_row

  parse_args "$@"
  require_root
  [[ -n "$device_id" ]] || fail "--device-id is required."
  [[ -r "$registry_file" ]] || fail "Registry file not found: $registry_file"

  row="$(registry_get_row_by_device || true)"
  [[ -n "$row" ]] || fail "Device not found in registry: $device_id"

  user_name="$(echo "$row" | awk -F, '{print $2}')"
  remote_port="$(echo "$row" | awk -F, '{print $3}')"
  status="$(echo "$row" | awk -F, '{print $4}')"
  key_fingerprint="$(echo "$row" | awk -F, '{print $5}')"
  created_at="$(echo "$row" | awk -F, '{print $6}')"

  if [[ "$status" != "active" ]]; then
    echo "[OK] Device $device_id is already revoked."
    exit 0
  fi

  disable_tunnel_user_key "$user_name"
  revoked_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  updated_row="${device_id},${user_name},${remote_port},revoked,${key_fingerprint},${created_at},${revoked_at}"
  update_registry_row "$updated_row"

  if [[ "$terminate_active" == "true" ]]; then
    terminate_active_listener_by_port "$remote_port" || warn "Revoke completed but active listener termination encountered issues on port $remote_port."
  fi

  echo "[OK] Revoked device $device_id (user=$user_name, port=$remote_port)"
}

main "$@"
