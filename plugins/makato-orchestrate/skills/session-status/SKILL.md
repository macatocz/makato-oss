---
name: session-status
description: >-
  Read-only SessionStart hook that prints a one-line banner per active
  workflow when a Claude Code session opens (GAP-014 / #31). Scans
  `specs/*/workflow-state-<issue>.json`, surfaces HALT-ACTIVE / STALE /
  budget warnings, and gives operators a paste-ready resume command.
  Relevant whenever wiring the hook, interpreting the startup banner,
  diagnosing a stale or blocked run, or understanding why a duplicate
  dispatch was prevented. NOT an agent-invocable skill — do not call
  this from sub-agents or skills; the runtime triggers it automatically.
version: "1.1.0"
argument-hint: "(none — fires automatically on SessionStart)"
metadata:
  authors: ["makato-orchestrate"]
  last_updated: "2026-08-05"
---

<!-- markdownlint-disable MD013 -->

# session-status

## When to Use

`session-status.sh` is a **SessionStart hook**, not an invocable skill. It fires automatically when a new Claude Code session opens, before any prompt is entered.

**Do NOT Load this skill** if you are a sub-agent, build agent, or coder — the runtime triggers the hook; you do not interact with it. Load this skill only when:

- Wiring the hook into a new consumer repo's `.claude/settings.json`
- Interpreting STALE / HALT-ACTIVE / high-budget banners and deciding what to do next
- Smoke-testing the hook or customizing its env-var behaviour
- Reviewing a PR that touches `hooks/session-status.sh`

## Acting on the Banner (Decision Table)

This is the most commonly missed part. The banner prints on session open; here is what to do for each signal:

| Banner signal | What it means | Operator action |
|---|---|---|
| `⛔ HALT ACTIVE` | `~/.claude/HALT` file exists — all loop iterations are blocked | Verify no run is in flight, then: `rm ~/.claude/HALT` |
| `⚠ STALE — resume: /loop --autonomous <N>` | `updated_at` > 24 h ago; PO-agent likely crashed or was killed | Check if a worktree is still live (`git worktree list`); if stale, clean it up, then paste the printed `/loop --autonomous <N>` command |
| `budget: X/Y (>= 80%)` | Current run is within 20% of its token ceiling | Consider `HALT-008` will fire soon; review open tasks vs remaining budget before adding scope |
| `halts: N | HALT: HALT-XXX` | The last run hit a halt condition | Read `specs/<key>/workflow-state-<issue>.json` `.halt_audit[-1]`; act on the specific HALT code per `halt-conditions.md` |
| `No active workflows` | Clean slate; no `specs/*/workflow-state-*.json` files found | Nothing to act on; safe to dispatch |

**Agents loading this skill mid-session:** if the banner shows a workflow for the same issue you are about to implement, stop and return HALT-002 (duplicate dispatch) rather than proceeding.

## Anti-patterns

### NEVER write to `workflow-state.json` from this hook

WHY: The PO-agent (GAP-006 / #32) holds the sole-writer contract on `workflow-state.json` (AGENTS.md, never-patterns.md NEVER 4). SessionStart fires before any prompt — a write here would silently corrupt the audit trail or race with an in-flight PO-agent that resumes the same file. Any PR adding a write call to `session-status.sh` must be rejected at code review.

### NEVER exit non-zero from a SessionStart hook

WHY: A non-zero exit from a SessionStart hook blocks the entire session from opening. The operator would be locked out of Claude Code whenever `jq` is missing, the repo is not a git tree, or a state file is corrupted — none of which should prevent a session. All error paths in this hook fall back to a warning on stderr and `exit 0`.

### NEVER call this script from sub-agents or other skills

WHY: The runtime calls it exactly once per session open. A manual invocation from a skill or agent produces a spurious duplicate banner mid-session, confusing operators about the session state. Use `MAKATO_DISABLE_SESSION_STATUS=1` in test harnesses when you need to suppress the banner; do not invoke the script directly.

### NEVER rely on this banner to gate phase transitions or drive decisions

WHY: The banner is informational — it reflects the last-written state file, not a live process signal. A phase shown as "implement" may have already moved to "pr" if the PO-agent ran after the session-state snapshot. Gate transitions on `workflow-state.json` reads in the PO-agent's own loop, not on banner output.

### NEVER add sleeps, network calls, or API calls to this hook

WHY: SessionStart fires synchronously before any prompt. Blocking calls add latency every time an operator opens a session, turning a sub-second banner into a multi-second wait. The 10 s timeout in `settings.json` exists as an emergency abort, not a budget.

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

The 10 s timeout is well above the typical sub-second runtime. It exists only to abort a runaway scan over an exceptionally large `specs/` tree. The hook never blocks the session — it is informational only and prints to stdout.

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

## State file layout

The hook scans two glob patterns to cover both layouts:

- **Per-issue layout (current, #173):** `specs/<N>-<slug>/workflow-state-<issue>.json`
- **Legacy layout (migrated on next PO-agent mutation):** `specs/<N>-<slug>/workflow-state.json`

The per-issue layout allows multiple issues per spec folder. Until migration, legacy files on disk continue to be picked up and rendered exactly like per-issue files — the banner field extraction is identical.

Fields read per file (one `jq` invocation, not six forks):

| Field | Banner label | Fallback |
|---|---|---|
| `.issue_number` | `#<N>` | `?` |
| `.current_phase` | `phase:` | `?` |
| `.budget_consumed_tokens` | `budget: X/` | `0` |
| `.budget_limit_tokens` | `/Y` | `0` (renders as `?%`) |
| `.updated_at` | `updated:` | `""` (stale check skipped) |
| `.halt_audit \| length` | `halts:` | `0` |
| `.halt_audit[-1].code` | `HALT:` | omitted if `halts: 0` |

## Environment variables

| Variable | Default | Purpose |
|---|---|---|
| `MAKATO_HALT_FILE` | `$HOME/.claude/HALT` | Override the kill-switch file path. Shared with `check-halt.sh` so a single override covers both hooks during tests. |
| `MAKATO_DISABLE_SESSION_STATUS` | unset | Set to `1` to short-circuit and exit 0 silently. Use in CI runs (banner is noise) and emergencies (broken `jq`, corrupted `specs/`). |
| `MAKATO_SPECS_ROOT` | `$(git rev-parse --show-toplevel)/specs` | Override the directory scanned for `workflow-state-*.json`. Used in smoke tests; production uses the git-root derivation. |
| `MAKATO_STALE_HOURS` | `24` | Hours after which `updated_at` is considered stale. Non-numeric values are sanitised back to 24. |

## Failure semantics

Each failure mode exits 0 so the session always opens:

| Condition | Behaviour |
|---|---|
| `jq` missing | Prints `session-status: jq not found, skipping banner` to stderr; exits 0 |
| Not a git repo and no `MAKATO_SPECS_ROOT` | Exits 0 silently — nothing to scan |
| `MAKATO_SPECS_ROOT` set but absent | `nullglob` returns empty array; prints `No active workflows` |
| Malformed `workflow-state.json` | File skipped with `⚠ malformed: <path>` to stderr; other workflows still print |
| Missing `budget_limit_tokens` / division by zero | Budget renders as `?%`; line still prints |
| `updated_at` unparseable by both GNU `date -d` and BSD `date -j -f` | `updated_epoch` defaults to 0; stale check skipped for that file |
| All other failures | Hook never raises a non-zero exit. SessionStart hooks must not be gates. |

## Read-only contract

`session-status.sh` reads `workflow-state.json` files; it **never writes** them. The PO-agent (GAP-006 / #32) is the sole writer in steady state — see `AGENTS.md` § *Design Principles* and `never-patterns.md` NEVER 4. Any PR adding a write call to this hook must be rejected at code review.

## Related

- `plugins/makato-orchestrate/hooks/check-halt.sh` — PreToolUse hook reading the same HALT file (GAP-004 / #30)
- `plugins/makato-orchestrate/shared/workflow-state.sh` — the canonical writer of `workflow-state.json` (GAP-003 / #26)
- `plugins/makato-orchestrate/skills/workflow-state/references/workflow-state.schema.json` — schema this hook reads from
- `plugins/makato-orchestrate/hooks/session-status-smoke-tests.sh` — 8 smoke tests covering every banner path
- `plugins/makato-orchestrate/halt-conditions.md` — HALT code registry; reference when acting on a HALT banner
