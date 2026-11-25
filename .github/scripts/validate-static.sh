#!/usr/bin/env bash
# Static checks for Earthquake Hub Commons scripts and config files. Read-only.
#
#   1. Tracked text files use LF line endings in the repository.
#   2. Scripts that Compose or the backend run directly are executable in git.
#   3. Shell scripts parse (bash -n) and pass shellcheck.
#   4. Python scripts parse.
#   5. YAML files that are not Compose files parse.
#   6. No credentials are committed: .env files, private keys, or a real
#      WSTunnel path secret in a tracked Nginx config.
#
# Usage (from anywhere in the repository):
#   bash .github/scripts/validate-static.sh
set -euo pipefail
export MSYS_NO_PATHCONV=1 # Git Bash on Windows: keep container paths as written.

cd "$(dirname "${BASH_SOURCE[0]}")/../.."

# Scripts on the deployment path are held to shellcheck warnings; the others
# to errors only (their existing warnings are listed in docs/deployment-audit.md).
STRICT_PATHS='^(bastion|ringserver-configs|\.github/scripts)/'
# Run directly by Compose (entrypoint) or by the backend over SSH.
EXECUTABLE_PATHS='^(bastion|ringserver-configs)/.*\.sh$'
SHELLCHECK_IMAGE="${SHELLCHECK_IMAGE:-koalaman/shellcheck:stable}"

failures=0
fail() {
  echo "::error::$*"
  failures=$((failures + 1))
}
missing_tool() {
  if [[ ${CI:-} == true ]]; then
    fail "$1 is not installed, so this check cannot run"
  else
    echo "   SKIPPED: $1 not installed (CI runs this check)"
  fi
}
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

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# Tracked files plus new files that are not ignored, so local runs also check
# work that has not been committed yet.
list_files() { git ls-files --cached --others --exclude-standard -- "$@" | sort -u; }

echo "== Line endings: tracked text files are stored with LF"
crlf="$(git ls-files --eol | awk '$1 ~ /^i\/(crlf|mixed)$/ { print $NF }')"
if [[ -n $crlf ]]; then
  while read -r path; do fail "${path} is stored with CRLF line endings; convert it to LF"; done <<<"$crlf"
else
  echo "   ok"
fi

echo "== Executable bit: scripts run directly by Compose or the backend"
not_exec="$(git ls-files -s | awk '$1 != "100755" { print $4 }' | grep -E "$EXECUTABLE_PATHS" || true)"
if [[ -n $not_exec ]]; then
  while read -r path; do fail "${path} is not executable in git; run: git update-index --chmod=+x ${path}"; done <<<"$not_exec"
else
  echo "   ok"
fi

# Check a CR-free copy of each script. On Windows with core.autocrlf=true the
# working tree has CRLF, but git commits LF (verified by the line-ending check).
mapfile -t sh_files < <(list_files '*.sh')
snap="$work/snapshot"
for path in "${sh_files[@]}"; do
  mkdir -p "$snap/$(dirname "$path")"
  tr -d '\r' <"$path" >"$snap/$path"
done

echo "== bash -n: ${#sh_files[@]} shell scripts parse"
parse_ok=1
for path in "${sh_files[@]}"; do
  if ! bash -n "$snap/$path" 2>"$work/bash-n.err"; then
    sed 's/^/   /' "$work/bash-n.err"
    fail "${path} has a shell syntax error"
    parse_ok=0
  fi
done
[[ $parse_ok -eq 1 ]] && echo "   ok"

run_shellcheck() { # <severity> <file>...
  local severity=$1
  shift
  if command -v shellcheck >/dev/null 2>&1; then
    (cd "$snap" && shellcheck --severity="$severity" "$@")
  elif command -v docker >/dev/null 2>&1; then
    docker run --rm -v "$(host_path "$snap"):/mnt:ro" -w /mnt "$SHELLCHECK_IMAGE" --severity="$severity" "$@"
  else
    return 127
  fi
}

mapfile -t strict_files < <(printf '%s\n' "${sh_files[@]}" | grep -E "$STRICT_PATHS" || true)
mapfile -t other_files < <(printf '%s\n' "${sh_files[@]}" | grep -vE "$STRICT_PATHS" || true)
if ! command -v shellcheck >/dev/null 2>&1 && ! command -v docker >/dev/null 2>&1; then
  echo "== shellcheck"
  missing_tool shellcheck
