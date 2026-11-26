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
4. The external MongoDB volume exists: `docker volume create earthquake-hub-mongodb-data`. For the deployment-test stack, create `earthquake-hub-mongodb-data-dep-test` instead.
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
| MongoDB | `MONGO_CONNX_TYPE`, `MONGO_HOST`, `MONGO_PORT`, `MONGO_NAME` | `MONGO_HOST` is the Compose service name. |
| Web push | `PUBLIC_VAPID_KEY`, `PRIVATE_VAPID_KEY` (**secret**), `WEB_PUSH_CONTACT`, `NOTIF_CLEANUP_ENABLED`, `NOTIF_CLEANUP_INTERVAL_MIN`, `NOTIF_STALE_DAYS`, `NOTIF_FAILURE_THRESHOLD`, `NOTIF_INVALID_TTL_DAYS` | The frontend needs the matching public key. |
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
| Geoserve database (production file only) | `DATALOAD_DIR`, `DB_ADMIN_USER`, `DB_ADMIN_PASSWORD` (**secret**), `DB_LOAD_TYPE`, `DB_NAME`, `DB_USER`, `DB_PASS` (**secret**), `DB_SCHEMA`, `DB_ADMIN_DSN`, `PGDATA`, `POSTGRES_PASSWORD` (**secret**) | `PGDATA` and the volume path both spell `postgresqsl`; keep them matching. |
| Geoserve web service (production file only) | `DB_DSN`, `DB_USER`, `DB_PASS`, `DB_SCHEMA` | |
| Compose itself | `COMPOSE_PROJECT_NAME` | Optional; see section 5. |

Variables exported in your shell override `.env`. Run Compose from a clean shell on the server.

## 4. Image inputs

Each GHCR image can be set from the environment. When a variable is unset, Compose uses the same `:latest` image as before, so existing hosts behave exactly as they do now.

| Variable | Service | Default |
| --- | --- | --- |
| `EHUB_FRONTEND_IMAGE` | `ehub-frontend` / `earthquake-hub-frontend-dep-test` | `ghcr.io/upri-earthquake/earthquake-hub-frontend:latest` |
| `EHUB_BACKEND_IMAGE` | `ehub-backend` / `earthquake-hub-backend-dep-test` | `ghcr.io/upri-earthquake/earthquake-hub-backend:latest` |
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
| Container names | Fixed: `nginx-proxy`, `ehub-frontend`, `ehub-backend`, `ringserver`, `mongodb`, `wstunnel-server`. Scripts and docs use these names. | They can only exist once per Docker host, which is one reason staging needs its own VM. |
| Host ports | 80, 443, 16000, `127.0.0.1:27017`, and 7001 (`wstunnel-server` uses host networking). | Separate VM. Restrict access with the VM's firewall. |
| Network | `earthquake-hub-network`, subnet `172.21.0.0/16`, fixed IPs. The deployment-test file uses the same subnet and IPs. | Separate VM. Two stacks on one host fail with "Pool overlaps". |
| Data | External volume `earthquake-hub-mongodb-data`, `UPLOAD_HOST_DIR`, `ringserver-configs/{ring.conf,ring,auth}`, `../hazdev-geoserve-ws/data/`, `bastion/ssh/`. | Staging's own copies. Never mount production volumes or directories. Copying production data (it holds user accounts) needs separate approval. |
| Secrets | `.env`, `bastion/ssh/` keys, certificates, ringserver `auth/`, the Nginx tunnel path secret. | Generate new values. Separate signing keys stop staging tokens from working on production and the other way round. |
| Image inputs | Moving `:latest` defaults. | Set all three `EHUB_*_IMAGE` variables to the digests of the staging candidate (section 4). |
| Site name and TLS | `earthquake.up.edu.ph` and its certificate path are written into `https_data/nginx.d/nginx.conf`. | Needs its own site name and certificate. Keep staging values on the staging host; don't edit the production config for it. How staging provides its Nginx config is decided in the staging deployment task. |
| Outgoing effects | Email, web push, Google Analytics, sensor alert emails, USGS and FDSN queries. | Point email at a test inbox (for example Mailpit), use separate VAPID keys and `REACT_APP_GA_MEASUREMENT_ID_DEV`, and set `ALERT_EMAIL_ADMIN_TO` to a team address, so staging never contacts real users. |

