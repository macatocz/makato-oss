---
name: build-create-pr
description: >-
  Generate a pull request from the pushed feature branch. Drafts
  the PR description from spec artifacts — acceptance criteria map
  to How to Test, design decisions surface in the description, Jira
  story is linked. Presents draft for user approval before opening.
  Interactive. Use after push-to-git, before address-pr-comments.
version: "1.9.0"
argument-hint: "[work-item-key] [--autonomous]"
allowed-tools:
  - Bash
  - Read
---

## References

| Reference | MANDATORY trigger | Do NOT Load |
|-----------|-------------------|-------------|
| `@references/pr-description-guide.md` | Load at Step 3 before drafting the PR description body | Do NOT load before Step 3 — the guide is section-filling detail, not entry context |
| `@../../AUTONOMOUS-MODE.md` | Load at Step 1a when `--autonomous` flag is present, to read activation contract and bypass-log schema | Do NOT load in interactive-only sessions — the reference is autonomous-contract detail that adds noise when running interactively |

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

Apply the workspace-isolation entry guard from `@../../AUTONOMOUS-MODE.md` § *WORKTREE_PATH — workspace-isolation contract* and § *Falsy-check pattern* before Step 1's `git status -sb`. In autonomous mode an empty `WORKTREE_PATH` is a HALT with `errors: ["MISSING_INPUT: WORKTREE_PATH required in autonomous mode"]`; in interactive mode the guard falls back to `git rev-parse --show-toplevel`. After resolution, `cd "$WORKTREE_PATH"` — every `git`/`gh pr create` command below runs from this CWD.

**Spec-artefact reads use `REPO_ROOT`, not `WORKTREE_PATH`.** `specs/<key>-*/` is gitignored at the repo root; a fresh `git worktree add` produces a worktree with NO `specs/` content. Resolve `REPO_ROOT` once at entry alongside the worktree:

```bash
REPO_ROOT="$(cd "$(git -C "$WORKTREE_PATH" rev-parse --git-common-dir)/.." && pwd)"
```

Every spec-artefact path resolved in Step 1 below (`stories.json`, `prd.md`, `plan.md`, `created-issues.json`) is `$REPO_ROOT/specs/<key>-*/<file>`. `.github/PULL_REQUEST_TEMPLATE.md` lives in the tracked `.github/` directory and resolves correctly under either root, but for consistency the prose below references `$REPO_ROOT/.github/PULL_REQUEST_TEMPLATE.md`. See `AUTONOMOUS-MODE.md` § *Two roots, one contract*.

## Workflow

### Step 1 — Ask for work item key and load context

Use **AskUserQuestion** with selectable options:

> "Which work item are we creating a PR for?"
> Options: [ "DCP-1234 (paste your key)", "GitHub #N (paste issue number)", "No issue link — proceed without" ]

Or use the passed argument directly. A work item key is optional; if none is provided, the PR is created without an issue link.

Verify the branch is pushed: run `git status -sb` and check that the upstream tracking branch exists and no local commits are ahead of it. If commits are ahead of remote, stop and tell the user:

> "Branch has unpushed commits. Run `/push-to-git` first."

### Step 1a — Mode detection

The skill runs in `--interactive` mode by default; autonomous mode opts in per dispatch. When `--autonomous` is present, load `@../../AUTONOMOUS-MODE.md` (MANDATORY — see References table) to read the activation contract (§ *Activation triggers*) and the per-gate default table.

In autonomous mode, the Step 1 work-item-key prompt is replaced by:
1. If an argument was passed: use it.
2. Otherwise, read the most-recent `build.jsonl` session entry in the resolved spec folder (`specs/*/build.jsonl`, last entry where `step:"session"` and `status:"start"`) and extract the top-level `story` field as the key. Do NOT use `data.issue` or `data.story` (those fields do not exist in the build.jsonl schema) and do NOT rely on `data.branch` for key recovery — that field is only written by push-to-git and may be absent at this point.
3. If neither step yields a key: HALT with `MISSING_INPUT: build-create-pr in --autonomous mode requires a work-item-key argument or a populated build.jsonl session entry`, write `{step:"session", status:"error", data:{halt_code:"MISSING_INPUT"}}`, and return R1 `status:"failure"`.

