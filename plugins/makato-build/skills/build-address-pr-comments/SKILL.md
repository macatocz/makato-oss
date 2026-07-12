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
  OUT-OF-SCOPE carry-over issue).
  Interactive by default. Use after create-pr when review comments arrive.
version: "1.5.2"
argument-hint: "[work-item-key] [--autonomous]"
---

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

Load `@../../AUTONOMOUS-MODE.md` for the activation contract (§ *Activation triggers*) and the per-gate default table. The skill runs in `--interactive` mode by default; autonomous mode opts in per dispatch.

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

Load `@references/comment-classification-guide.md`. Assign each unresolved comment a tier: **MUST-FIX**, **SHOULD-FIX**, **CONSIDER**, or **OUT-OF-SCOPE**. Use the source heuristics and classification rules from the guide; content of the comment overrides the source heuristic.

For any MUST-FIX: check whether it requires changing the fundamental implementation approach (data model redesign, API contract reversal, algorithm replacement). If yes, flag it as **STRUCTURAL**.

---

### Step 5 — Present classification for approval

In **interactive mode**, present the full classification table to the user:

```
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

### Step 6 — Implement fixes

Implement in order: MUST-FIX first, then SHOULD-FIX, then approved CONSIDER items.

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

**Reply text is rendered from `@../../templates/pr-comment-replies.md`** — one section per classification tier plus three autonomous-only sections (DEFERRED, OUT-OF-SCOPE autonomous, STRUCTURAL). The skill MUST load that file and substitute placeholders (`<commit-sha>`, `<fix-summary>`, `<reason>`, `<follow-up-issue>`, `<comment-summary>`) at render time. Hard-coded prose in this skill is a contract violation (AC5).

Tier → template section mapping:

| Tier (mode) | Template section |
|---|---|
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

## Autonomous Execution

Autonomous mode is activated per `@../../AUTONOMOUS-MODE.md` § *Activation triggers*.

In autonomous mode:

- **Never prompt the user** — work-item-key, classification-approval, and push-fix-confirm gates are bypassed per the rules above.
- **Auto-apply policy**: MUST-FIX (non-STRUCTURAL) ✓, SHOULD-FIX ✓ (scope-guarded — see AC2 below), CONSIDER ✗, OUT-OF-SCOPE ✗ (but carry-over issue opened — see AC4).
- **SHOULD-FIX scope guard** (AC2): a SHOULD-FIX is applied only if every file it touches is already inside the task's diff. If not, the comment is marked DEFERRED, the `[DEFERRED]` reply is posted, and the PO-agent is left to decide whether to follow up. See `pr-comment-replies.md` § *SHOULD-FIX (deferred — autonomous-only)*.
- **STRUCTURAL MUST-FIX → HALT-003** (AC3): post a single summary reply on the PR (template § *STRUCTURAL MUST-FIX*), apply `needs-human-review` to the PR and linked issue, log per-comment and summary `autonomous_bypass` entries with `gate: "structural-must-fix"` / `structural-halt-summary`, then return R1 `status: "failure"` with `data.halt_code: "HALT-003"`. The PO-agent enters its HALT-003 recovery path (see `plugins/makato-orchestrate/halt-conditions.md`).
- **OUT-OF-SCOPE carry-over** (AC4): for each OUT-OF-SCOPE comment, open a follow-up GitHub Issue via `gh issue create` (label `makato-carry-over`, auto-created if missing), reply with template § *OUT-OF-SCOPE* autonomous variant pointing at the new issue. If `gh issue create` fails, HALT with `HALT-005` and `CARRY_OVER_FAILED: <comment_id>`.
- **Reply templates externalized** (AC5): every reply is rendered from `@../../templates/pr-comment-replies.md`. No reply text is hard-coded in this skill.
- **Log every bypass** to `build.jsonl` via `shared/build-log.sh` with the `autonomous_bypass` event schema documented in `@../../AUTONOMOUS-MODE.md` (AC1).
- **Emit an R1 envelope** as the final `json`-fenced block of the skill's output.

### Return Format (R1, when called as a sub-skill)

Top-level R1 envelope fields follow `plugins/makato-build/agents/RETURN-CONTRACT.md` § *R1 envelope schema*. The skill-specific `data` payload is:

```json
{
  "data": {
    "must_fix_applied": <N>,
    "should_fix_applied": <N>,
    "should_fix_deferred": <N>,
    "consider_skipped": <N>,
    "out_of_scope_skipped": <N>,
    "carry_over_issues": ["<url>", "..."],
    "structural_blockers": <N>,
    "halt_code": "HALT-003" | null,
    "commits": <N>,
    "replies_posted": <N>
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

Skill-specific cross-references the registry's prose cannot carry: `STRUCTURAL_BLOCKER` (Step 5a) is paired with `data.halt_code: "HALT-003"` — the PO-agent reads the numeric HALT and routes per `plugins/makato-orchestrate/halt-conditions.md`; the string token is forensic context. `PUSH_REJECTED`, `CARRY_OVER_FAILED`, and `RENDER_FAILED` all surface as `HALT-005` at the PO-agent boundary.
