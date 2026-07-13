---
name: build-review
description: >-
  Adversarial quality review of the branch diff — CRITICAL and (in
  autonomous mode) MAJOR findings are fixed and the review loops until
  clean. Auto-fixes mechanical issues (formatting, imports). Reports
  SUGGESTION and NITPICK findings. Autonomous. Use after simplify, before verify.
version: "1.4.0"
model: opus
argument-hint: "[work-item-key]"

Use after `/simplify` and before `/verify`. The implementation is working, tested, and
simplified. This step reads the branch diff adversarially — its job is to find problems
and improvements, not to confirm correctness.

## Workflow

> **This skill does not commit.** All changes — mechanical fixes and CRITICAL fixes — accumulate in the working tree and are committed by `/build-push-to-git`. Never run `git add` or `git commit` during this skill.

### Step 1 — Ask for work item key and load context

Ask: *"Which work item are we reviewing? (e.g. #123, or pass it directly: `/makato-build:build-review #123`)"* — or use the passed argument.

Read `plan.md` from the resolved spec folder (`specs/<key>-*/`) if it exists. Extract the acceptance criteria and task list —
these are the correctness contract. Every AC must be demonstrably covered by the diff.

Resolve the integration target with `DEFAULT_REF="$(shared/default-branch.sh)"` (returns e.g. `origin/main`). Fetch the remote first — `git fetch origin --quiet` — so the diff reflects the latest integration tip; if `origin` is unreachable, fall back to the local default branch and continue. Then run `git diff "$DEFAULT_REF...HEAD" --name-only` to get the list of changed files. Never diff against the bare local `main` — when local `main` lags `origin/main` the diff pulls in commits from already-merged PRs (#98).

---

### Step 2 — Log session start

Run:

```bash
shared/build-log.sh "<key>" '{"ts":"<ISO8601>","skill":"build-review","story":"<key>","step":"session","status":"start","data":{"files_changed":<N>,"pass":1}}'
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

Dispatch the `diff-reviewer` agent with:
- `STORY_KEY`: the work item key
- `PASS_NUMBER`: current pass number (starts at 1; increment on each re-dispatch after CRITICAL fixes)
- `CHANGED_FILES`: list of changed file paths from `git diff "$DEFAULT_REF...HEAD" --name-only` (with `DEFAULT_REF` from Step 1)
- `PLAN_CONTEXT`: acceptance criteria and task list extracted from `plan.md` in the resolved spec folder in Step 1
- `REPO_ROOT`: absolute path to the target repository root

The agent applies the adversarial lens across all seven categories (correctness, edge cases, error handling, security, contract, test coverage, optimizations) and returns findings classified as CRITICAL, MAJOR, SUGGESTION, or NITPICK with source-anchored evidence.

Log:
```
{"ts":"<ISO8601>","skill":"build-review","story":"<key>","step":"analyze","status":"ok","data":{"pass":<N>,"critical":<N>,"major":<N>,"suggestion":<N>,"nitpick":<N>}}
```

---

### Step 5 — Blocking-findings loop and zero-findings gate

**What counts as blocking** depends on mode:
- **CRITICAL findings are always blocking** — in both interactive and autonomous mode.
- **MAJOR findings are blocking in autonomous mode only.** With no human at the prompt, a correctness-adjacent MAJOR would otherwise reach the PR ungated (issue #290). In autonomous mode MAJOR re-triggers the fix loop exactly as CRITICAL does. In interactive mode MAJOR is advisory — reported in Step 6 alongside SUGGESTION so the user decides.

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
shared/log-bypass.sh build-review "<key>" major-autofix apply-in-loop "$TRIGGER"
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
shared/build-log.sh "<key>" '{"ts":"<ISO8601>","skill":"build-review","story":"<key>","step":"session","status":"ok","data":{"passes":<N>,"criticals_fixed":<N>,"majors_fixed":<N>,"majors_open":<N>,"suggestions":<N>,"nitpicks":<N>}}'
```

Tell the user:
*"\<N\> criticals and \<N\> majors fixed across \<N\> passes. \<N\> majors (interactive advisory), \<N\> suggestions and \<N\> nitpicks noted above.*
*Pipeline remaining: `/build-verify` → `/build-push-to-git` → `/build-create-pr`*
*Next: run `/build-verify` to confirm all quality gates pass."*
