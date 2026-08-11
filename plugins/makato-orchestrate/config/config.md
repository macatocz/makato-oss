<!-- markdownlint-disable MD013 -->
# loop.sh configuration

All tunable parameters for `scripts/loop.sh` live in [`config.yml`](config.yml).
`parse-config.py` reads that file and emits bash `NAME="${ENV:-default}"`
assignments which `loop.sh` evaluates at startup — so every parameter keeps its
original environment-variable override. Setting the env var before launching the
loop always wins over the `config.yml` default.

```bash
# Override at runtime (env wins over config.yml default):
MAKATO_LOOP_INTERVAL=60 loop.sh run --once

# Or edit the default in config.yml:
#   - { var: DEFAULT_INTERVAL, env: MAKATO_LOOP_INTERVAL, default: "300" }
```

## Files

| File | Purpose |
| --- | --- |
| `config.yml` | Declarative source of truth — one entry per tunable. |
| `parse-config.py` | Emits bash assignments from `config.yml`. PyYAML when present, stdlib fallback otherwise. |
| `config.md` | This document. |

Runtime-derived paths (`REPO_ROOT`, `SPECS_DIR`, `STATE_DIR`, `PIDFILE`,
`HALT_FILE`, `CONFIG_FILE`) are **not** in `config.yml` — they depend on `git`
and `$HOME` and are resolved directly in `loop.sh`. Their env overrides
(`MAKATO_LOOP_STATE_DIR`, `MAKATO_HALT_FILE`, `MAKATO_LOOP_CONFIG`,
`MAKATO_LOOP_PIDFILE`, `SPECS_DIR`) still apply.

## Poll cadence

| Variable | Env override | Default | Meaning |
| --- | --- | --- | --- |
| `DEFAULT_INTERVAL` | `MAKATO_LOOP_INTERVAL` | `300` | Seconds between poll ticks. |
| `DEFAULT_STATUS` | `MAKATO_LOOP_STATUS` | `Ready` | Board Status option to dispatch from. Comma-list accepted (`Ready,Todo`). |
| `MAKATO_LOOP_ALLOW_TODO` | `MAKATO_LOOP_ALLOW_TODO` | *(empty)* | `1` = run `promote-ready.sh` each tick to promote unblocked issues to Ready. |

## Adaptive idle backoff (#516)

When the queue is empty tick after tick, the effective interval grows by
`IDLE_BACKOFF_FACTOR` up to `IDLE_BACKOFF_MAX`, resetting to base the moment work
appears. Floor guards clamp a factor `<1` or a max below the base interval.

| Variable | Env override | Default | Meaning |
| --- | --- | --- | --- |
| `IDLE_BACKOFF_MAX` | `MAKATO_LOOP_IDLE_MAX` | `1800` | Cap on the grown interval (seconds). |
| `IDLE_BACKOFF_FACTOR` | `MAKATO_LOOP_IDLE_FACTOR` | `2` | Multiplier per idle tick. `1` disables backoff. |

## Board sync — assign & CAS claim

