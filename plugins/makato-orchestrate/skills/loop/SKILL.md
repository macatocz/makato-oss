---
name: loop
description: >-
  Autonomous polling driver for the PO-agent (GAP-007 / #33). Polls a
  GitHub Projects v2 **board** for items whose Status equals the
  configured "ready" option (default "Ready") and dispatches the
  PO-agent serially against each untracked item. Single-threaded by
  construction — the next item is not picked up until the current
  `workflow-state.json` reaches `current_phase: "done"` or the loop
  exits on a HALT. Honors `~/.claude/HALT` before every dispatch
  (NEVER 3) and emits `.claude/state/loop-status.json` as the
  operator-facing live audit.
version: "1.4.0"
argument-hint: "[--status <NAME>] [--interval <S>] [--dry-run] [--once] [--force]"
---

<!-- markdownlint-disable MD013 -->

# loop

> **Mission**: Replace the per-issue human dispatch of the PO-agent with an
> unattended polling driver. The PO-agent (GAP-006 / #32) drives a single
> issue to a merged PR; `loop` decides which issue is next and when.

## Why the board is the queue source

The makato suite tracks work state on a **GitHub Projects v2 board**, not
on issue labels. The `status:*` label taxonomy (`status:ready`,
`status:in-progress`, `status:in-review`, `status:blocked`, `status:done`,
`status:todo`) is documented in
`plugins/makato-plan/skills/issue-to-project/SKILL.md` but is **dormant for
auto-emission**: `to-issues` v3.2.0 emits only `status:blocked`, and
`issue-to-project` writes Status on the board instead of mutating labels.

A label-driven `/loop` would therefore poll into a void — there is no
`status:ready` label in the repo's label set. Reading the board's Status
field directly puts `loop` on the same source of truth as the sibling
`issue-to-project sync-lifecycle` flow, so the operator's intent
(`status:ready` → board `Ready` via `issue-to-project`, or manual board
edit) cascades straight into the queue.

## When to Use

Use **only** from the operator's terminal (or a `tmux`/`nohup` wrapper)
when starting an unattended run across a queue of `Ready` items. The
skill is the entry point for autonomous mode — every other autonomous
component (PO-agent, kill-switch, workflow-state, context-handoff) is
dispatched from this loop, never the other way around.

Do **not** invoke from sub-agents, `build-*` skills, or the PO-agent
itself. The loop's invariants (single-threaded dispatch, board filtering,
HALT-file polling at the outer-most boundary) assume it owns the session.

## Prerequisites

- `.claude/config.json` → `github_project` is populated. Run
  `/makato-plan:issue-to-project --init` once per repo before the first
  `loop` invocation. `loop` reads `github_project.owner`,
  `github_project.number`, and `github_project.host` from this block.
- The board has a `Status` single-select field with at least one option
  named "Ready" (the makato project board, `macatocz/projects/4`, has
  this by default). To use a different option name, pass
  `--status <NAME>` or export `MAKATO_LOOP_STATUS`.
- `gh` is authenticated with the `project` OAuth scope. The sibling
  `issue-to-project` pre-flight check 4 fails loudly when this is
  missing; `loop` simply returns an empty queue (`gh` stderr suppressed)
  so a misconfigured operator's loop idles instead of spinning.

## Invocation

```bash
# Long-running default (poll every 300 s, Status=Ready)
plugins/makato-orchestrate/scripts/loop.sh run

# Custom Status name and 60 s cadence
plugins/makato-orchestrate/scripts/loop.sh run --status Ready --interval 60

# Inspect the queue without dispatching anything
plugins/makato-orchestrate/scripts/loop.sh run --dry-run --once

# One poll-and-dispatch cycle (smoke-test or one-shot mode)
plugins/makato-orchestrate/scripts/loop.sh run --once
```

The driver also exposes lower-level subcommands for diagnostics:

| Subcommand | Purpose |
|------------|---------|
| `poll [STATUS_NAME]` | Print the board queue as JSON (wraps `gh project item-list`); filters to `Issue` content at the requested Status. |
| `next [STATUS_NAME]` | Print the issue number that would be dispatched next, or empty if none. |
| `status` | Pretty-print `.claude/state/loop-status.json`. |
| `dispatch <ISSUE> [--dry-run]` | Manually dispatch one issue. |
| `check-halt` | Exit 0/1 mirroring `hooks/check-halt.sh`. |

## Process

Each outer iteration of `run` performs the following steps in order:

1. **HALT check.** `check-halt` exits non-zero if `~/.claude/HALT` (or
   `$MAKATO_HALT_FILE`) is present — the loop exits cleanly (NEVER 3,
   HALT-000). The exit is recorded by stamping `.last_halt_at` in
   `loop-status.json`.
2. **Board poll.** `gh --hostname <host> project item-list <number>
   --owner <owner> --format json --limit 9999` runs and is filtered in
   two steps via `jq`:
   - Drop everything where `content.type != "Issue"` (DraftIssue and
     PullRequest items never enter the dispatch queue).
   - Keep only items whose `status` equals the requested Status name
     (default `Ready`).
   The output array carries `{issue, repository, title, url, status,
   labels}` per item. Network or `gh` errors degrade to an empty queue
   (the next poll retries); the loop does not fail hard on transient
   `gh` outages.
3. **Status checkpoint.** `loop-status.json` is patched with
   `last_poll`, `queue_depth`, the issue-number list under `queue`, and
   the operator-supplied `status_name` / `interval_seconds` /
   `dry_run` flags.
4. **In-flight filter.** Every `specs/*/workflow-state-*.json` (per-issue
   layout, #173; legacy `specs/*/workflow-state.json` files also parsed as
   a fallback until they migrate on next mutation) is scanned
   for `issue_number` + `current_phase`. Any issue whose state file
   exists and is NOT `current_phase: "done"` is considered in-flight
   and skipped — this guarantees single-threaded execution across
   restarts as well as within one session.
5. **Dispatch.** The first untracked issue is handed to `dispatch
   <issue>` which:
   - Writes `.active_workflow = {issue, started_at}` to
     `loop-status.json` before forking.
   - `exec`s `MAKATO_HEADLESS=1 $MAKATO_CLAUDE_BIN --dangerously-skip-permissions -p "<prompt that dispatches makato-orchestrate:po-agent via the Task tool for issue #<issue>>"`.
     The prompt explicitly names the po-agent subagent so the top-level
     Claude session delegates instead of running `makato-build` skills
     directly (which would default to interactive mode and deadlock a
     headless `claude -p` on the first `AskUserQuestion` — see #160).
     The prompt carries the po-agent's four required inputs
     (`ISSUE_NUMBER`, `KEY`, `REPO`, `BRANCH`, `REPO_ROOT`): `KEY` is the
     feature slug derived from the issue body's `to-issues` provenance
     (footer `*Feature slug: …*`, or the top-of-body
     `specs/<slug>/stories.json` line as fallback); `REPO` comes from the
     board poll's `repository` field; `BRANCH` is `feat/<issue>-<KEY>`
     (the po-agent creates it via `worktree.sh --new-branch` when absent);
     `REPO_ROOT` is the local repo root. Without these the po-agent fails
     input validation with `missing input: KEY` and never starts — the
     #144 crash. When the body has no provenance (a non-`to-issues`
     issue), `KEY` degrades to empty and a `WARN` is logged; the po-agent
     then surfaces the input-validation failure with a clear audit rather
     than dispatching blind.
     `MAKATO_HEADLESS=1` is the defensive belt: if the delegation prompt
     is somehow ignored and a `build-*` skill fires interactively, its
     Step 1b headless guard (see `plugins/makato-build/AUTONOMOUS-MODE.md`
     § "Defensive-headless guard") HALTs with `MISSING_INPUT` instead of
     hanging on `AskUserQuestion` — see #163.
     The child's combined stdout+stderr is captured to
     `.claude/state/dispatch-<issue>.log`; a background watchdog
     (see §*Liveness watchdog*) polls the log's mtime and escalates to
     WARN / SIGTERM if the PO-agent goes silent — see #164.
     The call blocks for the PO-agent's lifetime; on return,
     `.active_workflow` is cleared regardless of exit code.
   - Returns the PO-agent's exit code unchanged. The loop discards it
     deliberately — terminal state belongs to `workflow-state.json`,
     and the next poll re-derives ground truth instead of trusting an
     exit code.
6. **Sleep.** `sleep $interval_seconds`. The cycle repeats from step 1.

`--once` short-circuits step 6 and exits after one cycle. `--dry-run`
replaces the `exec` in step 5 with a stderr line; everything else
behaves identically (useful in CI smoke tests).

## Single-thread guarantee

The loop is intentionally serial. Four layers enforce this:

- The **run-mutex pidfile** at `.claude/state/loop.pid` refuses a
  second `run` invocation while a live one owns the state dir
  (see §*Run mutex* below). This is the layer that would have caught
  the #172 incident (plugin-cache `loop.sh` running alongside
  working-tree `loop.sh` for six hours).
