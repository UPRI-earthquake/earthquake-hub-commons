# Admin deployment environment reference

This reference covers variables added or consumed by the Admin Console,
browser-facing hub backend, private admin telemetry adapter, and optional host
collector. The complete copyable template remains `.env.example`.

Never commit `.env`. Keep it mode `0600`, replace every placeholder, and do not
paste secret values into commands, tickets, logs, or chat. Compose defaults are
useful for local compatibility, but production must explicitly record reviewed
image tags, retention periods, access policy, and telemetry security settings.

## Public site and coordinated images

| Variable | Default/example | Purpose |
| --- | --- | --- |
| `PUBLIC_SITE_HOST` | `<ehub-domain>` | Canonical hostname without scheme or path, used by public-frontend URL fallbacks. |
| `PUBLIC_SITE_ORIGIN` | `https://<ehub-domain>` | Canonical browser origin without a trailing slash. |
| `REACT_APP_PROD_HOSTS` | `<ehub-domain>` | Comma-separated hostnames accepted by the public frontend. |
| `ADMIN_FRONTEND_IMAGE_TAG` | `latest` | Admin SPA image selector. Set to the reviewed immutable SemVer release tag in production. |
| `ADMIN_BACKEND_IMAGE_TAG` | `latest` | Private read-only telemetry-adapter image selector. |
| `EHUB_BACKEND_IMAGE_TAG` | `latest` | Browser-facing API and admin control-plane image selector. |
| `EHUB_FRONTEND_IMAGE_TAG` | `latest` | Public EarthquakeHub frontend image selector. |

Use the same coordinated release tag when these repositories are tested and
released together. Record the image digest for each service; a tag alone is not
proof that the same artifact will remain available.

## Retention and bounded background work

| Variable | Default | Valid values and effect |
| --- | ---: | --- |
| `ADMIN_AUDIT_TELEMETRY_RETENTION_DAYS` | `90` | Whole days `0-3650` for successful `admin.telemetry.read` records. `0` omits expiry from newly created records. |
| `ADMIN_AUDIT_ADMINISTRATIVE_RETENTION_DAYS` | `730` | Whole days `0-3650` for authentication, mutation, failure, export, and other administrative audit evidence. |
| `ADMIN_INCIDENT_RESOLVED_RETENTION_DAYS` | `730` | Whole days `0-3650` after resolution. Active incidents do not expire. |
| `ADMIN_INCIDENT_EVENT_RETENTION_DAYS` | `730` | Whole days `0-3650` for append-only incident events. Keep this at least as long as resolved incidents. |
| `ADMIN_STATION_HISTORY_RETENTION_DAYS` | `365` | Whole days `1-3650` for station activity and WSTunnel registry transitions. |
| `ADMIN_STATION_TELEMETRY_SAMPLE_INTERVAL_SECONDS` | `900` | Whole seconds `60-86400` between retained packet-freshness samples. This is not a latency or uptime measurement. |
| `ADMIN_STATION_TELEMETRY_RETENTION_DAYS` | `90` | Whole days `1-3650` for sampled station freshness evidence. |
| `ADMIN_JOB_MAX_ATTEMPTS` | `3` | Whole number `1-10`; includes the original background-job attempt and approved retries. |
| `ADMIN_JOB_RETENTION_DAYS` | `180` | Whole days `0-3650` for terminal background-job records; `0` means indefinite retention for new jobs. |
| `ADMIN_JOB_TIMEOUT_MS` | `3600000` | Per-attempt timeout `60000-86400000` milliseconds. It does not authorize arbitrary commands. |

MongoDB TTL deletion is asynchronous. Changing retention values affects new
records until the corresponding reviewed reconciliation/backfill procedure is
run. Follow the audit and incident retention runbooks before applying policy to
historical records.

## Overview aggregation

| Variable | Default | Purpose |
| --- | ---: | --- |
| `ADMIN_OVERVIEW_SOURCE_TIMEOUT_MS` | `2500` | Maximum time for each Overview source before that source is marked unavailable. Other sources still render. |
| `ADMIN_OVERVIEW_CACHE_TTL_MS` | `5000` | Short server-side cache for the aggregated Overview snapshot, reducing repeated fan-out work during refreshes. |
| `ADMIN_TELEMETRY_STALE_AFTER_MS` | `60000` | Age after which operational evidence is presented as stale rather than current. |

All three values are milliseconds and must be positive integers. A timeout
should remain lower than the operator-facing refresh interval, and the cache
must remain short enough that the console does not imply old evidence is live.

