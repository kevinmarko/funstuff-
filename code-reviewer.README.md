# Code Reviewer — Managed Agent

Anthropic Managed Agent that reads a PR (diff + surrounding code), reports bugs
and risky patterns with severity + confidence, and — only when asked — posts
review comments via the GitHub MCP server.

Model: `claude-opus-4-8`. Toolset: `agent_toolset_20260401` + GitHub MCP.

> **Scripted setup:** `scripts/setup.sh`, `scripts/add_github_credential.sh`, and
> `scripts/smoke_test.py` automate the manual `ant`/SDK steps below. They
> require the `ant` CLI (setup/credential) and the `anthropic` Python package
> (smoke test) — neither is available in every environment, so the manual
> commands below remain the reference. Quick path:
>
> ```sh
> scripts/setup.sh --apply                                  # agent + environment + vault
> GITHUB_MCP_TOKEN=ghp_xxx scripts/add_github_credential.sh  # vault credential (manual rotation — see script header)
> python scripts/smoke_test.py OWNER/REPO                    # confirms MCP auth + repo access
> ```

---

## One-time setup

### 1. Create the agent

```sh
AGENT_ID=$(ant beta:agents create < code-reviewer.agent.yaml --transform id -r)
echo "$AGENT_ID"  # save this — sessions reference it
```

For subsequent edits, capture the current version and update in place (do not
re-create — that orphans the ID and loses history):

```sh
VERSION=$(ant beta:agents retrieve --agent-id "$AGENT_ID" --transform version -r)
ant beta:agents update --agent-id "$AGENT_ID" --version "$VERSION" < code-reviewer.agent.yaml
```

### 2. Create an environment

Unrestricted cloud egress is fine for this agent (it needs to reach GitHub's
MCP endpoint and, via `web_search`, public docs):

```sh
ENV_ID=$(ant beta:environments create \
  --name code-reviewer-env \
  --config '{type: cloud, networking: {type: unrestricted}}' \
  --transform id -r)
```

### 3. Create a vault with the GitHub MCP credential

The agent config declares the GitHub MCP server URL but carries no auth. Auth
lives in a vault attached at session-create time. See
`shared/managed-agents-tools.md` § Vaults for OAuth credential shape — the
Notion/Linear examples apply the same way to GitHub Copilot MCP.

```sh
VAULT_ID=$(ant beta:vaults create --display-name "Code Reviewer credentials" --transform id -r)
# Then: ant beta:vaults:credentials create --vault-id "$VAULT_ID" ... (mcp_oauth for github)
```

---

## Runtime — start a session per review

### Smoke test (first session — confirms MCP auth + repo access)

```sh
SID=$(ant beta:sessions create \
  --agent "$AGENT_ID" \
  --environment-id "$ENV_ID" \
  --vault-id "$VAULT_ID" \
  --title "smoke test" \
  --transform id -r)

# Stream-first: open the stream before sending the kickoff.
exec {stream}< <(ant beta:sessions:events stream --session-id "$SID")

ant beta:sessions:events send --session-id "$SID" > /dev/null <<'YAML'
events:
  - type: user.message
    content:
      - type: text
        text: |
          Confirm you can reach GitHub via the MCP tools and read the repository at OWNER/REPO.
          List the 3 most recent open pull requests with their number and title.
          Do not start reviewing anything yet — I just want to confirm access.
YAML
```

Replace `OWNER/REPO` with the target repo. A successful smoke test looks like
one `agent.message` with the 3 PRs, then `session.status_idle` with a terminal
`stop_reason` (not `requires_action`).

### Real review kickoff

```
Review PR #<NUM> in <OWNER>/<REPO>. Read the diff, check the surrounding code
and call sites where relevant, and report your findings. Do not post any
comments yet — return the findings as a message so I can review them first.
```

Only after you're happy with the findings, send a follow-up asking the agent
to post them.

---

## Decided defaults

1. **Repo scope: generic.** No target repo has been named yet, so the system
   prompt stays repo-agnostic (works against whatever `OWNER/REPO` is passed
   in the kickoff). If this agent ends up scoped to one repo, mount it via a
   `github_repository` session resource instead so the agent doesn't need to
   `git clone` at runtime.
2. **Posting: always ask.** The system prompt already says "Only post
   comments when the user has explicitly asked you to post." To loosen this
   for trusted repos, edit the system prompt and push the change with
   `sessions.update()` (or a new agent version).

## Still open

3. **Language-specific guidance?** Genuinely blocked on a real target
   repo — there's no language to write guidance for yet. Once one is named,
   add a short language block to the system prompt with the common failure
   modes to watch for (e.g. `err != nil` gaps and goroutine leaks for Go,
   missing `await`/unhandled promise rejections for JS/TS).
