---
name: build-address-pr-comments
description: >-
  Classify and resolve all PR comments — human reviewer feedback and
  automated bot findings (CI failures, lint bots, security scanners,
  Hyperspace). Classifies each as MUST-FIX / SHOULD-FIX / CONSIDER /
  OUT-OF-SCOPE, presents classification for approval, implements fixes
  grouped by file, commits and pushes, replies to each resolved comment.
  Structural feedback escalates to refine. Headless-safe under --autonomous
  (MUST-FIX auto-apply, SHOULD-FIX scope-guarded, STRUCTURAL HALT-003,
  OUT-OF-SCOPE carry-over issue). Review-feedback promotion — codifies recurring
  MUST-FIX categories as permanent pre-commit checks (Step 5a + Step 6a).
  Interactive by default. Use after create-pr when review comments arrive.
version: "1.6.0"
argument-hint: "[work-item-key] [--autonomous]"
allowed-tools: ["Bash", "Read", "Edit", "Write"]
---

## Classification Decision Framework

Before executing steps, internalise this decision hierarchy — it governs every non-obvious call:

**Tier assignment precedence (highest to lowest):**
1. SENSOR-BOT detection — checked first, unconditionally. If the author login matches the bot regex and the body is parseable as `tool:rule:path:line` findings, the tier is locked; no other classifier runs.
2. STRUCTURAL flag — a MUST-FIX that requires changing the fundamental implementation approach (data model redesign, API contract reversal, algorithm replacement). STRUCTURAL is a modifier on MUST-FIX, not a separate tier. Even a single STRUCTURAL item triggers HALT-003 in autonomous mode.
3. SHOULD-FIX scope guard — the critical autonomous decision: is *every* file the comment touches already inside the task's diff? If any file is outside `plan.md` `task[].Files[]`, the comment is DEFERRED regardless of how valuable the fix is. This is a hard boundary, not a judgment call.
4. MUST-FIX vs SHOULD-FIX vs CONSIDER — driven by the classification guide. When in doubt: source heuristic sets the default, comment content overrides it.

**The STRUCTURAL decision is the highest-consequence call in this skill.** When uncertain whether a MUST-FIX is STRUCTURAL, default to STRUCTURAL — a spurious HALT-003 is recoverable; silently implementing a broken architecture compounds debt.

## When to Use

Use after `/create-pr` when review comments have arrived on the PR. Handles all unresolved comments — human reviewer feedback, CI bot failures, security scanner findings, lint bots, and automated review tools. May run multiple times across review rounds.

## Input

When dispatched by the PO-agent (`--autonomous` mode):

- `<work-item-key>` — positional argument.
- `WORKTREE_PATH` — absolute filesystem path to the per-run git worktree. **Mandatory in autonomous mode** (see `plugins/makato-build/AUTONOMOUS-MODE.md` § *WORKTREE_PATH — workspace-isolation contract*). `gh pr` calls and per-comment fix applies operate from `WORKTREE_PATH` so commits land on the right branch.
- `--autonomous` — activation flag.

Interactive mode: `WORKTREE_PATH` is optional; fall back to `git rev-parse --show-toplevel` of the current `$PWD`.

### Workspace-isolation entry guard

Apply the workspace-isolation entry guard from `@../../AUTONOMOUS-MODE.md` § *WORKTREE_PATH — workspace-isolation contract* and § *Falsy-check pattern* before Step 1. In autonomous mode an empty `WORKTREE_PATH` is a HALT with `errors: ["MISSING_INPUT: WORKTREE_PATH required in autonomous mode"]`; in interactive mode the guard falls back to `git rev-parse --show-toplevel`. After resolution, `cd "$WORKTREE_PATH"`.

Spec-artefact reads use `$REPO_ROOT/specs/<key>-*/`:

```bash
REPO_ROOT="$(cd "$(git -C "$WORKTREE_PATH" rev-parse --git-common-dir)/.." && pwd)"
```

## Workflow

### Step 1 — Ask for work item key and PR URL

Ask: *"Which work item and PR are we addressing? (e.g. #123, or pass it directly: `/makato-build:build-address-pr-comments #123`)"* — or use the passed argument.

If only a key is given, derive the PR URL:
```
gh pr list --head $(git branch --show-current) --json url -q '.[0].url'
```

