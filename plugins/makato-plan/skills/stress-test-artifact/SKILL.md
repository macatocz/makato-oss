---
name: stress-test-artifact
description: >-
  Adversarial interview that stress-tests phase artifacts — grill decisions,
  challenge assumptions, review critically. Use after any artifact is drafted
  and needs scrutiny before committing to the next phase.
version: "1.5.0"
modelRole: advisor
argument-hint: "[slug] [artifact]"
allowed-tools: Bash
metadata:
  authors: ["makato-plan"]
  last_updated: "2026-08-15"
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

> **Do NOT load** files beyond the auto-detection table above. Front-loading the full
> spec tree creates token waste and contradicts the context-scout's role in surfacing
> relevant prior art.

Show the user what will be grilled:

```text
Grill target: {path}
Context: {list of context files}

Answer each question freely — agree, disagree, elaborate, or say
"don't know" to park it as an open question in decisions.md.
```

Confirm before starting.

---

## Step 2.0: Pre-Planning Protocol

Before the first question, load `references/question-planner.md` and prepare a lens
rotation plan for this session.

```bash
# Resolve path via git so it works in both normal checkout and git worktree
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || git -C "$PWD" rev-parse --git-common-dir | sed 's|/\.git.*||')
cat "${REPO_ROOT}/plugins/makato-plan/skills/stress-test-artifact/references/question-planner.md"
```

1. **Identify the artifact type** from Step 1's resolution (brainstorm, prd, design,
   spec, or story).
2. **Select the rotation plan** from the question-planner's table (Plan A for PRD/brainstorm,
   Plan B for design/architecture, Plan C for spec/story).
3. **Prepare the opening lens sequence** for the first four questions — note which lens
   opens Q1–Q4 before asking Q1.
4. **Do NOT tell the user** which plan was selected or which lens each question uses —
   the rotation is an internal structuring device, not a visible prompt.

### `[T]` Deferral Write-back

When the user says "don't know", "skip", or explicitly defers a topic during the grill
(Step 2), record it as a `[T]`-tagged open question in `decisions.md` so later rounds
can pick it up explicitly rather than losing it to the session record.

**Format for a deferred item in the Open Questions table of `decisions.md`:**

```markdown
| [T] Q{N} | {topic summary — one sentence} | {High/Medium/Low} | open |
```

The `[T]` prefix signals that this item was explicitly deferred, not merely skipped.
When a subsequent grill session opens `decisions.md`, all `[T]`-tagged rows are surfaced
first at Step 1 (Open Questions Startup Check) so no deferred topic silently expires.

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

## Anti-patterns

**NEVER use `AskUserQuestion` during the grill (Step 2)**
WHY: The skill's value comes from free-form dialogue that surfaces angles Claude
could not predict. Structured option lists constrain the user to choices Claude
already considered, terminating the discovery process at exactly the point where
unexpected input is most likely.

**NEVER hop between unrelated decision branches before the current branch is exhausted**
WHY: Partially-resolved branches mask second-order dependencies — a decision at the
end of branch A often constrains the first decision of branch B. Premature
topic-switching forces a return to branch A after branch B's context has changed it,
producing inconsistent conclusions the user already agreed to.

**NEVER accept vague or deferred answers ("we'll figure it out later") without
parking them as open questions**
WHY: Verbal agreements to "figure it out later" disappear from the session record.
The items that get deferred in a grill are precisely the ones that blow up during
implementation; a named open question in decisions.md with a Q# reference creates an
audit trail and prevents the team from discovering the ambiguity when it is most
expensive to resolve.

**NEVER modify the grill target artifact itself (prd.md, brainstorm.md, design.md)**
WHY: decisions.md is the canonical record of all shaping outcomes; the grill target
is the input, not the output. Writing conclusions back into the PRD breaks the
lineage used by downstream skills (decompose, create-architecture) to trace why a
decision was made. If the PRD needs updating based on grill findings, that is a
separate Refine invocation.

**NEVER duplicate decision content into glossary.md or other artifacts — reference
by ID only (e.g., "per D-12")**
WHY: Duplicated decision content silently diverges when a decision is later revised
via a subsequent grill session. Two documents with different versions of the same
decision create contradictory sources of truth that downstream skills cannot resolve
automatically.

---

## Step 3: Output

After all branches are resolved, update artifacts:

- **decisions.md**: Add new decisions discovered during the grill (with next
  available ID). Mark any overturned decisions as `**Status**: Revised` with the
  new decision inline. Park "don't know" items in the Open Questions table with
  the `[T]` prefix tag (per Step 2.0 deferral write-back format).
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

> **MANDATORY — derive TEMPLATE_PATH before dispatching doc-writer:**
> ```bash
> REPO_ROOT=$(git rev-parse --show-toplevel)
> TEMPLATE_PATH="${REPO_ROOT}/plugins/makato-plan/skills/stress-test-artifact/templates/stress-test-review.html"
> ```
> Do NOT hard-code a `pwd`-relative or `~`-relative path — the working directory
> differs between a normal checkout, a git worktree, and a nested spec subfolder.
> A mismatched path causes the agent to silently write an empty or broken HTML file
> with no error output.

Dispatch the `doc-writer` agent to generate a change-highlighted HTML review.
Include in the prompt:

- **MODE**: html-review
- **TEMPLATE_PATH**: derived above
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
