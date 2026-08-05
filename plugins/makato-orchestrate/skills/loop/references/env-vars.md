# loop Environment Variables Reference

Full variable table for `loop.sh`, `loop-fleet.sh`, and `loop-supervisor.sh`.

## Core `loop.sh` Variables

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
| `MAKATO_LOOP_PROMOTE_OVERRIDE` | unset | **Removed in #688.** No-op — `_promote_labelled_ready` no longer exists. |
| `MAKATO_LOOP_PROMOTE_DRYRUN` | unset | **Removed in #688.** No-op — `_promote_labelled_ready` no longer exists. |
| `MAKATO_LOOP_STALL_WARN` | `900` | Seconds of no output before the watchdog stamps `active_workflow.stalled = true`. |
| `MAKATO_LOOP_STALL_KILL` | `3600` | Seconds of no output before the watchdog `SIGTERM`s the PO-agent. |
| `MAKATO_LOOP_STALL_POLL` | `60` | Watchdog poll cadence in seconds (small values used in smoke tests). |
| `MAKATO_LOOP_STALL_TERM_GRACE` | `30` | Seconds between `SIGTERM` and the follow-up `SIGKILL` if the child hasn't exited. |
| `MAKATO_LOOP_STALL_DISABLE` | unset | Set to `1` to disable the watchdog entirely (no log capture, no background poller, no status stamps). |
| `MAKATO_LOOP_STALL_TEST_CMD` | unset | Test-only: run this command in place of `claude` (e.g. `sleep 30`) so the watchdog has a real stall to reap. |
| `MAKATO_LOOP_PIDFILE` | `<state-dir>/loop.pid` | Override the run-mutex pidfile path (#172). Tests use this to isolate the mutex from any concurrent operator loop on the same box. |
| `MAKATO_LOOP_FORCE_GRACE` | `10` | Seconds between `SIGTERM` and `SIGKILL` when `run --force` reclaims a live pidfile. |
| `MAKATO_LOOP_ASSIGN_ON_DISPATCH` | `1` | Set to `0` to skip the assign-on-dispatch step (no `issues.assigned` webhook → board stays at `Ready`). See §*assign-on-dispatch (#33) — now a belt-and-braces trigger* in SKILL.md. |
| `MAKATO_LOOP_ASSIGNEE` | `@me` | Assignee login passed to `gh issue edit --add-assignee` at dispatch. `@me` = the authenticated `gh` user driving the loop. |
| `MAKATO_LOOP_ASSIGN_TEST_FILE` | unset | Test-only: append the intended assign (`assign #<n> assignee=<x> repo=<y>`) to this file instead of calling `gh`. |
| `MAKATO_LOOP_CLAIM_ON_DISPATCH` | `1` | Set to `0` to disable the synchronous board CAS claim (#259). With it off, the loop relies solely on the async assign→webhook path and the cross-worktree double-dispatch race re-opens — leave enabled in multi-worktree setups. See §*Board writes at dispatch: the synchronous claim* in SKILL.md. |
| `MAKATO_LOOP_CLAIM_TEST_FILE` | unset | Test-only: append the claim decision (`claim #<n> status=<s> → {claimed\|skip\|warn-proceed}`) to this file instead of calling `gh`. |
| `MAKATO_LOOP_CLAIM_STATUS_OVERRIDE` | unset | Test-only: the fixture current board Status the re-poll should observe (`Ready`, `In progress`, or empty for the unreadable-Status fallback). Consumed only alongside `MAKATO_LOOP_CLAIM_TEST_FILE`. |
| `MAKATO_LOOP_REAP_ON_POLL` | `1` | Set to `0` to disable the merged-worktree reaper (#265) entirely (no pre-poll pass, `remove-worktrees` short-circuits). |
| `MAKATO_LOOP_REAP_INTERVAL` | `3600` | Minimum seconds between reap passes. The pass is invoked every tick but no-ops until the window elapses. Set `0` to run every call (one-shot cleanup / tests). |
| `MAKATO_LOOP_REAP_DRYRUN` | unset | Set to `1` to log intended removals (`reap would remove …`) without running `git worktree remove`. |
| `MAKATO_LOOP_REAP_REPO` | unset | Override the owner/repo used for `gh pr list` (default: `MAKATO_LOOP_DISPATCH_REPO`, else parsed from `git remote get-url origin`). |
| `MAKATO_LOOP_REAP_GH_OVERRIDE` | unset | Test-only: path to a JSON map `{"<branch>": "<pr#>"}` read instead of calling `gh pr list`. Keeps the reap smoke tests offline. |
| `MAKATO_LOOP_REAP_BASE_REF` | unset | Override the base ref used for the ancestry landed-check (default: `origin/HEAD`, else `origin/main`). Tests point it at a local `main` so ancestry works in a throwaway repo with no remote. |
| `MAKATO_LOOP_REAP_WT_OVERRIDE` | unset | Test-only: path to a file with canned `git worktree list --porcelain` output, read instead of invoking git. |
| `MAKATO_LOOP_REAP_SPECS` | `1` | Set to `0` to disable orphaned-specs pruning. When on, untracked `specs/<slug>/` folders for done/closed issues are removed in the same reap pass. Tracked spec folders are never touched (consumer repos use `archive-spec.sh`). |
| `MAKATO_LOOP_REAP_SPECS_GH_OVERRIDE` | unset | Test-only: path to a JSON map `{"<issue_number>": "open\|closed"}` read instead of calling `gh issue view`. Keeps the specs-prune smoke tests offline. |
| `MAKATO_HANDOFF_ACK_TIMEOUT` | `120` | Seconds the pre-poll HALT-007B liveness check (#284) waits for a resumed subprocess to write `resume_ack` before firing the HALT-007 fallback. A dead PID short-circuits the wait. Read by `context-handoff.sh check-pid`; lower it in tests to force the timeout path. |
| `MAKATO_LOOP_AUTOSEED_ON_POLL` | `1` | Set to `0` to disable the pre-poll auto-seed pass entirely (#373, epic #367 S5). When unset or `1`, `_auto_seed_unprepared` runs on every tick where "Ready" is among the polled statuses. Disable for repos that manage seeding externally or for debugging. |
| `MAKATO_LOOP_AUTOSEED_OVERRIDE` | unset | Test-only: path to a JSON file in `gh issue list --json number,labels,author` shape, read instead of calling `gh` in `_auto_seed_candidates`. Keeps S1/S5 discovery smoke tests offline. |
| `MAKATO_LOOP_SEED_TEST_CMD` | unset | Test-only: command string used as the dispatch command instead of the real `claude -p` in `_auto_seed_dispatch_light`. Receives the same env (`MAKATO_HEADLESS=1`, `ISSUE_NUMBER`, `REPO`, `REPO_ROOT`) and prompt as the production invocation. Keeps S2/S5 dispatch smoke tests offline. |
| `MAKATO_LOOP_BLOCK_TEST_FILE` | unset | Test-only: path to a file that `_auto_seed_block_full` appends `block #<n>` to instead of calling `gh project item-edit` to set `Blocked`. Keeps S4/S5 block smoke tests offline. |
| `MAKATO_LOOP_AUTOSEED_SPEC_ROOT` | unset | Test-only: override the `SPECS_DIR` root used by `_auto_seed_block_full` when creating spec-folder stubs. Tests redirect to a temp directory to avoid polluting `specs/`. |
| `MAKATO_LOOP_RECONCILE_ON_POLL` | `1` | Set to `0` to disable the orphaned-`In progress` reconciliation pass entirely (#368). |
| `MAKATO_LOOP_RECONCILE_DRYRUN` | unset | Set to `1` to log intended reconciliations without mutating board or labels. |
| `MAKATO_LOOP_RECONCILE_GH_OVERRIDE` | unset | Test-only: path to a JSON fixture for the `In progress` board poll instead of calling `gh`. Keeps Tl–Tp smoke tests offline. |
| `MAKATO_LOOP_RECONCILE_TEST_FILE` | unset | Test-only: append `reconcile #N` here instead of calling `gh project item-edit`. |
| `MAKATO_LOOP_RECONCILE_LABEL_TEST_FILE` | unset | Test-only: append `label #N needs-human-review` here instead of calling `gh issue edit`. |
| `MAKATO_LOOP_RECONCILE_SPECS_DIR` | unset | Test-only: override `SPECS_DIR` for the in-flight scan within `_reconcile_orphaned_in_progress`. Keeps Tm/Tn tests from polluting the real `specs/` tree. |
| `MAKATO_LOOP_GATE_DISABLE` | `0` | Set to `1` to disable the entire dispatch gate (#318/#355/#357). All four tiers (exclusion-label veto, merged-PR, in-flight workflow-state, label-board conflict) are bypassed and orphan detection is skipped. Pre-#318 dispatch behaviour is fully restored. Use only for debugging or offline smoke tests that need to exercise the post-gate path without fixtures for all gate inputs. |
| `MAKATO_LOOP_RESHAPE_ENABLED` | `0` | Set to `1` to enable the pre-poll reshape pass (#350). When disabled (default), `_reshape_pass` is a no-op regardless of board state. Enable for repos that use the Needs Planning → Reshape → Ready feedback loop (epic #319). |
| `MAKATO_MAX_RESHAPE_CYCLES` | `3` | Maximum number of `decompose Refine + to-issues` dispatch attempts per issue before `needs-human-review` is applied and no further reshaping is attempted. Guards against infinite reshape loops on structurally unresolvable stories. |
| `MAKATO_LOOP_RESHAPE_TEST_CMD` | unset | Test-only: command string eval'd inside a subshell in place of the real `claude` dispatch in `_reshape_pass`. Receives the same env context as the production path. Keeps T-reshape smoke tests offline. |
| `MAKATO_LOOP_RESHAPE_OVERRIDE` | unset | Test-only: path to a JSON file in `[{"number": N, "key": "K"}]` shape, read instead of calling `gh project item-list` / `gh issue list --label needs-reshape` in `_reshape_pass`. Keeps T-reshape smoke tests offline. |
| `MAKATO_LOOP_ALLOW_TODO` | unset | Set to `1` to trigger `promote-ready.sh run --yes` in the pre-poll step before each board poll. Promotes newly-unblocked issues from `Todo`/`Blocked` to `Ready` so the same tick can dispatch them. Default off — omitting the flag means no auto-promotion and no board mutation by this env path. Equivalent to passing `--promote-unblocked` on the CLI. |
| `MAKATO_PROMOTE_PATH` | (auto-resolved) | Override the path to `promote-ready.sh` for the `_dependency_order` helper and the `--promote-unblocked` pre-poll step. Defaults to `promote-ready.sh` in the same `scripts/` directory as `loop.sh`. Test-only: use a stub binary to control what wave ordering or promotion output the loop sees. |

## Fleet Mode Variables (`loop-fleet.sh`)

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

## Supervisor Variables (`loop-supervisor.sh`)

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
