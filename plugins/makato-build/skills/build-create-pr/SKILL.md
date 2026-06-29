---
name: build-create-pr
description: >-
  Generate a pull request from the pushed feature branch. Drafts
  the PR description from spec artifacts — acceptance criteria map
  to How to Test, design decisions surface in the description, Jira
  story is linked. Presents draft for user approval before opening.
  Interactive. Use after push-to-git, before address-pr-comments.
version: "1.5.1"
argument-hint: "[work-item-key] [--autonomous]"
---

## When to Use

Use after `/push-to-git` (branch is on remote) and before `/address-pr-comments`. The code is committed and pushed. This step generates a PR description from spec artifacts and opens the pull request for human review.

## Input

When dispatched by the PO-agent (`--autonomous` mode):

- `<work-item-key>` — positional argument (optional; see Step 1a fallback).
- `WORKTREE_PATH` — absolute filesystem path to the per-run git worktree. **Mandatory in autonomous mode** (see `plugins/makato-build/AUTONOMOUS-MODE.md` § *WORKTREE_PATH — workspace-isolation contract*). `gh pr create` and any `git` invocation MUST run from `WORKTREE_PATH` so the PR resolves the correct branch — running from the main checkout would open a PR against the wrong (or no) branch.
- `--autonomous` — activation flag.

Interactive mode: `WORKTREE_PATH` is optional; fall back to `git rev-parse --show-toplevel` of the current `$PWD`.

### Workspace-isolation entry guard

