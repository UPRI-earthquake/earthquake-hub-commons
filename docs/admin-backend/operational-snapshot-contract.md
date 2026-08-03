# Admin operational snapshot contract

Admin monitoring responses separate source availability from evidence
freshness. A successful HTTP response alone must not be displayed as proof that
the underlying evidence is current.

## Snapshot metadata

Monitoring payloads expose:

```json
{
  "observedAt": "2026-07-31T02:00:00.000Z",
  "operational": {
    "contractVersion": "1.0",
    "generatedAt": "2026-07-31T02:00:00.000Z",
    "availability": "available",
    "state": "healthy",
    "freshness": {
      "status": "fresh",
      "observedAt": "2026-07-31T02:00:00.000Z",
      "ageMs": 12,
      "staleAfterMs": 60000
    },
    "message": "Current operational evidence was retrieved."
  }
}
```

`availability` is one of `available`, `degraded`, or `unavailable`.
`freshness.status` is `fresh`, `stale`, or `unknown`. The derived `state`
prioritizes unavailable and degraded evidence before freshness:

1. `unavailable`
2. `degraded`
3. `stale`
4. `healthy`
5. `unknown`

The backend also retains `lastSuccessfulAt`, `failureSince`, and
`failureDurationMs` for private host telemetry resources. Failed reads never
replace the prior successful timestamp.

## Timestamp semantics

- `generatedAt`: response serialization time.
- snapshot `observedAt`: completion time for the bounded snapshot query.
- host telemetry `observedAt`: completion time for the fixed host check.
- event `originTime`: seismic event origin, not delivery time.
- event `observedAt`: when the hub backend persisted the delivered event.
- verification `checkedAt`: when FDSNWS recording verification completed.

Absence of recent earthquakes must not be interpreted as a SeisComP outage.
Process health requires an authoritative heartbeat or host-service observation.

## Stale threshold

`ADMIN_TELEMETRY_STALE_AFTER_MS` defaults to `60000`. Keep it:

- longer than the telemetry check duration and normal network jitter;
- shorter than the operator's expected refresh interval;
- identical in the deployment environment and its documented test setup.

Changing the threshold does not make an unavailable source available. It only
changes when successfully returned evidence is labeled stale.

## Frontend behavior

- Keep the last successful snapshot visible after a refresh failure.
- Mark retained data as degraded and provide an explicit retry.
- Show stale and unknown freshness states without replacing values with zero.
- Never label a snapshot healthy solely because the HTTP request returned 200.
- Continue to render usable metrics from degraded composite snapshots.

The local Playwright suite verifies degraded, stale, and retained-snapshot
behavior. The deployed smoke suite remains read-only and verifies access,
authentication, and sign-out.
