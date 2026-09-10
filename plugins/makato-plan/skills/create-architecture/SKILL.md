---
name: create-architecture
description: >-
  Create Architecture Design Documents from PRD output — architecture, technical
  design, system context, component design, API design, data model, security,
  deployment, test strategy. Use after PRD is approved.
version: "1.0.6"
modelRole: plan
argument-hint: "[slug]"
allowed-tools: Bash
metadata:
  last_updated: "2026-08-05"
---

# Create Architecture

Create an Architecture Design Document from PRD artifacts.
Pure document output — captures HOW we build it with system context, component design,
technical decisions, and operational strategy. No external side-effects.

## When to Use

- After PRD is complete (ideally Approved)
- Need to define the technical approach before decomposing into stories
- Want structured architecture document with decisions, trade-offs, and implementation
  strategy

## When NOT to Use

- No PRD exists yet (run create-prd first)
- Feature is trivial (single-file change with no architectural impact)
- Already have a design.md and want to decompose into stories (use decompose skill)
- Want to create implementation tasks or stories (that's the decompose skill)
- Want to create GitHub Issues or publish externally (use /to-issues downstream)

---

## Anti-Patterns

These failure modes are non-obvious and only experience teaches them. Claude MUST NOT do any of the following.

**NEVER accept "we'll figure it out later" for core architectural paths.**
WHY: service boundaries, auth mechanisms, and data models are the decisions that force rework late in delivery. An unanswered question on a critical path is not deferred risk — it is hidden cost. Push back explicitly: "Is this a critical path? If yes, decide now or park as a High-priority Q# that blocks decompose." Defer only peripherals (e.g., exact alerting thresholds, log retention policies).

**NEVER write a design.md section using AI-inferred content without flagging it.**
WHY: design.md is the authoritative technical contract consumed by build-refine. A plausible-sounding but inferred technology choice (e.g., "Redis for caching") that contradicts the team's actual infrastructure creates a false contract — developers implement against a fiction and discover the mismatch during integration, not shaping. Every section must trace to interview answer, PRD requirement, or context-scout finding. If no source exists, mark `[PENDING: Q#]`.

**NEVER accept vague architecture vocabulary without demanding concrete specifics.**
WHY: "microservices", "cache", "event-driven", and "scalable" each describe at least a dozen incompatible designs. Accepting them produces a design doc that reads coherent but makes no real decisions. The doc-writer agent will then fabricate specifics to fill the void, compounding the problem. Push back on every vague term — see `references/architecture-quality.md` for the push-back question per pattern.

**NEVER duplicate PRD requirements in the design doc.**
WHY: any PRD content copied into design.md creates two canonical sources. When the PRD is updated (common during refinement), the design doc silently drifts. The design doc's job is to say HOW — it references PRD requirements by implication ("NFR: page load <2s → CDN + edge caching + lazy loading"). If you're writing a requirement, it belongs in the PRD; if you find implementation detail in the PRD, move it here.

**NEVER approve a design with critical sections still `[PENDING: Q#]`.**
WHY: security, data model, and component design are the three sections that every downstream story depends on. Approving with a pending auth mechanism means every security story is blocked the moment development starts. Step 9 enforces this gate — it is not advisory.

**NEVER re-run all interview rounds when in Refine mode.**
WHY: re-interviewing on an update erases the user's existing answers and creates a full replacement instead of a delta. In Refine mode (Step 1.4), enter with the existing design loaded, ask only "what changed", and preserve untouched sections byte-for-byte per `shared/refinement-contract.md`. A refinement that inadvertently reverts a prior decision is harder to detect than a gap in a fresh document.

**NEVER downgrade this skill's model to sonnet to save tokens.**
WHY: the architecture interview drives multi-round synthesis across all three interview rounds plus grill output. Sonnet produces shallower follow-ups and misses coupling concerns that only emerge from connecting answers across rounds. The model selection is governed by AGENTS.md — change it only via a quality experiment.

---

## Constants

- **CONTEXT_SCOUT_TOKEN_BUDGET: 2000** — Maximum tokens returned by a single context-scout dispatch.

---

## Workflow

### Step 1: Resolve Spec Folder & Load Artifacts

#### 1.1: Resolve Spec Folder

From the argument (slug) or auto-detect the most recently modified `specs/*/` folder.

```text
Args: /create-architecture [slug]
Examples:
  /create-architecture checkout-redesign    → use specs/checkout-redesign/
  /create-architecture                      → auto-detect most recently modified specs/ folder
```

If no spec folder found, inform the user and suggest running brainstorming +
create-prd first.

#### 1.2: Load Required Artifacts

Read from the resolved spec folder:

1. **`prd.md`** (required) — the "what" and "why" that drives architectural decisions
2. **`decisions.md`** — cross-session continuity, existing decisions from brainstorming
   and PRD phases
3. **`repositories.yml`** — if already identified (from PRD phase or earlier).
   See plan: read `shared/repositories-yml-schema.md` now only if `repositories.yml`
   exists and needs schema validation — Do NOT load if no repo file is present yet.
4. **`reference/`** folder — catalogue file names and types only (architecture diagrams, T-shirt sizings, API specs, DB schemas). **Do not load their content yet — catalogue file names and types only. Conversion is eager; loading is lazy.**

**Missing PRD handling**: If `prd.md` is absent or still in Draft status:

```text
AskUserQuestion:
  question: "PRD is missing or still in Draft. Architecture should build on an
    approved PRD. How to proceed?"
  options:
    - "Run create-prd first (Recommended)"
    - "Continue anyway — I'll provide technical context directly"
```

If `reference/original/` contains unconverted files (PPTX, PDF), use `markitdown`
MCP to convert them to markdown in `reference/`.

#### 1.3: Open Questions Startup Check

If `decisions.md` exists and the Open Questions table has entries with Priority "High"
or raised in a prior architecture session:

```text
AskUserQuestion:
  question: "Found {N} open question(s) from prior sessions. Revisit before continuing?"
  options:
    - "Revisit now — address open questions first (Recommended)"
    - "Continue — I'll address them later"
```

If "Revisit now": present up to 4 open questions ordered by priority (High first).
Record answers — resolved questions move to Decision Details in decisions.md.

#### 1.4: Detect Update Mode

If `design.md` already exists in the spec folder:

```text
AskUserQuestion:
  question: "Architecture design already exists. What would you like to do?"
  options:
    - "Refine — update the existing design"
    - "Start fresh — replace with new design"
```

If "Refine": load existing design, display current content summary (components, key
decisions, status). Enter refinement flow — ask what changed (new constraint, revised
approach, additional component), preserve unchanged content.
Read `shared/refinement-contract.md` now (Do NOT load outside Refine mode — it
applies only when design.md already exists) and apply its rules (enumerate change
candidates, preserve untouched sections byte-for-byte, surface AI-inferred changes
for approval, emit a `changes[]` summary).

---

### Step 2: Repository Identification & Codebase Research

#### 2.1: Confirm and Expand Repositories

Always ask about repositories, even if `repositories.yml` exists from the PRD phase.
Architects identify repos the PO may not have known about.

**If repos exist**: "PRD identified {repos}. From a technical perspective, are there
additional repositories affected? Think about: shared libraries, infrastructure repos,
deployment configs, data pipelines. Any to remove?"

**If no repos**: "Which repositories does this feature affect? Consider: data layer,
API layer, UI, shared libraries, infrastructure, deployment."

Store confirmed + expanded list for `repositories.yml` output.

#### 2.2: Codebase Research

Spawn the `context-scout` agent per identified repository. Research focus for
architecture:

- Existing architecture patterns and conventions (how similar features are built)
- Integration points, service boundaries, middleware layers
- Data models, API contracts, authentication patterns
- Technology constraints (frameworks, libraries, platform mandates)
- Deployment topology and infrastructure patterns

If no `context/` directory exists for a repo, skip silently for that repo.

Display brief summary:

> Research complete: {N} repositories scanned. Key findings:
> {architecture patterns, constraints, integration points}

---

### Step 3: Architecture Interview

MANDATORY: Load @references/interview-rounds.md now for the full question bank.
Do NOT load it before this step — it is unused during artifact setup and validation.

Comprehensive interview targeting lead architects and team architects. Every design.md
section MUST trace back to either (a) a direct interview answer, (b) PRD content, or
(c) confirmed context-scout findings.
The AI MUST NOT generate content for a section without explicit input.

Conduct the three rounds in `references/interview-rounds.md` in order (System Context,
Design Decisions, Operations). All rounds always run; Round 3 depth varies by scope.

**Round 1 (System Context):** Before asking Round 1 questions, load any architecture diagrams and system context documents catalogued from `reference/` in Step 1.2 — these inform integration point and boundary questions.

**Round 2 (Design Decisions):** Before asking Round 2 questions, load any API specs, DB schemas, and T-shirt sizing documents catalogued from `reference/` in Step 1.2 — these ground technical decision questions in existing constraints.

**Round 3 (Operations):** Before asking Round 3 questions, load any deployment specs and infrastructure documents catalogued from `reference/` in Step 1.2 — these surface operational constraints and SLA baselines.

#### Expert Heuristics (non-obvious practitioner rules applied across all rounds)

**Reject vague architecture vocabulary immediately — do not record it as an answer.**
"Microservices", "cache", "event-driven", "scalable" describe incompatible designs.
Accepting them produces a design doc that reads coherent but decides nothing.
Push back inline: see `references/architecture-quality.md` Anti-Patterns table for the
exact push-back question per vague term. Only record a concrete answer.

**Cross-round connection: link Round 2 decisions back to Round 1 constraints.**
A technical decision (e.g., "use Kafka for events") not grounded in a Round 1 constraint
or integration point is a free-floating choice the grill will tear apart. After each Round
2 answer, check: "Does this trace to a constraint, integration point, or PRD NFR?"
If not, ask what drives the choice before recording it.

**Security is mandatory regardless of how the architect frames the feature.**
Every feature has an auth mechanism, a data sensitivity classification, and at least
one compliance angle from the PRD NFRs. If the architect says "no special security
requirements", probe the data model and user roles — they will reveal requirements.

#### Parking Unanswerable Questions

When the architect says "I don't know", "need to check with {person}", or
"depends on X":

1. Acknowledge: "Good question — let's park that for now."
2. Assign sequential ID (Q#) continuing from any existing Qs in decisions.md.
3. Note the question with context: what answering it unblocks.
4. Continue without dwelling.

**For critical architectural paths (core data model, service boundaries, auth
mechanism): reject "we'll figure it out later".** Either decide now or park as
High-priority open question that blocks the next phase. The distinction matters:
peripherals (exact alerting thresholds, log retention) are safe to defer; structural
elements are not — a pending auth model makes every security story in decompose
un-refinable.

If a parked question leaves a design.md section empty, mark it `[PENDING: Q#]`.

---

### Step 4: Decision Stress-Test (Grill)

Before committing architectural decisions to a design document, offer to stress-test
them.

```text
AskUserQuestion:
  question: "I recommend stress-testing your architecture decisions before writing
    the design doc. Shall I grill you?"
  options:
    - "Yes — challenge my technical decisions (Recommended)"
    - "Skip — I'm confident, proceed to design doc"
```

If accepted, invoke `/stress-test-artifact` scoped to the current spec folder. The grill targets
architectural decisions focusing on:

- Missed integration points and failure modes
- Scalability gaps and bottlenecks
- Security blind spots
- Deployment and rollback risks
- Coupling concerns and single points of failure
- Over-engineering vs. under-engineering trade-offs
- Missing fallback strategies

After the grill completes, its findings are written back into `decisions.md`. These
feed directly into design document generation.

---

### Step 5: Design Document Generation

Dispatch the `doc-writer` agent to write `specs/{folder}/design.md`.

MANDATORY: Load @references/architecture-quality.md now (decision format, NFR mapping rules,
anti-patterns, required sections, boundary rule). Do NOT load before Step 5 — it is
irrelevant during the interview and would inflate context for no gain.

Pass to the doc-writer:

- PRD content (goals, NFRs, scope, story sketches — for context and NFR mapping)
- Interview results (all 3 rounds)
- Grill decisions (resolved and referenced by ID)
- Codebase research findings (patterns, constraints, existing architecture)
- Technical reference documents (converted attachments from reference/)
- Template: load `templates/design-template.md`

**Key principle**: The design doc implements the PRD's "what" with "how". Reference
prd.md for requirements; do not repeat PRD content in the design doc.

**Decision references**: The design doc references `decisions.md` entries by ID where
they influence architecture (e.g., "Per D7: REST chosen over GraphQL due to team
expertise"). Never duplicate decision content.

**NFR implementation mapping**: For each NFR in the PRD (the "what"), the design doc
specifies the concrete technical approach (the "how"). Every NFR must map to a
specific implementation — do not include an NFR implementation without tracing it to
a PRD requirement. Example: PRD says "99.9% uptime" → design says "multi-AZ
deployment + health checks + auto-scaling + circuit breakers".

**New decisions**: Append architecture decisions made during this session to
`decisions.md` with category "Architecture" and the current date.

**Output**: `specs/{folder}/design.md` + updated `decisions.md` +
`repositories.yml` (confirmed/expanded)

---

### Step 6: Completeness Validation

Before presenting the HTML review, validate that every design.md section contains
real user-provided content — not AI assumptions.

#### 6.1: Section Scan

For each design.md section, check its data source:

- **User-confirmed**: content came from interview answer, PRD, or context-scout
  findings ✓
- **Pending**: marked `[PENDING: Q#]` — parked question, awaiting answer
- **Empty**: section was not applicable for this feature — omitted ✓
- **AI-assumed**: content was generated without explicit input ✗

#### 6.2: Flag Assumptions

If any section contains AI-assumed content:

```text
AskUserQuestion:
  question: "I found {N} section(s) where I filled in content based on inference,
    not your direct input. Review each:"
  (For each flagged section, show the assumed content and ask:)
  options:
    - "Confirm — this is accurate"
    - "Correct — I'll provide the right answer"
    - "Remove — park as open question instead"
```

For each "Correct" response: ask the clarifying question and update the design.
For each "Remove" response: replace with `[PENDING: Q#]` and add to open questions.

If multiple sections are AI-assumed, it means the interview missed those topics.
Consider going back to ask targeted follow-up questions rather than accepting
assumptions.

#### 6.3: Completeness Summary

Display:

```text
Design Doc Completeness:
  • {N} sections confirmed ✓
  • {N} sections pending (open questions)
  • {N} sections not applicable (omitted)
```

---

### Step 7: Parked Questions Persistence

Write ALL unresolved questions from this session to `decisions.md` Open Questions
table.

For EACH parked question (zero silent loss):

- Append row with next sequential Q# ID
- Set "Raised In" to `create-architecture`
- Assign priority: High = blocks decompose phase, Medium = resolve before
  implementation starts, Low = dev team can decide during refinement
- Include notes: why the question was asked and what answering it unblocks

---

### Step 8: HTML Review & Approval

Dispatch the `doc-writer` agent to generate an interactive HTML review.

Include in the prompt:

- **MODE**: html-review
- **TEMPLATE_PATH**: the absolute path to `templates/design-review.html`
- **OUTPUT_PATH**: `specs/{folder}/reviews/design-review.html`
- **CONTENT**: structured design results including:
  - feature_name, date, slug
  - system_context (boundaries, external systems, data exchanges)
  - component_design (breakdown, communication, responsibilities)
  - technical_decisions (options/rationale table per decision)
  - data_model (entities, relationships, storage)
  - api_design (endpoints, auth, errors, versioning)
  - security (authn, authz, encryption, compliance mapping)
  - performance (NFR implementation, caching, bottleneck mitigation)
  - deployment (strategy, environments, rollback, infra)
  - observability (monitoring, alerting, logging, tracing)
  - test_strategy (types, coverage, critical scenarios)
  - migration (data migration, backwards compat, rollback steps)
  - decisions_referenced (which D# entries the design relies on)
  - open_questions (parked items)
- **CHANGE_MODE** (update mode only): include `changes` array marking each modified
  section

#### 8.1: Change Highlighting (Update Mode)

When in update/refine mode (Step 1.4 detected existing design):

| Change type | Visual treatment | CSS class |
|-------------|-----------------|-----------|
| `added` | Green left border + "NEW" badge | `.change-added` |
| `modified` | Amber left border + "CHANGED" badge | `.change-modified` |
| `removed` | Red strikethrough + "REMOVED" badge | `.change-removed` |
| (unchanged) | No decoration | (none) |

For **first-time creation**: skip change highlighting — all content is new.

Open in browser (use the command for the user's OS):

```bash
open specs/{folder}/reviews/design-review.html        # macOS
xdg-open specs/{folder}/reviews/design-review.html    # Linux
start specs/{folder}/reviews/design-review.html       # Windows
```

Tell the user:

> "Architecture review is open in your browser. Check system context, technical
> decisions, and NFR implementation mapping. Add comments in each section and click
> 'Copy Feedback' when done."

In update mode, additionally say:

> "Changed sections are highlighted — green for new, amber for modifications,
> red for removals."

**If revisions requested**: parse feedback, adjust design.md, re-dispatch doc-writer
for updated review.
**If approved**: proceed to Step 9.

---

### Step 9: Status & Handoff

Offer to mark design status:

```text
AskUserQuestion:
  question: "Architecture design complete. Mark as Approved?"
  options:
    - "Yes — mark as Approved (Recommended)"
    - "Keep as Draft — I want to review more"
```

If approved: replace `**Status**: Draft` with `**Status**: Approved` in design.md.
Block approval if critical sections (security, data model, component design) are still
`[PENDING: Q#]`.

Display completion with next-step routing:

```text
Architecture Design Created: specs/{folder}/design.md
Technical Decisions: {N} decisions documented
Repositories: {repos confirmed}

Next steps based on feature characteristics:
  • UI feature → /create-prototype (visual/UX validation)
  • No UI or prototype done → /decompose (story slicing — planned)
  • Additional review → /stress-test-artifact (stress-test the design independently)
```
