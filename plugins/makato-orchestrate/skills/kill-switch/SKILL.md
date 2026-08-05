---
name: kill-switch
description: >-
  Operator and budget kill-switches for the autonomous PO-agent (GAP-004 / #30).
  Composes four checks at every outer-loop boundary: HALT-file presence,
  GitHub claude-halt label, per-task token budget, and daily token-budget
  ceiling. Also coordinates the HALT-007B proactive context handoff via
  scripts/context-handoff.sh. Used only by the PO-agent — never invoked
  by sub-agents or user-facing skills.
version: "1.0.0"
argument-hint: "<subcommand> <key> [args…]"
allowed-tools: [Bash]
---

<!-- markdownlint-disable MD013 -->

# kill-switch

> **Mission**: Provide the autonomous PO-agent with a single, composable kill-switch surface.
> Four orthogonal checks, one return code. Either the loop continues, or it terminates with a
> documented HALT code.

## When to Use

Use **only** from the PO-agent outer loop (GAP-006 / #32). The skill encapsulates four
distinct shutdown mechanisms so the PO-agent's main loop stays a single conditional:

```bash
# Inside PO-agent's outer loop (pseudocode):
for task in workflow_state.sub_tasks:
    /makato-orchestrate:kill-switch poll <KEY>      # exits non-zero if any HALT fires
    /makato-orchestrate:kill-switch handoff <KEY>   # exits 2 if context handoff initiated
    dispatch_coder(task)
    record_result_to_state(task, r1)
```

Do **not** call from sub-agents, build-* skills, or user-facing commands. The PO-agent is the
sole consumer; the kill-switch's writes (halt_audit, restart_failed, session_count,
needs-human-review label) are state-machine transitions only the PO-agent is authorised to make.

**Do NOT load this skill if:** you are inside a build-*, makato-change, or makato-plan skill;
if you are a sub-agent dispatched by the PO-agent; or if the task is user-initiated rather
than part of the autonomous outer loop.

## Subcommand-Dispatch Framework

Each of the four subcommands has exactly one correct moment in the PO-agent loop:

| Subcommand | When to call | Who may call |
|------------|-------------|--------------|
| `poll` | Before every `dispatch_coder` call | PO-agent only |
| `handoff` | Immediately after a passing `poll`, before dispatch | PO-agent only |
| `record-budget` | After every sub-agent dispatch returns its R1 | PO-agent only |
| `reset-daily-budget` | Operator-only; never inside the automated loop | Operator only |

The PO-agent never branches on individual HALT codes inside the loop body. It checks `poll`'s
exit code (0 = proceed, non-zero = stop), then reads `halt_audit[-1]` for logging and
`needs-human-review` labelling. This single-conditional design is the core invariant — adding
per-HALT-code branches in the outer loop is an anti-pattern (see Anti-Patterns below).

## Operator-facing controls

Three operator levers exist outside the PO-agent's control loop. Documenting them here so the
PO-agent's dispatch contract is explicit.

### Lever 1 — Drop a HALT file

```bash
echo "stopping for lunch" > ~/.claude/HALT
```

The `hooks/check-halt.sh` PreToolUse hook fires on every `Bash` tool call. A non-empty
`HALT` file blocks the next tool call entirely. PO-agent sees the failed tool result, runs
`kill-switch poll` at the next loop boundary, writes HALT-000 to `halt_audit`, exits.

**Resumption**: `rm ~/.claude/HALT && plugins/makato-orchestrate/scripts/loop.sh run` — invoke the loop entry point (which threads the po-agent delegation prompt); do not invoke `claude -p` directly with an ad-hoc prompt (see #160).

### Lever 2 — Apply the `claude-halt` GitHub label

```bash
gh issue edit <N> --add-label claude-halt
```

`kill-switch poll` checks the target issue's labels at every outer-loop boundary (≈ 60-second
cadence). A `claude-halt` label triggers HALT-009. The PO-agent applies `needs-human-review`
and terminates; the operator's `claude-halt` label is preserved as their intent marker.

**Resumption**: `gh issue edit <N> --remove-label claude-halt --remove-label needs-human-review`,
then re-invoke `loop --autonomous <N>`.

### Lever 3 — Set token budget ceilings via env vars

| Variable | Default | HALT |
|----------|---------|------|
| `MAKATO_DAILY_TOKEN_BUDGET` | unset (no daily ceiling) | HALT-007 when daily total ≥ ceiling |
| `MAKATO_CONTEXT_WARN_TOKENS` | 150000 | HALT-007B at run-level threshold (handoff path) |
| `MAKATO_MAX_HANDOFFS` | 5 | HALT-007 when handoff cap reached |
| `MAKATO_HANDOFF_DISABLE` | 0 | Forces HALT-007 fallback instead of handoff |

Per-task `budget_limit_tokens` (default 500000) is stored in `workflow-state.json` and patched
by the PO-agent on `init`. The daily ceiling is tracked at
`.claude/state/daily-budget-{YYYY-MM-DD}.json` — a separate file from workflow-state because
its lifecycle is per-day, not per-issue.

## Operations

### `poll <KEY>`

Single composite check. Exits non-zero on the first HALT that fires; the PO-agent treats the
exit code as the HALT signal and reads `halt_audit[-1]` to learn which code fired.

**Sequence** (short-circuits at first failure):

1. **HALT-000** — Re-check `~/.claude/HALT` even though the PreToolUse hook also checks it. The
   hook only fires on `Bash`; not every outer-loop iteration runs a `Bash` call. Belt and braces.
2. **HALT-009** — Query `gh issue view <issue_number> --json labels`. If `claude-halt` is in the
   label list, append HALT-009, apply `needs-human-review`, also call
   `shared/post-halt-comment.sh HALT-009 $issue_number $REPO` (best-effort), exit 1.
3. **HALT-007 (per-task)** — Read `budget_consumed_tokens` and `budget_limit_tokens` from state.
   If consumed ≥ limit, append HALT-007 with `data.trigger: "per_task"`, apply
   `needs-human-review`, also call `shared/post-halt-comment.sh HALT-007 $issue_number $REPO` (best-effort), exit 1.
4. **HALT-007 (daily)** — Read `.claude/state/daily-budget-{YYYY-MM-DD}.json` (zero-init if
   missing). If today's cumulative ≥ `MAKATO_DAILY_TOKEN_BUDGET` (when set), append HALT-007
   with `data.trigger: "daily"`, apply `needs-human-review`, also call
   `shared/post-halt-comment.sh HALT-007 $issue_number $REPO` (best-effort), exit 1.
5. **HALT-008** — Read `outer_iteration` from state. If `outer_iteration >= 3`, append HALT-008,
   apply `needs-human-review`, also call `shared/post-halt-comment.sh HALT-008 $issue_number $REPO` (best-effort), exit 1. This poll enforces **only** the re-plan budget
   (`outer_iteration`). The two other HALT-008 origins — `merge_conflict_cycles` (GAP-016 / #45)
   and `ci_failure_cycles` (#288) — are enforced by direct pre-dispatch checks in the PO-agent
   (Step 6 conflict sub-loop and Step 6a CI-failure fix loop respectively), NOT here, so their
   independent budgets are never conflated with the re-plan counter.

If all five checks pass, exit 0.

```bash
/makato-orchestrate:kill-switch poll gap-004
```

### `handoff <KEY> <ISSUE_NUMBER>`

Delegates to `scripts/context-handoff.sh check <KEY> <ISSUE_NUMBER>`. Single-line shim — exists so the
PO-agent's loop reads as four parallel kill-switch concerns rather than three plus a
shell-script call. Exit codes pass through unchanged:

| Exit | Meaning |
|------|---------|
| 0    | Per-session context delta (`budget_consumed_tokens - session_baseline_tokens`) below `context_warn_tokens` — no-op. |
| 2    | HANDOFF initiated. The current session must exit cleanly; the resume script has been emitted. |
| 1    | HALT-007 fallback fired (cap exceeded, summariser missed, or restart-binary missing). |

```bash
/makato-orchestrate:kill-switch handoff gap-004 42
```

### `record-budget <KEY> <ISSUE_NUMBER> <DELTA_TOKENS>`

Increment `budget_consumed_tokens` by `DELTA_TOKENS` AND increment the daily ledger by the
same amount. Used by the PO-agent after every sub-agent dispatch (it reads `tool_calls_used`
and a token estimate from the R1 envelope, multiplies by the model's price tier, and calls
this skill). The skill increments both counters atomically; computing an accurate `DELTA_TOKENS`
is the caller's responsibility — supply actual R1 figures, not pre-dispatch estimates (see
Anti-Patterns).

The daily ledger schema lives at @references/daily-budget.schema.json.

MANDATORY: load `@references/daily-budget.schema.json` if you need to validate or inspect the
ledger structure after a `record-budget` or `reset-daily-budget` call.

```bash
/makato-orchestrate:kill-switch record-budget gap-004 42 12500
```

### `reset-daily-budget`

For the operator only. Truncates today's daily-budget ledger to zero. Use after raising
`MAKATO_DAILY_TOKEN_BUDGET` mid-day if the operator wants the new ceiling to apply from now
rather than from the day's start.

```bash
/makato-orchestrate:kill-switch reset-daily-budget
```

## Daily-budget ledger

`.claude/state/daily-budget-{YYYY-MM-DD}.json` is a small JSON file with a single object:

```json
{
  "date": "2026-06-28",
  "consumed_tokens": 1843200,
  "runs": [
    {"issue": 30, "tokens": 152340, "ts": "2026-06-28T14:23:01.456Z"},
    {"issue": 31, "tokens": 1690860, "ts": "2026-06-28T18:11:08.012Z"}
  ],
  "ceiling_tokens": 2000000,
  "updated_at": "2026-06-28T18:11:08.012Z"
}
```

- `consumed_tokens` is the running total this UTC day.
- `runs[]` is append-only — every `record-budget` call adds an entry. The PO-agent reads it
  via `kill-switch poll` to see whether today's total has crossed the ceiling.
- `ceiling_tokens` is captured from `MAKATO_DAILY_TOKEN_BUDGET` at first write of the day; if
  the env var is unset, the field is omitted entirely and the daily check is a no-op.
- Files older than 30 days are auto-pruned by the PO-agent on session start (separate skill —
  out of scope for GAP-004).

## HALT codes this skill emits

| Code | Trigger | Action |
|------|---------|--------|
| HALT-000 | `~/.claude/HALT` exists | Append audit, exit 1. No `needs-human-review` label. |
| HALT-007 (per_task) | `budget_consumed_tokens >= budget_limit_tokens` | Append audit, apply label, exit 1. |
| HALT-007 (daily) | Daily ledger ≥ `MAKATO_DAILY_TOKEN_BUDGET` | Append audit, apply label, exit 1. |
| HALT-007 (handoff fallback) | Via `context-handoff.sh` — restart_failed or cap exceeded | Append audit, apply label, exit 1. |
| HALT-007B | Via `context-handoff.sh` — per-session delta (`consumed - session_baseline_tokens`) reached `context_warn_tokens` (#281) | Append audit, no label, exit 2. |
| HALT-008 | `outer_iteration >= 3` (re-plan budget only; `merge_conflict_cycles` and `ci_failure_cycles` enforced by the PO-agent, not this poll) | Append audit, apply label, exit 1. |
| HALT-009 | `claude-halt` label on GitHub issue | Append audit, apply label, exit 1. Preserve `claude-halt`. |

See `plugins/makato-orchestrate/halt-conditions.md` for the full table including codes this
skill does NOT emit (HALT-001 through HALT-006 are emitted by makato-build).

## Anti-Patterns

**NEVER call this skill from a sub-agent, build-* skill, or user-facing command.**
WHY: the kill-switch writes state-machine transitions (`halt_audit`, `session_count`,
`needs-human-review` label) that are authorised only at the PO-agent outer-loop boundary. A
sub-agent call produces out-of-sequence HALT audit entries and can double-apply
`needs-human-review` on an issue still actively being worked, corrupting the operator's
resumption signal with a false-positive halt.

**NEVER invoke `claude -p` directly for resumption; always use `loop.sh run`.**
WHY: bypassing `loop.sh` loses the `_pre_dispatch_plan_guard` (plan-presence gate), the
`_within_dispatch_guard` (concurrency mutex), and the board CAS claim (cross-machine
double-dispatch lock). The result is a headless session with no self-HALT path and no
idempotency guarantee — two sessions can dispatch against the same issue simultaneously
(issue #160).

**NEVER conflate `outer_iteration` with `merge_conflict_cycles` or `ci_failure_cycles`.**
WHY: these three counters are independent retry budgets with separate ceilings. Routing all
three through a single `poll`-side HALT-008 check would allow a runaway CI-failure loop to
consume the re-plan budget, or a conflict loop to false-trigger the ceiling before any
re-plan attempt has occurred. Each counter's ceiling is enforced at its own decision site
in the PO-agent.

**NEVER pass an estimated `DELTA_TOKENS` to `record-budget`; use the actual R1 figure.**
WHY: the daily ledger is append-only and non-rewindable. Over-reporting silently throttles
subsequent runs on the same day; under-reporting silently bypasses the daily ceiling.
`record-budget` increments atomically — correctness depends entirely on the caller supplying
the real token count from the R1 envelope's `tool_calls_used` field, not a pre-dispatch
estimate.

**NEVER add HALT-code-specific branches inside the PO-agent outer loop.**
WHY: the single-conditional design (`if poll exits non-zero → read halt_audit[-1] and log`)
is what keeps the outer loop auditable and the kill-switch surface composable. Per-code
branches inside the caller would couple the PO-agent to kill-switch's internal taxonomy,
forcing dual-file edits for every future HALT code addition.

## JSONL Audit

Every poll that fires a HALT, and every `record-budget` call that crosses a ceiling, MUST be
appended to `specs/<key>-<slug>/orchestrate.jsonl`:

```json
{"ts":"2026-06-28T14:23:01.456Z","skill":"kill-switch","issue":30,"step":"poll","status":"warn","data":{"halt_code":"HALT-007","trigger":"daily"},"error":"daily ledger exceeded MAKATO_DAILY_TOKEN_BUDGET"}
```

`record-budget` calls that DO NOT cross a ceiling are NOT audited — the workflow-state diff
is already on record via `workflow-state.sh patch`, and adding an audit line per dispatch
would dwarf the rest of the log.

## Dependencies

- `bash`, `jq`, `python3` — same as `workflow-state`.
- `gh` CLI authenticated against the target repo — for HALT-009 label polling and
  `needs-human-review` application.
- `scripts/context-handoff.sh` — delegated to for `handoff` subcommand.

## Verification

The `handoff` subcommand is covered by `scripts/context-handoff-smoke-tests.sh` (T1–T15;
run from repo root). The 15 scenarios exercise all HALT-007B and HALT-007 fallback paths
including delta-baseline calculation (#281) and liveness-watchdog supervision (#284).

Dedicated smoke tests for the `poll` and `record-budget` subcommands are a planned follow-on
— `references/kill-switch-smoke-tests.sh` does not yet exist. Until then, verify the five
`poll` shutdown paths against `halt-conditions.md` and confirm each produces the correct
`halt_code` entry in `orchestrate.jsonl`.
