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
version: "2.0.0"
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

### Pre-poll label→board bridge (#231)

The board is still the queue source — but an issue that never came through
`to-issues` (a hand-filed issue, or an auto-filed testbox/CI bug) has no
`created-issues.json`, so `issue-to-project`'s autonomous promotion never sees
it and it stays off the board's `Ready` column even when the operator has
stamped it `status:ready-for-dev`. Before #231 the only fix was a manual
`seed-issue` run.

`run` now performs a **pre-poll promotion pass** (Process step 2 below): every
tick, before the board poll, it lists open `status:ready-for-dev` issues and
sets any that are off-`Ready` to `Status=Ready` via `gh project item-edit` (the
same mutation `seed-issue` performs). This keeps the board the single source of
truth — every dispatched issue still has a real `Ready` card — while giving the
label a one-way on-ramp onto it. The pass is **guarded** (issues carrying
`triage`, `experimental`, `status:blocked`, or `autonomous:halt` are skipped)
and **best-effort** (any `gh` failure logs a WARN and never blocks the tick).
It runs only when polling the default `Ready` status.

### Pre-poll merged-worktree reap (#265)

Git worktrees under `.claude/worktrees/` accumulate on the operator's **local
disk**. The PO-agent's success path already calls `worktree.sh cleanup`
(§*Worktree lifecycle* in `po-agent.md`), but that only fires for a fully
autonomous run that reaches merge inside its own session. Worktrees created by
hand (`EnterWorktree`), or orphaned when a session died before cleanup, carry no
`workflow-state` and so nothing ever removes them — a live audit found 31
registered worktrees, the sampled majority from long-merged PRs.

`run` now performs a **pre-poll reap pass** (Process step 3 below): every tick
(throttled to at most once per `MAKATO_LOOP_REAP_INTERVAL`, default 1 h) it walks
`git worktree list --porcelain`, and for each worktree removes it via
`git worktree remove --force` **only** when its work has already **landed** on
the base branch. This runs locally because that is where the worktrees
physically live — a cloud GitHub Action on `ubuntu-latest` cannot reach the
operator's disk.

The removal is gated by an 8-layer guard stack; a worktree is reaped only when
it passes **all** of:

1. not the main checkout,
2. lives under `.claude/worktrees/`,
3. no nested-worktree relationship — neither the **parent** of another
   registered worktree nor a **child** living inside another worktree's
   `.claude/worktrees/` (the main checkout owning `.claude/worktrees/` is the
   normal layout, not nesting),
4. not `locked`,
5. not a detached HEAD (no branch → cannot correlate to landed work),
6. no **tracked** uncommitted changes — untracked `??` scratch (build
   artefacts, generated files) does **not** pin a worktree; only staged or
   modified tracked paths do,
7. not `worktree_retained` (when a `workflow-state` maps to it), and
8. its work has **landed** on the base branch — either a **merged PR**
   (`gh pr list --state merged`, any merge style) **or** its `HEAD` is a strict
   **ancestor** of the base ref (`git merge-base --is-ancestor`). The union
   catches squash/rebase merges *and* branches whose PR head was renamed so the
   `--head` lookup misses them. A worktree sitting exactly on the base tip (a
   freshly branched, not-yet-committed workspace) is **not** treated as landed.

The pass is **best-effort** — any `gh`/`git` failure logs a WARN and never
blocks the tick — and never touches a worktree with uncommitted **tracked**
work. Disable it with `MAKATO_LOOP_REAP_ON_POLL=0`.