Run `git branch --show-current` to confirm we are on the story branch. If on `main` or `master`, stop — fixes must go on the feature branch.

### Step 1a — Mode detection

**MANDATORY: Load `@../../AUTONOMOUS-MODE.md`** at this step and no later — it defines the activation contract (§ *Activation triggers*) and the per-gate default table. Do NOT load it before Step 1a; you do not need it during fetch or workspace setup. Do NOT load it again later in the workflow — it is session-global once loaded here.

In autonomous mode, the Step 1 work-item-key prompt is replaced by:
- If an argument was passed: use it.
- If no argument: HALT with `MISSING_INPUT: build-address-pr-comments in --autonomous mode requires a work-item-key argument`, write `{step:"session", status:"error", data:{halt_code:"MISSING_INPUT"}}`, and return R1 `status:"failure"`.

Log the bypass via `shared/log-bypass.sh build-address-pr-comments "<key>" work-item-key use-arg "<agent_id|cli_flag|task_id_bundle>"` when bypassed.

---

### Step 2 — Log session start

Run:

```bash
shared/build-log.sh "<key>" '{"ts":"<ISO8601>","skill":"build-address-pr-comments","story":"<key>","step":"session","status":"start","data":{"pr_url":"<url>"}}'
```

---

### Step 3 — Fetch all PR comments

Run:
```
gh pr view <url> --comments --json reviews,comments
```

Include all unresolved comments regardless of source — human reviewers, CI bots, security scanners, lint tools, and automated review tools (Hyperspace, Renovate, Dependabot, etc.).

Exclude only comments already marked as resolved in the PR review thread.

Note the author type for each comment (human vs bot) — this informs the classification default in Step 4 but does not exclude anything.

If there are no unresolved comments: tell the user and stop.

---

### Step 4 — Classify each comment

**MANDATORY: Load `@references/comment-classification-guide.md`** at this step. Do NOT load it earlier (you need the full comment list from Step 3 to apply the heuristics). Do NOT skip it for "obvious" MUST-FIX items — the guide owns the SENSOR-BOT regex and sub-type enum that Steps 5b and 6a depend on. Assign each unresolved comment a tier: **SENSOR-BOT**, **MUST-FIX**, **SHOULD-FIX**, **CONSIDER**, or **OUT-OF-SCOPE**. SENSOR-BOT is checked first. Use the source heuristics and classification rules from the guide; content of the comment overrides the source heuristic.

**SENSOR-BOT detection (checked before all other tiers):**
If `comment.author` (login or app name) matches `(?i)(ruff|pyright|bandit|biome|sqlfluff|markdownlint|semgrep|trivy|gitleaks|hyperspace-bot)`:
- Attempt to parse comment body for one or more `tool:rule:path:line` finding shapes.
- If ≥ 1 finding parseable → classify as **SENSOR-BOT** and skip further tier evaluation for this comment.
- If not parseable → fall through to MUST-FIX tier evaluation (existing path).

For any MUST-FIX: check whether it requires changing the fundamental implementation approach (data model redesign, API contract reversal, algorithm replacement). If yes, flag it as **STRUCTURAL**.

---

### Step 5 — Present classification for approval

In **interactive mode**, present the full classification table to the user:

```
[SENSOR-BOT]   ruff-bot (PR comment)    — "ruff:E501:src/foo.py:42: line too long"
[MUST-FIX]     src/Invoice.java:42      — "status field must be non-null"
[MUST-FIX]     CI: build failure        — "cannot find symbol OrderStatus"
[SHOULD-FIX]   src/InvoiceService.java  — lint: "method too long (87 lines)"
[CONSIDER]     Hyperspace               — "consider extracting a helper here"
[OUT-OF-SCOPE] human reviewer           — "add audit logging to all endpoints"
```

If any STRUCTURAL comment was found, present it clearly and define the flow:

> "This MUST-FIX requires changing the implementation approach. Recommended handling:
>
> **(A) Pause on structural item, continue non-structural** — address all non-structural MUST-FIX and SHOULD-FIX comments now. After the non-structural pass is complete, open a new `/build-refine` session to re-plan the structural change.
> **(B) Stop entirely** — address the structural change before any other comments.
> **(C) Override** — treat as a regular MUST-FIX and implement inline (only if you are confident the structural concern can be resolved without a new plan)."

