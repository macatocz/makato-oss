---
name: orchestrate
description: Guide users through change request workflow (analyze, design, execute, resolve-review), track progress, coordinate phases
version: "1.3.0"
argument-hint: "[ISSUE-KEY] [--autonomous]"
---
# orchestrate

Guide users through the complete change request workflow by coordinating the four phases: analyze requirements, design technical approach, execute implementation, and resolve review feedback.

## When to Use

Use this skill when:

- Starting a new change request implementation
- Resuming work on an existing change request
- Unsure which phase to run next
- Want a guided workflow instead of invoking individual phase skills

**Do NOT use this skill if:**

- You already know exactly which phase skill to invoke (use that skill directly)
- You're working on something other than a change request (use makato-plan for new features; for bugs, route through makato-plan if shaping is needed or makato-build if the fix is well-scoped)

## Autonomous mode

Load @../../AUTONOMOUS-MODE.md before Step 0.5. This skill supports headless operation — see that document for activation triggers, HALT codes, and the logging contract.

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

`ISSUE_NUMBER` is the numeric GitHub issue number. `REPO` is the `<owner>/<repo>` slug of the makato repo (not the target repo). Resolve both from the `workflow-state-<N>.json` stub written in Step 0.5 or from `gh issue view <ISSUE_KEY>`.

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

**Only execute this step when autonomous mode is active (see AUTONOMOUS-MODE.md § *Activation triggers*).**

