---
name: create-prd
description: Create Product Requirements Documents from brainstorming output — PRD, requirements, product requirements, feature requirements, user stories, acceptance criteria. Use after brainstorming and grilling.
version: "1.0.5"
model: opus
argument-hint: "[ITDB-KEY]"
---

# Create PRD

Create a Product Requirements Document from brainstorming artifacts. Pure document output — captures WHAT and WHY with rough vertical story sketches. No Jira or Confluence side-effects.

## When to Use

- After brainstorming and grilling are complete for an ITDB feature
- Need to formalize requirements before architecture or decomposition
- Want structured PRD with success metrics, scope, and story sketches

## When NOT to Use

- No brainstorming done yet (run brainstorming first)
- Feature is purely technical with no user-facing outcome (use a technical spec instead)
- Already have a PRD and want to decompose into stories (use decomposition skill)
- Want to create Jira issues (use publish skills downstream)
- Want to publish to Confluence (use publish skills downstream)

---

## Workflow

### Step 1: Resolve Spec Folder & Load Artifacts

#### 1.1: Resolve Spec Folder

From the argument (ITDB key) or auto-detect the most recently modified `specs/{ITDB-KEY}-*/` folder. The folder already exists — it was created during the brainstorming phase (named `specs/{ITDB-KEY}-{slug}/`).

```
Args: /create-prd [ITDB-KEY]
Examples:
  /create-prd ITDB-1234    → use specs/ITDB-1234-*/  (prefix match, pick most recently modified)
  /create-prd              → auto-detect most recently modified specs/ folder
```

If no spec folder found, inform the user and suggest running brainstorming first.

#### 1.2: Load Brainstorming Artifacts

Read from the resolved spec folder:

1. **`brainstorm.md`** — selected approach, rejected alternatives, edge cases, convergence rationale
2. **`decisions.md`** — resolved decisions and open questions

These are the primary input. No ITDB re-import needed — brainstorming already imported the ticket, attachments, and context.

**Missing artifact handling**: If `brainstorm.md` is absent:

```
AskUserQuestion:
  question: "No brainstorm.md found. Brainstorming normally precedes PRD. How to proceed?"
  options:
    - "Run brainstorming first (Recommended)"
    - "Continue without brainstorm — I'll provide context directly"
```

If `decisions.md` is absent, skip silently (may not exist for simple features).

#### 1.3: Open Questions Startup Check

If `decisions.md` exists and the Open Questions table has entries:

```
AskUserQuestion:
  question: "Found {N} open question(s) from prior sessions. Revisit before continuing?"
  options:
    - "Revisit now — address open questions first (Recommended)"
    - "Continue — I'll address them later"
```

If "Revisit now": present up to 4 open questions ordered by priority (High first). For each, ask how the user wants to address it. Record answers — resolved questions move to Decision Details in decisions.md.

#### 1.4: Detect Update Mode

If `prd.md` already exists in the spec folder:

```
AskUserQuestion:
  question: "PRD already exists. What would you like to do?"
  options:
    - "Refine — update the existing PRD"
    - "Start fresh — replace with new PRD"
```

If "Refine": load existing PRD, display current content summary (problem, story count, status). Enter refinement flow — ask what to change (scope, stories, metrics, priorities), preserve unchanged content, increment revision metadata. Read `shared/refinement-contract.md` and apply its rules (enumerate change candidates, preserve untouched sections byte-for-byte, surface AI-inferred changes for approval, emit a `changes[]` summary).

---

### Step 2: Repository Identification & Research

#### 2.1: Identify Repositories

Check if `specs/{folder}/repositories.yml` exists (may have been set in a prior phase).

**If found**: load and confirm with user ("Feature affects {repos}. Still correct?").

**If not found**: ask the user which repositories this feature affects:

```
AskUserQuestion:
  question: "Which repositories does this feature affect?"
  header: "Repos"
  options:
    - "I'll type the repo names (use Other)"
    - "Skip — determine later"
```