Wait for the user to choose. If (A): continue implementing non-structural comments in this session; after the commit-and-push step, prompt the user: "Structural item outstanding — ready to open `/build-refine` for re-planning?" If (B): stop here. If (C): proceed as a regular MUST-FIX.

Wait for the user to confirm or adjust classifications. User can: promote/demote tiers, mark a SHOULD-FIX as skip with a reason, or override the STRUCTURAL call.

In **autonomous mode**, skip the interactive prompts and apply this fixed policy:

- **SENSOR-BOT** — delegate to `sensor-fixer`: parse the comment body for `tool:rule:path:line` findings (already parsed in Step 4), emit a `sensor-delegated` row to `specs/<key>-*/build.jsonl` (`{"ts":"<ISO>","skill":"build-address-pr-comments","step":"fix","action":"sensor-delegated","key":"<key>","dispatched_by":"build-address-pr-comments","comment_id":"<id>"}`), dispatch `sensor-fixer(REPO_ROOT, FINDINGS=[parsed], SPEC_KEY=<key>)`. On R1 `failure`, revert to MUST-FIX tier and re-apply via Step 6. Log bypass: `shared/log-bypass.sh build-address-pr-comments "<key>" sensor-bot-classification delegate "<agent_id|cli_flag|task_id_bundle>"`.
- **MUST-FIX (non-STRUCTURAL)** — auto-apply in Step 6. Logged as `autonomous_bypass` with `gate: "comment-classification"`, `default_taken: "auto-apply"` (AC1).
- **SHOULD-FIX** — apply ONLY if every file the comment touches is already inside this task's diff scope (the file list captured by Step 3 of the most recent `build-implement-tdd` / `build-implement-goal` session, recoverable from `specs/<key>-<slug>/plan.md` `task[].Files[]`). If any touched file is outside that set, the comment is marked **DEFERRED**: the skill does NOT implement it, posts a `[DEFERRED]` reply (template `pr-comment-replies.md` § *SHOULD-FIX (deferred — autonomous-only)*), and logs `autonomous_bypass` with `gate: "should-fix-scope-guard"`, `default_taken: "defer"`, and `data.comment_id` + `data.out_of_scope_files[]`. The PO-agent reads the R1 envelope and decides whether to open a follow-up issue (AC2).
- **CONSIDER** — skip (do not implement). Reply with `pr-comment-replies.md` § *CONSIDER (deferred — interactive choice)* autonomous variant.
- **OUT-OF-SCOPE** — skip implementation, then **open a follow-up GitHub issue** via `gh issue create` with the comment text as the issue body, applying the `makato-carry-over` label (label is auto-created with `gh label create` if missing — non-destructive, no-op on existing). Post the reply using `pr-comment-replies.md` § *OUT-OF-SCOPE* autonomous variant with the new issue URL substituted in. Log `autonomous_bypass` with `gate: "out-of-scope-carry-over"`, `default_taken: "open-followup-issue"`, `data.follow_up_issue: "<url>"`, `data.comment_id`. If `gh issue create` fails, HALT with `HALT-005` rather than posting a half-rendered reply (AC4).
- **MUST-FIX flagged STRUCTURAL** — do NOT auto-apply. Apply the AC3 flow described in *§ Step 5a — STRUCTURAL HALT-003 (autonomous only)* below.

Log the bypass via `shared/log-bypass.sh build-address-pr-comments "<key>" comment-classification auto-apply "<agent_id|cli_flag|task_id_bundle>" '{"counts":{"must_fix":<N>,"should_fix":<N>,"should_fix_deferred":<N>,"consider":<N>,"out_of_scope":<N>,"structural":<N>}}'`.

The per-finding `autonomous_bypass` entries for `should-fix-scope-guard` and `out-of-scope-carry-over` are written from Step 6 (when each finding is acted on), not aggregated in Step 5 — operators reading `build.jsonl` need the finding-level granularity to reconstruct each decision (AC1, AGENTS.md Design Principle 4).

---

### Step 5a — STRUCTURAL HALT-003 (autonomous only)

This step fires once per autonomous session when Step 4 flagged one or more MUST-FIX comments as **STRUCTURAL**. The order is mandatory: post-reply → label → log → HALT. Each sub-step is best-effort isolated so a single failure (e.g. summary reply 502) does not block the HALT itself.

