---
name: decompose
description: >-
  Decompose shaped features into vertically-sliced stories with acceptance
  criteria — decompose, vertical slice, story slicing, break down feature,
  split into stories. Use after PRD and architecture are approved.
version: "1.4.1"
model: opus
argument-hint: "[slug]"
metadata:
  authors: ["makato-plan"]
  last_updated: "2026-08-05"
---

# Decompose

Decompose a shaped feature into vertically-sliced stories with acceptance criteria.
Produces `stories.json` — a machine-readable schema of stories ready for downstream
publish skills. Embeds a Three Amigos simulation (PO, Dev Lead, QA) for shared
understanding.

## When to Use

- After PRD and architecture design are complete (ideally Approved)
- Need to break a feature into independently deliverable, testable stories
- Want vertically-sliced stories with acceptance criteria and story point estimates

## When NOT to Use

- No PRD exists yet (run create-prd first)
- No architecture design exists (run create-architecture first)
- Feature is trivial (single story, no slicing needed)
- Want to create GitHub Issues (that's the `to-issues` skill downstream)
- Want detailed implementation tasks (that's dev team refinement — shaping boundary)

---

## Anti-Patterns

Non-obvious failure modes. Each NEVER is grounded in a downstream contract or sprint failure
mode — not generic advice.

**NEVER create a standalone technical enabler story.**
WHY: Produces a story with zero user-observable outcome — cannot be demoed or independently
tested against a Definition of Done. The enabler is only useful when paired with the
user-facing story it enables; splitting it out creates two stories where neither can ship
alone, defeating the vertical-slice contract and poisoning sprint velocity.

**NEVER accept a single-layer or single-repository story.**
WHY: A layer-cut story (UI-only, API-only, DB schema-only) delivers no standalone value and
cannot be tested in a running environment without the other layers. It creates a hidden
"must combine to demo" dependency between board items that appear independent but aren't.

**NEVER write `storyPoints > 13` without recording a BLOCK error.**
WHY: 13 SP is the schema hard cap (enforced in Step 8). An oversized story routinely crosses
sprint boundaries, corrupts velocity measurement, and almost always hides a safe split — the
BLOCK forces re-examination before `to-issues` creates an issue that the team cannot realistically
close in a sprint.

**NEVER emit `tier:`, `points:`, `module:`, `tech:`, or `status:` into `stories[].labels[]`.**
WHY: Each label is owned by a different authoritative source. `tier:` derives from `phase`;
`points:` from `storyPoints`; `module:` from the target repo's ADR folder structure (only
`to-issues` knows this at publish time); `tech:` from `to-issues` text-match; `status:` from
the dependency topo-sort. Emitting them here creates a drift vector: decompose's guess can
conflict with `to-issues`'s derivation, producing mismatched labels on the GitHub issue.

**NEVER mutate `stories.json` after `to-issues` has run.**
WHY: GitHub issues are anchored to story sequence numbers in `created-issues.json`. A sequence
shift after publish breaks the audit trail between each issue and its originating story.
Re-running `to-issues` after mutation creates duplicate issues with no link to the originals.

**NEVER omit `epic.objective` from `stories.json`.**
WHY: `to-issues` validates its presence before rendering the GitHub epic tracking issue title.
A missing objective is a hard publish failure — `to-issues` blocks the entire run, not just
the epic story row. The objective cannot be patched after publish without rewriting the issue.

**NEVER solicit a user choice with freeform prose — always use AskUserQuestion with enum options.**
WHY: Freeform questions cannot be handled by the autonomous loop's headless mode. Enum options
let the loop apply a predictable default (first option) without a human present, enabling
unattended dispatch. Freeform blocks the loop silently.

---

## Constants

- **CONTEXT_SCOUT_TOKEN_BUDGET: 2000** — Maximum tokens returned by a single context-scout dispatch.

---

## Workflow

### Workflow Overview

| Step | What Happens | Key Output |
|------|-------------|------------|
| 1 | Resolve spec folder, load artifacts, detect update mode | Loaded artifacts |
| 2 | Repository research + team mapping via context-scout | Team assignments |
| 3 | Story sketch analysis against architecture + sizing gate | Candidate story list |
| 4 | Decomposition interview — 3 rounds + feature toggle capture | Validated stories |
| 5 | Three Amigos simulation — parallel PO/Dev/QA agents | Per-story feedback + Gherkin |
| 6 | Three Amigos HTML review (max 2 iterations) | Resolved feedback |
| 7 | Generate `stories.json` with labels, skills, scenarios | `stories.json` |
| 8 | Completeness validation — BLOCK/warn/defer tiers | Error/warning list |
| 9 | Parked questions written to `decisions.md` | Updated `decisions.md` |
| 10 | Final HTML review + approval gate | Approved `stories.json` |
| 11 | Status + next-step routing | Handoff message |

### Reference Loading Contract

Load each reference ONLY at its designated step. Do NOT pre-load all references at skill entry —
loading before the designated step wastes context and can cause stale reads if artifacts change
during the interview rounds.

| Reference | MANDATORY at | Do NOT Load Before |
|-----------|-------------|-------------------|
| `@references/team-repository-mapping.md` | Step 2.2 | Step 2.2 |
| `@references/vertical-slicing-rules.md` | Step 3 | Step 3 |
| `@references/phase-assignment-rules.md` | Step 3 | Step 3 |
| `@references/story-point-estimation-guide.md` | Step 3 (5a) | Step 3 |
| `@references/stories-json-schema.md` | Step 7 | Step 7 |

---

### Step 1: Resolve Spec Folder & Load Artifacts

#### 1.1: Resolve Spec Folder

From the argument (slug) or auto-detect the most recently modified `specs/*/` folder.

```text
Args: /decompose [slug]
Examples:
  /decompose checkout-redesign    → use specs/checkout-redesign/
  /decompose                      → auto-detect most recently modified specs/ folder
```

If no spec folder found, inform the user and suggest running the upstream skills first.

#### 1.2: Load Required Artifacts

Read from the resolved spec folder:

1. **`prd.md`** (required) — goals, scope, story sketches, success criteria, phased rollout
2. **`design.md`** (required) — component design, data model, API design, technical decisions
3. **`prototype.html`** (optional) — interactive UI prototype, skip silently if absent
4. **`decisions.md`** — cross-session decision continuity
5. **`repositories.yml`** — affected repositories for team mapping.
   See plan: read `shared/repositories-yml-schema.md`.

**Missing artifact handling**: If `prd.md` or `design.md` is absent:

```yaml
AskUserQuestion:
  question: "Required artifact missing: {name}. Decomposition needs both PRD and architecture. How to proceed?"
  options:
    - "Run {skill} first (Recommended)"
    - "Continue anyway — I'll provide context directly"
```

**Draft status handling**: If `prd.md` or `design.md` exists but its body still contains
`**Status**: Draft`:

```yaml
AskUserQuestion:
  question: "{artifact} is still in Draft. Decomposition should build on Approved inputs. How to proceed?"
  options:
    - "Pause and finalize {artifact} first (Recommended)"
    - "Continue anyway — I accept the risk of late changes"
```

#### 1.3: Open Questions Startup Check

If `decisions.md` exists and the Open Questions table has entries with Priority "High":

```yaml
AskUserQuestion:
  question: "Found {N} high-priority open question(s) from prior sessions. Revisit before continuing?"
  options:
    - "Revisit now — address open questions first (Recommended)"
    - "Continue — I'll address them later"
```

If "Revisit now": present up to 4 open questions ordered by priority.
Record answers — resolved questions move to Decision Details in decisions.md.

#### 1.4: Detect Update Mode

If `stories.json` already exists in the spec folder:

```yaml
AskUserQuestion:
  question: "stories.json already exists. What would you like to do?"
  options:
    - "Refine — update existing stories"
    - "Start fresh — replace with new decomposition"
```

If "Refine": load existing stories, display current summary (story count, phases, total SP).
Enter refinement flow — ask what changed, preserve unchanged stories.
Read `shared/refinement-contract.md` and apply its rules:

- Enumerate change candidates
- Preserve untouched stories byte-for-byte
- Surface AI-inferred changes for approval
- Emit a `changes[]` summary listing modified story sequence numbers and fields

---

### Step 2: Repository Research & Context

#### 2.1: Codebase Research

Spawn the `context-scout` agent per identified repository (from repositories.yml).
Research focus for decomposition:

- Implementation patterns for similar features
- Service boundaries and integration points
- Team ownership signals (CODEOWNERS, recent committers)
- Existing feature toggle patterns

If no `context/` directory exists, skip silently.

**context-scout failure path**: If the scout agent returns an empty manifest or errors out
(e.g., no matching files, directory missing), skip silently and proceed with Step 2.2 using
only the artifact content loaded in Step 1. Do NOT block or prompt — absence of scout findings
is not an error; team mapping can still proceed from `repositories.yml` alone.

#### 2.2: Map Repositories to Teams

**MANDATORY: Load @references/team-repository-mapping.md at this step. Do NOT load before Step 2.2.**

Using repository findings + the mapping reference, propose team assignments for later use
in story creation. Present brief summary:

> Research complete: {N} repositories scanned. Team mapping: {repo → team}

---

### Step 3: Story Sketch Analysis

1. Load PRD story sketches (the 3-5 rough vertical slices from create-prd)
2. Load architecture component design from design.md
3. If prototype.html exists, load it and validate stories against its surfaces
4. For each sketch, analyze against architecture:
   - Is this still one coherent vertical slice?
   - Does the architecture reveal it should be split further?
   - Are technical enablers correctly absorbed (not standalone)?
     Absorb enablers into the first story that needs them.
5. Apply the 9 splitting patterns from @references/vertical-slicing-rules.md.
   Look specifically for hidden slices not obvious from the PRD sketch:
   business rule variations, error handling flows, admin/config setup stories,
   and data migration needs.
5a. **Apply sizing gate** — for each candidate story, estimate SP using
    @references/story-point-estimation-guide.md:
    - If SP > 8: apply the split-preferred rule — attempt to split using the patterns above.
    - For every candidate split, validate it against the split-safety checklist in
      @references/story-point-estimation-guide.md (all four checks: user-facing demoable outcome,
      independently testable, independently deployable, crosses layers). Cross-check against the
      anti-patterns table in @references/vertical-slicing-rules.md.
    - **Reject** any split that produces a story with no standalone user-facing demoable outcome,
      or a horizontal / single-layer cut.
    - If a safe split exists: apply it — splitting is the default, not the exception.
    - If no safe split exists AND SP > 13: record a **blocking error** to surface in Step 8.
      Format: `BLOCK: story <title> storyPoints=<x> exceeds hard cap of 13 with no safe split`.
    - Off-scale value (18, 21, any non-Fibonacci): record a blocking error immediately regardless
      of split outcome.
6. Identify external dependencies per story → drives phase assignment.
   Phase 1 must contain only stories with no external blockers — own code first.
7. Propose initial story list with phase assignments.
   Let feature scope determine story count — do not target a fixed number.

Every story must be a vertical slice delivering a user outcome across layers.
Reject any story scoped to a single layer or single repository.

**MANDATORY: Load @references/vertical-slicing-rules.md during this step. Do NOT load before Step 3.**
**MANDATORY: Load @references/phase-assignment-rules.md during this step. Do NOT load before Step 3.**
**MANDATORY: Load @references/story-point-estimation-guide.md during this step. Do NOT load before Step 3.**

---

### Step 4: Decomposition Interview (Terminal, 3 Rounds)

This happens in the terminal (conversational). Allows dig-deeper follow-ups.

**Round 1 — Story Validation:**

Present proposed stories one by one. For each ask:

- "Is this independently demoable? Is the scope right?"
- "Should it be split further or merged with another?"
- "Any external dependencies? Which team?"
- "Phase assignment: foundation / happy-path / edge-cases — agree?"
- "Which team(s) would work on this?"

Foundation stories must be clear. Reject "we'll figure it out later" for Phase 1 scope —
either decide now or park as a High-priority open question.

Include story point estimation using @references/story-point-estimation-guide.md

**Round 2 — Gaps & Edge Cases:**

- "What error scenarios are we missing?"
- "What admin/config/setup steps are hidden?"
- "What happens if [external system] is unavailable?"
- "Are there data migration stories needed?"
- "Anything from the prototype that's not covered?"

**Round 2.5 — Feature Toggle (epic-level, applies to gated stories):**

Most features use one toggle that gates several stories.
Capture it once, then mark which stories it applies to.

Ask the user:

1. "Does this feature need a runtime toggle? (yes/no)"
2. If **yes**:
   - "Toggle name? (e.g., `dcp-feature-name.enabled`)"
   - "Default state on rollout? (`enabled` / `disabled`)"
   - "Already in place, or does it need to be created? (`alreadyInPlace: true/false`)"
   - "Long-term toggle, or temporary rollout switch? (`longTermUsage: true/false`)"
   - "Which story sequence numbers should be gated by this toggle?" → list

Apply per story when writing stories.json (Step 7):

- **Gated story** → copy the 4 epic-level toggle answers;
  set `newNeeded` to the inverse of `alreadyInPlace`.
- **Not gated** → `newNeeded: false, alreadyInPlace: false, longTermUsage: false,
  name: "", defaultState: ""`.

If the user answers **no** at step 1, every story uses the "not gated" defaults.

**Round 3 — Epic Objective (one-liner):**

Capture `epic.objective` for stories.json. Try in order:

1. **Extract from `prd.md`**: Look for a Goals or Objective section (typically near the top).
   If a single-sentence objective is present, propose it back to the user verbatim:
   > "PRD states the objective as: '{extracted}'. Use this for `epic.objective`?"
   - If confirmed → store as `epic.objective`.
   - If user wants to refine → take the edited version.
2. **Ask fresh** (only if PRD has no clear one-liner objective):
   > "What's the one-line objective for this epic?
   > (Stakeholder-facing — optionally becomes the GitHub epic tracking issue title.)"

The objective is mandatory — `to-issues` validates its presence and the template renders it.
Do not let the user skip this round.

**Parking unanswerable questions**: When the user says "I don't know" or
"we'd need to check with {person}":

1. Acknowledge: "Good question — let's park that for now."
2. Assign sequential ID (Q#) continuing from any existing Qs in decisions.md.
3. Note the question with minimal context.
4. Continue without dwelling.

---

### Step 4.5: Pre-Amigos Compression

Before dispatching the three parallel Three Amigos agents, produce compressed excerpts of
the primary input artifacts. This saves ~24 k tokens per decompose run by replacing full
file content (~11 k tokens combined) with targeted summaries (~1 k tokens each) in every
agent dispatch bundle.

Produce the following three excerpts:

**PRD_EXCERPT** (~1 k tokens): A focused summary of `prd.md` containing:
- Feature goal and user problem (2-3 sentences)
- Key functional requirements as a bullet list (top 5-7 items)
- NFRs and constraints that directly affect story scoping (2-4 items)
- Any explicitly out-of-scope items relevant to story boundaries

**DESIGN_EXCERPT** (~1 k tokens): A focused summary of `design.md` containing:
- Architecture approach and key components (2-3 sentences)
- Service boundaries and integration points that affect story slicing
- Technical decisions (D# entries) referenced in the proposed stories
- Any data model or API contract details relevant to feasibility review

**DECISIONS_SUMMARY** (~1 k tokens): A focused summary of `decisions.md` containing:
- All ADR-format decisions (accepted and rejected options, rationale) referenced by the stories
- Open questions (Q# entries) with High or Medium priority
- Any decisions that constrain story scope or acceptance criteria

Pass `PRD_EXCERPT`, `DESIGN_EXCERPT`, and `DECISIONS_SUMMARY` to the three parallel agents
in Step 5 **in place of the full `prd.md`, `design.md`, and `decisions.md` files**.
The full files remain available in the spec folder; the agents do not need them — the excerpts
contain all context required for value, feasibility, and testability review.

---

### Step 5: Three Amigos Simulation

Run three dedicated agents **in parallel** against the proposed stories:

1. **po-reviewer agent** (Product Owner perspective):
   - Challenges: value, scope, phase assignment, user outcomes
   - Reads: proposed stories + prd.md + decisions.md

2. **dev-reviewer agent** (Lead Developer perspective):
   - Challenges: feasibility, technical risk, dependencies, estimates
   - Reads: proposed stories + design.md + decisions.md + context-scout findings

3. **qa-reviewer agent** (QA Engineer perspective):
   - Challenges: testability, completeness, produces draft Gherkin
   - Produces: 1-3 draft Gherkin scenarios per story
   - Reads: proposed stories + prd.md + design.md + decisions.md
   - For each scenario: if a concrete shell command exists that would verify this scenario
     in a running environment, record it as `verificationCommand`; otherwise omit the field.

**Output**: Structured per-story feedback from each perspective + draft Gherkin from QA.
The qa-reviewer's draft Gherkin is later copied into each story's
`description.successScenarios[]` during Step 7 (substep 4) — that array becomes the seed
input for the downstream `create-acceptance-tests` skill.

---

### Step 6: Three Amigos HTML Review

Generate interactive HTML review using `@templates/stories-review.html`:

**Structure:**

- **Slide 1 (Overview)**: Summary of all three perspectives, key disagreements highlighted,
  proposed story count and phase distribution
- **Slides 2-N (One per story)**:
  - Story summary rendered as a card (familiar format)
  - Three callout boxes, color-coded by agent:
    - PO feedback (blue)
    - Dev feedback (green)
    - QA feedback (amber) — includes draft Gherkin
  - User input textarea for resolution/feedback
- **Final slide**:
  - Cross-cutting concerns raised by agents
  - Missing stories proposed by any agent
  - Phase board view (3 columns: foundation / happy-path / edge-cases)

Write to: `specs/{folder}/reviews/three-amigos-review.html`

> **MAKATO_PLAN_NO_HTML guard**: Check `MAKATO_PLAN_NO_HTML` env var. If set, skip this browser-open call entirely and proceed to the next step.

Open in browser:

```bash
open specs/{folder}/reviews/three-amigos-review.html        # macOS
xdg-open specs/{folder}/reviews/three-amigos-review.html    # Linux
start specs/{folder}/reviews/three-amigos-review.html       # Windows
```

Tell the user:

> "Three Amigos review is open in your browser. Each story shows PO, Dev, and QA
> perspectives. Resolve disagreements and add your comments.
> Click 'Copy Feedback' when done."

**Loop logic**:

- User pastes feedback via "Copy Feedback" button
- If feedback exists: incorporate, re-run agents on changed stories only, regenerate HTML
- **Natural endpoint**: Max 2 iterations, OR user says "good enough" / "approved",
  OR no new high-severity findings in second pass
- Agents in subsequent passes: "Focus only on whether previous concerns were addressed.
  Do not raise new minor issues."

---

### Step 7: Generate stories.json

1. Incorporate all accepted three-amigos feedback
2. Write `specs/{folder}/stories.json` with the schema from @references/stories-json-schema.md
3. **Set `epic.objective`** from Round 3 of the Step 4 interview.
   This is mandatory — do not write stories.json without it.
4. **Copy qa-reviewer drafts into `description.successScenarios[]`**:
   For each story, take the 1-3 draft Gherkin scenarios that the `qa-reviewer` agent
   produced in Step 5 (after any user edits from the three-amigos review in Step 6) and
   write them into the story's `description.successScenarios[]` array using the shared
   scenario schema — read `shared/scenario-schema.md` for the canonical plan.
   `verificationCommand` is copied verbatim when present on a scenario and omitted when
   absent — do not add the field if the qa-reviewer did not produce one.
   These drafts are the seed input that the downstream `create-acceptance-tests` skill
   refines into polished `acceptanceTestCases[]`. If a story has no qa-reviewer draft
   (e.g., agent skipped it), leave `successScenarios: []` and flag it in Step 8 validation.
5. Apply progressive detail decay:
   - Story 1 (foundation): Full Gherkin scenarios, detailed scope, clear boundaries
   - Middle stories: Moderate detail, key scenarios
   - Later stories (edge-cases): Rougher acceptance criteria, acknowledged to be refined later
6. Include dependency graph (blockedBy/blocks between story sequences)
7. Write definition of done per story (3-5 product-level completion conditions —
   NOT generic team DoD items like "code reviewed"). These are story-specific:
   "user can do X", "error Y returned when Z". Use DoD as inter-story coherence check:
   Story N's DoD must be consistent with Story N+1's starting assumptions.
8. Mark QA Gherkin scenarios with a note in the surrounding feedback:
   "Draft — to be refined by create-acceptance-tests skill"
9. Map teams from repository research + user confirmation
10. Omit operational fields (assignee, sprint, status) —
    those belong to sprint planning, not shaping
11. **Emit `recommended_skills[]` per sub-task** (backward-compatible — see below)
12. **Emit taxonomic labels into `stories[].labels[]`** where `decompose` has an
    authoritative source of truth (see Step 7.12 below)

**MANDATORY: Load @references/stories-json-schema.md during this step. Do NOT load before Step 7.**

#### Step 7.11 — recommended_skills[] emission (agent-skill-routing #146)

After writing all sub-tasks for a story, enrich each sub-task with skill recommendations
from `plugins/makato-plan/config/task-skill-map.json`:

```
task_skill_map = load("plugins/makato-plan/config/task-skill-map.json")

for each sub_task in story.sub_tasks:
    matched_skills = []
    for archetype, skills in task_skill_map.items():
        if archetype starts with "_":        # skip comment keys
            continue
        if archetype.lower() is a case-insensitive substring of
           (sub_task.title + " " + sub_task.description).lower():
            matched_skills.extend(skills)
    deduplicate matched_skills (preserve first-occurrence order)
    if matched_skills is non-empty:
        sub_task["recommended_skills"] = deduplicated list
    # if no match: omit the field entirely — do NOT add an empty array.
    # Callers check `if "recommended_skills" in sub_task` (presence check, not truthiness).
```

**Backward-compatibility guarantee**: when `task-skill-map.json` is absent or cannot be
read, skip the lookup silently — produce `stories.json` without `recommended_skills` fields
and do NOT raise an error. Downstream consumers (`build-refine`, `coder`) treat
`recommended_skills` as optional.

#### Step 7.12 — taxonomic label emission (#272)

`decompose` writes taxonomy-prefixed labels into each story's `labels[]` **only where it
holds an authoritative source of truth** — so the downstream `to-issues` consumer
(v3.6.0+) can honor them directly instead of guessing from story text. `to-issues` resolves
`type:` (and the prioritization dimensions) with an **explicit-label-wins** precedence; the
prefixes emitted here are that explicit source. Without this emission, `to-issues` falls back
to a text heuristic that misfires on dense engineering prose (the #272 motivation).

Emit, per story, into `stories[].labels[]` (always alongside the mandatory `"makato"`):

1. **`type:<feat|fix|test|chore|docs>` — always.** `decompose` authors each story's scope and
   intent, so it knows the type reliably (the heuristic does not). Choose the value from the
   story's intent:
   - `type:feat` — new capability / user-facing outcome (the default for a normal slice).
   - `type:fix` — the story corrects a defect or regression.
   - `type:test` — the story's deliverable is test coverage / a test harness itself.
   - `type:chore` — build/CI/deps/tooling with no user-facing behavior change.
   - `type:docs` — documentation is the deliverable.
   The value MUST be in the `type:` enum documented in
   `../to-issues/references/label-taxonomy.md` (`## Type Inference Table`). This is the main win.
2. **`severity:` / `priority:` — only when the Three Amigos simulation (Step 5, Dev Lead risk
   challenge) actually produced them.** Do NOT invent values: for a routine feature story,
   severity/priority are typically N/A — omit them. Emit only the concrete value the review
   assigned (enum per `label-taxonomy.md` `## Prioritization Dimensions`).
3. **`effort:` — optional**, only when the Three Amigos assigned a t-shirt size (`s`/`m`/`l`/`xl`).
   Omit otherwise.

**Deliberately NOT emitted** (to avoid drift / because another field or the consumer owns them):

- `tier:` — already carried by the typed `phase` field; `to-issues` copies `tier:` from there.
- `points:` — already carried by `storyPoints`; `to-issues` derives `points:` from it.
- `module:` — a repo-specific ADR folder-name match; `decompose` is generic and does not know
  the target repo's ADR structure. Left to `to-issues`.
- `tech:` — `decompose` does not reliably know the target stack; left to the `to-issues` text-match.
- `status:` — computed by `to-issues` from the dependency topo-sort / `future-enhancement`.

**Backward-compatibility**: emitting these prefixes is additive — a story's `labels[]` still
begins with `"makato"` and may still carry free-form tags. A `to-issues` version predating
#272 simply ignores an unrecognized `type:` label (it read `type:` from text only), so old and
new consumers both work.

---

### Step 8: Completeness Validation (Relaxed)

Not strict — some fields are intentionally rough at this stage.

**Mandatory at the epic level** (block if missing — these break publish):

- `epic.summary`
- `epic.objective` (one-line, captured in Step 4 Round 3)
- `epic.labels`

**Mandatory per story** (flag if missing):

- summary
- background
- scope
- phase
- teams (at least 1)
- `storyPoints` present AND value is a valid Fibonacci (1, 2, 3, 5, 8, or 13) AND value ≤ 13.
  **BLOCK** if absent, off-scale (e.g. 18, 21), or > 13.
- No unsplit story may have `storyPoints` > 13. If one does AND no blocking error from the
  Step 3 sizing gate was recorded for it, synthesize a blocking error here:
  `BLOCK: story <n> storyPoints=<x> exceeds hard cap of 13 with no safe split recorded`.

**Expected but can be rough** (warn but don't block):

- At least 1 successScenario (high-level, not exhaustive —
  populated from qa-reviewer drafts in Step 7.4; warn if a story has none)
- definitionOfDone (at least 2 product-level conditions)
- A `type:` label in `stories[].labels[]` (#272) — Step 7.12 emits one per story; warn (do
  NOT block) if a story is missing it, since `to-issues` can still fall back to its text
  heuristic. Warning: `story <n> has no type: label — to-issues will infer type from text`.

**Intentionally empty** (don't flag):

- solutionApproach (filled during refinement)
- acceptanceTestCases (filled by QAs downstream)
- wikiDocumentation (filled post-implementation)

**Display completeness summary**:

```text
Stories Completeness:
  - {N} stories fully specified
  - {N} stories with rough estimates (acceptable at this stage)
  - {N} fields intentionally deferred to refinement
```

---

### Step 9: Parked Questions Persistence

Write ALL unresolved questions from this session to `decisions.md` Open Questions table.

For EACH parked question:

- Append row with next sequential Q# ID
- Set "Raised In" to `decompose`
- Assign priority: High = blocks `to-issues`, Medium = resolve before implementation,
  Low = dev team decides
- Include notes: why the question was asked and what answering it unblocks

---

### Step 10: Final HTML Review & Approval

> **MAKATO_PLAN_NO_HTML guard**: Check `MAKATO_PLAN_NO_HTML` env var. If set, skip this HTML generation step entirely and proceed to Step 11.

Generate the definitive review HTML using `@templates/stories-final-review.html`
(distinct from three-amigos review in Step 6):

**Structure:**

- **Slide 1 (Board Overview)**: All stories in kanban-style 3-column board
  (foundation / happy-path / edge-cases).
  Each card: summary, SP, team(s), dependency indicators
- **Slides 2-N (One per story)**: Story rendered as a full card with ALL fields
  (Background, Scope, Feature Toggle, Success Scenarios, Out of Scope)
- **Final slide**: Dependency graph (stories as nodes, deps as edges) + summary stats
  (total SP, stories per phase, estimated PI fit)

Write to: `specs/{folder}/reviews/stories-final-review.html`

Open in browser and collect feedback. Same loop as other skills —
regenerate on feedback until approved.

---

### Step 11: Status & Handoff

1. Offer to mark decomposition as approved:

```yaml
AskUserQuestion:
  question: "Stories decomposition complete. Mark as Approved?"
  options:
    - "Yes — mark as Approved (Recommended)"
    - "Keep as Draft — I want to review more"
```

1. If approved: add `"status": "approved"` to stories.json header.

1. Display completion with next-step routing:

```text
Stories Created: specs/{folder}/stories.json
Total Stories: {N} ({N} foundation, {N} happy-path, {N} edge-cases)
Total Story Points: {sum}
Dependencies: {N} inter-story, {N} external

Next steps:
  - /create-acceptance-tests — refine Gherkin scenarios into polished test cases
  - /to-issues — create GitHub Issues from the shaped stories
  - /stress-test-artifact — stress-test the decomposition independently
```
