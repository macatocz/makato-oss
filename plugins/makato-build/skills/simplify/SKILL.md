---
name: simplify
description: >-
  Review implemented code for complexity that does not serve the
  acceptance criteria — premature abstractions, unnecessary wrappers,
  dead code, over-indirection. Interactive: presents findings for
  approval before applying. Use after implement-tdd or implement-goal,
  before review.
version: "1.1.1"
argument-hint: "[work-item-key]"
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

Read `spec/<key>/plan.md` if it exists. Extract the acceptance criteria for each task —
these define "complexity that serves the ACs." If no plan exists, proceed without one.

Run `git diff main...HEAD --name-only` to identify all changed files in this branch.

---

### Step 2 — Log session start

Append to `spec/<key>/build.jsonl`:
```
{"ts":"<ISO8601>","skill":"simplify","story":"<key>","step":"session","status":"start","data":{"files_changed":<N>}}
```

---

### Step 3 — Establish test baseline

Run the full test suite. Record the current pass/fail count as the **pre-simplification baseline**.

If the suite already has failures, log the baseline and **proceed** — pre-existing failures are not caused by this session and must not gate simplification. Step 7 only blocks on *new* failures introduced during this session.

Log:
```
{"ts":"<ISO8601>","skill":"simplify","story":"<key>","step":"baseline","status":"ok","data":{"passing":<N>,"failing":<N>}}
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
  implementation approach; recommend `/refine`

Log:
```
{"ts":"<ISO8601>","skill":"simplify","story":"<key>","step":"analyze","status":"ok","data":{"simplify":<N>,"keep":<N>,"escalate":<N>}}
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

Wait for the user to approve or reject each SIMPLIFY finding. The user may override any
finding in either direction.

If there are zero SIMPLIFY findings, report that and confirm with the user before
proceeding — zero findings is plausible but warrants a quick sanity check.

Log:
```
{"ts":"<ISO8601>","skill":"simplify","story":"<key>","step":"review","status":"ok","data":{"approved":<N>,"rejected":<N>,"escalated":<N>,"pattern_divergences":<N>}}
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
{"ts":"<ISO8601>","skill":"simplify","story":"<key>","step":"apply","data":{"finding":<id>,"lines_removed":<N>}}
```

---

### Step 7 — Verify: run full test suite

Run the full test suite. Compare against the baseline from Step 3.

Zero new failures is the gate. If any test broke, the simplification was not
behavior-neutral. Revert the failing change, re-run to confirm recovery, and remove that
finding from the applied list.

Log:
```
{"ts":"<ISO8601>","skill":"simplify","story":"<key>","step":"verify","status":"ok","data":{"new_failures":0,"lines_removed_total":<N>}}
```

---

### Step 8 — Log session end and hand off

Append to `spec/<key>/build.jsonl`:
```
{"ts":"<ISO8601>","skill":"simplify","story":"<key>","step":"session","status":"ok","data":{"findings_applied":<N>,"escalated":<N>,"lines_removed":<N>}}
```

Tell the user:
*"Simplification complete — \<N\> findings applied, \<N\> lines removed. Next: run `/review`."*

If any ESCALATE findings were flagged:
*"Note: \<N\> structural finding(s) require re-planning. Run `/refine` to address them
before proceeding to `/review`."*