1. **Post a summary reply on the PR.** Render `pr-comment-replies.md` § *STRUCTURAL MUST-FIX (autonomous HALT — AC3)* with the list of comment-summaries (first 80 chars of each STRUCTURAL comment body, newlines collapsed). Use `gh pr comment <pr-number> --body "<rendered>"` for the general PR comment. If the call fails, log `data.event: "summary_reply_failed"` and continue — the HALT must still complete.
2. **Apply `needs-human-review`** to the PR and the linked issue:

   ```bash
   gh pr edit "$PR_NUMBER" --add-label needs-human-review
   gh issue edit "$ISSUE_NUMBER" --add-label needs-human-review
   ```

   The label is created on demand if absent (`gh label create needs-human-review --color FBCA04 --description "Autonomous run halted; operator action required"`). `$ISSUE_NUMBER` is read from `workflow-state.json` (`issue_number`); if missing, only the PR is labelled and `data.event: "missing_issue_number"` is logged.
3. **Log a STRUCTURAL decision entry** per STRUCTURAL comment plus a single summary entry. Per-comment: `shared/log-bypass.sh build-address-pr-comments "<key>" structural-must-fix halt "<agent_id|cli_flag|task_id_bundle>" '{"comment_id":"<id>","summary":"<comment-summary>"}'`. Summary: `shared/log-bypass.sh build-address-pr-comments "<key>" structural-halt-summary halt "<agent_id|cli_flag|task_id_bundle>" '{"count":<N>}'`.
4. **Exit with `HALT-003`.** Return R1 `status: "failure"` with `errors: ["STRUCTURAL_BLOCKER: <first comment-summary>"]` and `data.halt_code: "HALT-003"` plus `data.structural_blockers: <N>`. The PO-agent reads the R1 envelope; the `halt_audit[]` entry is written by the PO-agent per `plugins/makato-orchestrate/agents/po-agent.md` § *Label application* — but in this case the label has already been applied at sub-step 2, so the PO-agent's idempotent `gh issue edit --add-label` is a no-op (AGENTS.md Design Principle 1 — single source of truth is preserved because the label set is, not the writer count).

This step is **autonomous-only**. Interactive STRUCTURAL handling stays in Step 5's user-choice flow (A/B/C above) and never auto-applies the label.

---

### Step 5b — Write category lesson (review-feedback promotion)

**Applies to every resolved MUST-FIX comment (non-STRUCTURAL).**

Named constants:
- `RECURRENCE_THRESHOLD = 2` — minimum prior occurrences before proposing a harness rule

Category enum (from `comment-classification-guide.md` MUST-FIX sub-types):

| Category key | MUST-FIX sub-type |
|---|---|
| `correctness` | Correctness bug |
| `security` | Security issue |
| `broken-contract` | Broken contract |
| `ci-failure` | CI / build failure |
| `scanner-finding` | Security scanner finding |
| `reviewer-blocked` | Reviewer-explicit blocker |

For each resolved MUST-FIX comment (derived from Step 4 classification):

1. Derive `CATEGORY` from the sub-type enum above.
2. Write a generalizable procedural lesson record:

```bash
plugins/makato-build/shared/write-lessons.sh \
  "$KEY" "procedural" "generalizable" \
  "MUST-FIX resolved: $CATEGORY in PR review" \
  "must-fix,category:$CATEGORY"
```

3. On exit-code 0: log to `build.jsonl`: `{"step":"step-5b","status":"ok","data":{"category":"$CATEGORY"}}`.
4. On any failure: log `{"step":"step-5b","status":"warn","data":{"category":"$CATEGORY","error":"write-lessons failed"}}` and continue — never HALT.

This step runs in both interactive and autonomous mode without a gate bypass (the write is unconditional).

---

### Step 6 — Implement fixes

Implement in order: SENSOR-BOT first (sensor-fixer delegation), then MUST-FIX, then SHOULD-FIX, then approved CONSIDER items.

Group fixes by file — apply all changes to the same file in one pass to avoid partial edits. After all fixes to a file are applied, verify the file compiles (or passes a quick type-check if possible).

Do not implement OUT-OF-SCOPE items or unapproved CONSIDER items. Do not skip any MUST-FIX or approved SHOULD-FIX.

