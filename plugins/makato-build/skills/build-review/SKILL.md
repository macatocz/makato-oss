---
name: build-review
description: >-
  Adversarial quality review of the branch diff — CRITICAL and MAJOR
  findings go to the coder for repair in both manual and autonomous modes;
  re-review until no blocking findings remain. Auto-fixes mechanical issues.
  Reports SUGGESTION and NITPICK findings. Use after simplify, before
  verify. Trigger keywords: review, adversarial, diff-review, code-review,
  quality-gate, build-review, check implementation.
version: "1.7.1"
argument-hint: "[work-item-key]"
allowed-tools:
  - Bash
metadata:
  last_updated: "2026-08-05"
---

**Do NOT load this skill when:** reviewing human PR comments (use `build-address-pr-comments`); simplifying complexity without correctness review (use `build-simplify`). Use after implementation for adversarial review and the CRITICAL/MAJOR coder repair loop before verify.

Use after `/simplify` and before `/verify`. The implementation is working, tested, and
simplified. This step reads the branch diff adversarially — its job is to find problems
and improvements, not to confirm correctness.

## Expert Constraints (read before every step)

Non-obvious rules that cannot be inferred from context:

1. **Merge-base to working tree, not HEAD alone.** Resolve the integration target after fetching origin, then use `REVIEW_BASE="$(git merge-base "$DEFAULT_REF" HEAD)"`. Review `git diff "$REVIEW_BASE"` plus untracked files. This preserves three-dot merge-base semantics without hiding uncommitted implementation or coder repairs. Never use bare local `main` (#98).

2. **Zero-findings suspicion threshold: 50 LOC.** For diffs > 50 changed lines, zero CRITICAL/MAJOR findings on a first pass is statistically improbable. Require the citation-record recheck (Step 5). For diffs ≤ 50 LOC, a clean first pass is plausible but the citation record still applies.

3. **`ac_verdicts[]` transport: `build.jsonl` is the only durable record.** `workflow-state.json` is gitignored and never reaches the post-merge GHA runner. `build.jsonl` is the only cross-environment path the `build-create-pr` PR-body renderer and the `documentation-agent` checkpoint flipper can read. Write the verdict entry on the final clean pass — not on intermediate passes, not to any other file.

4. **Both blocking tiers are mode-independent.** CRITICAL and MAJOR must be repaired and independently re-reviewed in manual and autonomous runs. Never defer a MAJOR to the user, downgrade it to SUGGESTION, or mark it resolved merely because the coder returned success.

5. **`diff-reviewer` is the sole verdict judge.** `build-review` and `build-create-pr` are transport-only — they copy `ac_verdicts[]` verbatim. Re-evaluating verdicts here diverges silently from the diff-reviewer's reasoning and corrupts the downstream Issue checkbox chain.

6. **Checkpoint context is role-scoped, not renewed authorization.** On resume, use the current invocation and user authorization for the coordinator; historical child prompts are evidence, not coordinator instructions. Keep coordinator context separate from reviewer/coder dispatch bundles. A reviewer's read-only or no-test-edit restriction must never become a coordinator or coder restriction through a checkpoint. Preserve actual findings and input fingerprints, but reconcile stale role-scoped constraints before dispatch.

---

## Workflow

> **This skill does not commit.** Mechanical fixes and coder repairs stay in the working tree for `/build-push-to-git`. Neither the skill nor its coder dispatch may stage, commit, or push.

### Step 1 — Ask for work item key and load context

If no argument was passed, invoke `AskUserQuestion`:
- question: *"Which work item are we reviewing?"*
- hint: `e.g. #123 — or pass directly: /makato-build:build-review #123`

Resolve `MAKATO_BUILD_ROOT` from the runner plugin-root variables. Apply the workspace
entry guard in `$MAKATO_BUILD_ROOT/AUTONOMOUS-MODE.md`: `WORKTREE_PATH` is required
in autonomous mode; manual mode defaults to the current git worktree. Missing autonomous
workspace returns R1 failure, never a fallback to the main checkout.

```bash
cd "$WORKTREE_PATH"
REPO_ROOT="${MAKATO_TARGET_REPO_ROOT:-$(cd "$(git rev-parse --git-common-dir)/.." && pwd)}"
SPEC_FOLDER="$(python3 "$MAKATO_BUILD_ROOT/shared/spec_folder.py" "$REPO_ROOT" "<key>")"
```

Read `plan.md` from that folder if it exists. Extract the acceptance criteria and task list —
these are the correctness contract. Every AC must be demonstrably covered by the diff.

Fetch origin (`git fetch origin --quiet`), then resolve
`DEFAULT_REF="$("$MAKATO_BUILD_ROOT/shared/default-branch.sh")"`. If origin is unreachable,
use the helper's local fallback. Set `REVIEW_BASE="$(git merge-base "$DEFAULT_REF" HEAD)"`
once for this run. Before **every** review pass, refresh `CHANGED_FILES` as the deduplicated
union of `git diff --name-only "$REVIEW_BASE"` and `git ls-files --others --exclude-standard`.
Use NUL-delimited output when processing paths programmatically. Read untracked files directly;
`git diff` does not include them. All code reads and commands run in `WORKTREE_PATH`;
only spec reads and audit writes use the selected `REPO_ROOT`-rooted `SPEC_FOLDER`.

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

**MANDATORY: Load `@references/review-criteria.md` before dispatching the diff-reviewer agent.** Its four-tier severity rubric governs which findings enter the repair loop in both modes.

Dispatch the `diff-reviewer` agent with:
- `STORY_KEY`: the work item key
- `PASS_NUMBER`: starts at 1; increment on every re-dispatch
- `CHANGED_FILES`: freshly collected tracked changes and untracked paths from Step 1
- `PLAN_CONTEXT`: acceptance criteria, tasks, and constraints from the resolved plan
- `REPO_ROOT`: common repository root for spec context
- `WORKTREE_PATH`: resolved workspace; the reviewer must read the same files the coder edits
- `REVIEW_BASE`: merge-base SHA resolved in Step 1
- `PRIOR_FINDINGS`: prior pass's findings with source evidence; empty on pass 1

The agent applies the adversarial lens across all seven categories (correctness, edge cases, error handling, security, contract, test coverage, optimizations) and returns findings classified as CRITICAL, MAJOR, SUGGESTION, or NITPICK with source-anchored evidence. As of diff-reviewer v1.1.0 it also returns `data.ac_verdicts[]` — one `{ac_id, ac_text, verified, evidence, reason}` per acceptance criterion in `PLAN_CONTEXT`.

Log:
```
{"ts":"<ISO8601>","skill":"build-review","story":"<key>","step":"analyze","status":"ok","data":{"pass":<N>,"critical":<N>,"major":<N>,"suggestion":<N>,"nitpick":<N>}}
```

#### Step 4a — Retain the per-AC verdict set until the final clean pass

Keep `data.ac_verdicts[]` unchanged in memory. Only after Step 5 and Step 5.5 confirm
a complete, clean review of the final working tree, copy it **verbatim** into the
following `build.jsonl` entry. Never persist an intermediate pass as final verification.
This is the durable transport to the PR body and post-merge runner; the last
`ac-verification` line wins:

```
{"ts":"<ISO8601>","skill":"build-review","story":"<key>","step":"ac-verification","status":"ok","data":{"pass":<N>,"ac_verdicts":[{"ac_id":"AC-1","ac_text":"…","verified":true,"evidence":"…","reason":""}]}}
```

When `ac_verdicts` is absent (diff-reviewer predates v1.1.0) or empty, log the entry with
`"ac_verdicts":[]` and `status:"warn"` so the downstream skills degrade to the all-or-nothing
fallback rather than silently skipping checkbox marking.

---

### Step 5 — Blocking-findings loop and zero-findings gate

**CRITICAL and MAJOR are blocking in both manual and autonomous mode.**
The review skill owns this loop; the read-only `diff-reviewer` does not apply repairs.

Parse the last R1 JSON block. Missing/malformed R1, missing or invalid severity counts,
`partial`, or an incomplete file review cannot pass this gate. A `failure` with
blocking findings is a repair request, not a reason to skip to `/build-verify`.
A failure without actionable findings is a blocked review; surface its errors.
For a partial/incomplete review, re-dispatch the reviewer to cover the missing
files if actionable; otherwise return non-success with a terminal session error.
Never turn an unreadable file or absent count into a zero-findings result.

**If `critical_count > 0` OR `major_count > 0`:**

1. Retain every blocking finding with its severity, file/line, category, and evidence
   as `REVIEW_FINDINGS`. Assign a stable finding ID if the reviewer omitted one.
   Do not discard findings that already appeared in an earlier pass.
2. Log each finding before repair:

   ```json
   {"skill":"build-review","story":"<key>","step":"blocking-finding","status":"warn","data":{"pass":1,"severity":"MAJOR","finding":"F1","file":"<path>","category":"<type>","description":"<one line>"}}
   ```

3. Dispatch **`coder` in review-repair mode**, not the reviewer and not a new planning
   cycle. Pass `REVIEW_FINDINGS`, `PLAN_CONTEXT`, `STORY_KEY`, `JSONL_PATH`
   (`$SPEC_FOLDER/build.jsonl`), `REPO_ROOT`, `MAKATO_BUILD_ROOT`, and `WORKTREE_PATH`.
   Forward `GATE_COMMANDS` from implementation; if unavailable, obtain it once from
   `gate-scout` with `REPO_ROOT=WORKTREE_PATH`. Forward available baseline/test evidence
   without inventing a passing baseline. The coder must use the existing repair-mode
   contract in `$MAKATO_BUILD_ROOT/agents/coder.md`, verify its repairs, and return R1.
4. On coder success, log each verified repair with `step:"fix-blocking"`,
   `status:"ok"`, and `data:{pass,severity,finding,file}`. Coder success is **not**
   review approval. Return to Step 3, then Step 4 with an incremented pass counter,
   refreshed file set, and `PRIOR_FINDINGS`. Recheck unresolved findings and newly
   introduced defects against the actual uncommitted working tree.
5. If the coder cannot complete a repair or verification, return a non-success R1
   containing the unresolved findings and concrete blocker. Log terminal
   `step:"session",status:"error"`; never emit a clean result or advance to verify/push.

There is no fixed pass limit that permits unresolved findings through. Continue
repair → review until a complete reviewer R1 reports `status:"success"`,
`critical_count == 0`, and `major_count == 0`. SUGGESTION and NITPICK do not
trigger repairs. No `major-autofix` bypass entry is emitted: both modes now
require the same action, so no human approval gate is being bypassed.

**If zero blocking findings on the first pass:**
Use the merge-base-to-working-tree diff (`git diff "$REVIEW_BASE" --stat`) and the
untracked additions for the changed-LOC count. For diffs ≤ 50 LOC a clean first pass
is plausible, but the citation record still applies. For larger diffs, perform a
source-anchored recheck:
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

**Only a complete review with zero CRITICAL and zero MAJOR findings may proceed.**
After the first-pass recheck (when required), continue to Step 5.5.

---

### Step 5.5 — Final mechanical pass

Re-apply Step 3 after the blocking loop. If this changes any file, increment the
pass counter and return to Step 4: the final review must cover those edits too.
Only an unchanged mechanical pass permits persisting Step 4a's verdicts and
proceeding to Step 6.

Log:
```
{"ts":"<ISO8601>","skill":"build-review","story":"<key>","step":"mechanical-fixes-post","status":"ok","data":{"fixes_applied":<N>}}
```

---

### Step 6 — Present final report and hand off

Present the clean-run findings to the user:

- **CRITICAL and MAJOR findings** — list the verified repairs and pass count. Both
  open counts must be zero. Any surviving or regressed finding returns to Step 5.
- **SUGGESTION findings** — list with file, line, description. The user may address these
  before `/verify` if desired; they do not block.
- **NITPICK findings** — list with file, line, description. Purely informational.

Run:

```bash
"$MAKATO_BUILD_ROOT/shared/build-log.sh" "<key>" '{"ts":"<ISO8601>","skill":"build-review","story":"<key>","step":"session","status":"ok","data":{"passes":<N>,"criticals_fixed":<N>,"majors_fixed":<N>,"criticals_open":0,"majors_open":0,"suggestions":<N>,"nitpicks":<N>}}'
```

Tell the user:
*"\<N\> criticals and \<N\> majors fixed across \<N\> passes. No blocking findings remain. \<N\> suggestions and \<N\> nitpicks noted above.*
*Pipeline remaining: `/build-verify` → `/build-push-to-git` → `/build-create-pr`*
*Next: run `/build-verify` to confirm all quality gates pass."*

Return the R1 envelope from `$MAKATO_BUILD_ROOT/agents/RETURN-CONTRACT.md` with `agent:"build-review"`,
`status:"success"`, accumulated `files_changed`/`tests_written`, `errors:[]`,
and `data:{passes,critical_count:0,major_count:0}`. A caller must not infer success
from a prose report or a coder result.

---

## Anti-patterns

### NEVER diff against bare local `main` — WHY: PR-bleed

Diff against the merge-base with the fetched integration target, not the local branch
tip. Include working-tree repairs and untracked files; reviewing `HEAD` alone repeatedly
reviews the old bug and misses the uncommitted fix.

### NEVER commit during this skill — WHY: atomic-commit model

`/build-push-to-git` owns the commit step. Each commit must map to exactly one plan task and carry a conventional commit message derived from the plan. Ad-hoc commits during review produce un-attributable changesets that bisect incorrectly and confuse the post-merge documentation-agent that reads `build.jsonl` to reconstruct the session.

### NEVER accept "reviewed and found nothing" without source-anchored citations — WHY: non-falsifiable claim

Zero findings on a > 50 LOC diff without per-file citation records is not evidence of correctness — it is evidence of a passive scan. The citation format (`file:path:range | concern | verdict: clean | evidence: code line`) forces an active verification act: you must name the concern you looked for and quote the code that addresses it. A file without a citation is not reviewed; go back and read it.

### NEVER re-evaluate `ac_verdicts` in this skill or in `build-create-pr` — WHY: chain integrity

`diff-reviewer` is the only agent that reads both the diff AND the acceptance criteria simultaneously with the adversarial lens. Re-evaluating verdicts here or in `build-create-pr` uses only partial context (e.g., no diff, or no AC text) and silently diverges from the diff-reviewer's reasoning. The downstream `documentation-agent` in `makato-orchestrate` uses `build.jsonl` as the authoritative verdict source to flip Issue checkboxes; a re-evaluated verdict that contradicts the diff-reviewer's corrupts the audit trail irrecoverably.

### NEVER downgrade a correctness concern to SUGGESTION to avoid blocking — WHY: silent PR escape

SUGGESTION and NITPICK are informational in both modes. Anything touching correctness,
security, or a real failure path is MAJOR or CRITICAL and must enter the coder repair
loop. See `references/review-criteria.md` for the classification boundary.