| Variable | Env override | Default | Meaning |
| --- | --- | --- | --- |
| `ASSIGN_ON_DISPATCH` | `MAKATO_LOOP_ASSIGN_ON_DISPATCH` | `1` | Assign the issue before spawn to trigger the board Ready→In progress webhook (#33). `0` disables. |
| `ASSIGNEE` | `MAKATO_LOOP_ASSIGNEE` | `@me` | Login used for the assign. |
| `CLAIM_ON_DISPATCH` | `MAKATO_LOOP_CLAIM_ON_DISPATCH` | `1` | Synchronous board CAS claim closing the cross-worktree double-dispatch race (#259). **Never disable in multi-worktree setups.** |

## Dispatch gate (#318/#355)

| Variable | Env override | Default | Meaning |
| --- | --- | --- | --- |
| `GATE_DISABLE` | `MAKATO_LOOP_GATE_DISABLE` | `0` | `1` fully restores pre-#318 dispatch (no checks, no stamp). **Never in production.** |

## Liveness watchdog (#164)

Seconds of no PO-agent output before the watchdog escalates.

| Variable | Env override | Default | Meaning |
| --- | --- | --- | --- |
| `STALL_WARN_SECS` | `MAKATO_LOOP_STALL_WARN` | `900` | Stamp `stalled=true` (warn only). |
| `STALL_KILL_SECS` | `MAKATO_LOOP_STALL_KILL` | `3600` | SIGTERM the PO-agent (SIGKILL after grace). |
| `STALL_POLL_SECS` | `MAKATO_LOOP_STALL_POLL` | `60` | Watchdog poll cadence. |
| `STALL_TERM_GRACE_SECS` | `MAKATO_LOOP_STALL_TERM_GRACE` | `30` | Seconds between SIGTERM and SIGKILL. |

`MAKATO_LOOP_STALL_DISABLE=1` skips the watchdog entirely (read directly in
`functions.sh` — debug-only, never in production).

## Stall recovery (#444)

Bounded restart sequence before the watchdog kill takes over.

| Variable | Env override | Default | Meaning |
| --- | --- | --- | --- |
| `STALL_THRESHOLD_SECS` | `MAKATO_LOOP_STALL_THRESHOLD` | `300` | No-output window that triggers stall classification. |
| `MAX_STALL_RESTARTS` | `MAKATO_MAX_STALL_RESTARTS` | `3` | Restart-attempt ceiling per dispatch. |
| `STALL_BACKOFF_BASE_SECS` | `MAKATO_STALL_BACKOFF_BASE` | `60` | Base interval for exponential restart backoff. |

## Headless CLI resilience (#531/#532)

Exported so every `claude -p` subprocess inherits them.

| Variable | Env override | Default | Meaning |
| --- | --- | --- | --- |
| `CLAUDE_CODE_RETRY_WATCHDOG` | `CLAUDE_CODE_RETRY_WATCHDOG` | `1` | Retries 429/529 indefinitely; raises transient-error budget to ~300 attempts. |
| `API_TIMEOUT_MS` | `API_TIMEOUT_MS` | `1200000` | Per-request timeout (20 min). |

`API_FORCE_IDLE_TIMEOUT` is opt-in — exported by `loop.sh` only when the operator
sets it (the CLI's 5-min stream-idle watchdog; set `0` behind slow proxies).

## Run-mutex force reclaim (#172)

| Variable | Env override | Default | Meaning |
| --- | --- | --- | --- |
| `FORCE_GRACE_SECS` | `MAKATO_LOOP_FORCE_GRACE` | `10` | Seconds between SIGTERM and SIGKILL when `run --force` reclaims a live instance. |

## Worktree & specs reaper (#265/#320)

| Variable | Env override | Default | Meaning |
| --- | --- | --- | --- |
| `REAP_ON_POLL` | `MAKATO_LOOP_REAP_ON_POLL` | `1` | `0` disables the merged-worktree reaper. |
| `REAP_INTERVAL_SECS` | `MAKATO_LOOP_REAP_INTERVAL` | `3600` | Min seconds between reap passes. `0` = every tick. |
| `REAP_STALE_AGE_SECS` | `MAKATO_LOOP_REAP_STALE_AGE` | `86400` | Age before the stale-crash reaper considers a worktree. |
| `REAP_STALE_FORCE` | `MAKATO_LOOP_REAP_STALE_FORCE` | `0` | `1` reaps a stale worktree even with unpushed commits. |
| `REAP_SPECS` | `MAKATO_LOOP_REAP_SPECS` | `1` | `0` disables orphaned `specs/<slug>/` pruning. |

`MAKATO_LOOP_REAP_DRYRUN=1` logs intended removals without mutating disk (read
directly in `functions.sh`).

## Orphaned In-progress reconciliation (#368/#616)

| Variable | Env override | Default | Meaning |
| --- | --- | --- | --- |
| `RECONCILE_ON_POLL` | `MAKATO_LOOP_RECONCILE_ON_POLL` | `1` | Move In-progress cards with no live workflow-state to Blocked+needs-human-review. |
| `RECONCILE_DRYRUN` | `MAKATO_LOOP_RECONCILE_DRYRUN` | `0` | `1` = report only. |
| `ORPHAN_STALE_SECS` | `MAKATO_ORPHAN_STALE_SECS` | `3600` | Age before a present-but-dead workflow-state is a stale orphan. |
| `ORPHAN_DETECT_DISABLE` | `MAKATO_ORPHAN_DETECT_DISABLE` | `0` | `1` disables stale-orphan detection. |

## workflow-state prune pass (#597)

| Variable | Env override | Default | Meaning |
| --- | --- | --- | --- |
| `MAKATO_LOOP_PRUNE_ON_RUN` | `MAKATO_LOOP_PRUNE_ON_RUN` | `0` | `1` removes done+stale `workflow-state-*.json` after each reap. |
| `MAKATO_LOOP_PRUNE_AGE_DAYS` | `MAKATO_LOOP_PRUNE_AGE_DAYS` | `30` | Age threshold for the prune pass. |

## Sleep-wake & idempotent-dispatch guards (#171)

| Variable | Env override | Default | Meaning |
| --- | --- | --- | --- |
| `SLEEP_MAX_STEP_SECS` | `MAKATO_LOOP_SLEEP_MAX_STEP` | `30` | Max seconds per raw `sleep` in `_guarded_sleep` (wall-clock guarantee). Floored at 1. |
| `MIN_DISPATCH_GAP_SECS` | `MAKATO_LOOP_MIN_DISPATCH_GAP` | `30` | Refuse re-dispatch of an in-flight issue younger than this. |
| `LAST_DISPATCH_GAP_SECS` | `MAKATO_LOOP_LAST_DISPATCH_GAP` | `30` | Refuse re-dispatch within this window of the last dispatch. |

## Board-poll resilience (#289)

| Variable | Env override | Default | Meaning |
| --- | --- | --- | --- |
| `POLL_RETRIES` | `MAKATO_LOOP_POLL_RETRIES` | `3` | Poll attempts before surfacing a transient-error state. Floored at 1. |
| `POLL_BACKOFF_BASE_SECS` | `MAKATO_LOOP_POLL_BACKOFF_BASE` | `2` | Base for exponential poll backoff. |

## GraphQL rate-limit guard (#556/#683)

| Variable | Env override | Default | Meaning |
| --- | --- | --- | --- |
| `GRAPHQL_MIN_REMAINING` | `MAKATO_LOOP_GRAPHQL_MIN_REMAINING` | `1000` | Sleep-until-reset when remaining budget drops below this. |
| `RATE_GUARD` | `MAKATO_LOOP_RATE_GUARD` | `1` | `0` disables the guard. |
| `RATE_SKIP_THRESHOLD` | `MAKATO_LOOP_RATE_SKIP_THRESHOLD` | `3` | Consecutive rate-budget skips before the circuit-breaker sleep. |
| `RATE_SKIP_BACKOFF` | `MAKATO_LOOP_RATE_SKIP_BACKOFF` | `600` | Circuit-breaker sleep seconds. |
| `BOARD_LIMIT` | `MAKATO_LOOP_BOARD_LIMIT` | `500` | Item ceiling for the `item-list` fallback path. |

## Critical-call REST fallback (#447)

| Variable | Env override | Default | Meaning |
| --- | --- | --- | --- |
| `FALLBACK_RETRIES` | `MAKATO_LOOP_FALLBACK_RETRIES` | `2` | REST-fallback attempts after the primary `gh` call fails. Floored at 1. |
| `FALLBACK_BACKOFF_BASE_SECS` | `MAKATO_LOOP_FALLBACK_BACKOFF_BASE` | `2` | Base for exponential fallback backoff. |

## Promote-ready exclusion set

| Variable | Env override | Default | Meaning |
| --- | --- | --- | --- |
| `_PROMOTE_EXCLUSION_LABELS` | *(none)* | `triage experimental status:blocked autonomous:halt needs-human-review needs-reshape` | Labels that veto auto-seed promotion/dispatch even when board Status matches (#286). |

## Open-model endpoint (issue #7)

Routes every `omp` / Claude Code dispatch through a cloud open-model API so
makato-oss runs fully headless on an open endpoint without any closed-provider
dependency. Part of the Phase-1 harness-independence milestone.

| Variable | Env override | Default | Meaning |
| --- | --- | --- | --- |
| `MAKATO_OPEN_ENDPOINT_URL` | `MAKATO_OPEN_ENDPOINT_URL` | *(empty)* | Base URL of the cloud open-model API (e.g. `https://api.openai.com/v1` or any OpenAI-compatible endpoint). When non-empty, `loop.sh` exports it as `ANTHROPIC_BASE_URL` so the harness CLI routes all LLM calls through this endpoint. Empty = use harness default (closed API). |
| `MAKATO_OPEN_MODEL_ROLES` | `MAKATO_OPEN_MODEL_ROLES` | `sonnet,haiku,opus` | Comma-separated list of oh-my-pi modelRole tiers expected to route through `MAKATO_OPEN_ENDPOINT_URL`. Informational in Phase 1 (the roles are wired via issue #5 frontmatter); reserved for role-specific routing helpers added in later sequences. |

**Runtime behaviour:** `loop.sh` evaluates the config after `parse-config.py` and then runs:

```bash
if [[ -n "${MAKATO_OPEN_ENDPOINT_URL:-}" ]]; then
  export ANTHROPIC_BASE_URL="$MAKATO_OPEN_ENDPOINT_URL"
fi
```

Every `$CLAUDE_BIN` subprocess (po-agent, seed-issue, refine) inherits
`ANTHROPIC_BASE_URL`, which the harness respects as its API base. No changes
to sub-agent frontmatter are required — the modelRole wiring from issue #5 is
the only other half of this composition.

## Persistent volume (issue #8 — Vast.ai preemption survival)

Many `MAKATO_LOOP_*_TEST_*` / `*_OVERRIDE` env vars keep the smoke suite offline
(canned `gh` payloads, eval'd command stubs). They are consumed directly in
`functions.sh` and are **not** operator-facing tunables — see the `_test-*` hook
block in `loop.sh` and the per-function docstrings.
