# Earthquake Hub container image tags

Applies to the Frontend and Backend images in `ghcr.io/upri-earthquake/`. The Commons repository maintains deployment configuration but does not publish an application image.

| Tag | Meaning | Update rule |
| --- | --- | --- |
| `dev` | Latest successfully verified development build | Automatically after successful CI on the current `dev` HEAD |
| `sha-COMMIT` | Image built for one full 40-character Git commit SHA | Write once; never intentionally retag or rebuild under the same SHA tag |
| `staging` | Selected candidate under pre-production testing | Manual promotion of an already-published digest; may lag behind `dev` |
| `vX.Y.Z` | Approved semantic-version release | Write once, with a GitHub Release and recorded image digest |
| `latest` | Newest *approved production* release | Manual approved promotion; **do not change the existing tag during setup** |
| `stable` | Last known-good release retained as a rollback reference | Manual promotion after successful production observation and team approval |

## Promotion and rollback rules

1. PR checks never publish images. Successful CI on a `dev` push publishes `sha-COMMIT` and moves `dev`, only if that commit is still the current `dev` HEAD.
2. Promote **the same image digest** to `staging`, then to `vX.Y.Z` and `latest` after release approval. Do not rebuild an image during promotion.
3. Consider promoting `stable` only after an agreed production observation period (initial guideline: 7–14 days), with no unresolved critical regressions and explicit team approval. `stable` may intentionally lag behind `latest`.
4. Record the Frontend and Backend image digests, their compatible version pair, CI evidence, promotion decision, and any rollback reference. Deploy and roll back using the recorded `image@sha256:...` digest (or an exact, controlled release version), **not** moving aliases.
5. Keep `sha-COMMIT` and `vX.Y.Z` write-once by process and workflow checks. These checks are not a registry-wide immutability guarantee; repository/package administrators must also avoid manually replacing or deleting released artifacts.
6. Neither `latest` nor `stable` should be changed automatically during development. Existing `latest` images and Compose references stay untouched until migration is separately approved.

## Implementation boundary

**Active now:** automatic `dev` and `sha-COMMIT` publishing from verified `dev` CI. The publisher checks for an existing commit tag before publishing so reruns reuse rather than overwrite the tag.

**Not yet active:** staging selection, versioned GitHub Releases, `latest` release promotion, and manual `stable` promotion. Those approval-controlled workflows belong to the next implementation stage. A tag's existence does not itself deploy the application.

See the [GitHub Actions + image tagging task](https://app.notion.com/p/400301ef3a0581a08d56dfd8cc18258a) for current rollout status.