If repos provided, store as session variable. After PRD generation (Step 5.2), write `specs/{folder}/repositories.yml` using the plan defined in `shared/repositories-yml-schema.md` (read it first):

```yaml
version: "1.0"
affected:
  - name: repo-name
    role: primary
  - name: other-repo
    role: supporting
```

#### 2.2: Codebase Research

Spawn the `context-scout` agent with the feature summary and keywords from brainstorm.md. The agent scans `context/{repo}/` directories and returns synthesized findings — constraints, existing patterns, architectural decisions.

If no `context/` directory exists, skip silently.

Display brief summary:
> Research complete: {N} relevant areas found. Key patterns: {summary}

---

### Step 3: Product Strategy Interview

This is NOT gap-filling from the brainstorm. This is product strategy — sharpening commitments that the brainstorm explored but didn't finalize.

The interview is structured in rounds. Every PRD section MUST trace back to either (a) a direct user answer from the interview, or (b) content from brainstorm.md/decisions.md that the user already confirmed. The AI MUST NOT generate content for a section without explicit user input.

#### Round 1 — Core Strategy (always ask)

- **Success criteria** — 3-5 measurable KPIs. Reject vague qualifiers: "What does 'fast' mean? Give me a number." / "What does 'easy to use' mean? Give me a testable condition." Never accept "fast", "easy to use", or "intuitive" without measurable thresholds.
- **Scope boundaries** — explicit In-Scope list AND Non-Goals section (mandatory — undefined boundaries cause scope creep). "What are we explicitly NOT building?"
- **User personas** — who benefits, what's their primary need. Sharpen from brainstorm's broad categories into concrete persona descriptions.
- **Priority** — critical/high/medium/low with rationale for the choice.
- **Phased rollout** — what's MVP vs. enrichment? Use dependency-based phases (Phase 1 enables Phase 2), NEVER time-based ("Sprint 1", "Q3").
- **UI scope** — Yes (UI feature) / Minimal UI / No (backend only).

#### Round 2 — Context & Ownership (always ask)

- **Background & Context** — "Why are we building this NOW? What's the market driver, customer signal, or strategic initiative?" Distill from brainstorm if available, but confirm with user. 3-5 sentences max.
- **Stakeholders** — "Who is the lead PO? Who is responsible for delivery? Who is the business owner?" Named people, not generic titles. These own the PRD sign-off and decisions.
- **Constraints** — hard product-level limits. "What's non-negotiable? Budget ceiling, regulatory deadline, team size, platform mandates, data residency?" NOT technical constraints (those go in architecture doc).
- **Dependencies** — "What are we waiting on or need from other teams?"

#### Round 3 — Conditional (ask based on feature characteristics)

| Topic | Trigger Condition | Minimum Data Required |
|-------|-------------------|----------------------|
| **Assumptions** | Always (after constraints) | At least 1 believed-true condition with validation method |
| **User Journeys** | UI Required = Yes or Minimal | 1-2 end-to-end narratives with decision points |
| **Non-Functional Reqs** | Compliance, accessibility, i18n, or perf flagged | Category + target per relevant area |
| **Definition of Done** | Always | 3-5 conditions that signal "the whole feature can ship" |

**Assumptions**: "What are we believing to be true that we haven't verified? What happens if we're wrong?" Each assumption needs: the belief, how to validate it, and the makato if wrong.

**User Journeys** (UI features only): "Walk me through the main flow end-to-end. Where does the user start? What decisions do they make? Where do they end up?" 1-2 narratives with decision points and edge case notes.

**Non-Functional Requirements** (when triggered): "What quality targets must this feature meet? Accessibility standard? Performance from the user's perspective? Language support? Compliance mandates?" These are PRODUCT decisions that plan scope and cost. The implementation approach goes in the architecture doc.

**Definition of Done**: "What must be true for the ENTIRE feature to be considered shippable? Not per-story — the overall completion gate." Push for testable conditions. If the user can't answer yet, park as open questions but note that PRD cannot be Approved without a Definition of Done.

