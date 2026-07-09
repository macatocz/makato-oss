# Wireframe Tools & User Testing Reference

## Table of Contents
- [Fidelity Decision Tree](#fidelity-decision-tree)
- [Tool Selection](#tool-selection)
- [Penpot Details](#penpot-details)
- [Figma Details](#figma-details)
- [Excalidraw Details](#excalidraw-details)
- [User Testing](#user-testing)
- [Handoff Checklist](#handoff-checklist)

---

## Fidelity Decision Tree

```
Need to validate?
├─ Concept/layout → Low-fi (30min-2hr, paper/Balsamiq)
├─ User flow/navigation → Medium-fi (2-8hr, Penpot/Figma)
└─ Final design/handoff → High-fi (8hr+, Penpot/Figma+code)

Audience?
├─ Brainstorming → Whiteboard/paper
├─ Stakeholder review → Medium-fi with annotations
├─ User testing → Interactive prototype (clickable)
└─ Developer handoff → High-fi with specs + components
```

---

## Tool Selection

| Tool | Best For | Limitations |
|------|----------|-------------|
| ASCII (in specs) | Quick alignment, documentation | Not interactive |
| Excalidraw | Architecture sketches, whiteboard style | No prototyping |
| Balsamiq | Intentionally rough, early concepts | Limited interactivity |
| Penpot | Full design system, dev handoff, MCP-driven generation | Requires open browser tab + MCP setup |
| Figma | Full design system, dev handoff | Learning curve |
| Whimsical | Flowcharts + wireframes combined | Limited design system |
| Sketch (macOS) | High-fidelity with plugins | macOS only |

---

## Penpot Details

Penpot is the makato-native, MCP-drivable design tool. The `makato-ux:penpot-uiux-design`
skill owns all Penpot MCP interaction — `create-ux` delegates rendering to it (see SKILL.md
Steps 4-5). Reach for Penpot over Figma when you want the agent to generate and export the
design programmatically rather than hand-drawing it.

### When to Use
- Medium/high-fi wireframes the agent renders via `mcp__penpot__execute_code`
- Design-system work (components, tokens) that should round-trip into `ux.md`
- Developer handoff needing exported CSS (`penpot.generateStyle`) or PNG/SVG previews

### Division of Labour with create-ux
- `create-ux` owns the screen inventory, state matrix, and the `ux.md` document
- `penpot-uiux-design` owns MCP setup, board layout, component creation, and export
- Disagreements (a missing state surfaced by rendering) are resolved in the inventory first,
  then re-rendered

### Key Gotchas (full list in the penpot skill)
| Issue | Problem | Solution |
|-------|---------|----------|
| `execute_code` times out | Penpot tab not open / no file active | Open design.penpot.app with a design file active |
| `width`/`height` no-op | Both are read-only | Use `shape.resize(w, h)` |
| Board overlap | New boards default to origin | Compute rightmost edge + gap before placing |
| Return value empty | Last expression is not auto-returned | Explicitly `return` from `execute_code` |
| Advanced API missing | Deferred type defs not loaded | Call `mcp__penpot__high_level_overview` once per session first |

### Handoff Features
- Export previews per screen/state via `mcp__penpot__export_shape` (PNG/SVG) — embed in `ux.md`
- Export CSS/tokens via `penpot.generateStyle(selection, { type: 'css', includeChildren: true })`
- Reference the live Penpot file/board rather than pasting static screenshots

---

## Figma Details

### Key Gotchas

| Issue | Problem | Solution |
|-------|---------|----------|
| Auto-layout nesting | Breaks when mixing fixed + hug contents | Use consistent sizing within each frame |
| Prototype links | Links on variants don't persist across component swaps | Attach links to parent frame, not variant |
| SVG export | Text gets flattened | Outline fonts before export |
| Comments | Orphaned when element deleted | Clean up comments before sharing |

### Best Practices
1. **Component organization**: Use `/` naming for hierarchy (e.g., `Button/Primary/Large`)
2. **Variants**: Define all states upfront (default, hover, focus, disabled)
3. **Prototype flows**: Name flows descriptively (e.g., "Login Happy Path")
4. **Design tokens**: Use Figma variables for colors, spacing, typography

### Handoff Features
- Dev mode: Shows CSS/code snippets
- Inspect panel: Spacing, colors, fonts
- Comments: Tag developers with @mentions

---

## Excalidraw Details

### When to Use
- Quick ASCII-style wireframes in markdown docs
- Architecture sketches
- Whiteboard-style collaboration

### Limitations
- No interactive prototyping (export to Figma for clickable flows)
- Limited design system support
- No component variants

### Makato Integration
Use `makato-plan:excalidraw` skill for embedded diagrams in spec documents.

---

## User Testing

### Test Types

| Test Type | Participants | Time/Each | When to Use |
|-----------|--------------|-----------|-------------|
| Guerrilla (hallway) | 3-5 | 5-10 min | Early concept validation |
| Moderated remote | 5-8 | 30-45 min | Flow validation |
| Unmoderated | 10-20 | 10-15 min | Quantitative metrics |
| Card sorting | 15-30 | 15-20 min | IA validation |

### Recruiting Participants

| Source | Pros | Cons |
|--------|------|------|
| Colleagues | Free, fast | Biased by context |
| Customer support | Know pain points | Over-represent edge cases |
| Existing users | Understand product | Can't test onboarding |
| External recruits | Unbiased | Cost, scheduling |

### Sample Sizes
- **Qualitative** (find problems): 5 participants finds ~85% of issues
- **Quantitative** (compare designs): 20+ per variant for significance

### Script Template
```markdown
## Introduction (2 min)
- Thanks for participating
- We're testing the design, not you
- Think aloud - tell me what you're thinking

## Background (3 min)
- Tell me about your role
- How do you currently do [task]?

## Tasks (20 min)
Task 1: "You want to [goal]. How would you do that?"
- Observe silently
- Note: clicks, hesitations, verbal reactions

## Debrief (5 min)
- What was easy? What was confusing?
```

### Facilitator Rules
1. **Don't lead**: "What would you do?" not "Click the button"
2. **Don't rescue**: Let them struggle (note where)
3. **Don't explain**: If they ask, "What do you think it does?"
4. **Do prompt**: "Tell me what you're thinking"

### Success Metrics

| Metric | Target | Calculation |
|--------|--------|-------------|
| Task completion | >80% | Completed / Attempted |
| Time on task | <5 min | Average time per task |
| Error rate | <10% | Errors / Opportunities |
| SUS score | >70 | System Usability Scale |

### Severity Rating

| Level | Description | Action |
|-------|-------------|--------|
| 1 - Critical | Blocks task completion | Must fix before launch |
| 2 - Major | Significant confusion | Should fix before launch |
| 3 - Minor | Annoyance, workaround exists | Fix in next iteration |

---

## Handoff Checklist

Before transitioning to `spec.md`:
- [ ] Screen names match route naming convention
- [ ] All states documented: empty, loading, error, success
- [ ] Responsive breakpoints defined
- [ ] Interactive prototype tested with 3+ external users
- [ ] Components linked to design system
- [ ] Embed live design links — Penpot boards or Figma frames (not static screenshots)
- [ ] Exported CSS/tokens attached for high-fi handoff (Penpot `generateStyle` / Figma inspect)
