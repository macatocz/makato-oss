---
name: build-simplify
description: >-
  Review implemented code for complexity that does not serve the
  acceptance criteria — premature abstractions, unnecessary wrappers,
  dead code, over-indirection. Interactive: presents findings for
  approval before applying. Autonomous mode (per AUTONOMOUS-MODE.md):
  auto-approves SIMPLIFY findings and surfaces ESCALATE findings via R1.
  Use after implement-tdd or implement-goal, before review; also invoked
  by sensor-fixer / build-resolve-finding for code-complexity findings.
version: "1.4.0"
argument-hint: "[work-item-key] [--autonomous]"
---

## When to Use

Use after `/implement-tdd` or `/implement-goal` and before `/review`. The implementation
is working and tested. This step asks: is it as simple as it could be while still
satisfying the acceptance criteria?

Scoped to the build pipeline — only code changed in this branch. It is distinct from the
suite-level `simplify` skill, which is a general-purpose code review tool.

## Input

When dispatched by the PO-agent or `sensor-fixer` (`--autonomous` mode):

- `<work-item-key>` — positional argument.
- `WORKTREE_PATH` — absolute filesystem path to the per-run git worktree. **Mandatory in autonomous mode** (see `plugins/makato-build/AUTONOMOUS-MODE.md` § *WORKTREE_PATH — workspace-isolation contract*). `git diff` and any per-finding fix applies operate on the worktree's branch.
- `--autonomous` — activation flag.

Interactive mode: `WORKTREE_PATH` is optional; fall back to `git rev-parse --show-toplevel` of the current `$PWD`.

### Workspace-isolation entry guard

**Apply this guard BEFORE Step 1.** In autonomous mode (`--autonomous`, `task_id` bundle field, or `$AGENT_ID` exported) an empty `WORKTREE_PATH` is a HALT (R1 `status: "failure"`, `errors: ["MISSING_INPUT: WORKTREE_PATH required in autonomous mode"]`). In interactive mode, resolve `WORKTREE_PATH="$(git rev-parse --show-toplevel)"` and `cd "$WORKTREE_PATH"`. Every `git diff` and fix-apply below runs from this CWD.

Spec-artefact reads use `$REPO_ROOT/specs/<key>-*/`:

```bash
REPO_ROOT="$(cd "$(git -C "$WORKTREE_PATH" rev-parse --git-common-dir)/.." && pwd)"
```

## Workflow

### Step 1 — Ask for work item key and load context

Ask: *"Which work item are we simplifying? (e.g. DCP-1234)"* — or use the passed argument.

Read `plan.md` from the resolved spec folder under `$REPO_ROOT` (`$REPO_ROOT/specs/<key>-*/plan.md`) if it exists. Extract the acceptance criteria for each task —
these define "complexity that serves the ACs." If no plan exists, proceed without one.

Run `git diff main...HEAD --name-only` to identify all changed files in this branch.

---

### Step 1a — Mode detection

This skill follows `plugins/makato-build/AUTONOMOUS-MODE.md`. Autonomous mode activates when ANY of:

1. `--autonomous` is passed as a CLI flag.
2. The caller provides a context bundle whose payload includes a `task_id` field (set by `sensor-fixer` / `build-resolve-finding` when dispatching this skill).
3. `$AGENT_ID` is exported in the environment.

If none of those hold, the skill runs in interactive mode (the default — exactly the behavior prior to v1.3.0). Autonomous mode opts in per dispatch; the rest of this SKILL.md describes both behaviors inline at each gate.

---

### Step 2 — Log session start

Run:

```bash
shared/build-log.sh "<key>" '{"ts":"<ISO8601>","skill":"build-simplify","story":"<key>","step":"session","status":"start","data":{"files_changed":<N>}}'
```

---

### Step 3 — Establish test baseline

Dispatch the `gate-scout` agent (or follow `@shared/baseline-guide.md` discovery) to obtain the project's unit-test command. Two outcomes:

**(a) Test runner discovered.** Run the full test suite and record the **pre-simplification baseline** (passing and failing counts). Set `test_suite_present = true` in the session context.

Pre-existing failures do not gate this session — Step 7 only blocks on *new* failures introduced during simplification.

Log:
```
{"ts":"<ISO8601>","skill":"build-simplify","story":"<key>","step":"baseline","status":"ok","data":{"passing":<N>,"failing":<N>,"test_suite_present":true}}
```

**(b) No test runner discovered** (gate-scout returns empty / no `pyproject.toml`, `package.json`, `Makefile`, `go.mod`, `pom.xml`, `Cargo.toml`, `build.gradle*` produces a runnable test command). This is a **degraded-confidence** path, not an error — proceed without a baseline. Set `test_suite_present = false` in the session context and **skip baseline capture entirely**. Do NOT attempt to run any test command.

