# Admin backend release checklist

## Code and contract

- [ ] Hub-backend full Jest suite passes.
- [ ] Admin frontend lint and production build pass.
- [ ] Admin-backend tests pass.
- [ ] Dep-test and production Compose render successfully.
- [ ] Inventory Import remains `applyEnabled: false` unless the approved executor contract is implemented.
- [ ] Overview partial-failure behavior and five-second cache are verified.

## Security boundary

- [ ] Hub backend has no Docker socket, host PID namespace, privileged mode, host root, SeisComP root, or archive mount.
- [ ] Admin backend exposes only allowlisted read-only operations and has no unrestricted shell or user-selected paths.
- [ ] Admin backend runs read-only, drops all capabilities, and uses `no-new-privileges`.
- [ ] Audit records contain resource/outcome/duration/request ID/classification but no telemetry body or secrets.
- [ ] Admin authorization, expired sessions, CSRF-protected mutations, and rejected mutations pass regression tests.
- [ ] Production `/admin` and `/api/admin` routes remain disabled until an approved VPN/internal CIDR exists.

## Dep-test smoke

- [ ] Nginx admin route, login/logout, cookies, profile, all admin routes, and all admin APIs pass.
- [ ] Overview links reach each subsystem.
- [ ] Deployment fixed HTTP check reports independently.
- [ ] SeisComP fixed FDSNWS failure does not block other Overview sources.
- [ ] Archive check reports only mount state and free-space band.
- [ ] Browser smoke confirms loading, empty, unavailable, unauthorized, and partial-failure states.

## Production blockers

- [ ] mTLS client/server trust, hostname verification, certificate rotation, and network allowlist are implemented and tested.
- [ ] Host service identity has least-privilege read access; no dep-test unauthenticated mode is enabled.
- [ ] Fixed Docker/SeisComP/archive/log host operations have contract, timeout, redaction, and abuse-case tests.
- [ ] Inventory Import apply/rollback has approval binding, verified backups, reconciliation, and immutable audit evidence.
- [ ] Operator rollback is rehearsed without deleting Docker volumes, MongoDB data, SeisComP inventory, or waveform archives.