> **To pin a worktree indefinitely, use `git worktree lock`** — guard 4 always
> honours it, regardless of landed state. The `worktree_retained` flag (guard 7)
> only vetoes when a `workflow-state` file maps to the worktree; most
> hand-created worktrees have none, so `lock` is the reliable operator pin. The
> clean-tree guard (6) is the independent backstop for everything else.

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
| `remove-worktrees` | Remove local worktrees under `.claude/worktrees/` whose branch has a merged PR (#265); skips main/dirty/locked/retained/detached/nested. Also a pre-poll pass in `run`. One-shot: `MAKATO_LOOP_REAP_INTERVAL=0 loop remove-worktrees` (`MAKATO_LOOP_REAP_DRYRUN=1` to inspect). |
| `promote-ready` | Run the label→board promotion pass once and exit (#231). Useful for one-shot promotion without starting the full loop. |
| `auto-seed` | Run the pre-poll auto-seed pass (`_auto_seed_unprepared`) once and exit (#373, epic #367 S5). Seeds or blocks every open issue not yet at `status:ready-for-dev`: light-tier issues → headless `seed-issue` dispatch + thin-body reconciliation; full/change/untiered → spec-folder stub + board `Blocked` + `needs-human-review`. Best-effort: a failure per candidate logs a WARN and the pass always returns 0. |
| `check-halt` | Exit 0/1 mirroring `hooks/check-halt.sh`. |

## Process

Each outer iteration of `run` performs the following steps in order:

1. **HALT check.** `check-halt` exits non-zero if `~/.claude/HALT` (or
   `$MAKATO_HALT_FILE`) is present — the loop exits cleanly (NEVER 3,
   HALT-000). The exit is recorded by stamping `.last_halt_at` in
   `loop-status.json`.
1.5. **Pre-poll auto-seed pass (#373, epic #367 S5).** When polling the
   default `Ready` status and `MAKATO_LOOP_AUTOSEED_ON_POLL` is not `0`,
   `_auto_seed_unprepared` iterates every open issue that does NOT yet carry
   `status:ready-for-dev` and routes it to the appropriate arm:
   `plan-tier:light` → `_auto_seed_dispatch_light` (headless `seed-issue`
   dispatch) followed by `_auto_seed_reconcile_thin_body` (thin-body
   reconciliation); `plan-tier:full`, `plan-tier:change`, or untiered →
   `_auto_seed_block_full` (spec-folder stub + board `Blocked` +
   `needs-human-review`). Each candidate is handled under `|| true`
   (best-effort: any per-candidate failure logs a WARN and the pass continues).
   The pass runs **before** `_promote_labelled_ready` (step 2) so a freshly-seeded
   light issue arrives at `Status=Ready` in time to be dispatched in the same
   tick. Skipped under `--dry-run`, for custom `--status` runs, and when
   `MAKATO_LOOP_AUTOSEED_ON_POLL=0`. Also available standalone as
   `loop auto-seed`.
2. **Pre-poll promotion (#231).** When polling the default `Ready` status,
   `_promote_labelled_ready` lists open `status:ready-for-dev` issues and
   promotes those that are off-`Ready` and not carrying an exclusion label
   (`triage`, `experimental`, `status:blocked`, `autonomous:halt`) to
   `Status=Ready`. This bridges labelled non-`to-issues` issues onto the board
   queue (see *Pre-poll label→board bridge* above). Best-effort: a `gh` failure
   or missing config logs a WARN and the tick continues. Skipped under
   `--dry-run` and for custom `--status` runs. Also available standalone as
   `loop promote-ready`.
3. **Pre-poll worktree reap (#265).** `_reap_merged_worktrees` walks
   `git worktree list --porcelain` and removes worktrees whose work has landed
   on the base branch (merged PR or ancestor of the base ref), subject to the
   8-layer guard stack (see *Pre-poll merged-worktree reap* above). Throttled
   to at most once per `MAKATO_LOOP_REAP_INTERVAL` (default 1 h) via the
   `last_reap` stamp, so it is a sub-millisecond no-op on most ticks. Runs for
   all `--status` values (it operates on local disk, not the board).
   Best-effort: any `gh`/`git` failure logs a WARN and the tick
   continues. Skipped under `--dry-run` and when `MAKATO_LOOP_REAP_ON_POLL=0`.
   Also available standalone as `loop remove-worktrees`.
3.5. **Pre-poll HALT-007B liveness check (#284).** `_check_pending_handoffs`
   walks every `specs/*/workflow-state-*.json` and calls
   `context-handoff.sh check-pid` for each issue with a pending handoff
   (`handoff_reason == "context_ceiling"` AND `spawned_pid` set). `check-pid`
   clears the recorded PID when the resumed session confirms startup (a
   `resume_ack` fresher than the latest HALT-007B audit entry), keeps waiting
   while the subprocess is still booting inside `MAKATO_HANDOFF_ACK_TIMEOUT`
   (default 120 s), or — when the PID is dead or no ack arrives within the
   window — fires the HALT-007 fallback: `restart_failed=true`, a HALT-007
   `halt_audit` entry, and `needs-human-review` applied directly (the
   kill-switch poller that normally labels died with the abandoned session).
   This closes the silent-abandonment gap where a resume subprocess that
   crashed after fork left the issue stranded with no PR and no page. Runs for
   all `--status` values (reads local state, not the board). Skipped under
   `--dry-run`. Best-effort — any failure logs a WARN and never blocks the tick.
4. **Board poll.** `GH_HOST=<host> gh project item-list <number>
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
5. **Status checkpoint.** `loop-status.json` is patched with
   `last_poll`, `queue_depth`, the issue-number list under `queue`, and
   the operator-supplied `status_name` / `interval_seconds` /
   `dry_run` flags.
6. **In-flight filter.** Every `specs/*/workflow-state-*.json` (per-issue
   layout, #173; legacy `specs/*/workflow-state.json` files also parsed as
   a fallback until they migrate on next mutation) is scanned
   for `issue_number` + `current_phase`. Any issue whose state file
   exists and is NOT `current_phase: "done"` is considered in-flight
   and skipped — this guarantees single-threaded execution across
   restarts as well as within one session.
7. **Dispatch.** The first untracked issue is handed to `dispatch
   <issue>` which:
   - Writes `.active_workflow = {issue, started_at}` to
     `loop-status.json` before forking.
   - **Board claim (#259).** Re-polls the issue's board `Status` and
     compare-and-sets it `Ready → In progress` via `gh project item-edit`
     (see §*Board writes at dispatch: the synchronous claim*). If the
     re-poll shows the card is no longer at `Ready` — another `loop`
     session in a different worktree already claimed it — `dispatch`
     clears `active_workflow` and returns 0 without forking (a clean
     skip). Best-effort: an unreadable Status logs a `WARN` and proceeds.
     Disabled with `MAKATO_LOOP_CLAIM_ON_DISPATCH=0`.
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
     `REPO_ROOT` is the local repo root.
     When the body has NO `to-issues` provenance (a hand-filed or auto-filed
     issue), `_derive_key_for_issue` falls back to
     `<issue-number>-<normalized-title>` — the exact `seed-issue` SLUG
     convention (#232) — so the loop dispatches a valid KEY without a manual
     `seed-issue` run. Combined with the pre-poll promotion pass (step 2),
     a labelled hand-filed issue now enters the loop end-to-end unattended.
     KEY still degrades to empty (with a `WARN`, and the po-agent then
     surfaces `missing input: KEY`) only when neither provenance NOR a title
     can be read — e.g. a `gh` outage that returns an empty body and title.
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
8. **Sleep.** `sleep $interval_seconds`. The cycle repeats from step 1.

`--once` short-circuits step 8 and exits after one cycle. `--dry-run`
replaces the `exec` in step 7 with a stderr line; everything else
behaves identically (useful in CI smoke tests).

## Single-thread guarantee

The loop is intentionally serial. Five layers enforce this — the first
four are **worktree-local** (they defend a single `run` session and its
restarts), and the fifth is **cross-session** (it defends against a
second `run` in a *different* worktree on the same host):

- The **run-mutex pidfile** at `.claude/state/loop.pid` refuses a
  second `run` invocation while a live one owns the state dir
  (see §*Run mutex* below). This is the layer that would have caught
  the #172 incident (plugin-cache `loop.sh` running alongside
  working-tree `loop.sh` for six hours). *Worktree-local:* the pidfile
  lives under `$STATE_DIR`, so a second worktree has its own.
- The in-flight filter in step 4 excludes issues whose
  `workflow-state.json` is anything other than `current_phase: "done"`.
  *Worktree-local:* it scans this worktree's `specs/`.
- `dispatch` refuses (exit code 2) if `.active_workflow.issue` is set to
  a different issue — defensive guard for operators who manually
  invoke `dispatch` while `run` is mid-cycle.
- `run` runs the PO-agent **inline** via `$CLAUDE_BIN`. The next poll
  cannot start until the subprocess exits.
- **Cross-session (#259):** the **synchronous board CAS claim** at
  dispatch (§*Board writes at dispatch: the synchronous claim*) makes the
  board the shared *lock*. Because all four layers above are
  worktree-local, they are blind across parallel sessions in different
  worktrees; the claim is the only layer that closes that gap.

This is the deliberate v1 design (see issue #33 Out of Scope: "Priority
ordering of issues in the queue (FIFO only in v1)"). Parallel dispatch
across multiple PO-agents is not supported and would require a separate
mutex around `loop-status.json` plus per-issue workflow-state isolation.

## Board writes at dispatch: the synchronous claim (#259)

> **Invariant change (#259).** Earlier versions of `loop` were *strictly
> read-only against the board* and relied on the asynchronous
> assign→webhook path to move `Ready → In progress`. That left a race:
> two `loop run` sessions in different worktrees on the same host each
> have their own `.claude/state/` (pidfile) and `specs/` (in-flight
> filter), so neither sees the other's in-flight issue, and the only
> cross-session signal — the board `Status` — is not moved to
> `In progress` until the webhook lands. Between session A's assign and
> the webhook, session B polls, still sees `Ready`, and dispatches a
> **second** PO-agent against the same issue. As of #259 the loop
> **claims the board card itself, synchronously, immediately before
> spawn** — making the board the shared *lock*, not just the shared
> *queue*.

At dispatch, `_claim_board_card` performs a compare-and-set:

1. **Re-poll** the target issue's board `Status` (a fresh
   `gh project item-list`, closing the TOCTOU window as far as the API
   allows).
2. **CAS:** only if `Status` is still the dispatch status (`Ready`), call
   `gh project item-edit` to set `Status=In progress` — the same mutation
   `seed-issue` / `issue-to-project` use (field id + `in_progress` option
   id are cached in `.claude/config.json` → `github_project.fields.status`).
3. If the re-poll shows `Status != Ready`, **another session already
   claimed the card** — the issue is treated as in-flight and **skipped**
   (`cmd_dispatch` clears `active_workflow` and returns 0, a clean skip,
   not an error).
4. Only after a successful claim does the loop assign the issue and spawn
   the PO-agent.

**Ownership split with `issue-to-project sync-lifecycle`.** The claim
intentionally revises the old read-only invariant, but the split of Status
writes is still clean and forward-only:

| Status transition | Owner |
|-------------------|-------|
| `Ready → In progress` | **`loop`** (this claim, #259) — and, redundantly, the `issues.assigned` webhook that the assign-on-dispatch step still fires. |
| `In progress → In review` | `issue-to-project sync-lifecycle` (on `pull_request.opened`). |
| `In review → Done` | `issue-to-project sync-lifecycle` (on `pull_request.closed`+merged). |

Because the claim only ever writes **from** `Ready`, it is forward-only —
it can never roll a card back from `In review`/`Done`, so it never races
`sync-lifecycle` for a later transition. The redundant assign→webhook path
is preserved as a belt-and-braces trigger and is likewise forward-only.

**Best-effort, never blocks dispatch.** Any inability to *read* the current
Status (a `gh` outage, missing `github_project` config, an empty board
result) logs a `WARN` and **proceeds** — degrading to the pre-#259
assign-only path is strictly safer than blocking real work, and the
residual race in that degraded case is exactly the old behaviour. A failed
*write* (the `item-edit` itself, after Ready was already observed) also
proceeds, because the async webhook remains the backstop.

**Opt-out.** `MAKATO_LOOP_CLAIM_ON_DISPATCH=0` disables the claim entirely;
the loop then relies solely on the async assign→webhook path and the
cross-worktree double-dispatch race re-opens. Leave the claim **enabled**
in any multi-worktree setup.

## Why we still don't mutate labels at dispatch

The issue #33 brief suggested removing `status:ready-for-dev` at dispatch
to prevent double-dispatch. We don't touch the label:

1. `status:ready-for-dev` exists in the repo as a **passive stamp**
   written by `issue-to-project` v2.8+ during autonomous auto-promotion
   (`ready_queue_mode: "autonomous"`). It is a historical marker — the
   downstream orchestrator can grep it without reading the board — but it
   is **not the dispatch signal**. The board's `Status` field remains the
   source of truth; `loop` reads (and, since #259, claims) `Status`, not
   the label.
2. The double-dispatch defence is now the board CAS claim above (plus the
   worktree-local in-flight filter for same-session restarts). Mutating
   the *label* from `loop` would duplicate `issue-to-project
   sync-lifecycle`'s contract for no additional protection.

### assign-on-dispatch (#33) — now a belt-and-braces trigger

Independently of the #259 board claim, `loop` still makes one **repo**
mutation at dispatch: it assigns the issue to the dispatch actor via
`gh issue edit --add-assignee` (default `@me`) just before spawning the
PO-agent. This fires the `issues.assigned` webhook that the
`project-board-sync.yml` GHA translates into a `Ready → In progress`
Status move. Since #259 already writes `In progress` synchronously, the
assign is now redundant for the board move but retained as a
belt-and-braces trigger and for its own sake (the issue *should* be
assigned to whoever is driving it).

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
| `last_reap` | ISO-8601 ms \| null | Timestamp of the most recent merged-worktree reap pass (#265). Drives the reap throttle. `null` until the first pass runs. |
| `last_reap_count` | integer \| null | Number of worktrees removed in the last reap pass (`0` when the pass ran but removed nothing). |
| `reaped` | array \| null | `[{path, branch, landed}, …]` from the last pass that removed at least one worktree (`landed` is the reason string, e.g. `merged PR #206` or `ancestor of origin/main`); not rewritten on a zero-removal pass. |
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
| `MAKATO_LOOP_ISSUE_TITLE_OVERRIDE` | unset | Test-only: use this string as the issue title instead of `gh issue view --json title` in the `_derive_key_for_issue` third fallback (#232). Keeps the T27 no-provenance KEY test offline. |
| `MAKATO_LOOP_PROMOTE_OVERRIDE` | unset | Test-only: read the candidate list (`gh issue list --json number,labels` shape) from this path instead of invoking `gh` in `_promote_labelled_ready` (#231). Keeps the T28 promotion test offline. |
| `MAKATO_LOOP_PROMOTE_DRYRUN` | unset | Test-only: set to `1` so `_promote_labelled_ready` logs `would promote #N → Ready` instead of calling `gh project item-edit`. Asserted by T28. |
| `MAKATO_LOOP_STALL_WARN` | `900` | Seconds of no output before the watchdog stamps `active_workflow.stalled = true`. |
| `MAKATO_LOOP_STALL_KILL` | `3600` | Seconds of no output before the watchdog `SIGTERM`s the PO-agent. |
| `MAKATO_LOOP_STALL_POLL` | `60` | Watchdog poll cadence in seconds (small values used in smoke tests). |
| `MAKATO_LOOP_STALL_TERM_GRACE` | `30` | Seconds between `SIGTERM` and the follow-up `SIGKILL` if the child hasn't exited. |
| `MAKATO_LOOP_STALL_DISABLE` | unset | Set to `1` to disable the watchdog entirely (no log capture, no background poller, no status stamps). |
| `MAKATO_LOOP_STALL_TEST_CMD` | unset | Test-only: run this command in place of `claude` (e.g. `sleep 30`) so the watchdog has a real stall to reap. |
| `MAKATO_LOOP_PIDFILE` | `<state-dir>/loop.pid` | Override the run-mutex pidfile path (#172). Tests use this to isolate the mutex from any concurrent operator loop on the same box. |
| `MAKATO_LOOP_FORCE_GRACE` | `10` | Seconds between `SIGTERM` and `SIGKILL` when `run --force` reclaims a live pidfile. |
| `MAKATO_LOOP_ASSIGN_ON_DISPATCH` | `1` | Set to `0` to skip the assign-on-dispatch step (no `issues.assigned` webhook → board stays at `Ready`). See §*assign-on-dispatch (#33) — now a belt-and-braces trigger*. |
| `MAKATO_LOOP_ASSIGNEE` | `@me` | Assignee login passed to `gh issue edit --add-assignee` at dispatch. `@me` = the authenticated `gh` user driving the loop. |
| `MAKATO_LOOP_ASSIGN_TEST_FILE` | unset | Test-only: append the intended assign (`assign #<n> assignee=<x> repo=<y>`) to this file instead of calling `gh`. |
| `MAKATO_LOOP_CLAIM_ON_DISPATCH` | `1` | Set to `0` to disable the synchronous board CAS claim (#259). With it off, the loop relies solely on the async assign→webhook path and the cross-worktree double-dispatch race re-opens — leave enabled in multi-worktree setups. See §*Board writes at dispatch: the synchronous claim*. |
| `MAKATO_LOOP_CLAIM_TEST_FILE` | unset | Test-only: append the claim decision (`claim #<n> status=<s> → {claimed\|skip\|warn-proceed}`) to this file instead of calling `gh`. |
| `MAKATO_LOOP_CLAIM_STATUS_OVERRIDE` | unset | Test-only: the fixture current board Status the re-poll should observe (`Ready`, `In progress`, or empty for the unreadable-Status fallback). Consumed only alongside `MAKATO_LOOP_CLAIM_TEST_FILE`. |
| `MAKATO_LOOP_REAP_ON_POLL` | `1` | Set to `0` to disable the merged-worktree reaper (#265) entirely (no pre-poll pass, `remove-worktrees` short-circuits). |
| `MAKATO_LOOP_REAP_INTERVAL` | `3600` | Minimum seconds between reap passes. The pass is invoked every tick but no-ops until the window elapses. Set `0` to run every call (one-shot cleanup / tests). |
| `MAKATO_LOOP_REAP_DRYRUN` | unset | Set to `1` to log intended removals (`reap would remove …`) without running `git worktree remove`. |
| `MAKATO_LOOP_REAP_REPO` | unset | Override the owner/repo used for `gh pr list` (default: `MAKATO_LOOP_DISPATCH_REPO`, else parsed from `git remote get-url origin`). |
| `MAKATO_LOOP_REAP_GH_OVERRIDE` | unset | Test-only: path to a JSON map `{"<branch>": "<pr#>"}` read instead of calling `gh pr list`. Keeps the reap smoke tests offline. |
| `MAKATO_LOOP_REAP_BASE_REF` | unset | Override the base ref used for the ancestry landed-check (default: `origin/HEAD`, else `origin/main`). Tests point it at a local `main` so ancestry works in a throwaway repo with no remote. |
| `MAKATO_LOOP_REAP_WT_OVERRIDE` | unset | Test-only: path to a file with canned `git worktree list --porcelain` output, read instead of invoking git. |
| `MAKATO_HANDOFF_ACK_TIMEOUT` | `120` | Seconds the pre-poll HALT-007B liveness check (#284) waits for a resumed subprocess to write `resume_ack` before firing the HALT-007 fallback. A dead PID short-circuits the wait. Read by `context-handoff.sh check-pid`; lower it in tests to force the timeout path. |
| `MAKATO_LOOP_AUTOSEED_ON_POLL` | `1` | Set to `0` to disable the pre-poll auto-seed pass entirely (#373, epic #367 S5). When unset or `1`, `_auto_seed_unprepared` runs before `_promote_labelled_ready` on every `Ready`-status tick. Disable for repos that manage seeding externally or for debugging. |
| `MAKATO_LOOP_AUTOSEED_OVERRIDE` | unset | Test-only: path to a JSON file in `gh issue list --json number,labels,author` shape, read instead of calling `gh` in `_auto_seed_candidates`. Keeps S1/S5 discovery smoke tests offline. |
| `MAKATO_LOOP_SEED_TEST_CMD` | unset | Test-only: command string used as the dispatch command instead of the real `claude -p` in `_auto_seed_dispatch_light`. Receives the same env (`MAKATO_HEADLESS=1`, `ISSUE_NUMBER`, `REPO`, `REPO_ROOT`) and prompt as the production invocation. Keeps S2/S5 dispatch smoke tests offline. |
| `MAKATO_LOOP_BLOCK_TEST_FILE` | unset | Test-only: path to a file that `_auto_seed_block_full` appends `block #<n>` to instead of calling `gh project item-edit` to set `Blocked`. Keeps S4/S5 block smoke tests offline. |
| `MAKATO_LOOP_AUTOSEED_SPEC_ROOT` | unset | Test-only: override the `SPECS_DIR` root used by `_auto_seed_block_full` when creating spec-folder stubs. Tests redirect to a temp directory to avoid polluting `specs/`. |

## Smoke tests

`scripts/loop-smoke-tests.sh` covers thirty scenarios:

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
22. **Board CAS claim (#259, T30).** `dispatch` claims the card when its
    board Status is still `Ready`, **skips** (exit 0, no spawn, no
    assign, `active_workflow` cleared) when the Status has moved off
    `Ready` (a second worktree session already claimed it),
    `WARN`-proceeds when the Status is unreadable, and records no claim
    decision when `MAKATO_LOOP_CLAIM_ON_DISPATCH=0`.
23. **Reaper decision set (#265, T31).** `remove-worktrees --dry-run` flags a
    landed (merged-PR) clean worktree for removal and skips tracked-dirty,
    locked, not-landed, and the main checkout.
24. **Reaper live removal (#265, T32).** A landed, clean worktree is actually
    removed; tracked-dirty/locked/not-landed worktrees survive; `last_reap`,
    `last_reap_count`, and `reaped[].landed` are stamped in `loop-status.json`.
25. **Reaper retained guard (#265, T33).** A worktree whose `workflow-state`
    has `worktree_retained: true` is skipped even when its PR is merged.
26. **Reaper opt-out (#265, T34).** `MAKATO_LOOP_REAP_ON_POLL=0` short-circuits
    the whole pass — no worktrees are walked.
27. **Reaper throttle (#265, T35).** A second `remove-worktrees` call within
    `MAKATO_LOOP_REAP_INTERVAL` is a no-op (the `last_reap` stamp gates it).
28. **Reaper ancestry landed-check (#265, T36).** A branch whose `HEAD` is an
    ancestor of the base ref is reaped even with **no** merged PR (renamed-head
    / squash-merge safe); a worktree sitting exactly on the base tip survives.
29. **Reaper untracked-scratch (#265, T37).** A landed worktree carrying only
    untracked files is still reaped — untracked scratch does not pin.
30. **Reaper nested-worktree guard (#265, T38).** Both a worktree that is the
    parent of a nested worktree and one nested inside another worktree are
    skipped.
31. **Auto-seed composition — light seed (Ta, #373).** `_auto_seed_unprepared`
    dispatches S2 for a `plan-tier:light` candidate, S3 confirms no thin-body,
    function returns 0.
32. **Auto-seed composition — thin-body reconciled (Tb, #373).** Light candidate
    dispatched (S2); S3 detects thin-body → `needs-human-review` applied; function
    returns 0 (best-effort).
33. **Auto-seed composition — full-blocked (Tc, #373).** `plan-tier:full` candidate
    routes to S4 (block recorded), function returns 0.
34. **Auto-seed composition — untiered-as-full (Td, #373).** Empty `plan_tier`
    routes to S4 (same as full).
35. **Auto-seed composition — exclusion-veto (Te, #373).** Candidate carrying an
    exclusion label is skipped; no seed or block action.
36. **Auto-seed composition — best-effort on S2 failure (Tf, #373).** S2 dispatch
    exits 1; WARN is logged; function still returns 0.
37. **Auto-seed composition — sentinel idempotency (Tg, #373).** S4 detects the
    block sentinel already present in issue comments and skips re-posting.
38. **Auto-seed composition — toggle-off (Th, #373).** `MAKATO_LOOP_AUTOSEED_ON_POLL`
    guard is present in `cmd_run` and protects the `_auto_seed_unprepared` call
    (structural check — confirms the toggle controls the call site).
39. **Auto-seed composition — ordering (Ti, #373).** `_auto_seed_unprepared`
    appears on an earlier line than `_promote_labelled_ready` in `cmd_run`,
    confirming the load-bearing tick ordering.
40. **Auto-seed composition — dependencies veto (Tj, #373).** Candidate with the
    `dependencies` label is skipped by S1 discovery.
41. **Auto-seed composition — already-ready skipped (Tk, #373).** Candidate with
    `status:ready-for-dev` is excluded from candidates (S1 filter); no action.

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
- **Board mutation beyond the claim.** As of #259 `loop` makes exactly
  one board write — the synchronous `Ready → In progress` compare-and-set
  claim at dispatch (see §*Board writes at dispatch: the synchronous
  claim*). It writes no other Status transitions: `In progress → In
  review → Done` remain owned by `issue-to-project sync-lifecycle`
  (driven by `pull_request.opened` / `pull_request.closed`+merged
  webhooks).

## Tracking issue

[GAP-007 (#33)](https://github.com/macatocz/makato/issues/33) — closes
the autonomous-dispatch gap in the AgenticSystem PRD. Depends on
GAP-006 (#32) — PO-agent — which is the dispatch target. Reads board
state populated by GAP-005 (#27) → `issue-to-project --init`.
