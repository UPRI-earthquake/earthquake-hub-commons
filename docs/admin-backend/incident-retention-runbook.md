# Admin incident retention

Operational incidents are persisted in two MongoDB collections:

- `adminincidents` stores current incident state.
- `adminincidentevents` stores append-only lifecycle evidence such as detected,
  acknowledged, investigating, assigned, resolved, and reopened events.

Active incidents never expire. When an incident resolves, the backend records
the applied retention period and an absolute `expiresAt` timestamp. Reopening
the condition removes both fields. Incident events receive their own absolute
expiry when they are created.

```dotenv
ADMIN_INCIDENT_RESOLVED_RETENTION_DAYS=730
ADMIN_INCIDENT_EVENT_RETENTION_DAYS=730
```

Values must be whole days from `0` through `3650`; `0` means indefinite
retention. Keep event retention greater than or equal to resolved-incident
retention so the lifecycle evidence does not disappear before its incident.
MongoDB TTL cleanup is asynchronous and may occur after `expiresAt`.

## First rollout and policy changes

Back up the MongoDB volume before applying a policy to historical records.
Shortening a period can make old resolved incidents or events immediately
eligible for background deletion.

After deploying the matching hub-backend image, preview the reconciliation:

```bash
docker compose --profile admin --env-file .env -f docker-compose.yml \
  exec ehub-backend npm run incident-retention:backfill
```

The dry run reports:

- resolved incidents whose recorded policy differs;
- active incidents that incorrectly carry retention metadata;
- incident events whose recorded policy differs.

Review the configured periods and counts, confirm the database backup, then
apply:

```bash
docker compose --profile admin --env-file .env -f docker-compose.yml \
  exec ehub-backend npm run incident-retention:backfill -- --apply
```

The command anchors incident expiry to `resolvedAt`, falling back to
`updatedAt` or `createdAt`, and anchors event expiry to `createdAt`. It is safe
to rerun: records already carrying the selected policy are not rewritten.

## Verification

Replace `latestEQs` if `MONGO_NAME` differs:

```bash
docker exec mongodb mongosh --quiet --eval '
const d = db.getSiblingDB("latestEQs");
printjson(d.adminincidents.getIndexes());
printjson(d.adminincidentevents.getIndexes());
printjson(d.adminincidents.aggregate([
  {$group: {_id: {status: "$status", retentionDays: "$retentionDays"},
    records: {$sum: 1}}},
  {$sort: {"_id.status": 1}}
]).toArray());
printjson(d.adminincidentevents.aggregate([
  {$group: {_id: "$retentionDays", records: {$sum: 1}}},
  {$sort: {_id: 1}}
]).toArray());
'
```

Both collections must have an `expiresAt_1` index with
`expireAfterSeconds: 0`. Active incidents must not contain `expiresAt` or
`retentionDays`.

Check storage growth periodically:

```bash
docker exec mongodb mongosh --quiet --eval '
const d = db.getSiblingDB("latestEQs");
for (const name of ["adminincidents", "adminincidentevents"]) {
  const s = d.runCommand({collStats: name, scale: 1048576});
  printjson({collection: name, documents: s.count, dataMB: s.size,
    storageMB: s.storageSize, indexesMB: s.totalIndexSize});
}
'
```

Do not manually delete active incidents, incident history, or the MongoDB
volume to reclaim space. Adjust policy only through a reviewed change with a
backup and dry run.
