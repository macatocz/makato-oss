---
name: build-start
description: >-
  Entry point for a full build session — validates git state, validates spec
  prerequisites, captures implementation mode, initializes the build log, and
  kicks off /build-refine. Use when starting a new story build, beginning the
  makato-build workflow, running build-start on a work item, or starting local
  work without a ticket.
version: "1.7.0"
argument-hint: "[work-item-key]"
allowed-tools: [Bash]
metadata:
  last_updated: "2026-08-15"
---

# build-start

## Mindset

Three non-obvious ordering principles drive this skill's sequencing:

1. **Claim before plan.** Marking the issue In Progress (Step 2d) happens at
   the earliest safe moment — after git state is verified but before
   `/build-refine` consumes tokens. This prevents the autonomous loop from
   dispatching a second agent to the same issue concurrently; a clean git
   branch is the authoritative ownership signal, but the board claim is the
   race guard.
2. **Canary before commit.** Running the test framework before refinement
   (Step 2e) catches a red baseline before file targets are committed to
   `plan.md`. A plan written on a broken foundation is invalid from birth —
   the TDD RED→GREEN loop cannot distinguish "tests I wrote" from "tests
   already broken before I started".
3. **Board is best-effort; git is hard-stop.** Board update failures never
   block a build session — the branch namespace is the authoritative ownership
   record. Git state violations always stop — a dirty tree or diverged base
   corrupts the branch diff that `/build-review` uses to judge AC coverage.

## When to Use

Use at the beginning of every makato-build session, before `/build-refine`.

For ticket-based work: spec artifacts must have been produced by makato-plan
(or equivalent) before this skill can run.

For local work without a ticket: this skill creates a minimal `design.md` via
a short interview, then hands off to `/build-refine`.

**Do NOT use when:**
- Resuming mid-session — each skill in the pipeline is invocable directly

## Workflow

### Step 1 — Identify the work item

Ask: *"Which work item are we building? (Jira key, GitHub issue, or press Enter
for local work without a ticket)"* — or use the argument passed directly.

- If a key is given: normalize to uppercase (e.g. `dcp-1234` → `DCP-1234`).
  Set `key = <normalized-key>`. Set `local_work = false`.
- If no key (user pressed Enter or passed nothing): ask for a short kebab-case
  slug describing the work (e.g. `fix-auth-bug`, `refactor-invoice-mapper`).
  Set `key = "local-<slug>"`. Set `local_work = true`.

Before any board-gate logging or helper invocation, resolve
`MAKATO_BUILD_ROOT` from the runner-provided installed-plugin root contract
(`CLAUDE_PLUGIN_ROOT`, `OMP_PLUGIN_ROOT`, or `PLUGIN_ROOT`). All suite-owned
helpers below use this absolute path; never assume the consumer repository
contains `plugins/makato-build`.

### Step 1b — DoR gate

Only when `local_work = false`. Check the board item's Status before git pre-flight to confirm the issue is Ready — ensuring the PO has shaped and approved the work before tokens are spent on planning and implementation.

**Read project config** from `.claude/config.json`. If the `github_project` block is absent (or missing any of `fields.status.id`, `fields.status.options.ready`, `project_node_id`, `host`, `owner`, `number`), skip the gate with:
> `build-start: WARN — no github_project config — DoR gate skipped`

Log the skip and continue to Step 2 unchanged:
```bash
"$MAKATO_BUILD_ROOT/shared/build-log.sh" "<key>" '{"ts":"<ISO8601>","skill":"build-start","story":"<key>","step":"dor-gate","status":"warn","data":{"reason":"no-github-project-config"}}'
```

**When `github_project` is present:**

Resolve `ISSUE_NUMBER` using the same two-step lookup as Step 2d (manifest first, then integer-key direct). If `ISSUE_NUMBER` is empty, skip the gate silently and continue.

