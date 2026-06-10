# Vertical Slicing Rules

## Core Principle

Each story cuts through ALL technical layers needed to deliver observable value. The fundamental test: "Can a user do something new when this story is complete, without waiting for any other story?"

## Walking Skeleton

The first story is always the **walking skeleton** — the thinnest possible end-to-end path through the system. It proves the architecture works. Every subsequent story enriches the skeleton.

## Nine Splitting Patterns

1. **Workflow Steps** — break multi-step flows into individual end-to-end steps
2. **Operations (CRUD)** — split "Manage X" into Create, Read, Update, Delete
3. **Business Rule Variations** — separate rules into distinct stories
4. **Data Variations** — start with simplest data plan, expand later
5. **Data Entry Methods** — simple input first, enhance later (manual → import → API)
6. **Major Effort** — "support one type" then "support all types"
7. **Simple/Complex** — extract happy-path, defer edge cases
8. **Defer Performance** — make it work, then make it fast
9. **Break Out a Spike** — time-box research when uncertainty is high

## Technical Enablers

Technical enablers (infrastructure, scaffolding, shared libraries) are NEVER standalone stories. Absorb them into the first user-facing story that needs them. The walking skeleton carries the heaviest enabler load.

## Progressive Detail Decay

- Story 1 (walking skeleton): Full detail — clear Gherkin, precise scope, explicit boundaries
- Middle stories (happy-path): Moderate detail — key scenarios, bounded scope
- Later stories (edge-cases): Rough — acknowledged to need refinement closer to implementation

## Validation Checklist (per story)

- [ ] User-facing outcome? Can a stakeholder see the result?
- [ ] Independently testable? Can we demo this alone?
- [ ] Independently deployable? Can it ship without other stories?
- [ ] Crosses layers? Touches 2+ technical boundaries?

## Anti-Patterns

| Anti-Pattern | Why It's Wrong | Fix |
|---|---|---|
| Horizontal slice (by layer) | No standalone value until all layers combine | Slice by user outcome |
| One story per repo | Same — no value until integration | Slice by workflow step |
| Too thin (no standalone value) | Can't demo, can't test meaningfully | Merge with adjacent story |
| Too thick (>8 SP, >15 criteria) | Won't fit a sprint, too much risk | Apply splitting patterns |
| Entity-driven (by data model) | Optimizes for data, not for user | Slice by workflow instead |
| Component team split (FE/BE) | Forces integration later, blocks teams | Each story crosses layers |

## Each Story Is Independently Shippable

A story behind a feature toggle can ship to production without other stories. If a story requires another story to be useful, they should be merged or sequenced with explicit dependencies.
