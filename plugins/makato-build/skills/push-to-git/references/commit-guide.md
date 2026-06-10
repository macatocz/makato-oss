# Commit Guide

## Conventional Commit Format

```
<type>(<scope>): <description>
```

- `<type>` — what kind of change (see Type Selection below)
- `<scope>` — the area of the codebase affected (module, service, component name)
- `<description>` — imperative mood, no period, ≤72 characters total line length

**Valid:** `feat(invoice): add status field to Invoice entity`
**Invalid:** `Added status field.` (past tense, no type, no scope, has period)

## Type Selection

| Type | Use when |
|------|----------|
| `feat` | New behavior visible to the caller or user |
| `fix` | Corrects wrong behavior in existing code |
| `refactor` | Restructures code without changing behavior |
| `test` | Adds or changes tests only (no production code) |
| `chore` | Build config, dependency updates, tooling — nothing that changes runtime behavior |
| `docs` | Documentation only |
| `style` | Formatting, whitespace — zero logic change |

**Default for story implementation tasks:** `feat` — each task adds new behavior.

Use `fix` only if a task explicitly corrects a defect. Use `refactor` only if a task explicitly restructures without new behavior. When in doubt, `feat`.

## Description Rules

- Imperative mood: "add", "expose", "remove", "update" — not "added", "exposes", "removed"
- No trailing period
- ≤72 characters for the full `type(scope): description` line
- Describes the logical change, not the files changed: `add status field to Invoice entity` — not `modify Invoice.java`

## Grouping Rules

**What goes together in one commit:**
- Production code for one plan task + its tests → always together
- A shared utility file and the task that primarily introduced it → together
- A configuration change and the code that requires it → together

**What must be split into separate commits:**
- Two distinct features or tasks, even if they touch the same file — split by task boundary
- A refactor and a behavior change — split so each commit leaves the build green
- Infrastructure setup and application code — split if they serve different tasks

**Key invariant:** Every commit in the sequence must leave the build in a passing state. A commit that breaks the build mid-sequence breaks `git bisect`. If staging a subset of changes would leave the build broken, re-examine the grouping.

## Catch-all Commit

If any changed files cannot be attributed to a specific plan task (e.g. auto-generated files, minor fixups not tied to a task):

```
chore(<scope>): miscellaneous changes from <key>
```

This commit goes last. It should be rare — most changes should map to a specific task.