#### Parking Unanswerable Questions

When the user says "I don't know" or "we'd need to check with {person}":
1. Acknowledge: "Good question — let's park that for now."
2. Assign sequential ID (Q1, Q2, Q3...) continuing from any existing Qs in decisions.md.
3. Note the question with minimal context.
4. Continue without dwelling.

If a parked question leaves a PRD section empty, mark it `[PENDING: Q#]` — the section stays in the PRD but is clearly flagged as incomplete.

---

### Step 4: Decision Stress-Test (Grill) — REQUIRED CHECKPOINT

Do NOT proceed to Step 5 without running this checkpoint. This step is mandatory after Round 3 completes.

```
AskUserQuestion:
  question: "Stress-test your decisions with /grill before writing the PRD?"
  options:
    - "Yes — challenge my assumptions (Recommended)"
    - "Skip — proceed to PRD"
```

If "Yes": invoke `/grill` scoped to the current spec folder. The grill targets `brainstorm.md` and `decisions.md` — focusing on business behavior, scope, and user experience questions only (no technical implementation at this stage). After the grill completes, its findings are written back into `decisions.md`. These feed directly into PRD generation.

If "Skip": proceed to Step 5.

---

### Step 5: PRD Generation

#### 5.0: Interview Consolidation — REQUIRED CHECKPOINT

Do NOT proceed to story sketching without consolidating the interview. This step is mandatory after Step 4 completes.

The interview ran across multiple rounds. Later answers can contradict earlier ones, and a late answer may have unlocked an additional vertical slice that wasn't visible during sketching planning. Consolidate first — internal-only, not written to disk and not shown to the user — before story sketching reads from interview state.

Build a consolidated slot table covering ALL available slots from the interview, brainstorm, and grill. For each slot, record the latest authoritative value:

- **Priority** (Round 1)
- **UI scope** (Round 1)
- **User personas** (Round 1)
- **In-scope** (Round 1)
- **Non-goals** (Round 1)
- **Phased rollout** (Round 1)
- **Success metrics** (Round 1)
- **Background & Context** (Round 2)
- **Stakeholders** (Round 2)
- **Constraints** (Round 2)
- **Dependencies** (Round 2)
- **Assumptions** (Round 3)
- **User Journeys** (Round 3, if triggered)
- **Non-Functional Requirements** (Round 3, if triggered)
- **Definition of Done** (Round 3)
- **Open Questions** (parked across all rounds)

**Later wins.** When a later answer contradicts an earlier answer in the same slot, the later answer is authoritative. Drop the contradicted earlier answer from the slot. Append a row to `decisions.md` Decision Summary recording the superseded answer and the later answer that replaced it (audit trail).

**Grill > interview > brainstorm.** Apply the later-wins rule across sources too: grill findings supersede interview answers in the same slot; interview answers supersede brainstorm content in the same slot. Untouched brainstorm content survives — the HTML review (Step 8) is the gate where the user can flag anything that shouldn't carry forward.

**Re-evaluate story coverage.** With all slots consolidated, scan for late answers that materially changed scope, personas, or rollout. If a late answer suggests an additional vertical slice that the original direction didn't cover, add it to the sketching input for Step 5.1.

**Refine mode skip.** If Step 1.4 detected an existing PRD and the user chose "Refine", skip Step 5.0 — the existing PRD already reflects prior consolidation; refinement runs through `shared/refinement-contract.md` rules instead.

#### 5.1: Vertical Story Sketching

Based on interview + brainstorm + grill outcomes, sketch 3-5 rough vertical story ideas. Every story must be a vertical slice crossing technical layers — never slice by layer or repository.

Load @references/vertical-slicing.md

Each story sketch includes:
- **User outcome** — what can the user do after this ships?
- **Layers touched** — which technical boundaries it crosses (UI, API, DB, config, etc.)
- **Acceptance sketch** — 2-3 high-level conditions (NOT detailed criteria — those come during spec/decomposition)
- **Derived from** — slot references from the Step 5.0 consolidation that justify this slice (e.g., "Personas, In-scope, Phased rollout Phase 1"). Observable trace that consolidation actually informed sketching.

