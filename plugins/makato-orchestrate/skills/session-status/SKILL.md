---
name: session-status
description: >-
  Read-only SessionStart hook reference (GAP-014 / #31). Documents
  `plugins/makato-orchestrate/hooks/session-status.sh`, which scans
  `specs/*/workflow-state.json` and prints a one-line banner per active
  workflow when a Claude Code session opens — so operators can see at a
  glance whether a run is in progress, what phase it's in, how much of the
  budget is consumed, whether a HALT fired, and when state was last updated.
  Read-only by design: PO-agent (GAP-006 / #32) remains the sole writer of
  workflow-state.json.
version: "1.0.0"
argument-hint: "(none — fires automatically on SessionStart)"
---

<!-- markdownlint-disable MD013 -->

# session-status

## When to Use

`session-status.sh` is a **SessionStart hook**, not an invocable skill. It fires automatically when a new Claude Code session opens, before any prompt is entered. Wire it into the consumer repo's `.claude/settings.json` (snippet below) and forget it — it has no operator-facing surface.

Do **not** call this script from skills, agents, or scripts. The runtime triggers it; manual invocation is meaningful only when smoke-testing.

## Purpose

When an operator opens a new Claude Code session in a repo that hosts autonomous PO-agent runs, there is no native signal telling them whether a workflow is already in progress, whether it's stalled, or whether a HALT fired. The banner prints:

- A global **HALT ACTIVE** warning when `~/.claude/HALT` exists — printed first, before any per-workflow line.
- One line per `specs/<key>-<slug>/workflow-state.json` found, showing: issue number, current phase, budget consumed vs. limit (with percentage), HALT count, last `updated_at` timestamp, and the last HALT code if any.
- A `⚠ STALE — resume: /loop --autonomous <issue>` marker on any workflow whose `updated_at` is more than 24 hours ago.
- `No active workflows` and exit 0 when no state files exist.

This prevents duplicate dispatches, surfaces blocked workflows immediately, and gives the operator a resume command they can paste back into the same session.

## settings.json wiring

Copy the following entry into the consumer repo's `.claude/settings.json` under `hooks.SessionStart`:

```json
{
  "matcher": "SessionStart",
  "hooks": [{
    "type": "command",
    "command": "${CLAUDE_PLUGIN_ROOT}/hooks/session-status.sh",
    "timeout": 10000
  }]
}
```

A 10 s timeout is well above the typical sub-second runtime; it exists only to abort a runaway scan over an exceptionally large `specs/` tree. The hook never blocks the session — it is informational only, and prints to stdout (surfaced to the operator at session start).

## Output format

```text
═══════════════════════════════════════════════════════════════
⛔  HALT ACTIVE — remove /Users/<you>/.claude/HALT to resume
═══════════════════════════════════════════════════════════════
Active workflows:
  #31 | phase: implement | budget: 25000/100000 (25%) | halts: 0 | updated: 2026-06-29T11:00:00.000Z
  #42 | phase: refine    | budget: 80000/100000 (80%) | halts: 1 | updated: 2026-06-28T10:30:00.000Z | HALT: HALT-008 ⚠ STALE — resume: /loop --autonomous 42
```

When nothing is running:

```text
No active workflows
```

## Environment variables

| Variable                         | Default               | Purpose |
|----------------------------------|-----------------------|---------|
| `MAKATO_HALT_FILE`               | `$HOME/.claude/HALT`  | Override the kill-switch file path. Shared with `check-halt.sh` so a single override covers both hooks during tests. |
| `MAKATO_DISABLE_SESSION_STATUS`  | unset                 | Set to `1` to short-circuit the hook and exit 0 silently. Reserved for emergencies (broken `jq`, corrupted `specs/`, hostile state file) and CI runs where a banner is noise. |
| `MAKATO_SPECS_ROOT`              | `<repo-root>/specs`   | Override the directory scanned for `*/workflow-state.json`. Used by smoke tests; not used in production. |
| `MAKATO_STALE_HOURS`             | `24`                  | Hours after which `updated_at` is considered stale. Mostly a knob for tests. |

## Failure semantics

- **`jq` missing** — prints `session-status: jq not found, skipping banner` to stderr and exits 0. Session continues.
- **Not a git repo and no `MAKATO_SPECS_ROOT`** — exits 0 silently. There is nothing to scan.
- **Malformed `workflow-state.json`** — that file is skipped with a `⚠ malformed: <path>` warning to stderr; other workflows still print.
- **Missing `budget_limit_tokens` / division by zero** — printed as `?%` rather than crashing.
- **All other failures** — the hook never raises a non-zero exit that would block a session start. SessionStart hooks must not be gates.

## Read-only contract

`session-status.sh` reads `workflow-state.json` files; it **never writes** them. The PO-agent (GAP-006 / #32) is the sole writer in steady state — see `AGENTS.md` § *Design Principles* and `never-patterns.md` NEVER 4. Any PR adding a write call to this hook must be rejected at code review.

## Related

- `plugins/makato-orchestrate/hooks/check-halt.sh` — PreToolUse hook reading the same HALT file (GAP-004 / #30).
- `plugins/makato-orchestrate/shared/workflow-state.sh` — the canonical writer of `workflow-state.json` (GAP-003 / #26).
- `plugins/makato-orchestrate/skills/workflow-state/references/workflow-state.schema.json` — schema this hook reads from.
- `plugins/makato-orchestrate/hooks/session-status-smoke-tests.sh` — 8 smoke tests covering every banner path.