Log the bypass via `shared/log-bypass.sh build-create-pr "<key>" work-item-key "<use-arg|read-build-jsonl>" "<agent_id|cli_flag|task_id_bundle>"` when bypassed.

Read from the resolved spec folder under `$REPO_ROOT` (NOT under `$WORKTREE_PATH` — see the entry guard above): `$REPO_ROOT/specs/<key>-*/`:
- `stories.json` — acceptance criteria for this work item (if key was provided and file exists)
- `seed-manifest.json` — optional; when `.spec_tier == "plan-only"` and no `stories.json`, `plan.md` `## Acceptance criteria` is the How-to-Test source (see Step 3)
- `prd.md` — goals, scope, motivation (if exists)
- `plan.md` — completed tasks, for "What changed" bullets; also the plan-only How-to-Test source (if exists)
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

Load `@references/pr-description-guide.md` (MANDATORY — see References table). Use `.github/PULL_REQUEST_TEMPLATE.md` (already read in Step 1) as the body structure — populate each of its sections from spec artifacts. This ensures the produced PR matches the template enforced by the project rather than a free-form body.

**PR title**: `feat: <story title>` — title from `stories.json` or `plan.md`; if no spec, derive from commit messages. Append ` (DCP-1234)` or ` (#42)` when a work item key is available. The full title must fit on one line in GitHub's PR list view: keep it under 72 characters total. Truncate or rephrase the story title if needed; never truncate the issue reference.

**Title format rule**: the title MUST match `^(feat|fix|docs|refactor|test|chore|ci|build|perf|style|revert)(\([a-z0-9-]+\))?: .+$` — the same regex enforced by the CI `pr-title` check. Scope is optional; when present it must be a single `[a-z0-9-]` identifier (no commas, no slashes). For cross-plugin or repo-wide changes, omit the scope entirely (`fix: description`, not `fix(a,b,c): description`). Validate the title against this regex **before** calling `gh pr create` and fail with a clear error if it does not match — do not let CI catch it first.

Fill each template section as follows:

**Description of Changes > What changed**: one bullet per plan task — task title + one sentence on what was changed. If no `plan.md` exists, derive from commit messages.

**Goal Alignment**: plugin name, goal statement (read `AGENTS.md` in the target repo), one sentence connecting this story to the goal.

**Links**: see Step 6 for issue tracker handling. When `created-issues.json` is present and valid, the Links section receives an auto-injected `Closes #N` line per artifact entry (in artifact order), deduped against any user-supplied `GH#N` reference — see Step 6 Case 4.

**How to Test**: one numbered step per acceptance criterion, in this precedence order:
1. **`stories.json` present** → one step per acceptance criterion from `stories.json`.
2. **No `stories.json`, but `spec_tier:plan-only`** (D11 enabler) → read `seed-manifest.json`
   `.spec_tier`; when it is `"plan-only"`, source the steps from `plan.md`
   `## Acceptance criteria` — one numbered step per non-empty acceptance item. This is the
   authoritative test source for the lightweight planning lane; do NOT fall through to the
   commit-message derivation below when a populated `## Acceptance criteria` section exists.
3. **Neither of the above** → write steps derived from the commit messages and changed code
   (existing fallback, unchanged).

Make each step concrete (name the command, the input, the expected output).

