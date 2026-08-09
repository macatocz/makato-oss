# loop Smoke-Test Scenarios Reference

Full enumeration of all scenarios in `scripts/loop-smoke-tests.sh`.
Referenced by the process step numbers in SKILL.md.

Run all tests:
```bash
plugins/makato-orchestrate/scripts/loop-smoke-tests.sh
```

The harness uses `MAKATO_LOOP_GH_OVERRIDE` to inject a canned `item-list` fixture — fully offline, no GitHub access required.

## Core Scenarios (T1–T21)

1. `check-halt` exits 0 with no HALT file.
2. `check-halt` exits 1 with a HALT file.
3. `dispatch <n> --dry-run` writes and clears `active_workflow`.
4. `dispatch` refuses (exit 2) while another `active_workflow` is in flight.
5. `in_flight_issues` skips spec folders with `current_phase: "done"`.
6. `in_flight_issues` includes spec folders with `current_phase: "implement"`.
7. `run --once --dry-run` writes the status file and exits without dispatching.
8. `run --once` exits cleanly when the HALT file is present (no dispatch).
9. `run --once` with `MAKATO_LOOP_DRY_DISPATCH=1` dispatches the first untracked issue and records `last_dispatch_issue`.
10. `poll <STATUS>` filters by board Status (items at other Statuses excluded).
11. `poll` excludes non-Issue content (DraftIssue, PullRequest).
12. Watchdog stamps `active_workflow.stalled = true` after `MAKATO_LOOP_STALL_WARN` seconds of silence (#164).
13. Watchdog SIGTERMs the child after `MAKATO_LOOP_STALL_KILL` seconds and the `last_watchdog_kill` snapshot survives the `active_workflow=null` clear (#164).
14. `MAKATO_LOOP_STALL_DISABLE=1` opts out of the watchdog entirely — no log file, no status stamps (#164).
15. `run` refuses with exit 3 when a live pidfile exists — the refusing instance does not clobber the pidfile (#172).
16. `run` reclaims a stale pidfile silently (PID gone) and its EXIT trap cleans up on shutdown (#172).
17. `startup_audit` records `script_path`, `pid`, `ppid`, `pidfile`, and the CLI arguments (#172).
18. `run --force` SIGTERMs a live incumbent and takes over the pidfile (#172).
19. `dispatch` assigns the issue on the real-fork path (assignee + repo threaded through); `--dry-run` does not assign (#33).
20. `MAKATO_LOOP_ASSIGN_ON_DISPATCH=0` disables the assign step (#33).
21. `dispatch` derives `KEY`/`BRANCH` from the issue body's `to-issues` provenance and threads the full po-agent input bundle (`ISSUE_NUMBER`/`KEY`/`REPO`/`BRANCH`/`REPO_ROOT`) into the dispatch prompt; falls back to the `specs/<slug>/stories.json` line; degrades to a `WARN` with empty `KEY` when the body has no provenance (#144).

## Board CAS + Reaper Scenarios (T22–T30)

22. **Board CAS claim (#259, T30).** `dispatch` claims the card when its board Status is still `Ready`, **skips** (exit 0, no spawn, no assign, `active_workflow` cleared) when the Status has moved off `Ready` (a second worktree session already claimed it), `WARN`-proceeds when the Status is unreadable, and records no claim decision when `MAKATO_LOOP_CLAIM_ON_DISPATCH=0`.
23. **Reaper decision set (#265, T31).** `remove-worktrees --dry-run` flags a landed (merged-PR) clean worktree for removal and skips tracked-dirty, locked, not-landed, and the main checkout.
24. **Reaper live removal (#265, T32).** A landed, clean worktree is actually removed; tracked-dirty/locked/not-landed worktrees survive; `last_reap`, `last_reap_count`, and `reaped[].landed` are stamped in `loop-status.json`.
25. **Reaper retained guard (#265, T33).** A worktree whose `workflow-state` has `worktree_retained: true` is skipped even when its PR is merged.
26. **Reaper opt-out (#265, T34).** `MAKATO_LOOP_REAP_ON_POLL=0` short-circuits the whole pass — no worktrees are walked.
27. **Reaper throttle (#265, T35).** A second `remove-worktrees` call within `MAKATO_LOOP_REAP_INTERVAL` is a no-op (the `last_reap` stamp gates it).
28. **Reaper ancestry landed-check (#265, T36).** A branch whose `HEAD` is an ancestor of the base ref is reaped even with **no** merged PR (renamed-head / squash-merge safe); a worktree sitting exactly on the base tip survives.
29. **Reaper untracked-scratch (#265, T37).** A landed worktree carrying only untracked files is still reaped — untracked scratch does not pin.
30. **Reaper nested-worktree guard (#265, T38).** Both a worktree that is the parent of a nested worktree and one nested inside another worktree are skipped.

## Auto-Seed Scenarios (Ta–Ti, #373/#688)

31. **Auto-seed composition — light seed (Ta, #373).** `_auto_seed_unprepared` dispatches S2 for a `plan-tier:light` candidate, S3 confirms no thin-body, function returns 0.
32. **Auto-seed composition — thin-body reconciled (Tb, #373).** Light candidate dispatched (S2); S3 detects thin-body → `needs-human-review` applied; function returns 0 (best-effort).
33. **Auto-seed composition — full-blocked (Tc, #373).** `plan-tier:full` candidate routes to S4 (block recorded), function returns 0.
34. **Auto-seed composition — untiered-as-full (Td, #373).** Empty `plan_tier` routes to S4 (same as full).
35. **Auto-seed composition — exclusion-veto (Te, #373).** Candidate carrying an exclusion label is skipped; no seed or block action.
36. **Auto-seed composition — best-effort on S2 failure (Tf, #373).** S2 dispatch exits 1; WARN is logged; function still returns 0.
37. **Auto-seed composition — sentinel idempotency (Tg, #373).** S4 detects the block sentinel already present in issue comments and skips re-posting.
38. **Auto-seed composition — toggle-off (Th, #373).** `MAKATO_LOOP_AUTOSEED_ON_POLL` guard is present in `cmd_run` and protects the `_auto_seed_unprepared` call (structural check — confirms the toggle controls the call site).
39. **Auto-seed composition — ordering (Ti, #688).** `_promote_labelled_ready || true` is absent from `cmd_run` (removed); `_auto_seed_unprepared` call is still present.
40. **Auto-seed composition — dependencies veto (Tj, #373).** Candidate with the `dependencies` label is skipped by S1 discovery.
41. **Auto-seed composition — already-ready (Tk, #688).** Candidate with `status:ready-for-dev` label now appears in candidates (label filter removed; AC-4).

## Orphaned-In-Progress Reconciliation (Tl–Tp, #368)

42. **Orphaned-In-progress reconciliation — orphaned card reconciled (Tl, #368).** Board has issue #600 at `In progress`; no local workflow-state; function records `reconcile #600` in test file and logs the orphaned message.
43. **Orphaned-In-progress reconciliation — live workflow-state skipped (Tm, #368).** Board has #601 at `In progress`; non-done `workflow-state-601.json` present; #601 is NOT written to the reconcile test file.
44. **Orphaned-In-progress reconciliation — done workflow-state reconciled (Tn, #368).** Board has #602 at `In progress`; `workflow-state-602.json` with `current_phase: "done"`; treated as orphaned → reconciled.
45. **Orphaned-In-progress reconciliation — dry-run no mutation (To, #368).** `MAKATO_LOOP_RECONCILE_DRYRUN=1`; board has orphaned #603; reconcile test file stays empty; log contains `would reconcile`.
46. **Orphaned-In-progress reconciliation — toggle-off no-op (Tp, #368).** `MAKATO_LOOP_RECONCILE_ON_POLL=0`; board has orphaned #604; function returns 0 without walking candidates.

## Reshape Pass Scenarios (T-reshape-*, #350)

47. **Reshape pass — flag disabled (T-reshape-disabled, #350).** `MAKATO_LOOP_RESHAPE_ENABLED=0` (or unset): `_reshape_pass` returns 0 immediately, no dispatch, no label write.
48. **Reshape pass — HALT preempts (T-reshape-halt-preempts, #350).** HALT file present: `_reshape_pass` returns 0 without dispatching, honouring the kill-switch.
49. **Reshape pass — happy path (T-reshape-happy-path, #350).** `reshape_cycles=0`, both dispatches succeed: `needs-reshape` label removed, `reshape_cycles` incremented to 1, `orchestrate.jsonl` records `step:"reshape" status:"ok"`.
50. **Reshape pass — decompose fails (T-reshape-decompose-fails, #350).** Dispatch exits non-zero: `needs-human-review` applied, `reshape_cycles` unchanged, `orchestrate.jsonl` records `status:"error"`.
51. **Reshape pass — cycle ceiling (T-reshape-cycle-ceiling, #350).** `reshape_cycles >= MAKATO_MAX_RESHAPE_CYCLES`: `needs-human-review` applied without dispatching.
52. **Reshape pass — label fallback (T-reshape-label-fallback, #350).** Board poll empty but `MAKATO_LOOP_RESHAPE_OVERRIDE` fixture provides a candidate: dispatch proceeds correctly (tests the fallback discovery path).
53. **Reshape pass — toggle position (T-reshape-toggle-position, #350).** Structural grep confirms `_reshape_pass` call site appears on an earlier line than `_auto_seed_unprepared` in `cmd_run`, preserving the load-bearing serial invariant.

## Orphan Detection + Dispatch Gate Scenarios (T-orphan-*, #357)

54. **Orphan detection — missing created-issues.json (T-orphan-1, #357).** No `created-issues.json` in any specs folder: `_is_orphan_issue` exits 0 (orphan).
55. **Orphan detection — malformed created-issues.json (T-orphan-2, #357).** Non-JSON file: treated as orphan (D11).
56. **Orphan detection — zero-byte created-issues.json (T-orphan-3, #357).** Empty file: treated as orphan (D11).
57. **Orphan detection — referenced issue not orphan (T-orphan-4, #357).** `created-issues.json` contains matching `issue_number`: `_is_orphan_issue` exits 1 (not orphan).
58. **Orphan with merged PR skipped by tier 1 (T-orphan-5, #357).** Orphan + merged-PR fixture: tier 1 fires, dispatch skipped, `orphan_dispatches` NOT incremented.
59. **Orphan with no blocking signals proceeds (T-orphan-6, #357).** Orphan + no PR + no in-flight: dispatch proceeds, `orphan_dispatches` increments to 1.
60. **Orphan counter accumulates (T-orphan-7, #357).** Three orphan dispatches in sequence: `orphan_dispatches == 3` after the run.
61. **Orphan counter is session-scoped (T-orphan-8, #357).** Pre-existing `orphan_dispatches=5` in status file is reset to 0 at session start; one orphan dispatch brings it to 1.

## Fleet Scenarios (`loop-fleet-smoke-tests.sh`)

Six scenarios: N=2 distinct state dirs (T-FLEET-1), CAS fail-closed (T-FLEET-2), no double-dispatch (T-FLEET-3), same-folder guard (T-FLEET-4), N=1 serial compat (T-FLEET-5), HALT-file blocks spawn (T-FLEET-6). All run offline with a stub `loop.sh`.

```bash
plugins/makato-orchestrate/scripts/loop-fleet-smoke-tests.sh
```

## Supervisor Scenarios (`loop-supervisor-smoke-tests.sh`)

Nine offline scenarios covering all four plan-specified cases plus edge variants (dead-pid empty board, missing pidfile, alive+stale dispatch, alive mid-dispatch no-action, alive stalled dispatch restart).

```bash
plugins/makato-orchestrate/scripts/loop-supervisor-smoke-tests.sh
```
