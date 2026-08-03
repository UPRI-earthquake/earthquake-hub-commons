#!/usr/bin/env bash
# Verify the admin console as it is exposed through the dep-test nginx proxy.
#
# Usage:
#   ADMIN_SMOKE_IDENTIFIER=... ADMIN_SMOKE_PASSWORD=... \
#     ./scripts/admin-dep-test-smoke.sh
#
# The supplied account must already have the `admin` role in the isolated
# dep-test MongoDB data. This script never creates accounts or changes data.

set -euo pipefail

base_url="${ADMIN_SMOKE_BASE_URL:-https://ehub.local}"
identifier="${ADMIN_SMOKE_IDENTIFIER:?Set ADMIN_SMOKE_IDENTIFIER to a dep-test admin username or email.}"
password="${ADMIN_SMOKE_PASSWORD:?Set ADMIN_SMOKE_PASSWORD for the dep-test admin account.}"
cookie_jar="$(mktemp)"
headers_file="$(mktemp)"
trap 'rm -f "$cookie_jar" "$headers_file"' EXIT

request_status() {
  local method="$1"
  local path="$2"
  local expected="$3"
  shift 3
  local actual
  local -a curl_method=()
  if [[ "$method" == 'HEAD' ]]; then
    curl_method=(--head)
  else
    curl_method=(--request "$method")
  fi
  actual="$(curl --silent --show-error --insecure --output /dev/null --write-out '%{http_code}' \
    "${curl_method[@]}" --cookie "$cookie_jar" --cookie-jar "$cookie_jar" "$@" "${base_url}${path}")"
  if [[ "$actual" != "$expected" ]]; then
    printf 'FAIL %s %s: expected %s, got %s\n' "$method" "$path" "$expected" "$actual" >&2
    exit 1
  fi
  printf 'PASS %s %s -> %s\n' "$method" "$path" "$actual"
}

printf 'Checking dep-test admin proxy at %s\n' "$base_url"
request_status HEAD /admin/ 200
request_status GET /api/admin/profile 401

login_status="$(curl --silent --show-error --insecure --output /dev/null --dump-header "$headers_file" \
  --write-out '%{http_code}' --request POST --cookie-jar "$cookie_jar" \
  --header 'Content-Type: application/json' \
  --data "{\"identifier\":\"${identifier}\",\"password\":\"${password}\"}" \
  "${base_url}/api/admin/authenticate")"
[[ "$login_status" == '200' ]] || { printf 'FAIL POST /api/admin/authenticate: expected 200, got %s\n' "$login_status" >&2; exit 1; }
rg --ignore-case --quiet '^set-cookie: accessToken=' "$headers_file" && rg --ignore-case --quiet '^set-cookie: refreshToken=' "$headers_file" \
  || { echo 'FAIL login did not issue accessToken and refreshToken cookies' >&2; exit 1; }
printf 'PASS POST /api/admin/authenticate -> 200 (session cookies issued)\n'

request_status GET /api/admin/profile 200

pages=(/ /accounts /devices-stations /earthquake-events /community-reports /ringserver /seiscomp /inventory-import /archive-storage /deployment /audit-logs /settings)
for page in "${pages[@]}"; do
  request_status GET "/admin${page}" 200
done

api_routes=(
  /overview/snapshot
  /incidents
  /accounts
  /devices-stations
  /earthquake-events
  /community-reports
  /ringserver/snapshot
  /seiscomp/snapshot
  /inventory-import/workflow
  /archive-storage/snapshot
  /deployment-health/snapshot
  /audit-logs
  /configuration-diagnostics/snapshot
)
for route in "${api_routes[@]}"; do
  request_status GET "/api/admin${route}" 200
done

request_status POST /api/admin/signout 200
request_status GET /api/admin/profile 401
printf 'Admin dep-test smoke check passed.\n'
