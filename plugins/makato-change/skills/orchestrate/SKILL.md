---
name: orchestrate
description: >-
  Entry-point coordinator for the makato-change workflow (analyze → design →
  execute → resolve-review). Use when starting or resuming a change request,
  unsure which phase is next, or wanting guided end-to-end autonomous or
  interactive coordination. Keywords: orchestrate change request, resume CR
  workflow, which phase next, coordinate change workflow, guided change,
  autonomous change dispatch.
version: "1.6.1"
argument-hint: "[ISSUE-KEY] [--autonomous]"
allowed-tools: Bash, Skill
metadata:
  Authors: makato-change team
  last_updated: "2026-08-05"
---
# orchestrate

Entry-point coordinator for the complete change request workflow. Coordinates four phases — analyze, design, execute, resolve-review — tracking state in `specs/<ISSUE_KEY>/` artifacts and the project board, and optionally operating headless in autonomous mode.

## OMP skill dispatch boundary

This boundary applies only when the resolved `MAKATO_HARNESS_MODE` is `omp`.
For `claude` and other non-OMP harnesses, keep the native invocations below unchanged.

Execute workflow skills from makato-build, makato-plan and makato-change in separate
OMP runs through `python3 "$MAKATO_SKILL_RUNNER"`, not inline Skill/Task calls.
Resolve the runner from `$MAKATO_BUILD_ROOT/scripts/run-skill.py` if not already
exported; if neither path is available, report the missing makato-build runtime.
This rule applies to every skill dispatch below, including retries and follow-on
skills. It does not replace ordinary helper-agent dispatch or reference reads.

For each invocation, write a context file containing the complete current bundle
(REPO_ROOT, WORKTREE_PATH, issue/key, artifact paths, decisions, and step-specific
inputs). The new session has no parent conversation history. Run:

```bash
python3 "$MAKATO_SKILL_RUNNER" --repo-root "$REPO_ROOT" \
  --cwd "${WORKTREE_PATH:-$REPO_ROOT}" --context-file "$CONTEXT_FILE" \
  makato-build:build-refine -- "$KEY" --autonomous
```

Replace the skill and its arguments for the selected phase. Wait for completion,
then apply the existing result/artifact checks. Nonzero exit is a dispatch failure;
never silently fall back to inline execution. Human-driven interviews use
`--interactive` before the skill name. The selected current skill executes its own
body inline; it must not launch itself again merely to apply this policy.


## When to Use

- Starting a new change request implementation
- Resuming work on an existing change request
- Unsure which phase to run next
- Want a guided workflow instead of invoking individual phase skills

**Do NOT use this skill if:**

- You already know exactly which phase skill to invoke (use that skill directly)
- You're working on something other than a change request (use makato-plan for new features; for bugs, route through makato-plan if shaping is needed or makato-build if the fix is well-scoped)

## Orchestrator Mindset

This skill is a **state machine coordinator**, not a phase implementer. Its two responsibilities are: (1) determine authoritative current state from artifacts on disk, never from memory or assumption; (2) advance exactly one phase at a time, verifying the artifact boundary before and after each dispatch. Resist the urge to skip artifact checks to save a shell call — a missing `analysis.md` means the previous phase did not complete, regardless of what the state file says.

**Phase trust hierarchy (most to least authoritative):**

1. Artifact presence on disk (`analysis.md`, `design.md`, PR link)
2. `change-state-<N>.json:.phases_complete` field
3. `workflow-state-<N>.json:.current_phase` field

Artifacts win over state files if they conflict. State files win over GitHub board status.

**Key non-obvious decisions:**

- Board promotion to "In Progress" happens **before** phase dispatch, not after. Racing the autonomous loop is the failure mode — a second dispatch of the same issue after the first is already In Progress is catastrophic.
- On resume, recover `WORKTREE_PATH` from state first; skip Step 0.5 initialization entirely. Reinitializing drops the worktree link and turns the subsequent `--new-branch` into a hard-fail.
- `resolve-review` is NEVER dispatched in autonomous mode — see Anti-Patterns for why.

## Autonomous mode

> **MANDATORY — Load `@references/autonomous-mode.md` at Step 0.5, ONLY when `--autonomous` is present or any other activation trigger fires.**
> **Do NOT Load** when running interactively (no activation trigger) — it is irrelevant and wastes context.

