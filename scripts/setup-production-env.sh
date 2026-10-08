#!/usr/bin/env bash
# Idempotently configure the `production` environment on Gnzaga/<repo>:
#   - environment with custom deployment branch policy
#   - branch policy allowing <branch> to deploy to it
#   - environment secrets sourced from Vault (values are never printed)
#
# Usage: setup-production-env.sh <repo> [branch=main] [--dry-run]
#
# A Vault path or field that is missing is skipped with a warning.
# --dry-run prints the planned actions without calling GitHub or Vault.
set -euo pipefail

usage() {
  sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-1}"
}

repo=""
branch="main"
dry_run=0

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage 0 ;;
    --dry-run) dry_run=1; shift ;;
    -*) echo "error: unknown flag $1" >&2; usage ;;
    *)
      if [ -z "$repo" ]; then repo="$1"
      else branch="$1"
      fi
      shift ;;
  esac
done

[ -n "$repo" ] || usage

env_api="repos/Gnzaga/${repo}/environments/production"
policy_api="${env_api}/deployment-branch-policies"

# Secret name, Vault KV path (under deployments/), and field to read.
secret_map=(
  "DEPLOYER_APP_ID github-apps/deployer app_id"
  "DEPLOYER_PRIVATE_KEY github-apps/deployer private_key"
  "ARGOCD_AUTH_TOKEN argocd/ci-deployer token"
)

if [ "$dry_run" = 1 ]; then
  echo "dry-run: no GitHub or Vault calls will be made"
  echo "plan 1: PUT ${env_api} with deployment_branch_policy {protected_branches: false, custom_branch_policies: true}"
  echo "plan 2: GET ${policy_api}; POST it with {name: \"${branch}\", type: \"branch\"} if absent"
  for entry in "${secret_map[@]}"; do
    read -r name path field <<<"$entry"
    echo "plan 3: gh secret set ${name} --env production -R Gnzaga/${repo}  <- vault kv get -field=${field} deployments/${path}"
  done
  exit 0
fi

echo "configuring environment production on Gnzaga/${repo} (branch ${branch})"
gh api -X PUT "$env_api" --input - >/dev/null <<<'{"deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}}'
echo "ok: environment production exists with custom branch policies"

has_policy=$(gh api "$policy_api" --jq ".branch_policies[]? | select(.name == \"${branch}\") | .name" | head -n1)
if [ -n "$has_policy" ]; then
  echo "ok: branch policy ${branch} already present"
else
  gh api -X POST "$policy_api" --input - --jq '"ok: created branch policy \(.name)"' <<<"$(jq -nc --arg b "$branch" '{name: $b, type: "branch"}')"
fi

for entry in "${secret_map[@]}"; do
  read -r name path field <<<"$entry"
  if value=$(vault kv get -field="$field" "deployments/${path}" 2>/dev/null); then
    printf '%s' "$value" | gh secret set "$name" --env production -R "Gnzaga/${repo}"
    echo "ok: set ${name} from deployments/${path}#${field}"
  else
    echo "warning: skipped ${name}: deployments/${path}#${field} not readable in Vault" >&2
  fi
  value=""
done
