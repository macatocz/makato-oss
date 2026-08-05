---
name: create-ux
description: >-
  Create UX design documents with wireframes, interaction patterns, and user testing plan —
  ux-design, wireframe, user-flow, screen-states, information-architecture, accessibility,
  figma, user-testing, developer-handoff. Use when PRD has "UI Required: Yes", designing
  user flows, documenting screen states, or preparing developer handoff.
version: "1.2.0"
model: opus
argument-hint: "[slug]"
allowed-tools: [Write, Read, Skill]
metadata:
  authors: [makato-plan]
  last_updated: "2026-08-05"
---
# create-ux

## When to Use

- PRD exists with `UI Required: Yes` or `UI Required: Minimal`
- Need to define screen inventory, navigation structure, or information architecture
- Creating wireframes for any fidelity (ASCII sketches through Figma)
- Documenting interaction patterns and component states before implementation
- Planning or conducting user testing on UI surfaces
- Preparing developer handoff with screen specs and accessibility notes

## When NOT to Use

- No PRD exists yet — run `brainstorming` and `create-prd` first
- Feature has no user-facing UI surfaces — go directly to `create-architecture`
- PRD says `UI Required: No`
- Want to create interactive HTML prototypes for stakeholder review — use `create-prototype` instead

---

## UX Thinking Framework

Every UX artifact answers a specific question for a specific audience at a specific lifecycle moment. Apply this filter before each step:

| Artifact | Question it answers | Who reads it | When |
|---|---|---|---|
| Screen inventory | What surfaces exist and how do they connect? | Team alignment | Before wireframes open |
| Wireframes | Where does content live and what can the user do? | Designer / developer | Before implementation |
| Interaction patterns | What happens next, and under what condition? | Developer | During implementation |
| Testing plan | Which hypotheses are unvalidated? | Facilitator / stakeholder | Before handoff |

**Gate rule:** If the upstream artifact for your current step is still changing, stop and stabilize it first. Rework cost grows with every downstream artifact opened. Screen names changing after interaction patterns are written is a cascade edit. Screen names changing after routes are implemented is a two-team coordinated edit across branches already in flight.

---

## Workflow

### Step 1: Resolve Spec Folder

From the argument (slug) or auto-detect the most recently modified `specs/*/` folder.

```text
Args: /create-ux [slug]
Examples:
  /create-ux checkout-redesign   → use specs/checkout-redesign/
  /create-ux                     → auto-detect most recently modified specs/ folder
```

If no spec folder found, stop and tell the user to run `brainstorming` + `create-prd` first.

### Step 2: Load Artifacts

Read from the resolved spec folder:

1. **`prd.md`** (required) — user stories with UI interactions, personas, key user journeys, UI Required field
2. **`design.md`** (optional) — component design, data model, API shape that influences UI

If `prd.md` is absent or `UI Required` is not `Yes`/`Minimal`, stop:

> "This skill requires a PRD with UI Required: Yes or Minimal. Run `create-prd` first."

### Step 3: Information Architecture

Define the screen inventory from the PRD's user stories and journeys:

1. List every screen the feature requires (name + one-line purpose)
2. Map navigation structure — how screens connect (arrows, parent/child, tab flows)
3. Define content hierarchy for each screen — what the user sees first, second, third

**Do not proceed to wireframes without closing the screen inventory.** Wireframes crystallize layout and navigation patterns; adding screens after wireframing begins forces retrofitting of the state matrix and navigation wiring. The inventory is the contract — close it before drawing.

Screen names chosen here cascade to route paths and API endpoint names in the implementation. Treat them as authoritative from this point; changing them post-handoff requires coordinated backend + frontend edits (see Anti-patterns).

### Step 4: Choose Fidelity and Tools

> **MANDATORY:** Load `@references/tools-and-testing.md` for tool comparison and tool-specific gotchas.
> **Do NOT Load** when the goal is concept validation and ASCII output is pre-decided (skip the table; proceed to fidelity selection below).

Select fidelity based on the validation goal:

- **Low-fi** (concept/layout validation) — ASCII wireframes, paper sketches, Balsamiq
- **Medium-fi** (user flow validation) — Penpot or Figma wireframes, clickable prototype
- **High-fi** (developer handoff) — Penpot or Figma with design system tokens + component specs

