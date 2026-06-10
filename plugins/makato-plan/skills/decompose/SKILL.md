---
name: decompose
description: >-
  Decompose pland features into vertically-sliced stories with acceptance
  criteria — decompose, vertical slice, story slicing, break down feature,
  split into stories. Use after PRD and architecture are approved.
version: "1.1.1"
model: opus
argument-hint: "[slug]"
---

# Decompose

Decompose a pland feature into vertically-sliced stories with acceptance criteria.
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
- Want to create GitHub Issues (that's the publish skill downstream)
- Want detailed implementation tasks (that's dev team refinement — shaping boundary)

---

## Workflow

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

#### 2.2: Map Repositories to Teams

Load @references/team-repository-mapping.md

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
5. Apply the 9 splitting patterns — look for hidden slices:
   - Business rule variations not captured
   - Data variations that warrant separate stories
   - Error handling flows
   - Admin/config/setup stories
   - Data migration needs
6. Identify external dependencies per story → drives phase assignment.
   Phase 1 must contain only stories with no external blockers — own code first.
7. Propose initial story list with phase assignments.
   Let feature scope determine story count — do not target a fixed number.

Every story must be a vertical slice delivering a user outcome across layers.
Reject any story scoped to a single layer or single repository.

Load @references/vertical-slicing-rules.md during this step.
Load @references/phase-assignment-rules.md during this step.

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
   > (Stakeholder-facing — appears in handoff.md and optionally as the GitHub epic
   > tracking issue title.)"

The objective is mandatory — `publish` validates its presence and the template renders it.
Do not let the user skip this round.

**Parking unanswerable questions**: When the user says "I don't know" or
"we'd need to check with {person}":

1. Acknowledge: "Good question — let's park that for now."
2. Assign sequential ID (Q#) continuing from any existing Qs in decisions.md.
3. Note the question with minimal context.
4. Continue without dwelling.

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

Load @references/stories-json-schema.md during this step.
Load @references/dcp-story-template.md for rendering guidance.

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

**Expected but can be rough** (warn but don't block):

- storyPoints (rough estimate is fine)
- At least 1 successScenario (high-level, not exhaustive —
  populated from qa-reviewer drafts in Step 7.4; warn if a story has none)
- definitionOfDone (at least 2 product-level conditions)

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
- Assign priority: High = blocks publish, Medium = resolve before implementation,
  Low = dev team decides
- Include notes: why the question was asked and what answering it unblocks

---

### Step 10: Final HTML Review & Approval

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
  - /publish — create handoff.md, story folders, and optionally GitHub Issues
  - /grill — stress-test the decomposition independently
```