In **autonomous mode**, additional per-finding actions fire here (the Step 5 policy decides what; Step 6 executes it):

- **SHOULD-FIX scope guard.** Before implementing each SHOULD-FIX, compute `out_of_scope_files = comment.files - task.Files` (set difference against the task diff captured in `plan.md`). If non-empty, skip implementation, mark the comment DEFERRED, post the `[DEFERRED]` reply (template § *SHOULD-FIX (deferred — autonomous-only)*) in Step 9, and log:

  ```bash
  shared/log-bypass.sh build-address-pr-comments "<key>" should-fix-scope-guard defer "<agent_id|cli_flag|task_id_bundle>" \
    '{"comment_id":"<id>","out_of_scope_files":["<path>","..."]}'
  ```
- **OUT-OF-SCOPE carry-over.** For each OUT-OF-SCOPE comment, open a follow-up issue:

  ```bash
  # Ensure label exists (idempotent — gh label create is no-op on existing)
  gh label list --repo "$TARGET_REPO" --json name --jq '.[].name' | grep -qx makato-carry-over \
    || gh label create makato-carry-over --color D4C5F9 \
         --description "Out-of-scope PR comment carried over for separate tracking (build-address-pr-comments)" \
         --repo "$TARGET_REPO"

  FOLLOWUP_URL="$(gh issue create \
    --repo "$TARGET_REPO" \
    --title "Carry-over from PR review: <one-line gloss>" \
    --label makato-carry-over \
    --body "Carried over from <pr-url> — comment by @<author>:

    > <original comment body, blockquoted>

    Filed automatically by \`build-address-pr-comments\` in --autonomous mode for <key>.")"
  ```

  Use `$FOLLOWUP_URL` to render the `[OUT-OF-SCOPE]` reply (template § *OUT-OF-SCOPE* autonomous variant) in Step 9. Log:

  ```bash
  shared/log-bypass.sh build-address-pr-comments "<key>" out-of-scope-carry-over open-followup-issue "<agent_id|cli_flag|task_id_bundle>" \
    '{"comment_id":"<id>","follow_up_issue":"<url>"}'
  ```

  If `gh issue create` exits non-zero, HALT immediately with `HALT-005` (`PUSH_REJECTED` is reused for any non-fatal `gh`-write failure to keep the HALT taxonomy bounded; the error string disambiguates: `CARRY_OVER_FAILED: <comment_id>`). Do NOT post a partially-rendered reply.

Log each fix:

```
{"ts":"<ISO8601>","skill":"build-address-pr-comments","story":"<key>","step":"fix","status":"ok","data":{"tier":"MUST-FIX","file":"src/Invoice.java","comment_id":"<id>"}}
```

---

### Step 6a — Recurrence check and harness promotion

Runs once per PR run after all fixes are committed and pushed (Step 6), before verify gates (Step 7). De-duplicates by category within the run.

```bash
RECURRENCE_THRESHOLD=2
REPO="$(git remote get-url origin | sed 's/\.git$//')"
```

For each unique resolved MUST-FIX category in this run:

**1. Query prior occurrences:**

```bash
PRIOR=0
if [ -f "$REPO_ROOT/.makato/memory/procedural.jsonl" ]; then
  PRIOR=$(jq -c --arg repo "$REPO" --arg cat "category:$CATEGORY" \
    'select(.repo == $repo and (.tags // [] | contains([$cat])))' \
    "$REPO_ROOT/.makato/memory/procedural.jsonl" 2>/dev/null | wc -l)
else
  shared/build-log.sh "$KEY" \
    "{\"step\":\"step-6a\",\"status\":\"warn\",\"data\":{\"msg\":\"procedural.jsonl absent — PRIOR=0\",\"category\":\"$CATEGORY\"}}"
fi
```

**2. Recurrence gate:**

If `PRIOR < RECURRENCE_THRESHOLD`: log `{"step":"step-6a","status":"ok","data":{"category":"$CATEGORY","prior":$PRIOR,"promoted":false}}` and skip to next category.

**3. Dedup check:**

```bash
EXISTING=$(gh issue list --repo "$REPO" \
  --label "type:harness" --state open \
  --search "pre-commit promotion: $CATEGORY" \
  --json number --jq length 2>/dev/null || echo 0)
```