Read the item's current Status:
```bash
ITEM_LINE="$(GH_HOST="$HOST" gh project item-list "$PROJECT_NUMBER" \
  --owner "$OWNER" --format json --limit 9999 \
  --jq ".items[] | select(.content.number == $ISSUE_NUMBER)" 2>/dev/null \
  | head -1)"
ITEM_ID="$(jq -r '.id // empty' <<<"$ITEM_LINE")"
CUR_STATUS="$(jq -r '.status // empty' <<<"$ITEM_LINE")"
```

If `ITEM_ID` is empty: log `build-start: WARN — issue #$ISSUE_NUMBER not found on board; DoR gate skipped` and continue.

**When `CUR_STATUS == "Ready"`:** log and continue to Step 2:
```bash
"$MAKATO_BUILD_ROOT/shared/build-log.sh" "<key>" '{"ts":"<ISO8601>","skill":"build-start","story":"<key>","step":"dor-gate","status":"ok","data":{"issue":<ISSUE_NUMBER>,"board_status":"Ready"}}'
```

**When `CUR_STATUS != "Ready"` (e.g. Todo, Blocked, In Progress):**

In **interactive mode**: stop immediately with an actionable message:
> "Issue #$ISSUE_NUMBER board Status is '$CUR_STATUS' — not Ready. Move the item to Ready on the board before starting a build session."

Log:
```bash
"$MAKATO_BUILD_ROOT/shared/build-log.sh" "<key>" '{"ts":"<ISO8601>","skill":"build-start","story":"<key>","step":"dor-gate","status":"error","data":{"halt_code":"DOR_NOT_READY","issue":<ISSUE_NUMBER>,"board_status":"<CUR_STATUS>"}}'
```

In **autonomous mode** (`--autonomous`): log the same entry above, then return R1 `status: "failure"` with `data.halt_code: "DOR_NOT_READY"` and `errors: ["DOR_NOT_READY: issue #<ISSUE_NUMBER> board Status is '<CUR_STATUS>' — expected Ready"]`.

### Step 2 — Git pre-flight

Run these checks before touching any spec files:

The `MAKATO_BUILD_ROOT` resolved before Step 1b remains in force. All helper
commands in this skill use that absolute path; the consumer repository is not
assumed to contain the makato plugin checkout.

Resolve the workspace before running any pre-flight command so `git status`,
fetches, comparisons, and later edits all target the isolated checkout:

```bash
# WORKTREE_PATH is supplied by the autonomous orchestrator. In interactive
# mode it may be the current checkout (a developer can start on a feature
# worktree); it is never silently changed to a new ambient branch.
if [[ -z "${WORKTREE_PATH:-}" ]]; then
  if [[ -n "${AGENT_ID:-}" || -n "${TASK_ID:-}" || "${AUTONOMOUS_MODE:-}" == "1" ]]; then
    # Return R1 failure: MISSING_INPUT: WORKTREE_PATH required in autonomous mode.
    exit 1
  fi
  WORKTREE_PATH="$(git rev-parse --show-toplevel)"
fi
cd "$WORKTREE_PATH"
REPO_ROOT="$(cd "$(git -C "$WORKTREE_PATH" rev-parse --git-common-dir)/.." && pwd)"
```

Only after this resolution, run the following checks:

**2a — Clean working tree**

Run `git status --porcelain`. If output is non-empty → stop. Tell the user:

> "Working tree is dirty. Commit, stash, or discard your changes before
> starting a build session. Run `git status` to see what's modified."

**2b — Fetch and check branch state**

Run `git fetch origin` (silent — update remote refs only).

Get the current branch: `git branch --show-current`.

Compare local vs remote:
- `git rev-parse HEAD` vs `git rev-parse origin/<branch>` (if the remote
  ref exists — skip if the branch has no upstream yet).
- If local is **behind** origin: ask *"Your branch is behind origin/<branch>.
  Pull latest before starting? [Y/n]"*. If yes, run `git pull --ff-only`. If no,
  warn and continue.
