#!/usr/bin/env bash
set -euo pipefail

SCRIPT_VERSION="2026-03-12.1"
REGISTRY_FILE_DEFAULT="/etc/upri/rshake-tunnels/devices.csv"
registry_file="$REGISTRY_FILE_DEFAULT"

usage() {
  cat <<EOF_USAGE
Usage: $(basename "$0") [--registry-file <path>] [--active-only]
       $(basename "$0") --version
EOF_USAGE
}

fail() {
  echo "[FAILED] $*" >&2
  exit 1
}

active_only="false"

tunnel_listener_state() {
  local port="$1"
  if [[ ! "$port" =~ ^[0-9]+$ ]]; then
    echo "n/a"
    return 0
  fi
  if command -v ss >/dev/null 2>&1; then
    if ss -lnt "sport = :$port" 2>/dev/null | awk 'NR > 1 {print}' | grep -Eq "127\\.0\\.0\\.1:${port}\\b"; then
      echo "up"
      return 0
    fi
    echo "down"
    return 0
  fi
  echo "unknown"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --registry-file)
        registry_file="${2:-}"; shift 2 ;;
      --active-only)
        active_only="true"; shift ;;
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
  local device_id
  local bastion_user
  local remote_port
  local status
  local listener

  parse_args "$@"
  [[ -r "$registry_file" ]] || fail "Registry file missing or not readable: $registry_file (run with sudo or grant read access)"

  printf "%-28s %-24s %-12s %-10s %-8s\n" "DEVICE_ID" "BASTION_USER" "REMOTE_PORT" "STATUS" "LISTENER"
  printf "%-28s %-24s %-12s %-10s %-8s\n" "---------" "------------" "-----------" "------" "--------"
  while IFS= read -r row; do
    [[ -n "$row" ]] || continue
    device_id="$(echo "$row" | awk -F, '{print $1}')"
    bastion_user="$(echo "$row" | awk -F, '{print $2}')"
    remote_port="$(echo "$row" | awk -F, '{print $3}')"
    status="$(echo "$row" | awk -F, '{print $4}')"

    if [[ "$active_only" == "true" && "$status" != "active" ]]; then
      continue
    fi

    listener="$(tunnel_listener_state "$remote_port")"
    printf "%-28s %-24s %-12s %-10s %-8s\n" "$device_id" "$bastion_user" "$remote_port" "$status" "$listener"
  done < <(awk -F, 'NR > 1 {print}' "$registry_file")
}

main "$@"
