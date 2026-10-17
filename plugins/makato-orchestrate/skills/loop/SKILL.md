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
  operator-facing live audit. Use when starting an unattended run
  across a queue of Ready items, driving autonomous polling overnight,
  or running a single dispatch cycle with --once. Trigger keywords:
  autonomous, polling, board, Ready, unattended, GAP-007, loop run,
  dispatch queue.
version: "2.5.0"
argument-hint: "[--status <NAME>] [--interval <S>] [--dry-run] [--once] [--force]"
allowed-tools: [Bash]
metadata:
  authors: [makato-orchestrate]
  last_updated: "2026-08-05"
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

### Pre-poll label→board bridge (removed in #688)

> **Note:** The `_promote_labelled_ready` pre-poll pass that previously listed
> open `status:ready-for-dev` issues and moved them to board Status=Ready has
> been removed. Board Status=Ready is now the sole dispatch signal and the sole
> on-ramp into the queue. Use `seed-issue` (which moves the card to Ready) or
> `issue-to-project` autonomous mode for issues that need to enter the queue.
> The `promote-ready` subcommand of `loop.sh` now exits with an error message
> as a removed-feature notice.

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

### Orphaned specs/ folder pruning

The reap pass also prunes local `specs/<slug>/` scratch folders in the same
window (`_reap_orphan_specs`, run right after the worktree walk). The po-agent
writes per-run artefacts there (`plan.md`, `workflow-state-<N>.json`,
`orchestrate.jsonl`, `seed-manifest.json`, `lessons-*.md`); in the makato repo
`specs/**` is gitignored, so once an issue is done those files linger as
untracked local scratch. `archive-spec.sh` cannot clean them — it runs on a GHA
runner with a fresh checkout and never sees the operator's disk — so the reaper
does it locally.

A folder is pruned only when **all** hold:

1. it is **fully untracked** (`git ls-files <dir>` returns empty) — a folder
   with any tracked file belongs to a consumer repo where specs are committed
   and managed by `archive-spec.sh` via `git mv`; the reaper **never** deletes
   it;
2. the owning issue number is derivable — from `seed-manifest.json`
   `.issue_number`, or the `workflow-state-<N>.json` filename;
3. the issue is **done** — either `workflow-state-<N>.json` has
   `current_phase == "done"` (fast local path, no network) **or**
   `gh issue view <N> --json state` returns `CLOSED` (fallback for thin folders
   with no workflow-state file). An `OPEN` issue is skipped; an unknown/error
   state is skipped with a WARN.
