# Admin Console server deployment status

Last reviewed: 2026-08-04

This is a simple status snapshot for the current deployment test. It does not
replace the release checklist or production runbooks. Do not record secrets,
tokens, private keys, or host-specific allowlist addresses in this file.

## Confirmed working

- [x] The deployment checkout contains the production `admin-backend` service
  and generated nginx allowlist mount.
- [x] The four updated application images are available to Compose:
  `admin-backend`, `admin-frontend`, `ehub-backend`, and `ehub-frontend`.
- [x] The Admin Console loads through `/admin/` and an admin can sign in.
- [x] `/admin/` and `/api/admin/` are protected by the generated nginx
  allowlist followed by `deny all`.
- [x] `runtime/admin-access.d/allow.conf` is mounted read-only inside
  `nginx-proxy`.
- [x] `admin-backend` and `ehub-backend` report healthy.
- [x] Admin telemetry port `5100` is not published to the host.
- [x] Only `admin-backend` and `ehub-backend` share the private telemetry
  network.
- [x] mTLS, hostname verification, and the independent bearer token pass the
  production telemetry smoke test.
- [x] Archive, Deployment, SeisComP, and System telemetry report `available`.
- [x] CPU, memory, and disk telemetry are transported from the private adapter.

## Not set up yet

- [ ] Install and enable the optional `earthquakehub-host-collector` systemd
  service.
- [ ] Configure the collector Unix socket path, directory, timeout, and shared
  group ID in `.env`.
- [ ] Recreate `admin-backend` and confirm WSTunnel telemetry no longer reports
  `unavailable (not_configured)`.
- [ ] Replace the temporary public `/32` nginx allow entry with an approved,
  stable VPN or internal administrator CIDR when available.
- [ ] Validate deployment-VM CPU, memory, and filesystem measurements before
  changing `ADMIN_HOST_METRICS_SCOPE` from `deployment-container`.

The missing WSTunnel collector is not a blocker for Admin Console feature
testing. It means host listener evidence is unavailable; it does not prove that
WSTunnel itself is down.

## Still needs verification or operational review

- [ ] Confirm CPU, memory, and disk values render in the Admin Console after a
  browser refresh.
- [ ] Pin `.env` to reviewed immutable image tags and record their remote
  digests instead of relying only on `latest`.
- [ ] Verify audit, incident, station-history, station-telemetry, and background
  job retention indexes and approved retention periods.
- [ ] Schedule and test audit maintenance/archive handling and disk-threshold
  response.
- [ ] Rehearse rollback using immutable image tags without deleting MongoDB,
  Docker volumes, SeisComP inventory, or waveform archives.
- [ ] Assign owners for allowlist changes, certificate rotation, telemetry
  failures, and rollback approval.

## Routine verification

Run after an application or telemetry configuration change:

```bash
docker compose --profile admin --env-file .env -f docker-compose.yml \
  config --quiet
docker compose --profile admin --env-file .env -f docker-compose.yml \
  ps admin-backend admin-frontend ehub-backend ehub-frontend nginx-proxy
docker exec nginx-proxy nginx -t
./scripts/admin-production-telemetry-smoke.sh .env
```

Expected telemetry summary for the current stage:

```text
archive: available
deployment: available
seiscomp: available
system: available
wstunnel: unavailable (not_configured)
```

Continue with `production-read-only-runbook.md` for the optional host collector
and `release-checklist.md` before treating the deployment as production-ready.