Log:
```
{"ts":"<ISO8601>","skill":"build-simplify","story":"<key>","step":"baseline","status":"skip","data":{"test_suite_present":false,"reason":"no test runner discovered"}}
```

The Step 7 verify gate honors this flag and short-circuits; the R1 envelope surfaces `data.test_suite_present` and `data.degraded_confidence` so the PO-agent can route the run for elevated scrutiny.

---

### Step 4 — Analyze changed files for simplification opportunities

Load `@references/simplification-patterns.md`.

For each changed file, read the full diff (`git diff main...HEAD -- <file>`) and scan for
patterns. For each candidate, cross-reference against the plan's ACs:
"Does this complexity serve an acceptance criterion?"
- Yes → verdict: **KEEP**
- No → verdict: **SIMPLIFY** (removable) or **ESCALATE** (structural, requires re-plan)

Classify each finding:
- **SIMPLIFY** — complexity with no AC justification; can be removed or inlined without
  changing behavior
- **KEEP** — appears complex but serves an AC or aligns with a clear codebase pattern;
  document why
- **ESCALATE** — structural over-complexity that cannot be resolved without changing the
  implementation approach; recommend `/refine`. **Also classify as ESCALATE regardless of test pass/fail state:** any removal of input validation, authentication/authorization checks, or security-related guards (e.g. null checks on external input, permission assertions, CSRF tokens, rate-limit enforcement). Flag these explicitly for user review — a test suite may not cover the removed security path.

Log:
```
{"ts":"<ISO8601>","skill":"build-simplify","story":"<key>","step":"analyze","status":"ok","data":{"simplify":<N>,"keep":<N>,"escalate":<N>}}
```

---

### Step 5 — Optional: check against repo patterns, then present findings (interactive)

Load `@references/repo-patterns-guide.md`. Follow its instructions to discover local code
conventions from the repository context (naming, abstraction levels, structural patterns).

For each SIMPLIFY finding, check whether the proposed simplification aligns with local
patterns or diverges from them. If a simplification would introduce a pattern inconsistency,
flag it and reconsider.

Scan the changed code for any patterns not caught by the anti-pattern catalog but that
diverge from local codebase style — add these as additional SIMPLIFY candidates.

Present all findings grouped by verdict. For each SIMPLIFY finding, show:
- File and line(s)
- Pattern matched (anti-pattern from simplification-patterns.md, or local-pattern divergence)
- What to remove, inline, or align
- Confidence that the change won't alter behavior

For each ESCALATE finding, present separately and recommend `/refine`.

**Interactive mode** — wait for the user to approve or reject each SIMPLIFY finding. The user may override any finding in either direction. If there are zero SIMPLIFY findings, report that and confirm with the user before proceeding — zero findings is plausible but warrants a quick sanity check.

**Autonomous mode (per AUTONOMOUS-MODE.md)** — apply the documented defaults without prompting:

- Every `SIMPLIFY` finding is **auto-approved** and queued for Step 6. Reasoning: the finding came out of the anti-pattern catalog or local-pattern divergence pass, both of which produce deterministic findings; the test-baseline gate in Step 7 catches any behavior-breaking apply.
- Every `KEEP` finding stays KEEP. No action.
- Every `ESCALATE` finding is **NOT auto-applied**. The finding is preserved for the R1 envelope (`data.escalated`) so the PO-agent can surface it for re-planning. ESCALATE includes both structural over-complexity AND security-guard removals from Step 4.
- Zero SIMPLIFY findings is acceptable — proceed without confirmation. Zero findings AND any ESCALATE findings means the session returns R1 `status: "partial"` (work remains for the PO-agent); zero ESCALATE means `status: "success"`.

Emit one `autonomous_bypass` log row per bypassed gate (per AUTONOMOUS-MODE.md § Logging contract):

```json
{"ts":"<ISO8601>","skill":"build-simplify","story":"<key>","step":"decision","status":"decision","data":{"event":"autonomous_bypass","gate":"per-finding-approval","bypassed":true,"default_taken":"auto-approve-simplify","trigger":"agent_id|cli_flag|task_id_bundle"}}
```

If zero SIMPLIFY findings:

```json
{"ts":"<ISO8601>","skill":"build-simplify","story":"<key>","step":"decision","status":"decision","data":{"event":"autonomous_bypass","gate":"zero-findings-confirm","bypassed":true,"default_taken":"proceed","trigger":"..."}}
```

Then emit the standard review log:
```
{"ts":"<ISO8601>","skill":"build-simplify","story":"<key>","step":"review","status":"ok","data":{"approved":<N>,"rejected":<N>,"escalated":<N>,"pattern_divergences":<N>,"zero_findings":<bool>}}
```

---

### Step 6 — Apply approved simplifications