The first story is always the **walking skeleton** — thinnest end-to-end path. Subsequent stories enrich the skeleton.

These are rough ideas showing direction. They are NOT final artifacts — detailed acceptance criteria and refined stories come later.

#### 5.2: Write PRD

Dispatch the `doc-writer` agent to write `specs/{folder}/prd.md`.

Load @references/prd-quality.md

Pass to the doc-writer:
- Brainstorm findings (selected approach, rejected alternatives)
- Interview results (all rounds: strategy, context/ownership, conditional topics)
- Grill decisions (resolved and referenced by ID)
- Codebase research findings
- Vertical story sketches
- Repository list (for frontmatter)
- Template: load `templates/prd-template.md`
- Conditional section flags (which Round 3 sections apply based on feature characteristics)

**Decision references**: The PRD references `decisions.md` entries by ID where they influence scope or requirements (e.g., "Per D3: batch processing deferred to Phase 2"). Never duplicate decision content.

**Reconciliation already performed in Step 5.0** — do not re-apply. Source precedence (grill > interview > brainstorm) and audit logging to `decisions.md` happen in the consolidation checkpoint before sketching. Step 5.2 must not write additional audit rows for the same contradictions.

**Delivery Recommendations guidance** for the doc-writer — the template includes a Delivery Recommendations section. The doc-writer fills it using qualitative scope estimation:
- Cross-repository breadth (1 repo = likely small, 3+ = likely large)
- Dependency complexity (isolated feature vs. deep integration)
- Compliance flags (any compliance = at least Medium)
- Grill risk assessment (many unresolved risks = scale up)

**Output**: `specs/{folder}/prd.md`

After writing, also write `specs/{folder}/repositories.yml` if it didn't exist and repos were identified in Step 2.1.

---

### Step 6: Completeness Validation

Before presenting the HTML review, validate that every PRD section contains real user-provided content — not AI assumptions.

#### 6.1: Section Scan

For each PRD section, check its data source:
- **User-confirmed**: content came from a direct interview answer or brainstorm.md ✓
- **Pending**: marked `[PENDING: Q#]` — parked question, awaiting answer
- **Empty**: section was conditional and not triggered — omitted from PRD ✓
- **AI-assumed**: content was generated without explicit user input ✗

#### 6.2: Flag Assumptions

If any section contains AI-assumed content, present to the user:

```
AskUserQuestion:
  question: "I found {N} section(s) where I filled in content based on inference, not your direct input. Review each:"
  (For each flagged section, show the assumed content and ask:)
  options:
    - "Confirm — this is accurate"
    - "Correct — I'll provide the right answer"
    - "Remove — park as open question instead"
```

For each "Correct" response: ask the clarifying question and update the PRD.
For each "Remove" response: replace section content with `[PENDING: Q#]` and add to open questions.

#### 6.3: Completeness Summary

Display:
```
PRD Completeness:
  • {N} sections confirmed ✓
  • {N} sections pending (open questions)
  • {N} conditional sections skipped (not applicable)
```

If >3 sections are pending, warn: "This PRD has significant gaps. Consider addressing open questions before seeking approval."

---

### Step 7: Parked Questions Persistence

Write ALL unresolved questions from this session (including any new ones from Step 6) to `decisions.md` Open Questions table.

For EACH parked question (zero silent loss):
- Append row with next sequential Q# ID
- Set "Raised In" to `create-prd`
- Assign priority: High = blocks next phase, Medium = should resolve in architecture, Low = can defer
- Include notes: why the question was asked and what answering it unblocks

If `decisions.md` doesn't exist, create it using the template from the brainstorming skill's output format:

```markdown
# Decisions: {Feature Name}

**Last Updated**: {YYYY-MM-DD}
**Feature**: {ITDB-KEY} — {Feature Name}

---

## Decision Summary

| # | Decision | Chosen Option | Category | Phase | Date |
|---|----------|--------------|----------|-------|------|

---

## Open Questions

| # | Question | Raised In | Priority | Notes |
|---|----------|-----------|----------|-------|
```

---

### Step 8: HTML Review & Approval

Dispatch the `doc-writer` agent to generate an interactive HTML review.

Include in the prompt:
- **MODE**: html-review
- **TEMPLATE_PATH**: the absolute path to `templates/prd-review.html`
- **OUTPUT_PATH**: `specs/{folder}/reviews/prd-review.html`
- **CONTENT**: structured PRD results including:
  - feature_name, date, itdb_key
  - stakeholders (lead PO, implementation lead, business owner)
  - executive_summary (problem + background/why-now + solution)
  - success_metrics (KPIs table)
  - user_personas
  - story_sketches (rough vertical slices with outcomes)
  - user_journeys (end-to-end narratives, if applicable)
  - scope (in-scope + non-goals)
  - assumptions_and_constraints (assumptions table + constraints table)
  - non_functional_requirements (if applicable)
  - dependencies
  - risks_and_mitigations
  - phased_rollout (phases with exit criteria)
  - definition_of_done (overall completion gate)
  - delivery_recommendations (scope, epics, groupings)
  - decisions_referenced (which D# entries the PRD relies on)
  - open_questions (parked items)
- **CHANGE_MODE** (update mode only): include `changes` array marking each modified section

#### 8.1: Change Highlighting (Update Mode)

When in update/refine mode (Step 1.4 detected existing PRD), the HTML review MUST visually highlight what changed. Pass a `changes` array to the doc-writer with the change type for each content block:

| Change type | Visual treatment | CSS class |
|-------------|-----------------|-----------|
| `added` | Green left border + "NEW" badge | `.change-added` |
| `modified` | Amber left border + "CHANGED" badge | `.change-modified` |
| `removed` | Red strikethrough + "REMOVED" badge | `.change-removed` |
| (unchanged) | No decoration — rendered normally | (none) |

The doc-writer compares the previous PRD content (loaded in Step 1.4) against the new content and tags each section/field accordingly. At the top of the review, show a change summary:

```
Changes in this revision:
  • 2 sections modified (Scope, Delivery Recommendations)
  • 1 story sketch added (Story Sketch 4)
  • 1 non-goal removed
```

This ensures reviewers immediately see what's different without reading the entire PRD again.

For **first-time PRD creation** (not update mode): skip change highlighting entirely — all content is new by definition.

Open in browser (use the command for the user's OS):
```bash
open specs/{folder}/reviews/prd-review.html        # macOS
xdg-open specs/{folder}/reviews/prd-review.html    # Linux
start specs/{folder}/reviews/prd-review.html       # Windows
```

Tell the user:
> "PRD review is open in your browser. Check story sketches, scope boundaries, and delivery recommendations. Add comments in each section and click 'Copy Feedback' when done."

In update mode, additionally say:
> "Changed sections are highlighted — green for new content, amber for modifications, red strikethrough for removals."

**If revisions requested**: parse feedback, adjust PRD, re-dispatch doc-writer for updated review.
**If approved**: proceed to Step 9.

---

### Step 9: Status & Handoff

Offer to mark PRD status:

```
AskUserQuestion:
  question: "PRD complete. Mark as Approved?"
  options:
    - "Yes — mark as Approved (Recommended)"
    - "Keep as Draft — I want to review more"
```

If approved: replace `**Status**: Draft` with `**Status**: Approved` in prd.md. Block approval if Definition of Done is absent and no open question covers it.

Display completion with next-step routing:

```
PRD Created: specs/{folder}/prd.md
Story Sketches: {N} vertical slices outlined
Scope: {Small/Medium/Large}

Next steps:
  • Small scope → proceed to spec (skip design doc)
  • Medium scope → proceed to architecture design
  • Large/compliance → architecture + security review

Run /grill to stress-test the PRD before moving on.
```