- The in-flight filter in step 4 excludes issues whose
  `workflow-state.json` is anything other than `current_phase: "done"`.
- `dispatch` refuses (exit code 2) if `.active_workflow.issue` is set to
  a different issue — defensive guard for operators who manually
  invoke `dispatch` while `run` is mid-cycle.
- `run` runs the PO-agent **inline** via `$CLAUDE_BIN`. The next poll
  cannot start until the subprocess exits.

This is the deliberate v1 design (see issue #33 Out of Scope: "Priority
ordering of issues in the queue (FIFO only in v1)"). Parallel dispatch
across multiple PO-agents is not supported and would require a separate
mutex around `loop-status.json` plus per-issue workflow-state isolation.

## Why we don't mutate the board / labels at dispatch

The issue #33 brief suggested removing `status:ready-for-dev` at dispatch
to prevent double-dispatch. Two reasons we don't:

1. There is no `status:ready-for-dev` label in the repo (or any
   `status:*` label except via `to-issues`); the board's `Status` field
   is the source of truth.
2. The in-flight filter already prevents double-dispatch and works
   across restarts. Label or Status mutation from `loop` would
   duplicate `issue-to-project sync-lifecycle`'s contract and risk
   racing the lifecycle webhook handler. `loop` leaves the board to
   `issue-to-project` — it only reads it.

### The one exception: assign-on-dispatch (#33)

`loop` stays strictly read-only against the **board** (the Status field),
but it *does* make one **repo** mutation at dispatch: it assigns the issue
to the dispatch actor via `gh issue edit --add-assignee` (default `@me`)
just before spawning the PO-agent. This is not a board write — it is the
`issues.assigned` webhook *trigger* that the `project-board-sync.yml` GHA
listens for and translates into a `Ready → In progress` Status move. The
split of responsibilities is preserved: `loop` never touches
`updateProjectV2ItemFieldValue`; the board sync workflow (the native
equivalent of `issue-to-project --from-webhook`) owns every Status write.

The assign is **best-effort** — a failed `gh` call is logged and swallowed,
never blocking dispatch. It is idempotent (GitHub's add-assignee API is a
no-op when already assigned) and the board sync is forward-only (a late
re-assign never rolls a card back from `In review`/`Done`). Disable the
whole behaviour with `MAKATO_LOOP_ASSIGN_ON_DISPATCH=0`; override the
assignee login with `MAKATO_LOOP_ASSIGNEE`.

## `loop-status.json` contract

`.claude/state/loop-status.json` is the operator-facing audit. It is
written atomically (via `mktemp` + `mv`) and stamps `updated_at` on
every write.

```json
{
  "status_name": "Ready",
  "interval_seconds": 300,
  "dry_run": false,
  "last_poll": "2026-06-28T18:23:14.812Z",
  "queue_depth": 3,
  "queue": [101, 102, 103],
  "active_workflow": {
    "issue": 101,
    "started_at": "2026-06-28T18:23:15.001Z",
    "stalled": false,
    "stalled_since": null,
    "killed_by_watchdog": false
  },
  "startup_audit": {
    "started_at": "2026-06-28T18:23:14.500Z",
    "script_path": "/Users/op/GITHUB/makato/plugins/makato-orchestrate/scripts/loop.sh",
    "pid": 12345,
    "ppid": 12344,
    "pidfile": "/Users/op/GITHUB/makato/.claude/state/loop.pid",
    "status_name": "Ready",
    "interval_seconds": 300,
    "dry_run": false
  },
  "last_halt_at": null,
  "last_dispatch_issue": 101,
  "last_watchdog_kill": null,
  "updated_at": "2026-06-28T18:23:15.001Z"
}
```

Field semantics:

| Field | Type | Meaning |
|-------|------|---------|
| `status_name` | string | Last `--status` argument the loop ran with (board Status option). |
| `interval_seconds` | integer | Configured poll cadence. |
| `dry_run` | boolean | True if the operator passed `--dry-run`. |
| `last_poll` | ISO-8601 ms \| null | Timestamp of the most recent `gh` poll. |
| `queue_depth` | integer ≥ 0 | Count of board Issue items at the requested Status at last poll. |
| `queue` | array<int> | Issue numbers from last poll (untracked-vs-in-flight not filtered — call `next` for that). |
| `active_workflow` | object \| null | `{issue, started_at, stalled, stalled_since, killed_by_watchdog}` while a dispatch is in flight; `null` between iterations. |
| `active_workflow.stalled` | boolean | Set by the watchdog when the PO-agent has been silent ≥ `MAKATO_LOOP_STALL_WARN` seconds. Warn-only; no signal is sent. |
| `active_workflow.stalled_since` | ISO-8601 ms \| null | Timestamp `stalled` was first flipped to `true`. |
| `active_workflow.killed_by_watchdog` | boolean | Set to `true` just before the watchdog SIGTERMs the PO-agent. Cleared with `active_workflow` when `cmd_dispatch` returns; the audit is preserved on `last_watchdog_kill`. |
| `startup_audit` | object \| null | `{started_at, script_path, pid, ppid, pidfile, status_name, interval_seconds, dry_run}` — identity of the process holding the run mutex (see §*Run mutex*). Stamped once at `run` startup; not updated per iteration. |
| `last_halt_at` | ISO-8601 ms \| null | Timestamp the loop last exited on HALT. |
| `last_dispatch_issue` | integer \| null | Issue number of the most recent dispatch (set by the `MAKATO_LOOP_DRY_DISPATCH` test hook and overwritten by real runs). |
| `last_watchdog_kill` | object \| null | `{issue, killed_at, idle_seconds, stall_kill_seconds}` — surviving audit of the most recent watchdog reap. `null` if the watchdog has never fired. |
| `updated_at` | ISO-8601 ms | Auto-stamped on every write. |

Operators can `tail -f .claude/state/loop-status.json | jq` (or
`watch -n 5 plugins/makato-orchestrate/scripts/loop.sh status`) to follow
the loop unattended.

## Run mutex

Every `run` invocation acquires a pidfile at
`.claude/state/loop.pid` (override via `MAKATO_LOOP_PIDFILE`). This is
the layer-1 defence against #172 — two `loop.sh` installations
polling the same repo in parallel, each writing to
`loop-status.json` and each dispatching PO-agents into the same
`specs/` tree.

**Contract:**

- Startup writes `$$` to the pidfile after checking that any
  existing entry names a dead PID. An EXIT trap removes the file on
  clean shutdown (crashes and `kill -9` leave a stale entry, which
  the next start reclaims silently).
- A live pidfile (PID responds to `kill -0`) causes the second
  invocation to exit `3` with an operator-facing message pointing at
  the incumbent PID and pidfile. `active_workflow`, `queue`, and
  `last_poll` in `loop-status.json` are untouched — the refusing
  instance never took ownership.
- `--force` reclaims a live pidfile by `SIGTERM`ing the incumbent
  (grace period `MAKATO_LOOP_FORCE_GRACE`, default 10 s, then
  `SIGKILL`). Use only when the incumbent is verifiably stuck; a
  cooperative `kill -TERM <pid>` from the operator's terminal is
  cleaner because it gives the incumbent's EXIT trap time to run.

**Startup audit.** On successful acquire, `loop-status.json` gets a
new `startup_audit` object identifying the process — script path
(canonicalised through `os.path.realpath`, so a symlinked plugin-
cache path resolves to its real disk location), PID, PPID, pidfile
path, and the CLI arguments the process was started with. Operators
who see two `loop.sh` processes in `ps` can cross-reference the audit
to tell which one owns the state dir. The audit is stamped once at
startup and not updated per iteration; the `updated_at` field on the
outer object tracks the last state write.

**Non-goals.** The mutex is process-scoped, not host-scoped or
cluster-scoped. Two operators running two loops against two different
state dirs (via `MAKATO_LOOP_STATE_DIR`) is supported by design — the
pidfile lives next to the state file, so it isolates naturally. A
`flock`-based cross-clone lock is out of scope; the #172 damage came
from *accidentally* parallel installs, not from a race between two
operators who both hit start in the same second.

## Liveness watchdog

Every real dispatch (i.e. not `--dry-run`, not `MAKATO_LOOP_DRY_DISPATCH`)
runs a background watchdog against the forked PO-agent subprocess. The
watchdog is defensive net-of-last-resort for the class of deadlock that
motivated #160 — it does not replace the PO-agent's own kill-switches
(HALT-file poll, GitHub label poll, token-budget); those fire at outer-
loop boundaries **inside** the PO-agent's session and cannot help when
the PO-agent itself never reaches its next boundary.

**Design:** output-mtime polling. `cmd_dispatch` redirects the child's
combined stdout+stderr to `.claude/state/dispatch-<issue>.log` and spawns
`_watchdog_poll` in the background. Every `MAKATO_LOOP_STALL_POLL` seconds
(default 60) the watchdog `stat`s the log file:

- **WARN** (`idle ≥ MAKATO_LOOP_STALL_WARN`, default 900 s = 15 min):
  stamp `active_workflow.stalled = true` and `active_workflow.stalled_since
  = <iso>` in `loop-status.json`. Operator visibility only — no signal is
  sent to the child. A single-shot latch: warning is stamped at most once
  per dispatch.
- **KILL** (`idle ≥ MAKATO_LOOP_STALL_KILL`, default 3600 s = 60 min):
  snapshot the audit to `last_watchdog_kill` (survives the
  `active_workflow=null` clear that `cmd_dispatch` does on return), stamp
  `active_workflow.killed_by_watchdog = true`, then `kill -TERM` the
  child. If the child is still alive after `MAKATO_LOOP_STALL_TERM_GRACE`
  seconds (default 30), `kill -KILL`. `cmd_dispatch`'s `wait "$child_pid"`
  then unblocks and the outer loop resumes on the next tick.

**Non-goals.** The watchdog is a coarse liveness proxy, not a semantic
progress meter — a busy-loop that prints a heartbeat every 10 seconds
will keep the log mtime fresh and pass the watchdog forever. Semantic
progress is the PO-agent's kill-switch's job. See #164 for the design
rationale and non-goals.

**Escape hatch:** `MAKATO_LOOP_STALL_DISABLE=1` skips log capture and
never spawns the watchdog. Use only for debug sessions where an operator
is attached and long silences are expected. Production runs should keep
it enabled.

## Kill-switches

`loop` itself implements only **HALT-000** (`~/.claude/HALT` polling at
the outer-loop boundary). Every other kill-switch fires inside the
PO-agent's session via the `kill-switch` skill — once the PO-agent has
HALTed, its `workflow-state.json` records the terminal phase and the
loop's next poll naturally excludes any issue still marked in-flight.

The intentional design split:

| Concern | Implemented by | Why |
|---------|----------------|-----|
| Queue HALT (stop picking up new issues) | `loop` (this skill) | The loop is the outermost frame; one HALT-file check per cycle is sufficient. |
| Per-issue HALT (cancel the active run) | `kill-switch poll` inside PO-agent | The PO-agent already polls every outer-iteration boundary; duplicating from `loop` would race the active subprocess. |
| Per-issue context handoff (HALT-007B) | `scripts/context-handoff.sh` inside PO-agent | The handoff respawns a fresh `claude --dangerously-skip-permissions --resume <KEY> -p "<po-agent delegation prompt>"` directly — the loop's role is only to start the first session, not to manage handoffs. The delegation prompt names the po-agent subagent for the same reason as the initial dispatch (see #160). |

## Environment variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `MAKATO_LOOP_INTERVAL` | `300` | Poll cadence in seconds (CLI `--interval` wins). |
| `MAKATO_LOOP_STATUS` | `Ready` | Default board Status option name (CLI `--status` wins). |
| `MAKATO_LOOP_CONFIG` | `<repo>/.claude/config.json` | Override config path (tests only). |
| `MAKATO_CLAUDE_BIN` | `claude` | Path to the claude binary used for dispatch. Tests stub this. |
| `MAKATO_HALT_FILE` | `~/.claude/HALT` | HALT-file path override (mirrors `hooks/check-halt.sh`). |
| `MAKATO_LOOP_STATE_DIR` | `<repo>/.claude/state` | Override status-file directory (tests only). |
| `MAKATO_LOOP_DRY_DISPATCH` | unset | Test-only: skip the real `claude` exec and record `last_dispatch_issue` instead. |
| `MAKATO_LOOP_GH_OVERRIDE` | unset | Test-only: read the canned `gh project item-list` JSON from this path instead of invoking `gh`. |
| `MAKATO_LOOP_ISSUE_BODY_OVERRIDE` | unset | Test-only: read the issue body from this path instead of invoking `gh issue view` in `_derive_key_for_issue`. Keeps the T25 KEY-derivation test offline. |
| `MAKATO_LOOP_STALL_WARN` | `900` | Seconds of no output before the watchdog stamps `active_workflow.stalled = true`. |
| `MAKATO_LOOP_STALL_KILL` | `3600` | Seconds of no output before the watchdog `SIGTERM`s the PO-agent. |
| `MAKATO_LOOP_STALL_POLL` | `60` | Watchdog poll cadence in seconds (small values used in smoke tests). |
| `MAKATO_LOOP_STALL_TERM_GRACE` | `30` | Seconds between `SIGTERM` and the follow-up `SIGKILL` if the child hasn't exited. |
| `MAKATO_LOOP_STALL_DISABLE` | unset | Set to `1` to disable the watchdog entirely (no log capture, no background poller, no status stamps). |
| `MAKATO_LOOP_STALL_TEST_CMD` | unset | Test-only: run this command in place of `claude` (e.g. `sleep 30`) so the watchdog has a real stall to reap. |
| `MAKATO_LOOP_PIDFILE` | `<state-dir>/loop.pid` | Override the run-mutex pidfile path (#172). Tests use this to isolate the mutex from any concurrent operator loop on the same box. |
| `MAKATO_LOOP_FORCE_GRACE` | `10` | Seconds between `SIGTERM` and `SIGKILL` when `run --force` reclaims a live pidfile. |
| `MAKATO_LOOP_ASSIGN_ON_DISPATCH` | `1` | Set to `0` to skip the assign-on-dispatch step (no `issues.assigned` webhook → board stays at `Ready`). See §*The one exception: assign-on-dispatch*. |
| `MAKATO_LOOP_ASSIGNEE` | `@me` | Assignee login passed to `gh issue edit --add-assignee` at dispatch. `@me` = the authenticated `gh` user driving the loop. |
| `MAKATO_LOOP_ASSIGN_TEST_FILE` | unset | Test-only: append the intended assign (`assign #<n> assignee=<x> repo=<y>`) to this file instead of calling `gh`. |

## Smoke tests

`scripts/loop-smoke-tests.sh` covers twenty-one scenarios:

1. `check-halt` exits 0 with no HALT file.
2. `check-halt` exits 1 with a HALT file.
3. `dispatch <n> --dry-run` writes and clears `active_workflow`.
4. `dispatch` refuses (exit 2) while another `active_workflow` is in flight.
5. `in_flight_issues` skips spec folders with `current_phase: "done"`.
6. `in_flight_issues` includes spec folders with `current_phase: "implement"`.
7. `run --once --dry-run` writes the status file and exits without
   dispatching.
8. `run --once` exits cleanly when the HALT file is present (no dispatch).
9. `run --once` with `MAKATO_LOOP_DRY_DISPATCH=1` dispatches the first
   untracked issue and records `last_dispatch_issue`.
10. `poll <STATUS>` filters by board Status (items at other Statuses excluded).
11. `poll` excludes non-Issue content (DraftIssue, PullRequest).
12. Watchdog stamps `active_workflow.stalled = true` after
    `MAKATO_LOOP_STALL_WARN` seconds of silence (#164).
13. Watchdog SIGTERMs the child after `MAKATO_LOOP_STALL_KILL` seconds and
    the `last_watchdog_kill` snapshot survives the `active_workflow=null`
    clear (#164).
14. `MAKATO_LOOP_STALL_DISABLE=1` opts out of the watchdog entirely —
    no log file, no status stamps (#164).
15. `run` refuses with exit 3 when a live pidfile exists — the refusing
    instance does not clobber the pidfile (#172).
16. `run` reclaims a stale pidfile silently (PID gone) and its EXIT
    trap cleans up on shutdown (#172).
17. `startup_audit` records `script_path`, `pid`, `ppid`, `pidfile`, and
    the CLI arguments (#172).
18. `run --force` SIGTERMs a live incumbent and takes over the pidfile (#172).
19. `dispatch` assigns the issue on the real-fork path (assignee + repo
    threaded through); `--dry-run` does not assign (#33).
20. `MAKATO_LOOP_ASSIGN_ON_DISPATCH=0` disables the assign step (#33).
21. `dispatch` derives `KEY`/`BRANCH` from the issue body's `to-issues`
    provenance and threads the full po-agent input bundle
    (`ISSUE_NUMBER`/`KEY`/`REPO`/`BRANCH`/`REPO_ROOT`) into the dispatch
    prompt; falls back to the `specs/<slug>/stories.json` line; degrades
    to a `WARN` with empty `KEY` when the body has no provenance (#144).

Run them directly:

```bash
plugins/makato-orchestrate/scripts/loop-smoke-tests.sh
```

The harness uses `MAKATO_LOOP_GH_OVERRIDE` to inject a canned
`item-list` fixture — fully offline, no GitHub access required.

## Out of scope

Documented limits of the v1 implementation (per issue #33):

- **Priority ordering.** The queue is FIFO from `gh project item-list`
  (board insertion order). Issue priorities, labels like
  `severity:critical`, and points are not consulted. Operators wanting
  priority can sort the board manually or use the Projects v2 field
  filters in the UI.
- **Multi-repo queue aggregation.** A single `loop` run operates against
  the project board configured in `.claude/config.json`. Cross-repo
  boards (the makato project board hosts multiple repos) work
  transparently — every Issue item is dispatched against its own
  repository, and the in-flight filter is global to this clone's
  `specs/` tree, not per-repo.
- **GitHub Actions trigger variant.** For webhook-driven dispatch
  (`issues.labeled` → spin up a runner), use
  `plugins/makato-plan/skills/issue-to-project --from-webhook`. The
  polling and webhook paths are complementary, not alternatives.
- **Board mutation at dispatch.** `loop` is strictly read-only against
  the board. Moving an issue's Status from `Ready` to `In progress`
  is done by `issue-to-project sync-lifecycle` when the PO-agent's
  first commit lands on the feature branch (the lifecycle webhook
  fires on `pull_request.opened`).

## Tracking issue

[GAP-007 (#33)](https://github.com/macatocz/makato/issues/33) — closes
the autonomous-dispatch gap in the AgenticSystem PRD. Depends on
GAP-006 (#32) — PO-agent — which is the dispatch target. Reads board
state populated by GAP-005 (#27) → `issue-to-project --init`.
