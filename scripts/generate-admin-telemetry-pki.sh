#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $0 [--force] [output-directory]" >&2
  echo "Default output: ./secrets/admin-telemetry" >&2
}

force=false
if [[ "${1:-}" == "--force" ]]; then
  force=true
  shift
fi
if [[ $# -gt 1 ]]; then
  usage
  exit 2
fi

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
compose_dir="$(cd -- "${script_dir}/.." && pwd)"
output_root="${1:-${compose_dir}/secrets/admin-telemetry}"
server_dir="${output_root}/server"
client_dir="${output_root}/client"
issuer_dir="${output_root}/issuer"

command -v openssl >/dev/null 2>&1 || {
  echo "openssl is required." >&2
  exit 1
}

artifacts=(
  "${server_dir}/ca.crt" "${server_dir}/tls.crt" "${server_dir}/tls.key"
  "${client_dir}/ca.crt" "${client_dir}/tls.crt" "${client_dir}/tls.key"
  "${issuer_dir}/ca.crt" "${issuer_dir}/ca.key"
)
for artifact in "${artifacts[@]}"; do
  if [[ -e "${artifact}" && "${force}" != true ]]; then
    echo "Refusing to overwrite existing PKI artifact: ${artifact}" >&2
    echo "Use --force only during a coordinated certificate rotation." >&2
    exit 1
  fi
done

mkdir -p -- "${server_dir}" "${client_dir}" "${issuer_dir}"
umask 077
tmp_dir="$(mktemp -d)"
cleanup() {
  case "${tmp_dir}" in
    /tmp/tmp.*) rm -r -- "${tmp_dir}" ;;
    *) echo "Refusing unexpected temporary-directory cleanup: ${tmp_dir}" >&2 ;;
  esac
}
trap cleanup EXIT

openssl genrsa -out "${tmp_dir}/ca.key" 3072
openssl req -x509 -new -sha256 -days 3650 \
  -key "${tmp_dir}/ca.key" \
  -subj "/CN=EarthquakeHub Admin Telemetry CA" \
  -out "${tmp_dir}/ca.crt"

openssl genrsa -out "${tmp_dir}/server.key" 3072
openssl req -new -sha256 \
  -key "${tmp_dir}/server.key" \
  -subj "/CN=admin-backend" \
  -out "${tmp_dir}/server.csr"
printf '%s\n' \
  'basicConstraints=critical,CA:FALSE' \
  'keyUsage=critical,digitalSignature,keyEncipherment' \
  'extendedKeyUsage=serverAuth' \
  'subjectAltName=DNS:admin-backend' > "${tmp_dir}/server.ext"
openssl x509 -req -sha256 -days 397 \
  -in "${tmp_dir}/server.csr" \
  -CA "${tmp_dir}/ca.crt" \
  -CAkey "${tmp_dir}/ca.key" \
  -CAcreateserial \
  -extfile "${tmp_dir}/server.ext" \
  -out "${tmp_dir}/server.crt"

openssl genrsa -out "${tmp_dir}/client.key" 3072
openssl req -new -sha256 \
  -key "${tmp_dir}/client.key" \
  -subj "/CN=ehub-backend" \
  -out "${tmp_dir}/client.csr"
printf '%s\n' \
  'basicConstraints=critical,CA:FALSE' \
  'keyUsage=critical,digitalSignature,keyEncipherment' \
  'extendedKeyUsage=clientAuth' \
  'subjectAltName=URI:spiffe://earthquake-hub/ehub-backend' > "${tmp_dir}/client.ext"
openssl x509 -req -sha256 -days 397 \
  -in "${tmp_dir}/client.csr" \
  -CA "${tmp_dir}/ca.crt" \
  -CAkey "${tmp_dir}/ca.key" \
  -CAcreateserial \
  -extfile "${tmp_dir}/client.ext" \
  -out "${tmp_dir}/client.crt"

install -m 0644 "${tmp_dir}/ca.crt" "${server_dir}/ca.crt"
install -m 0644 "${tmp_dir}/server.crt" "${server_dir}/tls.crt"
install -m 0600 "${tmp_dir}/server.key" "${server_dir}/tls.key"
install -m 0644 "${tmp_dir}/ca.crt" "${client_dir}/ca.crt"
install -m 0644 "${tmp_dir}/client.crt" "${client_dir}/tls.crt"
install -m 0600 "${tmp_dir}/client.key" "${client_dir}/tls.key"
install -m 0644 "${tmp_dir}/ca.crt" "${issuer_dir}/ca.crt"
install -m 0600 "${tmp_dir}/ca.key" "${issuer_dir}/ca.key"

openssl verify -CAfile "${issuer_dir}/ca.crt" "${server_dir}/tls.crt" "${client_dir}/tls.crt"
openssl x509 -in "${server_dir}/tls.crt" -noout -checkend 2592000 >/dev/null
openssl x509 -in "${client_dir}/tls.crt" -noout -checkend 2592000 >/dev/null

echo "Generated admin telemetry mTLS material under ${output_root}."
echo "Move ${issuer_dir}/ca.key to protected offline storage after deployment."
echo "Recreate admin-backend and ehub-backend together after certificate rotation."
