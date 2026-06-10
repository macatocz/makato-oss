# PRD Quality Standards

Quality rules applied when writing and reviewing the PRD. Load during Step 5.2 (PRD generation).

---

## Measurable Criteria

Every success metric and acceptance condition must be concrete and testable. Reject vague language:

| Vague | Concrete |
|-------|----------|
| "fast" | "returns results within 200ms for 10k records" |
| "easy to use" | "completes task in under 3 clicks from landing page" |
| "intuitive" | "zero training required — new user succeeds on first attempt" |
| "scalable" | "handles 10x current load without architecture changes" |
| "reliable" | "99.9% uptime measured over 30-day rolling window" |

If a metric can't be quantified yet, label it "TBD — requires baseline measurement" rather than using vague language.

---

## Dependency-Based Phases

Phased rollout uses dependency ordering, NEVER time-based sprints:

```diff
# WRONG — time-based
- Sprint 1: Build API
- Sprint 2: Build UI
- Q3: Launch

# RIGHT — dependency-based
+ Phase 1 (MVP): End-to-end path with minimal UI
+   Exit criteria: user can complete core workflow
+ Phase 2 (Enrichment): Polish UI, add edge cases
+   Exit criteria: all personas satisfied
+ Phase 3 (Scale): Performance optimization, monitoring
+   Exit criteria: handles projected load
```

Each phase has explicit exit criteria. Phase N+1 depends on Phase N being complete.

---

## Decision References

The PRD references `decisions.md` entries by ID. Never duplicate decision content:

```markdown
<!-- WRONG — duplicated decision content -->
We chose REST over GraphQL because the team has more experience with REST
and our API surface is simple enough that GraphQL's complexity isn't justified.

<!-- RIGHT — reference by ID -->
The API uses REST (per D3: team expertise + simple surface area).
```

This keeps decisions.md as the single source of truth. When a decision changes, only one file needs updating.

---

## Required Sections

Every PRD must include:

1. **Executive Summary** — Problem, Solution, 3-5 measurable success KPIs
2. **User Personas** — who benefits, primary need per persona
3. **Story Sketches** — rough vertical slices (walking skeleton first)
4. **Scope** — In-Scope AND Non-Goals (both required)
5. **Success Metrics** — quantified with measurement method
6. **Dependencies** — what this feature depends on
7. **Risks & Mitigations** — identified risks with likelihood/makato/strategy
8. **Phased Rollout** — dependency-based phases with exit criteria
9. **Delivery Recommendations** — advisory scope/Epic sizing

---

## Non-Goals Section

The Non-Goals section is mandatory. Undefined boundaries cause scope creep. For each non-goal, briefly state WHY it's excluded (not just WHAT):

```markdown
### Non-Goals
- **Admin dashboard** — out of scope for Phase 1; admin workflows are low-frequency and can use existing tools
- **Batch processing** — deferred per D5; real-time processing covers 95% of use cases
- **Mobile support** — current user base is 98% desktop; revisit after usage data confirms demand
```
