#!/usr/bin/env bash
set -euo pipefail

SCRIPT_VERSION="2026-06-30.1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_DIR_DEFAULT="$(cd "$SCRIPT_DIR/.." && pwd)"
NGINX_CONTAINER_DEFAULT="nginx-proxy"
WSTUNNEL_CONTAINER_DEFAULT="wstunnel-server"
WSTUNNEL_HEALTH_URL_DEFAULT="http://host.docker.internal:7001/"

compose_dir="$COMPOSE_DIR_DEFAULT"
nginx_container="$NGINX_CONTAINER_DEFAULT"
wstunnel_container="$WSTUNNEL_CONTAINER_DEFAULT"
wstunnel_health_url="$WSTUNNEL_HEALTH_URL_DEFAULT"
remote_port=""
warn_count=0
fail_count=0

usage() {
  cat <<EOF_USAGE
Usage: $(basename "$0") [options]

Options:
  --compose-dir <path>       earthquake-hub-commons directory (default: parent of this script)
  --nginx-container <name>   nginx container name (default: $NGINX_CONTAINER_DEFAULT)
  --wstunnel-container <name>
                             wstunnel container name (default: $WSTUNNEL_CONTAINER_DEFAULT)
  --wstunnel-url <url>       URL nginx should reach for wstunnel (default: $WSTUNNEL_HEALTH_URL_DEFAULT)
  --remote-port <port>       Optional assigned bastion listener port to check
  --version                  Print script version
  -h, --help                 Show help

Examples:
  $(basename "$0")
  $(basename "$0") --compose-dir /path/to/earthquake-hub-commons --remote-port 22000
EOF_USAGE
}

pass() {
  echo "[PASS] $*"
}

warn() {
  warn_count=$((warn_count + 1))
  echo "[WARN] $*"
}

fail_check() {
  fail_count=$((fail_count + 1))
  echo "[FAIL] $*"
}

die() {
  echo "[FAILED] $*" >&2
  exit 1
}

validate_port() {
  local value="$1"
  [[ "$value" =~ ^[0-9]+$ ]] || return 1
  (( value >= 1 && value <= 65535 )) || return 1
}

parse_env_value() {
  local key="$1"
  local file="$2"
  awk -F= -v key="$key" '
    $0 !~ /^[[:space:]]*#/ && $1 == key {
      value=$0
      sub("^[^=]*=", "", value)
      gsub(/^["'\'']|["'\'']$/, "", value)
      print value
      exit
    }
  ' "$file"
}

container_running() {
  local name="$1"
  docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null | grep -qx true
}

check_file_contains() {
  local file="$1"
  local pattern="$2"
  local success="$3"
  local failure="$4"

  if grep -Eq "$pattern" "$file"; then
    pass "$success"
  else
    fail_check "$failure"
  fi
}