Apply each approved finding. Do not change any test files — production code only.
Do not introduce new behavior. The goal is reduction: fewer lines, fewer abstraction layers,
clearer intent aligned with local conventions.

After all changes verify: (a) no new imports or dependencies were introduced, (b) no public
method signatures changed. If signatures changed, flag this as a potential API change before
proceeding.

Log per change:
```
{"ts":"<ISO8601>","skill":"build-simplify","story":"<key>","step":"apply","data":{"finding":<id>,"lines_removed":<N>}}
```

For each finding classified ESCALATE (not applied), log:
```
{"ts":"<ISO8601>","skill":"build-simplify","story":"<key>","step":"escalate","status":"warn","data":{"finding":"<title>","reason":"<one line — why it requires re-planning>"}}
```

---

### Step 7 — Verify: run full test suite

**Short-circuit when no test runner is present.** If `test_suite_present == false` from Step 3, do NOT attempt to run any test command. The session proceeds with **reduced confidence** in behavior-neutrality; the R1 envelope's `data.degraded_confidence: true` flag is the contract the PO-agent reads to route this run for elevated scrutiny.

Log and proceed to Step 7a:
```
{"ts":"<ISO8601>","skill":"build-simplify","story":"<key>","step":"verify","status":"skip","data":{"test_suite_present":false,"degraded_confidence":true,"new_failures":0,"lines_removed_total":<N>}}
```

**Otherwise** (`test_suite_present == true`), run the full test suite. Compare against the baseline from Step 3.

Zero new failures is the gate. If any test broke, the simplification was not
behavior-neutral. Revert the failing change, re-run to confirm recovery, and remove that
finding from the applied list.

Log:
```
{"ts":"<ISO8601>","skill":"build-simplify","story":"<key>","step":"verify","status":"ok","data":{"test_suite_present":true,"degraded_confidence":false,"new_failures":0,"lines_removed_total":<N>}}
```

---

### Step 7a — Unverified-change gate (no test runner)

This step only fires when `test_suite_present == false` AND at least one applied simplification touched a file outside `**/*.{md,yaml,yml,json,toml}` (i.e. a code file whose behavior is not trivially auditable from the diff).

**Interactive mode** — prompt the user once before Step 8:

> *"No test runner found — `<N>` applied change(s) touched code files and are unverified.  
> Proceed with hand-off to `/build-review`? (y/n)"*

If the user answers `n`, revert the applied changes (`git reset --hard <baseline-sha>` or per-finding revert) and exit the session with `status: "failure"` and `errors: ["UNVERIFIED_HALT: user rejected unverified code changes"]`.

If the user answers `y`, continue to Step 8. Log the decision:
```
{"ts":"<ISO8601>","skill":"build-simplify","story":"<key>","step":"unverified-gate","status":"decision","data":{"test_suite_present":false,"code_files_touched":<N>,"user_choice":"continue|halt"}}
```

**Autonomous mode** — skip the prompt entirely. The R1 envelope's `data.degraded_confidence: true` AND `data.test_suite_present: false` is the upward signal; the PO-agent decides whether to:

1. Accept the change (low-risk diff, docs-only repo).
2. Open `/build-refine` to add a test runner before re-running simplification.
3. Surface to the human operator.

Emit a bypass entry per AUTONOMOUS-MODE.md § Logging contract:
```json
{"ts":"<ISO8601>","skill":"build-simplify","story":"<key>","step":"decision","status":"decision","data":{"event":"autonomous_bypass","gate":"unverified-code-changes","bypassed":true,"default_taken":"proceed-with-degraded-confidence","trigger":"agent_id|cli_flag|task_id_bundle"}}
```

If `test_suite_present == false` AND **only** doc/config files were touched, Step 7a is a no-op in both modes — the changes are auditable from the diff and the user gate is unnecessary.

---

### Step 8 — Log session end and hand off

Run:

```bash
shared/build-log.sh "<key>" '{"ts":"<ISO8601>","skill":"build-simplify","story":"<key>","step":"session","status":"ok","data":{"findings_applied":<N>,"escalated":<N>,"lines_removed":<N>,"test_suite_present":<bool>,"degraded_confidence":<bool>}}'
```

**Interactive mode** — tell the user:
*"Simplification complete — \<N\> findings applied, \<N\> lines removed.*
*Pipeline remaining: `/build-review` → `/build-verify` → `/build-push-to-git` → `/build-create-pr`*
*Next: run `/build-review` for an adversarial quality review."*

If any ESCALATE findings were flagged:
*"Note: \<N\> structural finding(s) require re-planning. Run `/build-refine` to address them
before proceeding to `/build-review`."*

If `test_suite_present == false`:
*"Note: no test runner discovered — applied changes were NOT verified for behavior-neutrality.
Audit the diff manually before proceeding, or add a test runner and re-run this skill."*

