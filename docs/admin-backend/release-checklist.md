# Admin backend release checklist

## Code and contract

- [ ] Hub-backend full Jest suite passes.
- [ ] Admin frontend lint and production build pass.
- [ ] Admin frontend mocked E2E suite and deployed allow/deny smoke pass.
- [ ] Disposable Mongo integration suite passes (`npm run test:integration:mongo`).
- [ ] Degraded, stale, and failed-refresh snapshots render without clearing the last successful evidence.
- [ ] `ADMIN_TELEMETRY_STALE_AFTER_MS` matches the reviewed operator refresh expectation.
- [ ] Admin-backend tests pass.
- [ ] Dep-test and production Compose render successfully.
- [ ] Existing `.env` was compared to `.env.example` by key name only; all reviewed admin variables are present and no placeholder secrets remain.
- [ ] `ADMIN_JOB_*` retention/retry/timeout and `ADMIN_OVERVIEW_*` timeout/cache values match the reviewed operational policy.
- [ ] Admin, hub-backend, and any changed public-frontend image tags are immutable and their digests are recorded.
- [ ] Inventory Import remains `applyEnabled: false` unless the approved executor contract is implemented.
- [ ] Overview partial-failure behavior and five-second cache are verified.
- [ ] Public REST and `SC_EVENT` responses expose the same canonical event-summary contract.

## Security boundary

- [ ] Hub backend has no Docker socket, host PID namespace, privileged mode, host root, SeisComP root, or archive mount.
- [ ] Admin backend exposes only allowlisted read-only operations and has no unrestricted shell or user-selected paths.
- [ ] Admin backend runs read-only, drops all capabilities, and uses `no-new-privileges`.
- [ ] Audit records contain resource/outcome/duration/request ID/classification but no telemetry body or secrets.
- [ ] Audit metadata size/depth limits, secret redaction, immutable records, and cursor pagination pass regression tests.
- [ ] Admin authorization, expired sessions, CSRF-protected mutations, and rejected mutations pass regression tests.
- [ ] Generated nginx admin allow file contains only approved canonical CIDRs; absent/empty configuration returns 403.
- [ ] First-admin bootstrap refuses when an admin exists and never receives a password as a command argument or committed environment value.
- [ ] Admin backend port 5100 is not published and only `ehub-backend` and `admin-backend` are attached to the private telemetry network.
- [ ] mTLS rejects missing/untrusted client identity; hostname verification and the independent bearer token pass the production smoke test.
- [ ] Admin frontend runs read-only without Linux capabilities; frontend, hub backend, and adapter health checks report healthy.

## Dep-test smoke

- [ ] Nginx admin route, login/logout, cookies, profile, all admin routes, and all admin APIs pass.
- [ ] Overview links reach each subsystem.
- [ ] Deployment fixed HTTP check reports independently.
- [ ] SeisComP fixed FDSNWS failure does not block other Overview sources.
- [ ] Archive check reports mount state plus rounded total, used, and available capacity without paths, remote mount identifiers, files, or waveform data.
- [ ] Browser smoke confirms loading, empty, unavailable, unauthorized, and partial-failure states.

## Production blockers

- [ ] Generated mTLS client/server trust, hostname verification, certificate rotation, and the two-service network boundary are tested on the actual server.
- [ ] Host service identity has least-privilege read access; no dep-test unauthenticated mode is enabled.
- [ ] Fixed Docker/SeisComP/archive/log host operations have contract, timeout, redaction, and abuse-case tests.
- [ ] Inventory Import apply/rollback has approval binding, verified backups, reconciliation, and immutable audit evidence.
- [ ] Operator rollback is rehearsed without deleting Docker volumes, MongoDB data, SeisComP inventory, or waveform archives.
- [ ] Audit TTL indexes and historical backfill are verified before enabling retention in production.
- [ ] Incident TTL indexes, dry-run counts, backup, and historical policy reconciliation are reviewed before apply.
- [ ] Station operational-history TTL indexes and the selected retention period are verified; operators understand that history begins at deployment and is not backfilled.
- [ ] Station packet-freshness unique bucket and TTL indexes are verified; sample interval and retention are approved, and operators understand that missing samples are not downtime.
- [ ] Admin background-job TTL index, retention, per-attempt timeout, and maximum attempts are verified without enabling arbitrary execution.
- [ ] Legacy web, device, and barangay signing-key handling is recorded; any forced reauthentication window is approved.
- [ ] Legacy custom event summaries are inventoried and the Approved-only publication cutover is reviewed.
- [ ] Monthly audit archives, checksums/manifests, encrypted off-site transfer, and disk-threshold alert handling are scheduled and tested.

## Event-summary publication rollout

Use immutable, coordinated backend, hub-frontend, and admin-frontend image tags.
Do not apply the migration until the dry-run count and database backup have been
reviewed.

1. Set `EVENT_SUMMARY_ALLOW_UNAPPROVED_COMPAT=true` and deploy the updated
   backend first. This preserves legacy publication while exposing the new
   canonical contract.
2. Deploy the updated public and admin frontends. Confirm the admin Events drawer
   shows generated/custom comparison and the current public source.
3. From the reviewed backend image, run the dry-run and record its count:

   ```bash
   docker compose --profile admin --env-file .env -f docker-compose.yml \
     exec ehub-backend npm run summary-review:backfill
   ```

4. After backup and count approval, apply the migration:

   ```bash
   docker compose --profile admin --env-file .env -f docker-compose.yml \
     exec ehub-backend npm run summary-review:backfill -- --apply
   ```

5. Review each Needs Review summary. Approve text that should remain public;
   revert or leave unapproved text private when the cutover occurs.
6. Set `EVENT_SUMMARY_ALLOW_UNAPPROVED_COMPAT=false`, recreate `ehub-backend`,
   and verify Draft/Needs Review text is absent from public REST and live SSE
   responses while Approved text remains public.
7. Keep rollback bounded to setting the compatibility switch back to `true` and
   recreating only `ehub-backend`; do not roll back by restoring MongoDB unless a
   separately reviewed data recovery is required.
