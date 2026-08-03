# Admin backend production read-only deployment

This runbook deploys the current `earthquake-hub-admin-backend` as a private,
read-only telemetry adapter. It does not enable Docker control, raw logs,
SeisComP commands, Inventory Import apply, arbitrary paths, or shell execution.

The deployment uses two independent service controls:

1. A dedicated Docker network containing only `ehub-backend` and
   `admin-backend`.
2. Mutual TLS with hostname verification, plus the existing bearer token.

The adapter has no host-published port. Its host mounts are narrow, read-only
filesystem markers plus an optional Unix-socket directory for the separately
sandboxed host collector. The collector does not accept TCP traffic, commands,
paths, service names, or requested ports.

## 1. Build and publish immutable images

All three images are required: the admin adapter provides host telemetry, the
hub backend contains the mTLS client and audit policy, and the admin frontend
uses cursor-based audit pagination. Use one coordinated SemVer release tag
instead of overwriting `latest`.

Confirm the server and build-workstation architecture with `uname -m`. When
both are x86-64, run from an authenticated development workstation:

```bash
RELEASE_TAG=v1.1.0-rc.1

cd /path/to/earthquake-hub-admin-frontend
npm ci
npm run lint
npx playwright install chromium
npm run test:e2e
npm run build
docker build \
  -t ghcr.io/upri-earthquake/admin-frontend:${RELEASE_TAG} .
docker push ghcr.io/upri-earthquake/admin-frontend:${RELEASE_TAG}

cd /path/to/earthquake-hub-admin-backend
npm test
docker build \
  -t ghcr.io/upri-earthquake/earthquake-hub-admin-backend:${RELEASE_TAG} .
docker push ghcr.io/upri-earthquake/earthquake-hub-admin-backend:${RELEASE_TAG}

cd /path/to/earthquake-hub-backend
npm test -- --runInBand
docker build \
  -t ghcr.io/upri-earthquake/earthquake-hub-backend:${RELEASE_TAG} .
docker push ghcr.io/upri-earthquake/earthquake-hub-backend:${RELEASE_TAG}
```

The tag above is a coordinated deployment release; it does not replace each
package's own `package.json` version. Record all resulting image digests for review and
rollback. If the workstation architecture differs from the server, use an
installed Buildx builder with the server's explicit `--platform` instead of the
plain builds above.

## 2. Prepare narrow filesystem markers on the server

This changes host directories but does not modify MongoDB, waveform data,
SeisComP inventory, or Docker volumes.

Create one empty directory on the deployment filesystem:

```bash
sudo install -d -o root -g root -m 0555 \
  /var/lib/earthquake-hub/admin-telemetry/deployment-filesystem
```

Create another empty directory on the same filesystem as the waveform archive.
Replace `<ARCHIVE_ROOT>` with the verified archive mount; do not guess it:

```bash
sudo install -d -o root -g root -m 0555 \
  <ARCHIVE_ROOT>/.earthquake-hub-telemetry
findmnt -T <ARCHIVE_ROOT>/.earthquake-hub-telemetry
```

Only the empty marker is mounted. Do not mount `/`, `/var/lib/docker`, the
SeisComP configuration tree, or the full archive into the adapter.

## 3. Generate the private mTLS identity

From the production Compose checkout:

```bash
./scripts/generate-admin-telemetry-pki.sh
```

The script refuses to overwrite an existing identity. `--force` is reserved for
a coordinated rotation in which both containers are recreated together.

Verify that UID 1000 can read only the runtime key material, because both Node
images run as the unprivileged `node` user:

```bash
sudo chown -R 1000:1000 \
  secrets/admin-telemetry/server \
  secrets/admin-telemetry/client
find secrets/admin-telemetry -maxdepth 2 -type f -printf '%M %u:%g %p\n'
```

Back up `secrets/admin-telemetry/issuer/ca.key` in protected offline storage.
It is not mounted into either container and is needed only for certificate
rotation.

## 4. Install the optional host listener collector

This step adds a dedicated host service, OS user, shared group, one installed
JavaScript file, and one systemd unit. It does not restart Docker, WSTunnel,
SeisComP, nginx, or MongoDB. Review the source and unit before running these
commands. Use the collector file from the same reviewed admin-backend release
as the image; do not copy it from an uncommitted working tree.

