# Admin Console release-safety controls

This runbook covers the controls that must be verified before publishing or
deploying the admin frontend, hub backend, or private admin telemetry adapter.
It does not enable Inventory Import apply, Docker control, shell execution, or
arbitrary host access.

## Fail-closed production access

The production nginx routes are tracked and permanently fail closed. Both
`/admin/` and `/api/admin/` load validated `allow` directives from
`runtime/admin-access.d/allow.conf`, followed by a tracked `deny all`. An empty
or missing generated file therefore permits no source address.

Generate the allow file before recreating nginx. Use an approved network CIDR,
not the VM's own private address. Use `/32` for one fixed IPv4 source:

```bash
./scripts/configure-admin-access.sh <APPROVED_VPN_OR_INTERNAL_CIDR>
cat runtime/admin-access.d/allow.conf

docker compose --profile admin --env-file .env -f docker-compose.yml config >/dev/null
docker compose --profile admin --env-file .env -f docker-compose.yml up -d nginx-proxy
docker exec nginx-proxy nginx -t
```

After the new mount exists, later allowlist changes can be validated and
reloaded atomically:

```bash
./scripts/configure-admin-access.sh <APPROVED_CIDR> --reload
```

Emergency fail-closed rollback:

```bash
./scripts/configure-admin-access.sh --disable --reload
```

The script canonicalizes host-form networks. For example,
`10.206.123.45/22` becomes `10.206.120.0/22`. Review that result before reload.
Do not use a private address assigned only to the server VM unless nginx
actually observes administrator requests from that network.

## First-admin bootstrap

The hub backend image contains a one-time first-admin bootstrap command. It:

- refuses to run once any account has the `admin` role;
- accepts the password only through a hidden TTY prompt or protected stdin;
- applies the current username and password policy;
- creates an approved account with only the `admin` role;
- records `admin.account.bootstrap` lifecycle evidence; and
- removes the account if its success audit event cannot be persisted.

On a fresh database only, run:

```bash
docker compose --profile admin --env-file .env -f docker-compose.yml \
  exec ehub-backend npm run admin:bootstrap -- \
  --username=<ADMIN_USERNAME> --email=<ADMIN_EMAIL>
```

Do not run this on the current server if its manually created admin account
already exists; refusal is the expected result. Never place the password in a
command argument, `.env`, Git, task documentation, or chat.

## Health and readiness

The hub backend exposes two minimal internal probes:

- `/health/live` returns success while the Node process can serve requests.
- `/health/ready` returns success only while MongoDB is connected.

The private adapter's deployment check and Docker health check use the readiness
endpoint. The admin frontend exposes `/healthz` inside its container and runs
with a read-only root filesystem, no Linux capabilities, `no-new-privileges`,
and writable tmpfs paths limited to nginx runtime data.

Verify after recreation:

```bash
docker compose --profile admin --env-file .env -f docker-compose.yml ps
docker inspect --format '{{.Name}} {{if .State.Health}}{{.State.Health.Status}}{{end}}' \
  admin-frontend admin-backend ehub-backend
docker exec ehub-backend node -e \
  "fetch('http://127.0.0.1:5000/health/ready').then(async r=>{console.log(r.status,await r.text());process.exit(r.ok?0:1)})"
```

## Browser smoke tests

The admin frontend's deterministic suite mocks the API boundary and verifies
unauthenticated redirect, successful login/sign-out, and recoverable API
failure handling:

```bash
npm ci
npx playwright install chromium
npm run test:e2e
```

To prove that a source outside the allowlist is denied:

```bash
ADMIN_E2E_BASE_URL=https://earthquake.up.edu.ph \
ADMIN_E2E_EXPECT_ACCESS=denied \
npm run test:e2e:deployed
```

From an approved administrator connection, store the password in a temporary
mode-0600 file outside the repository and run:

```bash
ADMIN_E2E_BASE_URL=https://earthquake.up.edu.ph \
ADMIN_E2E_EXPECT_ACCESS=allowed \
ADMIN_E2E_USERNAME=<ADMIN_USERNAME> \
ADMIN_E2E_PASSWORD_FILE=/path/to/protected/password-file \
npm run test:e2e:deployed
```

Remove the temporary credential file using the institution's approved secure
handling procedure. The test logs in, confirms the protected shell, and signs
out; it does not perform administrative mutations.

## Release gate

Before rollout, require all of the following:

1. Backend Jest, admin adapter tests, frontend lint/build/E2E, and both Compose
   renders pass.
2. All three image digests are recorded with the coordinated release tag.
3. `nginx -t` passes with the generated allow file mounted.
4. Containers report healthy without mounting Docker data, MongoDB data, or
   unrestricted host paths into the admin adapter.
5. Deployed smoke proves one denied source and one approved authenticated source.
6. The rollback command and previous image digests are available to the operator.

The current React Router advisory applies to server/RSC action handling, which
this client-only Vite SPA does not use. Record this scoped risk acceptance until
an upstream patched 7.x release is available; do not use `npm audit fix --force`
to downgrade across other known Router security fixes.