check_source_files() {
  local env_file="$compose_dir/.env"
  local nginx_conf="$compose_dir/https_data/nginx.d/nginx.conf"
  local restrictions_file="$compose_dir/wstunnel-restrictions.yaml"
  local compose_file="$compose_dir/docker-compose.yml"
  local prefix=""

  [[ -d "$compose_dir" ]] || die "Compose directory not found: $compose_dir"

  if [[ -r "$env_file" ]]; then
    prefix="$(parse_env_value "TUNNEL_WSS_PATH_PREFIX" "$env_file" || true)"
  else
    warn "No .env file found at $env_file; skipping deployed tunnel prefix check."
  fi

  if [[ -r "$nginx_conf" ]]; then
    if grep -q "ws-tusnnel" "$nginx_conf"; then
      fail_check "nginx config contains ws-tusnnel typo."
    else
      pass "nginx config has no ws-tusnnel typo."
    fi

    if [[ -n "$prefix" ]]; then
      if grep -Fq "location ^~ /${prefix}/" "$nginx_conf"; then
        pass "nginx has the configured WSTunnel location: /${prefix}/"
      else
        fail_check "nginx does not contain location ^~ /${prefix}/"
      fi
    else
      warn "TUNNEL_WSS_PATH_PREFIX is not set; cannot confirm nginx secret path."
    fi

    check_file_contains "$nginx_conf" 'proxy_pass[[:space:]]+http://host\.docker\.internal:7001;' \
      "nginx proxies WSTunnel to host.docker.internal:7001." \
      "nginx WSTunnel proxy_pass is not host.docker.internal:7001."
  else
    fail_check "nginx config is missing or unreadable: $nginx_conf"
  fi

  if [[ -r "$restrictions_file" ]]; then
    check_file_contains "$restrictions_file" '![[:space:]]*Any|![Aa]ny' \
      "WSTunnel restrictions use match: !Any." \
      "WSTunnel restrictions do not use match: !Any."
    if grep -q "!PathPrefix" "$restrictions_file"; then
      fail_check "WSTunnel restrictions still contain !PathPrefix; this can reject valid reverse tunnels."
    else
      pass "WSTunnel restrictions do not contain !PathPrefix."
    fi
    check_file_contains "$restrictions_file" '22000\.\.22999' \
      "WSTunnel restrictions keep the expected remote port range." \
      "WSTunnel restrictions are missing remote port range 22000..22999."
    check_file_contains "$restrictions_file" '127\.0\.0\.1/32' \
      "WSTunnel restrictions allow localhost IPv4 listener destinations." \
      "WSTunnel restrictions are missing 127.0.0.1/32."
  else
    fail_check "WSTunnel restrictions file is missing or unreadable: $restrictions_file"
  fi

  if [[ -r "$compose_file" ]]; then
    check_file_contains "$compose_file" 'network_mode:[[:space:]]*host' \
      "wstunnel-server uses host networking." \
      "wstunnel-server is not configured with network_mode: host."
    check_file_contains "$compose_file" 'host\.docker\.internal:host-gateway' \
      "Compose maps host.docker.internal to the host gateway." \
      "Compose is missing host.docker.internal:host-gateway."
  else
    fail_check "Compose file is missing or unreadable: $compose_file"
  fi
}

check_runtime() {
  local code

  if ! command -v docker >/dev/null 2>&1; then
    warn "docker is not available; skipping container runtime checks."
    return 0
  fi

  if container_running "$nginx_container"; then
    pass "$nginx_container is running."
    if docker exec "$nginx_container" nginx -t >/tmp/upri-nginx-check.out 2>&1; then
      pass "nginx runtime config test passes."
    else
      fail_check "nginx runtime config test failed: $(tr '\n' ' ' </tmp/upri-nginx-check.out)"
    fi

    if docker exec "$nginx_container" getent hosts host.docker.internal >/dev/null 2>&1; then
      pass "$nginx_container resolves host.docker.internal."
    else
      fail_check "$nginx_container cannot resolve host.docker.internal."
    fi

    if docker exec "$nginx_container" sh -lc 'command -v curl >/dev/null 2>&1'; then
      code="$(docker exec "$nginx_container" sh -lc "curl -sS -m 5 -o /tmp/upri-wstunnel-check.body -w '%{http_code}' '$wstunnel_health_url'" 2>/tmp/upri-wstunnel-curl.err || true)"
      case "$code" in
        400)
          pass "$nginx_container reaches WSTunnel; HTTP 400 is expected for plain HTTP."
          ;;
        000|"")
          fail_check "$nginx_container cannot reach WSTunnel at $wstunnel_health_url: $(tr '\n' ' ' </tmp/upri-wstunnel-curl.err)"
          ;;
        *)
          warn "$nginx_container reached $wstunnel_health_url but got HTTP $code; expected 400 for plain HTTP."
          ;;
      esac
    else
      warn "$nginx_container does not have curl; skipping nginx-to-WSTunnel HTTP probe."
    fi
  else
    warn "$nginx_container is not running; skipping nginx runtime checks."
  fi

  if container_running "$wstunnel_container"; then
    pass "$wstunnel_container is running."
    if docker logs --tail 80 "$wstunnel_container" 2>&1 | grep -q "not allowed destination"; then
      warn "Recent WSTunnel logs still contain 'not allowed destination'."
    else
      pass "Recent WSTunnel logs do not show restriction rejections."
    fi
  else
    warn "$wstunnel_container is not running; skipping WSTunnel log checks."
  fi
}

