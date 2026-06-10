# Story Point Estimation Guide

## Scale

Fibonacci: **1, 2, 3, 5, 8, 13**

If an estimate exceeds 8 SP, consider splitting further. 13 SP stories are rare and should be justified (true complexity that can't be decomposed).

## Team Calibration Summary

DCP teams estimate relative to their own domain complexity. The same Fibonacci scale produces different distributions per team because their work profiles differ.

| Team | Avg SP | Range | Profile |
|------|--------|-------|---------|
| **Core1** | 3.2 | 2–5 | Mid-range; backend platform services, API contracts |
| **Core2** | 3.7 | 3–5 | Slightly higher; infrastructure and shared service work |
| **Ext1** | 5.6 | 3–8 | Highest; complex rule-engine logic, pricing/eligibility |
| **Ext2** | 4.0 | 2–5 | Moderate-high; backend extensions, integration features |
| **Configurator** | 2.8 | 1–5 | Lower; UI-heavy configuration screens, simpler scope |
| **Ind1** | 2.9 | 2–5 | Lower; Angular UI components, feature toggle work |
| **Ind2** | 2.5 | 1–5 | Lowest avg; many small lambda/backend changes, some complex order flows |

**Key insight**: A "3 SP story" means different things to different teams. When decomposing cross-team features, calibrate estimates per team — don't assume uniform sizing.

## Estimation by Story Type

### 1 SP — Trivial
Config change, feature toggle removal, copy/label update, simple CSS fix, adding a parameter to an existing endpoint.

**Real examples**:
- DCP-55800 (Ind2): Remove feature toggle for already-stable feature
- DCP-55556 (Ind2): Add single field to existing Lambda response
- DCP-54792 (Configurator): Minor UI label/config adjustment

### 2 SP — Simple
Single-file logic change with tests, straightforward UI component adjustment, adding a validation that mirrors an existing pattern.

**Real examples**:
- DCP-54989 (Core1): Add validation check to existing service endpoint
- DCP-54781 (Ind1): Single-service cart validation rule (one check, clear scope)
- DCP-55614 (Ext2): Add parameter handling to existing API flow
- DCP-54843 (Configurator): Small configurator UI enhancement

### 3 SP — Moderate
New backend logic touching one service, simple frontend component with state management, new API endpoint with basic logic, cross-component UI change.

**Real examples**:
- DCP-54927 (Core1): New service logic with multiple conditions and tests
- DCP-47401 (Ind1): Angular component rework with feature toggle integration
- DCP-55657 (Ind2): Lambda decorator logic spanning cart validate + cart commit
- DCP-55955 (Ext1): Backend logic determining modal display (7 scenarios)
- DCP-53755 (Configurator): New configurator feature with UI + backend coordination

### 5 SP — Significant
Multi-page UI feature, cross-service integration, new workflow with multiple steps, Lambda with full error handling and edge cases, stories spanning dev + QA effort.

**Real examples**:
- DCP-54509 (Ind1): Show/hide details across 4 pages (multi-page UI, one coherent outcome)
- DCP-54417 (Ind1): Complex Angular component with multiple integration points
- DCP-54953 (Ind2): Prevent out-of-order event processing in quote Lambda (complex state)
- DCP-55130 (Ext1): Multi-step eligibility flow with rules engine integration
- DCP-55044 (Core2): Shared service feature with downstream consumer makato
- DCP-53755 (Configurator): Complex config feature touching multiple screens

### 8 SP — Complex
New service endpoint with full test coverage + error handling, complex multi-component UI feature, new integration with external system, rule engine with many permutations.

**Real examples**:
- DCP-55130 (Ext1): Complex pricing rule with negative prerequisites (rule engine)
- DCP-54987 (Ext1): Full eligibility feature with multiple business rule variations
- DCP-54775 (Ext1): New extension point with cross-service orchestration

**Note**: 8 SP appears almost exclusively in Ext1 (rule-engine complexity). Other teams rarely exceed 5 SP — if they do, the story likely needs splitting.

### 13 SP — Major (Rare)
New service/lambda from scratch, major architectural addition, complex cross-repo integration with data migration. Should be questioned — often splittable.

## Pre-Estimation Pattern ("LO")

DCP teams use "LO" (Lean Offering) comments in Jira before formal refinement:

| Team | Format | Example |
|------|--------|---------|
| Configurator | `LO: N SP` | "LO: 3 SP" |
| Ind1 | `LO N dev [N QA]` | "LO 1 dev", "LO Dev 1 QA 1" |
| Ind2 | `LO N DEV / N QA` | "LO 0.5 DEV / 0.5 QA", "LO 1 DEV / 1 QA" |
| Ext1/Ext2 | `LO: N SP` | "LO: 5 SP" |
| Core1/Core2 | `LO: N SP` | "LO: 3 SP" |

**Ind1 and Ind2 split dev/QA effort** — the story point is the sum. When they say "LO 1 DEV / 1 QA" that equals 2 SP total.

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
- Ext1 uses detailed Definition of Ready checklist (13-item) in Jira

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