Start at the lowest fidelity that answers the current question. Pixel-perfect mockups resist feedback; rough sketches invite it.

If fidelity is not obvious from the PRD, use **AskUserQuestion** with selectable options:

```
Which fidelity level is right for this session?
  A) Low-fi — ASCII wireframes (concept / layout validation, ~30 min)
  B) Medium-fi — Penpot or Figma wireframes, clickable prototype (flow validation, ~2-8 hr)
  C) High-fi — Penpot or Figma with design tokens + component specs (developer handoff, ~8 hr+)
```

#### When to render in Penpot (via MCP)

Penpot is the preferred medium/high-fi tool when the user wants **live, editable design artifacts** rather than ASCII sketches. Switch from ASCII to Penpot when **any** of these hold:

- Fidelity is medium or high (user-flow validation or developer handoff)
- The user explicitly mentions Penpot, a design file, a design system, or component library work
- The screen inventory has 3+ screens that share components (reusable boards/components pay off)
- Developer handoff needs exportable CSS / design tokens (Penpot `generateStyle` output)

When the decision is to render in Penpot, **invoke the `makato-ux:penpot-uiux-design` skill** — it owns the Penpot MCP tools (`mcp__penpot__execute_code`, `mcp__penpot__export_shape`, `mcp__penpot__high_level_overview`, `mcp__penpot__penpot_api_info`), MCP setup/troubleshooting, and the component/accessibility reference specs. This `create-ux` skill stays the owner of the `ux.md` document and workflow; `penpot-uiux-design` is the rendering engine it delegates to.

**If Penpot MCP is unavailable mid-session** (execute_code times out, tab closed, or MCP not configured and the user does not want to set one up): fall back to ASCII wireframes for the remaining screens and record a `⚠ Penpot unavailable — ASCII fallback` note in the `ux.md` header. Do not leave screen states undocumented because the rendering tool is down.

Stay with ASCII wireframes (Step 5) when the goal is low-fi concept validation, when Penpot MCP is unavailable, or when the artifact only needs to live inline in `ux.md`.

### Step 5: Create Wireframes

> **MANDATORY:** Load `@references/tools-and-testing.md` for tool-specific guidance (wireframe best practices, tool gotchas).
> **MANDATORY:** Load `@templates/ux-template.md` for ASCII layout patterns and state documentation templates.
> **Do NOT Load** `@references/tools-and-testing.md` when Step 4 already loaded it in this session — the reference is loaded once per workflow, not per step.

For each screen in the inventory:

1. Sketch the layout at the chosen fidelity
2. Annotate interactive elements (buttons, forms, links, gestures)
3. Document **all states** for each screen/component inline:
   - Default, Loading, Empty, Error, Success
   - Form validation behaviors
   - Screen transition triggers

#### Rendering wireframes in Penpot

When Step 4 selected Penpot, hand the screen inventory to the `makato-ux:penpot-uiux-design` skill and let it drive the Penpot MCP. Keep the division of labour clean:

1. **Pass structured context, not pixels** — give `penpot-uiux-design` the screen inventory (name + purpose), navigation map, content hierarchy, target platform/breakpoints, and the design system tokens (or a note that none exists). It handles MCP setup, board positioning, layout, and export.
2. **One board per screen state** — ask it to render Default plus the Loading / Empty / Error / Success states so the state matrix from step 3 is visible, not just the happy path.
3. **Round-trip the artifacts into `ux.md`** — for each screen, capture the Penpot board/file reference and an exported preview (via `mcp__penpot__export_shape`) so the `ux.md` document links live design, not orphaned screenshots. Record the CSS/token export (`penpot.generateStyle`) in the developer-handoff section when fidelity is high.

The `create-ux` workflow remains authoritative for the screen inventory, states, and `ux.md`; `penpot-uiux-design` only renders. If the two disagree (e.g. Penpot output reveals a missing state), update the inventory here first, then re-render.

### Step 6: Document Interaction Patterns

For each interactive component, document:

- **Default state** — what the user sees on arrival
- **Trigger** — what action causes a state change
- **Result** — what changes in the UI (animate, navigate, update inline)
- **Error state** — what the user sees when something fails, and how to recover

