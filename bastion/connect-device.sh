#!/usr/bin/env bash
set -euo pipefail

SCRIPT_VERSION="2026-03-17.1"
REGISTRY_FILE_DEFAULT="/etc/upri/rshake-tunnels/devices.csv"
SSH_USER_DEFAULT="${TUNNEL_DEVICE_SSH_USER:-myshake}"
SSH_HOST_DEFAULT="${TUNNEL_DEVICE_SSH_HOST:-127.0.0.1}"
SSH_BIN_DEFAULT="${SSH_BIN:-ssh}"

device_id=""
registry_file="$REGISTRY_FILE_DEFAULT"
ssh_user="$SSH_USER_DEFAULT"
ssh_host="$SSH_HOST_DEFAULT"
ssh_bin="$SSH_BIN_DEFAULT"
dry_run="false"
allow_non_active="false"
skip_listener_check="false"
declare -a passthrough_ssh_args
passthrough_ssh_args=()

usage() {
  cat <<EOF_USAGE
Usage: $(basename "$0") --device-id <id> [options] [-- <ssh args...>]

Required:
  --device-id <id>          Device ID as stored in registry

Options:
  --ssh-user <user>         Target device ssh user (default: $SSH_USER_DEFAULT)
  --ssh-host <host>         Local relay host (default: $SSH_HOST_DEFAULT)
  --registry-file <path>    Registry CSV path (default: $REGISTRY_FILE_DEFAULT)
  --dry-run                 Print resolved ssh command without executing it
  --allow-non-active        Allow connect even if status is not "active"
  --skip-listener-check     Skip localhost listener check before SSH
  --version                 Print script version
  -h, --help                Show help

Examples:
  $(basename "$0") --device-id AM_RF47F
  $(basename "$0") --device-id AM_RF47F --ssh-user myshake
  $(basename "$0") --device-id AM_RF47F -- -o StrictHostKeyChecking=no
EOF_USAGE
}

fail() {
  echo "[FAILED] $*" >&2
  exit 1
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

listener_is_up() {
  local port="$1"
  if ! command -v ss >/dev/null 2>&1; then
    return 0
  fi
  ss -lnt "sport = :$port" 2>/dev/null | awk 'NR > 1 {print}' | grep -Eq "127\\.0\\.0\\.1:${port}\\b"
}

print_cmd() {
  local arg
  for arg in "$@"; do
    printf '%q ' "$arg"
  done
  printf '\n'
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --device-id)
        device_id="${2:-}"; shift 2 ;;
      --ssh-user)
        ssh_user="${2:-}"; shift 2 ;;
      --ssh-host)
        ssh_host="${2:-}"; shift 2 ;;
      --registry-file)
        registry_file="${2:-}"; shift 2 ;;
      --dry-run)
        dry_run="true"; shift ;;
      --allow-non-active)
        allow_non_active="true"; shift ;;
      --skip-listener-check)
        skip_listener_check="true"; shift ;;
      --version)
        echo "$(basename "$0") $SCRIPT_VERSION"; exit 0 ;;
      -h|--help)
        usage; exit 0 ;;
      --)
        shift
        passthrough_ssh_args=("$@")
        break
        ;;
      *)
        fail "Unknown option: $1"
        ;;
    esac
  done

  [[ -n "$device_id" ]] || fail "--device-id is required."
  [[ -r "$registry_file" ]] || fail "Registry file missing or not readable: $registry_file (run with sudo or adjust permissions)."
  [[ -n "$ssh_user" ]] || fail "--ssh-user cannot be empty."
  [[ -n "$ssh_host" ]] || fail "--ssh-host cannot be empty."
  command -v "$ssh_bin" >/dev/null 2>&1 || fail "SSH client not found: $ssh_bin"
}

main() {
  local row
  local remote_port
  local status
  local cmd

  parse_args "$@"

  row="$(registry_get_row_by_device || true)"
  [[ -n "$row" ]] || fail "Device not found in registry: $device_id"

  remote_port="$(echo "$row" | awk -F, '{print $3}')"
  status="$(echo "$row" | awk -F, '{print $4}')"
  validate_port "$remote_port" || fail "Invalid remote port in registry for $device_id: $remote_port"

  if [[ "$allow_non_active" != "true" && "$status" != "active" ]]; then
    fail "Device $device_id is not active (status=$status). Use --allow-non-active to bypass."
  fi

  if [[ "$skip_listener_check" != "true" ]] && ! listener_is_up "$remote_port"; then
    fail "No listener on 127.0.0.1:$remote_port (device likely offline). Use --skip-listener-check to bypass."
  fi

  cmd=("$ssh_bin" "-p" "$remote_port" "${ssh_user}@${ssh_host}")
  if (( ${#passthrough_ssh_args[@]} > 0 )); then
    cmd+=("${passthrough_ssh_args[@]}")
  fi

  if [[ "$dry_run" == "true" ]]; then
    print_cmd "${cmd[@]}"
    return 0
  fi

  echo "[INFO] Executing: $(print_cmd "${cmd[@]}")" >&2
  exec "${cmd[@]}"
}

main "$@"