**Autonomous mode** — emit the R1 envelope as the final `json`-fenced block of the response. See Autonomous Execution below for the shape.

---

## Autonomous Execution

This skill supports dual-mode execution per `plugins/makato-build/AUTONOMOUS-MODE.md`.

### Mode Detection

Autonomous mode activates when ANY of:

- `--autonomous` CLI flag is passed
- Caller passes context bundle with a `task_id` field (set by `sensor-fixer` / `build-resolve-finding` when dispatching this skill on a code-complexity sensor finding routed via `finding-routes.json`)
- `$AGENT_ID` is exported in the environment

Interactive mode is the default. The OR-equivalent activation rule means a single trigger is enough.

### Autonomous Behavior Summary

| Gate | Interactive | Autonomous default |
|---|---|---|
| Step 1 work-item-key prompt | Asks for key | Use arg if passed; otherwise read it from the dispatching context bundle's `story` / `task_id` field. HALT `MISSING_INPUT` only if neither yields a value. |
| Step 5 per-finding approval | Asks per SIMPLIFY finding | Auto-approve every SIMPLIFY finding. ESCALATE findings are logged + surfaced in R1, never auto-applied. |
| Step 5 zero-findings confirmation | Asks user to confirm | Proceed without confirmation. |
| Step 7a unverified-code-changes gate | Prompts y/n when no test runner AND code files touched | Skip prompt; proceed with `data.degraded_confidence: true` in R1 so the PO-agent decides upstream. |

Every bypassed gate emits an `autonomous_bypass` JSONL entry per AUTONOMOUS-MODE.md § Logging contract.

### R1 Return Format

The final `json`-fenced block of the response MUST be the R1 envelope:

```json
{
  "schema": "r1",
  "agent": "build-simplify",
  "status": "success | partial | failure",
  "summary": "<one-line synthesis>",
  "files_changed": ["..."],
  "tests_written": [],
  "errors": [],
  "tool_calls_used": 0,
  "data": {
    "findings_simplify": 0,
    "findings_keep": 0,
    "findings_escalate": 0,
    "applied": 0,
    "escalated": [],
    "lines_removed": 0,
    "zero_findings": false,
    "new_test_failures": 0,
    "test_suite_present": true,
    "degraded_confidence": false
  }
}
```

Status mapping:

- `status: "success"` — session completed cleanly: zero ESCALATE findings AND Step 7 verify gate green (no new test failures). The SIMPLIFY count may be zero. `degraded_confidence` MAY be `true` if `test_suite_present == false` and only doc/config files were touched (Step 7a no-op) — the verify gate was skipped but no manual scrutiny is needed.
- `status: "partial"` — session completed BUT one or more ESCALATE findings remain unresolved (they were logged for the PO-agent). Also returned when `test_suite_present == false` AND code files were touched in autonomous mode — `data.degraded_confidence: true` signals the PO-agent to route for elevated scrutiny. The caller decides whether to open `/build-refine` for re-planning.
- `status: "failure"` — Step 7 verify gate failed (new test failures introduced) AND could not be cleanly reverted, OR a Hard prerequisite (no plan, no diff) blocked the session entirely, OR Step 7a interactive prompt was answered `n` (`UNVERIFIED_HALT`).

`data.test_suite_present` is the boolean from Step 3 (`true` when gate-scout discovered a runnable test command; `false` when no runner was found). `data.degraded_confidence` is `true` whenever the verify gate was skipped — i.e. whenever `test_suite_present == false`. The two flags are tightly coupled today, but kept separate in the envelope because future Step 7 short-circuits (e.g. test runner present but crash-on-startup) will need to set `degraded_confidence: true` while `test_suite_present: true`.

`data.escalated` is the array of ESCALATE finding descriptors (file:line + reason) so the PO-agent can dispatch each one to `/build-refine` independently.

### HALT Codes

| Code | Meaning |
|---|---|
| `MISSING_INPUT` | No work-item key resolvable from args, context bundle, or `$AGENT_ID` source. |
| `MISSING_PLAN` | No `plan.md` in `specs/<key>-*/` AND the dispatch did not pass acceptance criteria inline. (Soft — Step 1 says "proceed without one" so this is only HALT when autonomous AND the dispatch contract demanded ACs.) |
| `BASELINE_BROKEN` | Step 3 test runner was discovered but crashed before producing pass/fail counts. Distinct from the no-runner skip path (Step 3 outcome (b)) which is **not** a HALT — that path sets `test_suite_present: false` and proceeds with `degraded_confidence`. |
| `VERIFY_FAILED` | Step 7 detected new failures introduced by applied simplifications and revert did not restore green. |
| `UNVERIFIED_HALT` | Step 7a interactive prompt answered `n` — user rejected hand-off of unverified code-file changes. Applied diffs are reverted before exit. |
