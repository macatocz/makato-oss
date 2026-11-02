# Plan Schema

The implementation plan is written to `plan.md` in the resolved spec folder (`specs/<key>-<slug>/`).
All fields are required unless marked optional.

## Top-Level Structure

```text
# Implementation Plan: <work-item-key>

## Story
**Key:** <work-item-key>
**Title:** <story-title>
**Phase:** <phase>
**Dependencies:** <comma-separated keys, or "None">

## Implementation Mode
**Mode:** tdd | goal | mixed
**Rationale:** <one sentence: why this mode for this story>
**runOrder:** [tdd, goal] | [goal, tdd] | N/A
  (for mixed-mode plans: which mode runs first when both have dependency-ready tasks. The
  PO-agent turns cross-mode `blockedBy` into pass boundaries; runOrder never overrides it.
  N/A for single-mode plans.)

## Tasks
<task list — one entry per task, see Task Schema below>

## Acceptance Criteria Coverage
<coverage table — see Coverage Table Schema below>

## Acceptance Test Oracle   (optional)
<QA-authored acceptance-test scenarios — see Acceptance Test Oracle Schema below. Omitted entirely when the source story carries no acceptanceTestCases.>

## Runtime verification   (optional)
<single shell command declared as a fenced code block — see Runtime Verification Schema below. Omitted when the story has no service/API runtime health-check to declare.>

## Scope Flags
<optional warnings about task count, ambiguity, or split recommendations>
```

## Task Schema

Each task uses this structure:

```text
### Task <N>: <Title>

**Mode:** tdd | goal
**blockedBy:** [<task-index>, …] | []
  (1-based indices of tasks whose production code this task depends on at compile time.
  Empty list means no hard dependency. Must be populated when these files cannot compile
  without a prior task's output.)
**reviewRisk:** normal | auth,money,persistence,public-contract
  (Use only applicable risk labels; high-risk boundaries request earlier review.)
**atomicGroup:** none | unknown | <cutover-group>
  (none means an independently reviewable compatible contract. Every task in an atomic
  schema/writer/reader cutover uses the same group. Unknown or omitted metadata defers
  intermediate review; it never bypasses final review.)
**commitMessage:** `<conventional-commit-message>`
  (e.g. `feat(invoice): add OrderStatus enum`)
**Files:**

- `<path/to/file.ext>` — create | modify

**Unit Test:** <What to mock; what assertions to make — or "N/A: <reason>">

**Integration Test:** <Which real boundary to cross; what to verify — or "N/A: <reason>">

**Satisfies:** AC-<N>[, AC-<M>, …]
```

## Coverage Table Schema

```text
| AC   | Description    | Covered By       |
|------|----------------|------------------|
| AC-1 | <ac text>      | Task 1, Task 3   |
| AC-2 | <ac text>      | Task 2           |
```

Every AC row must name at least one task in the "Covered By" column.

## Acceptance Test Oracle Schema

Optional section. Written **only** when the source story carries a non-empty
`description.acceptanceTestCases[]` (QA-refined scenarios from the `create-acceptance-tests` skill).
When the story has no `acceptanceTestCases`, this section is **omitted entirely** — its absence is
the legacy default and changes nothing downstream.

Each scenario is a Gherkin block annotated with the AC it verifies:

```text
## Acceptance Test Oracle

### Scenario 1: <outcome-focused title>   (maps to AC-1)
Given <precondition>
When <triggering action>
Then <observable outcome>
And <optional additional assertion>

### Scenario 2: <outcome-focused title>   (maps to AC-2)
Given <precondition>
When <triggering action>
Then <observable outcome>
```

- Scenarios are copied verbatim from `acceptanceTestCases[]` (same Gherkin shape as
  `successScenarios[]`; see `scenario-schema.md` in makato-plan).
- Each `(maps to AC-N)` annotation links the scenario to a numbered AC from the coverage table. When
  a scenario maps to no specific AC, annotate `(maps to AC-*)` (applies to the whole story).
- The `coder` agent filters this section by each task's `**Satisfies:**` AC links and implements the
  matching scenarios as its RED tests (see `coder.md` § _Test oracle_). The oracle is **advisory** —
  it never overrides `PLAN_CONTEXT.Hard Constraints`.

## Runtime Verification Schema

Optional section. Written **only** for service or API stories where a health-check or smoke command
can be executed after startup to verify the runtime is healthy. When the story has no runtime
health-check to declare, this section is **omitted entirely** — its absence is the default and
changes nothing downstream.

The section contains a **single fenced code block** with the shell command to run:

````text
## Runtime verification

```bash

curl -sf http://localhost:8080/health | grep '"status":"ok"'

```

````

Rules:

- The command must be a single shell expression (pipeline allowed; multi-line not supported —
  compose into a one-liner if needed).
- The command must exit 0 on success and non-zero on failure.
- **No timeout declaration.** `HEALTH_CHECK_TIMEOUT_SECONDS` env-var override remains the
  authoritative timeout mechanism; the plan section must not declare a timeout value.
- `build-verify` Step 1 reads this section from `plan-<N>.md` at session start and sets
  `PLAN_RUNTIME_CMD`. Gate 6 (Step 8b) uses `PLAN_RUNTIME_CMD` when non-empty; this value takes
  precedence over any `health_check_cmd` returned by the gate-scout. When the section is absent or
  empty, gate-scout discovery is the fallback (existing behavior preserved).
- `gate-scout` MUST NOT be modified to read `plan.md`; plan-command extraction belongs exclusively
  in `build-verify` Step 1.
- Gate 6 is always advisory: non-zero exit logs `warn`, never fails the build.
- The `build.jsonl` entry for Gate 6 (`step:"gate-health"`) includes a `runtime_cmd_source` field:
  `"plan"` when the command came from `plan-<N>.md`, `"gate-scout"` when it came from gate-scout
  discovery, `"none"` when both are absent.

## Validation Rules

- Every AC from stories.json must appear in the coverage table
- Every task must be linked to at least one AC in the coverage table
- Tasks must be ordered by implementation sequence (dependencies first)
- File paths must be project-relative (no leading `/`)
- Mode must be `tdd`, `goal`, or `mixed` (top-level); each task must be `tdd` or `goal`
- `blockedBy` must be populated (as `[]` or a non-empty list) for every task — never omitted
- New plans must declare `reviewRisk` and `atomicGroup` for each task. Never infer `none` from
  dependency order alone; use `unknown` when a compatible checkpoint cannot be proven.
- `commitMessage` must be populated for every task — never omitted
- `runOrder` must be present when top-level mode is `mixed`; omit or set to `N/A` for single-mode
  plans
- `## Acceptance Test Oracle` is optional — present only when the source story has a non-empty
  `acceptanceTestCases[]`; every scenario in it must carry a `(maps to AC-N)` annotation referencing
  an AC from the coverage table (or `AC-*` for story-wide scenarios)
- `## Runtime verification` is optional — present only for service/API stories that declare a
  health-check or smoke command; must contain exactly one fenced code block with a single shell
  expression; must NOT declare a timeout (use `HEALTH_CHECK_TIMEOUT_SECONDS` env-var instead)
