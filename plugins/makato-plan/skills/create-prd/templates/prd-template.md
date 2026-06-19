# <Feature Name> — PRD

**Status**: Draft
**Feature**: <slug>
**Created**: <YYYY-MM-DD>
**Author**: <user>
**UI Required**: <Yes/Minimal/No>
**Repositories**: <repo1 (primary), repo2>

---

## Stakeholders

| Person | Role | Responsibility |
|--------|------|----------------|
| <name> | Lead PO | PRD approval, scope decisions, release go/no-go |
| <name> | Implementation Lead | Delivery ownership, technical feasibility |
| <name> | Business Owner | Business case validation, budget |

---

## Executive Summary

### Problem Statement
<1-2 sentences: What problem are we solving? Who is affected?>

### Background & Context
<Why are we building this NOW? Market driver, customer signal, or strategic initiative. 3-5 sentences max.>

### Proposed Solution
<1-2 sentences: How will we solve it? What's the high-level approach?>

### Success Criteria

| # | Metric | Current Baseline | Target | How to Measure |
|---|--------|-----------------|--------|----------------|
| 1 | <KPI> | <current or "TBD"> | <target value> | <measurement method> |
| 2 | <KPI> | <current or "TBD"> | <target value> | <measurement method> |
| 3 | <KPI> | <current or "TBD"> | <target value> | <measurement method> |

---

## User Personas

| Persona | Description | Primary Need |
|---------|-------------|--------------|
| <user type> | <who they are, role/context> | <what they need from this feature> |

---

## Story Sketches

> These are rough vertical slices showing direction. Detailed acceptance criteria
> and refined stories come during spec/decomposition phases. Sketch as many slices
> as the feature warrants — single-MVP PRDs are valid for tight features, and
> there is no upper cap. Every slice must hit every layer in the feature's
> declared scope.

### Story Sketch 1 (MVP): <User Outcome Title>
**User can**: <what they can do after this ships>
**Layers**: <UI, Middle Tier, Security, DB, Config — every layer the feature's scope requires>
**Coverage**: <repo × layer matrix; e.g., "ui-libs: UI; storefront: UI+Middle Tier; svc: Middle Tier+DB">
**Acceptance sketch**:
- <High-level condition 1>
- <High-level condition 2>
- <High-level condition 3>

<!-- Optional enrichment sketches — include only when phased rollout defines multiple phases -->
### Story Sketch 2 (Enrichment): <User Outcome Title>
**User can**: <incremental value on top of MVP>
**Layers**: <every layer the feature's scope requires>
**Coverage**: <repo × layer matrix>
**Acceptance sketch**:
- <High-level condition 1>
- <High-level condition 2>

### Story Sketch 3 (Enrichment): <User Outcome Title>
**User can**: <additional value>
**Layers**: <every layer the feature's scope requires>
**Coverage**: <repo × layer matrix>
**Acceptance sketch**:
- <High-level condition 1>
- <High-level condition 2>

---

<!-- CONDITIONAL: Include only if UI Required = Yes or Minimal -->
## User Journeys

> 1-2 end-to-end narratives showing how a persona flows through the feature.
> Not wireframes — decision points, entry/exit conditions, and what happens at each stage.

### Journey 1: <Title — Persona + Goal>

1. <Entry point — how does the user arrive?>
2. <Step>
3. **Decision**: <choice point>
   - Option A: <path> → <outcome>
   - Option B: <path> → <outcome>
4. <Step>
5. **Exit**: <where does the user end up?>

**Edge cases**: <What if they abandon? What if configuration conflicts? What if permissions are insufficient?>

---

## Scope

### In Scope
- <Feature/capability 1>
- <Feature/capability 2>
- <Feature/capability 3>

### Non-Goals
- **<What we're NOT building>** — <why it's excluded>
- **<Future consideration>** — <why deferred>
- **<Explicitly out of scope>** — <rationale>

---

## Assumptions & Constraints

### Assumptions

| # | Assumption | Validation Method | Impact if Wrong |
|---|-----------|-------------------|-----------------|
| A1 | <believed-true condition> | <how to verify> | <consequence if assumption fails> |
| A2 | <believed-true condition> | <how to verify> | <consequence if assumption fails> |

### Constraints

| Constraint | Type | Impact on Scope |
|-----------|------|-----------------|
| <hard limit> | <Regulatory/Resource/Platform/Timeline> | <how it bounds what we can build> |

---

## Dependencies

| Dependency | Type | Owner | Status |
|------------|------|-------|--------|
| <dependency> | <Internal/External> | <team/person> | <Active/Blocked/Resolved> |

---

<!-- CONDITIONAL: Include if compliance, accessibility, i18n, or performance targets are flagged -->
## Non-Functional Requirements

> Product-level quality targets (the WHAT). Implementation approach deferred to architecture doc (the HOW).

| Category | Requirement | Target | Notes |
|----------|------------|--------|-------|
| <Accessibility/Performance/Localization/Compliance/Availability> | <requirement> | <target> | <context or decision reference> |

---

## Risks & Mitigations

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| <risk description> | <H/M/L> | <H/M/L> | <mitigation strategy> |

---

## Phased Rollout

| Phase | Scope | Exit Criteria |
|-------|-------|---------------|
| Phase 1 (MVP) | <Core functionality — thinnest end-to-end vertical slice> | <measurable exit criteria> |
| Phase 2 (Enrichment) | <Extended features> | <measurable exit criteria> |
| Phase 3 (if needed) | <Scale/polish> | <measurable exit criteria> |

---

## Definition of Done

> What must be true for the ENTIRE feature to be considered shippable.
> Not per-story — this is the overall completion gate.

- [ ] <Condition 1 — e.g., all Phase 1 stories implemented and passing acceptance tests>
- [ ] <Condition 2 — e.g., non-functional requirements met>
- [ ] <Condition 3 — e.g., documentation updated>
- [ ] <Condition 4 — e.g., stakeholder demo completed with PO sign-off>
- [ ] <Condition 5 — e.g., rollback verified>

---

## Delivery Recommendations

**Estimated scope**: <Small | Medium | Large>
**Suggested Epics**: <1 | 2+, with scope split rationale>
**Story sketches grouped by Epic**:
- Epic 1: <Story Sketches 1-2 (core flow)>
- Epic 2: <Story Sketch 3 (enrichment)> (if applicable)

**Affected repositories**: <from repositories.yml>

> These are advisory only. Epic/Story creation in GitHub Issues happens downstream via /publish.

---

## Key Decisions Referenced

| ID | Decision | Relevance to PRD |
|----|----------|-----------------|
| <D#> | <decision summary> | <how it influences this PRD's scope/approach> |

---

## Open Questions

- [ ] <Question 1 — parked during PRD creation>
- [ ] <Question 2>

> Full question details with priority and context are in decisions.md.

---

*PRD focuses on WHAT and WHY. Technical HOW belongs in the architecture/design phase.*
