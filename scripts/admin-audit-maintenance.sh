#!/usr/bin/env bash
set -Eeuo pipefail

umask 077

ENV_FILE="${1:-.env}"
COMPOSE_FILE="${2:-docker-compose.yml}"
ARCHIVE_DIR="${ADMIN_AUDIT_ARCHIVE_STAGING_DIR:-./audit-archives}"
MONGODB_VOLUME="${ADMIN_AUDIT_MONGODB_VOLUME:-earthquake-hub-mongodb-data}"
WARNING_PERCENT="${ADMIN_AUDIT_DISK_WARNING_PERCENT:-70}"
ACTION_PERCENT="${ADMIN_AUDIT_DISK_ACTION_PERCENT:-80}"
CRITICAL_PERCENT="${ADMIN_AUDIT_DISK_CRITICAL_PERCENT:-90}"
OFFSITE_DEST="${ADMIN_AUDIT_ARCHIVE_RSYNC_DEST:-}"
REQUIRE_OFFSITE="${ADMIN_AUDIT_REQUIRE_OFFSITE:-false}"

log_message() {
  local level="$1"
  shift
  printf '%s admin-audit-maintenance[%s] %s\n' "$(date -u +%FT%TZ)" "$level" "$*" >&2
  if command -v logger >/dev/null 2>&1; then
    logger -t admin-audit-maintenance -- "[$level] $*"
  fi
}

is_percent() {
  [[ "$1" =~ ^[0-9]+$ ]] && (( "$1" >= 1 && "$1" <= 100 ))
}

for threshold in "$WARNING_PERCENT" "$ACTION_PERCENT" "$CRITICAL_PERCENT"; do
  if ! is_percent "$threshold"; then
    log_message error "Disk thresholds must be integers from 1 through 100."
    exit 64
  fi
done
if (( WARNING_PERCENT >= ACTION_PERCENT || ACTION_PERCENT >= CRITICAL_PERCENT )); then
  log_message error "Expected warning < action < critical disk thresholds."
  exit 64
fi

if [[ ! -f "$ENV_FILE" || ! -f "$COMPOSE_FILE" ]]; then
  log_message error "Missing env or Compose file: env=$ENV_FILE compose=$COMPOSE_FILE"
  exit 66
fi

mkdir -p -- "$ARCHIVE_DIR"
chmod 0700 -- "$ARCHIVE_DIR"

compose=(docker compose --profile admin --env-file "$ENV_FILE" -f "$COMPOSE_FILE")
if ! "${compose[@]}" ps --status running ehub-backend | grep -q 'ehub-backend'; then
  log_message error "ehub-backend is not running; audit export cannot proceed."
  exit 69
fi

period_end="$(date -u +%Y-%m-01T00:00:00Z)"
period_start="$(date -u -d "$period_end -1 month" +%Y-%m-01T00:00:00Z)"
period_label="$(date -u -d "$period_start" +%Y-%m)"
archive_name="admin-audit-${period_label}.ndjson.gz"
archive_path="$ARCHIVE_DIR/$archive_name"
checksum_path="$archive_path.sha256"
manifest_path="$ARCHIVE_DIR/admin-audit-${period_label}.manifest.json"
manifest_checksum_path="$manifest_path.sha256"

if [[ -f "$archive_path" ]]; then
  if [[ ! -f "$checksum_path" ]] || ! (cd "$ARCHIVE_DIR" && sha256sum -c "$(basename "$checksum_path")"); then
    log_message error "Existing archive failed checksum verification: $archive_path"
    exit 65
  fi
  log_message info "Verified existing archive $archive_path"
else
  archive_tmp="$(mktemp "$ARCHIVE_DIR/.admin-audit-${period_label}.XXXXXX")"
  trap 'rm -f -- "${archive_tmp:-}" "${manifest_tmp:-}"' EXIT
  log_message info "Exporting closed period [$period_start, $period_end)"
  "${compose[@]}" exec -T ehub-backend \
    node scripts/export-audit-logs.js \
    "--after=$period_start" "--before=$period_end" \
    | gzip -9 > "$archive_tmp"
  mv -- "$archive_tmp" "$archive_path"
  (cd "$ARCHIVE_DIR" && sha256sum "$archive_name" > "$(basename "$checksum_path")")
fi

archive_sha="$(sha256sum "$archive_path" | awk '{print $1}')"
record_count="$(gzip -cd -- "$archive_path" | wc -l | tr -d ' ')"
previous_manifest="$(find "$ARCHIVE_DIR" -maxdepth 1 -type f -name 'admin-audit-*.manifest.json' ! -path "$manifest_path" -print | sort | tail -n 1)"
previous_manifest_sha=""
if [[ -n "$previous_manifest" ]]; then
  previous_manifest_sha="$(sha256sum "$previous_manifest" | awk '{print $1}')"