```bash
getent group ehub-admin-telemetry >/dev/null || \
  sudo groupadd --system ehub-admin-telemetry
id ehub-host-collector >/dev/null 2>&1 || sudo useradd --system \
  --gid ehub-admin-telemetry \
  --home-dir /nonexistent \
  --shell /usr/sbin/nologin \
  ehub-host-collector

sudo install -d -o root -g root -m 0755 /opt/earthquakehub-host-collector
sudo install -o root -g root -m 0555 \
  /path/to/earthquake-hub-admin-backend/src/hostCollector.js \
  /opt/earthquakehub-host-collector/hostCollector.js
sudo install -o root -g root -m 0644 \
  host-collector/earthquakehub-host-collector.service \
  /etc/systemd/system/earthquakehub-host-collector.service
sudo install -o root -g ehub-admin-telemetry -m 0640 \
  host-collector/earthquakehub-host-collector.env.example \
  /etc/earthquakehub-host-collector.env
```

Confirm the two range values in `/etc/earthquakehub-host-collector.env` exactly
match `TUNNEL_PORT_RANGE_START` and `TUNNEL_PORT_RANGE_END`. Then start and
inspect only the new unit:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now earthquakehub-host-collector.service
sudo systemctl status --no-pager earthquakehub-host-collector.service
sudo journalctl -u earthquakehub-host-collector.service --since '10 minutes ago' --no-pager

sudo curl --unix-socket /run/earthquakehub-host-collector/collector.sock \
  http://localhost/v1/wstunnel/listeners
```

The response may legitimately contain zero ports. It must contain only ports in
the configured range and must not contain IP addresses, process details,
commands, environment values, or paths. The dedicated service is intentionally
restricted to `AF_UNIX`; do not add `PrivateNetwork=true`, because that would
move it into a different network namespace and make its listener evidence
incorrect.

The unit runs Node with `--jitless` so systemd can enforce
`MemoryDenyWriteExecute=true`. Use the repository-supported Node 22 or newer;
do not remove either control merely to accommodate an older runtime.

Record the shared group ID for Compose:

```bash
getent group ehub-admin-telemetry | cut -d: -f3
```

## 5. Configure `.env`

Generate a new independent bearer token and place it in `.env`; do not commit or
send it through chat:

```bash
openssl rand -hex 32
```

Set these values:

```dotenv
ADMIN_FRONTEND_IMAGE_TAG=v1.1.0-rc.1
ADMIN_BACKEND_IMAGE_TAG=v1.1.0-rc.1
EHUB_BACKEND_IMAGE_TAG=v1.1.0-rc.1
# Set this when the coordinated release also contains public frontend changes.
EHUB_FRONTEND_IMAGE_TAG=v1.1.0-rc.1

ADMIN_HOST_TELEMETRY_URL=https://admin-backend:5100/v1
ADMIN_HOST_TELEMETRY_TOKEN=<NEW_RANDOM_TOKEN>
ADMIN_HOST_TELEMETRY_TLS_REQUIRED=true
ADMIN_HOST_TELEMETRY_TIMEOUT_MS=2500

ADMIN_TELEMETRY_SERVER_PKI_DIR=./secrets/admin-telemetry/server
ADMIN_TELEMETRY_CLIENT_PKI_DIR=./secrets/admin-telemetry/client
ADMIN_TELEMETRY_CHECK_TIMEOUT_MS=1500
ADMIN_TELEMETRY_DEPLOYMENT_CHECK_URL=http://ehub-backend:5000/health/ready
ADMIN_TELEMETRY_SEISCOMP_CHECK_URL=http://host.docker.internal:8080/fdsnws/dataselect/1/version

ADMIN_TELEMETRY_ARCHIVE_HOST_PATH=<ARCHIVE_ROOT>/.earthquake-hub-telemetry
ADMIN_TELEMETRY_SERVER_FILESYSTEM_HOST_PATH=/var/lib/earthquake-hub/admin-telemetry/deployment-filesystem
ADMIN_TELEMETRY_ARCHIVE_SOURCE_LABEL=Waveform archive filesystem
ADMIN_SERVER_FILESYSTEM_LABEL=Deployment filesystem

ADMIN_HOST_METRICS_SCOPE=deployment-container
ADMIN_HOST_METRICS_SOURCE_LABEL=EarthquakeHub admin telemetry container
ADMIN_HOST_CPU_SAMPLE_MS=150

ADMIN_HOST_COLLECTOR_SOCKET_PATH=/run/earthquakehub-host-collector/collector.sock
ADMIN_HOST_COLLECTOR_SOCKET_DIR=/run/earthquakehub-host-collector
ADMIN_HOST_COLLECTOR_TIMEOUT_MS=1000
ADMIN_HOST_COLLECTOR_GID=<EHUB_ADMIN_TELEMETRY_GROUP_ID>

