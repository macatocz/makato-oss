---
name: create-acceptance-tests
description: >-
  Refine draft Gherkin scenarios into polished acceptance test cases
  (3-5 per foundation/happy-path story, 1-3 per edge-case story). Use after
  decompose to create acceptance tests, generate Gherkin scenarios, or refine
  test cases.
version: "1.5.0"
argument-hint: "[slug]"
allowed-tools: [Read, Write, Agent, Bash]
metadata:
  authors: [makato-plan]
  last_updated: "2026-08-15"
---

# Create Acceptance Tests

Refine the draft Gherkin scenarios from decompose's QA agent into polished,
high-level acceptance test cases (3-5 per foundation/happy-path story, 1-3 per
edge-case story). Writes results back into `stories.json` → `acceptanceTestCases`
field.

> **Downstream note:** `to-issues` does NOT render `acceptanceTestCases[]` into the
> GitHub issue body — it renders `successScenarios[]` only. Instead, `acceptanceTestCases[]`
> feeds the build pipeline: `build-refine` copies it into the plan's `## Acceptance Test
> Oracle` section (`TEST_ORACLE`), and the `coder` agent implements those exact scenarios as
> its RED tests in TDD mode. This is what makes running this skill improve build quality —
> the QA scenarios become the coder's test specification instead of tests the coder derives
> on its own. Run this skill before implementation; it is independent of `to-issues`.

---

## Mindset — Reasoning Framework

A `successScenario` from decompose captures **feasibility signal**: the QA agent confirmed the
scenario is achievable within the story boundary. It does NOT confirm the scenario is a complete
test oracle. For each seed, ask three questions:

1. Can a PO reproduce this outcome in a demo without reading code?
2. Can a coder translate Given/When/Then into a RED test without asking clarifying questions?
3. Are the preconditions reproducible in an integration test harness without mocking internals?

If any answer is "no", the scenario is a draft, not a polished oracle. When you see a vague
seed (e.g., "user can complete checkout"), resist expanding it into multiple scenarios —
sharpen the single seed to pass all three bars first, then consider whether the story's phase
justifies additional scenarios.

The build pipeline treats `acceptanceTestCases[]` as executable spec. Ambiguity here becomes
ambiguity in RED test implementation that the coder cannot resolve alone.

| Bar | Test | Fail signal |
|-----|------|-------------|
| PO-demo testable | A PO can verify outcome manually without reading code | Steps mention endpoints, SQL, or component names |
| Coder-complete | Coder knows exactly what to build from Given/When/Then alone | Then says "correctly" or "properly" without specifying what |
| Boundary-scoped | Preconditions reproducible without mocking internals | Given references specific IDs, config keys, or data fixtures |

A scenario that passes all three bars is polished. Anything failing any bar needs
revision before write-back.

---

## Anti-patterns

These are pipeline-specific failure modes that standard Gherkin style guides do not cover.
Generic Gherkin quality rules (implementation leaks, vague language, etc.) live in
`references/gherkin-quality-rules.md` — the items below are makato-pipeline failures only.

**NEVER seed `acceptanceTestCases[]` from `prd.md` goals — always seed from `successScenarios[]`.**
WHY: The decompose QA agent has already reviewed feasibility and story scope; scenarios
invented from PRD prose bypass that review and produce TEST_ORACLE entries the coder cannot
satisfy within the story boundary, causing TDD RED tests to fail permanently.
Fix: Read `stories[].successScenarios[]` from `stories.json` — those are the authoritative seeds.

**NEVER exceed the phase limit (5 for foundation/happy-path, 3 for edge-cases), even for complex features.**
WHY: `build-refine` passes the entire `acceptanceTestCases[]` array to the coder as RED
test targets; over-specified oracles force the coder to write integration tests for minor
variations that belong in unit tests, inflating TDD cycles beyond the story's scope.
Fix: If the story generates more candidates, keep only those closest to the story's definition
of done; move rejected candidates to a comment on the story's GitHub issue.

**NEVER dispatch `acceptance-writer` in bulk (all stories in one prompt).**
WHY: Context degradation across stories causes the agent to produce generic scenarios not
grounded in each story's specific `phase`, `successScenarios`, and `definitionOfDone`;
per-story dispatch is the contract that preserves quality signal.
Fix: Loop through `stories.json` serially — one `acceptance-writer` dispatch per story.

**NEVER approve scenarios for a story that has zero `successScenarios[]` entries.**
WHY: The `acceptance-writer` uses `successScenarios` as seeds; without seeds it invents
scenarios outside the story boundary, producing a TEST_ORACLE misaligned with what the
decompose QA agent validated.
Fix: Return to `/decompose` for the affected story so the QA agent can complete its review.

**NEVER leave `acceptanceTestCases[]` absent after approval.**
WHY: `build-refine` reads `acceptanceTestCases[]` specifically to populate TEST_ORACLE; if
the field is absent it falls back to deriving tests from story descriptions, losing the
QA-refined specification entirely.
Fix: If write-back was interrupted (user abort, crash), re-run from Step 6 with the previously
approved scenarios — the HTML review file at `specs/{folder}/reviews/acceptance-review.html`
preserves the approved content.

---

## Workflow

### Step 1: Resolve Spec Folder & Validate Input

From the argument (slug) or auto-detect the most recently modified `specs/*/` folder.

```text
Args: /create-acceptance-tests [slug]
Examples:
  /create-acceptance-tests checkout-redesign    → use specs/checkout-redesign/
  /create-acceptance-tests                      → auto-detect most recently modified specs/ folder
```

**Ambiguous auto-detect guard:** If two or more `specs/*/` folders share the most-recent
modification timestamp (within 30 seconds of each other), do not auto-select. List the
candidates and ask:

```text
Multiple spec folders share the most recent modification time:
  • specs/checkout-redesign/   (2026-08-05 14:32:01)
  • specs/payment-flow/        (2026-08-05 14:32:00)