- If local is **ahead** of origin: warn *"Branch has local commits not yet
  pushed to origin. You are starting from existing work, not a fresh session."*
  Continue (do not stop).

**Upstream sync check** (fork workflows): run `git remote` to list remotes. If an `upstream` remote exists:
1. Run `git fetch upstream` (silent).
2. Find the merge base: `git merge-base HEAD upstream/main` (or `upstream/master` — use whichever exists).
3. Compare the merge base to `upstream/main`: `git rev-list --count <merge-base>..upstream/main`.
4. If the count is > 0: warn *"Your branch base is `<N>` commit(s) behind `upstream/main`. Consider rebasing before starting work to avoid merge conflicts at PR time: `git rebase upstream/main`. Continue anyway? [Y/n]"*. If no: stop. If yes: continue.
5. If no `upstream` remote: skip this check silently.

**2c — Branch/worktree check**

`build-start` MUST NOT create a branch by mutating the caller's checkout. The
workspace guard above already changed into `WORKTREE_PATH` and derived
`REPO_ROOT`; this step only validates the checked-out branch and resolves the
protected/default integration branch.

Resolve the protected/default integration branch before deciding whether this
checkout is safe. `development` is a valid default branch and MUST be treated
the same as `main`/`master`:

```bash
DEFAULT_REF="$(git symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null || true)"
if [[ -z "$DEFAULT_REF" ]]; then
  DEFAULT_REF="$(
    git ls-remote --symref origin HEAD 2>/dev/null |
      awk '$1 == "ref:" && $2 ~ /^refs\/heads\// {sub(/^refs\/heads\//, "", $2); print "origin/" $2; exit}' ||
      true
  )"
fi
if [[ -z "$DEFAULT_REF" && -x "$MAKATO_BUILD_ROOT/shared/default-branch.sh" ]]; then
  DEFAULT_REF="$("$MAKATO_BUILD_ROOT/shared/default-branch.sh" 2>/dev/null || true)"
fi
DEFAULT_BRANCH="${DEFAULT_REF#refs/remotes/origin/}"
DEFAULT_BRANCH="${DEFAULT_BRANCH#origin/}"
CURRENT_BRANCH="$(git branch --show-current)"
```

If `CURRENT_BRANCH` equals the resolved `DEFAULT_BRANCH` (or, when no remote
default can be resolved, equals `main` or `master`), do **not** run a
branch-creation checkout (or any other branch-creation command) here:

- In autonomous mode this is a lifecycle violation. Stop with
  `MISSING_INPUT: WORKTREE_PATH required in autonomous mode`; the PO-agent must
  create/resume the registered worktree through
  `shared/worktree.sh create [--new-branch] <KEY> <ISSUE_NUMBER> <REPO> <BRANCH>`
  before dispatching `build-start`.
- In interactive mode, hand off instead of changing the ambient checkout:
  > "`build-start` does not create branches in the caller checkout. Create or
  > resume an isolated worktree through the makato-orchestrate lifecycle
  > (or run `git worktree add -b <branch> <path> <base>`), then rerun
  > `build-start <key>` from that worktree with `WORKTREE_PATH=<path>`."
When `WORKTREE_PATH` is already a registered feature worktree, continue the
pre-flight checks and pass both `WORKTREE_PATH` and `REPO_ROOT` to every
downstream build skill. This makes source edits, tests, commits, and pushes
stay in the isolated worktree while specs and audit logs remain in `REPO_ROOT`.

### Step 2d — Mark In Progress on project board

Only when `local_work = false`. This is the earliest safe moment to claim the issue — git state is clean and work is about to start. Marking now prevents the autonomous loop from picking up the same issue concurrently.

**Determine the GitHub issue number:**

1. If `key` is a plain integer (e.g., `450`): use it directly as `ISSUE_NUMBER`.
2. Otherwise: resolve `SPEC_FOLDER` with
   `python3 "$MAKATO_BUILD_ROOT/shared/spec_folder.py" "$REPO_ROOT" "$key"`
   and read `.issue_number` from its manifest:
   ```bash
   ISSUE_NUMBER="$(jq -r '.issue_number // empty' "$SPEC_FOLDER/seed-manifest.json" 2>/dev/null || true)"
   ```