1. **Read ISSUE_KEY from CLI arg** — if the first argument is present, use it as `ISSUE_KEY`. If absent, HALT with R1 `status:"failure"` and `errors:["MISSING_INPUT: ISSUE_KEY required in autonomous mode"]`.
2. **Detect fresh vs resume run.** Check whether `specs/<ISSUE_KEY>/change-state-<N>.json` already exists **and** has a non-null `worktree_path`. This branch is load-bearing for #467: on a context-handoff resume the state file and the feature branch already exist, so re-initializing from scratch is wrong — it resets `current_phase` and hard-fails the `--new-branch` worktree create, which drops the session onto the ambient checkout.

   **Resume branch** — `change-state-<N>.json` exists with a non-null `worktree_path`:

   a. Do **NOT** overwrite `workflow-state-<N>.json` or `change-state-<N>.json`.
   b. Do **NOT** reset `current_phase` — the file already records where the run was interrupted (artifact-based phase detection in Step 2 stays authoritative).
   c. Recover `WORKTREE_PATH` using the probe-then-create pattern from `po-agent.md` Step 2b (the canonical source — never mutate a local git branch directly, #170):

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

   d. Patch `change-state-<N>.json:.worktree_path` only if the recovered path differs from the stored one (avoid an unnecessary write).
   e. Log `orchestrate: resume detected — recovered WORKTREE_PATH=<path>` and skip to Step 5.

   **Fresh branch** — `change-state-<N>.json` is absent or has `worktree_path:null`:

   a. **Write workflow-state stub** — create `specs/<ISSUE_KEY>/workflow-state-<N>.json` (where `<N>` = GitHub issue number extracted from `ISSUE_KEY` or fetched via `gh issue view`):

      ```json
      {
        "schema": "workflow-state",
        "version": "1.0",
        "issue_key": "<ISSUE_KEY>",
        "issue_number": <N>,
        "current_phase": "in_progress",
        "plugin": "makato-change",
        "started_at": "<ISO-8601-ms>",
        "updated_at": "<ISO-8601-ms>"
      }
      ```

   b. **Write change-state file** — create `specs/<ISSUE_KEY>/change-state-<N>.json` with initial schema (see AUTONOMOUS-MODE.md § *Phase state file*). Set `current_phase:"analyze"`, `started_at` and `updated_at` to now.

   c. **Init worktree** (if `MAKATO_ORCHESTRATE_SHARED` is set):

      ```bash
      "${MAKATO_ORCHESTRATE_SHARED}/worktree.sh" create --new-branch <KEY> <N> <REPO_NAME> feat/<KEY>-change
      ```

      Store the returned path (`tail -1` of the output) in `change-state-<N>.json:.worktree_path` and in `WORKTREE_PATH`. If `MAKATO_ORCHESTRATE_SHARED` is unset, log a warning and continue without worktree isolation.

5. **Mark In Progress on project board** — immediately before any phase dispatch, mark the issue as In Progress so the autonomous loop cannot pick it up concurrently.

   Determine `ISSUE_NUMBER` from the workflow-state stub (`.issue_number`).

   Read `.claude/config.json` → `github_project` block. If the block or any of `fields.status.id`, `fields.status.options.in_progress`, `project_node_id`, `host`, `owner`, `number` are missing, log `orchestrate: WARN — no github_project config; board status not updated` and continue (best-effort — never HALT).

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
   Log `orchestrate: marked #$ISSUE_NUMBER as In Progress on project board` on success; log a WARN on failure and continue.

6. **Emit run-start note** (if `MAKATO_ORCHESTRATE_SHARED` is set):

   ```bash
   "${MAKATO_ORCHESTRATE_SHARED}/progress-comment.sh" note <KEY> <N> <REPO> \
     --text "Change request run started — working through analyze → design → execute."
   ```

### Step 1: Get GitHub Issues Key

**In interactive mode:** Ask the user: **"What is the GitHub Issues issue key for this change request?"**

The key must be in format: `PROJECT-1234` (e.g., `PROJ-567`, `BDC-1234`)

**In autonomous mode:** Use the CLI argument passed to this skill. HALT with `MISSING_INPUT` if no argument was provided (handled in Step 0.5).

Store: `ISSUE_KEY`

### Step 1.5: Mark In Progress on project board (interactive mode only)

**In autonomous mode:** this was already done in Step 0.5. Skip.

**In interactive mode:** mark the issue as In Progress now — before phase dispatch — so the autonomous loop cannot pick up the same issue concurrently.

Fetch `ISSUE_NUMBER` from `gh issue view "$ISSUE_KEY" --json number --jq '.number'` (or parse numeric part directly if key is a plain integer).

Read `.claude/config.json` → `github_project` block. If absent or any of `fields.status.id`, `fields.status.options.in_progress`, `project_node_id`, `host`, `owner`, `number` are missing, log `orchestrate: WARN — no github_project config; board status not updated` and continue.

Otherwise:
```bash
ITEM_ID="$(GH_HOST="$HOST" gh project item-list "$PROJECT_NUMBER" \
  --owner "$OWNER" --format json --limit 9999 \
  --jq ".items[] | select(.content.number == $ISSUE_NUMBER) | .id" 2>/dev/null \
  | head -1)"
```
If `ITEM_ID` is non-empty:
```bash
GH_HOST="$HOST" gh project item-edit \
  --id "$ITEM_ID" \
  --project-id "$PROJECT_NODE_ID" \
  --field-id "$STATUS_FIELD_ID" \
  --single-select-option-id "$IN_PROGRESS_OPTION_ID"
```
Log `orchestrate: marked #$ISSUE_NUMBER as In Progress on project board` on success; WARN on failure and continue.

### Step 2: Detect Current Phase

Check `specs/<ISSUE_KEY>/` directory to determine workflow state.

**Spec folder shapes:** When the issue was seeded via `seed-issue` (new-work path), the folder may instead be `specs/<N>-<slug>/` where `<N>` is the issue number and `<slug>` is the normalized title (e.g. `specs/233-fix-auth-bug/`). Both shapes are valid. Check both locations when locating the spec folder — use whichever exists.

> **Spec folder shapes:** `specs/<ISSUE_KEY>/` is the legacy/change path. Issues seeded via
> `seed-issue` may use `specs/<N>-<slug>/` instead. Apply two-step resolution: prefix-match
> `specs/<ISSUE_KEY>-*/` first, then exact-match fallback `specs/<ISSUE_KEY>/`.

Load @references/phase-detection.md for detection logic.

Determine:

- Which phases are complete (artifacts exist)
- What the recommended next phase is
- Whether prerequisites are met for later phases

Store the phase status in memory.

### Step 3: Display Phase Status

Show the user a progress summary:

```
Change Request Workflow: <ISSUE_KEY>

✓ Analyze (completed)
✓ Design (completed)
○ Execute (next)
○ Resolve Review (not started)
```

Use:

- ✓ for completed phases
- ● for current/recommended phase
- ○ for not-yet-started phases

### Step 4: Recommend Next Action and Offer Options

**First, state the recommendation clearly:**

Based on phase detection from Step 2, determine the recommended next phase:

- No artifacts → **Recommend: Start with Analyze**
- Analyze complete → **Recommend: Continue to Design**
- Design complete → **Recommend: Continue to Execute**
- Execute complete + PR has comments → **Recommend: Resolve Review**
- All complete → **Workflow finished**

**Present recommendation to user:**

```
🎯 Recommended Next Step: <Phase Name>

<One-sentence explanation of what this phase will do>
```

**Then offer options using `AskUserQuestion`:**

**Primary options** (always show):

1. **[RECOMMENDED] Continue to <next phase></next>** (if prerequisites met)
2. Re-run a completed phase (specify which)
3. Exit workflow

**Additional options** (show conditionally):

- Skip to execute (only if analyze + design complete, warn about skipping)
- Skip to resolve-review (only if PR exists in GitHub Issues, warn about skipping)

For each option, show:

- What will happen
- Whether prerequisites are met
- Warning if action might overwrite existing work

### Step 5: Invoke Selected Skill

Based on user selection (or autonomous phase recommendation), invoke the appropriate phase skill:

Load @references/skill-invocation-guide.md for invocation patterns.

**Before dispatch**, narrate the START into the live issue comment (best-effort — see § *Progress comment*):

```bash
"${MAKATO_ORCHESTRATE_SHARED}/progress-comment.sh" start <KEY> <ISSUE_NUMBER> <REPO> \
  --skill "<skill-name>" --agent "<agent>" \
  --input "<brief description of inputs available>" \
  --goal "<goal from per-phase narration table>"
```

Use the row for the dispatched phase from the narration table in § *Progress comment*.

**In autonomous mode**, update `change-state-<N>.json` before dispatch:

- Set `current_phase` to the phase being dispatched
- Set `updated_at` to now

**In interactive mode**, use the `Skill` tool to invoke:

- Analyze → `Skill(skill="makato-change:analyze", args="<ISSUE_KEY>")`
- Design → `Skill(skill="makato-change:design", args="<ISSUE_KEY>")`
- Execute → `Skill(skill="makato-change:execute", args="<ISSUE_KEY>")`
- Resolve Review → `Skill(skill="makato-change:resolve-review", args="<ISSUE_KEY>")`

**In autonomous mode**, append `--autonomous` and forward `WORKTREE_PATH` to every phase so the phase skills operate inside the isolated worktree rather than the ambient checkout (#467).

Immediately before each phase dispatch, re-read the current worktree path from state (it may have been set by Step 0.5's fresh branch or recovered by its resume branch):

```bash
WORKTREE_PATH="$(jq -r '.worktree_path // ""' "specs/<ISSUE_KEY>/change-state-<N>.json")"
```

When `WORKTREE_PATH` is non-empty, prepend this context preamble to each `Skill(...)` invocation so the phase skill can locate the worktree:

```
Context:
WORKTREE_PATH=<worktree_path from change-state-<N>.json>
REPO_ROOT=<REPO_ROOT from context bundle>
ISSUE_KEY=<ISSUE_KEY>
ISSUE_NUMBER=<N>
```

- Analyze → `Skill(skill="makato-change:analyze", args="<ISSUE_KEY> --autonomous")`
- Design → `Skill(skill="makato-change:design", args="<ISSUE_KEY> --autonomous")`
- Execute → `Skill(skill="makato-change:execute", args="<ISSUE_KEY> --autonomous")`
- `resolve-review` is NOT invoked in autonomous mode (see AUTONOMOUS-MODE.md § *Skills NOT in scope*)

Wait for the skill to complete before continuing.

### Step 6: Post-Phase Check

After the invoked skill completes:

1. **Narrate DONE** into the live issue comment (best-effort — see § *Progress comment*):

   ```bash
   "${MAKATO_ORCHESTRATE_SHARED}/progress-comment.sh" done <KEY> <ISSUE_NUMBER> <REPO> \
     --skill "<skill-name>" \
     --result "<completed|failed>" \
     --summary "<one sentence: what the phase produced or why it failed>"
   ```

2. Re-run phase detection (Step 2) to update progress
3. Check if the phase actually completed:

   - Analyze: `analysis.md` should exist
   - Design: `design.md` should exist
   - Execute: PR link should exist in GitHub Issues
   - Resolve Review: verify comments were addressed
4. **In autonomous mode**, after each phase completes, append the phase name to `phases_complete[]` in `change-state-<N>.json` and set `updated_at`. After the execute phase completes and a PR was created, also write the PR URL to `pr_url` in `change-state-<N>.json`:

   ```bash
   # After each phase completes (e.g., "analyze"):
   PHASE_DONE="analyze"
   jq --arg p "$PHASE_DONE" '.phases_complete += [$p] | .updated_at = (now | todate)' \
     change-state-<N>.json > tmp.json && mv tmp.json change-state-<N>.json

   # After execute phase, also capture the PR URL:
   PR_URL="$(gh pr list --head "$BRANCH" --repo "$REPO" --json url --jq '.[0].url' 2>/dev/null || true)"
   [ -n "$PR_URL" ] && jq --arg url "$PR_URL" '.pr_url = $url | .updated_at = (now | todate)' \
     change-state-<N>.json > tmp.json && mv tmp.json change-state-<N>.json
   ```

If the phase did not complete (user exited early or error occurred):

- Show current state
- Ask if user wants to retry or move to a different phase

### Step 7: Loop or Exit

Check if all phases are complete:

- Analyze artifact exists
- Design artifact exists
- Execute complete (PR link in GitHub Issues)
- Resolve Review complete (no unresolved comments, or user confirms done)

**If all phases complete**: Auto-exit with final summary. Emit a closing note (best-effort):

```bash
"${MAKATO_ORCHESTRATE_SHARED}/progress-comment.sh" note <KEY> <ISSUE_NUMBER> <REPO> \
  --text "All phases complete — PR is open and ready for review."
```

Then show the user:

```
✅ Change Request Workflow Complete: <ISSUE_KEY>

✓ All phases finished
PR: <link>

Next:
- Monitor PR for approval
- Merge when approved
```

**In autonomous mode**, on all-phases-complete terminal state:

1. Patch `change-state-<N>.json:.current_phase` to `"done"` and set `updated_at`.
2. Patch `workflow-state-<N>.json:.current_phase` to `"done"` and set `updated_at`.
3. Run `${MAKATO_ORCHESTRATE_SHARED}/worktree.sh cleanup <KEY> <N>` if worktree was created.
4. Return R1 `status:"success"` envelope with `data.current_phase:"done"`.

**On HALT in autonomous mode:**

1. Emit a closing note (best-effort):

   ```bash
   "${MAKATO_ORCHESTRATE_SHARED}/progress-comment.sh" note <KEY> <ISSUE_NUMBER> <REPO> \
     --text "Run halted with <HALT_CODE> — needs human review."
   ```

2. Patch `change-state-<N>.json:.current_phase` to `"halted"` and set `halt_code`.
3. Patch `workflow-state-<N>.json:.current_phase` to `"halted"` and set `updated_at`.
4. Run `${MAKATO_ORCHESTRATE_SHARED}/worktree.sh retain <KEY> <N> <HALT_CODE>` if worktree was created.
5. Return R1 `status:"failure"` envelope.

**If phases remain**: Re-detect current state (Step 2) and present recommendation:

```
🎯 Recommended Next Step: <Phase Name>

<One-sentence explanation>
```

Then ask the user: **"What would you like to do next?"**

Options:

1. **[RECOMMENDED] Continue to <next phase></next>** (show which phase is next)
2. **Re-run a phase** (specify which)
3. **Exit workflow**

**If continuing**: Return to Step 3 (display updated status) and loop.

**If exiting before completion**: Present status summary:

```
Change Request Workflow: <ISSUE_KEY>

Current Progress:
✓ Analyze (completed)
✓ Design (completed)
✓ Execute (completed)
○ Resolve Review (not started)

Next Steps:
- Wait for PR review feedback
- Invoke /makato-change:orchestrate again when ready to resolve review comments
```

## Edge Cases

**User wants to skip phases:**

- Warn that artifacts from skipped phases won't exist
- Explain what information will be missing
- Offer to run the prerequisite phase first
- Only allow skip if user explicitly confirms

**Artifacts exist but are incomplete/corrupt:**

- Detect by checking file size or key sections
- Offer to re-run that phase
- Don't auto-delete — let user decide

**Multiple people working on same change request:**

- The orchestrator doesn't lock — assumes one person at a time
- If artifacts change unexpectedly, re-detect and show updated state
- User can see what's been done and pick up where previous person left off

**GitHub Issues issue type is not Story or Activity:**

- Warn the user
- Offer to continue anyway (some orgs use custom types)
- Phase skills will validate and may block if truly incompatible

**`MAKATO_ORCHESTRATE_SHARED` is unset:**

- All progress-comment calls are skipped silently
- Workflow proceeds without narration (degraded mode — no HALT)
