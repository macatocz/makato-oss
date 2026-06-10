# Phase Assignment Rules

> **Vocabulary note.** "Phase 1/2/3" and "Foundation/Happy-Path/Edge-Cases" are two notations for the *same* concept — story slicing phase. The `phase` field in `stories.json` always uses the name form (`foundation`/`happy-path`/`edge-cases`). This is unrelated to the plan-lifecycle phase column in `decisions.md` (Discover/Plan/Execute).

## Three Phases

| Phase | Name | What Goes Here | External Dependencies |
|-------|------|---------------|----------------------|
| 1 | **Foundation** | Walking skeleton — thinnest end-to-end path. Things we fully own. | None allowed |
| 2 | **Happy Path** | Core user flows. Our code + integrations already available. | Low-risk only |
| 3 | **Edge Cases** | Error handling, admin flows, external team dependencies. | Yes |

## Decision Matrix

|  | We own it | Depends on others |
|---|---|---|
| **Happy path** | Phase 1-2 | Phase 2-3 |
| **Edge case** | Phase 2-3 | Phase 3 |

## Rules

1. **Phase 1 = zero external dependencies**. Only things we fully own and control.
2. **External deps push stories to later phases.** If a story is blocked on another team's work, it goes into the latest feasible phase.
3. **Feature toggles enable phased delivery.** Ship Phase 1 behind a toggle. Integrate external pieces in Phase 2-3 without blocking early progress.
4. **First story is always the walking skeleton.** It proves the architecture, sets up infrastructure, establishes the vertical path.
5. **If in doubt, push to a later phase.** Can always pull forward if dependencies resolve early. Can't easily push back if they don't.
6. **Never accept "we'll figure it out later" for Phase 1 stories.** Foundation must be clear and unambiguous.

## Phase Characteristics

### Foundation (Phase 1)
- Walking skeleton story (always first)
- Core infrastructure setup (absorbed into skeleton, not standalone)
- Feature toggle creation
- Simplest possible end-to-end path
- Zero external dependencies
- Typically 1-3 stories

### Happy Path (Phase 2)
- Main user workflows
- Core business logic
- Integrations with available systems
- Low-risk external dependencies (already deployed, stable API)
- Typically the largest phase (3-6 stories)

### Edge Cases (Phase 3)
- Error scenarios and fallbacks
- Admin/configuration workflows
- External team dependencies (waiting on their delivery)
- Performance optimizations
- Data migration stories
- Typically 2-4 stories

## External Dependency Handling

When a story has an external dependency:
1. Identify the team and what's needed
2. Record in `externalDependencies` array
3. Assign to Phase 2 at earliest (Phase 3 if high-risk)
4. Consider: can we mock the external system for earlier phases?
5. If mockable → Phase 2 with a follow-up "integrate real system" story in Phase 3
