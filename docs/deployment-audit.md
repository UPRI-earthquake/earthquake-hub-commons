# Commons deployment configuration audit

Audit of the Compose, Nginx, environment and deployment-script configuration on `dev`, done for the "Standardize EHub Commons Nginx and Docker deployment" task.

- **Baseline:** `dev` at `ba9e8b7` (2026-11-24).
- **Out of scope:** the `admin-dashboard` branch, which is a separate integration stream. It changes the same Compose and Nginx files, so expect small merge conflicts on the image lines when it lands.
- **Production:** nothing here changes the running server. The running configuration is the server's own checkout, `.env` and any `*.local*` overrides, which this audit couldn't see.

Operating procedures are in [deployment-runbook.md](deployment-runbook.md).

## Summary

- `dep-improvements` is fully merged into `dev`: its tip `261740c` was merged in PR #16, and nothing in that branch is missing from `dev`.
- The deployment-test Nginx config **failed to load** from 2026-02-15 until this branch fixed it (F3).
- Two production Nginx problems were confirmed against the committed config, and need an approved change:
  - report images over 1 MB are rejected with 413 (F1);
  - the security headers are missing from almost every response (F2).
- Every application image is a moving `:latest` tag, and nothing has a health check or a restart policy, except `wstunnel-server` (F4, F5).
- Commons had no CI. This branch adds non-deploying checks for Compose, Nginx and scripts. They pass, and they catch each class of error they target (see the validation record).

## Inventory

### Services

| Production service | Deployment-test service | Default image | Host ports | Network / IP | Restart | Health check |
| --- | --- | --- | --- | --- | --- | --- |
| `nginx-proxy` | `nginx-proxy-dep-test` | `nginx:stable` | 80, 443 | app / `.8`, test `.10` | none | none |
| `wstunnel-server` | — | `ghcr.io/erebe/wstunnel:${WSTUNNEL_SERVER_VERSION:-v10.5.2}` | 7001 (host network) | host | `unless-stopped` | none |
| `certbot` | — (commented out) | `certbot/certbot` (no tag) | — | default | none | — (runs on demand) |
| `upload-permissions` | `upload-permissions-dep-test` | `alpine:3.20` | — | default | — (one-shot) | — |
| `ehub-frontend` | `earthquake-hub-frontend-dep-test` | `earthquake-hub-frontend:latest` | — (expose 3000) | app / `.2` | none | none |
| `ehub-backend` | `earthquake-hub-backend-dep-test` | `earthquake-hub-backend:latest` | — (expose 5000) | app / `.3` | none | none |
| `ringserver` | `ringserver-dep-test` | `receiver-ringserver:latest` | 16000 | app / `.4` | none | none |
| `mongodb` | `mongodb-dep-test` | `mongo:5.0` | `127.0.0.1:27017` | app / `.5` | none | none |
| `geoserve-db` | `geoserve-db` | built from `../hazdev-geoserve-ws` (`:latest`) | — | app / `.6` | none | none |
| `geoserve-ws` | `geoserve-ws` | built from `../hazdev-geoserve-ws` (`:latest`) | — (expose 80) | app / `.7` | none | none |

"app" is `earthquake-hub-network` (production) or `earthquake-hub-network-dep-test`. Both use subnet `172.21.0.0/16` and the same fixed IPs. `certbot` and `upload-permissions` join the project's default network.

### Volumes and host paths

| What | Production | Deployment test |
| --- | --- | --- |
| MongoDB data | external volume `earthquake-hub-mongodb-data` | external volume `earthquake-hub-mongodb-data-dep-test` |
| Report uploads | `${UPLOAD_HOST_DIR:-./backend-uploads}` → `${UPLOAD_DIR}` | same |
| Nginx config | `./https_data/nginx.d` (read-only) | `./https_data/nginx.dep-test.d` (read-only) |
| TLS certificates and ACME webroot | `./https_data/certbot/conf`, `./https_data/certbot/www` | same |
| Ringserver config and ring buffer | `./ringserver-configs` (read-write; runtime files git-ignored) | same |
| Bastion scripts and SSH material | `./bastion` → `/opt/upri/bastion` (read-only) | same |
| WSTunnel restrictions | `./wstunnel-restrictions.yaml` | — |
| Geoserve data and source | `../hazdev-geoserve-ws/data/{dataload,pgdata}`, `../hazdev-geoserve-ws/src/*` | same |

