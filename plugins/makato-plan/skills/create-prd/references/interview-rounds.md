# PRD Product Strategy Interview Rounds

## Pre-Round Coverage Scan

Before each round fires, scan all available sources against that round's question list and
classify each question as one of three states:

| State | Meaning | Action in the round |
|-------|---------|---------------------|
| `covered` | A direct answer already exists in `brainstorm.md`, `decisions.md`, or a prior round's response | Collapse to a one-sentence confirmation: "brainstorm already recorded X — confirm Y/N?" Do NOT re-ask the full question. |
| `needs-confirmation` | A partial or implicit answer exists but was not explicitly confirmed by the user | Ask a short confirmation question (one sentence) rather than the full open-ended prompt. |
| `needs-answer` | No prior coverage found | Ask the full question as specified in the round. |

**Scan procedure** (internal — not shown to the user):

1. List every topic in the upcoming round.
2. For each topic, search `brainstorm.md` and `decisions.md` for a direct answer.
   If this is Round 2 or Round 3, also check whether a prior round already captured it.
3. Assign one of the three states above.
4. When `covered` topics would reduce a round to confirmation checks only, the round
   may collapse entirely to a brief "Confirming a few points from our brainstorm" block
   rather than a full interview sequence.

Do NOT skip the scan — even if brainstorm.md is rich, always verify which questions
were explicitly confirmed vs. implied.

---

## Round 1 — Core Strategy (always ask)

- **Success criteria** — 3-5 measurable KPIs. Reject vague qualifiers:
  "What does 'fast' mean? Give me a number." / "What does 'easy to use' mean?
  Give me a testable condition." Never accept "fast", "easy to use", or "intuitive"
  without measurable thresholds.
- **Scope boundaries** — explicit In-Scope list AND Non-Goals section
  (mandatory — undefined boundaries cause scope creep).
  "What are we explicitly NOT building?"
- **User personas** — who benefits, what's their primary need.
  Sharpen from brainstorm's broad categories into concrete persona descriptions.
- **Priority** — critical/high/medium/low with rationale for the choice.
- **Phased rollout** — what's MVP vs. enrichment? Use dependency-based phases
  (Phase 1 enables Phase 2), NEVER time-based ("Sprint 1", "Q3").
- **UI scope** — Yes (UI feature) / Minimal UI / No (backend only).

## Round 2 — Context & Ownership (always ask)

> **Pre-round:** Run the Pre-Round Coverage Scan against the Round 2 topics
> before asking any questions. Collapse already-covered topics to confirmation checks.

- **Background & Context** — "Why are we building this NOW? What's the market
  driver, customer signal, or strategic initiative?" Distill from brainstorm if
  available, but confirm with user. 3-5 sentences max.
- **Stakeholders** — "Who is the lead PO? Who is responsible for delivery? Who is
  the business owner?" Named people, not generic titles. These own the PRD sign-off
  and decisions.
- **Constraints** — hard product-level limits. "What's non-negotiable? Budget ceiling,
  regulatory deadline, team size, platform mandates, data residency?"
  NOT technical constraints (those go in architecture doc).
- **Dependencies** — "What are we waiting on or need from other teams?"

## Round 3 — Conditional (ask based on feature characteristics)

> **Pre-round:** Run the Pre-Round Coverage Scan against the Round 3 topics
> before asking any questions. Collapse already-covered topics to confirmation checks.

| Topic | Trigger Condition | Minimum Data Required |
|-------|-------------------|-----------------------|
| **Assumptions** | Always (after constraints) | At least 1 believed-true condition with validation method |
| **User Journeys** | UI Required = Yes or Minimal | 1-2 end-to-end narratives with decision points |
| **Non-Functional Reqs** | Compliance, accessibility, i18n, or perf flagged | Category + target per relevant area |
| **Definition of Done** | Always | 3-5 conditions that signal "the whole feature can ship" |

**Assumptions**: "What are we believing to be true that we haven't verified?
What happens if we're wrong?" Each assumption needs: the belief, how to validate it,
and the impact if wrong.

**User Journeys** (UI features only): "Walk me through the main flow end-to-end.
Where does the user start? What decisions do they make? Where do they end up?"
1-2 narratives with decision points and edge case notes.

**Non-Functional Requirements** (when triggered): "What quality targets must this
feature meet? Accessibility standard? Performance from the user's perspective?
Language support? Compliance mandates?" These are PRODUCT decisions that shape scope
and cost. The implementation approach goes in the architecture doc.

**Definition of Done**: "What must be true for the ENTIRE feature to be considered
shippable? Not per-story — the overall completion gate." Push for testable conditions.
If the user can't answer yet, park as open questions but note that PRD cannot be
Approved without a Definition of Done.

## Parking Unanswerable Questions

When the user says "I don't know" or "we'd need to check with {person}":

1. Acknowledge: "Good question — let's park that for now."
2. Assign sequential ID (Q1, Q2, Q3...) continuing from any existing Qs in decisions.md.
3. Note the question with minimal context.
4. Continue without dwelling.

If a parked question leaves a PRD section empty, mark it `[PENDING: Q#]` — the section
stays in the PRD but is clearly flagged as incomplete.
