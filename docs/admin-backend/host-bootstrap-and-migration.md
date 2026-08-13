# Admin Console host bootstrap and migration guide

Last reviewed: 2026-08-10

This guide separates the repeatable Admin Console deployment from the small
amount of privileged host preparation it needs. It is intended for a new VM,
a server migration, or a recovery rehearsal.

It does **not** replace the production read-only runbook. That runbook remains
the source for mTLS, environment values, and service-specific verification.

## Design decision: Compose owns containers; the host owns host authority

The `upload-permissions` Compose service is a good Compose pattern: it performs
one bounded permission repair on a known application bind mount, then exits. It
does not create operating-system users, install packages, alter firewall rules,
or gain access to host runtime state.

The host collector and bastion integration are different. They require a
system user/group, a systemd unit, host-network listener visibility, SSH
authorization, and a protected Unix socket. Putting those responsibilities in
a privileged container would broaden the container attack surface and make
ownership during recovery unclear.

| Responsibility | Owner | Why |
| --- | --- | --- |
| Admin frontend/backend, nginx routes, private telemetry network | Docker Compose | Container lifecycle and application configuration |
| Upload directory ownership repair | One-shot Compose service | Narrow, known application mount |
| Host collector user/group, Node runtime, systemd unit, Unix socket | Host bootstrap | Requires host identity and host-network visibility |
| Bastion scripts, SSH material, sudo policy, registry permissions | Host bootstrap | Requires host authorization and protected key material |
| VPN/private ingress, DNS, firewall, VM backups | Infrastructure owner | Outside application scope and often organization-managed |

Do not solve a migration by mounting host root, Docker socket, `/proc`, the
archive, or the tunnel registry into an application container.

## Target migration bundle

Keep the following versioned with the deployment checkout, excluding secrets
and production `.env` files:

```text
earthquake-hub-commons/
  docker-compose.yml
  .env.example
  host-collector/
  bastion/
  scripts/
  docs/admin-backend/
```

Back up and restore these separately through the approved secret/backup
process:

- production `.env`;
- `secrets/admin-telemetry/`, especially the issuer CA key;
- MongoDB data and a tested restore procedure;
- waveform archive and SeisComP configuration/inventory;
- bastion registry and SSH material under `/opt/upri/bastion` and its protected
  registry location.

Never commit any of those secret or host-specific artifacts.

## Idempotent bootstrap script

The host preparation entry point is:

```bash
sudo ./scripts/bootstrap-admin-host.sh --check
sudo ./scripts/bootstrap-admin-host.sh --dry-run \
  --collector-image ghcr.io/upri-earthquake/earthquake-hub-admin-backend:<IMMUTABLE_TAG>
sudo ./scripts/bootstrap-admin-host.sh \
  --collector-image ghcr.io/upri-earthquake/earthquake-hub-admin-backend:<IMMUTABLE_TAG>
```

The script always creates this local deployment-filesystem marker:

```text
<earthquake-hub-commons>/runtime/admin-telemetry/deployment-filesystem
```

It creates an archive marker only when the mounted storage path is explicitly
provided. It resolves the prospective marker path to its containing mount and
refuses root or the same filesystem as the deployment checkout:

```bash
sudo ./scripts/bootstrap-admin-host.sh \
  --collector-image ghcr.io/upri-earthquake/earthquake-hub-admin-backend:<IMMUTABLE_TAG> \
  --archive-marker-path /mnt/storage-server/.earthquake-hub-telemetry
```

This is intentional: remote storage setup and credentials are infrastructure
responsibilities, and a missing archive mount must never silently result in a
marker on the VM root filesystem.

The image must already be pulled and verified. The script creates a stopped
temporary container only to copy `/app/src/hostCollector.js`; it never starts
the image. Alternatively, use a locally reviewed source file:

```bash
sudo ./scripts/bootstrap-admin-host.sh \
  --collector-source /path/to/earthquake-hub-admin-backend/src/hostCollector.js
```

The script’s contract is deliberately conservative:

### It should do

- Check that Node 22 or newer is already installed; fail with a clear
  instruction when it is missing rather than silently changing host packages.
- Create `ehub-admin-telemetry` only if absent.
- Create `ehub-host-collector` only if absent, as a non-login system user in
  that group.
- Install the reviewed collector source and systemd unit only when their
  content differs.
- Create the local deployment filesystem marker automatically.
- Create an archive filesystem marker only after the operator explicitly
  supplies a path on a separately mounted filesystem.
- Create `/etc/earthquakehub-host-collector.env` from the example only when it
  is absent; preserve an existing operator-edited file.
- Run `systemd-analyze verify`, `systemctl daemon-reload`, and enable/start only
  `earthquakehub-host-collector.service`.
- Invoke the existing idempotent `bastion/setup-host.sh` for the bastion assets.
- Report the collector group ID needed by `ADMIN_HOST_COLLECTOR_GID`.
- Offer `--check` as a read-only preflight and `--dry-run` before mutations.

### It must not do

- Install packages, reboot the VM, restart Docker, restart SSH, or restart
  unrelated systemd services without a separate explicit operator action.
- Create or replace telemetry PKI, tokens, `.env`, or administrator allowlists.
- Modify DNS, VPN routing, firewall rules, archive content, SeisComP, MongoDB,
  Docker volumes, or user data.
- Add Docker-socket access, privileged containers, host networking, or broad
  filesystem mounts.

These limits make repeated execution safe and make a failed bootstrap easy to
review and recover from.

## New-server or migration sequence

### 1. Preflight the host

Before copying application data, confirm the VM architecture, Docker Engine,
Docker Compose plugin, systemd, and a supported Node runtime for the collector.
Also identify the real deployment and archive filesystems with `findmnt`.