check_host_ports() {
  if command -v ss >/dev/null 2>&1; then
    if ss -lnt "sport = :7001" 2>/dev/null | awk 'NR > 1 {print}' | grep -q ':7001\b'; then
      pass "Host has a listener on port 7001."
    else
      fail_check "Host has no listener on port 7001."
    fi

    if [[ -n "$remote_port" ]]; then
      if ss -lnt "sport = :$remote_port" 2>/dev/null | awk 'NR > 1 {print}' | grep -Eq "127\\.0\\.0\\.1:${remote_port}\\b"; then
        pass "Bastion listener is up on 127.0.0.1:$remote_port."
      else
        fail_check "No bastion listener on 127.0.0.1:$remote_port."
      fi
    fi
  else
    warn "ss is not available; skipping host listener checks."
  fi
}

check_firewall_hint() {
  local ufw_output=""

  if ! command -v ufw >/dev/null 2>&1; then
    warn "ufw is not available; skipping firewall rule check."
    return 0
  fi

  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    ufw_output="$(ufw status verbose 2>/dev/null || true)"
  elif command -v sudo >/dev/null 2>&1; then
    ufw_output="$(sudo -n ufw status verbose 2>/dev/null || true)"
  fi

  if [[ -z "$ufw_output" ]]; then
    warn "Cannot read UFW status without sudo; verify Docker bridge access to host port 7001 manually."
    return 0
  fi

  if grep -Eq '7001/tcp.*ALLOW IN' <<<"$ufw_output"; then
    pass "UFW has an allow rule for TCP port 7001."
  else
    warn "No UFW allow rule for TCP port 7001 was found; nginx may time out reaching WSTunnel."
  fi
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --compose-dir)
        compose_dir="${2:-}"; shift 2 ;;
      --nginx-container)
        nginx_container="${2:-}"; shift 2 ;;
      --wstunnel-container)
        wstunnel_container="${2:-}"; shift 2 ;;
      --wstunnel-url)
        wstunnel_health_url="${2:-}"; shift 2 ;;
      --remote-port)
        remote_port="${2:-}"; shift 2 ;;
      --version)
        echo "$(basename "$0") $SCRIPT_VERSION"; exit 0 ;;
      -h|--help)
        usage; exit 0 ;;
      *)
        die "Unknown option: $1" ;;
    esac
  done

  [[ -n "$compose_dir" ]] || die "--compose-dir cannot be empty."
  [[ -n "$nginx_container" ]] || die "--nginx-container cannot be empty."
  [[ -n "$wstunnel_container" ]] || die "--wstunnel-container cannot be empty."
  [[ -n "$wstunnel_health_url" ]] || die "--wstunnel-url cannot be empty."
  if [[ -n "$remote_port" ]]; then
    validate_port "$remote_port" || die "--remote-port must be between 1 and 65535."
  fi
}

main() {
  parse_args "$@"
  compose_dir="$(cd "$compose_dir" && pwd)"

  echo "WSTunnel check context:"
  echo "  compose_dir=$compose_dir"
  echo "  nginx_container=$nginx_container"
  echo "  wstunnel_container=$wstunnel_container"
  echo "  wstunnel_url=$wstunnel_health_url"
  if [[ -n "$remote_port" ]]; then
    echo "  remote_port=$remote_port"
  fi
  echo

  check_source_files
  check_runtime
  check_host_ports
  check_firewall_hint

  echo
  echo "Summary: $fail_count failed, $warn_count warnings"
  if (( fail_count > 0 )); then
    exit 1
  fi
}

main "$@"