### Deployment scripts

| Script | Runs where | Notes |
| --- | --- | --- |
| `ringserver-configs/entrypoint.sh` | Container entrypoint | Must stay executable and LF; CI now checks both. |
| `bastion/setup-host.sh` | Host, once, as root | Creates `tunnel-admin`, the sudoers entries, the device registry and `bastion/ssh/`. |
| `bastion/*.sh` (others) | Host; called by the backend over SSH | Paths come from `TUNNEL_*_SCRIPT`. |
| `seiscomp-scripts/install-services.sh` / `uninstall-services.sh` | SeisComP host | Install systemd units for the messaging proxies. |
| `deploymentTesting/mongodb/import_data.sh`, `deploymentTesting/queryScripts/queryEvents.sh` | Developer or test host | Test data helpers. |

## Comparison with `dep-improvements`

`dep-improvements` was merged into `dev` in PR #16 (`b383a50`). `git log origin/dev..origin/dep-improvements` is empty, and the files this audit covers are identical between the branch tip and `dev`. Since the merge, `dev` has changed only docs: the branching guide, the PR template, the image-tag policy and the release promotion procedure.

What PR #16 brought in (`git log b383a50^1..b383a50^2`, limited to these files), with the environment assumptions it added:

| Change | Commits | Assumption it adds |
| --- | --- | --- |
| Production domain set to `earthquake.up.edu.ph`, plus the default FDSN domain | `b51677c`, `572e9f5` | Domain and certificate path are written into `nginx.d/nginx.conf`. `EVENT_SOURCE_SERVER` defaults to the production server name. |
| Bastion scripts, WSTunnel edge, restrictions and helper commands | `52b81b1`, `5624005`, `8dc56af`, `8da0bb4`, `32a1baa`, `a4de941` | Host port 7001, a firewall rule from the Docker bridge, and a secret tunnel path set on the server. |
| Report upload storage and permissions | `8674faf`, `8c87eb5` | Backend container UID/GID `1000:1000`. |
| Event availability and report variables | `825616a`, `0e1772c` | — |
| Earthquake detail deep links | `4ea8eb0` | Production Nginx only; never added to the deployment-test config. |
| Prefix location matching, restricted messaging, and notification and caching settings | `bd3b3ad`, `4f86000`, `eba34ec` | `eba34ec` also added the deployment-test `@spa_not_found` block that broke that config (F3). |

## Environment-specific assumptions

Values tied to one environment that currently sit in shared configuration:

1. **Site name and certificate path:** in `https_data/nginx.d/nginx.conf` (`earthquake.up.edu.ph`) and `nginx.dep-test.conf` (`ehub.local`).
2. **SeisComP FDSN web service** on the Docker host at port 8080 (`host.docker.internal:8080`).
3. **WSTunnel on the host network, port 7001.** The secret tunnel path is a placeholder in git and set on each server.
4. **Fixed container names, subnet `172.21.0.0/16` and fixed IPs**, which allow one stack per host.
5. **External Docker volumes** that have to be created by hand.
6. **The sibling checkout `../hazdev-geoserve-ws`**, which holds the geoserve database data.
7. **Bastion host state:** the `tunnel-admin` user, `/etc/upri/rshake-tunnels/devices.csv`, and SSH material synced into `bastion/ssh/`.
8. **Backend container UID/GID `1000:1000`**, assumed by `upload-permissions` and `setup-host.sh`.
9. **Compose defaults that carry production values**, for example `EVENT_SOURCE_SERVER=earthquake.up.edu.ph` and `TZ=Asia/Manila`.

## Drift between the production and deployment-test files

- **Compose:**
  - The deployment-test file has no `wstunnel-server` and no `certbot`.
  - Its backend gets every production variable plus five `*_DEV_*` host variables (CI now enforces this).
  - The frontend Google Analytics variable differs on purpose: `REACT_APP_GA_MEASUREMENT_ID` versus `_DEV`.
  - The deployment-test ringserver also exposes 18000.
  - The geoserve passwords are written into the deployment-test file instead of read from `.env` (F9).