**AC Verification block (machine-readable, #347-followup)**: append a fenced block to the PR body carrying the per-AC verdicts produced by `build-review` (diff-reviewer v1.1.0+). This block is the **sole durable transport** of the verdict to the post-merge `documentation-agent` — `workflow-state.json` is gitignored and `build.jsonl` is not staged into the PR, so the PR body is the only artifact that survives to the GHA runner. Source it from the **last** `step:"ac-verification"` entry in the resolved spec folder's `build.jsonl`:

````markdown
## AC Verification
<!-- makato:ac-verdicts — machine-readable; do not hand-edit. Consumed by documentation-agent post-merge. -->
```json
[
  {"ac_id":"AC-1","ac_text":"<verbatim AC text>","verified":true,"evidence":"src/foo.py:42 + tests/test_foo.py:10"},
  {"ac_id":"AC-2","ac_text":"<verbatim AC text>","verified":false,"reason":"<shortfall>"}
]
```
````

Rules:
- Emit the block **only** when a `step:"ac-verification"` entry exists in `build.jsonl`. When none exists (interactive build, or diff-reviewer predates v1.1.0), **omit the entire section** — do NOT emit an empty block. Its absence signals the documentation-agent to skip checkbox marking (no false `[x]`).
- Copy `ac_verdicts[]` verbatim from the last such entry — do NOT re-derive verdicts here. This skill is a transport, not a judge.
- The HTML comment marker `makato:ac-verdicts` is the anchor the documentation-agent greps for; keep it exact.

**Breaking Changes**: check the diff for changes to public APIs, database schemas, or shared contracts. Check `Yes` if any are found and describe the migration path.

**AI-assisted**: pre-check "Code implementation", "Commit messages", "PR description".

**PR Checklist**: pre-check all items that are verifiably true (conventional commit title ✓, CHANGELOG updated ✓, self-contained skills ✓, version bumped if behavior changed).

**Additional Changelog Entries**: leave empty — this is a single-story PR.

---

### Step 4 — Present draft for user review

In **interactive mode**, present the complete draft PR (title + full description body) to the user.

Use **AskUserQuestion** with selectable options:

> "Does this PR description look correct?"
> Options: [ "Approved — open the PR", "Edit title", "Edit description", "Re-generate from spec" ]

Apply any edits the user requests. Re-present if edits alter the title or more than one section. Do not open the PR until the user selects "Approved".

In **autonomous mode**, skip the prompt: proceed directly to Step 5 with the draft as-rendered. Log `shared/log-bypass.sh build-create-pr "<key>" pr-draft-approval open-pr-as-drafted "<agent_id|cli_flag|task_id_bundle>"`. The PR body is populated entirely from spec artifacts (`stories.json`, `prd.md`, `plan.md`) and workflow-state (`build.jsonl`) — no human authoring is required and the `created-issues.json` auto-`Closes` injection in Step 6 Case 4 is the canonical issue-link source.

---

### Step 5 — Create the pull request

**GH_HOST detection**: before calling `gh pr create`, resolve the remote URL:
```
git remote get-url origin
```
Extract the hostname from the URL (e.g. `github.tools.sap` from `https://github.tools.sap/org/repo.git`). If the hostname differs from `github.com`, prefix all subsequent `gh` commands with `GH_HOST=<hostname>`. Emit an informational note: "Using `GH_HOST=<hostname>` — remote is not github.com."

#### Step 5a — Mandatory pre-call audit event

**Before** invoking `gh pr create`, append a `pr_created status:"start"` line so a subsequent silent process death is attributable to this step:

```bash
shared/build-log.sh "<key>" '{"ts":"<ISO8601>","skill":"build-create-pr","story":"<key>","step":"pr_created","status":"start","data":{"branch":"<name>","gh_host":"<hostname>","title_len":<N>}}'
```

This event is required in **every** mode (interactive AND autonomous). Skipping it violates the SKILL.md audit contract — see § *Audit invariant* below.

#### Step 5b — Invoke `gh pr create`

Run:
```
gh pr create --title "<title>" --body "$(cat <<'EOF'
<body>
EOF
)"
```

Base branch: `main`. If the project uses a different default base (e.g. `develop`), check `gh repo view --json defaultBranchRef` or ask the user before creating. Capture both the exit code and stderr:

```bash
GH_STDERR="$(mktemp)"
gh pr create --title "$TITLE" --body "$BODY" 2>"$GH_STDERR"
GH_RC=$?
```

#### Step 5c — Handle result (mandatory branches)

**On success (`GH_RC == 0`):** capture the PR URL from stdout, then append:

```bash
shared/build-log.sh "<key>" '{"ts":"<ISO8601>","skill":"build-create-pr","story":"<key>","step":"pr_created","status":"ok","data":{"pr_url":"<url>","pr_number":<N>}}'
```

Proceed to Step 6.

**On failure (`GH_RC != 0`):** the skill MUST NOT exit silently. Classify and log:

1. Determine `halt_code`:
   - `GH_AUTH_FAILED` — stderr contains `authentication`, `not logged in`, `token`, or `401`.
   - `PR_CREATE_FAILED` — every other non-zero exit (template missing, branch-protection reject, API outage, title too long, unpushed commits detected post-hoc, etc.).
2. Append the finding line **verbatim** (do not paraphrase the `gh` error):

   ```bash
   shared/build-log.sh "<key>" '{"ts":"<ISO8601>","skill":"build-create-pr","story":"<key>","step":"pr_created","status":"error","data":{"halt_code":"<code>","exit_code":<GH_RC>,"stderr":"<first 500 chars, JSON-escaped>"}}'
   ```

3. Append the **terminal session-error** event (see § *Audit invariant* — this is the "either ok or error, never neither" guarantee):

   ```bash
   shared/build-log.sh "<key>" '{"ts":"<ISO8601>","skill":"build-create-pr","story":"<key>","step":"session","status":"error","data":{"halt_code":"<code>","branch":"<name>"}}'
   ```

4. Emit the R1 failure envelope (see § *Return Format*) as the final `json`-fenced block and return. Do NOT retry `gh pr create` silently, and do NOT fall through to Step 6.

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

---

## Anti-patterns

These are production-derived failure modes — most were silent bugs before explicit guards were added.

**NEVER use `data.issue` or `data.story` from `build.jsonl` for key recovery.**
WHY: those fields do not exist in the build.jsonl schema. `build-log.sh` writes the key at the top-level `story` field; the `data` sub-object is free-form payload per skill. Reading a non-existent field silently produces `null` and creates a PR with no issue link and an incorrect session key that later breaks the audit trail search.

**NEVER compare the commit range against bare local `main`.**
WHY: a stale local `main` includes commits from already-merged PRs that happened between your last `git fetch` and now. Those commits appear in `git log main..HEAD` as if they are part of this PR, inflating the "What changed" section with unrelated history. Always resolve via `shared/default-branch.sh` after a `git fetch origin --quiet` so the tip is `origin/main` (or the true remote default).

**NEVER rely on `data.branch` in `build.jsonl` for key recovery.**
WHY: `data.branch` is written only by `build-push-to-git` and is absent if that skill has not run yet (e.g., the agent is re-dispatched after a partial session). Treating an absent field as the key silently falls through to an empty string, producing a MISSING_INPUT halt that looks like a missing argument bug, not a schema misread.

**NEVER truncate the issue reference at the end of the PR title.**
WHY: the CI `pr-title` check validates the full title against the conventional commit regex, and the GitHub PR list renders the issue reference as a clickable identifier. Truncating `(DCP-1234)` to `(DCP-...` breaks both the regex match (non-alphanumeric suffix) and the cross-link. Truncate or rephrase the story title instead.

**NEVER emit an empty `## AC Verification` block when no `step:"ac-verification"` entry exists in `build.jsonl`.**
WHY: an empty block is indistinguishable from a block where all verdicts evaluated to zero. The `documentation-agent` uses block *absence* as the signal to skip checkbox marking entirely — an empty block triggers the checkbox writer and marks every AC as unverified (`- [ ]` stays), which is correct only if a reviewer actually ran. An omitted block means "no reviewer ran" and is the safe fallback.

**NEVER retry `gh pr create` silently after a non-zero exit.**
WHY: `gh pr create` errors split into recoverable (auth token expired, network blip) and hard-stop (branch-protection reject, PR already exists, title too long). A silent retry on a hard-stop reason creates duplicate PR drafts or hammers a rate-limited API endpoint. Log the `halt_code`, emit the R1 failure envelope, and let the PO-agent route the recovery.

**NEVER run `git log` or `gh pr create` from `REPO_ROOT` in autonomous mode when `WORKTREE_PATH` is set.**
WHY: in the autonomous loop each story runs in a dedicated `git worktree add` at `WORKTREE_PATH`. That worktree has its own `HEAD` pointing to the feature branch. Running `gh pr create` from the main checkout instead opens a PR against whatever branch the main checkout is on, not the story branch — this silently creates a PR against `main` from `main` (or the previous story's branch), which GitHub may accept but is irreversible without force-closing.

---

## Autonomous Execution

Autonomous mode is activated per `@../../AUTONOMOUS-MODE.md` § *Activation triggers*.

In autonomous mode:

- **Never prompt the user** — work-item-key and draft-approval gates are bypassed per the rules above.
- **Read workflow-state from `build.jsonl`** when the work-item-key argument is missing — Step 1a documents the lookup order.
- **PR body is fully autogenerated** from spec artifacts (`stories.json`, `prd.md`, `plan.md`, `.github/PULL_REQUEST_TEMPLATE.md`) and workflow-state. No human authoring.
- **Auto-inject `Closes #<n>`** lines from `created-issues.json` per Step 6 Case 4 — this is the canonical issue-link source in autonomous mode.
- **Render the AC Verification block** from the last `build.jsonl` `step:"ac-verification"` entry (Step 3) so the post-merge `documentation-agent` can flip verified AC checkboxes. Omit the block entirely when no such entry exists.
- **Log every bypass** to `build.jsonl` via `shared/build-log.sh` with the `autonomous_bypass` event schema documented in `@../../AUTONOMOUS-MODE.md`.
- **Emit an R1 envelope** as the final `json`-fenced block of the skill's output.

### Return Format (R1, when called as a sub-skill)

Top-level R1 envelope fields follow `plugins/makato-build/agents/RETURN-CONTRACT.md` § *R1 envelope schema*. The skill-specific `data` payload is:

**On success:**

```json
{
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

`agent` is `"build-create-pr"`. `summary` is `"Opened PR <url>"` on success.

**On failure (`gh pr create` non-zero exit — Step 5c error branch):**

```json
{
  "status": "failure",
  "agent": "build-create-pr",
  "summary": "gh pr create failed: <first line of stderr>",
  "errors": ["<halt_code>: <gh stderr, first 500 chars>"],
  "data": {
    "halt_code": "GH_AUTH_FAILED" | "PR_CREATE_FAILED",
    "exit_code": <GH_RC>,
    "branch": "<name>",
    "gh_host": "<hostname>"
  }
}
```

The PO-agent reads `data.halt_code` and routes per `plugins/makato-build/halt-codes.md` (`GH_AUTH_FAILED` → operator-escalation; `PR_CREATE_FAILED` → operator-escalation).

### Audit invariant

`build-create-pr` MUST emit **exactly one** terminal `step:"session"` line per invocation — either `status:"ok"` (Step 7 happy path) or `status:"error"` (Step 5c failure branch). Any other exit — silent process death, uncaught exception, model-turn drift, context ceiling mid-skill — is a contract violation and appears in `build.jsonl` as an unclosed session (last event is not `step:"session"` with terminal status).

Fixed by v1.7.0 (#169): earlier versions had no mandatory error-branch logging, so an autonomous session that failed inside `gh pr create` left the audit trail ending on `pr-draft-approval bypass` and the PO-agent had no `halt_code` to route on. See `plugins/makato-build/shared/audit-contract-smoke-tests.sh` — the smoke test scans this file for the mandatory audit events (`pr_created status:"start"`, per-branch `status:"ok"` and `status:"error"`, terminal `session` closes) and CI fails when any regress out.

### HALT Codes

The HALT codes emitted by this skill (`MISSING_INPUT`, `UNPUSHED_COMMITS`, `GH_AUTH_FAILED`, `PR_CREATE_FAILED`) are registered with their PO-agent recovery routes in `plugins/makato-build/halt-codes.md`.

Skill-specific behavioural note: `MISSING_INPUT` here fires only when neither the positional argument NOR a recoverable `build.jsonl` session entry yields a work-item-key — see Step 1a for the two-step resolution order.
