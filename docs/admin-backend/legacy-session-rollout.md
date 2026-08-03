# Legacy session and signing-key rollout

New web, admin, device, and barangay sessions carry an account
`sessionVersion`. Deactivation, session revocation, and admin-role changes
increment that version, causing generation-bound access and refresh tokens to
fail their next database-backed validation.

Tokens issued before this support do not carry `sessionVersion`. A legacy
access token remains usable until its expiry unless its signing key is rotated.
A valid legacy refresh token may be upgraded only while the account is active,
still owns the role, and its persisted session version remains `0`.

## Required rollout decision

Record one decision for each token scope before deployment:

| Scope | Variables | Recommended first rollout |
| --- | --- | --- |
| Web and admin | `ACCESS_TOKEN_PRIVATE_KEY_WEB`, `REFRESH_TOKEN_PRIVATE_KEY_WEB`, `JWT_WEB_EXPIRY`, `REFRESH_TOKEN_WEB_EXPIRY` | Rotate both keys during a reviewed maintenance window if immediate legacy-admin invalidation is required; this also signs out citizen and barangay browser sessions. Otherwise preserve the keys and accept the bounded legacy window. |
| Sender/device | `ACCESS_TOKEN_PRIVATE_KEY_DEVICE`, `REFRESH_TOKEN_PRIVATE_KEY`, `JWT_DEVICE_EXPIRY`, `REFRESH_TOKEN_DEVICE_EXPIRY` | Preserve compatibility until sender reauthentication and recovery are tested. Set the scoped access key equal to the current legacy access key for the first rollout. |
| Barangay bearer | `ACCESS_TOKEN_PRIVATE_KEY_BRGY`, `REFRESH_TOKEN_PRIVATE_KEY_BRGY`, `JWT_BRGY_EXPIRY`, `REFRESH_TOKEN_BRGY_EXPIRY` | Preserve compatibility unless all clients can be deliberately reauthenticated; the configured lifetimes may be long. |

Do not copy a placeholder from `.env.example`, print secrets into tickets, or
run `docker compose config` into an unprotected log. All token settings are read
when `ehub-backend` starts.

## Recommended sequence

1. Inventory the configured lifetimes and determine the latest possible expiry
   of legacy access and refresh tokens.
2. Confirm at least two active super-admin accounts and test one fresh admin
   login before changing web keys.
3. Keep device and barangay scoped keys compatible for the first deployment
   unless a coordinated client reauthentication window is approved.
4. Deploy the generation-aware backend. Verify that newly issued tokens contain
   an account ID and session version without recording the token itself.
5. Test session revocation against a disposable account: its old
   generation-bound session must return `401`; account deactivation or role
   removal must return `403`.
6. If immediate legacy-admin cutoff is required, rotate both web access and web
   refresh keys, restart only `ehub-backend`, and require administrators and
   browser users to sign in again.
7. Rotate device or barangay keys only in a separate, approved change after
   enrollment, refresh, offline recovery, and rollback have been exercised.

## Safe state inspection

This command reports only whether scoped keys are present or still equal to a
legacy fallback; it does not print their values:

```bash
docker compose --profile admin --env-file .env -f docker-compose.yml \
  exec ehub-backend node -e '
const e = process.env;
console.log(JSON.stringify({
  webAccessScoped: Boolean(e.ACCESS_TOKEN_PRIVATE_KEY_WEB),
  webRefreshScoped: Boolean(e.REFRESH_TOKEN_PRIVATE_KEY_WEB),
  deviceAccessScoped: Boolean(e.ACCESS_TOKEN_PRIVATE_KEY_DEVICE),
  deviceAccessMatchesLegacy:
    Boolean(e.ACCESS_TOKEN_PRIVATE_KEY_DEVICE) &&
    e.ACCESS_TOKEN_PRIVATE_KEY_DEVICE === e.ACCESS_TOKEN_PRIVATE_KEY,
  brgyAccessScoped: Boolean(e.ACCESS_TOKEN_PRIVATE_KEY_BRGY),
  brgyRefreshScoped: Boolean(e.REFRESH_TOKEN_PRIVATE_KEY_BRGY),
  expiries: {
    webAccess: e.JWT_WEB_EXPIRY,
    webRefresh: e.REFRESH_TOKEN_WEB_EXPIRY,
    deviceAccess: e.JWT_DEVICE_EXPIRY || e.JWT_EXPIRY,
    deviceRefresh: e.REFRESH_TOKEN_DEVICE_EXPIRY || e.REFRESH_TOKEN_EXPIRY,
    brgyAccess: e.JWT_BRGY_EXPIRY,
    brgyRefresh: e.REFRESH_TOKEN_BRGY_EXPIRY
  }
}, null, 2));
'
```

## Rollback

Retain the previous image tag and protected previous key material until the
acceptance window closes. Rolling back the image does not restore sessions
invalidated by a key rotation or account-generation increment. Restoring an old
signing key can re-enable still-unexpired legacy tokens, so it requires an
explicit security decision rather than an automatic rollback.
