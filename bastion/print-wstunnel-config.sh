#!/usr/bin/env bash
set -euo pipefail

SCRIPT_VERSION="2026-06-30.1"
PATH_BASE_DEFAULT="api/ws-tunnel"
SECRET_BYTES_DEFAULT=20

path_base="$PATH_BASE_DEFAULT"
secret=""

usage() {
  cat <<EOF_USAGE
Usage: $(basename "$0") [options]

Options:
  --secret <value>      Use an existing WSTunnel path secret instead of generating one
  --path-base <path>    Public tunnel path base (default: $PATH_BASE_DEFAULT)
  --version             Print script version
  -h, --help            Show help

Examples:
  $(basename "$0")
  $(basename "$0") --secret f0cc4f32294d20d243c9bb737a0bffe50bfb4a05
EOF_USAGE
}

fail() {
  echo "[FAILED] $*" >&2
  exit 1
}

generate_secret() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex "$SECRET_BYTES_DEFAULT"
    return 0
  fi

  if [[ -r /dev/urandom ]] && command -v od >/dev/null 2>&1; then
    od -An -N "$SECRET_BYTES_DEFAULT" -tx1 /dev/urandom | tr -d ' \n'
    printf '\n'
    return 0
  fi

  fail "Unable to generate a secret; install openssl or pass --secret."
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --secret)
        secret="${2:-}"; shift 2 ;;
      --path-base)
        path_base="${2:-}"; shift 2 ;;
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
  local prefix

  parse_args "$@"

  path_base="${path_base#/}"
  path_base="${path_base%/}"
  [[ -n "$path_base" ]] || fail "--path-base cannot be empty."
  [[ "$path_base" != *[[:space:]]* ]] || fail "--path-base must not contain whitespace."

  if [[ -z "$secret" ]]; then
    secret="$(generate_secret)"
  fi
  [[ "$secret" =~ ^[A-Za-z0-9._~-]+$ ]] || fail "--secret may only contain URL path-safe characters: A-Z a-z 0-9 . _ ~ -"

  prefix="${path_base}/${secret}"

  cat <<EOF_OUT
Suggested WSTunnel path secret:
  $secret

You may use this generated secret or generate your own. Keep the same prefix in the backend environment and nginx tunnel location:

.env:
  TUNNEL_WSS_PATH_PREFIX=$prefix

nginx:
  location ^~ /${prefix}/ {

wstunnel-restrictions.yaml:
  Keep match as !Any and restrict only the allowed reverse tunnel destination:
    match:
      - !Any
    allow:
      - !ReverseTunnel
        protocol:
          - Tcp
        port:
          - 22000..22999
        cidr:
          - 127.0.0.1/32
          - ::1/128
EOF_OUT
}

main "$@"
