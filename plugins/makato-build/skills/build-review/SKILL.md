---
name: build-review
description: >-
  Adversarial quality review of the branch diff — CRITICAL and (in
  autonomous mode) MAJOR findings are fixed and the review loops until
  clean. Auto-fixes mechanical issues (formatting, imports). Reports
  SUGGESTION and NITPICK findings. Autonomous. Use after simplify, before
  verify. Trigger keywords: review, adversarial, diff-review, code-review,
  quality-gate, build-review, check implementation.
version: "1.6.0"
model: opus
argument-hint: "[work-item-key] [--round <N>]"
allowed-tools:
  - Bash
metadata:
  last_updated: "2026-10-18"
---
**Do NOT load this skill when:** reviewing human PR comments (use `build-address-pr-comments`); simplifying complexity without correctness review (use `build-simplify`). Load this skill when the implementation loop has completed and a full adversarial review + CRITICAL fix loop is needed before verify.

Use after `/simplify` and before `/verify`. The implementation is working, tested, and
simplified. This step reads the branch diff adversarially — its job is to find problems
and improvements, not to confirm correctness.

## Expert Constraints (read before every step)

Non-obvious rules that cannot be inferred from context:

1. **Three-dot diff, not two-dot.** `git diff "$DEFAULT_REF...HEAD"` (three dots) diffs the branch tip against the merge-base with the integration target. Two-dot (`..`) diffs against the *current local tip* — if local `main` lags `origin/main`, you import commits from already-merged PRs as if they are changes on this branch, producing false findings on code the author never touched (#98). Always `git fetch origin` first.
2. **Zero-findings suspicion threshold: 50 LOC.** For diffs > 50 changed lines, zero CRITICAL/MAJOR findings on a first pass is statistically improbable. Require the citation-record recheck (Step 5). For diffs ≤ 50 LOC, a clean first pass is plausible but the citation record still applies.
3. **`ac_verdicts[]` transport: `build.jsonl` is the only durable record.** `workflow-state.json` is gitignored and never reaches the post-merge GHA runner. `build.jsonl` is the only cross-environment path the `build-create-pr` PR-body renderer and the `documentation-agent` checkpoint flipper can read. Write the verdict entry on the final clean pass — not on intermediate passes, not to any other file.
4. **MAJOR is mode-gated, not severity-downgraded.** In autonomous mode, a MAJOR finding that reaches a PR without human review is a gating failure (#290). In interactive mode, MAJOR is advisory. Never silently drop a MAJOR or reclassify it as SUGGESTION to avoid triggering the fix loop.
5. **`diff-reviewer` is the sole verdict judge.** `build-review` and `build-create-pr` are transport-only — they copy `ac_verdicts[]` verbatim. Re-evaluating verdicts here diverges silently from the diff-reviewer's reasoning and corrupts the downstream Issue checkbox chain.
6. **`--round <N>` means one round, never a loop.** When the PO-agent passes `--round`, this skill repairs only the findings the review ledger hands it, runs one independent review, and returns. Whether another round happens is decided by `shared/review_gate.py` in the PO-agent, never here. See § *Round mode*.

---

## Round mode (`--round <N>`) — PO-agent owned loop

Used only by the PO-agent (Step 6 #0). Without `--round`, skip this section and run the
**Workflow** below unchanged (interactive use and other callers keep the in-skill loop).

Inputs (context bundle): `STORY_KEY`, `ROUND` (from `--round`), `REVIEW_LEDGER` (absolute path to
`specs/<key>-*/review-ledger.json`), `WORKTREE_PATH`, `REPO_ROOT`, `MAKATO_BUILD_ROOT`.
Set `GATE="$MAKATO_BUILD_ROOT/shared/review_gate.py"` and `SPEC_FOLDER="$(dirname "$REVIEW_LEDGER")"`.
Run everything inside `WORKTREE_PATH`.

**RM1 — Precondition (hard stop).** Before any dispatch or edit:

```bash
python3 "$GATE" assert-round --ledger "$REVIEW_LEDGER" --round "$ROUND"
```

Non-zero exit (missing ledger, terminal decision, or a round number other than the next allowed
one) → log `step:"session",status:"error"` with `data.halt_code:"MISSING_INPUT"` and return R1
`failure` with `errors: ["MISSING_INPUT: review round <N> not allowed by review ledger"]` and
`data.halt_code: "MISSING_INPUT"`. Dispatch nothing, edit nothing.

**RM2 — Context.** Log session start with `data:{round:<N>,mode:"round"}`. Read `plan.md`
acceptance criteria as in Step 1. Read the round's repair set and review base:

```bash
python3 "$GATE" repair-set --ledger "$REVIEW_LEDGER"   # {round, repair_ids, findings, review_base}
```

`REVIEW_BASE` = its `review_base`. `CHANGED_FILES` = the deduplicated union of
`git diff --name-only "$REVIEW_BASE"` and `git ls-files --others --exclude-standard`,
excluding `specs/`.

**RM3 — Repair (round ≥ 1 only).** For each finding in `findings`, in the given order, fix it in
place exactly as Step 5 fixes a blocking finding (production code for logic issues, a test for
missing coverage), guided by its `evidence`, `expected` and `acceptance_criteria`. Fix only those
IDs — no unrelated refactoring, never edit `review-ledger.json` or `workflow-state.json`. Log
`step:"blocking-finding"` before and `step:"fix-blocking"` after each, with `data.finding` = the
ledger `id`. A finding you cannot fix → log `step:"repair-skipped",status:"warn"` with the blocker
and continue; the gate counts the attempt either way. Run the targeted tests for touched files
when a runner is known and log the result (`build-verify` still owns the full suite).

**RM4 — Mechanical fixes.** Apply Step 3.

**RM5 — Fingerprint the tree the reviewer will read.**

```bash
REVISION="$(python3 "$GATE" fingerprint --worktree "$PWD" --base "$REVIEW_BASE" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["revision"])')"
```

**RM6 — One independent review.** Load `@references/review-criteria.md`, then dispatch
`diff-reviewer` with `STORY_KEY`, `PASS_NUMBER = ROUND + 1`, `CHANGED_FILES`, `PLAN_CONTEXT`,
`REPO_ROOT`, `REVIEW_BASE`, and `PRIOR_FINDINGS` = the `unresolved` list from
`python3 "$GATE" decide --ledger "$REVIEW_LEDGER"` (empty on round 0). A `partial` result →
re-dispatch once for the missing files; still `partial` → keep it (the gate stops the loop).
The Step 5 zero-findings recheck rules apply unchanged.

**RM7 — Final mechanical pass.** Re-apply Step 3. If it changed files, recompute `REVISION` (RM5)
and repeat RM6 once without repairs; if the second pass changes files again, return the reviewer's
R1 with `status:"partial"` — never return a revision the reviewer did not read.

**RM8 — Persist.** Write the reviewer's R1 verbatim to `$SPEC_FOLDER/review-round-<N>.json`.
When the reviewer returned `success`, persist `ac_verdicts[]` exactly as Step 4a. Log
`step:"review-round"` with `data:{round,critical,major,repaired_ids,repair_skipped_ids}` and a
terminal `step:"session"` (`ok` for `success`/`failure`, `error` for `partial`).

**RM9 — Return.** R1 with `agent:"build-review"`, `status` = the reviewer's status, `errors` = the
reviewer's `errors`, and `data` = the reviewer's `data` (verbatim: counts, `findings`,
`verified_prior_ids`, `ac_verdicts`) plus `round:<N>`, `review_revision:"$REVISION"`,
`repaired_ids`, `repair_skipped_ids`. Do not loop back to RM3, do not call
`review_gate.py reconcile`, and do not decide what happens next.

---

## Workflow

> **This skill does not commit.** All changes — mechanical fixes and CRITICAL fixes — accumulate in the working tree and are committed by `/build-push-to-git`. Never run `git add` or `git commit` during this skill.

### Step 1 — Ask for work item key and load context

If no argument was passed, invoke `AskUserQuestion`:

- question: *"Which work item are we reviewing?"*
- hint: `e.g. #123 — or pass directly: /makato-build:build-review #123`

Read `plan.md` from the resolved spec folder (`specs/<key>-*/`) if it exists. Extract the acceptance criteria and task list —
these are the correctness contract. Every AC must be demonstrably covered by the diff.

Resolve the integration target with `DEFAULT_REF="$("$MAKATO_BUILD_ROOT/shared/default-branch.sh")"` (returns e.g. `origin/main`). Fetch the remote first — `git fetch origin --quiet` — so the diff reflects the latest integration tip; if `origin` is unreachable, fall back to the local default branch and continue. Then run `git diff "$DEFAULT_REF...HEAD" --name-only` to get the list of changed files. Never diff against the bare local `main` — when local `main` lags `origin/main` the diff pulls in commits from already-merged PRs (#98).

---

### Step 2 — Log session start

Run:

```bash
"$MAKATO_BUILD_ROOT/shared/build-log.sh" "<key>" '{"ts":"<ISO8601>","skill":"build-review","story":"<key>","step":"session","status":"start","data":{"files_changed":<N>,"pass":1}}'
```

---

### Step 3 — Auto-fix mechanical issues

Load `@references/mechanical-fixes.md`.

Apply all applicable fixes silently — these are never findings:

- Formatting drift (indentation, spacing) — run the project's formatter if one is configured
- Import ordering and unused import removal
- Trailing whitespace

Log:

```
{"ts":"<ISO8601>","skill":"build-review","story":"<key>","step":"mechanical-fixes","status":"ok","data":{"fixes_applied":<N>}}
```

---

### Step 4 — Review the diff (via diff-reviewer agent) — loops

**MANDATORY: Load `@references/review-criteria.md` before dispatching the diff-reviewer agent.** The severity classification decision tree (CRITICAL / MAJOR / SUGGESTION / NITPICK) and the adversarial stance live in that reference and govern how the diff-reviewer rates every finding. Incorrect classification at this step misroutes the entire fix loop — a MAJOR rated SUGGESTION bypasses the autonomous fix loop entirely.

Dispatch the `diff-reviewer` agent with:

- `STORY_KEY`: the work item key
- `PASS_NUMBER`: current pass number (starts at 1; increment on each re-dispatch after CRITICAL fixes)
- `CHANGED_FILES`: list of changed file paths from `git diff "$DEFAULT_REF...HEAD" --name-only` (with `DEFAULT_REF` from Step 1)
- `PLAN_CONTEXT`: acceptance criteria and task list extracted from `plan.md` in the resolved spec folder in Step 1
- `REPO_ROOT`: absolute path to the target repository root

The agent applies the adversarial lens across all seven categories (correctness, edge cases, error handling, security, contract, test coverage, optimizations) and returns findings classified as CRITICAL, MAJOR, SUGGESTION, or NITPICK with source-anchored evidence. As of diff-reviewer v1.1.0 it also returns `data.ac_verdicts[]` — one `{ac_id, ac_text, verified, evidence, reason}` per acceptance criterion in `PLAN_CONTEXT`.

Log:

```
{"ts":"<ISO8601>","skill":"build-review","story":"<key>","step":"analyze","status":"ok","data":{"pass":<N>,"critical":<N>,"major":<N>,"suggestion":<N>,"nitpick":<N>}}
```

#### Step 4a — Persist the per-AC verdict set (AC-verification transport)

After parsing the diff-reviewer R1, copy `data.ac_verdicts[]` **verbatim** into a dedicated
`build.jsonl` entry. This is the durable Layer-2 transport: `workflow-state.json` is gitignored
and never reaches the post-merge runner, and `build.jsonl` is the audit file `build-create-pr`
reads to render the PR-body verdict block (Layer 3's only cross-environment input). Emit it on
the **final** (clean) pass so the persisted verdicts reflect the merged code, overwriting any
earlier pass's entry by recency (the last `ac-verification` line wins):

```
{"ts":"<ISO8601>","skill":"build-review","story":"<key>","step":"ac-verification","status":"ok","data":{"pass":<N>,"ac_verdicts":[{"ac_id":"AC-1","ac_text":"…","verified":true,"evidence":"…","reason":""}]}}
```

When `ac_verdicts` is absent (diff-reviewer predates v1.1.0) or empty, log the entry with
`"ac_verdicts":[]` and `status:"warn"` so the downstream skills degrade to the all-or-nothing
fallback rather than silently skipping checkbox marking.

---

### Step 5 — Blocking-findings loop and zero-findings gate

**What counts as blocking** depends on mode:

- **CRITICAL findings are always blocking** — in both interactive and autonomous mode.
- **MAJOR findings are blocking .** With no human at the prompt, a correctness-adjacent MAJOR would otherwise reach the PR ungated (issue #290). In autonomous mode MAJOR re-triggers the fix loop exactly as CRITICAL does. In interactive mode MAJOR is advisory — reported in Step 6 alongside SUGGESTION so the user decides.

Autonomous mode is detected via the standard triggers in `plugins/makato-build/AUTONOMOUS-MODE.md` § *Activation triggers* (`--autonomous`, `task_id` in the dispatch bundle, or `$AGENT_ID` exported).

**If blocking findings exist** (CRITICAL always; MAJOR when autonomous):
Fix each one. For logic issues, fix the production code. For missing test coverage, add
the test.

Before fixing each blocking finding, log it:

```
{"ts":"<ISO8601>","skill":"build-review","story":"<key>","step":"blocking-finding","status":"warn","data":{"pass":<N>,"severity":"CRITICAL"|"MAJOR","finding":<id>,"file":"<path>","category":"<type>","description":"<one line>"}}
```

Log each fix:

```
{"ts":"<ISO8601>","skill":"build-review","story":"<key>","step":"fix-blocking","data":{"severity":"CRITICAL"|"MAJOR","finding":<id>,"file":"<path>"}}
```

In autonomous mode, also emit an `autonomous_bypass` audit entry the first time a MAJOR is auto-fixed on a pass (the interactive path would have deferred the decision to the user):

```bash
"$MAKATO_BUILD_ROOT/shared/log-bypass.sh" build-review "<key>" major-autofix apply-in-loop "$TRIGGER"
```

Return to Step 4. Increment the pass counter.

**If zero blocking findings on the first pass:**
Treat zero findings as suspicious when the changed LOC count (from `git diff "$DEFAULT_REF...HEAD" --stat`) exceeds 50. For diffs ≤ 50 LOC, a clean first pass is plausible and the citation record still applies. For diffs > 50 LOC, perform a source-anchored recheck:
for every changed file, produce a citation record confirming it is clean:

```
file: <path>:<line-range> | concern: <what was checked> | verdict: clean | evidence: <exact code or line reference>
```

Every changed file must have a citation. A file without one is not reviewed — go back
and read it. *"Reviewed and found nothing"* is not acceptable evidence.

Log:

```
{"ts":"<ISO8601>","skill":"build-review","story":"<key>","step":"zero-findings-recheck","status":"start","data":{"files_to_cite":<N>}}
{"ts":"<ISO8601>","skill":"build-review","story":"<key>","step":"zero-findings-recheck","status":"ok","data":{"files_cited":<N>}}
```

Return to Step 4 if the source-anchored recheck surfaces new findings.

**If zero blocking findings on any pass after the first, or the recheck confirms clean:**
Proceed to Step 5.5.

---

### Step 5.5 — Re-run mechanical fixes after CRITICAL loop

CRITICAL fixes can introduce formatting drift (e.g. a multi-line fix that the formatter would rewrite). Re-apply the same mechanical fix pass from Step 3 — formatter, unused imports, trailing whitespace — before the final report. This ensures the working tree is clean when `/build-push-to-git` stages files. (MAJOR fixes applied in autonomous mode are subject to the same re-run.)

Log:

```
{"ts":"<ISO8601>","skill":"build-review","story":"<key>","step":"mechanical-fixes-post","status":"ok","data":{"fixes_applied":<N>}}
```

---

### Step 6 — Present final report and hand off

Present the clean-run findings to the user:

- **MAJOR findings** — correctness-adjacent defects below the CRITICAL bar. In **autonomous mode** these were already fixed in the Step 5 loop, so this list is empty on a clean run; if any MAJOR survives (e.g. a fix was reverted), it is reported here and the run should not be treated as clean. In **interactive mode** MAJOR findings are advisory: list them with file, line, and description. The user SHOULD address them before `/verify` — they are more than preferences — but they do not hard-block the interactive pipeline.
- **SUGGESTION findings** — list with file, line, description. The user may address these
  before `/verify` if desired; they do not block.
- **NITPICK findings** — list with file, line, description. Purely informational.

Run:

```bash
"$MAKATO_BUILD_ROOT/shared/build-log.sh" "<key>" '{"ts":"<ISO8601>","skill":"build-review","story":"<key>","step":"session","status":"ok","data":{"passes":<N>,"criticals_fixed":<N>,"majors_fixed":<N>,"majors_open":<N>,"suggestions":<N>,"nitpicks":<N>}}'
```

Tell the user:
*"\<N\> criticals and \<N\> majors fixed across \<N\> passes. \<N\> majors (interactive advisory), \<N\> suggestions and \<N\> nitpicks noted above.*
*Pipeline remaining: `/build-verify` → `/build-push-to-git` → `/build-create-pr`*
*Next: run `/build-verify` to confirm all quality gates pass."*

---

## Anti-patterns

### NEVER diff against bare local `main` — WHY: PR-bleed

`git diff main...HEAD` uses the local `main` tip. If local `main` lags `origin/main` by even one merged PR, that PR's commits appear in the diff as if the author wrote them. The diff-reviewer then emits findings on code outside the story scope. Those findings trigger fix loops on the wrong code, and the ac_verdicts written to `build.jsonl` reference ACs the author never implemented. Three-dot syntax with a prefetch is the only correct form (#98).

### NEVER loop in round mode — WHY: the gate owns termination

With `--round`, the next round exists only if `review_gate.py` returned `CONTINUE` to the
PO-agent. A second repair or review inside the same invocation bypasses the round, attempt and
stagnation limits the ledger enforces, and makes `review-round-<N>.json` disagree with the tree.

### NEVER commit during this skill — WHY: atomic-commit model

`/build-push-to-git` owns the commit step. Each commit must map to exactly one plan task and carry a conventional commit message derived from the plan. Ad-hoc commits during review produce un-attributable changesets that bisect incorrectly and confuse the post-merge documentation-agent that reads `build.jsonl` to reconstruct the session.

### NEVER accept "reviewed and found nothing" without source-anchored citations — WHY: non-falsifiable claim

Zero findings on a > 50 LOC diff without per-file citation records is not evidence of correctness — it is evidence of a passive scan. The citation format (`file:path:range | concern | verdict: clean | evidence: code line`) forces an active verification act: you must name the concern you looked for and quote the code that addresses it. A file without a citation is not reviewed; go back and read it.

### NEVER re-evaluate `ac_verdicts` in this skill or in `build-create-pr` — WHY: chain integrity

`diff-reviewer` is the only agent that reads both the diff AND the acceptance criteria simultaneously with the adversarial lens. Re-evaluating verdicts here or in `build-create-pr` uses only partial context (e.g., no diff, or no AC text) and silently diverges from the diff-reviewer's reasoning. The downstream `documentation-agent` in `makato-orchestrate` uses `build.jsonl` as the authoritative verdict source to flip Issue checkboxes; a re-evaluated verdict that contradicts the diff-reviewer's corrupts the audit trail irrecoverably.

### NEVER downgrade a correctness concern to SUGGESTION to avoid blocking — WHY: silent PR escape

SUGGESTION findings are informational and do not trigger the autonomous fix loop. A correctness issue mis-rated as SUGGESTION in interactive mode lands in the PR as a comment, not as a required fix. See `references/review-criteria.md` Classification Summary: if a finding touches correctness, security, or a real failure path it is MAJOR regardless of probability. The MAJOR tier exists precisely to catch this slip.