else
  echo "== shellcheck (warnings and above): ${#strict_files[@]} deployment scripts"
  if [[ ${#strict_files[@]} -gt 0 ]]; then
    if run_shellcheck warning "${strict_files[@]}"; then echo "   ok"; else fail "shellcheck reported problems in deployment scripts"; fi
  fi
  echo "== shellcheck (errors only): ${#other_files[@]} other scripts"
  if [[ ${#other_files[@]} -gt 0 ]]; then
    if run_shellcheck error "${other_files[@]}"; then echo "   ok"; else fail "shellcheck reported errors in other scripts"; fi
  fi
fi

py="$(find_python || true)"

mapfile -t py_files < <(list_files '*.py')
echo "== Python: ${#py_files[@]} scripts parse"
if [[ ${#py_files[@]} -gt 0 ]]; then
  if [[ -z $py ]]; then
    missing_tool python3
  else
    py_args=()
    for path in "${py_files[@]}"; do py_args+=("$(host_path "$PWD/$path")"); done
    if "$py" - "${py_args[@]}" <<'PY'; then
import ast
import sys

bad = 0
for path in sys.argv[1:]:
    try:
        with open(path, encoding="utf-8") as fh:
            ast.parse(fh.read(), path)
    except SyntaxError as err:
        print(f"::error file={path},line={err.lineno}::{err.msg}")
        bad += 1
sys.exit(1 if bad else 0)
PY
      echo "   ok"
    else
      failures=$((failures + 1))
    fi
  fi
fi

# Compose files are validated by validate-compose.sh.
mapfile -t yaml_files < <(list_files '*.yml' '*.yaml' | grep -vE '^docker-compose[^/]*\.ya?ml$' || true)
echo "== YAML: ${#yaml_files[@]} files parse"
if [[ ${#yaml_files[@]} -gt 0 ]]; then
  if [[ -n $py ]] && "$py" -c 'import yaml' >/dev/null 2>&1; then
    yaml_args=()
    for path in "${yaml_files[@]}"; do yaml_args+=("$(host_path "$PWD/$path")"); done
    # Custom tags such as wstunnel's !Any are accepted, not interpreted.
    if "$py" - "${yaml_args[@]}" <<'PY'; then
import sys

import yaml


class Loader(yaml.SafeLoader):
    pass


Loader.add_multi_constructor("!", lambda loader, suffix, node: None)
bad = 0
for path in sys.argv[1:]:
    try:
        with open(path, encoding="utf-8") as fh:
            yaml.load(fh, Loader=Loader)
    except yaml.YAMLError as err:
        print(f"::error file={path}::{err}")
        bad += 1
sys.exit(1 if bad else 0)
PY
      echo "   ok"
    else
      failures=$((failures + 1))
    fi
  elif command -v yq >/dev/null 2>&1; then
    yaml_ok=1
    for path in "${yaml_files[@]}"; do
      if ! yq '.' "$path" >/dev/null; then
        fail "${path} is not valid YAML"
        yaml_ok=0
      fi
    done
    [[ $yaml_ok -eq 1 ]] && echo "   ok"
  else
    missing_tool "PyYAML or yq"
  fi
fi

echo "== No committed credentials"
secrets_ok=1
env_files="$(list_files | grep -E '(^|/)\.env$' || true)"
if [[ -n $env_files ]]; then
  while read -r path; do fail "${path} must not be committed (only .env.example belongs in git)"; done <<<"$env_files"
  secrets_ok=0
fi
key_files="$(git grep --untracked -lE -- '-----BEGIN ([A-Z0-9]+ )*PRIVATE KEY-----' || true)"
if [[ -n $key_files ]]; then
  while read -r path; do fail "${path} contains a private key"; done <<<"$key_files"
  secrets_ok=0
fi
# The tunnel path suffix is a secret; tracked configs keep the <SECRET> placeholder.
tunnel_paths="$(list_files 'https_data/*.conf' |
  xargs -r grep -HnoE 'location[[:space:]]+\^~[[:space:]]+/api/ws-tunnel/[^/[:space:]]+/' |
  grep -vF '/api/ws-tunnel/<SECRET>/' || true)"
if [[ -n $tunnel_paths ]]; then
  while read -r match; do fail "${match%%:*}: a WSTunnel location uses a real path secret; keep /api/ws-tunnel/<SECRET>/ in git and set the real one on the server"; done <<<"$tunnel_paths"
  secrets_ok=0
fi
[[ $secrets_ok -eq 1 ]] && echo "   ok"

if [[ $failures -gt 0 ]]; then
  echo "Static checks: ${failures} problem(s) found"
  exit 1
fi
echo "Static checks: all checks passed"