```bash
uname -m
docker --version
docker compose version
node --version
findmnt -T "$PWD"
findmnt -T <ARCHIVE_ROOT>
```

Do not use a sample marker directory as evidence for both filesystems in a
production migration.

### 2. Restore the deployment checkout and prerequisites

Place the reviewed checkout at its intended path, create the external Docker
network/volume if required, and restore only approved data backups. Do not run
cleanup commands against existing MongoDB volumes or archive paths.

```bash
docker network inspect earthquake-hub-network >/dev/null 2>&1 || \
  docker network create earthquake-hub-network
docker volume inspect earthquake-hub-mongodb-data >/dev/null 2>&1 || \
  docker volume create earthquake-hub-mongodb-data
```

Restore MongoDB only using the documented backup procedure. A migration is not
a reason to initialize an empty database over known-good production data.

### 3. Perform host bootstrap

Run the bootstrap script using the same immutable admin-backend image selected
for the deployment. Review the image digest, source/unit, and dry-run output
before applying it. The script enables or starts only the new collector unit;
it does not restart Docker, WSTunnel, SeisComP, nginx, or MongoDB.

```bash
docker pull ghcr.io/upri-earthquake/earthquake-hub-admin-backend:<IMMUTABLE_TAG>
sudo ./scripts/bootstrap-admin-host.sh --check
sudo ./scripts/bootstrap-admin-host.sh --dry-run \
  --collector-image ghcr.io/upri-earthquake/earthquake-hub-admin-backend:<IMMUTABLE_TAG>
sudo ./scripts/bootstrap-admin-host.sh \
  --collector-image ghcr.io/upri-earthquake/earthquake-hub-admin-backend:<IMMUTABLE_TAG>
```

After the storage administrator restores the archive mount, repeat the command
with `--archive-marker-path /mnt/storage-server/.earthquake-hub-telemetry`.
The script will refuse the path if the remote mount is absent and it resolves
to the VM root/deployment filesystem.

The collector is correctly installed when all of the following are true:

```bash
sudo systemctl is-enabled earthquakehub-host-collector.service
sudo systemctl is-active earthquakehub-host-collector.service
getent group ehub-admin-telemetry
sudo curl --unix-socket /run/earthquakehub-host-collector/collector.sock \
  http://localhost/v1/wstunnel/listeners
```

Expected: `enabled`, `active`, a group ID, and a bounded JSON response. The
response may list zero listeners on a new server.

### 4. Restore secure configuration

Restore `.env` from the protected secret store, then review it against
`.env.example` using the procedure in
[`environment-reference.md`](environment-reference.md). Confirm:

- immutable application image tags and recorded image digests;
- mTLS client/server material and an independent telemetry bearer token;
- real archive and deployment filesystem marker host paths;
- `ADMIN_HOST_COLLECTOR_GID` matches `getent group ehub-admin-telemetry`;
- WSTunnel port ranges match the bastion and collector configuration;
- a stable approved VPN/internal CIDR is used for the nginx admin allowlist.

Generate the runtime-only allowlist on the server; never restore a stale public
IP address from an old server:

```bash
./scripts/configure-admin-access.sh <APPROVED_VPN_OR_INTERNAL_CIDR>
```

The bootstrap output prints the exact marker-path values to place in `.env`.

### 5. Deploy containers and verify

```bash
docker compose --profile admin --env-file .env -f docker-compose.yml pull
docker compose --profile admin --env-file .env -f docker-compose.yml up -d

docker compose --profile admin --env-file .env -f docker-compose.yml \
  config --quiet
docker compose --profile admin --env-file .env -f docker-compose.yml \
  ps admin-backend admin-frontend ehub-backend ehub-frontend nginx-proxy
docker exec nginx-proxy nginx -t
./scripts/admin-production-telemetry-smoke.sh .env
```

Open `/admin/` only from an approved source. Confirm that unauthorised sources
receive `403`, authenticated administrators can sign in, and `/api/admin/`
remains inaccessible without both network access and an administrator session.

### 6. Verify operational data, not only container health

- Check the Deployment page labels match the configured telemetry scope.
- Check a mapped station shows its registry port and corresponding listener
  evidence; a missing listener is a valid device-state result, not a mapping
  import failure.
- Verify archive and deployment filesystem labels refer to their actual mounts.
- Run the scheduled audit-maintenance procedure in dry-run/controlled mode and
  verify backup/restore ownership before enabling retention cleanup.
- Record image digests, operator, timestamp, approved access CIDR owner, and
  rollback tag in the deployment change record.

## Migration acceptance checklist

- [ ] Host prerequisites and real filesystem mounts verified.
- [ ] MongoDB and archive restore process completed and tested.
- [ ] Collector and bastion bootstrap complete without broad host mounts.
- [ ] Telemetry PKI/token restored from protected storage; issuer key remains
      outside containers.
- [ ] Compose configuration validates with the `admin` profile.
- [ ] Private telemetry smoke passes, including WSTunnel when configured.
- [ ] Nginx syntax passes and admin access fails closed outside the approved
      network.
- [ ] Admin sign-in, overview, deployment telemetry, station mappings, and
      listener evidence verified.
- [ ] Image digests, rollback identity, backup status, and responsible owners
      recorded.

## References

- [Docker Compose profiles](https://docs.docker.com/compose/how-tos/profiles/)
- [Docker Compose service configuration](https://docs.docker.com/reference/compose-file/services/)
- [systemd service sandboxing](https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html)
- [Nginx access control module](https://nginx.org/en/docs/http/ngx_http_access_module.html)
