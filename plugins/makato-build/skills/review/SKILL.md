---
name: review
description: >-
  Adversarial quality review of the branch diff — CRITICAL findings
  are fixed and the review loops until clean. Auto-fixes mechanical
  issues (formatting, imports). Reports SUGGESTION and NITPICK
  findings. Autonomous. Use after simplify, before verify.
version: "1.0.1"
argument-hint: "[work-item-key]"
---

## When to Use

Use after `/simplify` and before `/verify`. The implementation is working, tested, and
simplified. This step reads the branch diff adversarially — its job is to find problems
and improvements, not to confirm correctness.

## Workflow

### Step 1 — Ask for work item key and load context

Ask: *"Which work item are we reviewing? (e.g. DCP-1234)"* — or use the passed argument.

Read `spec/<key>/plan.md` if it exists. Extract the acceptance criteria and task list —
these are the correctness contract. Every AC must be demonstrably covered by the diff.

Run `git diff main...HEAD --name-only` to get the list of changed files.

---

### Step 2 — Log session start

Append to `spec/<key>/build.jsonl`:
```
{"ts":"<ISO8601>","skill":"review","story":"<key>","step":"session","status":"start","data":{"files_changed":<N>,"pass":1}}
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
{"ts":"<ISO8601>","skill":"review","story":"<key>","step":"mechanical-fixes","status":"ok","data":{"fixes_applied":<N>}}
```

---

### Step 4 — Review the diff — adversarial analysis (loops)

Load `@references/review-criteria.md`.

For each changed file, read the full diff using `git diff main...HEAD -- <file>`, **and**
enough surrounding context — the file before the change, its callers, and what it calls —
to understand the behavior. Do not review a diff in isolation; correctness requires context.

Apply the adversarial lens: assume the author made mistakes. Look for what could go wrong,
not for what is correct. Actively seek all seven categories:

1. **Correctness** — does the implementation do what the AC requires?
2. **Edge cases** — what happens at boundaries, with empty input, with concurrent calls?
3. **Error handling** — are all failure paths handled appropriately?
4. **Security** — is user input validated? Are secrets kept out of logs and responses?
5. **Contract** — does the public interface match what callers expect?
6. **Test coverage** — does the test suite cover the critical paths and all ACs?
7. **Improvements & optimizations** — unnecessary allocations, N+1 queries, inefficient
   algorithms, resource leaks, missed caching opportunities where a clearly better
   approach exists

Classify each finding:
- **CRITICAL** — must be fixed before `/verify`; blocks the pipeline
- **SUGGESTION** — should be fixed; does not block; reported at session end
- **NITPICK** — style or minor clarity; never blocks; reported at session end

Log:
```
{"ts":"<ISO8601>","skill":"review","story":"<key>","step":"analyze","status":"ok","data":{"pass":<N>,"critical":<N>,"suggestion":<N>,"nitpick":<N>}}
```

---

### Step 5 — CRITICAL loop and zero-findings gate

**If CRITICAL findings exist:**
Fix each one. For logic issues, fix the production code. For missing test coverage, add
the test.

Log each fix:
```
{"ts":"<ISO8601>","skill":"review","story":"<key>","step":"fix-critical","data":{"finding":<id>,"file":"<path>"}}
```

Return to Step 4. Increment the pass counter.

**If zero CRITICAL findings on the first pass:**
Treat zero findings as suspicious — do not advance. Perform a source-anchored recheck:
for every changed file, produce a citation record confirming it is clean:

```
file: <path>:<line-range> | concern: <what was checked> | verdict: clean | evidence: <exact code or line reference>
```

Every changed file must have a citation. A file without one is not reviewed — go back
and read it. *"Reviewed and found nothing"* is not acceptable evidence.

Log:
```
{"ts":"<ISO8601>","skill":"review","story":"<key>","step":"zero-findings-recheck","status":"start","data":{"files_to_cite":<N>}}
{"ts":"<ISO8601>","skill":"review","story":"<key>","step":"zero-findings-recheck","status":"ok","data":{"files_cited":<N>}}
```

Return to Step 4 if the source-anchored recheck surfaces new findings.

**If zero CRITICAL findings on any pass after the first, or the recheck confirms clean:**
Proceed to Step 6.

---

### Step 6 — Present final report and hand off

Present the clean-run findings to the user:

- **SUGGESTION findings** — list with file, line, description. The user may address these
  before `/verify` if desired; they do not block.
- **NITPICK findings** — list with file, line, description. Purely informational.

Append to `spec/<key>/build.jsonl`:
```
{"ts":"<ISO8601>","skill":"review","story":"<key>","step":"session","status":"ok","data":{"passes":<N>,"criticals_fixed":<N>,"suggestions":<N>,"nitpicks":<N>}}
```

Tell the user:
*"\<N\> criticals fixed across \<N\> passes. \<N\> suggestions and \<N\> nitpicks noted
above. Next: run `/verify`."*
