#!/usr/bin/env bash
set -Eeuo pipefail

# Installs the narrowly scoped, host-native pieces required by the Admin
# Console. It intentionally does not install packages, alter network access,
# replace secrets, or restart Docker/SSH.

SCRIPT_VERSION="2026-08-13.1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

COLLECTOR_GROUP="ehub-admin-telemetry"
COLLECTOR_USER="ehub-host-collector"
COLLECTOR_INSTALL_DIR="/opt/earthquakehub-host-collector"
COLLECTOR_TARGET="$COLLECTOR_INSTALL_DIR/hostCollector.js"
COLLECTOR_ENV_TARGET="/etc/earthquakehub-host-collector.env"
COLLECTOR_UNIT_TARGET="/etc/systemd/system/earthquakehub-host-collector.service"
COLLECTOR_UNIT_SOURCE="$ROOT_DIR/host-collector/earthquakehub-host-collector.service"
COLLECTOR_ENV_SOURCE="$ROOT_DIR/host-collector/earthquakehub-host-collector.env.example"
BASTION_SETUP="$ROOT_DIR/bastion/setup-host.sh"
DEPLOYMENT_MARKER_PATH="$ROOT_DIR/runtime/admin-telemetry/deployment-filesystem"

CHECK_ONLY=false
DRY_RUN=false
SKIP_BASTION=false
COLLECTOR_SOURCE=""
COLLECTOR_IMAGE=""
ARCHIVE_MARKER_PATH=""
TEMPORARY_SOURCE_DIR=""

usage() {
  cat <<'USAGE'
Usage:
  sudo ./scripts/bootstrap-admin-host.sh --check
  sudo ./scripts/bootstrap-admin-host.sh --collector-source <hostCollector.js>
  sudo ./scripts/bootstrap-admin-host.sh --collector-image <immutable-image-reference>

Options:
  --check                    Read-only preflight; does not require a collector source.
  --dry-run                  Print intended changes without writing them.
  --collector-source <path>  Reviewed hostCollector.js source file to install.
  --collector-image <image>  Already-pulled admin-backend image from which to copy
                             /app/src/hostCollector.js without starting a container.
  --archive-marker-path <path>
                             Create an empty archive telemetry marker at this path.
                             The path must resolve to a mounted filesystem other
                             than the deployment filesystem; root is rejected.
  --skip-bastion             Do not run the idempotent bastion/setup-host.sh step.
  --version                  Print version.
  -h, --help                 Show this help.

Exactly one of --collector-source or --collector-image is required unless
--check is used. The script never installs Node.js, pulls images, replaces an
existing collector environment file, restarts Docker/SSH, or changes firewall,
VPN, DNS, admin allowlists, MongoDB, archive contents, or secrets. It always
creates the local deployment filesystem marker and creates an archive marker
only when --archive-marker-path is explicitly supplied and validated.
USAGE
}

fail() {
  printf '[FAILED] %s\n' "$*" >&2
  exit 1
}

note() {
  printf '[INFO] %s\n' "$*"
}

warn() {
  printf '[WARN] %s\n' "$*" >&2
}

run() {
  if [[ "$DRY_RUN" == true ]]; then
    printf '[DRY RUN]'
    printf ' %q' "$@"
    printf '\n'
    return 0
  fi
  "$@"
}

require_root() {
  [[ "${EUID:-$(id -u)}" -eq 0 ]] || fail 'Run this script through sudo.'
}