If `EXISTING > 0`: log `{"step":"step-6a","status":"warn","data":{"category":"$CATEGORY","skipped_dedup":true}}` and skip to next category.

**4. Stanza lookup (static table):**

| Category | Candidate stanza |
|---|---|
| `correctness` | `ruff` hook (ruff-pre-commit, `ruff check`) |
| `security` | `bandit` hook (PyCQA/bandit, `-r .`) |
| `broken-contract` | `pyright` hook (RobertCraigie/pyright-pre-commit) |
| `ci-failure` | `pytest` hook (local, `pytest --tb=short`) |
| `scanner-finding` | `gitleaks` hook (gitleaks, `protect`) |
| `reviewer-blocked` | `markdownlint` hook (igorshubovych/markdownlint-cli) |

If category not in table: use placeholder stanza `# TODO: add pre-commit rule for <CATEGORY>`.

**5. Open harness issue:**

```bash
HARNESS_URL="$(gh issue create \
  --repo "$REPO" \
  --title "pre-commit promotion: $CATEGORY" \
  --label "type:harness,makato" \
  --body "## Review-feedback promotion

**Category**: $CATEGORY
**Prior occurrences**: $PRIOR

This category has appeared in >=$RECURRENCE_THRESHOLD PR reviews. Candidate pre-commit stanza:

\`\`\`yaml
$STANZA
\`\`\`" 2>/dev/null)"
```

On failure: log `{"step":"step-6a","status":"warn","data":{"halt_token":"HARNESS_ISSUE_FAILED: $CATEGORY"}}` and continue (soft-warn — does NOT block). Do NOT post a reply.
On success: record `HARNESS_URL`.

**6. Post reply** on the triggering MUST-FIX comment thread using the `[HARNESS-PROPOSED]` template section (see `@../../templates/pr-comment-replies.md`), substituting `<harness-issue>` = `$HARNESS_URL` and `<proposed-rule>` = `$CATEGORY`.

**7. Log bypass (autonomous mode only):**

```bash
shared/log-bypass.sh build-address-pr-comments "$KEY" recurring-pattern-check \
  open-harness-issue "$TRIGGER" \
  "{\"category\":\"$CATEGORY\",\"prior\":$PRIOR,\"harness_url\":\"$HARNESS_URL\"}"
```

---

### Step 7 — Re-run verify gates

Run the project's build and unit test suite to confirm fixes did not break anything:
- **Build** (compile / type-check) — must pass
- **Unit tests** — zero new failures vs. pre-session baseline

On failure: classify.
- **Fixable** → fix and re-run from BUILD
- **Structural** → stop, report, recommend `/refine`

Full integration test suite is optional here — defer to the CI run triggered by the push unless the fixes touched integration-boundary code.

---

### Step 8 — Commit and push fixes

Stage and commit the fixes. Commit message:
```
fix(<scope>): address PR review feedback for <key>
```

If fixes span multiple logical themes (e.g. a CI build fix plus several readability fixes), use multiple commits — one per group.

In **interactive mode**, show the user the staged diff and ask: *"Ready to push `<N>` fix commits to `origin/<branch>`?"* Wait for confirmation before pushing. Run `git push` on approval.

In **autonomous mode**, skip the prompt: run `git push` immediately (pre-push hook still fires per the cross-skill propagation rule in `@../../AUTONOMOUS-MODE.md`). Log `shared/log-bypass.sh build-address-pr-comments "<key>" push-fix-confirm push "<agent_id|cli_flag|task_id_bundle>"`.

---

### Step 9 — Reply to PR comments

For each addressed comment, prefer `mcp__github-tools__add_reply_to_pull_request_comment` when the `github-tools` MCP is configured — it requires only the comment ID and body.

If the `github-tools` MCP is not available, fall back to `gh api`:

```bash
# Reply to a review comment
gh api repos/{owner}/{repo}/pulls/comments/{comment_id}/replies \
  -X POST -f body="<reply text>"

# Post a general review comment batch
gh pr review <pr-number> --comment -b "<reply text>"
```