Establish and lock screen names now. Changes after developer handoff break API endpoint names and route conventions.

### Step 7: User Testing Plan

> **MANDATORY:** Load `@references/tools-and-testing.md` for testing scripts, recruiting approach, and metrics.
> **Do NOT Load** if already loaded in Steps 4 or 5 this session.

Define:

1. **What to validate** — list 2-4 specific hypotheses (e.g., "users can find the checkout button without prompting")
2. **Test type** — guerrilla (3-5 participants, early validation) or moderated (5-8 participants, flow validation)
3. **Success criteria** — task completion rate >80%, time-on-task <5 min, SUS score >70

Test with external participants, not team members. Team members navigate by knowledge of the system, not UI affordances.

### Step 8: Accessibility Notes

Document WCAG AA requirements inline for each screen — see `@references/tools-and-testing.md` for the complete checklist.

Keep accessibility notes inline with each screen's wireframe section rather than in a standalone appendix. Developers working on a screen who miss a separate appendix implement without constraints; inline notes are impossible to skip.

### Step 9: Save UX Document

> **MANDATORY:** Load `@templates/ux-template.md` for the document structure before writing.
> **Do NOT Load** if already loaded in Step 5 this session.

Write the complete UX doc to `specs/{folder}/ux.md` using `@templates/ux-template.md` as the structure.

> **Consumer note:** `ux.md` is a handoff artifact for developers and designers — it is
> NOT read by `decompose` or any automated downstream skill. Share it with the
> implementation team alongside `design.md`. If content in `ux.md` must influence
> decompose output, it must also be present in `prd.md` or `design.md`.

The document must contain:

- Screen inventory with navigation map
- Wireframes for all screens (all states documented inline)
- Interaction patterns per component
- Accessibility notes (WCAG AA, inline per screen)
- User testing plan

### Step 10: Status and Handoff

Display completion summary:

```text
UX Design Created: specs/{folder}/ux.md
Screens: {N} screens documented
Fidelity: {low/medium/high}
States documented: {list any screens with incomplete states}

Next steps:
  • /create-architecture — incorporate UX structure into technical design
  • /create-prototype    — generate interactive HTML prototype for stakeholder review
```

---

## Anti-patterns

A dedicated list of non-obvious failures this skill's domain teaches the hard way. Each NEVER has an explicit WHY.

**NEVER start wireframing before the screen inventory is closed.**
Adding a screen after wireframing begins means retrofitting navigation wiring, updating the state matrix, and revisiting layout for shared components. The inventory is the architectural contract for the wireframe phase — opening the wireframe phase while the contract is still open causes unbounded rework.

**NEVER change screen names after developer handoff begins.**
Screen names are not decoration; in this codebase they cascade directly to route path segments and API endpoint slugs. A name change post-handoff triggers coordinated backend + frontend edits across branches that are already in flight. Lock names at Step 6 completion.

**NEVER use `ux.md` as input to `decompose`.**
`decompose` reads `prd.md` and `design.md` — `ux.md` is a consumer-side handoff artifact, not a machine-readable input to the planning pipeline. If a UX constraint or interaction rule must influence story decomposition, it must first be encoded in `prd.md` or `design.md`. Feeding the decompose agent a path to `ux.md` causes it to silently skip the document or produce stories that diverge from the authoritative inputs.

**NEVER document only the happy-path screen state in wireframes.**
Developers implement the state they can see in the wireframe spec. Empty, loading, error, and success states left undocumented default to whatever the developer imagines — resulting in inconsistent UX discovered in production, not during review. Document all states in Step 5; an incomplete state matrix is an incomplete handoff.

**NEVER embed static screenshots of Penpot/Figma boards in `ux.md`.**
Static images orphan the live design: when the board changes, the screenshot lies. Always embed live board references (Penpot file/board ID, Figma frame link) supplemented by exported previews via `mcp__penpot__export_shape`. This keeps the document synchronized with the source of truth for the lifetime of the feature.

**NEVER test user flows with team members or the development team.**
Team members navigate by system knowledge — they know where the button is, what the jargon means, and what the flow should do. Their feedback optimizes discoverability for people who already know the system, not for new users. Guerrilla testing with external participants surfaces discovery failures that internal testing cannot.
