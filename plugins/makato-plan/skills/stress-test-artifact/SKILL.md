---
name: stress-test-artifact
description: Adversarial interview that stress-tests phase artifacts — grill decisions,
  challenge assumptions, review critically. Use after any artifact is drafted and
  needs scrutiny before committing to the next phase.
version: "1.3.0"
model: opus
argument-hint: "[slug] [artifact]"
---

# Stress-Test Artifact

Interview me relentlessly about every aspect of the target artifact AND its context
files until we reach a shared understanding. Challenge decisions, assumptions, ideas,
and rejected options equally — anything stated or implied in any of the loaded files
is fair game. Walk down each branch of the decision tree, resolving dependencies
between decisions one-by-one.

---

## Step 1: Resolve Target

```text
Args: /stress-test-artifact [spec-number-or-folder] [artifact-name]
Examples:
  /stress-test-artifact                         → auto-detect from most recently modified spec folder
  /stress-test-artifact checkout-redesign       → auto-detect artifact in that spec folder
  /stress-test-artifact checkout-redesign prd   → grill the PRD in that spec folder
  /stress-test-artifact brainstorm              → grill brainstorm.md in most recent spec folder
```

Resolution order:

1. If explicit spec + artifact given → use them
2. If only spec given → find the spec folder, auto-detect latest artifact
3. If no args → scan `specs/` for the most recently modified folder, auto-detect

Auto-detection (latest artifact wins):

| Artifacts present              | Grill target  | Additional context  |
|-------------------------------|---------------|---------------------|
| brainstorm.md only             | brainstorm.md | reference/          |
| brainstorm.md + decisions.md   | decisions.md  | brainstorm.md       |
| prd.md                         | prd.md        | brainstorm.md       |
| design.md                      | design.md     | prd.md              |
| spec.md                        | spec.md       | design.md, prd.md   |

**Always load `decisions.md`** — regardless of which artifact is the grill target.
It is a living document: outcomes are written back to it after every grill session.

**Always load `glossary.md` if it exists** — the per-spec, feature-scoped vocabulary
written by previous grill sessions. Treat its canonical terms as established: do not
re-ask their meaning unless the user uses one in a way that contradicts the recorded
definition. Apply the glossary when reading every other context file — assumptions
about ambiguous terms in those files should be checked against the glossary first.

Also read any relevant docs from `reference/` within the spec folder if it exists.

Show the user what will be grilled:

```text
Grill target: {path}
Context: {list of context files}

Answer each question freely — agree, disagree, elaborate, or say
"don't know" to park it as an open question in decisions.md.
```

Confirm before starting.

---

## Step 2: Grill

Number every question (Q1, Q2, Q3...). For each question: state the challenge,
then state your recommended answer inline.

```text
Q7: {The specific challenge — a concrete scenario, risk, or ambiguity.}

My recommendation: {Your position and why.}
```

Ask one question at a time. Wait for the answer before moving on.
Do NOT use `AskUserQuestion` — the whole point is free-form input that may surface
new ideas and perspectives beyond yes/no choices.

When a branch has sub-questions, follow them depth-first before moving to the next
topic. Do NOT hop between unrelated decisions — exhaust each branch.

If a question can be answered by exploring the codebase, explore the codebase
instead of asking.

