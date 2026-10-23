#!/usr/bin/env bash
set -euo pipefail

SCRIPT_VERSION="2026-06-26.1"
KEY_FILE_DEFAULT="/etc/ssh/ssh_host_ed25519_key.pub"

public_bastion_host=""
key_file="$KEY_FILE_DEFAULT"

usage() {
  cat <<EOF_USAGE
Usage: $(basename "$0") --public-bastion-host <host> [options]

Required:
  --public-bastion-host <host>  Public bastion host returned to sender devices

Options:
  --key-file <path>             SSH host public key file (default: $KEY_FILE_DEFAULT)
  --version                     Print script version
  -h, --help                    Show help

Examples:
  $(basename "$0") --public-bastion-host earthquake.up.edu.ph
EOF_USAGE
}

fail() {
  echo "[FAILED] $*" >&2
  exit 1
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --public-bastion-host|--host)
        public_bastion_host="${2:-}"; shift 2 ;;
      --key-file)
        key_file="${2:-}"; shift 2 ;;
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
  local key_type
  local key_data

  parse_args "$@"

  [[ -n "$public_bastion_host" ]] || fail "--public-bastion-host is required."
  [[ "$public_bastion_host" != *[[:space:]]* ]] || fail "--public-bastion-host must not contain whitespace."
  [[ "$public_bastion_host" != *"/"* ]] || fail "--public-bastion-host must be a hostname, not a URL."
  [[ -r "$key_file" ]] || fail "SSH host public key is not readable: $key_file"

  read -r key_type key_data _ < "$key_file"
  [[ -n "${key_type:-}" && -n "${key_data:-}" ]] || fail "SSH host public key is invalid: $key_file"
  [[ "$key_type" == ssh-* ]] || fail "SSH host public key type is invalid: $key_type"

  printf 'TUNNEL_BASTION_HOST_KEY=%s %s %s\n' "$public_bastion_host" "$key_type" "$key_data"
}

main "$@"
