---
name: create-ux
description: Create UX design documents with wireframes, interaction patterns, and user testing plan — ux-design, wireframe, user-flow, screen-states, information-architecture, accessibility, figma, user-testing, developer-handoff. Use when PRD has UI Required: Yes, designing user flows, documenting screen states, or preparing developer handoff.
version: "1.0.0"
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

Do not proceed to wireframes without completing the screen inventory. Wireframes without a
screen inventory create orphan screens; capture any gaps before drawing.

### Step 4: Choose Fidelity and Tools

Load @references/tools-and-testing.md for tool comparison and Figma-specific gotchas.

Select fidelity based on the validation goal:

- **Low-fi** (concept/layout validation) — ASCII wireframes, paper sketches, Balsamiq
- **Medium-fi** (user flow validation) — Figma wireframes, clickable prototype
- **High-fi** (developer handoff) — Figma with design system tokens + component specs

Start at the lowest fidelity that answers the current question. Pixel-perfect mockups resist feedback; rough sketches invite it.

Ask the user which fidelity is appropriate if not obvious from the PRD.

### Step 5: Create Wireframes

Using @references/tools-and-testing.md for tool-specific guidance and `@templates/ux-template.md` for ASCII layout patterns:

For each screen in the inventory:

1. Sketch the layout at the chosen fidelity
2. Annotate interactive elements (buttons, forms, links, gestures)
3. Document **all states** for each screen/component inline:
   - Default, Loading, Empty, Error, Success
   - Form validation behaviors
   - Screen transition triggers

Design mobile-first — thumb zones and gestures differ fundamentally from desktop. Shrinking a desktop layout to mobile is not mobile design.

Use real content in key flows — dummy text hides layout problems that real data reveals.

### Step 6: Document Interaction Patterns

For each interactive component, document:

- **Default state** — what the user sees on arrival
- **Trigger** — what action causes a state change
- **Result** — what changes in the UI (animate, navigate, update inline)
- **Error state** — what the user sees when something fails, and how to recover

Establish and lock screen names now. Changes after developer handoff break API endpoint names and route conventions.

### Step 7: User Testing Plan

Load @references/tools-and-testing.md for testing scripts, recruiting approach, and metrics.

Define:

1. **What to validate** — list 2-4 specific hypotheses (e.g., "users can find the checkout button without prompting")
2. **Test type** — guerrilla (3-5 participants, early validation) or moderated (5-8 participants, flow validation)
3. **Success criteria** — task completion rate >80%, time-on-task <5 min, SUS score >70

Test with external participants, not team members. Team members navigate by knowledge of the system, not UI affordances.

### Step 8: Accessibility Notes

Document WCAG AA requirements inline for each screen:

- Colour contrast ratios for all text/interactive elements
- Keyboard navigation order and focus indicators
- Screen reader labels for icons and image content
- Touch target sizes (minimum 44×44 px)

Include accessibility from the start — retrofitting after implementation is 5–10× more expensive.

### Step 9: Save UX Document

Write the complete UX doc to `specs/{folder}/ux.md` using `@templates/ux-template.md` as the structure.

The document must contain:

- Screen inventory with navigation map
- Wireframes for all screens (all states documented inline)
- Interaction patterns per component
- Accessibility notes (WCAG AA)
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