This skill supports headless operation. See `references/autonomous-mode.md` for activation triggers, HALT codes, logging contract, and the R1 return envelope.

## Progress comment

Narrate every phase dispatch into a single live GitHub issue comment so anyone watching the issue can follow the run in plain English.

`${MAKATO_ORCHESTRATE_SHARED}/progress-comment.sh` is the only entry point. Three subcommands:

```bash
"${MAKATO_ORCHESTRATE_SHARED}/progress-comment.sh" start <KEY> <ISSUE_NUMBER> <REPO> \
  --skill <s> --agent <a> --input <i> --goal <g>
"${MAKATO_ORCHESTRATE_SHARED}/progress-comment.sh" done  <KEY> <ISSUE_NUMBER> <REPO> \
  --skill <s> --result <r> --summary <sum>
"${MAKATO_ORCHESTRATE_SHARED}/progress-comment.sh" note  <KEY> <ISSUE_NUMBER> <REPO> --text <t>
```

`ISSUE_NUMBER` is the numeric GitHub issue number. `REPO` is the `<owner>/<repo>` slug of the makato repo (not the target repo). Resolve both from `workflow-state-<N>.json` (Step 0.5) or from `gh issue view <ISSUE_KEY>`.

**Contract invariants:**

- **Best-effort, never fatal.** Any `gh` / state failure logs a WARN and exits 0. Never triggers a HALT, never blocks a dispatch.
- **Only when `MAKATO_ORCHESTRATE_SHARED` is set.** If the variable is unset, skip all progress-comment calls silently.
- **Opt-out.** `MAKATO_PROGRESS_COMMENT_DISABLE=1` makes every call a silent no-op.

**Per-phase narration rows:**

| Phase dispatch | `--skill` | `--agent` | `--goal` |
|---|---|---|---|
| Analyze | `change-analyze` | `requirements analyst` | analyse requirements and compare against current behaviour |
| Design | `change-design` | `technical designer` | design the technical approach for the change |
| Execute | `change-execute` | `coder` | implement the change, run verification, and open a PR |
| Resolve Review | `change-resolve-review` | `fix agent` | resolve the review comments on the pull request |

## Workflow

### Step 0.5: Autonomous initialization (only when --autonomous)

> **MANDATORY — Load `@references/autonomous-mode.md` now if not already loaded.**

**Only execute this step when autonomous mode is active (see `references/autonomous-mode.md` § *Activation triggers*).**

1. **Read ISSUE_KEY from CLI arg** — if the first argument is present, use it as `ISSUE_KEY`. If absent, HALT with R1 `status:"failure"` and `errors:["MISSING_INPUT: ISSUE_KEY required in autonomous mode"]`.

