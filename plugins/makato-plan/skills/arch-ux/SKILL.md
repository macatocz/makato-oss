---
name: daff-arch-ux
description: >-
  Create UX design documents with wireframes, interaction patterns, and user testing.
  Use when: PRD has "UI Required: Yes", designing user flows, creating wireframes,
  documenting screen states, defining information architecture, choosing wireframe tools,
  planning user testing, or preparing developer handoff.
  Triggers: ux-design, wireframe, prototype, mockup, user-flow, interaction, ui-feature,
  screen-states, navigation-structure, accessibility-notes, figma, user-testing, fidelity.
---

# UX Workflow

Create `specs/{folder}/ux.md` for UI features. Includes wireframe tools and user testing.

## Prerequisites

- PRD with `UI Required: Yes` or `UI Required: Minimal`
- Design Doc: `specs/{folder}/design.md`

## Workflow

### 1. Analyze PRD
Extract from PRD:
- User stories with UI interactions
- User personas
- Key user journeys

### 2. Information Architecture
Define:
- Screen inventory (all screens needed)
- Navigation structure (how screens connect)
- Content hierarchy (priority per screen)

### 3. Choose Fidelity & Tools
```
Need to validate?
├─ Concept/layout → Low-fi (ASCII, paper, Balsamiq)
├─ User flow → Medium-fi (Figma wireframes)
└─ Final design → High-fi (Figma + design system)
```

**Tool details**: See [references/tools-and-testing.md](references/tools-and-testing.md) for Figma gotchas, tool comparison.

### 4. Create Wireframes
Create wireframes for each screen. See [templates/ux-template.md](templates/ux-template.md) for ASCII templates.

Basic layout:
```
┌─────────────────────────────────┐
│  Header / Navigation           │
├─────────────────────────────────┤
│  Main Content Area             │
├─────────────────────────────────┤
│  Footer                        │
└─────────────────────────────────┘
```

### 5. Document Interaction Patterns
Document ALL states for each screen/component:
- Default, Loading, Empty, Error, Success states
- Form behaviors and validation rules
- Screen transitions

### 6. Validate with Users
Test prototype with 3-5 external users before finalizing.

| Test Type | Participants | When |
|-----------|--------------|------|
| Guerrilla | 3-5 | Early validation |
| Moderated | 5-8 | Flow validation |

**Targets**: >80% task completion, <5min/task, SUS >70

**Full guide**: See [references/tools-and-testing.md](references/tools-and-testing.md) for scripts, recruiting, metrics.

### 7. Save UX Doc
Save `specs/{folder}/ux.md` containing:
- User Flows
- Wireframes (all screens, all states)
- Component Specifications
- Accessibility Notes (WCAG AA)

## Output
```
╔═══════════════════════════════════════════════════╗
║           UX Design Created!                       ║
╚═══════════════════════════════════════════════════╝

  Local: specs/{folder}/ux.md

Next: Load daff-pm-spec
```

## NEVER
- Skip Information Architecture — wireframes without screen inventory create orphan screens; rework costs 3x more
- Design only "happy path" — document ALL states (error, empty, loading) upfront to prevent implementation delays
- High-fidelity before alignment — start rough to enable iteration; pixel-perfect mockups resist feedback
- Omit accessibility notes — retrofitting is 5-10x more expensive; include WCAG requirements from the start
- Test only with team members — they navigate by knowledge, not UI affordances; use external participants
- Shrink desktop to mobile — design mobile-first (thumb zones, gestures differ fundamentally)
- Use Lorem ipsum for key flows — real content reveals layout problems that dummy text hides
- Lock screen names late — establish naming early; changes after handoff break API/route conventions