**Reply text is rendered from `@../../templates/pr-comment-replies.md`** — **MANDATORY: load this file at Step 9 and only at Step 9** (earlier loading wastes context; later loading causes unsubstituted placeholder renders). Do NOT load it during Step 5 or Step 6 — the tier decisions happen before rendering. One section per classification tier plus three autonomous-only sections (DEFERRED, OUT-OF-SCOPE autonomous, STRUCTURAL). The skill MUST load that file and substitute placeholders (`<commit-sha>`, `<fix-summary>`, `<reason>`, `<follow-up-issue>`, `<comment-summary>`) at render time. Hard-coded prose in this skill is a contract violation (AC5).

Tier → template section mapping:

| Tier (mode) | Template section |
|---|---|
| SENSOR-BOT (delegated to sensor-fixer) | § *SENSOR-BOT (delegated)* — reply: "Delegated to sensor-fixer. Applied Phase 0 autofix for `<tool>:<rule>`. See `build.jsonl` for audit trail." |
| MUST-FIX (implemented) | § *MUST-FIX (applied)* (autonomous variant in autonomous mode) |
| SHOULD-FIX (implemented) | § *SHOULD-FIX (applied)* |
| SHOULD-FIX (deferred — autonomous only) | § *SHOULD-FIX (deferred — autonomous-only)* |
| CONSIDER (implemented in interactive) | § *CONSIDER (implemented)* |
| CONSIDER (deferred) | § *CONSIDER (deferred — interactive choice)* (autonomous variant for fixed policy) |
| OUT-OF-SCOPE (interactive) | § *OUT-OF-SCOPE* interactive variant |
| OUT-OF-SCOPE (autonomous) | § *OUT-OF-SCOPE* autonomous variant (with `<follow-up-issue>` URL from Step 6) |
| STRUCTURAL (autonomous HALT) | § *STRUCTURAL MUST-FIX (autonomous HALT — AC3)* — posted in Step 5a, NOT here |

Keep replies factual and brief. Quote the original comment only if needed for clarity. A reply MUST NOT contain an unsubstituted `<placeholder>` — if a placeholder cannot be filled, the skill HALTs (`HALT-005` with error `RENDER_FAILED: <comment_id>`) rather than posting a half-rendered reply.

---

### Step 10 — Log session end and hand off

Run:

```bash
shared/build-log.sh "<key>" '{"ts":"<ISO8601>","skill":"build-address-pr-comments","story":"<key>","step":"session","status":"ok","data":{"must_fix":<N>,"should_fix":<N>,"consider":<N>,"out_of_scope":<N>,"commits":<N>}}'
```

Tell the user: *"`<N>` comments addressed, `<N>` commits pushed. PR is ready for re-review."*

## Anti-patterns

Each item below captures a failure mode that experience (not documentation) teaches.

**NEVER implement a fix on `main` or `master`.**
WHY: `git push` from the main branch overwrites the protected default branch without a PR review. The guard at Step 1 (`git branch --show-current`) catches this, but if skipped — e.g. in a one-off "just fix it" interactive run — the result is unreviewed code on the release branch with no audit trail.

**NEVER implement a SHOULD-FIX that touches files outside the current task diff (autonomous mode).**
WHY: the scope guard exists because `plan.md Files[]` defines the blast radius that `build-refine` validated. Applying a SHOULD-FIX to an out-of-scope file silently expands the diff, invalidating the diff-reviewer's prior AC verdict and potentially shipping unreviewed changes to unrelated modules.

**NEVER auto-apply a STRUCTURAL MUST-FIX.**
WHY: STRUCTURAL means the current implementation plan is wrong at the architecture level. Implementing it inline without re-planning creates code that satisfies the reviewer's wording but breaks internal consistency (e.g. implementing an API contract reversal mid-task produces orphaned callers). The correct path — HALT-003 → `/build-refine` re-plan — costs one session but prevents compound debt.

**NEVER post a reply containing an unsubstituted `<placeholder>` token.**
WHY: the PR reply is the public record of what was done. A `<commit-sha>` or `<follow-up-issue>` placeholder left in the reply provides zero traceability and signals to reviewers that the automation misfired. HALT-005 (`RENDER_FAILED`) is the correct response — it keeps the audit trail honest.

**NEVER open the `makato-carry-over` follow-up issue, then fail to post the reply (or vice versa).**
WHY: if `gh issue create` fails, the reply template references a URL that does not exist — posting it creates a broken link in the PR thread. The HALT-005 guard on `gh issue create` failure ensures the two operations are atomic: both succeed or neither is visible.

