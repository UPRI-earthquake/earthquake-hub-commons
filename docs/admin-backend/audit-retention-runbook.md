# Admin audit retention and archival

The hub backend assigns every new audit event a retention class and an
`expiresAt` timestamp. MongoDB's TTL monitor removes expired records in the
background; expiry is not immediate and may occur after the timestamp.

| Record class | Included events | Default retention |
| --- | --- | --- |
| `routine_telemetry` | Successful `admin.telemetry.read` events | 90 days |
| `administrative` | Admin sign-ins, rate-limit rejections, privileged lifecycle events, and failed/degraded telemetry reads | 730 days |

Administrative coverage includes sign-in/sign-out, CSRF rejections, direct
audit-log access and export, device tunnel enrollment/revocation, account approvals, community-report
moderation, remote device actions, and earthquake summary/enrichment changes.
Future privileged endpoints must use the same audit lifecycle before they are
enabled.

Configure the periods in the deployment `.env`:

```dotenv
ADMIN_AUDIT_TELEMETRY_RETENTION_DAYS=90
ADMIN_AUDIT_ADMINISTRATIVE_RETENTION_DAYS=730
```

Values must be whole days from `0` through `3650`. A value of `0` omits
expiration from new records in that class. Changing a value affects new records
only; it does not revise existing audit evidence.

## First rollout and existing records

Back up the MongoDB volume before applying retention to existing records. The
backfill uses each record's original `createdAt`, so records already older than
their retention period become eligible for MongoDB deletion soon after apply.

After deploying the new hub-backend image, preview the affected records:

```bash
docker compose --profile admin --env-file .env -f docker-compose.yml \
  exec ehub-backend npm run audit-retention:backfill
```

Review the two counts, verify the configured periods, then apply once:

```bash
docker compose --profile admin --env-file .env -f docker-compose.yml \
  exec ehub-backend npm run audit-retention:backfill -- --apply
```

The command classifies only legacy records without `retentionClass`; rerunning
it does not extend or shorten already-classified records.

Verify the TTL index and retention distribution:

```bash
docker exec mongodb mongosh --quiet --eval '
const d = db.getSiblingDB("latestEQs");
printjson(d.auditlogs.getIndexes());
printjson(d.auditlogs.aggregate([
  {$group: {_id: "$retentionClass", records: {$sum: 1}}},
  {$sort: {_id: 1}}
]).toArray());
'
```

Replace `latestEQs` if `MONGO_NAME` differs. Confirm an `expiresAt_1` index with
`expireAfterSeconds: 0` exists.

## Protected archive procedure

Administrative audit exports include usernames, request IP addresses, targets,
and operational metadata. Store them encrypted with access limited to the
designated system administrators. Do not commit exports to Git or leave them in
the Compose checkout.

For one-off recovery or historical backfill, export administrative records for
a closed date range. The `--before` boundary is exclusive and `--after` is
inclusive:

```bash
install -d -m 0700 /path/to/protected-audit-staging
docker compose --profile admin --env-file .env -f docker-compose.yml \
  exec -T ehub-backend node scripts/export-audit-logs.js \
  --after=2026-01-01T00:00:00Z --before=2027-01-01T00:00:00Z \
  | gzip -9 > /path/to/protected-audit-staging/admin-audit-2026.ndjson.gz
sha256sum /path/to/protected-audit-staging/admin-audit-2026.ndjson.gz \
  > /path/to/protected-audit-staging/admin-audit-2026.ndjson.gz.sha256
```

Copy the compressed export and checksum to approved encrypted off-server
storage, verify the copied checksum, and record the custodian, location, date
range, record count, and deletion date. The export reads the selected records
and appends an `admin.audit.export` evidence event; it does not delay TTL expiry.
Schedule archival well before 730 days.

### Automated monthly export and daily storage check

`scripts/admin-audit-maintenance.sh` is an idempotent host-side job. It exports
the previous closed UTC month, verifies or creates SHA-256 checksums, chains each
manifest to the previous manifest, optionally copies all evidence with `rsync`,
checks the MongoDB volume filesystem, writes `storage-status.json`, and reports
to stderr and syslog. It deliberately runs on the host instead of mounting the
Docker socket into another container.

Test it interactively first:

```bash
ADMIN_AUDIT_ARCHIVE_STAGING_DIR=/var/lib/earthquake-hub/audit-archives \
ADMIN_AUDIT_ARCHIVE_RSYNC_DEST='audit-backup@example.internal:/srv/ehub-audit' \
ADMIN_AUDIT_REQUIRE_OFFSITE=true \
./scripts/admin-audit-maintenance.sh .env docker-compose.yml
```

The deployment user needs Docker access and a restricted SSH key accepted only
for the destination archive directory. Do not reuse deployment or administrator
SSH keys. After testing, schedule the same command daily using the host's timer
or cron facility. Example deployment-user crontab entry:

```cron
15 2 * * * cd /path/to/earthquake-hub-commons && ADMIN_AUDIT_ARCHIVE_STAGING_DIR=/var/lib/earthquake-hub/audit-archives ADMIN_AUDIT_ARCHIVE_RSYNC_DEST=audit-backup@example.internal:/srv/ehub-audit ADMIN_AUDIT_REQUIRE_OFFSITE=true ./scripts/admin-audit-maintenance.sh .env docker-compose.yml
```

Exit status `1` means the action threshold was reached, and `2` means critical
capacity. Connect non-zero timer/cron results or the
`admin-audit-maintenance` syslog tag to the institution's alerting system.

## Storage monitoring

Check collection growth monthly and after enabling dashboard auto-refresh:

```bash
docker exec mongodb mongosh --quiet --eval '
const d = db.getSiblingDB("latestEQs");
const s = d.runCommand({collStats: "auditlogs", scale: 1048576});
printjson({documents: s.count, dataMB: s.size, storageMB: s.storageSize,
  indexesMB: s.totalIndexSize, totalMB: s.totalSize});
'
docker volume inspect earthquake-hub-mongodb-data --format '{{.Mountpoint}}'
df -h "$(docker volume inspect earthquake-hub-mongodb-data --format '{{.Mountpoint}}')"
```

Escalate at 70% filesystem use, prepare cleanup/capacity action at 80%, and
treat 90% as urgent. Never manually delete the MongoDB volume to reclaim audit
space.

## Query and document bounds

The API continues to accept `offset` for existing clients and now returns
`pagination.nextCursor`. New clients should send `cursor` instead of increasing
offsets. Audit summaries use one grouped aggregation instead of six separate
count operations. Metadata is redacted and limited by depth, array items,
object keys, string length, and a final 32 KiB budget.

## Security and compliance controls

| Abuse or failure | Impact | Control and evidence |
| --- | --- | --- |
| Unbounded telemetry logging fills disk | API and database outage | 90-day per-record expiry; daily collection/filesystem monitoring |
| Important records expire before preservation | Lost incident evidence | 730-day window plus monthly protected export and checksum |
| Retention typo disables or shortens policy | Unexpected retention behavior | Backend rejects non-integer, negative, or over-10-year settings at startup |
| Application user deletes evidence | Loss or tampering | Audit model rejects updates/deletes; no delete API is exposed |
| Archive is disclosed or modified | Operational data exposure or unreliable evidence | Restricted encrypted off-site storage plus checksum-chained manifests |

Residual risk: MongoDB administrators can alter live records, and a host
administrator can alter local files. Off-server, access-controlled storage is
required when the archive must remain trustworthy after host compromise.
