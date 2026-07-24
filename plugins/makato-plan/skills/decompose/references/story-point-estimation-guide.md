# Story Point Estimation Guide

## Scale

Fibonacci valid values: **1, 2, 3, 5, 8, 13**

Values outside this set (18, 21, or any other non-Fibonacci number) are **INVALID** — not a
rough estimate, not acceptable. A story estimated at 18 or 21 SP is a sizing failure that
must be resolved before stories.json is written.

**Hard cap: no story may exceed 13 SP.** A value above 13 is a hard validation failure in
Step 8, not a warning.

## Sizing Gate

Apply this three-state decision tree when sizing each story:

| Estimate | Decision | Action |
|---|---|---|
| ≤ 8 SP | Accepted as-is | No sizing action required. |
| > 8 SP and ≤ 13 SP | **Split preferred** | Attempt to split into two or more independently deliverable, testable vertical slices. Keep whole only if every candidate split fails the split-safety checklist (see below). |
| > 13 SP or off-scale (18, 21, any non-Fibonacci) | **Hard block** | Must split. If no safe split exists, flag a blocking error. Off-scale values are a hard block regardless of split outcome. |

### Split-preferred rule

When a story estimates > 8 SP, splitting is the **default** choice — not only when the
estimate exceeds the cap. A ≤ 13 SP story that contains separable, independently-demoable
concerns should still be split.

Splitting is only skipped when both resulting pieces would fail the split-safety checklist.

### Split-safety checklist (all four must pass for a split to be accepted)

A candidate split slice is accepted only when ALL of the following hold:

1. **User-facing demoable outcome** — the slice delivers a standalone outcome a user can
   observe or interact with (not just internal plumbing).
2. **Independently testable** — acceptance criteria can be written and verified without the
   other slice being present.
3. **Independently deployable** — the slice can be deployed to staging/production on its own.
4. **Crosses layers** — the slice touches more than one layer or repository (not a
   single-layer / single-repo horizontal cut).

If any candidate split produces a piece that fails one or more of the four checks, that
**split is rejected**. If no safe split exists and the story is still > 13 SP, record a
**blocking error** to be surfaced in Step 8.

### Rejection examples (the two hard rejection conditions)

- **Non-demoable fragment** — splitting a UI dialog from the backend that makes it
  functional: the dialog alone delivers no user outcome (fails check 1 and 3).
- **Horizontal / single-layer cut** — a slice scoped to one layer only (e.g. "backend API
  only" with no UI or integration story): violates the vertical-slicing requirement (fails
  check 4).

## Team Calibration Summary

Teams estimate relative to their own domain complexity.
The same Fibonacci scale produces different distributions per team because their work profiles differ.

| Team | Avg SP | Range | Profile |
|------|--------|-------|---------|
| **Core1** | 3.2 | 2–5 | Mid-range; backend platform services, API contracts |
| **Core2** | 3.7 | 3–5 | Slightly higher; infrastructure and shared service work |
| **Ext1** | 5.6 | 3–8 | Highest; complex rule-engine logic, pricing/eligibility |
| **Ext2** | 4.0 | 2–5 | Moderate-high; backend extensions, integration features |
| **Configurator** | 2.8 | 1–5 | Lower; UI-heavy configuration screens, simpler scope |
| **Ind1** | 2.9 | 2–5 | Lower; Angular UI components, feature toggle work |
| **Ind2** | 2.5 | 1–5 | Lowest avg; many small lambda/backend changes, some complex order flows |

**Key insight**: A "3 SP story" means different things to different teams.
When decomposing cross-team features, calibrate estimates per team — don't assume uniform sizing.

## Estimation by Story Type

### 1 SP — Trivial

Config change, feature toggle removal, copy/label update, simple CSS fix,
adding a parameter to an existing endpoint.

**Real examples**:

- DCP-55800 (Ind2): Remove feature toggle for already-stable feature
- DCP-55556 (Ind2): Add single field to existing Lambda response
- DCP-54792 (Configurator): Minor UI label/config adjustment

### 2 SP — Simple

Single-file logic change with tests, straightforward UI component adjustment,
adding a validation that mirrors an existing pattern.

**Real examples**:

- DCP-54989 (Core1): Add validation check to existing service endpoint
- DCP-54781 (Ind1): Single-service cart validation rule (one check, clear scope)
- DCP-55614 (Ext2): Add parameter handling to existing API flow
- DCP-54843 (Configurator): Small configurator UI enhancement

### 3 SP — Moderate

New backend logic touching one service, simple frontend component with state management,
new API endpoint with basic logic, cross-component UI change.

**Real examples**:

