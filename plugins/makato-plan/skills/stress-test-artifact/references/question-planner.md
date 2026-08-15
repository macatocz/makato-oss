# Question Planner

Pre-planning reference for `stress-test-artifact`. Before starting the grill, load this
file and select a lens rotation plan that matches the target artifact type. The lenses
structure which angles to probe in each question group, ensuring the session covers
all four perspectives without drifting into a single dimension.

---

## The Four Lenses

### User Lens

Probes user-observable outcomes, personas, and friction points. Use when the artifact
makes claims about what users experience, who benefits, or how users will behave.

**Example question prompts:**
- Who is the primary actor performing this action, and what do they want to achieve?
- What does a frustrated user encounter when the happy path is not available?
- Which persona bears the most friction from this design, and is that friction justified?
- What does the user see immediately after the key action completes?
- Where does this feature sit in the user's journey — is it a first-time or repeat interaction?

---

### Tech Lens

Probes technical feasibility, dependencies, and architectural risk. Use when the artifact
references system boundaries, integration points, performance constraints, or implementation
choices.

**Example question prompts:**
- What external systems or services does this depend on, and what happens if they are unavailable?
- Where does state live, and who is authoritative when two systems disagree?
- What is the failure mode when the primary path times out or returns an error?
- Is there a precedent in the codebase for this pattern, or does this introduce a new abstraction?
- What is the expected scale (requests/day, data volume, concurrency) and does the design support it?

---

### Risk Lens

Probes assumptions, unknowns, edge cases, and rollback scenarios. Use when the artifact
makes implicit assumptions about system state, user behavior, or external conditions.

**Example question prompts:**
- What is the worst-case scenario if this feature ships with a subtle defect?
- What assumption in this design has the highest probability of being wrong?
- How do we roll back if this change causes degraded behavior in production?
- What security or privacy implications follow from the data flows described here?
- Which edge case is most likely to be discovered only after launch?

---

### Business Lens

Probes value delivery, success metrics, scope boundaries, and stakeholder alignment.
Use when the artifact makes claims about business outcomes, prioritization, or ROI.

**Example question prompts:**
- What measurable outcome confirms this feature delivered its intended value?
- Who outside the immediate team needs to approve or be informed about this decision?
- What scope is explicitly out of bounds, and why was it deferred?
- How does this feature interact with existing pricing, licensing, or contractual constraints?
- What does "done" mean to the product owner in a sprint demo — what do they click and what do they see?

---

## Lens Rotation Rules

Rotate lenses across question groups (typically Q1–Q4 per group) to prevent the session
from narrowing prematurely. Apply the rotation plan that matches the artifact being grilled.

### Rotation Plan A — PRD / Brainstorm (business-first)

Artifact is early-stage: scope, user outcomes, and success criteria are the primary risk.

| Group | Opening lens | Follow-up lenses |
|-------|-------------|------------------|
| Q1–Q4 | Business | User → Risk |
| Q5–Q8 | User | Business → Risk |
| Q9–Q12 | Risk | User → Business |
| Q13+ | Tech | Risk → Business |

### Rotation Plan B — Design / Architecture (tech-first)

Artifact is mid-stage: feasibility, boundaries, and failure modes are the primary risk.

| Group | Opening lens | Follow-up lenses |
|-------|-------------|------------------|
| Q1–Q4 | Tech | Risk → User |
| Q5–Q8 | Risk | Tech → Business |
| Q9–Q12 | User | Business → Risk |
| Q13+ | Business | User → Tech |

### Rotation Plan C — Spec / Story (balanced)

Artifact is late-stage: specificity, edge cases, and testability are the primary risk.

| Group | Opening lens | Follow-up lenses |
|-------|-------------|------------------|
| Q1–Q4 | User | Tech → Risk |
| Q5–Q8 | Risk | Business → User |
| Q9–Q12 | Business | Tech → User |
| Q13+ | Tech | Risk → Business |

---

## Selecting a Plan

| Grill target | Recommended plan |
|-------------|-----------------|
| `brainstorm.md` | A — PRD / Brainstorm |
| `prd.md` | A — PRD / Brainstorm |
| `design.md` | B — Design / Architecture |
| `spec.md` | C — Spec / Story |
| Individual story | C — Spec / Story |

When in doubt, use Plan C — it covers all lenses evenly and degrades gracefully
for targets that blend PRD and design concerns.
