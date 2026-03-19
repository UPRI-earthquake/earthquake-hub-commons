#!/usr/bin/env bash
set -euo pipefail

SCRIPT_VERSION="2026-03-19.1"
REGISTRY_FILE_DEFAULT="/etc/upri/rshake-tunnels/devices.csv"

device_id=""
registry_file="$REGISTRY_FILE_DEFAULT"
json_output="false"

usage() {
  cat <<EOF_USAGE
Usage: $(basename "$0") --device-id <id> [options]

Required:
  --device-id <id>          Device ID as stored in registry

Options:
  --registry-file <path>    Registry CSV path (default: $REGISTRY_FILE_DEFAULT)
  --json                    Emit JSON output instead of KEY=VALUE lines
  --version                 Print script version
  -h, --help                Show help

Examples:
  $(basename "$0") --device-id AM_RF47F
  $(basename "$0") --device-id AM_RF47F --json
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

listener_state() {
  local port="$1"

  if ! validate_port "$port"; then
    echo "n/a"
    return 0
  fi

  if ! command -v ss >/dev/null 2>&1; then
    echo "unknown"
    return 0
  fi

  if ss -lnt "sport = :$port" 2>/dev/null | awk 'NR > 1 {print}' | grep -Eq "127\\.0\\.0\\.1:${port}\\b"; then
    echo "up"
  else
    echo "down"
  fi
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --device-id)
        device_id="${2:-}"; shift 2 ;;
      --registry-file)
        registry_file="${2:-}"; shift 2 ;;
      --json)
        json_output="true"; shift ;;
      --version)
        echo "$(basename "$0") $SCRIPT_VERSION"; exit 0 ;;
      -h|--help)
        usage; exit 0 ;;
      *)
        fail "Unknown option: $1" ;;
    esac
  done

  [[ -n "$device_id" ]] || fail "--device-id is required."
  [[ -r "$registry_file" ]] || fail "Registry file missing or not readable: $registry_file"
}

main() {
  local row
  local bastion_user
  local remote_port
  local status
  local key_fingerprint
  local created_at
  local revoked_at
  local listener

  parse_args "$@"

  row="$(awk -F, -v id="$device_id" 'NR > 1 && $1 == id {print; exit}' "$registry_file")"
  [[ -n "$row" ]] || fail "Device not found in registry: $device_id"

  bastion_user="$(echo "$row" | awk -F, '{print $2}')"
  remote_port="$(echo "$row" | awk -F, '{print $3}')"
  status="$(echo "$row" | awk -F, '{print $4}')"
  key_fingerprint="$(echo "$row" | awk -F, '{print $5}')"
  created_at="$(echo "$row" | awk -F, '{print $6}')"
  revoked_at="$(echo "$row" | awk -F, '{print $7}')"
  listener="$(listener_state "$remote_port")"

  if [[ "$json_output" == "true" ]]; then
    printf '{"deviceId":"%s","bastionUser":"%s","remotePort":%s,"status":"%s","listener":"%s","keyFingerprint":"%s","createdAt":"%s","revokedAt":"%s"}\n' \
      "$device_id" \
      "$bastion_user" \
      "$remote_port" \
      "$status" \
      "$listener" \
      "$key_fingerprint" \
      "$created_at" \
      "$revoked_at"
    return 0
  fi

  cat <<EOF_OUT
DEVICE_ID=${device_id}
BASTION_USER=${bastion_user}
REMOTE_PORT=${remote_port}
STATUS=${status}
LISTENER=${listener}
KEY_FINGERPRINT=${key_fingerprint}
CREATED_AT=${created_at}
REVOKED_AT=${revoked_at}
EOF_OUT
}

main "$@"
