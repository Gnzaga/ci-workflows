#!/usr/bin/env bash
# Idempotently apply the `deploy-branch` ruleset to Gnzaga/<repo>.
#
# Usage: apply-ruleset.sh <repo> [branch=main] [--bypass-app-id <id>] [--dry-run]
#
# Creates the ruleset if missing, otherwise updates it in place (PUT).
# --dry-run prints the planned API call and payload without calling GitHub.
set -euo pipefail

usage() {
  sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-1}"
}

repo=""
branch="main"
bypass_app_id=""
dry_run=0

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage 0 ;;
    --dry-run) dry_run=1; shift ;;
    --bypass-app-id)
      [ $# -ge 2 ] || { echo "error: --bypass-app-id needs a value" >&2; exit 1; }
      bypass_app_id="$2"; shift 2 ;;
    -*) echo "error: unknown flag $1" >&2; usage ;;
    *)
      if [ -z "$repo" ]; then repo="$1"
      else branch="$1"
      fi
      shift ;;
  esac
done

[ -n "$repo" ] || usage
if [ -n "$bypass_app_id" ] && ! [[ "$bypass_app_id" =~ ^[0-9]+$ ]]; then
  echo "error: --bypass-app-id must be numeric" >&2
  exit 1
fi

if [ -n "$bypass_app_id" ]; then
  bypass_json=$(jq -n --argjson id "$bypass_app_id" \
    '[{actor_type: "Integration", actor_id: $id, bypass_mode: "always"}]')
else
  bypass_json='[]'
fi

payload=$(jq -n \
  --arg branch "$branch" \
  --argjson bypass "$bypass_json" \
  '{
    name: "deploy-branch",
    target: "branch",
    enforcement: "active",
    conditions: {ref_name: {include: ["refs/heads/\($branch)"], exclude: []}},
    bypass_actors: $bypass,
    rules: [
      {type: "deletion"},
      {type: "non_fast_forward"},
      {type: "pull_request", parameters: {
        required_approving_review_count: 0,
        dismiss_stale_reviews_on_push: false,
        require_code_owner_review: false,
        require_last_push_approval: false,
        required_review_thread_resolution: false
      }},
      {type: "required_status_checks", parameters: {
        strict_required_status_checks_policy: false,
        required_status_checks: [{context: "ci / ci"}]
      }}
    ]
  }')

api_base="repos/Gnzaga/${repo}/rulesets"

if [ "$dry_run" = 1 ]; then
  echo "dry-run: no GitHub API calls will be made"
  echo "plan: GET ${api_base}; if a ruleset named deploy-branch exists PUT ${api_base}/<id>, else POST ${api_base}"
  echo "payload:"
  echo "$payload" | jq .
  exit 0
fi

existing_id=$(gh api "$api_base" --jq '.[] | select(.name == "deploy-branch") | .id' | head -n1)

if [ -n "$existing_id" ]; then
  echo "updating ruleset deploy-branch (id ${existing_id}) on Gnzaga/${repo} for refs/heads/${branch}"
  gh api -X PUT "${api_base}/${existing_id}" --input - <<<"$payload" --jq '"ok: \(.name) id=\(.id) enforcement=\(.enforcement)"'
else
  echo "creating ruleset deploy-branch on Gnzaga/${repo} for refs/heads/${branch}"
  gh api -X POST "$api_base" --input - <<<"$payload" --jq '"ok: \(.name) id=\(.id) enforcement=\(.enforcement)"'
fi