If the user says "don't know" or "skip": accept it, park the item as an open
question in decisions.md (with Q# reference and topic summary), and move to the
next branch.

Keep drilling even when it gets uncomfortable — vague answers ("we'll figure it out
later") hide the hardest problems.

### Scope

Questions concern business behavior, user experience, scope, and business rules. Match scope to the target artifact:

- **`brainstorm.md` / `prd.md`** — technical implementation is **out of scope**. If a technical concern surfaces, park it as an open question for the architecture phase rather than asking it now. The PRD captures WHAT and WHY; HOW belongs to design/spec.
- **`design.md` / `spec.md`** — technical questions are valid at the architecture level, not code-line level.

**Business vs. technical — quick test.** When a question lands in a PRD/brainstorm grill, ask: "Would the answer change what the user experiences, or only how we build it?" If only the latter, defer.

| Question | Verdict for PRD/brainstorm |
|----------|---------------------------|
| "Should the discount cap be 30% or 25%?" | Business — ask |
| "Should cap math be additive or multiplicative?" | Business — ask (different totals → different UX) |
| "Stack PLT + voucher, or best-of?" | Business — ask |
| "One voucher slot or many?" | UX/scope — ask |
| "Validate voucher per-keystroke or on submit?" | UX — ask |
| "SSE vs. WebSocket vs. polling?" | Technical — defer to design.md |
| "After how many SSE reconnects do we fall back to polling?" | Technical — defer |
| "Big-bang cutover, parallel run, or permanent dual-path?" | Technical — defer |
| "Fail-open vs. fail-closed on degradation?" | Technical — defer (ask the user-facing behavior instead: "What should the user see if discounts are unavailable at confirm?") |

### Sharpen feature vocabulary

Watch for fuzzy, overloaded, or undefined terms in any loaded file or in the user's
answers. Triggers:

- **Acronyms / domain shorthand** dropped without expansion (e.g., "ZKDD", "LEP", "TR indirect")
- **Synonyms** used interchangeably ("partner" / "customer" / "account"; "item" / "material" / "line item")
- **Contested terms** where the user's usage conflicts with how the term is used in another file
- **Vague nouns** that could mean two distinct things ("runway" as channel vs. partner segment vs. integration path)

When you spot one, ask about it directly as a numbered question. Propose a canonical
term plus the alternatives to avoid ("You're using *account* — do you mean *Customer*
or *User*? Those are different things"). Resolve before moving on.

Resolved terms are written to `glossary.md` in Step 3 — do not batch them up in
your head, but capture the resolution in a note as soon as it lands so Step 3
has the full list.

---

## Step 3: Output

After all branches are resolved, update artifacts:

- **decisions.md**: Add new decisions discovered during the grill (with next
  available ID). Mark any overturned decisions as `**Status**: Revised` with the
  new decision inline. Park "don't know" items in the Open Questions table.
- **glossary.md**: See Step 3a.
- **Do NOT** modify the grill target itself — decisions.md is the canonical record of outcomes; the HTML review (Step 4) is the per-session snapshot.
- **Do NOT** duplicate decision content into other artifacts — reference by ID only

---

## Step 3a: Glossary write-back

Write resolved terms into `specs/{slug}/glossary.md`. Lazy-create the file with
the header below if it does not exist; otherwise append to / update the existing
sections.

**File header (only on first creation):**

```markdown
# {Feature name} — Glossary

Feature-scoped vocabulary for this shaping run. Populated by the `stress-test-artifact` skill as
terms are resolved during interviews. Other plan skills read this file on entry and
prefer the canonical terms below.

This file is **per-spec** and lives only inside this spec folder. The plugin-level
terminology reference is `shared/terminology.md` (different audience, different role).

## Language

## Relationships

## Flagged ambiguities
```

**Entry plan (under `## Language`):**

```markdown
**{Canonical term}**:
{One-sentence definition — what it IS, not what it does.}
_Avoid_: {comma-separated list of rejected synonyms or shorthand}
```

**Relationships block** — bounded cardinality between terms when stated:

```markdown
- A **{Term A}** produces one or more **{Term B}**
- A **{Term B}** belongs to exactly one **{Term C}**
```

**Flagged ambiguities** — explicit log when a term *was* used ambiguously and how
it was resolved:

```markdown
- "{ambiguous term}" was used to mean both **{Term X}** and **{Term Y}**
  — resolved: these are distinct concepts (Q{#}).
```

**Rules:**

- One sentence per definition. Define what it IS, not what it does.
- Pick one canonical term per concept. List rejected synonyms in `_Avoid_:`.
- Only feature-specific terms. Skip generic programming concepts (timeout, error
  type, validation) and skip terms that already live in `shared/terminology.md`.
- Do not couple to implementation detail. Domain-meaningful terms only.
- When a term is revised by a later grill session, replace the entry in place —
  keep the file canonical, not historical (decisions.md handles audit trail).

---

## Step 4: HTML Review

Dispatch the `doc-writer` agent to generate a change-highlighted HTML review.
Include in the prompt:

- **MODE**: html-review
- **TEMPLATE_PATH**: the absolute path to this skill's `templates/stress-test-review.html`
- **OUTPUT_PATH**: `specs/{slug}/reviews/stress-test-review-{YYYY-MM-DD}.html` (date-stamped so successive sessions don't overwrite each other)
- **CONTENT**: structured grill results including:
  - feature_name (from spec folder)
  - date (today)
  - grill_target (which artifact was grilled)
  - questions_resolved (count)
  - questions_deferred (count)
  - new_decisions (decisions discovered during grill)
  - revised_decisions (decisions overturned with old → new)
  - confirmed_assumptions (validated during grill)
  - open_questions (parked "don't know" items)
  - changes_to_decisions (diff-style: what was added/revised in decisions.md)
  - changes_to_glossary (diff-style: terms added, revised, or flagged-as-ambiguous in glossary.md)

The HTML template highlights changes with visual markers:

- **Added** content in green left-border blocks
- **Revised** content in amber left-border blocks with strikethrough of old text
- **Confirmed** content in subtle grey (validated, not changed)

Once the agent returns, open the HTML file in the browser (use the command for the
user's OS):

```bash
open specs/{slug}/reviews/stress-test-review-{YYYY-MM-DD}.html        # macOS
xdg-open specs/{slug}/reviews/stress-test-review-{YYYY-MM-DD}.html    # Linux
start specs/{slug}/reviews/stress-test-review-{YYYY-MM-DD}.html       # Windows
```

Tell the user:

> "Grill review is open in your browser. Changes to your artifacts are highlighted.
> Review and let me know if anything needs adjustment."

---

## Step 5: Handoff

Show total question count and list any deferred items:

```text
Interview complete ({N} questions resolved, {M} deferred to research).

Deferred items:
- {Q#}: {topic summary}
```

Then use `AskUserQuestion` for routing only:

```text
AskUserQuestion:
  question: "Grill complete. What next?"
  options:
    - "Continue to next phase (Recommended)"
    - "Stop here — I'll come back later"
```
