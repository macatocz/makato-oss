# Plan Schema

The implementation plan is written to `spec/<key>/plan.md`.
All fields are required unless marked optional.

## Top-Level Structure

```
# Implementation Plan: <work-item-key>

## Story
**Key:** <work-item-key>
**Title:** <story-title>
**Phase:** <phase>
**Dependencies:** <comma-separated keys, or "None">

## Implementation Mode
**Mode:** tdd | goal | mixed
**Rationale:** <one sentence: why this mode for this story>

## Tasks
<task list — one entry per task, see Task Schema below>

## Acceptance Criteria Coverage
<coverage table — see Coverage Table Schema below>

## Scope Flags
<optional warnings about task count, ambiguity, or split recommendations>
```

## Task Schema

Each task uses this structure:

```
### Task <N>: <Title>
**Mode:** tdd | goal
**Files:**
- `<path/to/file.ext>` — create | modify

**Unit Test:**
<What to mock; what assertions to make — or "N/A: <reason>">

**Integration Test:**
<Which real boundary to cross; what to verify — or "N/A: <reason>">

**Satisfies:** AC-<N>[, AC-<M>, …]
```

## Coverage Table Schema

```
| AC   | Description    | Covered By       |
|------|----------------|------------------|
| AC-1 | <ac text>      | Task 1, Task 3   |
| AC-2 | <ac text>      | Task 2           |
```

Every AC row must name at least one task in the "Covered By" column.

## Validation Rules

- Every AC from stories.json must appear in the coverage table
- Every task must be linked to at least one AC in the coverage table
- Tasks must be ordered by implementation sequence (dependencies first)
- File paths must be project-relative (no leading `/`)
- Mode must be `tdd`, `goal`, or `mixed` (top-level); each task must be `tdd` or `goal`
