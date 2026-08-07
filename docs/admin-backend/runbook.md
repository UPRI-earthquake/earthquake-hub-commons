# Admin backend dep-test runbook

The private admin backend provides fixed read-only checks in dep-test and in the
actual-server `admin` profile. It must not be exposed through nginx. This
runbook covers the dep-test workflow; use the
[actual-server smoke runbook](production-read-only-runbook.md) and
[deployment status checklist](server-deployment-status.md) for the server.

## Validate before starting

```bash
docker compose --env-file .dep-test.env -f docker-compose.dep-test.yml config --quiet
docker compose --env-file .env -f docker-compose.yml config --quiet
(cd ../../earthquake-hub-admin/earthquake-hub-admin-backend && npm test)
```

Confirm the rendered `earthquake-hub-backend-dep-test` service has no `/var/run/docker.sock`, host root, SeisComP root, archive mount, `privileged`, `pid: host`, or `network_mode: host`. Its only existing bind mounts are the scoped bastion directory (read-only) and uploads directory (read/write). The admin-backend integration adds no shell endpoint or host mount to the hub backend.

## Start or rebuild dep-test

This recreates dep-test containers and may briefly interrupt the local `ehub.local` stack. It does not remove volumes or production data.

```bash
COMPOSE_BAKE=false docker compose --env-file .dep-test.env -f docker-compose.dep-test.yml up --build -d earthquake-hub-frontend-dep-test admin-backend-dep-test earthquake-hub-backend-dep-test admin-frontend-dep-test nginx-proxy-dep-test
```

## Verify isolation and checks

```bash
docker inspect admin-backend-dep-test --format '{{json .HostConfig.Binds}} {{json .HostConfig.CapDrop}} {{.HostConfig.Privileged}} {{.HostConfig.PidMode}}'
docker inspect earthquake-hub-backend-dep-test --format '{{json .HostConfig.Binds}} {{json .HostConfig.CapDrop}} {{.HostConfig.Privileged}} {{.HostConfig.PidMode}}'
docker exec admin-backend-dep-test sh -c 'wget -q --header="Authorization: Bearer ${ADMIN_HOST_TELEMETRY_TOKEN}" -O - http://127.0.0.1:5100/v1/deployment'
docker exec admin-backend-dep-test sh -c 'wget -q --header="Authorization: Bearer ${ADMIN_HOST_TELEMETRY_TOKEN}" -O - http://127.0.0.1:5100/v1/seiscomp'
docker exec admin-backend-dep-test sh -c 'wget -q --header="Authorization: Bearer ${ADMIN_HOST_TELEMETRY_TOKEN}" -O - http://127.0.0.1:5100/v1/archive'
docker exec admin-backend-dep-test sh -c 'wget -q --header="Authorization: Bearer ${ADMIN_HOST_TELEMETRY_TOKEN}" -O - http://127.0.0.1:5100/v1/system'
```

Deployment and Archive should be `available` after the stack is healthy. The local Archive result is explicitly labeled as the dep-test fixture. SeisComP is checked directly through `host.docker.internal:8080`; it should be `unavailable` when local FDSNWS is not running, and that expected partial failure must not block the other Overview sources.

Run the authenticated proxy/API smoke suite with an existing isolated dep-test admin account:

```bash
ADMIN_SMOKE_IDENTIFIER='…' ADMIN_SMOKE_PASSWORD='…' ./scripts/admin-dep-test-smoke.sh
```

Then verify the Overview, Deployment, SeisComP, Archive & Storage, and Audit Logs pages. Audit Logs should include `admin.telemetry.read` without response bodies.

## Disable or roll back dep-test

To stop only the dep-test adapter:

```bash
docker compose --env-file .dep-test.env -f docker-compose.dep-test.yml stop admin-backend-dep-test
```

The hub backend treats an unavailable adapter as partial telemetry failure; other admin data remains usable. Do not remove MongoDB or archive volumes as part of rollback.

## Future host-service prerequisite

Neither adapter deployment runs host commands. The current production
container reports the intentionally narrow `deployment-container` scope.
Before VM-authoritative telemetry or host mutations are enabled, deploy or
connect a separately reviewed host-native collector under a dedicated
least-privilege identity. Do not give a container a Docker socket, host root
mount, privileged mode, or unrestricted shell access. SeisComP reload/restart,
Inventory Import, raw logs, and Docker service state remain disabled until
their fixed operation contracts and rollback procedures are implemented.