3. If `ISSUE_NUMBER` remains empty: skip this step silently (Jira-only key with no manifest — cannot resolve to a board item).

**Read project config** from `.claude/config.json`. If the `github_project` block is absent, or any of `fields.status.id`, `fields.status.options.in_progress`, `project_node_id`, `host`, `owner`, `number` are missing, skip with:
> `build-start: WARN — .claude/config.json has no github_project config — board status not updated`

**Otherwise:**

1. Find the board item and its current status:
   ```bash
   ITEM_LINE="$(GH_HOST="$HOST" gh project item-list "$PROJECT_NUMBER" \
     --owner "$OWNER" --format json --limit 9999 \
     --jq ".items[] | select(.content.number == $ISSUE_NUMBER)" 2>/dev/null \
     | head -1)"
   ITEM_ID="$(jq -r '.id // empty' <<<"$ITEM_LINE")"
   CUR_STATUS="$(jq -r '.status // empty' <<<"$ITEM_LINE")"
   ```
   If `ITEM_ID` is empty: log `build-start: WARN — issue #$ISSUE_NUMBER not found on board; skipping In Progress update` and continue.

2. Set Status = In Progress (only if not already set):
   If `CUR_STATUS` is already `"In progress"`: log `build-start: #$ISSUE_NUMBER is already In Progress — skipping` and continue.
   Otherwise:
   ```bash
   GH_HOST="$HOST" gh project item-edit \
     --id "$ITEM_ID" \
     --project-id "$PROJECT_NODE_ID" \
     --field-id "$STATUS_FIELD_ID" \
     --single-select-option-id "$IN_PROGRESS_OPTION_ID"
   ```
   On success: log `build-start: marked #$ISSUE_NUMBER as In Progress on project board`.
   On failure: log `build-start: WARN — could not set In Progress on board; continuing` (best-effort — never block the build session).

### Step 2e — Canary test-framework pre-flight

Run a single canary test to verify the test framework is operational before dispatching `/build-refine`. This catches a broken baseline early — before planning commits to file targets on a red foundation.

**Discover the unit command** by dispatching the `gate-scout` agent (same agent used by `/build-verify`). If no unit command is discovered (no test framework present in the project), log a skip entry and proceed to Step 3 unchanged:

```bash
"$MAKATO_BUILD_ROOT/shared/build-log.sh" "<key>" '{"ts":"<ISO>","skill":"build-start","story":"<key>","step":"canary-skipped","status":"ok","data":{"reason":"no-unit-command"}}'
```

Append one `build.jsonl` entry with step `"canary"`, `status: "ok"`, `data.event: "CANARY_SKIPPED"` so the audit trail records the skip:

```json
{"ts":"<ISO>","skill":"build-start","story":"<key>","step":"canary","status":"ok","data":{"event":"CANARY_SKIPPED","reason":"no-unit-command"}}
```

**When a unit command is discovered**, run it once with a timeout of 30 seconds (or the equivalent flag for the discovered runner — e.g. `--timeout 30` for pytest, `--testTimeout 30000` for jest):

```bash
<unit_command> --timeout 30
```

- **Canary passes (exit 0):** append one `build.jsonl` entry and proceed to Step 3:

  ```json
  {"ts":"<ISO>","skill":"build-start","story":"<key>","step":"canary","status":"ok","data":{"event":"CANARY_PASSED","unit_command":"<discovered-command>"}}
  ```