**NEVER write reply text inline in this skill.**
WHY: reply text lives in `pr-comment-replies.md` so that all skills in the build pipeline produce consistent, reviewable comment language. Inlining prose forks the message surface, making automated reply-detection (e.g. checking whether a comment was already handled) fragile and creating a maintenance split when phrasing is updated.

**NEVER skip the Step 5b lesson write on a resolved MUST-FIX.**
WHY: `write-lessons.sh` feeds the recurrence counter that Step 6a reads from `procedural.jsonl`. Skipping even one write depresses the count, preventing `RECURRENCE_THRESHOLD=2` from firing and silently deferring harness promotion. The write is unconditional — a best-effort call that logs warn on failure and never blocks.

**NEVER re-read `AUTONOMOUS-MODE.md` mid-workflow after Step 1a.**
WHY: loading it again mid-step wastes context window and, in a long session, can surface a stale cached version if the file changed between loads. Load once at Step 1a; treat it as session-global.

---

## Autonomous Quick-Reference

| Tier | Step where policy fires | Key constraint |
|---|---|---|
| SENSOR-BOT | Step 5 → sensor-fixer dispatch | Parse failure falls through to MUST-FIX |
| MUST-FIX (non-STRUCTURAL) | Step 6 | Auto-apply; Step 5b lesson always written |
| SHOULD-FIX | Step 6 | Scope guard: defer if any touched file is outside `plan.md Files[]` |
| CONSIDER | Step 5 | Skip; deferred reply posted |
| OUT-OF-SCOPE | Step 6 | Carry-over issue opened via `gh issue create`; HALT-005 if that fails |
| STRUCTURAL | Step 5a | HALT-003: post-reply → label → log → HALT (order mandatory) |
| Promotion | Steps 5b + 6a | `write-lessons.sh` → `procedural.jsonl` recurrence check → `type:harness` issue |

### Return Format (R1, when called as a sub-skill)

Top-level R1 envelope fields follow `plugins/makato-build/agents/RETURN-CONTRACT.md` § *R1 envelope schema*. The skill-specific `data` payload is:

```json
{
  "data": {
    "sensor_bot_delegated": <N>,
    "must_fix_applied": <N>,
    "should_fix_applied": <N>,
    "should_fix_deferred": <N>,
    "consider_skipped": <N>,
    "out_of_scope_skipped": <N>,
    "carry_over_issues": ["<url>", "..."],
    "structural_blockers": <N>,
    "halt_code": "HALT-003" | null,
    "commits": <N>,
    "replies_posted": <N>,
    "harness_issues_opened": <N>,
    "recurring_patterns_detected": <N>
  }
}
```

`agent` is `"build-address-pr-comments"`. `summary` is `"Addressed N comments across <M> commits"` on success.

`status` selection (autonomous mode):

| Outcome | `status` |
|---|---|
| All actionable comments handled, no STRUCTURAL items | `success` |
| At least one SHOULD-FIX deferred OR at least one CONSIDER/OUT-OF-SCOPE skip resulted in a carry-over issue but no STRUCTURAL | `partial` |
| Any STRUCTURAL item, or any HALT fired | `failure` |

### HALT Codes

The HALT codes emitted by this skill are registered with their PO-agent recovery routes in `plugins/makato-build/halt-codes.md`. Skill-level tokens: `MISSING_INPUT`, `PROTECTED_BRANCH`, `STRUCTURAL_BLOCKER`, `BUILD_FAILED`, `PUSH_REJECTED`, `CARRY_OVER_FAILED: <id>`, `RENDER_FAILED: <id>`.

Skill-specific cross-references the registry's prose cannot carry: `STRUCTURAL_BLOCKER` (Step 5a) is paired with `data.halt_code: "HALT-003"` — the PO-agent reads the numeric HALT and routes per `plugins/makato-orchestrate/halt-conditions.md`; the string token is forensic context. `PUSH_REJECTED`, `CARRY_OVER_FAILED`, and `RENDER_FAILED` all surface as `HALT-005` at the PO-agent boundary. `HARNESS_ISSUE_FAILED: <category>` is logged as a warn from Step 6a but does not surface as HALT-005 (soft-warn, non-blocking).