## 6. Validation commands

CI runs three read-only scripts on every pull request to `dev`, `staging` or `main`, and on pushes to those branches. Run them locally before opening a pull request:

```bash
bash .github/scripts/validate-compose.sh   # CI job "Compose config"
bash .github/scripts/validate-nginx.sh     # CI job "Nginx syntax"
bash .github/scripts/validate-static.sh    # CI job "Static checks"
```

| Script | What it checks |
| --- | --- |
| `validate-compose.sh` | Every variable the Compose files read is in `.env.example`. Both files render with `.env.example` without errors or warnings. The pinned references in `.github/scripts/fixtures/pinned-images.env` reach the services. The deployment-test backend gets every variable the production backend does. Moving default tags are reported as notices. |
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

The Compose files define no health checks yet, so check by hand after any change. Replace `<site>` with the site name.

| Service | Check | Expected |
| --- | --- | --- |
| All | `docker compose ps -a` | Long-running services `running`. `upload-permissions` exited with code 0. `certbot` exits, because it only runs on demand. |
| `nginx-proxy` | `docker exec nginx-proxy nginx -t`, then `curl -sI https://<site>/robots.txt` | "syntax is ok", then HTTP 200 |
| `ehub-frontend` | `curl -s -o /dev/null -w '%{http_code}\n' https://<site>/` | `200` |
| `ehub-backend` | `curl -s https://<site>/api/`, and `docker logs --tail 50 ehub-backend` | `{"version":"1.0"}`; the log shows "Production backend listening at …" and no start-up error |
| `mongodb` | `docker exec mongodb mongosh --quiet --eval 'db.runCommand({ ping: 1 }).ok'` | `1` |
| `ringserver` | `curl -s https://<site>/ringserver/id` | The ringserver ID text |
| `wstunnel-server` | `bastion-tunnel CHECK_WSTUNNEL --compose-dir <commons> --remote-port <port>` | See the [README](../README.md#wstunnel-troubleshooting-map); a plain HTTP request to port 7001 returns 400, as expected |
| FDSN web service (host) | `curl -s https://<site>/fdsnws/event/1/version` | A version string |
| `geoserve-ws`, `geoserve-db` | `docker compose ps` and the backend log | `running`; no geoserve errors in the backend log |

`GET /api/` answers even when MongoDB is down, so check MongoDB separately.

## 8. Troubleshooting

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| `nginx: [emerg] host not found in upstream "ehub-backend"` | Nginx looks up upstream names at start, and the container isn't running. | Start the frontend and backend first, then `docker compose up -d nginx-proxy`. |
| Nginx exits with `cannot load certificate` | No certificate for the configured site name. | Issue the certificate, or fix the path in the Nginx config on the host. |
| 413 on report image upload | Nginx's default 1 MB request limit is lower than the app's 5 MB limit (audit F1). | Pending an approved config change. |
| 502 on `/api/` | Backend crashed or is still starting. | `docker logs ehub-backend`. A common cause is `UPLOAD_DIR must be configured when NODE_ENV=production`. |
| `external volume "earthquake-hub-mongodb-data" not found` | New host. | `docker volume create earthquake-hub-mongodb-data`. Only do this on a host that has no data yet. |
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
```

Also copy any `https_data/nginx.d/*.local*` override and any local edit to the tracked Nginx config, because git doesn't hold the real tunnel path secret.

### Roll back

1. **Configuration.** Check out the recorded commit: `git checkout <commit>`, or a release tag once tags exist. If the release changed `.env`, restore the private `.env` copy.
2. **Images.** Set `EHUB_FRONTEND_IMAGE`, `EHUB_BACKEND_IMAGE` and `EHUB_RINGSERVER_IMAGE` in `.env` to the recorded `image@sha256:` references. Never use a moving tag such as `latest`.
3. **Validate before applying:** `docker compose config --quiet`, and for an Nginx-only change, `docker exec nginx-proxy nginx -t`.
4. **Apply** to the affected services only:
   - Images or `.env`: `docker compose pull <services>`, then `docker compose up -d <services>`.
   - Nginx config only: `docker exec nginx-proxy nginx -s reload`.
5. **Verify** with section 7 and record what was restored and why.

Rolling back configuration and images does not roll back data. If a release changed MongoDB data or the upload directory, restoring it needs a backup taken before the release.