- DCP-54927 (Core1): New service logic with multiple conditions and tests
- DCP-47401 (Ind1): Angular component rework with feature toggle integration
- DCP-55657 (Ind2): Lambda decorator logic spanning cart validate + cart commit
- DCP-55955 (Ext1): Backend logic determining modal display (7 scenarios)
- DCP-53755 (Configurator): New configurator feature with UI + backend coordination

### 5 SP — Significant

Multi-page UI feature, cross-service integration, new workflow with multiple steps,
Lambda with full error handling and edge cases, stories spanning dev + QA effort.

**Real examples**:

- DCP-54509 (Ind1): Show/hide details across 4 pages (multi-page UI, one coherent outcome)
- DCP-54417 (Ind1): Complex Angular component with multiple integration points
- DCP-54953 (Ind2): Prevent out-of-order event processing in quote Lambda (complex state)
- DCP-55130 (Ext1): Multi-step eligibility flow with rules engine integration
- DCP-55044 (Core2): Shared service feature with downstream consumer impact
- DCP-53755 (Configurator): Complex config feature touching multiple screens

### 8 SP — Complex

New service endpoint with full test coverage + error handling,
complex multi-component UI feature, new integration with external system,
rule engine with many permutations.

**Real examples**:

- DCP-55130 (Ext1): Complex pricing rule with negative prerequisites (rule engine)
- DCP-54987 (Ext1): Full eligibility feature with multiple business rule variations
- DCP-54775 (Ext1): New extension point with cross-service orchestration

**Note**: 8 SP appears almost exclusively in the Extensions team (rule-engine complexity).
Other teams rarely exceed 5 SP — if they do, the story likely needs splitting.

### 13 SP — Major (Rare)

New service/lambda from scratch, major architectural addition,
complex cross-repo integration with data migration. Should be questioned — often splittable.

## Pre-Estimation Pattern ("LO")

Teams use "LO" (Lean Offering) comments in the issue tracker before formal refinement:

| Team | Format | Example |
|------|--------|---------|
| Configurator | `LO: N SP` | "LO: 3 SP" |
| Ind1 | `LO N dev [N QA]` | "LO 1 dev", "LO Dev 1 QA 1" |
| Ind2 | `LO N DEV / N QA` | "LO 0.5 DEV / 0.5 QA", "LO 1 DEV / 1 QA" |
| Ext1/Ext2 | `LO: N SP` | "LO: 5 SP" |
| Core1/Core2 | `LO: N SP` | "LO: 3 SP" |

**Ind1 and Ind2 split dev/QA effort** — the story point is the sum.
When they say "LO 1 DEV / 1 QA" that equals 2 SP total.

## Estimation Rules

1. Estimate relative complexity, not time
2. Include test effort in the estimate (a story is not done until tested)
3. Foundation stories (Phase 1) carry extra weight from enabler setup — this is expected
4. Edge-case stories tend to be smaller (infrastructure already exists)
5. These estimates are rough at decompose time — refined during sprint planning
6. When in doubt, round up (surprises are usually negative)
7. Cross-team stories: use the higher team's calibration (uncertainty compounds)
8. Stories with external dependencies: add 1 SP for coordination overhead

## Team-Specific Patterns

### Ext1 / Ext2 (Extensions)

- Rule-engine stories are inherently complex → expect 5-8 SP
- Eligibility/pricing logic with multiple business rules → 8 SP
- Simple parameter additions to existing extensions → 2-3 SP
- Extensions team uses detailed Definition of Ready checklist (13-item) in the issue tracker

### Core1 / Core2

- Platform/shared service changes ripple to consumers → 3-5 SP
- API contract changes require coordination → add 1 SP
- Isolated service logic → 2-3 SP

### Configurator

- UI-focused with backend config → 2-3 SP typical
- New configuration screens → 3-5 SP
- Toggle/label changes → 1 SP

### Ind1 (Indirect One — UI/Frontend)

- Angular component work → 2-3 SP
- Multi-page visibility changes → 5 SP
- Feature toggle integration → 2 SP
- Primarily works in ps-ui repository

### Ind2 (Indirect Two — Backend/Lambda)

- Simple Lambda parameter additions → 1 SP
- Event processing with state management → 5 SP
- Feature toggle removals → 1 SP
- Mix of Commerce (Java) and Lambda (Node.js) work
- Stories spanning 3+ sprints (spillovers) exist at 5 SP — these should have been split

## Red Flags

- All stories estimated the same → probably not thinking carefully
- Every story is 3 SP → generic estimate, not calibrated to team
- Story has 8+ SP AND external dependencies → definitely split
- Ind2/Configurator story at 5+ SP → verify it can't be decomposed
- Ext1 story at 3 SP → verify it's genuinely simple (rare for rule engine work)
- Story spans 3+ sprints → was mis-estimated, should have been split at decompose time
