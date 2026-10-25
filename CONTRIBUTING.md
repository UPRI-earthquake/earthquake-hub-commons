# Contributing to Earthquake Hub Commons

This guide outlines the contribution process for Earthquake Hub's shared infrastructure and deployment configurations.

## Development Workflow

### Branching Strategy

The repository follows this workflow:

`feature/*` / `fix/*` / `docs/*` / `chore/*` → `dev` → `staging` → `main`

- **Working branches:** Infrastructure changes, bug fixes, documentation, and maintenance.
- **`dev`:** Integration of ongoing development.
- **`staging`:** Validation of release candidates.
- **`main`:** Approved production-release source.
- **`hotfix/*`:** Urgent corrections based on the verified production baseline.

Create regular working branches from `dev`.

### Contributions and Pull Requests

1. Create a working branch for the intended change.
2. Document the purpose and expected impact.
3. Validate affected configurations and services.
4. Submit a pull request to `dev`.
5. Address feedback and satisfy the applicable branch protection requirements before merging.

### Branch Protection

- Contributors follow the active GitHub branch rulesets.
- Organization admins may commit directly to `dev` when necessary.
- Changes to `staging` and `main` require pull requests, including for organization admins.
- Organization admins may bypass PR approval requirements where explicitly permitted.
- Protected branches cannot be force-pushed or deleted.

### Release Promotion and Hotfixes

Promote validated changes through `dev` → `staging` → `main` using pull requests.

For urgent production fixes, create `hotfix/*` from the verified production baseline, validate the correction, and merge it through the required release process. Propagate the fix back into active development branches.

## Contribution Guidelines

- Assess the impact of changes on dependent services and environments.
- Validate configurations before proposing deployment.
- Document configuration changes and any necessary migration steps.
- Include rollback considerations for deployment-impacting changes.
- Never commit credentials, secrets, certificates, or sensitive operational data.
- Coordinate production-affecting changes with the responsible maintainers.

For infrastructure-specific procedures, refer to the repository's current operational documentation.
