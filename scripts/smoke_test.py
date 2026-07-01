#!/usr/bin/env python3
"""
Runtime smoke test for the Code Reviewer Managed Agent.

Confirms the agent can reach GitHub (via the vault's MCP credential) and
read a target repo, without running an actual review. Sends the exact
kickoff text documented in code-reviewer.README.md.

Requires:
  - .managed-agents.env (written by `scripts/setup.sh --apply`)
  - GitHub credential added to the vault (`scripts/add_github_credential.sh`)
  - `pip install anthropic`
  - ANTHROPIC_API_KEY set, or `ant auth login` already run

Usage:
  python scripts/smoke_test.py OWNER/REPO
"""

from __future__ import annotations

import sys
from pathlib import Path

try:
    import anthropic
except ImportError:
    print("error: the 'anthropic' package is required — run: pip install anthropic", file=sys.stderr)
    sys.exit(1)

REPO_ROOT = Path(__file__).resolve().parent.parent
ENV_FILE = REPO_ROOT / ".managed-agents.env"


def load_env_file(path: Path) -> dict[str, str]:
    if not path.exists():
        print(f"error: {path} not found. Run 'scripts/setup.sh --apply' first.", file=sys.stderr)
        sys.exit(1)
    values: dict[str, str] = {}
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        values[key.strip()] = value.strip()
    return values


def kickoff_text(owner_repo: str) -> str:
    # Mirrors the multi-line text block in code-reviewer.README.md exactly
    # (three lines, not one paragraph) so the two stay in sync.
    return (
        f"Confirm you can reach GitHub via the MCP tools and read the repository at {owner_repo}.\n"
        "List the 3 most recent open pull requests with their number and title.\n"
        "Do not start reviewing anything yet — I just want to confirm access."
    )


def main() -> int:
    if len(sys.argv) != 2:
        print("Usage: python scripts/smoke_test.py OWNER/REPO", file=sys.stderr)
        return 1
    owner_repo = sys.argv[1]

    env = load_env_file(ENV_FILE)
    for required in ("AGENT_ID", "AGENT_VERSION", "ENV_ID", "VAULT_ID"):
        if required not in env:
            print(f"error: {required} missing from {ENV_FILE}", file=sys.stderr)
            return 1

    client = anthropic.Anthropic()

    print(f"Creating session (agent={env['AGENT_ID']} v{env['AGENT_VERSION']}, env={env['ENV_ID']}) ...")
    session = client.beta.sessions.create(
        agent={"type": "agent", "id": env["AGENT_ID"], "version": int(env["AGENT_VERSION"])},
        environment_id=env["ENV_ID"],
        vault_ids=[env["VAULT_ID"]],
        title="smoke test",
    )
    print(f"Session: {session.id}")

    got_response = False
    saw_error = False
    final_stop_reason = None

    # Stream-first: open the stream, then send — sending first risks missing
    # events emitted before the SSE connection is live.
    with client.beta.sessions.events.stream(session_id=session.id) as stream:
        client.beta.sessions.events.send(
            session_id=session.id,
            events=[
                {
                    "type": "user.message",
                    "content": [{"type": "text", "text": kickoff_text(owner_repo)}],
                }
            ],
        )

        for event in stream:
            if event.type == "agent.message":
                for block in event.content:
                    if block.type == "text" and block.text:
                        got_response = True
                        print(block.text, end="", flush=True)
            elif event.type == "session.error":
                saw_error = True
                message = event.error.message if event.error else "unknown error"
                print(f"\n[session.error] {message}", file=sys.stderr)
            elif event.type == "session.status_idle":
                # A bare status_idle can be transient (e.g. between parallel
                # tool calls, or waiting on a tool_confirmation /
                # custom_tool_result). Only stop when the reason isn't
                # "requires_action" — see shared/managed-agents-client-patterns.md
                # Pattern 5.
                final_stop_reason = event.stop_reason
                if event.stop_reason is None or event.stop_reason.type != "requires_action":
                    break
            elif event.type == "session.status_terminated":
                break

    print()  # newline after streamed text

    if saw_error:
        print("FAIL: session reported an error.", file=sys.stderr)
        return 1

    if not got_response:
        print("FAIL: no agent.message text received before the session went idle.", file=sys.stderr)
        if final_stop_reason is not None:
            print(f"  stop_reason: {final_stop_reason.type}", file=sys.stderr)
        return 1

    print("PASS: agent responded and session reached a terminal state.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