cleanup() {
  [[ -n "$TEMPORARY_SOURCE_DIR" ]] && rm -rf -- "$TEMPORARY_SOURCE_DIR"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --check) CHECK_ONLY=true; shift ;;
      --dry-run) DRY_RUN=true; shift ;;
      --skip-bastion) SKIP_BASTION=true; shift ;;
      --collector-source)
        COLLECTOR_SOURCE="${2:-}"
        [[ -n "$COLLECTOR_SOURCE" ]] || fail '--collector-source requires a path.'
        shift 2
        ;;
      --collector-image)
        COLLECTOR_IMAGE="${2:-}"
        [[ -n "$COLLECTOR_IMAGE" ]] || fail '--collector-image requires an image reference.'
        shift 2
        ;;
      --archive-marker-path)
        ARCHIVE_MARKER_PATH="${2:-}"
        [[ -n "$ARCHIVE_MARKER_PATH" ]] || fail '--archive-marker-path requires an absolute path.'
        [[ "$ARCHIVE_MARKER_PATH" == /* ]] || fail '--archive-marker-path must be absolute.'
        shift 2
        ;;
      --version) printf '%s %s\n' "$(basename "$0")" "$SCRIPT_VERSION"; exit 0 ;;
      --help|-h) usage; exit 0 ;;
      *) fail "Unknown option: $1" ;;
    esac
  done

  if [[ -n "$COLLECTOR_SOURCE" && -n "$COLLECTOR_IMAGE" ]]; then
    fail 'Use only one of --collector-source or --collector-image.'
  fi
  if [[ "$CHECK_ONLY" == false && -z "$COLLECTOR_SOURCE" && -z "$COLLECTOR_IMAGE" ]]; then
    fail 'Provide --collector-source or --collector-image (or use --check).'
  fi
}

mounted_filesystem_target() {
  local candidate
  candidate="$(realpath -m -- "$1")"
  while [[ ! -e "$candidate" ]]; do
    [[ "$candidate" != "/" ]] || break
    candidate="$(dirname -- "$candidate")"
  done
  findmnt -n -o TARGET -T "$candidate" 2>/dev/null | head -n 1
}

validate_marker_paths() {
  local deployment_mount archive_mount
  deployment_mount="$(mounted_filesystem_target "$DEPLOYMENT_MARKER_PATH")"
  [[ -n "$deployment_mount" ]] || fail "Unable to resolve deployment marker filesystem: $DEPLOYMENT_MARKER_PATH"
  note "Deployment marker filesystem: $deployment_mount"

  if [[ -z "$ARCHIVE_MARKER_PATH" ]]; then
    return 0
  fi

  archive_mount="$(mounted_filesystem_target "$ARCHIVE_MARKER_PATH")"
  [[ -n "$archive_mount" ]] || fail "Unable to resolve archive marker filesystem: $ARCHIVE_MARKER_PATH"
  [[ "$archive_mount" != "/" ]] || fail 'Archive marker resolves to the root filesystem; mount the archive first and use its separate mount path.'
  [[ "$archive_mount" != "$deployment_mount" ]] || fail 'Archive marker resolves to the deployment filesystem; provide a path on the separately mounted archive filesystem.'
  note "Archive marker filesystem: $archive_mount"
}

check_node() {
  command -v node >/dev/null 2>&1 || fail 'Node.js 22 or newer is required; install it through the approved host package process.'
  local version major
  version="$(node --version)"
  major="${version#v}"
  major="${major%%.*}"
  [[ "$major" =~ ^[0-9]+$ ]] && (( major >= 22 )) || fail "Node.js 22 or newer is required; found $version."
  note "Node runtime: $version"
}

check_sources() {
  [[ -r "$COLLECTOR_UNIT_SOURCE" ]] || fail "Collector systemd unit is missing: $COLLECTOR_UNIT_SOURCE"
  [[ -r "$COLLECTOR_ENV_SOURCE" ]] || fail "Collector environment template is missing: $COLLECTOR_ENV_SOURCE"
  [[ -x "$BASTION_SETUP" ]] || fail "Bastion setup script is missing or not executable: $BASTION_SETUP"

  if [[ -n "$COLLECTOR_SOURCE" ]]; then
    [[ -r "$COLLECTOR_SOURCE" ]] || fail "Collector source is not readable: $COLLECTOR_SOURCE"
  fi
  if [[ -n "$COLLECTOR_IMAGE" ]]; then
    command -v docker >/dev/null 2>&1 || fail 'Docker is required when --collector-image is used.'
    docker image inspect "$COLLECTOR_IMAGE" >/dev/null 2>&1 \
      || fail "Collector image is not present locally: $COLLECTOR_IMAGE (pull and verify it first)."
  fi
}

report_state() {
  local group_id="missing"
  local service_state="missing"
  local enabled_state="missing"
  local socket_state="missing"

  if getent group "$COLLECTOR_GROUP" >/dev/null; then
    group_id="$(getent group "$COLLECTOR_GROUP" | cut -d: -f3)"
  fi
  if [[ -r "$COLLECTOR_UNIT_TARGET" ]]; then
    service_state="$(systemctl is-active earthquakehub-host-collector.service 2>/dev/null || true)"
    enabled_state="$(systemctl is-enabled earthquakehub-host-collector.service 2>/dev/null || true)"
  fi
  [[ -S /run/earthquakehub-host-collector/collector.sock ]] && socket_state="present"

  note "Collector group: $COLLECTOR_GROUP (gid: $group_id)"
  if id "$COLLECTOR_USER" >/dev/null 2>&1; then
    note "Collector user: present"
  else
    note "Collector user: missing"
  fi
  note "Collector source: $COLLECTOR_TARGET ($(test -r "$COLLECTOR_TARGET" && echo present || echo missing))"
  note "Collector environment: $COLLECTOR_ENV_TARGET ($(test -r "$COLLECTOR_ENV_TARGET" && echo present || echo missing))"
  note "Collector service: $service_state; enabled: $enabled_state; socket: $socket_state"
  note "Deployment marker: $DEPLOYMENT_MARKER_PATH ($(test -d "$DEPLOYMENT_MARKER_PATH" && echo present || echo missing))"
  if [[ -n "$ARCHIVE_MARKER_PATH" ]]; then
    note "Archive marker: $ARCHIVE_MARKER_PATH ($(test -d "$ARCHIVE_MARKER_PATH" && echo present || echo missing))"
  else
    note 'Archive marker: not requested'
  fi
}

copy_source_from_image() {
  local temporary_container
  temporary_container="earthquakehub-host-collector-source-$$"
  TEMPORARY_SOURCE_DIR="$(mktemp -d)"

  if [[ "$DRY_RUN" == true ]]; then
    run docker create --name "$temporary_container" "$COLLECTOR_IMAGE"
    run docker cp "$temporary_container:/app/src/hostCollector.js" "$TEMPORARY_SOURCE_DIR/hostCollector.js"
    run docker rm -f "$temporary_container"
    COLLECTOR_SOURCE="$TEMPORARY_SOURCE_DIR/hostCollector.js"
    return 0
  fi

  docker create --name "$temporary_container" "$COLLECTOR_IMAGE" >/dev/null
  if ! docker cp "$temporary_container:/app/src/hostCollector.js" "$TEMPORARY_SOURCE_DIR/hostCollector.js"; then
    docker rm -f "$temporary_container" >/dev/null 2>&1 || true
    fail 'Could not extract /app/src/hostCollector.js from the supplied collector image.'
  fi
  docker rm -f "$temporary_container" >/dev/null
  COLLECTOR_SOURCE="$TEMPORARY_SOURCE_DIR/hostCollector.js"
}

install_telemetry_markers() {
  run install -d -o root -g root -m 0555 "$DEPLOYMENT_MARKER_PATH"
  if [[ -n "$ARCHIVE_MARKER_PATH" ]]; then
    run install -d -o root -g root -m 0555 "$ARCHIVE_MARKER_PATH"
  fi
}

install_collector_identity() {
  local expected_gid current_gid
  if ! getent group "$COLLECTOR_GROUP" >/dev/null; then
    run groupadd --system "$COLLECTOR_GROUP"
  fi
  expected_gid="$(getent group "$COLLECTOR_GROUP" | cut -d: -f3)"

  if id "$COLLECTOR_USER" >/dev/null 2>&1; then
    current_gid="$(id -g "$COLLECTOR_USER")"
    [[ "$current_gid" == "$expected_gid" ]] || fail "Existing $COLLECTOR_USER primary group does not match $COLLECTOR_GROUP; refusing to modify it."
  else
    run useradd --system --gid "$COLLECTOR_GROUP" --home-dir /nonexistent --shell /usr/sbin/nologin "$COLLECTOR_USER"
  fi
}

install_collector_files() {
  local temporary_source
  [[ -n "$COLLECTOR_SOURCE" ]] || fail 'Collector source was not resolved.'
  if [[ "$DRY_RUN" == true ]]; then
    if [[ -r "$COLLECTOR_SOURCE" ]]; then
      node --check "$COLLECTOR_SOURCE" >/dev/null || fail 'Collector source failed Node syntax validation.'
    else
      note 'Skipping source syntax validation in image-based dry run.'
    fi
    run install -d -o root -g root -m 0755 "$COLLECTOR_INSTALL_DIR"
    run install -o root -g root -m 0555 "$COLLECTOR_SOURCE" "$COLLECTOR_TARGET"
    run install -o root -g root -m 0644 "$COLLECTOR_UNIT_SOURCE" "$COLLECTOR_UNIT_TARGET"
    if [[ -e "$COLLECTOR_ENV_TARGET" ]]; then
      note "Preserving existing collector environment: $COLLECTOR_ENV_TARGET"
    else
      run install -o root -g "$COLLECTOR_GROUP" -m 0640 "$COLLECTOR_ENV_SOURCE" "$COLLECTOR_ENV_TARGET"
    fi
    return 0
  fi
  [[ -s "$COLLECTOR_SOURCE" ]] || fail "Collector source is empty: $COLLECTOR_SOURCE"
  node --check "$COLLECTOR_SOURCE" >/dev/null || fail 'Collector source failed Node syntax validation.'

  temporary_source="$(mktemp)"
  cp -- "$COLLECTOR_SOURCE" "$temporary_source"
  run install -d -o root -g root -m 0755 "$COLLECTOR_INSTALL_DIR"
  run install -o root -g root -m 0555 "$temporary_source" "$COLLECTOR_TARGET"
  run install -o root -g root -m 0644 "$COLLECTOR_UNIT_SOURCE" "$COLLECTOR_UNIT_TARGET"
  if [[ -e "$COLLECTOR_ENV_TARGET" ]]; then
    note "Preserving existing collector environment: $COLLECTOR_ENV_TARGET"
  else
    run install -o root -g "$COLLECTOR_GROUP" -m 0640 "$COLLECTOR_ENV_SOURCE" "$COLLECTOR_ENV_TARGET"
    warn "Created $COLLECTOR_ENV_TARGET; review its port range before starting the collector."
  fi
  rm -f -- "$temporary_source"
}

verify_and_start_collector() {
  run systemd-analyze verify "$COLLECTOR_UNIT_TARGET"
  run systemctl daemon-reload
  run systemctl enable --now earthquakehub-host-collector.service
  if [[ "$DRY_RUN" == false ]]; then
    systemctl is-active --quiet earthquakehub-host-collector.service \
      || fail 'Collector service did not become active; inspect journalctl -u earthquakehub-host-collector.service.'
  fi
}

main() {
  parse_args "$@"
  require_root
  check_node
  check_sources
  validate_marker_paths
  report_state

  if [[ "$CHECK_ONLY" == true ]]; then
    note 'Read-only preflight completed.'
    exit 0
  fi

  if [[ -n "$COLLECTOR_IMAGE" ]]; then
    copy_source_from_image
  fi
  install_collector_identity
  install_collector_files
  install_telemetry_markers
  if [[ "$SKIP_BASTION" == false ]]; then
    run "$BASTION_SETUP"
  else
    note 'Skipping bastion bootstrap by request.'
  fi
  verify_and_start_collector

  if [[ "$DRY_RUN" == false ]]; then
    note "Collector group ID for ADMIN_HOST_COLLECTOR_GID: $(getent group "$COLLECTOR_GROUP" | cut -d: -f3)"
    note "Set ADMIN_TELEMETRY_SERVER_FILESYSTEM_HOST_PATH=$DEPLOYMENT_MARKER_PATH in .env"
    if [[ -n "$ARCHIVE_MARKER_PATH" ]]; then
      note "Set ADMIN_TELEMETRY_ARCHIVE_HOST_PATH=$ARCHIVE_MARKER_PATH in .env"
    else
      warn 'No archive marker was created. After the archive mount is verified, rerun with --archive-marker-path <absolute-path>.'
    fi
    note 'Host bootstrap completed. Recreate admin-backend only after updating .env with the reported group ID.'
  fi
}

trap cleanup EXIT
main "$@"
