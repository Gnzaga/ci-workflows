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
- `komodo`: the `deploy` job rewrites the `image:` of every service in `compose-file` (in homelab.git) whose image matches the built image (`manifest-image`, or the pull-ref name when unset) to the new pull ref, commits and pushes, then sends the committed file to Komodo with `UpdateStack` (`file_contents`), runs `DeployStack` for `komodo-stack` and polls the resulting Update until it completes. Fails if a built image matches no service. Requires the `KOMODO_KEY` and `KOMODO_SECRET` production environment secrets.
- `none`: build and push only.

### Homelab push fallback

Both `argocd` and `komodo` commit to `main` of homelab.git. If the direct push is rejected by branch protection (stderr matches `protected branch`, `GH006` or `Required status check`), the deploy job falls back to a pull request:

1. Pushes the commit to `deploy/<app>-<sha7>-<run_id>`, where `sha7` is the caller's commit.
2. Opens a PR into `main` with the commit message as title and the run URL as body, then runs `gh pr merge --auto --merge --delete-branch`.
3. Polls every 10 seconds for up to 10 minutes. It runs `gh pr update-branch` while the PR is `BEHIND`, and stops when the PR is `MERGED`. It fails on `CLOSED` or timeout.
4. Uses the merge commit as the job's `sha` output. For `komodo`, the file pushed to Komodo is the merged content.

The fallback needs the deployer App to have `Pull requests: write`. `gh` is not in the `ghcr.io/actions/actions-runner` image, so the deploy job installs a pinned `gh` release (SHA-256 checked) on first use. Auto-merge must be enabled on homelab.git.

A bypass for the `gnzaga-deployer` App on homelab.git's `main` protection makes the fallback unnecessary: the direct push succeeds and no PR is created.

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

### Deploy-only mode

`images: '[]'` with `deploy-target: argocd` skips the build and the homelab commit. The deploy job only runs `argocd app sync <app>` and `app wait --sync --health`, so the Application gets a GitHub Deployment and a health result without pushing images. Use it for manifest-only repos. `[]` is rejected with any other deploy target, and when `prebuilt-digests` is set.

```yaml
jobs:
  deploy:
    needs: ci
    uses: Gnzaga/ci-workflows/.github/workflows/build-deploy.yml@v1
    with:
      app: <argocd-application>
      images: '[]'
    secrets: inherit
```

### Prebuilt digests and multi-target deploys

The `digests` workflow output lists the `ghcr.io/gnzaga/<name>@sha256:…` refs built by a call. Pass it as `prebuilt-digests` to a second call to deploy the same images to another target without rebuilding. `prebuilt-digests` requires `images` (for name and `manifest-image` mapping) and skips the build steps.

```yaml
jobs:
  k8s:
    uses: Gnzaga/ci-workflows/.github/workflows/build-deploy.yml@v1
    with: { app: bellegunz, images: '[...]' }
  fredo:
    needs: k8s
    uses: Gnzaga/ci-workflows/.github/workflows/build-deploy.yml@v1
    with:
      app: bellegunz-fredo
      deploy-target: komodo
      komodo-stack: bellegunz
      compose-file: stacks/fredo/bellegunz/compose.yml
      images: '[...]'
      prebuilt-digests: ${{ needs.k8s.outputs.digests }}
    secrets: inherit
```

Both deploy jobs use the `production` environment, so they can run in the same workflow run.

### Mode truth table

| Mode | `images` | `prebuilt-digests` | `deploy-target` | Build steps | Deploy job | Homelab commit | ArgoCD / Komodo |
| --- | --- | --- | --- | --- | --- | --- | --- |
| normal argocd | non-empty | empty | `argocd` | run | runs | yes | `homelab-apps` sync, digest poll, `app sync`, `app wait` |
| normal komodo | non-empty | empty | `komodo` | run | runs | compose file | `DeployStack`, poll Update |
| prebuilt | non-empty | set | `argocd` or `komodo` | skipped | runs with passthrough digests | as above | as above |
| deploy-only | `[]` | empty | `argocd` | skipped | runs | none | `app sync`, `app wait` |

## Operator scripts

Run locally with `gh` authenticated as Gnzaga. `setup-production-env.sh` also needs `vault`. Both accept `--dry-run`, which makes no calls.

- `scripts/apply-ruleset.sh <repo> [branch=main] [--bypass-app-id <id>]`: idempotent `deploy-branch` ruleset.
- `scripts/setup-production-env.sh <repo> [branch=main] [--komodo]`: idempotent `production` environment, branch policy, and the three Vault-sourced secrets (`DEPLOYER_APP_ID`, `DEPLOYER_PRIVATE_KEY`, `ARGOCD_AUTH_TOKEN`). `--komodo` also sets `KOMODO_KEY` and `KOMODO_SECRET` from Vault `deployments/komodo/ci-deployer` (`key`, `secret`).
