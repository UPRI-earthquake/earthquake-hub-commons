# Actual-server Admin Console deployment test

This procedure tests the reviewed images with the production
`docker-compose.yml` and `admin` profile. It does not use
`docker-compose.dep-test.yml`.

Recreating `ehub-backend`, the frontends, or nginx causes a short interruption
to those services. The commands below do not remove MongoDB, Docker volumes,
uploads, waveform archives, SeisComP inventory, or WSTunnel state. Never add
`down -v`, volume deletion, or broad host mounts to this procedure.

## 1. Build and publish a release candidate

Use a coordinated SemVer release-candidate tag, not `latest`. Confirm the build
workstation and deployment server architectures first with `uname -m`; use
Buildx with an explicit server platform if they differ.

```bash
RELEASE_TAG=v1.2.0-rc.1

cd /path/to/earthquake-hub-admin-frontend
npm ci
npm run lint
npm run test:e2e
npm run build
docker build -t ghcr.io/upri-earthquake/admin-frontend:${RELEASE_TAG} .
docker push ghcr.io/upri-earthquake/admin-frontend:${RELEASE_TAG}

cd /path/to/earthquake-hub-admin-backend
npm ci
npm test
docker build -t ghcr.io/upri-earthquake/earthquake-hub-admin-backend:${RELEASE_TAG} .
docker push ghcr.io/upri-earthquake/earthquake-hub-admin-backend:${RELEASE_TAG}

cd /path/to/earthquake-hub-backend
npm ci
npm test -- --runInBand
docker build -t ghcr.io/upri-earthquake/earthquake-hub-backend:${RELEASE_TAG} .
docker push ghcr.io/upri-earthquake/earthquake-hub-backend:${RELEASE_TAG}

# Required when this release includes public frontend changes.
cd /path/to/earthquake-hub-frontend
npm ci
npm run lint
CI=true npm test -- --watchAll=false
npm run build
docker build -t ghcr.io/upri-earthquake/earthquake-hub-frontend:${RELEASE_TAG} .
docker push ghcr.io/upri-earthquake/earthquake-hub-frontend:${RELEASE_TAG}
```

Record the digest printed by each push. The release record should map each
service name to its tag, digest, source commit, test result, and previous digest.

## 2. Inspect and update the server checkout

From the server's `earthquake-hub-commons` checkout, record the current state
before changing it:

```bash
git status --short
git branch --show-current
git rev-parse HEAD
docker compose --profile admin --env-file .env -f docker-compose.yml ps
docker inspect admin-frontend admin-backend ehub-backend ehub-frontend \
  --format '{{.Name}} {{.Config.Image}} {{.Image}}' 2>/dev/null
```

Do not pull over unreviewed tracked changes. Preserve `.env`, generated
`runtime/admin-access.d/allow.conf`, telemetry PKI, uploads, and other runtime
files. Update the reviewed deployment branch with the repository's normal
fast-forward-only workflow.

Create a protected backup of `.env` outside the Git checkout using the
institution's approved secret-storage procedure. Do not print it to the
terminal or attach it to a ticket.

## 3. Reconcile `.env` by key name

The following commands print key names only, never values:

```bash
comm -23 \
  <(sed -n 's/^\([A-Z][A-Z0-9_]*\)=.*/\1/p' .env.example | sort -u) \
  <(sed -n 's/^\([A-Z][A-Z0-9_]*\)=.*/\1/p' .env | sort -u)

comm -13 \
  <(sed -n 's/^\([A-Z][A-Z0-9_]*\)=.*/\1/p' .env.example | sort -u) \
  <(sed -n 's/^\([A-Z][A-Z0-9_]*\)=.*/\1/p' .env | sort -u)
```

Add missing reviewed keys manually; do not overwrite `.env` with the example.
At minimum, set the coordinated image selectors:

```dotenv
ADMIN_FRONTEND_IMAGE_TAG=v1.2.0-rc.1
ADMIN_BACKEND_IMAGE_TAG=v1.2.0-rc.1
EHUB_BACKEND_IMAGE_TAG=v1.2.0-rc.1
EHUB_FRONTEND_IMAGE_TAG=v1.2.0-rc.1
```

Review all admin values against `environment-reference.md`. For the private
adapter, complete the mTLS, filesystem-marker, independent bearer-token, and
optional collector preparation in `production-read-only-runbook.md`; do not
enable its URL with placeholder PKI or a blank token.

## 4. Confirm fail-closed nginx access

The allowlist is not stored in `.env`. Generate it only from the approved
source CIDR that nginx observes:

```bash
./scripts/configure-admin-access.sh <APPROVED_VPN_OR_INTERNAL_CIDR>
cat runtime/admin-access.d/allow.conf
```

Review the canonical network printed by the script. Do not use the VM's own SSH
address unless request logs prove that it is the administrator source network.
An empty generated file plus the tracked `deny all` must remain fail-closed.

## 5. Preflight without exposing secrets

Authenticate Docker to GHCR using an account/token with package read access.
Then validate Compose without rendering the environment into logs:

```bash
docker compose --profile admin --env-file .env -f docker-compose.yml config --quiet
docker compose --profile admin --env-file .env -f docker-compose.yml config --images
docker compose --profile admin --env-file .env -f docker-compose.yml \
  pull admin-backend ehub-backend admin-frontend ehub-frontend nginx-proxy
```

Confirm the four application images show the intended release tag. Stop if a
pull is unauthorized, a bind source is missing, a placeholder remains, or the
rendered tag is not the reviewed release.

## 6. Roll out in dependency order

Start the private adapter first, then the browser-facing backend, then the two
frontends. Recreate nginx only because this release includes its tracked admin
route/mount changes; routine application-only releases can validate and reload
the existing nginx container instead.

```bash
docker compose --profile admin --env-file .env -f docker-compose.yml \
  up -d --no-deps admin-backend
docker compose --profile admin --env-file .env -f docker-compose.yml \
  up -d --no-deps ehub-backend
docker compose --profile admin --env-file .env -f docker-compose.yml \
  up -d --no-deps admin-frontend ehub-frontend
docker compose --profile admin --env-file .env -f docker-compose.yml \
  up -d --no-deps nginx-proxy
```

Do not restart MongoDB, Ringserver, WSTunnel, Certbot, or host SeisComP as part
of this rollout.

## 7. Verify containers and private telemetry

```bash
docker compose --profile admin --env-file .env -f docker-compose.yml ps
docker inspect --format '{{.Name}} {{if .State.Health}}{{.State.Health.Status}}{{end}}' \
  admin-frontend admin-backend ehub-backend
docker exec nginx-proxy nginx -t
docker exec ehub-backend node -e \
  "fetch('http://127.0.0.1:5000/health/ready').then(async r=>{console.log(r.status,await r.text());process.exit(r.ok?0:1)}).catch(e=>{console.error(e.message);process.exit(1)})"
./scripts/admin-production-telemetry-smoke.sh .env
```

The telemetry smoke must prove that port `5100` is not host-published, only the
two backends join the private telemetry network, mTLS and the bearer token pass,
and all fixed resource IDs return a normalized response. A failed SeisComP
check may degrade that resource without blocking Deployment, Archive, System,
or WSTunnel evidence.

Inspect bounded recent logs for startup errors without dumping container
environments:

```bash
docker logs --since 10m admin-backend
docker logs --since 10m ehub-backend
docker logs --since 10m admin-frontend
docker logs --since 10m nginx-proxy
```

## 8. Verify the externally exposed route

From an approved administrator connection:

```bash
curl -4 -I https://earthquake.up.edu.ph/admin/
curl -4 -i https://earthquake.up.edu.ph/api/admin/profile
```

`/admin/` should return the SPA successfully. Before login, the profile request
must return `401`, not `403` or `404`. `403` means nginx did not observe an
allowlisted source; `404` means route wiring is wrong.

From a source intentionally outside the allowlist, both admin paths must return
`403`. Do not infer VPN enforcement merely because one changing public Wi-Fi IP
happens to be allowlisted.

Log in through the browser and verify, without invoking destructive actions:

1. Overview loads and distinguishes current, stale, degraded, and unavailable.
2. Accounts, Events, Reports, Stations, Ringserver, SeisComP, Archive,
   Deployment, Audit, and Settings routes load without `404` or repeated `5xx`.
3. A station inspector has one scroll surface and returns focus when closed.
4. Deployment/System telemetry shows its declared scope and source label.
5. Audit reads create bounded, redacted audit evidence.
6. Sign-out invalidates the session and returns to the login route.

The admin frontend repository also provides a non-mutating deployed smoke test;
follow the protected password-file procedure in `release-safety-runbook.md`.

## 9. Apply data-policy migrations separately

Do not combine first-time retention backfills or event-summary publication
cutover with the container availability test. After the release is stable and a
MongoDB backup is confirmed, run each documented dry run, review counts, and
only then use its explicit `--apply` command.

Relevant procedures:

- `audit-retention-runbook.md`
- `incident-retention-runbook.md`
- the event-summary rollout in `release-checklist.md`

Also verify MongoDB TTL indexes for admin jobs, station history, and station
freshness before treating those retention settings as operational.

## 10. Roll back by immutable tag

Restore the previously recorded image tags in `.env`, then recreate only the
affected services:

```bash
docker compose --profile admin --env-file .env -f docker-compose.yml config --quiet
docker compose --profile admin --env-file .env -f docker-compose.yml \
  up -d --no-deps admin-backend ehub-backend admin-frontend ehub-frontend
```

If only private telemetry regressed, clear `ADMIN_HOST_TELEMETRY_URL`, set
`ADMIN_HOST_TELEMETRY_TLS_REQUIRED=false`, clear
`ADMIN_HOST_COLLECTOR_SOCKET_PATH`, recreate only `ehub-backend`, and stop
`admin-backend` as documented in the production read-only runbook.

Do not roll back by rebuilding and overwriting `latest`, switching branches on
the server, deleting MongoDB data, or removing Docker volumes. Those approaches
are slower to verify and do not identify the exact artifact being restored.