- **Canary fails (non-zero exit or timeout):** append one `build.jsonl` entry, then HALT with `CANARY_FAILED`:

  ```json
  {"ts":"<ISO>","skill":"build-start","story":"<key>","step":"canary","status":"error","data":{"event":"CANARY_FAILED","unit_command":"<discovered-command>","exit_code":<N>}}
  ```

  Stop immediately. Do NOT proceed to Step 3 or dispatch `/build-refine`. Return a clear message to the user:

  > "The canary test run failed before planning began. The test framework is broken or the baseline is already red. Fix the test failures first, then re-run `build-start`.
  > Failing command: `<unit_command> --timeout 30`
  > Exit code: `<N>`"

  In **autonomous mode** (`--autonomous`): return R1 `status: "failure"` with `data.halt_code: "CANARY_FAILED"` and `errors: ["CANARY_FAILED: unit command exited <N> before build-refine dispatch"]`.

## HALT Codes

This skill registers one skill-level halt code. See `plugins/makato-build/halt-codes.md` for the full registry.

| Code | Step | Route | Description |
|------|------|-------|-------------|
| `DOR_NOT_READY` | Step 1b | operator-escalation | Board item Status is not Ready (e.g. Todo, Blocked, In Progress). The issue must be moved to Ready before starting a build session. In autonomous mode returns R1 `status:"failure"` with `data.halt_code:"DOR_NOT_READY"`. |
| `CANARY_FAILED` | Step 2e | operator-escalation | Unit command exited non-zero or timed out before `build-refine` was dispatched. See `halt-codes.md` for recovery instructions. |

### Step 3 — Validate or create spec

**Ticket path** (`local_work = false`):

Run the installed resolver:

```bash
SPEC_FOLDER="$(
  python3 "$MAKATO_BUILD_ROOT/shared/spec_folder.py" "$REPO_ROOT" "$key"
)"
```

The resolver preserves direct prefix and exact-key matches. For a numeric
GitHub key (`N` or `#N`) it additionally finds a unique folder containing
`plan-N.md`, a matching `seed-manifest.json`, `created-issues.json`, or
`workflow-state-N.json`. `to-issues`'s `specs/<slug>/plan-N.md` shape is
therefore supported without renaming the spec.

**Multiple matches:** the resolver never selects the first directory. Stop and
report:

> "Multiple spec folders found for `<key>`: `<list>`. Disambiguate by passing the full folder name as the key, e.g. `build-start DCP-1234-feat-a`."

- If no resolver match exists → stop: *"No spec folder found for `<key>`.
  Run makato-plan first to produce shaped artifacts, or pass the full spec
  slug."*
- If `stories.json` is missing → check whether `prd.md` and `design.md`
  both exist in the spec folder. If they do — stop:

  > "No `stories.json` found for `<key>`, but `prd.md` and `design.md` are present.
  > Run `/makato-plan:decompose <key>` to generate `stories.json`, then return to
  > `/build-start`."

  If `prd.md`/`design.md` are also absent — stop:

  > "Folder `specs/<key>-*/` exists but is missing `stories.json`. Run the makato-plan
  > pipeline first to complete the spec."
- If `plan.md` already exists in the spec folder → do NOT stop. Show the plan's title
  and task count, then offer:

  > "A plan already exists for `<key>`:
  > — `<plan-title>` · `<N>` tasks · mode: `<mode>`
  >
  > **(A) Continue existing session** — skip to `/build-refine` (reads the current plan)
  > **(B) Start fresh** — archive `plan.md` to `plan.md.bak` and re-run `/build-refine`
  > **(C) Implement now** — proceed directly to `/build-implement-tdd` or `/build-implement-goal`"
  >
  > Wait for the user's choice before continuing. If (B): rename `plan.md` to `plan.md.bak`
  > in the spec folder, then proceed to Step 4 as normal and invoke `/build-refine`. If (A)
  > or (C): skip to Step 5 (initialize build log) and invoke the appropriate implement skill.
- Warn (do not stop) if optional artifacts are absent: `prd.md`, `design.md`,
  `decisions.md`. State that `/build-refine` will run with reduced context.

**Local-work path** (`local_work = true`):