At skill entry (before Step 1's `git status -sb`), apply the falsy-check pattern from `AUTONOMOUS-MODE.md`: in autonomous mode an empty `WORKTREE_PATH` is a HALT (R1 `status: "failure"`, `errors: ["MISSING_INPUT: WORKTREE_PATH required in autonomous mode"]`). In interactive mode, resolve `WORKTREE_PATH="$(git rev-parse --show-toplevel)"` and `cd "$WORKTREE_PATH"`. Every `git`/`gh pr create` command below runs from this CWD.

**Spec-artefact reads use `REPO_ROOT`, not `WORKTREE_PATH`.** `specs/<key>-*/` is gitignored at the repo root; a fresh `git worktree add` produces a worktree with NO `specs/` content. Resolve `REPO_ROOT` once at entry alongside the worktree:

```bash
REPO_ROOT="$(cd "$(git -C "$WORKTREE_PATH" rev-parse --git-common-dir)/.." && pwd)"
```

Every spec-artefact path resolved in Step 1 below (`stories.json`, `prd.md`, `plan.md`, `created-issues.json`) is `$REPO_ROOT/specs/<key>-*/<file>`. `.github/PULL_REQUEST_TEMPLATE.md` lives in the tracked `.github/` directory and resolves correctly under either root, but for consistency the prose below references `$REPO_ROOT/.github/PULL_REQUEST_TEMPLATE.md`. See `AUTONOMOUS-MODE.md` § *Two roots, one contract*.

## Workflow

### Step 1 — Ask for work item key and load context

Ask: *"Which work item are we creating a PR for? (e.g. DCP-1234, or pass it directly: `/makato-build:build-create-pr DCP-1234`)"* — or use the passed argument. A work item key is optional; if none is provided, the PR can still be created without an issue link.

Verify the branch is pushed: run `git status -sb` and check that the upstream tracking branch exists and no local commits are ahead of it. If commits are ahead of remote, stop and tell the user:

> "Branch has unpushed commits. Run `/push-to-git` first."

### Step 1a — Mode detection

Load `@../../AUTONOMOUS-MODE.md` for the activation contract and the per-gate default table.

The skill runs in `--interactive` mode by default. Switch to `--autonomous` when ANY of:

- `--autonomous` is passed on the CLI, OR
- The caller provides a context bundle with a `task_id` field, OR
- `$AGENT_ID` is exported in the environment.

In autonomous mode, the Step 1 work-item-key prompt is replaced by:
1. If an argument was passed: use it.
2. Otherwise, read the most-recent `build.jsonl` session entry in the resolved spec folder (`specs/*/build.jsonl`, last entry where `step:"session"` and `status:"start"`) and extract `data.issue` or `data.story` as the key, and `data.branch` as the branch.
3. If neither step yields a key: HALT with `MISSING_INPUT: build-create-pr in --autonomous mode requires a work-item-key argument or a populated build.jsonl session entry`, write `{step:"session", status:"error", data:{halt_code:"MISSING_INPUT"}}`, and return R1 `status:"failure"`.

Log the bypass via `shared/build-log.sh "<key>" '{"ts":"…","skill":"build-create-pr","story":"<key>","step":"decision","status":"decision","data":{"event":"autonomous_bypass","gate":"work-item-key","bypassed":true,"default_taken":"<use-arg|read-build-jsonl>","trigger":"<agent_id|cli_flag|task_id_bundle>"}}'` when bypassed.

Read from the resolved spec folder under `$REPO_ROOT` (NOT under `$WORKTREE_PATH` — see the entry guard above): `$REPO_ROOT/specs/<key>-*/`:
- `stories.json` — acceptance criteria for this work item (if key was provided and file exists)
- `prd.md` — goals, scope, motivation (if exists)
- `plan.md` — completed tasks, for "What changed" bullets (if exists)
- `$REPO_ROOT/.github/PULL_REQUEST_TEMPLATE.md` — the project's required PR template

- `created-issues.json` — handoff artifact emitted by `/makato-plan:to-issues` (optional)

When `created-issues.json` exists in the spec folder, validate it against the schema at `$REPO_ROOT/plugins/makato-plan/skills/to-issues/references/created-issues.schema.json`:

```bash
python3 - <<PY
import json, sys
try:
    import jsonschema
except ImportError:
    import subprocess; subprocess.check_call([sys.executable, '-m', 'pip', 'install', '--quiet', 'jsonschema'])
    import jsonschema
SCHEMA = json.load(open('plugins/makato-plan/skills/to-issues/references/created-issues.schema.json'))
ART = json.load(open('$SPEC_FOLDER/created-issues.json'))
jsonschema.validate(ART, SCHEMA)
print('[build-create-pr] artifact valid: %d issues' % len(ART['issues']))
PY
```

If validation fails (invalid JSON or schema mismatch), log a single warning:
`[build-create-pr] WARNING: specs/<slug>/created-issues.json is malformed (<error>) — continuing without Closes injection`
…and proceed with the current v1.2.0 behavior. Never block PR creation on artifact problems (D21).

Resolve the integration target with `DEFAULT_REF="$(shared/default-branch.sh)"` (returns e.g. `origin/main`); run `git fetch origin --quiet` first so the comparison reflects the latest integration tip. Then run `git log "$DEFAULT_REF..HEAD" --oneline` to see the commits included in this PR. Never compare against the bare local `main` — a stale local `main` reports commits from already-merged PRs (#98).

---

### Step 2 — Log session start

Run:

```bash
shared/build-log.sh "<key>" '{"ts":"<ISO8601>","skill":"build-create-pr","story":"<key>","step":"session","status":"start","data":{"branch":"<name>","commits":<N>}}'
```

---

### Step 3 — Draft the PR description

Load `@references/pr-description-guide.md`. Use `.github/PULL_REQUEST_TEMPLATE.md` (already read in Step 1) as the body structure — populate each of its sections from spec artifacts. This ensures the produced PR matches the template enforced by the project rather than a free-form body.

**PR title**: `feat: <story title>` — title from `stories.json` or `plan.md`; if no spec, derive from commit messages. Append ` (DCP-1234)` or ` (#42)` when a work item key is available. The full title must fit on one line in GitHub's PR list view: keep it under 72 characters total. Truncate or rephrase the story title if needed; never truncate the issue reference.

Fill each template section as follows:

**Description of Changes > What changed**: one bullet per plan task — task title + one sentence on what was changed. If no `plan.md` exists, derive from commit messages.

**Goal Alignment**: plugin name, goal statement (read `AGENTS.md` in the target repo), one sentence connecting this story to the goal.

**Links**: see Step 6 for issue tracker handling. When `created-issues.json` is present and valid, the Links section receives an auto-injected `Closes #N` line per artifact entry (in artifact order), deduped against any user-supplied `GH#N` reference — see Step 6 Case 4.

**How to Test**: one numbered step per acceptance criterion from `stories.json` — make each concrete (name the command, the input, the expected output). If no `stories.json` exists, write steps derived from the commit messages and changed code.

**Breaking Changes**: check the diff for changes to public APIs, database schemas, or shared contracts. Check `Yes` if any are found and describe the migration path.

**AI-assisted**: pre-check "Code implementation", "Commit messages", "PR description".

**PR Checklist**: pre-check all items that are verifiably true (conventional commit title ✓, CHANGELOG updated ✓, self-contained skills ✓, version bumped if behavior changed).

**Additional Changelog Entries**: leave empty — this is a single-story PR.

---

### Step 4 — Present draft for user review

In **interactive mode**, present the complete draft PR (title + full description body) to the user.

Ask: *"Does this PR description look correct? Reply with any edits, or 'approved' to open the PR."*

Apply any edits the user requests. Re-present if edits are substantial. Do not open the PR until the user gives explicit approval.

In **autonomous mode**, skip the prompt: proceed directly to Step 5 with the draft as-rendered. Log `shared/build-log.sh "<key>" '{"ts":"…","skill":"build-create-pr","story":"<key>","step":"decision","status":"decision","data":{"event":"autonomous_bypass","gate":"pr-draft-approval","bypassed":true,"default_taken":"open-pr-as-drafted","trigger":"<agent_id|cli_flag|task_id_bundle>"}}'`. The PR body is populated entirely from spec artifacts (`stories.json`, `prd.md`, `plan.md`) and workflow-state (`build.jsonl`) — no human authoring is required and the `created-issues.json` auto-`Closes` injection in Step 6 Case 4 is the canonical issue-link source.

---

### Step 5 — Create the pull request

**GH_HOST detection**: before calling `gh pr create`, resolve the remote URL:
```
git remote get-url origin
```
Extract the hostname from the URL (e.g. `github.tools.sap` from `https://github.tools.sap/org/repo.git`). If the hostname differs from `github.com`, prefix all subsequent `gh` commands with `GH_HOST=<hostname>`. Emit an informational note: "Using `GH_HOST=<hostname>` — remote is not github.com."

Run:
```
gh pr create --title "<title>" --body "$(cat <<'EOF'
<body>
EOF
)"
```

Base branch: `main`. If the project uses a different default base (e.g. `develop`), check `gh repo view --json defaultBranchRef` or ask the user before creating.

On failure: report the exact `gh` error verbatim. Common causes: not authenticated (`gh auth login`), no remote set, title too long. Do not retry silently.

On success: capture the PR URL from the output.

---

### Step 6 — Link PR to issue tracker (optional)

This step depends on what tracking context is available. Do not block or ask the user if no reference was provided.

**Case 1 — Jira key provided (e.g. DCP-1234):**
Use the Jira MCP `create_remote_link` tool after the PR is created:
- `key`: the work item key
- `url`: the PR URL from Step 5
- `title`: `Pull Request: <PR title>`

If the Jira MCP is not configured, skip and note it in the log.

**Case 2 — GitHub issue reference provided (e.g. GH#42):**
Add `Closes #42` (or `Fixes #42`) to the PR body's Links section *before* calling `gh pr create` in Step 5. GitHub auto-closes the issue on merge. No separate API call needed.

**Case 3 — No issue reference provided:**
Skip linking entirely. Do not ask the user to supply one. Log `"issue_linked": false` and proceed.

**Case 4 — `created-issues.json` present and schema-valid:**

For each entry in `issues[]`, add `Closes #<issue_number>` to the PR body's Links section in artifact order, before calling `gh pr create` in Step 5.

**Dedupe rule (D20):** if Case 2 already added a `Closes #N` for the same issue number (because the user passed `GH#N`), do not duplicate — the artifact entry wins by being canonical; the user-supplied reference is dropped from the Links section to avoid two lines pointing at the same issue.

**No artifact, malformed artifact, or schema-invalid artifact (D21):** skip injection entirely. Log a warning (as in Step 1) and create the PR with the current Step 6 Case 1–3 behavior. Never block PR creation on artifact problems.

---

### Step 7 — Log session end and hand off

Run:

```bash
shared/build-log.sh "<key>" '{"ts":"<ISO8601>","skill":"build-create-pr","story":"<key>","step":"session","status":"ok","data":{"pr_url":"<url>","issue_linked":true|false,"issue_type":"jira"|"github"|"none","closes_injected":<N>,"artifact_status":"valid"|"missing"|"malformed"}}'
```

Tell the user: *"PR open: `<URL>`. Next: wait for review, then use `/address-pr-comments` to handle feedback."*

## Autonomous Execution

Autonomous mode activates when ANY of:

- `--autonomous` is passed on the CLI.
- The caller provides a context bundle with a `task_id` field.
- `$AGENT_ID` is exported in the environment.

In autonomous mode:

- **Never prompt the user** — work-item-key and draft-approval gates are bypassed per the rules above.
- **Read workflow-state from `build.jsonl`** when the work-item-key argument is missing — Step 1a documents the lookup order.
- **PR body is fully autogenerated** from spec artifacts (`stories.json`, `prd.md`, `plan.md`, `.github/PULL_REQUEST_TEMPLATE.md`) and workflow-state. No human authoring.
- **Auto-inject `Closes #<n>`** lines from `created-issues.json` per Step 6 Case 4 — this is the canonical issue-link source in autonomous mode.
- **Log every bypass** to `build.jsonl` via `shared/build-log.sh` with the `autonomous_bypass` event schema documented in `@../../AUTONOMOUS-MODE.md`.
- **Emit an R1 envelope** as the final `json`-fenced block of the skill's output.

### Return Format (R1, when called as a sub-skill)

```json
{
  "schema": "r1",
  "agent": "build-create-pr",
  "status": "success" | "partial" | "failure",
  "summary": "Opened PR <url>",
  "files_changed": [],
  "tests_written": [],
  "errors": [],
  "tool_calls_used": 0,
  "data": {
    "pr_url": "<url>",
    "pr_number": <N>,
    "issue_linked": <true|false>,
    "issue_type": "jira" | "github" | "none",
    "closes_injected": <N>,
    "artifact_status": "valid" | "missing" | "malformed",
    "gh_host": "<hostname>"
  }
}
```

### HALT Codes

| Code | Meaning |
|------|---------|
| `MISSING_INPUT` | `--autonomous` invoked without a work-item-key argument AND no recoverable `build.jsonl` session entry |
| `UNPUSHED_COMMITS` | Step 1 found local commits ahead of the upstream |
| `GH_AUTH_FAILED` | `gh pr create` returned auth error — caller must run `gh auth login` |
| `PR_CREATE_FAILED` | Step 5 — `gh pr create` returned non-zero for a reason other than auth |
