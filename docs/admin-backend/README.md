# Admin Console deployment documentation

Last reviewed: 2026-08-04

This directory owns deployment configuration and operator procedure for the
Admin Console. Application behavior belongs to the admin frontend, hub backend,
and private adapter repositories.

## Deployed architecture

```text
approved administrator source
  -> nginx allowlist
     -> /admin/       admin-frontend
     -> /api/admin/   ehub-backend

ehub-backend
  -> internal admin-telemetry-network
  -> mTLS + bearer token
  -> admin-backend:5100
       -> read-only filesystem markers
       -> optional Unix socket host collector
```

The `admin` Compose profile keeps optional admin services explicit. The private
adapter has no host-published port and is not routed through nginx. Only
`ehub-backend` and `admin-backend` join the telemetry network.

## Documentation map

| Document | Use it for |
| --- | --- |
| [`server-deployment-status.md`](server-deployment-status.md) | Simple actual-server completed/pending checklist |
| [`deployment-server-test.md`](deployment-server-test.md) | Full first rollout and verification sequence |
| [`environment-reference.md`](environment-reference.md) | Every admin environment variable, default, scope, and secret classification |
| [`production-read-only-runbook.md`](production-read-only-runbook.md) | Filesystem markers, mTLS, private adapter, optional host collector, and telemetry smoke |
| [`release-safety-runbook.md`](release-safety-runbook.md) | Fail-closed nginx allowlist, validation, emergency disable, and rollback |
| [`release-checklist.md`](release-checklist.md) | Cross-repository acceptance and production-readiness gates |
| [`operational-snapshot-contract.md`](operational-snapshot-contract.md) | Fresh/stale/unavailable/partial evidence semantics |
| [`audit-retention-runbook.md`](audit-retention-runbook.md) | Audit dry run, indexes, exports, retention, and storage maintenance |
| [`incident-retention-runbook.md`](incident-retention-runbook.md) | Resolved incident/event retention reconciliation |
| [`legacy-session-rollout.md`](legacy-session-rollout.md) | Generation-bound sessions and old-token expiry/key-rotation decision |
| [`runbook.md`](runbook.md) | Earlier admin backend deployment notes retained for compatibility |

## Key deployment decisions

### Generated nginx allowlist

Tracked nginx configuration always ends admin locations with `deny all`.
`scripts/configure-admin-access.sh` validates operator-supplied CIDRs and writes
runtime-only `allow` directives to `runtime/admin-access.d/allow.conf`.

This keeps host-specific addresses out of Git, prevents stash/pull conflicts,
and fails closed when the generated file is absent or empty. The current actual
server uses a temporary observed public `/32`; an approved stable VPN/internal
administrator CIDR remains the target access model.

### Separate private adapter

Host evidence is not collected by the browser-facing backend. The adapter is
read-only, capability-dropped, `no-new-privileges`, read-only-root, and mounted
only to narrow PKI/marker/socket paths. Mutual TLS, normal hostname
verification, private network membership, and an independent bearer token are
all required in production.

### Filesystem markers

Compose mounts empty markers on the selected deployment and archive
filesystems, not host root or the waveform tree. The adapter can use `statfs`
without receiving directory traversal or waveform access.

### Optional host collector

WSTunnel listener evidence requires a dedicated host-native systemd service
because the adapter container does not own the host network namespace. The
collector exposes one group-protected Unix socket operation and no TCP API.
`wstunnel: unavailable (not_configured)` is acceptable before this optional
service is installed and does not mean WSTunnel is down.

### Release tags and rollback

Use coordinated immutable tags and record remote digests. `latest` may be used
during an explicitly temporary test, but it is not a durable release or
rollback identity. Recreate only changed services and never delete MongoDB,
archive, certificate, or shared Docker volumes to roll back application code.

## Routine checks

```bash
docker compose --profile admin --env-file .env -f docker-compose.yml \
  config --quiet
docker compose --profile admin --env-file .env -f docker-compose.yml \
  ps admin-backend admin-frontend ehub-backend ehub-frontend nginx-proxy
docker exec nginx-proxy nginx -t
./scripts/admin-production-telemetry-smoke.sh .env
```

The telemetry smoke verifies no host-published adapter port, exact private
network membership, loopback health, mTLS/token authentication, and all fixed
resource contracts. A normalized unavailable resource can be an expected
partial result; transport or identity failure is not.

## References

- [nginx access module](https://nginx.org/en/docs/http/ngx_http_access_module.html)
- [Docker Compose profiles](https://docs.docker.com/reference/compose-file/profiles/)
- [Docker Compose networks](https://docs.docker.com/reference/compose-file/networks/)
- [Docker Compose service health checks](https://docs.docker.com/reference/compose-file/services/#healthcheck)
- [Node.js TLS](https://nodejs.org/api/tls.html)

