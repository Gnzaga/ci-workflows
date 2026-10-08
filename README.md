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

`argocd-server` defaults to `argocd-server.argocd.svc:80`. The in-cluster server runs with `server.insecure=true`, so the CLI uses `--plaintext`.

### `deploy-target`

- `argocd` (default): the `deploy` job writes Harbor pull refs into the `app` Application file in homelab.git and syncs ArgoCD.
- `komodo`: the `deploy` job rewrites the `image:` of every service in `compose-file` (in homelab.git) whose image matches the built image (`manifest-image`, or the pull-ref name when unset) to the new pull ref, commits and pushes, then runs Komodo `DeployStack` for `komodo-stack` and polls the resulting Update until it completes. Fails if a built image matches no service. Requires the `KOMODO_KEY` and `KOMODO_SECRET` production environment secrets.
- `none`: build and push only.

Komodo caller example (values are illustrative):

```yaml
jobs:
  deploy:
    needs: ci
    uses: Gnzaga/ci-workflows/.github/workflows/build-deploy.yml@v1
    with:
      app: toth-collection
      deploy-target: komodo
      komodo-stack: toth-collection
      compose-file: stacks/fredo/toth-collection/compose.yml
      images: '[{"name": "toth-collection-web", "context": ".", "dockerfile": "Dockerfile", "manifest-image": "harbor.gnzaga.com/ghcr/gnzaga/toth-collection-web"}]'
    secrets: inherit
```

`komodo-url` defaults to `http://192.168.42.27:9120`.

## Operator scripts

Run locally with `gh` authenticated as Gnzaga. `setup-production-env.sh` also needs `vault`. Both accept `--dry-run`, which makes no calls.

- `scripts/apply-ruleset.sh <repo> [branch=main] [--bypass-app-id <id>]`: idempotent `deploy-branch` ruleset.
- `scripts/setup-production-env.sh <repo> [branch=main] [--komodo]`: idempotent `production` environment, branch policy, and the three Vault-sourced secrets (`DEPLOYER_APP_ID`, `DEPLOYER_PRIVATE_KEY`, `ARGOCD_AUTH_TOKEN`). `--komodo` also sets `KOMODO_KEY` and `KOMODO_SECRET` from Vault `deployments/komodo/ci-deployer` (`key`, `secret`).