## Server-authoritative admin controls

Each switch below accepts `true` or `false`. `false` disables the backend route
and is reflected in frontend capabilities. These switches do not replace
admin-role authorization, recent-authentication checks, CSRF protection,
confirmation, or immutable audit evidence.

| Variable | Controlled operation |
| --- | --- |
| `ADMIN_ACCOUNT_APPROVAL_ENABLED` | Approve or reject pending barangay accounts. |
| `ADMIN_ACCOUNT_LIFECYCLE_ENABLED` | Activate or deactivate accounts. |
| `ADMIN_ACCOUNT_SESSION_REVOCATION_ENABLED` | Revoke active web sessions for an account. |
| `ADMIN_ACCOUNT_ROLE_MANAGEMENT_ENABLED` | Assign `admin-viewer`, `operator`, or `super-admin` tiers. |
| `ADMIN_INCIDENT_MANAGEMENT_ENABLED` | Acknowledge, investigate, assign, annotate, resolve, or reopen persistent incidents. |
| `ADMIN_REPORT_MODERATION_ENABLED` | Moderate community reports and transition persistent moderation cases. |
| `ADMIN_REPORT_DELETION_ENABLED` | Permanently delete a community report after guarded confirmation. |
| `ADMIN_EVENT_SUMMARY_ENABLED` | Create or edit generated/custom event summaries. |
| `ADMIN_EVENT_SUMMARY_REVIEW_ENABLED` | Submit, approve, revert, and control publication of event summaries. |
| `ADMIN_EVENT_ENRICHMENT_ENABLED` | Queue bounded event-enrichment jobs. |
| `ADMIN_EVENT_RECORDING_REFRESH_ENABLED` | Queue bounded recording-availability verification. |
| `ADMIN_DEVICE_REMOTE_ACTIONS_ENABLED` | Apply approved remote Ringserver configuration to sender devices. |
| `ADMIN_TUNNEL_REVOCATION_ENABLED` | Revoke a WSTunnel registry mapping. |

Related controls:

| Variable | Default | Purpose |
| --- | ---: | --- |
| `ADMIN_RECENT_AUTH_MAX_AGE_SECONDS` | `900` | Maximum age of the administrator authentication accepted for guarded actions. |
| `EVENT_SUMMARY_ALLOW_UNAPPROVED_COMPAT` | `false` | Temporary migration switch that allows legacy unapproved custom summaries to remain public. Return it to `false` after review. |
| `ADMIN_AUTH_RATE_LIMIT_WINDOW_MS` | `900000` | Admin-login throttle window. |
| `ADMIN_AUTH_RATE_LIMIT_IP_MAX` | `30` | Maximum attempts per source address during that window. |
| `ADMIN_AUTH_RATE_LIMIT_IDENTIFIER_MAX` | `5` | Maximum attempts per normalized username/email during that window. |

Inventory Import apply, SeisComP service control, deployment lifecycle control,
raw logs, Docker control, arbitrary paths, and shell execution are not enabled
by any variable in this template.

## Private read-only telemetry

The browser never calls `admin-backend` directly. Requests flow from nginx to
the authenticated `/api/admin/*` routes in `ehub-backend`, which alone can call
the adapter on the two-service private Docker network.