If `specs/local-<slug>/plan.md` already exists → apply the same recovery offer as the ticket-path (show summary, offer Continue / Start fresh / Implement now). If the user chooses (A) or (C): skip to Step 5 — do NOT run the interview below.

Create `specs/local-<slug>/` if it does not exist.

Run a short interview and write `specs/local-<slug>/design.md` **only if this is a new session** (no existing plan):

> Ask the following three questions, then write the file:
>
> 1. *"What are you trying to accomplish? (1–3 sentences)"*
> 2. *"Which files or components will this touch? (freeform, best guess)"*
> 3. *"Any constraints or things to avoid?"*

Write `specs/local-<slug>/design.md`:

```markdown
# Design: <slug>

## Goal

<answer to question 1>

## Scope

<answer to question 2>

## Constraints

<answer to question 3, or "None stated." if blank>
```

Tell the user: *"No stories.json will be created. `/build-refine` will read
`design.md` and derive a goal and acceptance criteria from it."*

### Step 4 — Select implementation mode

**Quick decision heuristic (covers the common case without loading the reference):**

| Story primarily involves… | Default mode |
|---|---|
| Business logic, API endpoints, data processing, event handling, validators | **TDD** |
| Database migrations (must run before tests verify schema) | **Goal** |
| Config changes, CLI scripts where behavior is observed by running | **Goal** |
| A mix of the above | **TDD** — let `/build-refine` override per-task |

Ask the user:
> "Which implementation mode? **(T) TDD** — tests-first, for logic/APIs/services. **(G) Goal** — build-first, for UI/config/migrations. [T/g]"

If the user is unsure or the story spans both categories: default to **TDD**. The `/build-refine` step will override individual tasks to Goal mode when it detects UI or migration work during plan decomposition.

**MANDATORY: Load @references/pipeline-map.md** when the user asks for a detailed pipeline overview, when the story has an unusual structure (e.g. involves the `grill-with-docs` optional phase), or when you need to verify hook-triggered phase transitions.

**Do NOT Load** `references/pipeline-map.md` outside Step 4, or when the heuristic table above is sufficient to answer the mode question. Front-loading it wastes context that `/build-refine` needs for plan decomposition.

### Step 4a — Resolve workflow schema

Before initialising the build log, resolve the workflow schema for this session.
The schema determines which skill artifacts are assembled into the pipeline.

Run `workflow-schema-loader.sh` passing the repository root as the first argument:

```bash
REPO_ROOT="$(cd "$(git -C "$WORKTREE_PATH" rev-parse --git-common-dir)/.." && pwd)"
ARTIFACT_LIST="$(bash "$MAKATO_BUILD_ROOT/scripts/workflow-schema-loader.sh" "$REPO_ROOT" 2>/tmp/schema-loader-err)"
SCHEMA_EXIT=$?
```

**On exit 0:** `ARTIFACT_LIST` contains one JSON object per line, each with fields
`id`, `skill`, `required`, `description`. Use this list to assemble the pipeline
order for Step 6. Log the resolved schema source:

```bash
SCHEMA_SOURCE="custom"   # or "default" — readable from first loader stderr line or infer:
# if .claude/workflow-schema.yml is absent → "default"
if [[ ! -f "$REPO_ROOT/.claude/workflow-schema.yml" ]]; then
  SCHEMA_SOURCE="default"
fi
```

**On exit 1 or 2:** The schema is invalid (parse error, cycle detected, or missing
arg). Do NOT continue — stop and report:

> "Workflow schema error: `<contents of /tmp/schema-loader-err>`
>
> Fix `.claude/workflow-schema.yml` before starting the build session. See
> `docs/workflow-schema.md` for format documentation."

Log the error:

```bash
"$MAKATO_BUILD_ROOT/shared/build-log.sh" "<key>" '{"ts":"<ISO8601>","skill":"build-start","story":"<key>","step":"schema-resolved","status":"error","error":"<loader stderr>"}'
```

### Step 5 — Initialize build log

Run:

```bash
"$MAKATO_BUILD_ROOT/shared/build-log.sh" "<key>" '{"ts":"<ISO8601>","skill":"build-start","story":"<key>","step":"session-start","status":"start","data":{"mode":"<tdd|goal>","local_work":<true|false>,"spec_artifacts":[...],"schema_source":"<default|custom>"}}'
```

List every artifact file found in the resolved `specs/<key>-*/` folder in the `spec_artifacts` array.
Include `schema_source` from Step 4a.

### Step 6 — Hand off to build-refine

Tell the user what to expect from `/build-refine`: it will read spec artifacts,
inspect the codebase, and produce `plan.md` in the spec folder — a task list with
file targets, test strategy, and acceptance mapping. It is interactive and will ask
questions before finalizing the plan.

Dispatch `/build-refine <key>` with the resolved workspace context:

```text
WORKTREE_PATH=<absolute registered worktree path>
REPO_ROOT=<absolute main checkout path>
MAKATO_BUILD_ROOT=<absolute installed makato-build root>
```

`build-refine` uses `WORKTREE_PATH` for source inspection and `REPO_ROOT` for
gitignored spec artifacts. Never omit or replace these fields with the ambient
checkout path.

Run:

```bash
"$MAKATO_BUILD_ROOT/shared/build-log.sh" "<key>" '{"ts":"<ISO8601>","skill":"build-start","story":"<key>","step":"session-end","status":"ok","data":{"next":"build-refine","worktree_path":"<WORKTREE_PATH>","repo_root":"<REPO_ROOT>"}}'
```

Invoke `/build-refine <key>` with the same `WORKTREE_PATH`, `REPO_ROOT`, and
`MAKATO_BUILD_ROOT` fields.

## Anti-Patterns

### NEVER proceed to Step 3 or dispatch `/build-refine` when the canary fails

**WHY:** `plan.md` encodes file targets chosen against the current codebase state. If the baseline is already red, the TDD RED→GREEN loop cannot distinguish "tests I wrote" from "tests that were already broken before I started" — the INTEGRATE phase gate becomes meaningless. Fix the baseline first; a plan built on broken ground must be discarded.

### NEVER let a board update failure block the build session

**WHY:** The board status is best-effort metadata. The authoritative record that "this issue is owned right now" is the feature branch in git. Blocking on a `gh project item-edit` timeout or API error does not protect against concurrent dispatch and wastes build tokens — the branch namespace provides the real race guard.

### NEVER silently use the first result when multiple `specs/<key>-*/` folders exist

**WHY:** Two folders with the same key prefix indicate a corrupted spec state — usually a re-seeded issue that created a second folder without removing the first. Silently loading the wrong `stories.json` produces a plan targeting files from a different feature; the error surfaces only at review time when AC coverage fails, not at plan-start when it is cheapest to fix.

### NEVER stop when `plan.md` already exists

**WHY:** A pre-existing `plan.md` almost always means a partially-executed session. Stopping with an error forces the user to manually archive or delete it; offering Continue / Start-fresh / Implement-now is the only path that preserves work-in-progress without data loss. The archive-to-`plan.md.bak` option preserves the old plan for diff comparison if the new plan diverges.

### NEVER use `pwd` for persistent paths in `build-log.sh` entries or `REPO_ROOT` derivation

**WHY:** `pwd` varies by shell invocation context — it diverges between worktrees, Claude invocation directories, and the autonomous loop's dispatched agent contexts. `git rev-parse --show-toplevel` is the only path stable across all contexts. `build.jsonl` entries using wrong absolute paths silently fail the log-archiver that reads `specs/<key>/` from the repo root.

### NEVER start the build session on `main` or `master` without creating a feature branch

**WHY:** `/build-push-to-git` pushes commits to the current branch. If that branch is `main`, the commits go directly to the protected default branch — bypassing PR review, CI gates, and AC verification. The branch check at Step 2c is the only guard; it must run before any spec file is written or the build log initialized.
