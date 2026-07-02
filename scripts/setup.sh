#!/usr/bin/env bash
#
# Control-plane bootstrap for the Code Reviewer Managed Agent:
# creates the agent, an environment, and an (empty) vault.
#
# These are billed, stateful `ant beta:{agents,environments,vaults} create`
# calls. By default this script only PRINTS the commands it would run —
# pass --apply to actually execute them.
#
# Requires: `ant` CLI installed and authenticated (`ant auth status`).
# Usage:
#   scripts/setup.sh              # dry run — prints commands only
#   scripts/setup.sh --apply      # creates the agent, environment, and vault
#   scripts/setup.sh --apply --force   # re-create even if .managed-agents.env exists
#
# On success, writes AGENT_ID / AGENT_VERSION / ENV_ID / VAULT_ID to
# .managed-agents.env for scripts/add_github_credential.sh and
# scripts/smoke_test.py to consume.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
AGENT_YAML="$REPO_ROOT/code-reviewer.agent.yaml"
ENV_FILE="$REPO_ROOT/.managed-agents.env"

APPLY=false
FORCE=false
for arg in "$@"; do
  case "$arg" in
    --apply) APPLY=true ;;
    --force) FORCE=true ;;
    *)
      echo "Unknown argument: $arg" >&2
      echo "Usage: $0 [--apply] [--force]" >&2
      exit 1
      ;;
  esac
done

if [[ -f "$ENV_FILE" && "$FORCE" != true ]]; then
  echo "Found existing $ENV_FILE — resources already provisioned:"
  echo
  cat "$ENV_FILE"
  echo
  echo "Re-run with --force to re-create (this does NOT delete the old resources)."
  exit 0
fi

if [[ "$FORCE" == true && -f "$ENV_FILE" ]]; then
  read -r -p "This will create NEW agent/environment/vault resources; the old ones in $ENV_FILE are not deleted. Continue? [y/N] " confirm
  if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
    echo "Aborted."
    exit 1
  fi
fi

if [[ "$APPLY" != true ]]; then
  cat <<EOF
Dry run — the following commands would be executed (pass --apply to run them):

  ant beta:agents create < "$AGENT_YAML" --transform id -r
  ant beta:environments create \\
    --name code-reviewer-env \\
    --config '{type: cloud, networking: {type: unrestricted}}' \\
    --transform id -r
  ant beta:vaults create \\
    --display-name "Code Reviewer credentials" \\
    --transform id -r

Results (AGENT_ID / AGENT_VERSION / ENV_ID / VAULT_ID) would be written to:
  $ENV_FILE

No GitHub token is created here — see scripts/add_github_credential.sh.
EOF
  exit 0
fi

if ! command -v ant >/dev/null 2>&1; then
  echo "error: 'ant' CLI not found. Install it first — see shared/anthropic-cli.md." >&2
  exit 1
fi

echo "Creating agent from $AGENT_YAML ..."
AGENT_ID=$(ant beta:agents create < "$AGENT_YAML" --transform id -r)
AGENT_VERSION=$(ant beta:agents retrieve --agent-id "$AGENT_ID" --transform version -r)
echo "  AGENT_ID=$AGENT_ID (version $AGENT_VERSION)"

echo "Creating environment ..."
ENV_ID=$(ant beta:environments create \
  --name code-reviewer-env \
  --config '{type: cloud, networking: {type: unrestricted}}' \
  --transform id -r)
echo "  ENV_ID=$ENV_ID"

echo "Creating vault (empty — add the GitHub credential separately) ..."
VAULT_ID=$(ant beta:vaults create \
  --display-name "Code Reviewer credentials" \
  --transform id -r)
echo "  VAULT_ID=$VAULT_ID"

cat > "$ENV_FILE" <<EOF
AGENT_ID=$AGENT_ID
AGENT_VERSION=$AGENT_VERSION
ENV_ID=$ENV_ID
VAULT_ID=$VAULT_ID
EOF

echo
echo "Wrote $ENV_FILE"
echo "Next: GITHUB_MCP_TOKEN=<token> scripts/add_github_credential.sh"