2. **Detect fresh vs resume run.** Check whether `specs/<ISSUE_KEY>/change-state-<N>.json` already exists **and** has a non-null `worktree_path`. This branch is load-bearing: on a context-handoff resume the state file and the feature branch already exist, so re-initializing from scratch is wrong — it resets `current_phase` and hard-fails the `--new-branch` worktree create.

   **Resume branch** — `change-state-<N>.json` exists with a non-null `worktree_path`:

   a. Do **NOT** overwrite `workflow-state-<N>.json` or `change-state-<N>.json`.
   b. Do **NOT** reset `current_phase` — the file already records where the run was interrupted.
   c. Recover `WORKTREE_PATH` using the probe-then-create pattern (the canonical source is `po-agent.md` Step 2b — never mutate a local git branch directly, #170):

      ```bash
      BRANCH="feat/<KEY>-change"
      if git -C "<REPO_ROOT>" ls-remote --exit-code origin "$BRANCH" >/dev/null 2>&1; then
        # Branch exists on remote — idempotent create WITHOUT --new-branch
        # (worktree.sh re-attaches to a registered worktree, emitting
        # `worktree_resumed`; --new-branch would hard-fail here).
        WORKTREE_OUTPUT="$("${MAKATO_ORCHESTRATE_SHARED}/worktree.sh" create \
          <KEY> <N> <REPO_NAME> "$BRANCH")"
      else
        # Rare: prior run never pushed the branch. Fall back to --new-branch.
        WORKTREE_OUTPUT="$("${MAKATO_ORCHESTRATE_SHARED}/worktree.sh" create --new-branch \
          <KEY> <N> <REPO_NAME> "$BRANCH")"
      fi
      WORKTREE_PATH="$(tail -1 <<<"$WORKTREE_OUTPUT")"
      ```

      **worktree.sh failure handling:** if the script is not found (non-zero exit, "not found" in stderr), log `orchestrate: WARN — worktree.sh unavailable at ${MAKATO_ORCHESTRATE_SHARED}/worktree.sh; continuing without worktree isolation` and proceed using `WORKTREE_PATH=""`. Do NOT HALT — worktree isolation is an enhancement, not a correctness prerequisite.

   d. Patch `change-state-<N>.json:.worktree_path` only if the recovered path differs from the stored one.
   e. Log `orchestrate: resume detected — recovered WORKTREE_PATH=<path>` and skip to Step 5.

   **Fresh branch** — `change-state-<N>.json` is absent or has `worktree_path:null`:

   a. **Write workflow-state stub** — create `specs/<ISSUE_KEY>/workflow-state-<N>.json` (where `<N>` = GitHub issue number extracted from `ISSUE_KEY` or fetched via `gh issue view`):

      ```json
      {
        "schema": "workflow-state",
        "version": "1.0",
        "issue_key": "<ISSUE_KEY>",
        "issue_number": 123,
        "current_phase": "in_progress",
        "plugin": "makato-change",
        "started_at": "<ISO-8601-ms>",
        "updated_at": "<ISO-8601-ms>"
      }
      ```

   b. **Write change-state file** — create `specs/<ISSUE_KEY>/change-state-<N>.json` with initial schema (see `references/autonomous-mode.md` § *Phase state file*). Set `current_phase:"analyze"`, `started_at` and `updated_at` to now.

   c. **Init worktree** (if `MAKATO_ORCHESTRATE_SHARED` is set):

      ```bash
      "${MAKATO_ORCHESTRATE_SHARED}/worktree.sh" create --new-branch <KEY> <N> <REPO_NAME> feat/<KEY>-change
      ```

      Store the returned path (`tail -1` of the output) in `change-state-<N>.json:.worktree_path` and in `WORKTREE_PATH`. If `MAKATO_ORCHESTRATE_SHARED` is unset, or if the script fails, log a warning and continue without worktree isolation.

3. **Mark In Progress on project board** — immediately before any phase dispatch:

   Read `.claude/config.json` → `github_project` block. If the block or any of `fields.status.id`, `fields.status.options.in_progress`, `project_node_id`, `host`, `owner`, `number` are missing, log `orchestrate: WARN — no github_project config; board status not updated` and continue.

   Otherwise, resolve `ITEM_ID` and current status:

   ```bash
   ITEM_LINE="$(GH_HOST="$HOST" gh project item-list "$PROJECT_NUMBER" \
     --owner "$OWNER" --format json --limit 9999 \
     --jq ".items[] | select(.content.number == $ISSUE_NUMBER)" 2>/dev/null \
     | head -1)"
   ITEM_ID="$(jq -r '.id // empty' <<<"$ITEM_LINE")"
   CUR_STATUS="$(jq -r '.status // empty' <<<"$ITEM_LINE")"
   ```

   If `ITEM_ID` is empty: log a WARN and continue.
   If `CUR_STATUS` is already `"In progress"`: log `orchestrate: #$ISSUE_NUMBER is already In Progress — skipping` and continue.
   Otherwise:

   ```bash
   GH_HOST="$HOST" gh project item-edit \
     --id "$ITEM_ID" \
     --project-id "$PROJECT_NODE_ID" \
     --field-id "$STATUS_FIELD_ID" \
     --single-select-option-id "$IN_PROGRESS_OPTION_ID"
   ```

4. **Emit run-start note** (if `MAKATO_ORCHESTRATE_SHARED` is set):

   ```bash
   "${MAKATO_ORCHESTRATE_SHARED}/progress-comment.sh" note <KEY> <N> <REPO> \
     --text "Change request run started — working through analyze → design → execute."
   ```

### Step 1: Get GitHub Issues Key

**In interactive mode:** Ask the user: **"What is the GitHub Issues issue key for this change request?"** Use `AskUserQuestion` with a text input.

**In autonomous mode:** Use the CLI argument passed to this skill. HALT with `MISSING_INPUT` if no argument was provided (handled in Step 0.5).

Store: `ISSUE_KEY`

### Step 1.5: Mark In Progress on project board (interactive mode only)

**In autonomous mode:** already done in Step 0.5. Skip.

**In interactive mode:** mark the issue as In Progress now — before phase dispatch — so the autonomous loop cannot pick up the same issue concurrently.

Fetch `ISSUE_NUMBER` from `gh issue view "$ISSUE_KEY" --json number --jq '.number'` (or parse numeric part directly if key is a plain integer).

Read `.claude/config.json` → `github_project` block. If absent, log WARN and continue. Otherwise:

```bash
ITEM_ID="$(GH_HOST="$HOST" gh project item-list "$PROJECT_NUMBER" \
  --owner "$OWNER" --format json --limit 9999 \
  --jq ".items[] | select(.content.number == $ISSUE_NUMBER) | .id" 2>/dev/null \
  | head -1)"
```

If `ITEM_ID` is non-empty, call `gh project item-edit` with the In Progress option ID. Log success or WARN on failure; never HALT.

### Step 2: Detect Current Phase

> **MANDATORY — Load `@references/phase-detection.md` at this step, every time phase detection runs.**
> **Do NOT Load** before reaching Step 2, or skip loading if `current_phase` was already restored from state in Step 0.5 and no artifact-check is needed.

Check `specs/<ISSUE_KEY>/` directory to determine workflow state.

**Spec folder shapes:** Two valid layouts exist:
- `specs/<ISSUE_KEY>/` — legacy/change path
- `specs/<N>-<slug>/` — issues seeded via `seed-issue` (e.g., `specs/233-fix-auth-bug/`)

Apply two-step resolution: prefix-match `specs/<ISSUE_KEY>-*/` first, then exact-match fallback `specs/<ISSUE_KEY>/`. If both match, use the prefix-match result.

Load `@references/phase-detection.md` for detection logic.

### Step 3: Display Phase Status

Show the user a one-line progress summary using `✓` (complete), `●` (current/recommended), `○` (not started) symbols — one line per phase. No template is mandatory; convey the four phases and their states concisely.

### Step 4: Recommend Next Action and Offer Options

State the recommendation clearly based on phase detection:

- No artifacts → **Recommend: Start with Analyze**
- Analyze complete → **Recommend: Continue to Design**
- Design complete → **Recommend: Continue to Execute**
- Execute complete + PR has comments → **Recommend: Resolve Review**
- All complete → **Workflow finished**

**Then offer options using `AskUserQuestion`** with selectable choices:

1. **[RECOMMENDED] Continue to <next phase>** (if prerequisites met)
2. Re-run a completed phase (specify which)
3. Exit workflow

**Additional options** (show conditionally):

- Skip to execute (only if analyze + design complete, warn about skipping)
- Skip to resolve-review (only if PR exists in GitHub Issues, warn about skipping)

### Step 5: Invoke Selected Skill

> **MANDATORY — Load `@references/skill-invocation-guide.md` at this step, only when dispatching a phase skill.**
> **Do NOT Load** before reaching Step 5 — it is only relevant at dispatch time.

Based on user selection (or autonomous phase recommendation), invoke the appropriate phase skill.

**Before dispatch**, narrate the START into the live issue comment (best-effort):

```bash
"${MAKATO_ORCHESTRATE_SHARED}/progress-comment.sh" start <KEY> <ISSUE_NUMBER> <REPO> \
  --skill "<skill-name>" --agent "<agent>" \
  --input "<brief description of inputs available>" \
  --goal "<goal from per-phase narration table>"
```

**In autonomous mode**, update `change-state-<N>.json` before dispatch:

- Set `current_phase` to the phase being dispatched
- Set `updated_at` to now

Re-read the current worktree path from state immediately before each phase dispatch:

```bash
REPO_ROOT="${MAKATO_TARGET_REPO_ROOT:-$(git rev-parse --show-toplevel)}"
WORKTREE_PATH="$(jq -r '.worktree_path // ""' \
  "${REPO_ROOT}/specs/<ISSUE_KEY>/change-state-<N>.json")"
```

When `WORKTREE_PATH` is non-empty, prepend this context preamble to each `Skill(...)` invocation:

```
Context:
WORKTREE_PATH=<worktree_path from change-state-<N>.json>
REPO_ROOT=<REPO_ROOT from context bundle>
ISSUE_KEY=<ISSUE_KEY>
ISSUE_NUMBER=<N>
```

**Interactive mode skill invocations** (bare names, no `makato-change:` prefix):

- Analyze → `Skill(skill="analyze", args="<ISSUE_KEY>")`
- Design → `Skill(skill="design", args="<ISSUE_KEY>")`
- Execute → `Skill(skill="execute", args="<ISSUE_KEY>")`
- Resolve Review → `Skill(skill="resolve-review", args="<ISSUE_KEY>")`

**Autonomous mode skill invocations** (append `--autonomous`; forward `WORKTREE_PATH` via context preamble):

- Analyze → `Skill(skill="analyze", args="<ISSUE_KEY> --autonomous")`
- Design → `Skill(skill="design", args="<ISSUE_KEY> --autonomous")`
- Execute → `Skill(skill="execute", args="<ISSUE_KEY> --autonomous")`
- `resolve-review` is NOT invoked in autonomous mode (see Anti-Patterns)

Wait for the skill to complete before continuing.

### Step 6: Post-Phase Check

After the invoked skill completes:

1. **Narrate DONE** (best-effort):

   ```bash
   "${MAKATO_ORCHESTRATE_SHARED}/progress-comment.sh" done <KEY> <ISSUE_NUMBER> <REPO> \
     --skill "<skill-name>" \
     --result "<completed|failed>" \
     --summary "<one sentence: what the phase produced or why it failed>"
   ```

2. Re-run phase detection (Step 2) to update progress.
3. Verify artifact boundary:
   - Analyze: `analysis.md` exists and > 100 bytes
   - Design: `design.md` exists and > 100 bytes
   - Execute: PR link exists in GitHub Issues
   - Resolve Review: no unresolved review comments remain

4. **In autonomous mode**, update `change-state-<N>.json`:

   ```bash
   PHASE_DONE="analyze"  # substitute current phase
   REPO_ROOT="${MAKATO_TARGET_REPO_ROOT:-$(git rev-parse --show-toplevel)}"
   STATE="${REPO_ROOT}/specs/<ISSUE_KEY>/change-state-<N>.json"
   jq --arg p "$PHASE_DONE" '.phases_complete += [$p] | .updated_at = (now | todate)' \
     "$STATE" > tmp.json && mv tmp.json "$STATE"

   # After execute phase, also capture the PR URL:
   PR_URL="$(gh pr list --head "$BRANCH" --repo "$REPO" --json url --jq '.[0].url' 2>/dev/null || true)"
   [ -n "$PR_URL" ] && jq --arg url "$PR_URL" '.pr_url = $url | .updated_at = (now | todate)' \
     "$STATE" > tmp.json && mv tmp.json "$STATE"
   ```

If the phase did not complete: show current state and use `AskUserQuestion` to offer retry, different phase, or exit — never auto-retry.

### Step 7: Loop or Exit

Check if all phases are complete:

- `analysis.md` exists and > 100 bytes
- `design.md` exists and > 100 bytes
- PR link found in GitHub Issues (execute complete)
- No unresolved review comments (or user confirms done)

**If all phases complete**, emit a closing note (best-effort) and show a brief summary with the PR link.

**In autonomous mode**, on all-phases-complete terminal state:

1. Patch `change-state-<N>.json:.current_phase` to `"done"` and set `updated_at`.
2. Patch `workflow-state-<N>.json:.current_phase` to `"done"` and set `updated_at`.
3. Run `${MAKATO_ORCHESTRATE_SHARED}/worktree.sh cleanup <KEY> <N>` if worktree was created (if script absent, log WARN and skip).
4. Return R1 `status:"success"` envelope with `data.current_phase:"done"`.

**On HALT in autonomous mode:**

1. Emit a closing note (best-effort): `"Run halted with <HALT_CODE> — needs human review."`
2. Patch `change-state-<N>.json:.current_phase` to `"halted"` and set `halt_code`.
3. Patch `workflow-state-<N>.json:.current_phase` to `"halted"` and set `updated_at`.
4. Run `${MAKATO_ORCHESTRATE_SHARED}/worktree.sh retain <KEY> <N> <HALT_CODE>` if worktree was created (if script absent, log WARN and skip).
5. Return R1 `status:"failure"` envelope.

**If phases remain:** re-detect (Step 2), display updated progress (Step 3), and use `AskUserQuestion` to offer:

- **[RECOMMENDED] Continue to <next phase>**
- **Re-run a phase**
- **Exit workflow**

**If continuing**: return to Step 3 and loop.

## Anti-Patterns

### NEVER use `--new-branch` when the remote branch already exists

**WHY:** `worktree.sh` hard-fails when `--new-branch` is passed for a branch already registered on the remote. The failure mode is silent enough that the session falls back to the ambient repo checkout — the skill then operates outside the isolated worktree, producing commits on the wrong branch without any HALT signal. The `ls-remote --exit-code` probe must always precede `create` to choose the correct flag.

### NEVER overwrite `change-state-<N>.json` or `workflow-state-<N>.json` on a resume run

**WHY:** The existing state file records which phases completed, the active worktree path, and the PR URL. Overwriting it resets `current_phase` to `"analyze"`, severs the link to the in-progress worktree branch, and turns the subsequent fresh `--new-branch` call into a hard-fail. Context-handoff resumes (#467) depend entirely on this file being immutable across re-dispatch.

### NEVER trigger a HALT from a progress-comment failure

**WHY:** `progress-comment.sh` is observability metadata only. A GitHub API rate-limit, transient network error, or unset `MAKATO_ORCHESTRATE_SHARED` does not invalidate any phase work. HALTing for a comment failure would stall the entire CR pipeline on infrastructure noise that has no bearing on correctness. Always log WARN and continue.

### NEVER invoke `resolve-review` in autonomous mode

**WHY:** Each PR review comment requires human judgment about whether the reviewer's concern is valid, architectural, deferrable, or out of scope. Autonomous resolution risks silently dismissing valid objections or accepting incorrect suggestions solely to unblock the pipeline. `resolve-review` is explicitly excluded from the autonomous scope in `references/autonomous-mode.md`.

### NEVER read state-file paths via CWD-relative strings in worktree contexts

**WHY:** The autonomous loop launches from repo root, but sub-shells and `cd` within phase scripts can drift CWD. A relative path like `specs/<KEY>/change-state-<N>.json` silently resolves to the wrong location after CWD drift. Anchor all state-file reads via `git rev-parse --show-toplevel` or via `REPO_ROOT` from the context bundle (see Step 5 pattern).

### NEVER prefix sibling skill invocations with `makato-change:`

**WHY:** The `Skill()` tool resolves sibling skills by bare name when called from within the same plugin. The `makato-change:` prefix adds a redundant namespace lookup that creates contradictory guidance for practitioners who also read `skill-invocation-guide.md` (which explicitly documents bare-name invocation). Use `Skill(skill="analyze")`, not `Skill(skill="makato-change:analyze")`.

### NEVER run `worktree.sh cleanup` on a HALT — always use `retain`

**WHY:** Cleanup removes the worktree and its branch from disk. On a HALT, the staged work, partial commits, and any diagnostic artifacts inside the worktree are the primary forensic record of what went wrong. Running cleanup destroys that record silently. Use `retain` with the HALT code so a human can inspect the worktree before deciding whether to preserve or discard it.

## Edge Cases

| Situation | Action |
|---|---|
| User wants to skip phases | Warn that skipped-phase artifacts won't exist; explain missing context; confirm explicitly before proceeding |
| Artifact exists but < 100 bytes | Treat as incomplete (same threshold as `references/phase-detection.md`); offer to re-run that phase; do not auto-delete |
| Multiple people on same change request | Re-detect on each orchestrate entry; show current state; no file lock — single-owner assumption |
| GitHub Issues type is not Story or Activity | Warn; offer to continue anyway; phase skills will validate and may block if truly incompatible |
| `MAKATO_ORCHESTRATE_SHARED` unset | Skip all progress-comment and worktree calls silently; workflow continues in degraded mode (no HALT) |
| Phase skill exits early without producing artifact | Show current state; use `AskUserQuestion` to offer retry, different phase, or exit — never auto-retry |
| `worktree.sh` not found or returns non-zero | Log WARN; continue without worktree isolation; set `WORKTREE_PATH=""`; never HALT |
| `specs/<N>-<slug>/` and `specs/<ISSUE_KEY>/` both match | Use prefix-match `specs/<N>-<slug>/` as the authoritative folder; log the resolution choice |
