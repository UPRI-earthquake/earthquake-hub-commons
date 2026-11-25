# Commons deployment configuration runbook

How the Commons Compose and Nginx configuration is set up, validated, checked and rolled back.

**What this runbook is not.** It doesn't authorize changes to the running production server. Deployment automation, staging provisioning and live rollback exercises belong to separate tasks. Follow your team's change approval before running anything here against production.

Findings behind this runbook: [deployment-audit.md](deployment-audit.md). Image tags and promotion: [image-tagging.md](image-tagging.md) and [release-promotion.md](release-promotion.md).

## 1. Files

| File | Purpose |
| --- | --- |
| `docker-compose.yml` | Production stack (`earthquake.up.edu.ph`, Let's Encrypt certificates). |
| `docker-compose.dep-test.yml` | Deployment-test stack (`ehub.local`, self-signed certificate). |
| `.env.example` | Every variable the Compose files read, with placeholder values. Copy it to `.env` on the host. Never commit a filled-in copy. |
| `https_data/nginx.d/nginx.conf` | Production Nginx config. |
| `https_data/nginx.dep-test.d/nginx.dep-test.conf` | Deployment-test Nginx config. |
| `https_data/certbot/conf/` | Shared TLS settings (`options-ssl-nginx.conf`, `ssl-dhparams.pem`). Certbot writes certificates here on the host; they are git-ignored. |
| `wstunnel-restrictions.yaml` | Which reverse tunnels `wstunnel-server` accepts. |
| `ringserver-configs/entrypoint.sh` | Ringserver start-up; creates `ring.conf`, `ring/` and `auth/` on first run (git-ignored). |
| `bastion/` | Host-side tunnel scripts; the backend runs them over SSH. |
| `.github/workflows/ci.yml`, `.github/scripts/` | Static validation that runs on pull requests (section 6). |

Files a host may add that git ignores: `.env`, `.dep-test.env`, `https_data/nginx*.d/*.local*` (host-specific Nginx overrides), `backend-uploads/`, `bastion/ssh/`, and the certbot and ringserver runtime files.

## 2. Deployment prerequisites

On the Docker host, before the first `docker compose up`:

1. Docker Engine with the Compose v2 plugin (`docker compose`).
2. Ports 80 and 443 (Nginx) and 16000 (ringserver) are free and open as required. Port 7001 (WSTunnel, host network) must be reachable from the Docker bridge. See the firewall note in the [README](../README.md#wstunnel-troubleshooting-map).
3. The subnet `172.21.0.0/16` is unused on the host, because the Compose files assign fixed container IPs.
4. The external PostgreSQL volume exists: `docker volume create ehub-postgres-data`. For the deployment-test stack, create `ehub-postgres-data-dep-test` instead. Don't reuse `earthquake-hub-postgres-data`: the backend's local development setup uses that name. The legacy MongoDB volume (`earthquake-hub-mongodb-data`) is only needed when the `legacy-mongodb` profile is used (section 10).
5. `../hazdev-geoserve-ws` is checked out next to this repository. Compose builds the geoserve images from it, and the geoserve database data lives in its `data/` directory.
6. SeisComP's FDSN web service listens on the host at port 8080. Nginx proxies `/fdsnws/` to `host.docker.internal:8080`.
7. A TLS certificate exists for the site name in the Nginx config, under `https_data/certbot/conf/live/<domain>/`. Nginx doesn't start without it.
8. The bastion host setup is done: `sudo ./bastion/setup-host.sh` (see the [README](../README.md#reverse-ssh-bastion-registry)).
9. `.env` is filled in from `.env.example` (section 3).

## 3. Environment variables

`.env.example` is the complete list, and CI fails if a Compose file reads a variable that isn't in it. The names are grouped below; values are never documented here. Variables marked **secret** must be generated for each environment and never shared between environments.

| Group | Variables | Notes |
| --- | --- | --- |
| Image inputs | `EHUB_FRONTEND_IMAGE`, `EHUB_BACKEND_IMAGE`, `EHUB_RINGSERVER_IMAGE` | Optional; see section 4. |
| Backend database | `PG_DATABASE`, `PG_USER`, `PG_PASSWORD` (**secret**); optional `JOB_LOCK_CLEANUP_ENABLED`, `JOB_LOCK_CLEANUP_INTERVAL_MIN` | `ehub-postgres` creates the database and user from these on the first start of an empty volume only (section 10). The Compose files set `PG_HOST` and `PG_PORT` themselves. |
| Reverse geolocation | `GEOSERVE_HOST`, `GEOSERVE_PORT`, `TZ` | |
| Event enrichment | `FDSNWS_DATASELECT_URL`, `FDSNWS_NETWORK`, `FDSNWS_LOCATION`, `FDSNWS_CHANNEL`, `FDSNWS_WINDOW_SECONDS`, `ONLINE_STATION_REFINEMENT_DELAY_MS`, `RECORDING_AVAILABILITY_GRACE_PERIOD_MS`, `RECORDING_AVAILABILITY_RETRY_DELAY_MS`, `RECORDING_AVAILABILITY_MAX_ATTEMPTS`, `EVENT_SOURCE_CATALOG`, `EVENT_SOURCE_SERVER`, `EVENT_SOURCE_SEISCOMP_VERSION`, `ENRICHMENT_CRON`, `ENRICHMENT_MIN_AGE_HOURS`, `MAX_ENRICHMENT_ATTEMPTS`, `ENRICHMENT_BATCH_SIZE`, `ENRICHMENT_RUN_ON_STARTUP`, `ENRICHMENT_STARTUP_DELAY_MS`, `ENRICHMENT_LOCK_TTL_MS`, `USGS_REQUEST_TIMEOUT_MS`, `PUPPETEER_EXECUTABLE_PATH` | |
| Site hosts | `W3_CLIENT_PROD_HOST`, `CLIENT_PROD_HOST`, `BACKEND_PROD_HOST`, `BACKEND_PROD_PORT`; deployment test only: `W3_CLIENT_DEV_HOST`, `CLIENT_DEV_HOST`, `CLIENT_DEV_PORT`, `BACKEND_DEV_HOST`, `BACKEND_DEV_PORT` | The backend builds its CORS origins from these. |
| Ringserver | `RINGSERVER_HOST`, `RINGSERVER_PORT` | |
| Signing keys | `ACCESS_TOKEN_PRIVATE_KEY_WEB`, `REFRESH_TOKEN_PRIVATE_KEY_WEB`, `ACCESS_TOKEN_PRIVATE_KEY_DEVICE`, `ACCESS_TOKEN_PRIVATE_KEY_BRGY`, `REFRESH_TOKEN_PRIVATE_KEY`, `REFRESH_TOKEN_PRIVATE_KEY_BRGY`, `PASSWORD_RESET_TOKEN_KEY`, `ACCESS_TOKEN_PRIVATE_KEY` (all **secret**) | Rotating a key logs out, or invalidates, everything it signed. |
| Token lifetimes | `JWT_WEB_EXPIRY`, `REFRESH_TOKEN_WEB_EXPIRY`, `JWT_EXPIRY`, `JWT_DEVICE_EXPIRY`, `JWT_BRGY_EXPIRY`, `REFRESH_TOKEN_EXPIRY`, `REFRESH_TOKEN_DEVICE_EXPIRY`, `REFRESH_TOKEN_BRGY_EXPIRY`, `PASSWORD_RESET_TOKEN_EXPIRY` | |
| Accounts and reports | `USERNAME_MIN_LENGTH`, `USERNAME_MAX_LENGTH`, `USERNAME_ALLOWED_PATTERN`, `COMMENTS_DEFAULT_STATUS`, `REPORT_POST_RATE_LIMIT_WINDOW_MS`, `REPORT_POST_RATE_LIMIT_MAX` | |
| Uploads | `UPLOAD_DIR`, `UPLOAD_PUBLIC_PATH`, `UPLOAD_HOST_DIR` | The backend refuses to start in production without `UPLOAD_DIR`. `UPLOAD_HOST_DIR` is the host directory mounted there. |
| Email | `EMAIL_TRANSPORT`, `EMAIL_HOST`, `EMAIL_PORT`, `EMAIL_SECURE`, `EMAIL_USER`, `EMAIL_PASS` (**secret**), `EMAIL_FROM`, `EMAIL_LOGO_URL`, `EMAIL_LOGO_PATH`, `EMAIL_LOGO_PUBLIC_FILE`, `EMAIL_FRONTEND_PUBLIC_DIR` | |
| Alerts | `ALERT_EMAIL_ADMIN_TO`, `EMAIL_ALERT_ADMIN_TO`, `ALERT_EMAIL_THREAD_KEY`, `ALERT_EMAIL_THREAD_DOMAIN`, `RSHAKE_ALERT_SHARED_SECRET` (**secret**), `RSHAKE_ALERT_DEVICE_SECRET_BYTES` | |
| Tunnel enrollment | `TUNNEL_REGISTER_SCRIPT`, `TUNNEL_REVOKE_SCRIPT`, `TUNNEL_RESOLVE_SCRIPT`, `TUNNEL_SCRIPT_TIMEOUT_MS`, `TUNNEL_REGISTRY_FILE`, `TUNNEL_BASTION_HOST`, `TUNNEL_BASTION_PORT`, `TUNNEL_BASTION_HOST_KEY`, `TUNNEL_PORT_RANGE_START`, `TUNNEL_PORT_RANGE_END`, `TUNNEL_WSS_URL`, `TUNNEL_WSS_PATH_PREFIX` (**secret** path), `WSTUNNEL_SERVER_VERSION` | `TUNNEL_WSS_PATH_PREFIX` must match the Nginx tunnel location on the host. |
| Tunnel script SSH | `TUNNEL_SCRIPT_EXEC_MODE`, `TUNNEL_SCRIPT_SSH_HOST`, `TUNNEL_SCRIPT_SSH_PORT`, `TUNNEL_SCRIPT_SSH_USER`, `TUNNEL_SCRIPT_SSH_KEY_PATH`, `TUNNEL_SCRIPT_SSH_KNOWN_HOSTS_PATH`, `TUNNEL_SCRIPT_SSH_STRICT_HOST_KEY`, `TUNNEL_SCRIPT_SSH_REMOTE_PREFIX` | Key files live in git-ignored `bastion/ssh/`. |
| Remote actions | `TUNNEL_REMOTE_ACTION_EXEC_MODE`, `TUNNEL_REMOTE_ACTION_TARGET_SSH_HOST`, `TUNNEL_REMOTE_ACTION_RELAY_SSH_REMOTE_PREFIX`, `TUNNEL_REMOTE_ACTION_SSH_HOST`, `TUNNEL_REMOTE_ACTION_SSH_USER`, `TUNNEL_REMOTE_ACTION_SSH_KEY_PATH`, `TUNNEL_REMOTE_ACTION_SSH_KNOWN_HOSTS_PATH`, `TUNNEL_REMOTE_ACTION_SSH_STRICT_HOST_KEY`, `TUNNEL_REMOTE_ACTION_TIMEOUT_MS`, `TUNNEL_REMOTE_ACTIONS_OPERATOR_PUBLIC_KEY`, `TUNNEL_OPERATOR_SSH_PUBLIC_KEY` | |
| Frontend | `PUBLIC_SITE_HOST`, `PUBLIC_SITE_ORIGIN`, `REACT_APP_PUBLIC_VAPID_KEY`, `REACT_APP_BACKEND`, `REACT_APP_FDSNWS`, `REACT_APP_RS_FDSNWS`, `REACT_APP_RINGSERVER_WS`, `REACT_APP_PROD_HOSTS`, `REACT_APP_REMOTE_ACTION_REQUIRE_TUNNEL`, `REACT_APP_DEFAULT_RINGSERVER_USERNAME`, `REACT_APP_SEIS_DEMO`, `REACT_APP_SEIS_DEMO_URL`, `REACT_APP_VERSION`; production: `REACT_APP_GA_MEASUREMENT_ID`; deployment test: `REACT_APP_GA_MEASUREMENT_ID_DEV`, `REACT_APP_BACKEND_DEV`, `REACT_APP_RINGSERVER_WS_DEV` | These are read at container start by the current frontend image. |
| Geoserve database (production file only) | `DATALOAD_DIR`, `DB_ADMIN_USER`, `DB_ADMIN_PASSWORD` (**secret**), `DB_LOAD_TYPE`, `DB_NAME`, `DB_USER`, `DB_PASS` (**secret**), `DB_SCHEMA`, `DB_ADMIN_DSN`, `PGDATA`, `POSTGRES_PASSWORD` (**secret**) | Geoserve's own database, separate from the backend's (`PG_*`). `PGDATA` and the volume path both spell `postgresqsl`; keep them matching. |
| Geoserve web service (production file only) | `DB_DSN`, `DB_USER`, `DB_PASS`, `DB_SCHEMA` | |
| Compose itself | `COMPOSE_PROJECT_NAME` | Optional; see section 5. |

Variables exported in your shell override `.env`. Run Compose from a clean shell on the server.

## 4. Image inputs

Each GHCR image can be set from the environment. When a variable is unset, Compose uses the same `:latest` image as before, so existing hosts behave exactly as they do now.

| Variable | Service | Default |
| --- | --- | --- |
| `EHUB_FRONTEND_IMAGE` | `ehub-frontend` / `earthquake-hub-frontend-dep-test` | `ghcr.io/upri-earthquake/earthquake-hub-frontend:latest` |
| `EHUB_BACKEND_IMAGE` | `ehub-backend` and `ehub-backend-migrate` / `earthquake-hub-backend-dep-test` and `earthquake-hub-backend-migrate-dep-test` | `ghcr.io/upri-earthquake/earthquake-hub-backend:latest` |
| `EHUB_RINGSERVER_IMAGE` | `ringserver` / `ringserver-dep-test` | `ghcr.io/upri-earthquake/receiver-ringserver:latest` |

To pin an environment, set each one to the exact reference from the release record, with both tag and digest:

```dotenv
EHUB_BACKEND_IMAGE=ghcr.io/upri-earthquake/earthquake-hub-backend:sha-<40-char commit>@sha256:<digest>
```

Docker pulls by digest when one is present; the tag is there for people reading the file. Use digests from a recorded promotion ([release-promotion.md](release-promotion.md)), never a value read from a moving tag at deploy time. To confirm what a reference resolves to without pulling it: `docker buildx imagetools inspect <image>:<tag>`.

## 5. Staging isolation

The Compose files assume one stack per Docker host. Run staging on its own VM; don't run it beside production. The table shows what has to be separate and why.

| Item | Production today | Staging |
| --- | --- | --- |
| Project name | No `name:` in the Compose files, so it comes from the checkout directory name. | Set `COMPOSE_PROJECT_NAME`, for example `ehub-staging`. **Don't** add or change a project name on the production host: Compose would treat the running containers as a different project, and the fixed container names would then conflict. |
| Container names | Fixed: `nginx-proxy`, `ehub-frontend`, `ehub-backend`, `ehub-backend-migrate`, `ehub-postgres`, `ringserver`, `wstunnel-server`, and `mongodb` with the `legacy-mongodb` profile. Scripts and docs use these names. | They can only exist once per Docker host, which is one reason staging needs its own VM. |
| Host ports | 80, 443, 16000, and 7001 (`wstunnel-server` uses host networking); `127.0.0.1:27017` with the `legacy-mongodb` profile. PostgreSQL publishes no host port. | Separate VM. Restrict access with the VM's firewall. |
| Network | `earthquake-hub-network`, subnet `172.21.0.0/16`, fixed IPs. The deployment-test file uses the same subnet and IPs. | Separate VM. Two stacks on one host fail with "Pool overlaps". |
| Data | External volume `ehub-postgres-data` (and the legacy `earthquake-hub-mongodb-data`), `UPLOAD_HOST_DIR`, `ringserver-configs/{ring.conf,ring,auth}`, `../hazdev-geoserve-ws/data/`, `bastion/ssh/`. | Staging's own copies. Never mount production volumes or directories. Copying production data (it holds user accounts) needs separate approval. |
| Secrets | `.env`, `bastion/ssh/` keys, certificates, ringserver `auth/`, the Nginx tunnel path secret. | Generate new values. Separate signing keys stop staging tokens from working on production and the other way round. |
| Image inputs | Moving `:latest` defaults. | Set all three `EHUB_*_IMAGE` variables to the digests of the staging candidate (section 4). |
| Site name and TLS | `earthquake.up.edu.ph` and its certificate path are written into `https_data/nginx.d/nginx.conf`. | Needs its own site name and certificate. Keep staging values on the staging host; don't edit the production config for it. How staging provides its Nginx config is decided in the staging deployment task. |
| Outgoing effects | Email, Google Analytics, sensor alert emails, USGS and FDSN queries. | Point email at a test inbox (for example Mailpit), use `REACT_APP_GA_MEASUREMENT_ID_DEV`, and set `ALERT_EMAIL_ADMIN_TO` to a team address, so staging never contacts real users. |

## 6. Validation commands

CI runs three read-only scripts on every pull request to `dev`, `staging` or `main`, and on pushes to those branches. Run them locally before opening a pull request:

```bash
bash .github/scripts/validate-compose.sh   # CI job "Compose config"
bash .github/scripts/validate-nginx.sh     # CI job "Nginx syntax"
bash .github/scripts/validate-static.sh    # CI job "Static checks"
```

| Script | What it checks |
| --- | --- |
| `validate-compose.sh` | Every variable the Compose files read is in `.env.example`. Both files render with `.env.example` without errors or warnings. The pinned references in `.github/scripts/fixtures/pinned-images.env` reach the services. The deployment-test backend gets every variable the production backend does. In each file, the migrate service uses the backend's image and database settings, and `PG_HOST` names a service in that file. Moving default tags are reported as notices. |
| `validate-nginx.sh` | `nginx -t` on both config directories, in the image `docker-compose.yml` uses, with a throwaway certificate and placeholder upstream hosts, and no network. |
| `validate-static.sh` | LF line endings in git. The executable bit on `bastion/` and `ringserver-configs/` scripts. `bash -n` and shellcheck. Python and YAML syntax. No committed `.env` files, private keys, or real tunnel path secret. |

Local requirements: Bash, Docker with Compose v2.17+, and OpenSSL. Shellcheck runs from Docker if it isn't installed. The YAML check needs Python 3 with PyYAML, or yq, and is skipped locally if neither is present. On Windows, use Git Bash.

None of the scripts read `.env`, use credentials, pull application images, or contact a server.

On a server, these read-only checks use the server's real `.env`:

```bash
docker compose config --quiet    # prints nothing when the file and .env are valid
docker exec nginx-proxy nginx -t
```

`docker compose config` without `--quiet` prints the resolved secrets. Don't paste its output anywhere.

## 7. Expected health checks

Only `ehub-postgres` defines a health check, so check the rest by hand after any change. Replace `<site>` with the site name, and `<PG_USER>` and `<PG_DATABASE>` with the values in `.env`.

| Service | Check | Expected |
| --- | --- | --- |
| All | `docker compose ps -a` | Long-running services `running`; `ehub-postgres` `(healthy)`. `upload-permissions` and `ehub-backend-migrate` exited with code 0. `certbot` exits, because it only runs on demand. |
| `ehub-postgres` | `docker exec ehub-postgres pg_isready -h 127.0.0.1 -U <PG_USER> -d <PG_DATABASE>` | `accepting connections` |
| `ehub-backend-migrate` | `docker logs ehub-backend-migrate` | `Batch N run: …` after an upgrade, or `Already up to date` |
| `nginx-proxy` | `docker exec nginx-proxy nginx -t`, then `curl -sI https://<site>/robots.txt` | "syntax is ok", then HTTP 200 |
| `ehub-frontend` | `curl -s -o /dev/null -w '%{http_code}\n' https://<site>/` | `200` |
| `ehub-backend` | `curl -s https://<site>/api/`, and `docker logs --tail 50 ehub-backend` | `{"version":"1.0"}`; the log shows "Connected to PostgreSQL … at ehub-postgres:5432/…", "Production backend listening at …" and no start-up error |
| `ringserver` | `curl -s https://<site>/ringserver/id` | The ringserver ID text |
| `wstunnel-server` | `bastion-tunnel CHECK_WSTUNNEL --compose-dir <commons> --remote-port <port>` | See the [README](../README.md#wstunnel-troubleshooting-map); a plain HTTP request to port 7001 returns 400, as expected |
| FDSN web service (host) | `curl -s https://<site>/fdsnws/event/1/version` | A version string |
| `geoserve-ws`, `geoserve-db` | `docker compose ps` and the backend log | `running`; no geoserve errors in the backend log |

`GET /api/` answers even when the database is down: the backend logs the connection error and keeps running. Check `ehub-postgres` and the "Connected to PostgreSQL" log line separately.

## 8. Troubleshooting

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| `nginx: [emerg] host not found in upstream "ehub-backend"` | Nginx looks up upstream names at start, and the container isn't running. | Start the frontend and backend first, then `docker compose up -d nginx-proxy`. |
| Nginx exits with `cannot load certificate` | No certificate for the configured site name. | Issue the certificate, or fix the path in the Nginx config on the host. |
| 413 on report image upload | Nginx's default 1 MB request limit is lower than the app's 5 MB limit (audit F1). | Pending an approved config change. |
| 502 on `/api/` | Backend crashed or is still starting. | `docker logs ehub-backend`. A common cause is `UPLOAD_DIR must be configured when NODE_ENV=production`. |
| `external volume "ehub-postgres-data" not found` | New host. | `docker volume create ehub-postgres-data`. Only do this on a host that has no data yet. |
| `required variable PG_PASSWORD is missing a value` | `.env` lacks a `PG_*` value. | Fill in `PG_DATABASE`, `PG_USER` and `PG_PASSWORD` (section 3). |
| `service "ehub-backend-migrate" didn't complete successfully: exit 1`, and the backend doesn't start | A migration failed, or the database can't be reached. | `docker logs ehub-backend-migrate`. The backend stays down on purpose, so it never runs on a half-migrated schema. |
| `password authentication failed for user …` | `PG_USER` or `PG_PASSWORD` changed after the volume was first created; they only apply to an empty volume. | Restore the original values in `.env`, or change the password inside PostgreSQL (`ALTER USER`) to match. |
| Backend log: `relation "…" does not exist` | Migrations didn't run: an image without them, or a backend started outside Compose. | `docker compose up -d ehub-backend` runs the migrate service first. Check `docker logs ehub-backend-migrate`. |
| Backend log shows MongoDB connection errors | `EHUB_BACKEND_IMAGE` points at a backend built before the PostgreSQL move. | Use a backend image built from the PostgreSQL backend (section 10). |
| `Pool overlaps with other one on this address space` | Another stack on the host uses `172.21.0.0/16`. | Run one stack per host (section 5). |
| `The container name "/ehub-backend" is already in use` | A second project, or a changed project name, on the same host. | Use the original checkout directory and project name. |
| Ringserver: `permission denied` or `/bin/bash^M: bad interpreter` | `entrypoint.sh` lost its executable bit, or was checked out with CRLF. | CI checks both. On the host: `git config core.autocrlf false`, then `git checkout -- ringserver-configs/entrypoint.sh` and `chmod +x` it. |
| Compose warns `The "X" variable is not set` | `.env` is missing a variable. | Compare with `.env.example`. |
| Geoserve build fails: `unable to prepare context` | `../hazdev-geoserve-ws` is missing. | Clone it next to this repository. |
| Tunnel `Permission denied (publickey)`, or sender 404/504/429 errors | Bastion SSH or WSTunnel setup. | Follow the [README checklist](../README.md#new-server-tunnel-setup-checklist) and [troubleshooting map](../README.md#wstunnel-troubleshooting-map). |

## 9. Restoring a known-good configuration and pinned images

Use this when a configuration or image change has to be undone. Exercising it on staging belongs to the automated deployment task.

### Before any change: record the baseline

Store the record outside the repository directory, where only operators can read it. Don't paste `.env` contents into tickets or chat.

```bash
cd <commons checkout>
git rev-parse HEAD                                   # configuration commit
git status --short                                   # local edits that git doesn't hold
for c in ehub-frontend ehub-backend ringserver; do   # running image digests
  img="$(docker inspect --format '{{.Config.Image}}' "$c")"
  echo "$c $img $(docker image inspect --format '{{join .RepoDigests " "}}' "$img")"
done
mkdir -p -m 700 ~/ehub-backups
install -m 600 .env ~/ehub-backups/env-$(date +%Y%m%d-%H%M)   # private copy of .env
docker compose exec -T ehub-backend npm run --silent db:pg:status   # applied migrations
(umask 077; docker exec ehub-postgres pg_dump -U <PG_USER> -d <PG_DATABASE> -Fc \
  > ~/ehub-backups/pg-$(date +%Y%m%d-%H%M).dump)              # database backup
```

The database backup holds user accounts. Keep it with the same care as `.env`.

Also copy any `https_data/nginx.d/*.local*` override and any local edit to the tracked Nginx config, because git doesn't hold the real tunnel path secret.

### Roll back

1. **Configuration.** Check out the recorded commit: `git checkout <commit>`, or a release tag once tags exist. If the release changed `.env`, restore the private `.env` copy.
2. **Images.** Set `EHUB_FRONTEND_IMAGE`, `EHUB_BACKEND_IMAGE` and `EHUB_RINGSERVER_IMAGE` in `.env` to the recorded `image@sha256:` references. Never use a moving tag such as `latest`.
3. **Validate before applying:** `docker compose config --quiet`, and for an Nginx-only change, `docker exec nginx-proxy nginx -t`.
4. **Apply** to the affected services only:
   - Images or `.env`: `docker compose pull <services>`, then `docker compose up -d <services>`.
   - Nginx config only: `docker exec nginx-proxy nginx -s reload`.
5. **Verify** with section 7 and record what was restored and why.

Rolling back configuration and images does not roll back data. If a release changed the database or the upload directory, restoring it needs a backup taken before the release. An older backend image runs against a newer schema only if the newer migrations kept it compatible; otherwise undo them first (section 10) or restore the database backup.

## 10. Backend database (PostgreSQL)

The backend stores its data in PostgreSQL 18 with PostGIS 3.6 (`postgis/postgis:18-3.6`), in the `ehub-postgres` service (`ehub-postgres-dep-test` in the deployment-test file). The database is reachable only on the Compose network. Schema and rules: the backend's `POSTGRES.md` and `DB_SCHEMA.md`.

### Start-up order

`docker compose up -d` starts the services in this order:

1. `ehub-postgres` starts. On the first start of an empty volume, it creates `PG_USER` and `PG_DATABASE`. It creates no extensions: the first migration adds them.
2. When `ehub-postgres` is healthy, `ehub-backend-migrate` runs `npm run db:pg:migrate` from the backend image and exits. When nothing is pending, it changes nothing.
3. `ehub-backend` starts only if the migration exited with code 0.

So deploying a new backend image applies its migrations before the new backend starts. Back up the database first (section 9).

### Requirements

- **Backend image.** `EHUB_BACKEND_IMAGE` must be a backend built after the move to PostgreSQL. Older backend images still expect MongoDB: they start, but every request that reads or writes data fails. Deploy this Compose configuration and the PostgreSQL backend release together.
- **Volume.** Create `ehub-postgres-data` once (section 2). It's external, so `docker compose down -v` never deletes it.

### Operations

Run these from the Commons checkout. Use `exec` on the running backend rather than `docker compose run`: a `run` container would request the backend's fixed IP, which the running backend already holds.

| Task | Command |
| --- | --- |
| Migration status | `docker compose exec ehub-backend npm run db:pg:status` |
| Undo the last migration batch | `docker compose exec ehub-backend npm run db:pg:rollback`. Only as part of an approved rollback: a `down` migration can drop tables and their data. |
| SQL shell | `docker exec -it ehub-postgres psql -U <PG_USER> -d <PG_DATABASE>` |
| Backup | See section 9. |
| Restore a backup into the existing database | `docker exec -i ehub-postgres pg_restore -U <PG_USER> -d <PG_DATABASE> --clean --if-exists --no-owner < <file>.dump`, with `ehub-backend` stopped |
| Test data (**deployment test only**) | `docker compose -f docker-compose.dep-test.yml exec -e NODE_ENV=development earthquake-hub-backend-dep-test node scripts/seed-dev-data.js`. It adds test accounts with a known password, so **never** run it on production. The script refuses `NODE_ENV=production`; the override is only for test stacks. |

`deploymentTesting/mongodb/import_data.sh` loads test data into MongoDB only; it doesn't apply to the PostgreSQL backend.

### Moving production off MongoDB

Production data is still in MongoDB. Copying it into PostgreSQL is a separate, approved task: the backend's `POSTGRES.md` (section 6) describes it, and the copy scripts are in backend commit `f4e7db9`. Until that task is done and verified:

- The `mongodb` service stays in the Compose files under the `legacy-mongodb` profile. It doesn't start by default, and the backend doesn't depend on it. For the copy: `docker compose --profile legacy-mongodb up -d mongodb`.
- Keep `earthquake-hub-mongodb-data`. It's the source for the copy and for rolling back to the MongoDB backend.
- Removing the service and the volume is a later change, after the move is verified.
