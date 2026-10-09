# ci-workflows

Shared reusable GitHub Actions workflows and operator scripts for Gnzaga homelab app repos.

## Trust model
| Workflow | Job | Runner | Code trust | Secrets |
| --- | --- | --- | --- | --- |
| `pr-ci.yml` | `ci` | GitHub-hosted `ubuntu-latest` | untrusted (PR code) | none; `GITHUB_TOKEN` (`packages: read`) only when `ghcr-login: true` |
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

### `ghcr-login` (pr-ci)

`ghcr-login: true` logs in to `ghcr.io` with `GITHUB_TOKEN` (`packages: read`) before the image build checks, so a Dockerfile can `FROM` a private GHCR image. Default `false`. PR code runs in the same job, so the token is available to its build; only enable it for repos whose PRs are trusted to read the org's packages.

```yaml
jobs:
  ci:
    uses: Gnzaga/ci-workflows/.github/workflows/pr-ci.yml@v1
    with:
      ghcr-login: true
      images: '[...]'
```

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

### Harbor pull-cache warm-up

Harbor's proxy-cache project (`ghcr` for `harbor.gnzaga.com/ghcr/gnzaga/<name>`) fetches a layer from GHCR on its first request. A first pull of a large layer can end early in containerd (`short read ... unexpected EOF`) while Harbor is still caching, and the pod then sits in ImagePullBackOff past the progress deadline. To avoid this, the `deploy` job warms the cache before any homelab commit:

1. Runs right after the `Map built images to pull refs` step and skips in deploy-only mode (`images: '[]'`).
2. Installs `crane` v0.22.1 (SHA-256 checked) into `$RUNNER_TEMP/bin`.
3. Logs in to `harbor.gnzaga.com` with the `HARBOR_PULL_USERNAME` and `HARBOR_PULL_PASSWORD` production environment secrets. The login is scoped to a step-local docker config. If either secret is empty, it emits a `::warning::` and skips the warm-up without failing the job.
4. Runs `crane pull --format=oci` for each new pull ref. Each ref gets up to 6 attempts with backoff of 10, 20, 30, 45 and 60 seconds. The job fails if all attempts for a ref fail. Per-image seconds are printed, and the total is recorded in the job summary timings as `warm-cache`.

`setup-production-env.sh` sets both secrets from Vault `deployments/harbor/k8s-pull` (`username`, `password`).

### Manual promotion (`homelab-auto-merge: false`)

Default is `true`: the deploy job lands digests on homelab main (or through the fallback PR above) and then syncs ArgoCD or runs the Komodo deploy.

With `homelab-auto-merge: false` the deploy job never writes homelab main and never enables auto-merge:

1. Pushes the digest commit to `deploy/<app>-<sha7>-<run_id>` and opens a homelab PR into `main` for it. Requires the deployer App to have `Pull requests: write`.
2. Does not wait for the PR. Writes the PR URL to the job summary and to the step output `pr_url` of the commit step, and sets the `production` environment URL to that PR when the expression resolves (the environment URL falls back to the ArgoCD or Komodo URL otherwise).
3. Skips the ArgoCD sync and health steps, and the Komodo `UpdateStack` and `DeployStack` steps. The app deploys when the PR is merged. Merging the PR is the deploy gate.

If the source has no digest change, the job reports that and opens no PR.

Caller example (sig-7 staging, ArgoCD app `sig7-staging`, app file `sig7.yaml` in homelab.git):

```yaml
jobs:
  deploy:
    uses: Gnzaga/ci-workflows/.github/workflows/build-deploy.yml@main
    with:
      app: sig7-staging
      homelab-app-file: deployment-library/k8s/gitops/apps/sig7.yaml
      homelab-auto-merge: false
      images: '[{"name": "sig7-web", "context": ".", "dockerfile": "Dockerfile", "manifest-image": "harbor.gnzaga.com/apps/sig7-web"}, {"name": "sig7-worker", "context": ".", "dockerfile": "Dockerfile.worker", "manifest-image": "harbor.gnzaga.com/apps/sig7-worker"}]'
    secrets: inherit
```

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
| manual promotion (`homelab-auto-merge: false`) | non-empty | empty or set | `argocd` or `komodo` | as above | runs | PR only, not merged | none |

## Operator scripts

Run locally with `gh` authenticated as Gnzaga. `setup-production-env.sh` also needs `vault`. Both accept `--dry-run`, which makes no calls.

- `scripts/apply-ruleset.sh <repo> [branch=main] [--bypass-app-id <id>]`: idempotent `deploy-branch` ruleset.
- `scripts/setup-production-env.sh <repo> [branch=main] [--komodo]`: idempotent `production` environment, branch policy, and the five Vault-sourced secrets (`DEPLOYER_APP_ID`, `DEPLOYER_PRIVATE_KEY`, `ARGOCD_AUTH_TOKEN`, `HARBOR_PULL_USERNAME`, `HARBOR_PULL_PASSWORD` from Vault `deployments/harbor/k8s-pull`). `--komodo` also sets `KOMODO_KEY` and `KOMODO_SECRET` from Vault `deployments/komodo/ci-deployer` (`key`, `secret`).
