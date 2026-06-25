---
name: create-acceptance-tests
description: >-
  Refine draft Gherkin scenarios into polished acceptance test cases
  (3-5 per foundation/happy-path story, 1-3 per edge-case story). Use after
  decompose to create acceptance tests, generate Gherkin scenarios, or refine
  test cases.
version: "1.0.2"
model: sonnet
argument-hint: "[slug]"
---

# Create Acceptance Tests

Refine the draft Gherkin scenarios from decompose's QA agent into polished,
high-level acceptance test cases (3-5 per foundation/happy-path story, 1-3 per
edge-case story). Writes results back into `stories.json` → `acceptanceTestCases`
field.

## When to Use

- After decompose has produced `stories.json` with draft `successScenarios`
- Want to refine rough QA drafts into polished, manually testable acceptance tests
- Need acceptance criteria formalized before running /publish

## When NOT to Use

- No `stories.json` exists (run `/decompose` first)
- Want detailed automated test scripts (those are created during implementation)
- Want to create implementation tasks (that's the development workflow)
- Stories have no `successScenarios` entries (decompose didn't complete properly)

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

Validate:

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
2. **`prd.md`** (required) — goals, scope, success criteria for framing test intent
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
    {prd goals and scope}

    ## FEATURE_CONTEXT
    Feature toggle: {story.description.featureToggle}
    Definition of Done: {story.definitionOfDone}
    {if design.md present: Architecture context: {designContextExcerpt}}

    ## GUIDELINES
    {gherkin quality rules — full content of @references/gherkin-quality-rules.md}
  "
})
```

Load @references/gherkin-quality-rules.md and include its full content in the agent
dispatch.

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

---

### Step 4: Quality Self-Review

After collecting agent output for all stories, validate each scenario against the
6 anti-patterns from @references/gherkin-quality-rules.md:

| # | Anti-Pattern | Detection Signal |
|---|---|---|
| 1 | Implementation leaks | API, endpoint, database, SQL, function, class, HTTP verbs |
| 2 | Generic titles | "test", "check", "verify", "handle", "it should" |
| 3 | Vague language | "correct", "appropriate", "valid", "properly", "successfully" |
| 4 | Multiple actions | Two When steps or "and" chaining actions |
| 5 | Over-detailed steps | Specific field names, payloads, config keys |
| 6 | Too many scenarios | More than 5 (foundation/happy-path) or more than 3 (edge-cases) |

For each violation found: fix inline. Track fixes for the review summary.

Also validate structural constraints:

- Each foundation/happy-path story has 3-5 scenarios; each edge-cases story has
  1-3 scenarios
- Each scenario has: title, given, when, then (and is optional)
- Title is not empty, doesn't start with "Test"/"Check"/"Verify"
- Then step contains "should"

---

### Step 5: Generate HTML Review

Generate an interactive review HTML using @templates/acceptance-review.html showing:

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

2. Write the updated `stories.json` back to disk (preserve all other fields
   unchanged)

Load @references/acceptance-test-cases-schema.md during this step to validate the
output structure. The scenario plan itself is defined in `shared/scenario-schema.md`
(read it before writing scenarios) — keep both consumers (`successScenarios`,
`acceptanceTestCases`) aligned with that schema.

Display completion summary:

```text
Acceptance tests written to stories.json

  Stories:  {N} stories updated
  Scenarios: {total} scenarios across all stories
  Quality:  {violations_fixed} anti-pattern violations fixed

  Next: /publish to create stories with embedded acceptance tests
```
