---
name: create-prototype
description: >-
  Create interactive HTML prototypes of new UI surfaces from PRD and architecture
  artifacts — prototype, mockup, UI preview, UX validation. Use after architecture
  design is complete for features with user-facing interfaces.
version: "1.0.2"
model: opus
argument-hint: "[slug]"
---

# Create Prototype

Create an interactive, high-fidelity HTML prototype of new UI surfaces from PRD and
architecture artifacts. Single self-contained HTML file with integrated review.
Pure visual/UX validation — no external side-effects.

## When to Use

- After architecture design is complete for a feature with user-facing interfaces
- Need to validate UX decisions before decomposing into stories
- Want stakeholders to click through the feature before committing to implementation
- PRD has `UI scope = Yes` or `Minimal` and user journeys are defined

## When NOT to Use

- No PRD or architecture exists yet (run create-prd and create-architecture first)
- Feature has no UI surfaces (skip to decompose)
- Feature is trivial UI (single button, config toggle — decompose directly)
- Want to validate technical architecture (that's the architecture skill or grill)
- Want to create GitHub Issues or publish externally (use /to-issues downstream)

---

## Workflow

### Step 1: Resolve Spec Folder & Load Artifacts

#### 1.1: Resolve Spec Folder

From the argument (slug) or auto-detect the most recently modified `specs/*/` folder.

```text
Args: /create-prototype [slug]
Examples:
  /create-prototype checkout-redesign    → use specs/checkout-redesign/
  /create-prototype                      → auto-detect most recently modified specs/ folder
```

If no spec folder found, inform the user and suggest running brainstorming +
create-prd + create-architecture first.

#### 1.2: Load Required Artifacts

Read from the resolved spec folder:

1. **`prd.md`** (required) — user journeys, story sketches, UI scope, personas,
   success metrics
2. **`design.md`** (required) — component design, data model, API endpoints,
   technical decisions

**Missing artifact handling**: If either is absent:

```text
AskUserQuestion:
  question: "PRD or architecture design is missing. Prototyping needs both to
    understand WHAT to build and HOW. Proceed?"
  options:
    - "Run the missing phase first (Recommended)"
    - "Continue — I'll provide context directly"
```

#### 1.3: Load Mandatory-If-Exists

These files are loaded whenever they exist (not optional — they contain cross-session
continuity):

1. **`decisions.md`** — prior decisions from brainstorming, PRD, and architecture
   phases (especially UX-related decisions)
2. **`repositories.yml`** — target repositories for design system research.
   See plan: read `shared/repositories-yml-schema.md`.

#### 1.4: Gate Check

If PRD indicates `UI scope = No` or contains no user journeys:

> "This feature has no user-facing UI surfaces. Prototyping won't add value.
> Proceed to `/decompose` instead."

Abort the skill.

#### 1.5: Detect Update Mode

If `prototype.html` already exists in the spec folder:

```text
AskUserQuestion:
  question: "Prototype already exists. What would you like to do?"
  options:
    - "Refine — update the existing prototype"
    - "Start fresh — replace with new prototype"
```

If "Refine": load existing prototype, ask what changed (new surface, interaction
tweak, styling update), preserve unchanged surfaces.
Read `shared/refinement-contract.md` and apply its rules (enumerate change candidates,
preserve untouched surfaces byte-for-byte, surface AI-inferred changes for approval,
emit a `changes[]` summary).

---

### Step 2: Design System Research

#### 2.1: Identify Target Repositories

If `repositories.yml` was loaded in Step 1.3, read the list of affected repositories.

If `repositories.yml` is absent, ask the user which repository contains the target
application's UI code:

```text
AskUserQuestion:
  question: "No repositories.yml found. Which repository contains the UI code for
    this feature?"
  options:
    - "Let me provide the repo path"
    - "Skip design system research — I'll describe the design system in the interview"
```

If skipped, proceed directly to Step 3 (UX Interview) with no design tokens.

#### 2.2: Spawn Context-Scout for Design System Discovery

Spawn the `context-scout` agent per repository with a design-system-focused search
brief.

Read `references/design-system-extraction.md` and pass its content to the
context-scout as additional search focus. The scout looks for:

- Design tokens (colors, spacing, typography, radii, shadows, motion)
- Component patterns (buttons, forms, modals, navigation, tables, cards)
- Layout conventions (grid system, sidebar patterns, responsive breakpoints)
- External design system references (package.json dependencies pointing to shared
  design systems like Glow, imports/requires of component libraries)

#### 2.3: Synthesize Design Context

From context-scout findings, build a design context summary:

- **Token map**: key colors, spacing scale, typography stack, border-radii, shadows
- **Component inventory**: which components exist that the prototype can reuse
  patterns from
- **External DS identified**: name and version of any shared design system
  (e.g., "Glow 3.x")

When design system tokens are available, use them exclusively. Never fall back to
generic framework defaults (Bootstrap, Material Design) if real tokens exist.

#### 2.4: External Design System Handling

Design systems often live outside the feature repos (loaded as npm/yarn dependencies).
If the context-scout finds references to an external design system:

1. Note the design system name and version
2. Ask the user to confirm: "Found reference to {DS name}. Is this the design system
   to match?"
3. If the user can provide Storybook URL or documentation link, use that for
   additional context

#### 2.5: Fallback — Insufficient Context

If design system context is insufficient (no tokens, no component patterns, no
external DS identified):

```text
AskUserQuestion:
  question: "I couldn't find enough design system context in the repositories.
    I need visual reference to create a high-fidelity prototype.
    Can you provide any of the following?"
  options:
    - "I'll provide a Storybook URL or design system docs link"
    - "I'll describe the visual language (colors, fonts, component style)"
    - "Use a clean, modern default — we'll refine styling later"
```

If the user provides a URL, use `WebFetch` to extract token and pattern information.

---

### Step 3: Identify UI Surfaces to Prototype

#### 3.1: Extract from PRD

- User journeys: end-to-end flows with decision points, screens mentioned
- Story sketches: any that mention UI outcomes ("user sees...", "user can...")
- Personas: what they need to see and interact with

#### 3.2: Extract from Design Document

- Component design: new or significantly changed components
- API endpoints: those that produce user-visible results
- Data model: entities that surface in the UI

#### 3.3: Derive Discrete UI Surfaces

Compile a list of discrete UI surfaces — each is one "view" the user sees:

- Screens (full page views)
- Dialogs/modals (overlay interactions)
- Panels/sections (distinct functional areas within a page)
- Key states (empty, loading, error, success — if significantly different from
  default)

For each surface, note:

- What the user sees (layout, data displayed)
- What they can interact with (buttons, forms, navigation)
- What state transitions occur (click → result)

#### 3.4: Confirm with User

Present the surface list (scope to new/changed surfaces for this feature only —
do not prototype the entire application):

```text
I identified {N} UI surfaces to prototype:

1. {Surface name} — {brief description}
2. {Surface name} — {brief description}
...

Each will be one slide in the prototype. Add, remove, or reorder?
```

Wait for confirmation before proceeding.

---

### Step 4: Adaptive UX Interview (if gaps exist)

#### 4.1: Gap Analysis

Scan the identified surfaces for ambiguity:

- Missing interaction patterns (what happens on click?)
- Unclear navigation flow (how do surfaces connect?)
- Unspecified states (loading, error, empty, success)
- Responsive behavior unclear
- Accessibility considerations not addressed

#### 4.2: Skip Condition

If user journeys in the PRD cover all identified surfaces AND states are
well-specified in the design doc: skip the interview, proceed to Step 5.

Tell the user: "UX decisions are well-specified in existing artifacts.
Proceeding directly to grill/generation."

#### 4.3: Targeted UX Questions (if gaps exist)

Ask only about the gaps (max 3-5 questions total, not per surface):

- **Interactions**: "When the user clicks {action}, what happens? Inline feedback,
  modal confirmation, or navigation to a new view?"
- **Navigation**: "How does the user move between {Surface A} and {Surface B}?
  Tab navigation, breadcrumb, wizard steps, or direct links?"
- **Responsive**: "Mobile-first or desktop-first? Which surfaces must work on mobile?"
- **States**: "What does {Surface X} look like when empty? During loading?
  After an error?"
- **Accessibility**: "Any specific accessibility requirements beyond standard
  (screen reader focus order, high contrast, reduced motion)?"

#### 4.4: Park Unanswerable Questions

When the user says "I don't know" or "need to check":

1. Acknowledge and park as open question (Q# system)
2. Note what answering it would unblock
3. Continue — make a reasonable assumption for the prototype and mark it as [ASSUMED]

---

### Step 5: UX Decision Stress-Test (Grill)

Before committing UX decisions to a prototype, offer to stress-test them.

```text
AskUserQuestion:
  question: "I recommend stress-testing your UX decisions before generating the
    prototype. Shall I grill you?"
  options:
    - "Yes — challenge my interaction decisions (Recommended)"
    - "Skip — I'm confident, proceed to prototype generation"
```

If accepted, invoke `/grill` scoped to the current spec folder. The grill targets
UX decisions focusing on:

- Interaction patterns that might confuse users
- Missing states (error, empty, loading) that would break the experience
- Accessibility gaps in the proposed interactions
- Inconsistencies with existing app patterns (from design system research)
- Navigation dead-ends or circular flows
- Information density and cognitive load

After grill completes, its findings feed into prototype generation:

- Resolved decisions improve the prototype
- Open questions become [ASSUMED] placeholders in the prototype with visual markers

---

### Step 6: Prototype Generation

Dispatch the `prototype-builder` agent with all collected context.

Read `references/prototype-quality.md` and pass its content as QUALITY_STANDARDS to
the agent. The quality file is loaded here and passed to the agent — the agent does
NOT read it from disk.

Pass to the prototype-builder:

- **QUALITY_STANDARDS**: content of `references/prototype-quality.md` (quality rules
  and fidelity requirements)
- **SURFACES**: list of UI surfaces with descriptions, interactions, and states
- **DESIGN_TOKENS**: synthesized token map from Step 2 (colors, typography, spacing,
  radii)
- **COMPONENT_PATTERNS**: inventory of component styles to match
- **MOCK_DATA**: realistic data samples derived from the data model in design.md
  (never Lorem ipsum or placeholder text — all visible data must be domain-realistic)
- **INTERACTIONS**: interaction specifications from interview/PRD
- **DECISIONS**: relevant UX decisions from decisions.md
- **OUTPUT_PATH**: `specs/{folder}/prototype.html`
- **FEATURE_NAME**: for the review chrome title
- **ASSUMED_ITEMS**: any assumptions made where questions were parked (to mark
  visually)

The agent generates a single self-contained HTML file with:

- The slide-deck review pattern (step tracker, slides, feedback panels, copy button)
- Each surface as one slide: prototype on the left/main area, feedback panel on the
  right
- All CSS/JS inline, no external dependencies
- Interactive mock elements (buttons, forms, state transitions)
- Design tokens applied to prototype content; makato review chrome for the wrapper

#### 6.1: HTML Validation

After the agent returns the generated file:

1. Check the file was written successfully
2. Verify well-formed HTML structure (no unclosed tags)
3. Verify no external dependencies (CDN links, external fonts, remote images — file
   must be fully self-contained)
4. Verify all interactive elements have functional responses (no broken buttons or
   dead-end forms)
5. Verify file size is reasonable (warn if >500KB — might indicate issues)
6. If validation fails, re-dispatch with error details

---

### Step 7: Open & Collect Feedback

#### 7.1: Write Output

The prototype-builder writes to `specs/{folder}/prototype.html`.

#### 7.2: Open in Browser

Use platform-aware command:

- macOS: `open specs/{folder}/prototype.html`
- Linux: `xdg-open specs/{folder}/prototype.html`
- Windows: `start specs/{folder}/prototype.html`

Detect platform via `uname` or environment.

#### 7.3: Instruct User

> "Prototype is open in your browser. Each slide shows one UI surface — interact with
> the elements, check the styling matches your app, and add feedback in the right
> panel per surface. Click 'Copy Feedback' when done."

#### 7.4: Process Feedback

**If revisions requested**: parse the structured feedback (section → comments),
re-dispatch prototype-builder with targeted changes, re-open.

**If approved** (user says "looks good", "approved", pastes empty feedback):
proceed to Step 8.

---

### Step 8: Parked Questions Persistence

Write ALL unresolved UX questions from this session to `decisions.md` Open Questions
table.

For EACH parked question (zero silent loss):

- Append row with next sequential Q# ID
- Set "Raised In" to `create-prototype`
- Assign priority: High = blocks decompose phase, Medium = resolve before
  implementation starts, Low = dev team can decide during refinement
- Include notes: what the question affects and what answering it unblocks

---

### Step 9: Status & Handoff

Display completion summary:

```text
Prototype Created: specs/{folder}/prototype.html
UI Surfaces: {N} prototyped
Design System: {name or "custom tokens"}
Assumptions: {N} items marked [ASSUMED] (see open questions)

Next step:
  • /decompose — slice into stories (prototype informs interaction boundaries)
```
