#!/usr/bin/env bash
# Nginx syntax validation for Earthquake Hub Commons.
#
# Runs `nginx -t` on each tracked Nginx config directory inside the same nginx
# image that docker-compose.yml uses. It needs no real certificates, secrets or
# running services:
#   - a throwaway self-signed certificate is placed at every ssl_certificate
#     and ssl_certificate_key path the config names;
#   - every proxy_pass host is mapped to 127.0.0.1, because nginx resolves
#     upstream names when it loads the config;
#   - the container runs with no network access.
#
# Usage (from anywhere in the repository):
#   bash .github/scripts/validate-nginx.sh [conf-dir ...]
set -euo pipefail
export MSYS_NO_PATHCONV=1 # Git Bash on Windows: keep container paths as written.

cd "$(dirname "${BASH_SOURCE[0]}")/../.."

# Certbot's shared TLS settings; Compose mounts this directory at /etc/nginx/ssl.
SSL_SHARED=https_data/certbot/conf
NGINX_IMAGE="${NGINX_IMAGE:-$(grep -m1 -oE 'nginx:[A-Za-z0-9._-]+' docker-compose.yml)}"

if [[ $# -gt 0 ]]; then
  CONF_DIRS=("$@")
else
  CONF_DIRS=(https_data/nginx.d https_data/nginx.dep-test.d)
fi

host_path() {
  if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s\n' "$1"; fi
}

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# One throwaway key pair, copied to every certificate path the configs name.
# host_path: on Windows the openssl found first may be a native build that cannot open /tmp paths.
if ! openssl_out="$(openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=nginx-ci" \
  -keyout "$(host_path "$work/key.pem")" -out "$(host_path "$work/cert.pem")" 2>&1)"; then
  printf '%s\n' "$openssl_out" >&2
  echo "::error::could not create the throwaway certificate with openssl"
  exit 1
fi

echo "Using ${NGINX_IMAGE}"
failures=0
for dir in "${CONF_DIRS[@]}"; do
  echo "== nginx -t: ${dir}"
  shopt -s nullglob
  confs=("$dir"/*.conf)
  shopt -u nullglob
  if [[ ${#confs[@]} -eq 0 ]]; then
    echo "::error::${dir}: no .conf files found"
    failures=$((failures + 1))
    continue
  fi

  ssl="$work/ssl-$(basename "$dir")"
  mkdir -p "$ssl"
  cp "$SSL_SHARED/options-ssl-nginx.conf" "$SSL_SHARED/ssl-dhparams.pem" "$ssl/"

  dir_ok=1
  while read -r directive path; do
    rel=${path#/etc/nginx/ssl/}
    if [[ $rel == "$path" ]]; then
      echo "::error::${dir}: ${directive} ${path} is outside /etc/nginx/ssl, so this check cannot provide it"
      dir_ok=0
      continue
    fi
    mkdir -p "$ssl/$(dirname "$rel")"
    if [[ $directive == ssl_certificate ]]; then
      cp "$work/cert.pem" "$ssl/$rel"
    else
      cp "$work/key.pem" "$ssl/$rel"
    fi
  done < <(sed -nE 's/^[[:space:]]*(ssl_certificate(_key)?)[[:space:]]+([^;[:space:]]+);.*/\1 \3/p' "${confs[@]}" | sort -u)

  add_hosts=()
  while read -r host; do
    add_hosts+=(--add-host "${host}:127.0.0.1")
  done < <(sed -nE 's#^[[:space:]]*proxy_pass[[:space:]]+https?://([^:/;[:space:]]+).*#\1#p' "${confs[@]}" | sort -u)

  # --entrypoint skips the image's start-up scripts, which only matter for a running server.
  if [[ $dir_ok -eq 1 ]] && docker run --rm --network none "${add_hosts[@]}" \
    -v "$(host_path "$PWD/$dir"):/etc/nginx/conf.d:ro" \
    -v "$(host_path "$ssl"):/etc/nginx/ssl:ro" \
    --entrypoint nginx "$NGINX_IMAGE" -t; then
    echo "   ok"
  else
    echo "::error::nginx -t failed for ${dir}"
    failures=$((failures + 1))
  fi
done

if [[ $failures -gt 0 ]]; then
  echo "Nginx validation: ${failures} config director(ies) failed"
  exit 1
fi
echo "Nginx validation: all checks passed"