- **Nginx:**
  - The deployment-test config lacks the `/earthquake-detail` location, the WSTunnel locations and the rate-limit zones.
  - It has an `@spa_not_found` fallback that production lacks.
- **Both stacks use the same subnet and fixed IPs.**

## Findings

Status: **fixed** means fixed in this branch. **Follow-up** means it needs a separate, approved change, usually because it changes production behaviour.

| ID | Severity | Finding | Evidence | Status |
| --- | --- | --- | --- | --- |
| F1 | High | No `client_max_body_size` in either Nginx config, so Nginx's 1 MB default applies. The frontend and backend both accept report images up to 5 MB, so 1–5 MB uploads fail with 413 at the proxy. | A 2 MB multipart POST to `/api/comments` returned 413 against the production config. Limits: frontend `REPORT_IMAGE_MAX_BYTES` and backend `MAX_IMAGE_BYTES`, both 5 MB. The server may have a local override; check with `nginx -T`. | Follow-up: add `client_max_body_size 6m;` to `location ^~ /api/` in both configs. |
| F2 | Medium | The server-level `add_header` security headers (HSTS, `X-Frame-Options`, `X-Content-Type-Options`, `Referrer-Policy`, `Permissions-Policy`) are only sent from locations that set no headers of their own. Nginx drops inherited headers once a location adds any. That covers `/`, `/api/`, `/uploads/`, static assets and most other locations. | `/robots.txt` returned all the headers; `/api/` returned only `Cache-Control`. | Follow-up: move the headers into an included snippet and include it in every location that sets headers. |
| F3 | High (deployment test) | `nginx.dep-test.conf` didn't load: `proxy_pass` with a URI inside a named location (`@spa_not_found`) is invalid. Introduced in `eba34ec` (2026-02-15). | `nginx -t`: `"proxy_pass" cannot have URI part in location given by regular expression, or inside named location…` | **Fixed:** rewrite to `/index.html`, then `proxy_pass` without a URI. Behaviour is unchanged. |
| F4 | Medium | Every GHCR image is a moving `:latest` tag. `nginx:stable` moves, `certbot/certbot` has no tag, and geoserve is built locally as `:latest`. Rollback to a known image isn't possible from the config. | `docker compose config --images` | **Partly fixed:** the `EHUB_FRONTEND_IMAGE`, `EHUB_BACKEND_IMAGE` and `EHUB_RINGSERVER_IMAGE` inputs take recorded digests, and the defaults are unchanged. Follow-up: pin the defaults once a production baseline is approved, and pin `nginx`, `certbot` and `alpine` versions. `postgis/postgis:18-3.6` (added on `feature/postgres-backend`) also moves with patch releases. |
| F5 | Medium | No health checks. No restart policy except `wstunnel-server`. `depends_on` only waits for a container to start. After a host reboot or a Docker restart, containers stay down unless the host restarts them some other way. | Rendered config | Follow-up: add `restart: unless-stopped` and health checks (backend `GET /`, `nginx -t`), and use `condition: service_healthy`. `feature/postgres-backend` adds the first one: `ehub-postgres` has a `pg_isready` health check, and the migrate service waits for it. |
| F6 | Medium | MongoDB 5.0, which is past end of life, with no authentication. The backend's PostgreSQL migration will need a database service here. | `mongo:5.0`, v5.0.33 | **Superseded** on `feature/postgres-backend`: the backend now uses PostgreSQL (`ehub-postgres`, password-protected, no host port), and `mongodb` is kept only under the off-by-default `legacy-mongodb` profile until production's data is copied (runbook section 10). `chore/mongodb-8-auth` is no longer needed; tell its owner before closing it. |
| F7 | Low | The frontend's runtime configuration (`REACT_APP_*` at container start, and the `/config.js` Nginx location) belongs to the current image. The frontend's move to Vite builds that configuration in at build time. | Frontend repository | Follow-up: agree the frontend deployment model with the frontend team before changing the Compose or Nginx frontend entries. |
| F8 | Low | Fixed container names, host ports, and the same subnet and IPs in both files mean two stacks can't share a host. | Compose files | Documented: staging runs on its own VM (runbook section 5). |
| F9 | Low | The deployment-test geoserve services have their passwords written into the tracked file. Both files mount geoserve data at `postgresqsl` (a typo). The path is consistent with `PGDATA`, so it works, but renaming it would detach existing data. | `docker-compose.dep-test.yml` | Follow-up: read the passwords from `.env`. Leave the path unless a data migration is planned. |
| F10 | Low | `certbot` has no command, and nothing in the repository schedules `certbot renew`. | `docker-compose.yml` | Follow-up: confirm the server has a renewal schedule, or add one with a reload of `nginx-proxy`. |
| F11 | Low | Windows checkouts with `core.autocrlf=true` get CRLF working files. The repository stores LF, but a bind-mounted `entrypoint.sh` from such a checkout would fail. | `git ls-files --eol`: all LF in git | Partly covered: CI rejects CRLF in git. Follow-up: add `.gitattributes` with `*.sh text eol=lf`. |
| F12 | Low | Shellcheck warnings in scripts outside the deployment path: `queryEvents.sh:5` (getopts `-n` not handled), `install-services.sh:6` (`LIST_OF_SCRIPTS` unused), `uninstall-services.sh:7` (`SERVICES_DIR` unused). | shellcheck 0.11.0 | Follow-up: fix them, then hold those scripts to warnings in CI as well. |
| F13 | Info | `.env.example` didn't list `PUBLIC_SITE_HOST`, `PUBLIC_SITE_ORIGIN` or `REACT_APP_PROD_HOSTS`, so Compose warned on every render. Its backend section was labelled "frontend". | Compose warning | **Fixed.** |

