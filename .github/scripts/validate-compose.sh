#!/usr/bin/env bash
# Static Compose validation for Earthquake Hub Commons.
#
# Renders every tracked Compose file with the committed placeholder values in
# .env.example (plus a fixture of fake, digest-pinned image references) and
# fails on errors or warnings. It never reads a real .env file, pulls or builds
# images, starts containers, or connects to a server.
#
# Usage (from anywhere in the repository):
#   bash .github/scripts/validate-compose.sh
set -euo pipefail
export MSYS_NO_PATHCONV=1 # Git Bash on Windows: keep paths as written.

cd "$(dirname "${BASH_SOURCE[0]}")/../.."

ENV_EXAMPLE=.env.example
PINNED_FIXTURE=.github/scripts/fixtures/pinned-images.env
PROD_FILE=docker-compose.yml
TEST_FILE=docker-compose.dep-test.yml
COMPOSE_FILES=("$PROD_FILE" "$TEST_FILE")

failures=0
fail() {
  echo "::error::$*"
  failures=$((failures + 1))
}

# Windows Python and Docker need C:/... paths; elsewhere this is a no-op.
host_path() {
  if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s\n' "$1"; fi
}

find_python() {
  local candidate
  for candidate in python3 python; do
    if command -v "$candidate" >/dev/null 2>&1 &&
      "$candidate" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 8) else 1)' >/dev/null 2>&1; then
      echo "$candidate"
      return 0
    fi
  done
  return 1
}

