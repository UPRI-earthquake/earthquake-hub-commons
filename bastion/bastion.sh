#!/usr/bin/env bash
set -euo pipefail

SCRIPT_VERSION="2026-03-19.1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'EOF_USAGE'
Usage: bastion.sh <COMMAND> [args...]

Commands:
  SETUP_HOST      One-time bastion bootstrap (installs scripts, launcher, tunnel-admin, sudoers, ssh material)
  REGISTER_DEVICE Register/update a device tunnel mapping
  REVOKE_DEVICE   Revoke a device tunnel mapping
  LIST_DEVICES    List registered devices
  RESOLVE_DEVICE  Resolve one device mapping state (machine-readable)
  CONNECT_DEVICE  Resolve device port then run SSH to device (equivalent to ssh -p <port> <user>@127.0.0.1)
  VERSION         Print version
  HELP            Show this help

Examples:
  sudo ./bastion.sh SETUP_HOST
  sudo ./bastion.sh REGISTER_DEVICE --device-id AM_RF47F --bastion-host earthquake.science.upd.edu.ph --public-key-file /etc/upri/remote-tunnel/id_ed25519.pub
  sudo ./bastion.sh REVOKE_DEVICE --device-id AM_RF47F
  sudo ./bastion.sh REVOKE_DEVICE --device-id AM_RF47F --terminate-active
  ./bastion.sh LIST_DEVICES --active-only
  ./bastion.sh RESOLVE_DEVICE --device-id AM_RF47F
  ./bastion.sh CONNECT_DEVICE --device-id AM_RF47F
EOF_USAGE
}

fail() {
  echo "[FAILED] $*" >&2
  exit 1
}

require_script() {
  local path="$1"
  [[ -x "$path" ]] || fail "Missing executable script: $path"
}

main() {
  local cmd="${1:-HELP}"
  shift || true

  case "$cmd" in
    SETUP_HOST|setup-host|SETUP|setup)
      require_script "$SCRIPT_DIR/setup-host.sh"
      exec "$SCRIPT_DIR/setup-host.sh" "$@"
      ;;
    REGISTER_DEVICE|register-device|REGISTER|register)
      require_script "$SCRIPT_DIR/register-device.sh"
      exec "$SCRIPT_DIR/register-device.sh" "$@"
      ;;
    REVOKE_DEVICE|revoke-device|REVOKE|revoke)
      require_script "$SCRIPT_DIR/revoke-device.sh"
      exec "$SCRIPT_DIR/revoke-device.sh" "$@"
      ;;
    LIST_DEVICES|list-devices|LIST|list)
      require_script "$SCRIPT_DIR/list-devices.sh"
      exec "$SCRIPT_DIR/list-devices.sh" "$@"
      ;;
    RESOLVE_DEVICE|resolve-device|RESOLVE|resolve)
      require_script "$SCRIPT_DIR/resolve-device.sh"
      exec "$SCRIPT_DIR/resolve-device.sh" "$@"
      ;;
    CONNECT_DEVICE|connect-device|CONNECT|connect)
      require_script "$SCRIPT_DIR/connect-device.sh"
      exec "$SCRIPT_DIR/connect-device.sh" "$@"
      ;;
    VERSION|--version|-v)
      echo "$(basename "$0") $SCRIPT_VERSION"
      ;;
    HELP|help|-h|--help)
      usage
      ;;
    *)
      fail "Unknown command: $cmd (run with HELP)"
      ;;
  esac
}

main "$@"