4. **no still-open sibling** — the *shared-epic guard*. A folder whose
   `created-issues.json` / `stories.json` enumerates more than one issue is the
   shared AC/plan store for the whole batch (e.g. `openspec-transfer-features`
   hosts #562–#568 under one `stories.json`). The done signal in (3) only clears
   the single derived issue; the folder is pruned only once **every** referenced
   sibling is also closed. While any sibling is still open — or its state is
   unreadable — the folder is KEPT so the sibling stories never lose their plans.
   A single-issue folder (no siblings) is unaffected.

Best-effort and respects `MAKATO_LOOP_REAP_DRYRUN`. Disable with
`MAKATO_LOOP_REAP_SPECS=0`. Audit counts land in `loop-status.json` under
`last_reap_specs_count` / `reap_specs_pruned`.

**Lessons are promoted before the folder is deleted.** The po-agent's lessons
live only in gitignored `workflow-state-<N>.json` / `change-lessons.jsonl`, so
`documentation-agent` on a fresh GHA checkout never sees them — the reaper is
the one place that can lift them into the committed store. Before `rm -rf`,
`_reap_orphan_specs` runs `promote-lessons.sh <N>` so any `scope: generalizable`
lesson lands in `.makato/memory/procedural.jsonl`. If promotion fails
(non-zero — a genuine I/O error), the folder is **kept** so no lesson is ever
lost; a clean exit (promoted, or nothing generalizable to promote) authorises
removal.

## When to Use

Use **only** from the operator's terminal (or a `tmux`/`nohup` wrapper)
when starting an unattended run across a queue of `Ready` items. The
skill is the entry point for autonomous mode — every other autonomous
component (PO-agent, kill-switch, workflow-state, context-handoff) is
dispatched from this loop, never the other way around.

This is now **enforced** (#743): `cmd_run` aborts with an actionable error
when it detects a `bg-spare` / `bg-pty-host` / headless-Claude ancestor,
because such a session is reaped after a few minutes and its SIGTERM would
kill the loop and any in-flight dispatch. For an unattended run, detach with
`nohup`+`disown` (see *Invocation → When invoked from a Claude skill*); set
`MAKATO_LOOP_ALLOW_BG_SESSION=1` only for headless CI with external SIGTERM
protection.

Do **not** invoke from sub-agents, `build-*` skills, or the PO-agent
itself. The loop's invariants (single-threaded dispatch, board filtering,
HALT-file polling at the outer-most boundary) assume it owns the session.

## Anti-patterns

**NEVER invoke `loop` from sub-agents, `build-*` skills, or the PO-agent itself.**
WHY: The loop's invariants (single-threaded dispatch, board filtering, HALT-file polling at the outermost boundary) assume it owns the session. A sub-agent invoking `loop` would spawn a second session that bypasses every single-thread guarantee — the pidfile, the in-flight filter, and the board CAS claim all live in the parent session's state dir, invisible to the child. The result is unchecked parallel dispatch against the same issue.

**NEVER use `--force` unless you have verified the incumbent `loop` process is genuinely stuck.**
WHY: `--force` sends `SIGTERM` followed by `SIGKILL` to the incumbent. If the PO-agent inside that session is mid-write to `workflow-state.json`, `orchestrate.jsonl`, or the branch, a forced kill leaves those files in a partially-written state. The safer alternative is `kill -TERM <pid>` from your terminal — the incumbent's EXIT trap runs, the pidfile is released, and the next `loop run` starts clean. Reserve `--force` for `kill -9` orphans where the EXIT trap cannot run.

**NEVER disable `MAKATO_LOOP_CLAIM_ON_DISPATCH` in a multi-worktree setup.**
WHY: The board CAS claim (`Ready → In progress` compare-and-set) is the only cross-session coordination point. The pidfile, in-flight filter, and run-mutex are all worktree-local — they are blind across parallel sessions. Disabling the claim with `MAKATO_LOOP_CLAIM_ON_DISPATCH=0` re-opens the double-dispatch race that #259 closed: two sessions both see `Ready`, both proceed to spawn a PO-agent for the same issue, and both worktrees drive a competing PR on the same branch.

**NEVER set `MAKATO_LOOP_GATE_DISABLE=1` in production.**
WHY: The dispatch gate runs four safety tiers before spawning the PO-agent — exclusion-label veto, merged-PR check, in-flight workflow-state check, and label-board conflict check. Each tier prevents a category of wasted or corrupting work. Disabling all four simultaneously (which `GATE_DISABLE=1` does) bypasses the only protection against dispatching an already-merged issue, an already-in-flight issue, or an issue that carries `needs-human-review`. Use only for offline smoke tests that need to exercise the post-gate path with incomplete fixtures.

**NEVER use `MAKATO_LOOP_STALL_DISABLE=1` in production.**
WHY: The watchdog is the liveness net of last resort for the class of PO-agent deadlocks that motivated #160. If the PO-agent enters an infinite-wait that keeps the log mtime fresh (e.g. a blocking tool call), the watchdog is the only mechanism that will eventually `SIGTERM` it. Disabling the watchdog means a single stuck dispatch can hold the loop hostage indefinitely — no SIGTERM, no `last_watchdog_kill` audit, no opportunity for the next item to run. Use only for interactive debug sessions where an operator is attached and long silences are expected.

**NEVER seed issues via the removed `promote-ready` subcommand of `loop.sh`.**
WHY: `loop.sh promote-ready` was removed in #688. The pre-poll `_promote_labelled_ready` pass that it invoked no longer exists — calling the subcommand exits immediately with an error. The correct on-ramp is `seed-issue` (which stamps the to-issues provenance footer and moves the board card to `Status=Ready`) or `issue-to-project` autonomous mode. Any automation invoking `loop.sh promote-ready` will silently stop seeding issues without an obvious failure.

**NEVER run `loop` on a cloud runner that lacks access to the operator's local disk.**
WHY: The merged-worktree reaper and orphaned-specs pruner operate on git worktrees and `specs/` folders that physically exist on the local disk. A fresh `ubuntu-latest` checkout on GitHub Actions has neither. The reap pass is best-effort, so the cloud run itself won't fail, but local worktrees and spec folders accumulate silently — the exact leak the reaper was built to prevent. The scheduled `loop-cron.yml` workflow requires a self-hosted `makato` runner with local checkout access for this reason.

## Prerequisites

- `.claude/config.json` → `github_project` is populated. Run
  `/makato-plan:issue-to-project --init` once per repo before the first
  `loop` invocation. `loop` reads `github_project.owner`,
  `github_project.number`, and `github_project.host` from this block.
- The board has a `Status` single-select field with at least one option
  named "Ready" (the makato project board, `macatocz/projects/4`, has
  this by default). To use a different option name, pass
  `--status <NAME>` or export `MAKATO_LOOP_STATUS`.
- **Needs Planning board Status (one-time migration):** The
  `emit_needs_planning_signal.py` script sets a board card's Status to
  "Needs Planning" when `structural_halt_cycles` reaches the threshold
  (`MAKATO_STRUCTURAL_RESHAPE_THRESHOLD`, default 2). Before this signal
  can write the board, a "Needs Planning" option must exist on the board's
  Status field **and** its option ID must be recorded in
  `.claude/config.json` under `github_project.fields.status.options.needs_planning`
  (and the duplicate `github_project.options.needs_planning` key). Steps:
  1. Add the "Needs Planning" Status option on Projects v2 board #4 via
     the GitHub UI (board settings → Status field → add option).
  2. Retrieve the new option's ID:
     `gh project field-list <project-number> --owner <owner> --format json`.
  3. Populate `.claude/config.json` (both locations):

     ```json
     "options": { ..., "needs_planning": "<option-id>" }
     ```

  4. Run `/makato-plan:issue-to-project --init` to refresh the full
     options map from the live board and overwrite the placeholder.

  Until this migration is complete the script degrades gracefully to
  label-only (`needs-reshape` applied, board Status unchanged) and
  records a WARN in `orchestrate.jsonl`.
- `gh` is authenticated with the `project` OAuth scope. The sibling
  `issue-to-project` pre-flight check 4 fails loudly when this is
  missing; `loop` simply returns an empty queue (`gh` stderr suppressed)
  so a misconfigured operator's loop idles instead of spinning.

## Invocation

**Thread the operator's arguments through verbatim.** When an operator invokes
`/makato-orchestrate:loop run --status Ready,Todo`, the generated Bash MUST pass
that exact `--status` value to `loop.sh` — do NOT copy a hardcoded `--status Ready`
from the examples below. A comma-separated value such as `Ready,Todo` must reach
`loop.sh run --status "Ready,Todo"` unchanged (#743). Bind the operator's values to
shell variables and quote them:

```bash
# Thread the operator-supplied --status / --interval through verbatim.
# Substitute the operator's values for the defaults; do NOT hardcode "Ready".
STATUS="${STATUS:-Ready}"        # e.g. "Ready,Todo" when the operator passed it
INTERVAL="${INTERVAL:-300}"
plugins/makato-orchestrate/scripts/loop.sh run --status "$STATUS" --interval "$INTERVAL"
```

### When invoked from a Claude skill (unattended)

The loop must **not** inherit a background/headless Claude session's lifecycle —
that session is reaped after a few minutes and its SIGTERM kills the loop and any
in-flight dispatch (#743). `cmd_run` now aborts with an actionable error when it
detects a `bg-spare` / `bg-pty-host` ancestor. For an unattended run, detach the
loop from the session with `nohup`+`disown` so its ppid becomes `1`:

```bash
# Detach from the session (ppid=1) so a session reap does NOT SIGTERM the loop.
STATUS="${STATUS:-Ready}"
nohup plugins/makato-orchestrate/scripts/loop.sh run --status "$STATUS" \
  > ~/.claude/state/loop.log 2>&1 &
disown
```

To intentionally run headless in CI where SIGTERM protection is handled
externally, export `MAKATO_LOOP_ALLOW_BG_SESSION=1` to bypass the guard.

### Examples

```bash
# Long-running default (poll every 300 s, Status=Ready)
plugins/makato-orchestrate/scripts/loop.sh run

# Custom Status name and 60 s cadence — pass the operator's value verbatim
plugins/makato-orchestrate/scripts/loop.sh run --status "$STATUS" --interval 60

# Multi-status queue (Ready and Todo) — comma-separated, quoted
plugins/makato-orchestrate/scripts/loop.sh run --status "Ready,Todo"

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
| `dispatch <ISSUE> [--dry-run] [--resume]` | Manually dispatch one issue. `--resume` continues a HALTed or orphaned run from its kept workflow-state (#156). |
| `remove-worktrees` | Remove local worktrees under `.claude/worktrees/` whose branch has a merged PR (#265); skips main/dirty/locked/retained/detached/nested. Also prunes orphaned untracked `specs/<slug>/` folders for done/closed issues (`MAKATO_LOOP_REAP_SPECS=0` to disable). Also a pre-poll pass in `run`. One-shot: `MAKATO_LOOP_REAP_INTERVAL=0 loop remove-worktrees` (`MAKATO_LOOP_REAP_DRYRUN=1` to inspect). |
| `promote-ready` | **Removed in #688.** Exits with an error message. Use `seed-issue` to move a card to Status=Ready. |
| `auto-seed` | Run the pre-poll auto-seed pass (`_auto_seed_unprepared`) once and exit (#373, epic #367 S5). Seeds or blocks every open issue not yet at board Status=Ready: light-tier issues → headless `seed-issue` dispatch + thin-body reconciliation; change-tier → no-op (change-orchestrate owns them); full/untiered → spec-folder stub + board `Blocked` + `needs-human-review`. Best-effort: a failure per candidate logs a WARN and the pass always returns 0. |
| `reconcile-orphaned` | Move board cards that are `In progress` but have no live local workflow-state to `Blocked` + `needs-human-review` (#368). Best-effort one-shot pass. |
| `check-halt` | Exit 0/1 mirroring `hooks/check-halt.sh`. |

## Process

Each outer iteration of `run` performs the following steps in order:

1. **HALT check.** `check-halt` exits non-zero if `~/.claude/HALT` (or
   `$MAKATO_HALT_FILE`) is present — the loop exits cleanly (NEVER 3,
   HALT-000). The exit is recorded by stamping `.last_halt_at` in
   `loop-status.json`.
1.4. **Pre-poll reshape pass (#350, epic #319).** When `MAKATO_LOOP_RESHAPE_ENABLED=1`
   and `--dry-run` is not set, `_reshape_pass` checks for issues at board Status=Needs
   Planning (primary) or carrying the `needs-reshape` label (fallback) and drives a
   bounded `makato-plan:decompose` Refine + `to-issues` dispatch for each candidate.
   For each candidate, reads `reshape_cycles` from `workflow-state-<N>.json`; if
   `reshape_cycles >= MAKATO_MAX_RESHAPE_CYCLES` (default 3) it applies
   `needs-human-review` and logs `status:error` without dispatching. On a successful
   dispatch it increments `reshape_cycles`, removes the `needs-reshape` label, and sets
   board Status=Ready so the reshaped issue enters the queue in the next tick. On a
   dispatch failure it applies `needs-human-review` and leaves the issue at Needs
   Planning. Feature-flagged **off** by default (`MAKATO_LOOP_RESHAPE_ENABLED=0`);
   the pass is a no-op when disabled. Runs **before** `_auto_seed_unprepared` (step 1.5)
   so a successfully reshaped issue can be seeded in the same tick. Skipped under
   `--dry-run`. Kill-switch honoured: if a HALT file is present the pass returns 0
   immediately without dispatching. Also available standalone as `loop reshape-pass`.

1.5. **Pre-poll auto-seed pass (#373, epic #367 S5).** When "Ready" is among
   the polled statuses and `MAKATO_LOOP_AUTOSEED_ON_POLL` is not `0`,
   `_auto_seed_unprepared` iterates every open issue not yet at board Status=Ready
   and routes it to the appropriate arm:
   `plan-tier:light` → `_auto_seed_dispatch_light` (headless `seed-issue`
   dispatch) followed by `_auto_seed_reconcile_thin_body` (thin-body
   reconciliation); `plan-tier:change` → no-op (change-orchestrate creates
   its own spec folder in Step 0.5 — `_auto_seed_block_full` returns 0
   immediately without writing a plan.md stub, blocking the card, or posting
   a comment); `plan-tier:full` or untiered →
   `_auto_seed_block_full` (spec-folder stub + board `Blocked` +
   `needs-human-review`). Candidate discovery (`_auto_seed_candidates`) vetoes
   issues that must never be seeded: exclusion labels, the `dependencies` label,
   `[bot]` authors, and — closing the #499/#510 shared-folder gap (incident
   #347) — **any issue already planned by `to-issues`** (referenced in a
   `specs/<slug>/created-issues.json`, detected via `_is_orphan_issue`). Such
   an issue already has a buildable `plan-<n>.md`; re-seeding it would spawn a
   second, hollow stub folder under seed-issue's `<n>-<title>` convention,
   producing two competing plans for one issue — the exact collision that makes
   the po-agent look in the wrong folder and report "plan not found" (or
   HALT-006) even though a real plan exists. #571 fixed this for the
   auto-seed-block arm; this closes the candidate-discovery arm. Each candidate
   is handled under `|| true`
   (best-effort: any per-candidate failure logs a WARN and the pass continues).
   Skipped under `--dry-run` and when `MAKATO_LOOP_AUTOSEED_ON_POLL=0`. Also
   available standalone as `loop auto-seed`.
2. **Pre-poll promotion pass removed (#688).** The `_promote_labelled_ready`
   pass (which promoted `status:ready-for-dev` issues to board Ready) has been
   removed. Board Status=Ready is now the sole dispatch signal. Use `seed-issue`
   or `issue-to-project` autonomous mode to bring an issue into the queue.
3. **Pre-poll worktree reap (#265).** `_reap_merged_worktrees` walks
   `git worktree list --porcelain` and removes worktrees whose work has landed
   on the base branch (merged PR or ancestor of the base ref), subject to the
   8-layer guard stack (see *Pre-poll merged-worktree reap* above). Throttled
   to at most once per `MAKATO_LOOP_REAP_INTERVAL` (default 1 h) via the
   `last_reap` stamp, so it is a sub-millisecond no-op on most ticks. Runs for
   all `--status` values (it operates on local disk, not the board).
   Best-effort: any `gh`/`git` failure logs a WARN and the tick
   continues. Skipped under `--dry-run` and when `MAKATO_LOOP_REAP_ON_POLL=0`.
   Also available standalone as `loop remove-worktrees`. In the same pass,
   `_reap_orphan_specs` prunes untracked `specs/<slug>/` folders for done/closed
   issues (`MAKATO_LOOP_REAP_SPECS=0` to disable; see *Orphaned specs/ folder
   pruning* above).
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
3.7. **Pre-poll orphaned-`In progress` reconciliation (#368).**
   `_reconcile_orphaned_in_progress` polls the board for all `In progress`
   cards. For each card, it checks whether a non-done `workflow-state.json`
   exists locally. Cards with no live state (session died without cleanup,
   or workflow completed but board write failed) are moved to `Blocked` and
   labelled `needs-human-review`. The reconciliation is best-effort (any `gh`
   failure logs a WARN and never blocks the tick) and toggle-able via
   `MAKATO_LOOP_RECONCILE_ON_POLL=0`. Skipped under `--dry-run`. Also
   available standalone as `loop reconcile-orphaned`.
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
   - **Dispatch gate (#318/#355/#357).** Before the `exec`, read-only safety
     checks run. Skipped entirely when `MAKATO_LOOP_GATE_DISABLE=1` (pre-#318
     behaviour). Each skip path logs attribution, increments `gate_skips_total`,
     clears `active_workflow`, and returns 0 (clean skip — the outer loop moves
     on). Gate never writes board Status (D5 no-op invariant). Steps:
     1. **Exclusion-label veto.** Fetch the issue's labels via `gh issue view`.
        If any label is in the exclusion set (`status:blocked`,
        `needs-human-review`, `claude-halt`, etc.), skip dispatch. Applies to
        both normal and orphan issues.
     2. **Orphan classification (#357 D6).** Check whether any
        `specs/*/created-issues.json` references this issue number. A missing,
        zero-byte, or malformed `created-issues.json` is treated as orphan (D11).
        Orphan issues run the degraded gate: tiers 1 and 2 only; tiers 3 and 4
        are skipped. `orphan_dispatches` is incremented on each orphan that
        proceeds. An orphan whose merged-PR or in-flight signals fire still
        skips dispatch (tier 1 MUST still win).
     3. **Tier 1 — merged-PR check.** Call `_reap_pr_merged` for the derived
        branch (`feat/<issue>-<key>`). If the branch already has a merged PR,
        skip dispatch and apply `needs-human-review`.
     4. **Tier 2 — in-flight workflow-state check.** Re-assert `in_flight_issues`
        for the direct `dispatch <n>` entry point. If a non-done
        `workflow-state-<issue>.json` exists, skip — unless the operator passed
        `--resume` (#156) and `_resume_allowed` confirms exactly one non-done
        state, no live `.loop-owner.pid` owner, no pending context-ceiling
        handoff and `restart_failed` unset. The other tiers still apply, so the
        operator clears `needs-human-review` and sets the card to Ready first;
        `run` never resumes on its own.
     5. **Tier 3/4 — label-board conflict (#356).** Non-orphan only. After the
        board CAS claim, check for a `status:*` label that contradicts the
        observed board Status (`Ready`). Skip and apply `needs-human-review` on
        conflict. Orphan issues bypass this check because their label history
        pre-dates the `to-issues` taxonomy.
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

This is the deliberate v1 design (see issue #33 Out of Scope). Parallel dispatch
across multiple PO-agents is not supported and would require a separate
mutex around `loop-status.json` plus per-issue workflow-state isolation.

## Wave-ordered dispatch (#548)

When `specs/` contains a `created-issues.json` or `stories.json` dependency
graph, the loop selects the next issue by **wave order** rather than raw board
insertion (FIFO) order:

1. At each poll tick, `_dependency_order()` calls
   `promote-ready.sh plan --json` to obtain the topological wave structure.
2. Issues at **wave 0** (no unresolved blockers) are selected before
   issues at wave 1, 2, … and so on.
3. **FIFO order is preserved within a wave** — issues at the same wave level
   are dispatched in their original board insertion order.
4. When no graph files are present (no `created-issues.json` / `stories.json`
   under `specs/`) or `promote-ready.sh` returns an empty list, the loop falls
   back **byte-for-byte** to the original `jq … | head -1` FIFO selection.
   Callers that do not use dependency graphs observe no behaviour change.

The `_dependency_order()` helper is **read-only** — it never mutates the board.
The board-mutation (`promote-ready.sh run --yes`) is opt-in via
`MAKATO_LOOP_ALLOW_TODO` or `--promote-unblocked` (see below).

## Opt-in auto-promotion of Todo/Blocked issues

By default the loop only dispatches issues already at board `Status=Ready`;
it does not automatically promote unblocked issues from `Todo` or `Blocked`.
Two mechanisms enable operator-controlled auto-promotion:

| Trigger | Behaviour |
|---------|-----------|
| `MAKATO_LOOP_ALLOW_TODO=1` env var | Before each poll tick, run `promote-ready.sh run --yes` non-interactively to promote newly-unblocked issues to `Ready`. |
| `--promote-unblocked` CLI flag | Same effect as `MAKATO_LOOP_ALLOW_TODO=1` for this run only. |

A non-zero exit from `promote-ready.sh` is logged but never aborts the loop
tick. Both flags default to **off** — a loop run without either does not
invoke `promote-ready.sh` and does not change any board field.

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

## Board Status=Ready as the sole dispatch signal (#688)

The board's `Status=Ready` field is the **single source of truth** for dispatch.
`loop` reads (and, since #259, claims) `Status` — not any label. Any `status:*`
label on an issue whose board card is at `Status=Ready` is now a conflict
(caught by the label-board conflict gate, tier 3/4). Operators wanting to hold
a Ready card for human review should apply `needs-human-review` (which also
appears in `_PROMOTE_EXCLUSION_LABELS` and prevents seeding).

The double-dispatch defence is the board CAS claim (plus the worktree-local
in-flight filter for same-session restarts).

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
| `queue` | array\<int\> | Issue numbers from last poll (untracked-vs-in-flight not filtered — call `next` for that). |
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
| `gate_skips_total` | integer | Running total of dispatch-gate skips this session (each skip path — exclusion-label veto, merged-PR, in-flight workflow-state, label-board conflict — increments this by 1). Reset implicitly when `loop-status.json` is recreated at `run` startup (it is not an explicit session field, so it accumulates across ticks until the file is deleted). |
| `orphan_dispatches` | integer | Count of orphan issues dispatched in the current `run` session (issues with no `created-issues.json` referencing them that proceed through the degraded gate after tiers 1+2). Reset to `0` at every `run` startup (#357 D7). Non-zero means at least one issue dispatched without full-authority gate checks — visible risk signal. |
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

- **WARN** (`idle ≥ MAKATO_LOOP_STALL_WARN`, default 21600 s = 6 h):
  stamp `active_workflow.stalled = true` and `active_workflow.stalled_since
  = <iso>` in `loop-status.json`. Operator visibility only — no signal is
  sent to the child. A single-shot latch: warning is stamped at most once
  per dispatch.
- **KILL** (`idle ≥ MAKATO_LOOP_STALL_KILL`, default 43200 s = 12 h):
  snapshot the audit to `last_watchdog_kill` (survives the
  `active_workflow=null` clear that `cmd_dispatch` does on return), stamp
  `active_workflow.killed_by_watchdog = true`, then `kill -TERM` the
  child. If the child is still alive after `MAKATO_LOOP_STALL_TERM_GRACE`
  seconds (default 30), `kill -KILL`. `cmd_dispatch`'s `wait "$child_pid"`
  then unblocks and the outer loop resumes on the next tick.

The defaults are long because the default OMP harness (`omp --yolo -p`, text
output) writes nothing to the dispatch log until the session ends, so the log
mtime stays frozen for the whole healthy PO-agent run. A genuinely hung
dispatch is therefore reaped only after 12 h; use `~/.claude/HALT` or
`kill -TERM <loop-pid>` to stop one sooner.

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

> **MANDATORY: Load `references/env-vars.md` when configuring environment overrides, writing tests, or tuning watchdog/reap thresholds.** The reference file is the authoritative table for all `loop.sh`, `loop-fleet.sh`, and `loop-supervisor.sh` variables. Do not duplicate it here.

Key groupings for quick orientation:

- **Dispatch control**: `MAKATO_LOOP_INTERVAL`, `MAKATO_LOOP_STATUS`, `MAKATO_CLAUDE_BIN`, `MAKATO_HALT_FILE`
- **Watchdog thresholds**: `MAKATO_LOOP_STALL_WARN` (21600 s), `MAKATO_LOOP_STALL_KILL` (43200 s), `MAKATO_LOOP_STALL_DISABLE`
- **Board CAS claim**: `MAKATO_LOOP_CLAIM_ON_DISPATCH` (default `1` — leave enabled in multi-worktree setups)
- **Reaper**: `MAKATO_LOOP_REAP_ON_POLL`, `MAKATO_LOOP_REAP_INTERVAL` (3600 s), `MAKATO_LOOP_REAP_SPECS`
- **Escape hatches (debug/test only)**: `MAKATO_LOOP_GATE_DISABLE`, `MAKATO_LOOP_STALL_DISABLE`, `MAKATO_LOOP_DRY_DISPATCH`
- **Fleet** (`loop-fleet.sh`): `MAKATO_FLEET_WORKERS`, `MAKATO_FLEET_CAS_STRICT`
- **Supervisor** (`loop-supervisor.sh`): `SUPERVISOR_STALE_SECS`, `MAKATO_SUPERVISOR_DRY_RUN`

State directory anchor: all paths under `.claude/state/` resolve from the repo root obtained via `git rev-parse --show-toplevel`, or from the `MAKATO_LOOP_STATE_DIR` override. Never construct state paths from `pwd`.

## Smoke tests

> **MANDATORY: Load `references/smoke-test-scenarios.md` when writing new tests, debugging a failing scenario, or verifying test coverage against the process steps above.** The reference file is the authoritative enumeration of all 61 scenarios across `loop-smoke-tests.sh`, `loop-fleet-smoke-tests.sh`, and `loop-supervisor-smoke-tests.sh`.

Run all core scenarios:

```bash
plugins/makato-orchestrate/scripts/tests/loop-smoke-tests.sh
```

The harness uses `MAKATO_LOOP_GH_OVERRIDE` to inject a canned
`item-list` fixture — fully offline, no GitHub access required.

Fleet and supervisor scenarios have their own harnesses:

```bash
plugins/makato-orchestrate/scripts/tests/loop-fleet-smoke-tests.sh
plugins/makato-orchestrate/scripts/tests/loop-supervisor-smoke-tests.sh
```

## Fleet mode — N parallel workers (#546)

`scripts/loop-fleet.sh` is an **opt-in** launcher that runs N independent
`loop.sh` workers concurrently against the same board, enabling parallel
issue dispatch without modifying the single-threaded dispatch core.

### Design

Each worker gets its own isolated state directory and pidfile so the
`loop-status.json` read-modify-write path and `stall_restart_count` counter
are never shared. The **board CAS claim** (`_claim_board_card`) is the sole
cross-worker coordination point — worker that cannot confirm its claim skips
the item rather than dispatching (fail-closed contract, #289).

A **same-folder co-schedule guard** prevents two workers from dispatching
issues that share a `specs/<folder>/` directory at the same time (avoids
`plan.md` / `seed-manifest.json` collisions, mirrors `promote-ready`'s
exclusion rule).

### Usage

```bash
# Launch 4 parallel workers (default)
plugins/makato-orchestrate/scripts/loop-fleet.sh

# Explicit worker count
plugins/makato-orchestrate/scripts/loop-fleet.sh --workers 2

# Single-tick run (each worker runs --once then exits)
plugins/makato-orchestrate/scripts/loop-fleet.sh --workers 3 --once

# N=1 is byte-for-byte the existing serial loop.sh path
plugins/makato-orchestrate/scripts/loop-fleet.sh --workers 1
```

### Key environment variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `MAKATO_FLEET_WORKERS` | `4` | Worker count (overridden by `--workers`) |
| `MAKATO_FLEET_STATE_DIR` | `$REPO_ROOT/.claude/state/fleet` | Fleet state root; per-worker subdirs are `worker-N/` |
| `MAKATO_FLEET_CAS_STRICT` | `1` | Set `MAKATO_LOOP_CLAIM_ON_DISPATCH=1` per worker (fail-closed CAS) |
| `MAKATO_FLEET_TICK_SECS` | `5` | Supervision tick interval in seconds |
| `MAKATO_FLEET_DASHBOARD` | `1` | Print per-worker status line each tick (set `0` to suppress) |
| `MAKATO_SPECS_DIR` | `$REPO_ROOT/specs` | Specs directory for the same-folder in-flight scan |
| `MAKATO_LOOP_SH_PATH` | auto-resolved | Path to `loop.sh` (useful for testing with a stub) |
| `MAKATO_HALT_FILE` | `~/.claude/HALT` | HALT-file path; launcher exits without spawning if present |

### Same-folder co-schedule guard

Before dispatching an issue, the launcher scans `MAKATO_SPECS_DIR` for
`workflow-state-*.json` files. If another issue in the same `specs/<folder>/`
has `current_phase != "done"` (i.e. is in-flight), the candidate issue is
held back for that tick. This is **read-only** — the guard never writes state
or touches the board.

### N=1 backward-compatibility guarantee

`loop-fleet.sh --workers 1` is strictly equivalent to running `loop.sh run`
directly: a single worker-1 subprocess is spawned with the same forwarded
arguments and the same environment (minus the fleet-specific vars). No
behavioural change, no extra state files beyond `fleet/worker-1/`.

### Supervision

The launcher keeps N workers alive: if a worker exits unexpectedly in
continuous mode (no `--once`), it is restarted on the next supervision tick.
Use `MAKATO_FLEET_TICK_SECS` to tune the restart latency.

### Smoke tests

```bash
plugins/makato-orchestrate/scripts/tests/loop-fleet-smoke-tests.sh
```

Six scenarios: N=2 distinct state dirs (T-FLEET-1), CAS fail-closed
(T-FLEET-2), no double-dispatch (T-FLEET-3), same-folder guard (T-FLEET-4),
N=1 serial compat (T-FLEET-5), HALT-file blocks spawn (T-FLEET-6). All run
offline with a stub `loop.sh`.

### Known limitations

- **No cross-machine fleet**: `in_flight_issues()` scans gitignored
  `specs/**` — a second host sees an empty in-flight set. The board CAS
  claim is still the correctness backstop, but cross-machine fleets are
  unsupported until `workflow-state` is promoted to a tracked location.
- **Shared Anthropic daily token budget**: N workers burn N× faster.
  Surface budget headroom before launching a large fleet; the kill-switch
  HALT-007 fires per-worker when the ceiling is reached.
- **Shared GitHub PAT secondary rate limits**: no global throttle exists;
  heavy write ops (`gh pr create`, board sync) from N workers may trigger
  GitHub secondary limits under sustained load.

## External supervisor (outermost safety net)

`scripts/loop-supervisor.sh` is an **opt-in** safety net that sits one layer
outside `loop.sh`. While `loop.sh`'s run-mutex and liveness watchdog protect
the dispatch loop from within, they cannot restart themselves if the `loop.sh`
process dies unexpectedly (OS-level OOM kill, session exit, `kill -9`). The
external supervisor fills that gap.

### What it checks

On every invocation the supervisor reads exactly two public files — nothing else
from `loop.sh` internals:

| File | Used for |
|------|----------|
| `$STATE_DIR/loop.pid` | Liveness probe (`kill -0 <pid>`; missing pidfile = dead) |
| `$STATE_DIR/loop-status.json` | `.last_dispatch_at` (staleness) and `.queue_depth` (idle vs. stuck) |

### Decision table

| Pidfile | Board | Action |
|---------|-------|--------|
| Alive   | Empty   | `no_action` — idle loop is healthy regardless of age |
| Alive   | Non-empty, recent dispatch | `no_action` — loop is progressing |
| Alive   | Non-empty, stale dispatch (≥ `SUPERVISOR_STALE_SECS`, default 600 s) | `restart` — loop appears stuck |
| Dead / missing | Empty | `no_action` — nothing to do |
| Dead / missing | Non-empty | `restart` — loop gone, work queued |
| Any     | Any | `halt_skip` if `~/.claude/HALT` exists or the `autonomous:halt` label is on the repo |

A restart is issued via `nohup bash loop.sh run … &`. Because `loop.sh`'s run-mutex
refuses a second start when it is already alive (exit 3), a false-positive restart
(supervisor misread a slow-starting process) is safe: the second start exits immediately
and the incumbent continues unaffected.

### Install

The supervisor does **not** start automatically with `loop run`. Install it as a
launchd agent or a cron job — whichever fits your setup.

**launchd (macOS):**

```bash
# 1. Copy the template and substitute placeholders
cp plugins/makato-orchestrate/scripts/com.makato.loop-supervisor.plist.template \
   ~/Library/LaunchAgents/com.makato.loop-supervisor.plist

# Replace {{MAKATO_REPO_ROOT}} and {{HOME}} in the copied file, then:

# 2. Load the agent
launchctl load ~/Library/LaunchAgents/com.makato.loop-supervisor.plist

# 3. Unload when you want to stop it
launchctl unload ~/Library/LaunchAgents/com.makato.loop-supervisor.plist
```

**cron (cross-platform fallback):**

```bash
# crontab -e
*/5 * * * * /path/to/makato/plugins/makato-orchestrate/scripts/loop-supervisor.sh >> ~/.claude/state/supervisor.log 2>&1
```

### Audit log

Every tick appends one JSON line to `$STATE_DIR/supervisor-audit.jsonl`:

```json
{"ts":"<ISO8601>","action":"<no_action|restart|halt_skip>","reason":"<why>","pid_status":"<alive|dead|missing>","stale_secs":<int-or-null>}
```

### Environment overrides

| Variable | Default | Purpose |
|----------|---------|---------|
| `MAKATO_LOOP_STATE_DIR` | `<REPO_ROOT>/.claude/state` | State directory (matches `loop.sh`) |
| `MAKATO_LOOP_PIDFILE` | `$STATE_DIR/loop.pid` | Pidfile path (matches `loop.sh`) |
| `MAKATO_HALT_FILE` | `~/.claude/HALT` | HALT-file path override |
| `SUPERVISOR_STALE_SECS` | `600` | Staleness threshold in seconds |
| `MAKATO_REPO_ROOT` | Derived from script location | Repository root |
| `MAKATO_LOOP_SCRIPT` | `<REPO_ROOT>/plugins/makato-orchestrate/scripts/loop.sh` | Path to `loop.sh` |
| `MAKATO_SUPERVISOR_AUDIT` | `$STATE_DIR/supervisor-audit.jsonl` | Per-tick audit log |
| `MAKATO_SUPERVISOR_DRY_RUN` | unset | Set to `1` to skip restart without a real `nohup` (tests) |

### Smoke tests

```bash
plugins/makato-orchestrate/scripts/tests/loop-supervisor-smoke-tests.sh
```

Seven offline scenarios covering all four plan-specified cases plus edge variants
(dead-pid empty board, missing pidfile, alive+stale dispatch).

## Out of scope

Documented limits of the v1 implementation (per issue #33):

- **Priority ordering within a wave.** Issues within the same wave are
  dispatched in board insertion (FIFO) order. Priority labels, severity
  fields, and story points are not consulted. Operators wanting finer
  priority within a wave can reorder the board manually or use the
  Projects v2 field filters in the UI.
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