# A moving tag can point at a different image tomorrow: no digest, and either
# no tag at all or one of the aliases the image-tag policy moves.
is_moving_ref() {
  local ref=$1 last
  [[ $ref == *@sha256:* ]] && return 1
  last=${ref##*/}
  [[ $last != *:* || $last == *:latest || $last == *:stable || $last == *:dev || $last == *:staging ]]
}

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

mapfile -t names < <(grep -ohE '\$\{[A-Za-z_][A-Za-z0-9_]*' "${COMPOSE_FILES[@]}" | sed 's/^\${//' | sort -u)

# Variables exported in the calling shell override env files; drop them so the
# result depends only on the committed fixtures.
unset "${names[@]}" COMPOSE_FILE COMPOSE_PROJECT_NAME COMPOSE_PROFILES 2>/dev/null || true

echo "== Every variable the Compose files read is listed in ${ENV_EXAMPLE}"
missing=0
for name in "${names[@]}"; do
  if ! grep -qE "^[[:space:]]*#?[[:space:]]*${name}=" "$ENV_EXAMPLE"; then
    fail "${name} is used by a Compose file but not listed in ${ENV_EXAMPLE} (add it; comment it out if it is optional)"
    missing=$((missing + 1))
  fi
done
[[ $missing -eq 0 ]] && echo "   ok: ${#names[@]} variables"

for file in "${COMPOSE_FILES[@]}"; do
  echo "== ${file}: render with ${ENV_EXAMPLE}"
  if docker compose -f "$file" --env-file "$ENV_EXAMPLE" config --format json >"$work/$file.json" 2>"$work/$file.err"; then
    if grep -qiE 'level=warn|^WARN' "$work/$file.err"; then
      sed 's/^/   /' "$work/$file.err"
      fail "${file}: Compose printed warnings (usually a variable that ${ENV_EXAMPLE} does not set)"
    else
      echo "   ok"
    fi
  else
    sed 's/^/   /' "$work/$file.err"
    fail "${file}: docker compose config failed"
    continue
  fi

  # Report moving default tags without failing: production still uses them
  # until a pinned baseline is approved.
  while read -r image; do
    [[ -n $image ]] || continue
    if is_moving_ref "$image"; then
      echo "::notice::${file}: default image '${image}' is a moving tag; pin it per environment (docs/deployment-runbook.md, Image inputs)"
    fi
  done < <(docker compose -f "$file" --env-file "$ENV_EXAMPLE" config --images 2>/dev/null)
done

echo "== Image inputs: the pinned references in ${PINNED_FIXTURE} replace the defaults"
for file in "${COMPOSE_FILES[@]}"; do
  if ! images="$(docker compose -f "$file" --env-file "$ENV_EXAMPLE" --env-file "$PINNED_FIXTURE" config --images 2>"$work/pinned.err")"; then
    sed 's/^/   /' "$work/pinned.err"
    fail "${file}: docker compose config failed with ${PINNED_FIXTURE}"
    continue
  fi
  pinned_ok=1
  while IFS='=' read -r key value; do
    [[ -z $key || $key == \#* ]] && continue
    value=${value%$'\r'}
    if ! grep -qxF "$value" <<<"$images"; then
      fail "${file}: ${key} did not reach a service image (expected ${value})"
      pinned_ok=0
    fi
  done <"$PINNED_FIXTURE"
  [[ $pinned_ok -eq 1 ]] && echo "   ok: ${file}"
done

echo "== Backend variables: ${TEST_FILE} matches ${PROD_FILE}; each migrate service matches its backend"
if [[ -s "$work/$PROD_FILE.json" && -s "$work/$TEST_FILE.json" ]]; then
  if py="$(find_python)"; then
    if "$py" - "$(host_path "$work/$PROD_FILE.json")" "$(host_path "$work/$TEST_FILE.json")" <<'PY'; then
import json
import sys

# file label -> (backend service, migrate service)
SERVICES = {
    "docker-compose.yml": ("ehub-backend", "ehub-backend-migrate"),
    "docker-compose.dep-test.yml": ("earthquake-hub-backend-dep-test", "earthquake-hub-backend-migrate-dep-test"),
}
DB_KEYS = ("PG_HOST", "PG_PORT", "PG_DATABASE", "PG_USER", "PG_PASSWORD")

rendered = {}
for label, path in zip(SERVICES, sys.argv[1:3]):
    with open(path, encoding="utf-8") as fh:
        rendered[label] = json.load(fh)

errors = []
backend_env = {}
for label, (backend, migrate) in SERVICES.items():
    services = rendered[label]["services"]
    missing_services = [name for name in (backend, migrate) if name not in services]
    if missing_services:
        errors.append(f"{label}: service(s) {', '.join(missing_services)} not found; update the names in validate-compose.sh")
        continue
    b_env = services[backend].get("environment") or {}
    m_env = services[migrate].get("environment") or {}
    backend_env[label] = b_env
    for key in DB_KEYS:
        if key not in b_env:
            errors.append(f"{label}: {backend} does not set {key}")
        elif b_env.get(key) != m_env.get(key):
            errors.append(f"{label}: {migrate} must set {key} exactly as {backend} does")
    if services[migrate].get("image") != services[backend].get("image"):
        errors.append(f"{label}: {migrate} must use the same image as {backend}")
    host = b_env.get("PG_HOST")
    if host and host not in services:
        errors.append(f"{label}: PG_HOST={host} is not a service in this file")

if len(backend_env) == len(SERVICES):
    prod_env, test_env = (set(env) for env in backend_env.values())
    missing = sorted(prod_env - test_env)
    if missing:
        errors.append("backend variables in docker-compose.yml but not in docker-compose.dep-test.yml: " + ", ".join(missing))

for error in errors:
    print(f"::error::{error}")
if errors:
    sys.exit(1)
print(f"   ok: {len(prod_env)} production backend variables are also in the deployment-test file;"
      " each migrate service matches its backend's database settings and image")
PY
      :
    else
      failures=$((failures + 1))
    fi
  elif [[ ${CI:-} == true ]]; then
    fail "python3 is not installed; cannot compare backend variables"
  else
    echo "   SKIPPED: no Python 3 found (CI runs this check)"
  fi
else
  fail "cannot compare backend variables: a Compose file did not render"
fi

if [[ $failures -gt 0 ]]; then
  echo "Compose validation: ${failures} problem(s) found"
  exit 1
fi
echo "Compose validation: all checks passed"
