# Earthquake Hub staging and release promotion

This is an **operator-controlled workflow**, not a deployment. Frontend and Backend images must be promoted and validated as a compatible pair.

## Current boundaries

- Existing `dev`/full `sha-COMMIT` tags are produced by successful CI.
- Staging workflow: `.github/workflows/promote-staging.yml` in each application repository.
- Release workflow: `.github/workflows/release.yml` in each application repository.
- Both workflows are manually dispatched from the repository's `dev` branch and default to **dry run**.
- Never modify `latest`, `stable`, the production server, or Compose files as part of these workflows.
- Do not attempt a live promotion until team approval and required environment/reviewer governance are confirmed.

## Candidate selection

1. Choose compatible Frontend and Backend full 40-character commit SHAs that were built on `dev` and passed push CI.
2. Record both exact digests from the published `sha-COMMIT` tags. Do not use a mutable `dev` tag as the selection input.
3. Promote the selected code through the regular PR path `dev → staging`. The selected source commit must remain an ancestor of `staging`; otherwise select a commit that meets the condition, without rebuilding.
4. Run **Promote staging image** in each application repository with the SHA and matching `sha256:...` digest, first with `dry_run=true`. Review the preflight summary and confirmations.
5. After **separate team approval** for this specific candidate, optionally run with `dry_run=false` and `confirmation=PROMOTE-STAGING`. The workflow sets `staging` to the same digest. Verify each tag resolves to the recorded digest.
6. Test the selected Frontend/Backend images together in a staging environment; the tag operation itself **does not deploy** them.

## Approved versioned release

1. Complete staging validation and the authorized `staging → main` PR/branch promotion for each application repository.
2. Select a **new** semantic version per repository such as `v1.0.0`; check no matching Git tag, GitHub Release, or GHCR version exists. Do not reuse version numbers.
3. Run **Prepare versioned release** in both repos with each source SHA, digest, version, and `dry_run=true`.
4. Obtain explicit approval for the compatible Frontend/Backend pair. Live promotion uses `dry_run=false` and `confirmation=APPROVE-VERSION`. The workflow assigns `vX.Y.Z` from the existing digest and creates a GitHub Release with the commit and digest recorded.
5. Record the paired release versions and both digests together. Partial success is possible if one component fails; never assume the other release succeeded, and never overwrite an existing version to retry.
6. **Do not move `latest` or deploy automatically.** An approved production-baseline migration must precede using the release as production. `stable` promotion remains manual after an observation period and team approval.

## Release record (copy into the team change log)

| Field | Value |
| --- | --- |
| Candidate/release identifier | |
| Frontend commit SHA and `vX.Y.Z` | |
| Frontend image digest | |
| Backend commit SHA and `vX.Y.Z` | |
| Backend image digest | |
| Successful CI runs | |
| Staging verification and test evidence | |
| Approval and approved date | |
| Current production versions and digests (rollback baseline) | |
| Deployment authorization/reference (if separate) | |

## Rollback and retention

- Deploy or roll back to a recorded `image@sha256:...` reference, **never an unrecorded moving alias**.
- Keep all released versions and any image still deployed to production or staging.
- Do not enable automated registry cleanup until referenced rollout and rollback digests are recorded and protected.
- GitHub Actions environment reviewer settings, if desired, must be configured in repository Settings; a confirmation string alone is **not a substitute for an independent review**.
- The workflows intentionally do not promote `latest` or `stable`.

Related: [image tag policy](./image-tagging.md) and the [CI and tagging ticket](https://app.notion.com/p/400301ef3a0581a08d56dfd8cc18258a).
