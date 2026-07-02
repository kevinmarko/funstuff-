#!/usr/bin/env bash
#
# Adds a GitHub Copilot MCP OAuth credential to the vault created by
# scripts/setup.sh. This is what lets the Code Reviewer agent actually call
# GitHub MCP tools (read PRs, post review comments) — the agent config
# declares the MCP server but carries no auth by design.
#
# TOKEN HANDLING: the token is read from the GITHUB_MCP_TOKEN env var only.
# It is never accepted as a CLI argument (would land in shell history) and
# is never echoed, logged, or written to a file by this script.
#
# KNOWN GAP: this creates the credential WITHOUT a `refresh` block, so the
# token will not auto-renew — GitHub Copilot MCP's OAuth app registration
# details (token endpoint, client auth style) aren't available to verify
# from this environment. Until that's resolved, treat this as a manual
# rotation: re-run this script with a fresh token when the old one expires.
#
# Requires: `ant` CLI installed and authenticated; scripts/setup.sh already
# run with --apply (needs VAULT_ID from .managed-agents.env).
#
# Usage:
#   GITHUB_MCP_TOKEN=ghp_xxx scripts/add_github_credential.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$REPO_ROOT/.managed-agents.env"
GITHUB_MCP_SERVER_URL="https://api.githubcopilot.com/mcp/"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "error: $ENV_FILE not found. Run 'scripts/setup.sh --apply' first." >&2
  exit 1
fi

# shellcheck source=/dev/null
source "$ENV_FILE"

if [[ -z "${VAULT_ID:-}" ]]; then
  echo "error: VAULT_ID not set in $ENV_FILE." >&2
  exit 1
fi

if [[ -z "${GITHUB_MCP_TOKEN:-}" ]]; then
  echo "error: set GITHUB_MCP_TOKEN before running this script, e.g.:" >&2
  echo "  GITHUB_MCP_TOKEN=ghp_xxx $0" >&2
  exit 1
fi

if ! command -v ant >/dev/null 2>&1; then
  echo "error: 'ant' CLI not found. Install it first — see shared/anthropic-cli.md." >&2
  exit 1
fi

echo "Adding GitHub Copilot MCP credential to vault $VAULT_ID ..."

# The token is passed via a variable expanded into the --auth JSON, never
# printed. `set +x` (already off) and no `echo "$GITHUB_MCP_TOKEN"` anywhere
# in this file keeps it out of script output.
ant beta:vaults:credentials create \
  --vault-id "$VAULT_ID" \
  --display-name "GitHub Copilot MCP" \
  --auth "{type: mcp_oauth, mcp_server_url: \"$GITHUB_MCP_SERVER_URL\", access_token: \"$GITHUB_MCP_TOKEN\"}" \
  --transform id -r > /tmp/.gh_cred_id

CRED_ID=$(cat /tmp/.gh_cred_id)
rm -f /tmp/.gh_cred_id

echo "Credential created: $CRED_ID"
echo
echo "NOTE: no refresh token configured — this credential will need to be"
echo "rotated manually (re-run this script) when it expires. See the"
echo "'KNOWN GAP' comment at the top of this file."