| Variable | Default/example | Purpose |
| --- | --- | --- |
| `ADMIN_HOST_TELEMETRY_URL` | empty | Adapter base URL. Empty disables private telemetry. Production value is `https://admin-backend:5100/v1`. |
| `ADMIN_HOST_TELEMETRY_TOKEN` | empty | Independent random bearer token shared only by the two backends. Empty causes adapter requests to fail closed. |
| `ADMIN_HOST_TELEMETRY_TIMEOUT_MS` | `2500` | Hub-backend timeout for one adapter request. |
| `ADMIN_HOST_TELEMETRY_TLS_REQUIRED` | `false` | Set `true` in production so the hub backend requires HTTPS, CA trust, and a client identity. |
| `ADMIN_TELEMETRY_SERVER_PKI_DIR` | `./secrets/admin-telemetry/server` | Host directory mounted read-only into the adapter with its CA, server certificate, and private key. |
| `ADMIN_TELEMETRY_CLIENT_PKI_DIR` | `./secrets/admin-telemetry/client` | Host directory mounted read-only into the hub backend with its CA, client certificate, and private key. |
| `ADMIN_TELEMETRY_CHECK_TIMEOUT_MS` | `1500` | Adapter timeout for each fixed downstream HTTP check. |
| `ADMIN_TELEMETRY_DEPLOYMENT_CHECK_URL` | hub readiness URL | Fixed deployment readiness endpoint; request input cannot replace it. |
| `ADMIN_TELEMETRY_SEISCOMP_CHECK_URL` | host FDSNWS version URL | Fixed SeisComP/FDSNWS reachability endpoint. Its failure degrades only that resource. |
| `ADMIN_TELEMETRY_ARCHIVE_HOST_PATH` | sample marker | Empty host directory on the waveform archive filesystem, mounted read-only for `statfs`. Never use the archive root. |
| `ADMIN_TELEMETRY_SERVER_FILESYSTEM_HOST_PATH` | sample marker | Empty host directory on the deployment filesystem, mounted read-only for `statfs`. Never use `/` or Docker data. |
| `ADMIN_TELEMETRY_ARCHIVE_SOURCE_LABEL` | configured label | Safe operator-facing archive-filesystem label; the host path is not returned. |
| `ADMIN_SERVER_FILESYSTEM_LABEL` | configured label | Safe operator-facing deployment-filesystem label. |
| `ADMIN_HOST_METRICS_SCOPE` | `deployment-container` | Evidence scope shown in the UI. Keep this value until VM equivalence is verified. |
| `ADMIN_HOST_METRICS_SOURCE_LABEL` | configured label | Safe source label displayed with CPU/memory/filesystem evidence. |
| `ADMIN_HOST_CPU_SAMPLE_MS` | `150` | CPU sampling period, bounded by the adapter to `50-1000` milliseconds. |

Compose fixes the adapter's `PORT`, loopback `HEALTH_PORT`, TLS mode, certificate
paths, and container marker paths. Operators should not override those internal
container values in `.env`.

## Optional host listener collector

| Variable | Default/example | Purpose |
| --- | --- | --- |
| `ADMIN_HOST_COLLECTOR_SOCKET_PATH` | empty | Unix-socket path used by the adapter. Empty disables host listener evidence. |
| `ADMIN_HOST_COLLECTOR_SOCKET_DIR` | `./runtime/admin-host-collector` | Host directory containing only the protected collector socket. |
| `ADMIN_HOST_COLLECTOR_TIMEOUT_MS` | `1000` | Adapter-to-collector timeout; implementation caps it at `2000` ms. |
| `ADMIN_HOST_COLLECTOR_GID` | `65534` | Numeric host group ID added to the adapter container so it can read the socket. Replace with the actual `ehub-admin-telemetry` GID. |

The systemd collector has a separate protected environment file:

| Variable | Purpose |
| --- | --- |
| `HOST_COLLECTOR_WSTUNNEL_PORT_RANGE_START` | First loopback listener port the collector may report; match `TUNNEL_PORT_RANGE_START`. |
| `HOST_COLLECTOR_WSTUNNEL_PORT_RANGE_END` | Last permitted port; match `TUNNEL_PORT_RANGE_END`; inclusive range is limited to 4096 ports. |
| `HOST_COLLECTOR_SOCKET_PATH` | Absolute group-protected Unix-socket path. The collector creates no TCP listener. |

## Nginx access is not an environment variable

`/admin/` and `/api/admin/` are fail-closed through
`runtime/admin-access.d/allow.conf`. Generate that file with
`scripts/configure-admin-access.sh`; do not place a CIDR in `.env` and do not
edit the tracked nginx file with a host-specific address. The allowlist must be
the source address or network nginx actually observes, not the VM's own private
SSH address.

## Compare an existing `.env` without printing secrets

Run from the Compose checkout. The first command lists template keys missing
from `.env`; the second lists local/legacy keys not present in the template.
Neither command prints values.

```bash
comm -23 \
  <(sed -n 's/^\([A-Z][A-Z0-9_]*\)=.*/\1/p' .env.example | sort -u) \
  <(sed -n 's/^\([A-Z][A-Z0-9_]*\)=.*/\1/p' .env | sort -u)

comm -13 \
  <(sed -n 's/^\([A-Z][A-Z0-9_]*\)=.*/\1/p' .env.example | sort -u) \
  <(sed -n 's/^\([A-Z][A-Z0-9_]*\)=.*/\1/p' .env | sort -u)
```

Do not replace the existing `.env` wholesale: that risks losing production
secrets and host-specific values. Add reviewed missing keys, keep known legacy
keys until their consumers are checked, and validate with `docker compose
config --quiet`.