Which folder should I use?
```

Validate the resolved folder:

1. `stories.json` exists in the resolved folder
2. At least one story has `successScenarios` with entries
3. Stories status is "draft" or "approved" (not empty/broken)

If validation fails, halt with:

```text
Cannot generate acceptance tests — stories.json is missing or has no draft scenarios.
Run /decompose first to produce stories with success scenarios.
```

---

### Step 2: Load Context

Read from the resolved spec folder:

1. **`stories.json`** (required) — all stories with their draft successScenarios
2. **`prd.md`** (required for full quality; degrade gracefully if absent) — goals, scope,
   success criteria for framing test intent. If absent, warn:
   ```text
   prd.md not found — proceeding without goal context.
   Test intent will be inferred from successScenarios[] alone; scenario quality may be
   weaker. Consider running /create-prd first for best results.
   ```
   Continue; do not halt.
3. **`design.md`** (optional) — architectural context that may inform what's testable
   at integration level
4. **`decisions.md`** (optional) — resolved decisions that affect test scope

Display summary:

```text
Found {N} stories with draft scenarios in specs/{folder}/.
Refining acceptance tests for each story
(3-5 scenarios per foundation/happy-path story; 1-3 per edge-case story).
```

---

### Step 3: Dispatch Acceptance Writer Agent (Per Story)

For each story in `stories.json`, dispatch the `acceptance-writer` agent with:

```text
Agent({
  subagent_type: "acceptance-writer",
  prompt: "
    ## STORY
    {story as JSON}

    ## PRD_CONTEXT
    {prd goals and scope — or 'prd.md absent; frame from story successScenarios only'}

    ## FEATURE_CONTEXT
    Feature toggle: {story.description.featureToggle}
    Definition of Done: {story.definitionOfDone}
    {if design.md present: Architecture context: {designContextExcerpt}}

    ## GUIDELINES — Gherkin Quality Rules (6-rule condensed checklist)

    Reject any scenario that violates one of these six rules. Fix inline before returning.

    1. **No implementation leaks** — steps must not mention APIs, endpoints, SQL, HTTP
       verbs, error codes, or internal component/class names. Rewrite in business language.
    2. **No generic titles** — title must not contain "test", "check", "verify", "handle",
       "it should", or "make sure". Rewrite as an outcome statement.
    3. **No vague language** — steps must not use "correct", "appropriate", "valid",
       "properly", "successfully", or "as expected" without specifying the concrete
       observable behavior.
    4. **Single When step** — one triggering action per scenario. Split multi-action
       scenarios into separate scenarios.
    5. **No over-detailed steps** — steps must not mention specific field names, exact
       API payloads, database columns, config keys, or environment variables. Describe
       user-level intent only.
    6. **Scenario count** — 3–5 scenarios for foundation/happy-path stories; 1–3 for
       edge-case stories. Minor variations belong in automated unit tests, not here.
  "
})
```

The agent returns refined scenarios per story in structured JSON.
Target count depends on `story.phase`: 3-5 for `foundation` and `happy-path`;
1-3 for `edge-cases`.

```json
{
  "storySequence": 1,
  "scenarios": [
    {
      "title": "Outcome-focused title",
      "given": "precondition in business terms",
      "when": "single user action",
      "then": "observable outcome with should",
      "and": ["additional outcome"]
    }
  ]
}
```

Process stories sequentially — each dispatch is independent but sequential avoids
overwhelming context.

**Error handling:** If the agent returns malformed JSON (missing `storySequence` or
`scenarios` fields), re-dispatch once with the same prompt. If still malformed after retry,
retain the story's `successScenarios[]` as a fallback and flag the story in the completion
summary. Do not halt — continue with remaining stories.

If the agent returns an empty `scenarios` array for a story, treat it the same as malformed
output (fallback to `successScenarios[]`).

---

### Step 4: Quality Self-Review

Validate each scenario against the 6 rules in the Step 3 condensed checklist.
For each violation found: fix inline. Track fixes for the review summary.

Also validate structural constraints:

- Each foundation/happy-path story has 3-5 scenarios; each edge-cases story has
  1-3 scenarios
- Each scenario has: title, given, when, then (and is optional)
- Title is not empty, doesn't start with "Test"/"Check"/"Verify"
- Then step contains "should"

**High-violation edge case:** If more than half of all stories have >2 violations each, the
input `successScenarios` may be too incomplete to refine well. Report a warning in the
summary but proceed with best-effort fixes — do not block write-back on violation count alone.

---

### Step 5: Generate HTML Review

**Do NOT load `templates/acceptance-review.html` before this step.**

Generate an interactive review HTML using `@templates/acceptance-review.html` showing:

**Structure:**

- **Slide 1 (Overview)**: Total stories processed, total scenarios, quality check
  summary (violations found and fixed), scenario count per story
- **Slides 2-N (One per story)**: Story summary at top, then all refined scenarios
  rendered as Gherkin blocks with proper formatting. Feedback textarea per story.
- **Final slide**: Summary stats + "Copy Feedback" button + next steps guidance

Write to: `specs/{folder}/reviews/acceptance-review.html`

Open in browser and tell the user:

> "I've opened the acceptance test review in your browser. Review the scenarios per
> story and add feedback for anything you'd like changed. Click 'Copy Feedback' and
> paste it back here, or say 'approved' to write them to stories.json."

---

### Step 6: Collect Feedback & Iterate

If user provides feedback:

1. Parse feedback (section → changes needed)
2. Adjust scenarios for the affected stories
3. Re-run quality self-review (Step 4)
4. Regenerate HTML review (Step 5)
5. Repeat until user approves

---

### Step 7: Write Back to stories.json

**MANDATORY: Load `references/acceptance-test-cases-schema.md` at this step to validate
output structure before writing. Do NOT load this reference before user approval.**

On approval, for each story in `stories.json`:

1. Set `acceptanceTestCases` to the refined scenarios array (same structure as
   `successScenarios`):

```json
"acceptanceTestCases": [
  {
    "title": "User should see pricing summary after adding items",
    "given": "the user has added three items to the cart",
    "when": "the user views the cart summary",
    "then": "the user should see the total price including all items",
    "and": ["each line item should show its individual price"]
  }
]
```

2. Write the updated `stories.json` back to disk (preserve all other fields unchanged).

3. **Post-write verification** — re-read `stories.json` from disk and assert that every processed story has an `acceptanceTestCases` field present and non-empty. For each story where the field is missing after write-back, emit a warning:

   ```text
   WARNING: acceptanceTestCases missing after write-back for story {sequence}: {summary}.
   Recovery source: specs/{folder}/reviews/acceptance-review.html
   Re-run from Step 6 using the approved scenarios in that file.
   ```

   Do not silently continue past a missing field — surface it explicitly so the operator can recover without re-running the full skill.

The scenario object shape is defined in `shared/scenario-schema.md` — keep both consumers
(`successScenarios`, `acceptanceTestCases`) aligned with that schema.

Display completion summary:

```text
Acceptance tests written to stories.json

  Stories:   {N} stories updated
  Scenarios: {total} scenarios across all stories
  Quality:   {violations_fixed} anti-pattern violations fixed
  Fallbacks: {fallback_count} stories used successScenarios fallback (agent retry failed)

  Next: /to-issues to create GitHub issues (renders successScenarios[]).
        acceptanceTestCases[] flows separately into the build pipeline via
        build-refine → TEST_ORACLE → coder RED tests.
```