fi

if [[ ! -f "$manifest_path" ]]; then
  manifest_tmp="$(mktemp "$ARCHIVE_DIR/.admin-audit-${period_label}.manifest.XXXXXX")"
  printf '{\n  "version": 1,\n  "archiveFile": "%s",\n  "archiveSha256": "%s",\n  "periodStart": "%s",\n  "periodEnd": "%s",\n  "recordCount": %s,\n  "createdAt": "%s",\n  "previousManifestSha256": "%s"\n}\n' \
    "$archive_name" "$archive_sha" "$period_start" "$period_end" "$record_count" \
    "$(date -u +%FT%TZ)" "$previous_manifest_sha" > "$manifest_tmp"
  mv -- "$manifest_tmp" "$manifest_path"
  (cd "$ARCHIVE_DIR" && sha256sum "$(basename "$manifest_path")" > "$(basename "$manifest_checksum_path")")
fi

if [[ ! -f "$manifest_checksum_path" ]] \
  || ! (cd "$ARCHIVE_DIR" && sha256sum -c "$(basename "$manifest_checksum_path")"); then
  log_message error "Manifest failed checksum verification: $manifest_path"
  exit 65
fi
if ! grep -Fq "\"archiveSha256\": \"$archive_sha\"" "$manifest_path"; then
  log_message error "Manifest does not reference the verified archive checksum: $manifest_path"
  exit 65
fi

if [[ -n "$OFFSITE_DEST" ]]; then
  if [[ "$OFFSITE_DEST" == -* ]]; then
    log_message error "Off-site rsync destination must not begin with '-'."
    exit 64
  fi
  if ! command -v rsync >/dev/null 2>&1; then
    log_message error "rsync is required when ADMIN_AUDIT_ARCHIVE_RSYNC_DEST is configured."
    exit 69
  fi
  rsync -a --checksum -- "$archive_path" "$checksum_path" "$manifest_path" "$manifest_checksum_path" "$OFFSITE_DEST/"
  log_message info "Copied archive evidence to configured off-site destination."
elif [[ "$REQUIRE_OFFSITE" == "true" ]]; then
  log_message error "Off-site archival is required but ADMIN_AUDIT_ARCHIVE_RSYNC_DEST is empty."
  exit 78
else
  log_message warning "Archive is staged locally only; configure off-site rsync for host-compromise resilience."
fi

disk_percent="$(docker exec mongodb df -P /data/db | awk 'NR==2 {gsub(/%/, "", $5); print $5}')"
if [[ ! "$disk_percent" =~ ^[0-9]+$ ]] || (( disk_percent < 0 || disk_percent > 100 )); then
  log_message error "Unable to determine MongoDB volume filesystem usage."
  exit 74
fi

mongo_name="$("${compose[@]}" exec -T ehub-backend printenv MONGO_NAME | tr -d '\r\n')"
if [[ ! "$mongo_name" =~ ^[A-Za-z0-9_-]+$ ]]; then
  log_message error "Backend returned an invalid MongoDB database name."
  exit 78
fi
collection_stats="$(docker exec mongodb mongosh --quiet "$mongo_name" --eval '
const s = db.runCommand({collStats: "auditlogs", scale: 1048576});
print(JSON.stringify({documents: s.count || 0, dataMB: s.size || 0,
  storageMB: s.storageSize || 0, indexesMB: s.totalIndexSize || 0,
  totalMB: s.totalSize || 0}));
')"

status_path="$ARCHIVE_DIR/storage-status.json"
printf '{"observedAt":"%s","volume":"%s","usedPercent":%s,"warningPercent":%s,"actionPercent":%s,"criticalPercent":%s,"collection":%s}\n' \
  "$(date -u +%FT%TZ)" "$MONGODB_VOLUME" "$disk_percent" \
  "$WARNING_PERCENT" "$ACTION_PERCENT" "$CRITICAL_PERCENT" "$collection_stats" > "$status_path"

if (( disk_percent >= CRITICAL_PERCENT )); then
  log_message critical "MongoDB filesystem is ${disk_percent}% full. Immediate capacity action is required."
  exit 2
fi
if (( disk_percent >= ACTION_PERCENT )); then
  log_message error "MongoDB filesystem is ${disk_percent}% full. Prepare cleanup or capacity expansion."
  exit 1
fi
if (( disk_percent >= WARNING_PERCENT )); then
  log_message warning "MongoDB filesystem is ${disk_percent}% full. Review growth and retention."
else
  log_message info "MongoDB filesystem usage is ${disk_percent}%."
fi

log_message info "Maintenance complete: archive=$archive_path records=$record_count"