## Changes in this branch

| File | Change | Effect on production |
| --- | --- | --- |
| `docker-compose.yml`, `docker-compose.dep-test.yml` | The image lines for frontend, backend and ringserver read `EHUB_*_IMAGE`, defaulting to the current image. | None by default. The rendered config is byte-identical to before with the same `.env`. |
| `https_data/nginx.dep-test.d/nginx.dep-test.conf` | Fixed the `@spa_not_found` block (F3). | None; deployment-test config only. |
| `.env.example` | Image inputs (commented out), the missing site variables, and a header fix. | None; the production server uses its own `.env`. |
| `.github/workflows/ci.yml`, `.github/scripts/*` | Non-deploying CI: Compose, Nginx and static checks. | None. |
| `docs/deployment-runbook.md`, `docs/deployment-audit.md`, `README.md`, `CONTRIBUTING.md` | Documentation. | None. |

## Validation record

Run on 2026-11-24 on Windows 11 with Docker Engine 29.8.1 and Compose v5.5.1. Nginx checks used `nginx:stable` (1.30.8) and shellcheck 0.11.0 (`koalaman/shellcheck:stable`). The YAML check ran under WSL Ubuntu with PyYAML 6.0.3. CI on GitHub hasn't run yet, because the branch isn't pushed.

| Check | Result |
| --- | --- |
| `validate-compose.sh` | Pass. 154 variables listed. Both files render with no warnings. Pinned inputs reach all three services. 116 production backend variables are present in the deployment-test file. 13 notices for moving default tags. |
| `validate-nginx.sh` | Pass for both directories (after the F3 fix). |
| `validate-static.sh` | Pass. LF line endings. Executable bits. `bash -n` on 18 scripts. Shellcheck: 14 deployment scripts at warning level, 4 others at error level. 3 Python files. 2 YAML files. No `.env` files, keys or tunnel secrets. |
| Production render unchanged | `docker compose config` before and after, with the original `.env.example`, is byte-identical for both Compose files. |
| Negative tests (throwaway copy) | Each injected fault failed its check: a variable missing from `.env.example`, a backend variable only in production, an ignored image input, an Nginx syntax error, a CRLF script, a non-executable entrypoint, a shell syntax error, a committed `.env`, a private key, and a real tunnel path. |

After the first CI run on GitHub, the Infrastructure team can make the jobs **Compose config**, **Nginx syntax** and **Static checks** required in the branch rulesets for `dev`, `staging` and `main`.
