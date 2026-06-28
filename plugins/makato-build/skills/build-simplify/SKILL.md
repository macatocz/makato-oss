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
version: "1.3.0"
argument-hint: "[work-item-key] [--autonomous]"
---

## When to Use

Use after `/implement-tdd` or `/implement-goal` and before `/review`. The implementation
is working and tested. This step asks: is it as simple as it could be while still
satisfying the acceptance criteria?

Scoped to the build pipeline — only code changed in this branch. It is distinct from the
suite-level `simplify` skill, which is a general-purpose code review tool.

## Workflow

### Step 1 — Ask for work item key and load context

Ask: *"Which work item are we simplifying? (e.g. DCP-1234)"* — or use the passed argument.

Read `plan.md` from the resolved spec folder (`specs/<key>-*/`) if it exists. Extract the acceptance criteria for each task —
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

Load @shared/baseline-guide.md. Run the full test suite and record the **pre-simplification baseline** (passing and failing counts).

Pre-existing failures do not gate this session — Step 7 only blocks on *new* failures introduced during simplification.

Log:
```
{"ts":"<ISO8601>","skill":"build-simplify","story":"<key>","step":"baseline","status":"ok","data":{"passing":<N>,"failing":<N>}}
```

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

Run the full test suite. Compare against the baseline from Step 3.

Zero new failures is the gate. If any test broke, the simplification was not
behavior-neutral. Revert the failing change, re-run to confirm recovery, and remove that
finding from the applied list.

Log:
```
{"ts":"<ISO8601>","skill":"build-simplify","story":"<key>","step":"verify","status":"ok","data":{"new_failures":0,"lines_removed_total":<N>}}
```

---

### Step 8 — Log session end and hand off

Run:

```bash
shared/build-log.sh "<key>" '{"ts":"<ISO8601>","skill":"build-simplify","story":"<key>","step":"session","status":"ok","data":{"findings_applied":<N>,"escalated":<N>,"lines_removed":<N>}}'
```

**Interactive mode** — tell the user:
*"Simplification complete — \<N\> findings applied, \<N\> lines removed.*
*Pipeline remaining: `/build-review` → `/build-verify` → `/build-push-to-git` → `/build-create-pr`*
*Next: run `/build-review` for an adversarial quality review."*

If any ESCALATE findings were flagged:
*"Note: \<N\> structural finding(s) require re-planning. Run `/build-refine` to address them
before proceeding to `/build-review`."*

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
    "new_test_failures": 0
  }
}
```

Status mapping:

- `status: "success"` — session completed cleanly: zero ESCALATE findings AND Step 7 verify gate green (no new test failures). The SIMPLIFY count may be zero.
- `status: "partial"` — session completed BUT one or more ESCALATE findings remain unresolved (they were logged for the PO-agent). The caller decides whether to open `/build-refine` for re-planning.
- `status: "failure"` — Step 7 verify gate failed (new test failures introduced) AND could not be cleanly reverted, OR a Hard prerequisite (no plan, no diff) blocked the session entirely.

`data.escalated` is the array of ESCALATE finding descriptors (file:line + reason) so the PO-agent can dispatch each one to `/build-refine` independently.

### HALT Codes

| Code | Meaning |
|---|---|
| `MISSING_INPUT` | No work-item key resolvable from args, context bundle, or `$AGENT_ID` source. |
| `MISSING_PLAN` | No `plan.md` in `specs/<key>-*/` AND the dispatch did not pass acceptance criteria inline. (Soft — Step 1 says "proceed without one" so this is only HALT when autonomous AND the dispatch contract demanded ACs.) |
| `BASELINE_BROKEN` | Step 3 baseline could not be established (test runner errors out before producing pass/fail counts). |
| `VERIFY_FAILED` | Step 7 detected new failures introduced by applied simplifications and revert did not restore green. |

