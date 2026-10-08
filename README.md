# ci-workflows

Shared reusable GitHub Actions workflows and operator scripts for Gnzaga homelab app repos.

## Trust model
| Workflow | Job | Runner | Code trust | Secrets |
| --- | --- | --- | --- | --- |
| `pr-ci.yml` | `ci` | GitHub-hosted `ubuntu-latest` | untrusted (PR code) | none |
| `build-deploy.yml` | `build` | GitHub-hosted `ubuntu-latest` | merged code only | `GITHUB_TOKEN` (push to GHCR) |
| `build-deploy.yml` | `deploy` | ARC `arc-<repo>` (in-cluster) | merged code only | `production` env |

`deploy` has LAN reach from inside the cluster. Never call `build-deploy.yml` from `pull_request`, forks, or any workflow triggered by untrusted input.

## Caller example

```yaml
name: ci
on:
  pull_request:
  push:
    branches: [main]
jobs:
  ci:
    uses: Gnzaga/ci-workflows/.github/workflows/pr-ci.yml@v1
    with: { images: '[...]' }
  deploy:
    if: github.event_name == 'push'
    needs: ci
    uses: Gnzaga/ci-workflows/.github/workflows/build-deploy.yml@v1
    with: { app: what2read, images: '[...]' }
```

Required status check: `ci / ci`. Image JSON: `[{"name", "context", "dockerfile", "build-args", "manifest-image"}]`. `name` is the GHCR package under `ghcr.io/gnzaga/`, `context` and `dockerfile` are relative to the repo root, `build-args` is newline-separated `K=V`, and `manifest-image` is the image name as written in the app manifests (optional). Build-only callers pass `deploy-target: none`, which skips the `deploy` job.

## Operator scripts

Run locally with `gh` authenticated as Gnzaga. `setup-production-env.sh` also needs `vault`. Both accept `--dry-run`, which makes no calls.

- `scripts/apply-ruleset.sh <repo> [branch=main] [--bypass-app-id <id>]`: idempotent `deploy-branch` ruleset.
- `scripts/setup-production-env.sh <repo> [branch=main]`: idempotent `production` environment, branch policy, and the three Vault-sourced secrets (`DEPLOYER_APP_ID`, `DEPLOYER_PRIVATE_KEY`, `ARGOCD_AUTH_TOKEN`).