ADMIN_AUDIT_TELEMETRY_RETENTION_DAYS=90
ADMIN_AUDIT_ADMINISTRATIVE_RETENTION_DAYS=730
ADMIN_JOB_MAX_ATTEMPTS=3
ADMIN_JOB_RETENTION_DAYS=180
ADMIN_JOB_TIMEOUT_MS=3600000
ADMIN_OVERVIEW_SOURCE_TIMEOUT_MS=2500
ADMIN_OVERVIEW_CACHE_TTL_MS=5000
```

See `environment-reference.md` for the complete Admin Console variable catalog,
valid ranges, and the key-only comparison procedure for an existing `.env`.

Keep `ADMIN_HOST_METRICS_SCOPE=deployment-container` for the initial rollout.
Change it to `deployment-vm` only after CPU, memory, and filesystem values have
been compared with direct VM observations and documented as equivalent.

Verify the fixed SeisComP/FDSNWS endpoint on the host before rollout:

```bash
curl -i --max-time 5 http://127.0.0.1:8080/fdsnws/dataselect/1/version
```

An unavailable FDSNWS endpoint should degrade only the SeisComP telemetry
resource; it must not block other Admin Console pages.

## 6. Validate and deploy

Recreating `ehub-backend` causes a short API interruption. It does not recreate
MongoDB or remove any volume.

```bash
docker compose --profile admin --env-file .env -f docker-compose.yml config --quiet
docker compose --profile admin --env-file .env -f docker-compose.yml \
  pull admin-backend ehub-backend
docker compose --profile admin --env-file .env -f docker-compose.yml \
  up -d --no-deps admin-backend
docker compose --profile admin --env-file .env -f docker-compose.yml \
  up -d --no-deps ehub-backend
```

Do not restart nginx, MongoDB, Ringserver, WSTunnel, or SeisComP for this
rollout.

## 7. Verify

```bash
./scripts/admin-production-telemetry-smoke.sh .env
docker logs --since 10m admin-backend
docker logs --since 10m ehub-backend
```

The smoke test proves:

- port 5100 is not published to the host;
- only `admin-backend` and `ehub-backend` share the telemetry network;
- the loopback health endpoint responds;
- the hub backend can authenticate with mTLS and the bearer token;
- all five fixed resource IDs return a normalized adapter response, including
  bounded WSTunnel listener evidence.

Open one mapped station in the Admin Console. Treat `Listener observed` as
point-in-time socket evidence only. `Listener not observed` does not by itself
prove the device is disconnected, and `Evidence unavailable` must remain
distinct from both states.

`seiscomp` may be `unavailable` when FDSNWS is down. Other resources should not
be blocked by that partial failure. Refresh the Admin Console and verify CPU,
memory, disk, Deployment, SeisComP, Archive, and immutable audit events.

For the first rollout of audit retention, follow the backup, dry-run backfill,
TTL-index verification, archival, and storage-monitoring steps in
`docs/admin-backend/audit-retention-runbook.md`.

Before declaring the audit control operational, run and schedule
`scripts/admin-audit-maintenance.sh` with a restricted off-site rsync
destination. A local checksum alone does not protect evidence from deployment
host compromise.

## 8. Roll back

The lowest-risk telemetry-only rollback is to clear these values in `.env`:

```dotenv
ADMIN_HOST_TELEMETRY_URL=
ADMIN_HOST_TELEMETRY_TLS_REQUIRED=false
ADMIN_HOST_COLLECTOR_SOCKET_PATH=
```

Then recreate only the hub backend and stop the adapter:

```bash
docker compose --profile admin --env-file .env -f docker-compose.yml \
  up -d --no-deps ehub-backend
docker compose --profile admin --env-file .env -f docker-compose.yml \
  stop admin-backend
```

The Admin Console returns to partial telemetry mode. Do not remove MongoDB,
archive data, SeisComP inventory, upload storage, or Docker volumes. If the hub
backend or audit UI regressed, restore the previously recorded
`EHUB_BACKEND_IMAGE_TAG` and/or `ADMIN_FRONTEND_IMAGE_TAG`, then recreate only
the affected service.

If only the host collector must be rolled back, clear
`ADMIN_HOST_COLLECTOR_SOCKET_PATH`, recreate `admin-backend`, and stop the unit:

```bash
sudo systemctl disable --now earthquakehub-host-collector.service
```

Leave the installed file and unit in place for review; removing them is a
separate host-change decision.
