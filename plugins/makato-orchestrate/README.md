# makato-orchestrate

**Goal:** Drive a GitHub Issue from ready-for-dev through to a merged PR without human intervention.

**How:** The plugin hosts the PO-agent and the supporting infrastructure that bridges makato-plan
output to makato-build execution — workflow-state for resumable session state, kill-switch for
operator and budget controls, a polling loop as the unattended entry point, a session-status hook
for restart resumability, and resolve-pr-conflict for autonomous merge-conflict handling. Four
agents (po-agent, context-summariser, task-file-scout, documentation-agent) and five skills cover the full
lifecycle from issue pickup through post-merge housekeeping.

**Why:** Without an outer driver, every transition between planning and build requires a human.
`makato-plan` shapes and decomposes GitHub Issues into acceptance-tested stories; `makato-build`
takes a single story and produces a tested, reviewed PR. This plugin is the control plane that
connects them, managing retry, HALT, and audit semantics so the entire pipeline can run
unattended.

## What Belongs Here

- The PO-agent definition and its dispatch loop
- Workflow-state schema and read/write skill (sole writer of state)
- Kill-switch infrastructure: HALT file poll, GitHub label poll, token-budget ceiling
- Session-status hook for restart resumability
- The autonomous loop skill (entry point for unattended runs)
- HALT-code dispatch tables and needs-human-review labelling logic
- resolve-pr-conflict skill for autonomous merge-conflict resolution
- context-summariser and task-file-scout agents supporting the PO-agent loop
- documentation-agent for post-merge housekeeping
- worktree lifecycle helper (shared/worktree.sh)

## What Does NOT Belong Here

- Any source-code edits to the target repository (PO-agent orchestrates, never implements)
- Planning and shaping skills — PRD, architecture, decomposition (those live in makato-plan)
- Quality-gate skills — review, simplify, verify (those live in makato-build)
- Hotfixes or ad-hoc changes (those belong in makato-change)
- CI/CD pipeline configuration

## Workflow

The outer loop is entered via the `loop` skill and exits on a merged PR or a documented HALT:

```
  operator terminal              loop-cron.yml (GHA, every 10 min)
  loop --autonomous              loop.sh run --once
        │                        [requires ANTHROPIC_API_KEY secret]
        └────────────┬───────────────────────┘
                     │ cross-machine mutex: board CAS claim (Status → In Progress)
                     ▼
┌───────────────────────────┐
│           loop            │  Entry: loop --autonomous / run --once
│        (autonomous)       │  Output: .claude/state/loop-status.json
└──────────┬────────────────┘
           │ dispatches PO-agent serially per untracked issue
           ▼
┌───────────────────────────┐
│         po-agent          │  Input:  GitHub Issue + specs/<key>-<slug>/
│    (sonnet, maxTurns=100) │  Output: merged PR or documented HALT code
└──────────┬────────────────┘
           │
   ┌───────┴──────────────────────────────────────┐
   │  outer loop (bounded by outer_iterations)    │
   │    kill-switch.poll()      → HALT if fired   │
   │    context-handoff check   → HALT-007B       │
   │    build-refine            → task plan       │
   │    scout (per task)        → SCOUT_SUMMARY   │
   │    build-implement-tdd /                     │
   │      build-implement-goal  → R1 envelope     │
   │    resolve-pr-conflict     → on push reject  │
   │    build-review --round N  → one review round│
   │      review_gate.py        → SUCCESS/        │
   │                              CONTINUE/STOP   │
   │    build-verify                              │
   │    build-push-to-git                         │
   │    build-create-pr         → PR number       │
   │    build-address-pr-comments → merged or     │
   │      re-loop                  needs-human    │
   └──────────────────────────────────────────────┘
           │ on PR merged
           ▼
┌───────────────────────────┐
│  workflows/post-merge.yml │  Trigger: pull_request.closed + merged=true
│       (GitHub Actions)    │  Output: CHANGELOG, README, Issue closure,
└──────────┬────────────────┘          Projects v2 board → Done
           │ dispatches
           ▼
┌───────────────────────────┐
│    documentation-agent    │  Input:  merged PR number
│  (sonnet, maxTurns=30)    │  Output: CHANGELOG entry, README patch,
└───────────────────────────┘          closed Issues, board advanced
```

Per-phase input/output summary:

| Phase | Input | Output |
|-------|-------|--------|
| loop | .claude/config.json github_project block; GitHub Projects v2 board | Dispatched PO-agent sessions; .claude/state/loop-status.json |
| po-agent | GitHub Issue + specs folder | Patched workflow-state.json; merged PR or HALT audit entry |
| kill-switch | workflow-state.json; .claude/state/daily-budget-{date}.json | Exit 0 (continue) or HALT code appended to halt_audit[] |
| build-* dispatch | R1 envelope from each build skill | Patch to workflow-state.json sub_tasks[]; orchestrate.jsonl entry |
| resolve-pr-conflict | workflow-state.json worktree_path; PR branch | Rebased/force-pushed branch or HALT-008 + needs-human-review label |
| documentation-agent | Merged PR diff + commit history + `makato:ac-verdicts` PR block | CHANGELOG entry; README patch; verified AC checkboxes marked `[x]`; closed Issues; board advanced to Done |

### Live progress comment on the issue

The PO-agent's machine audit trail (`orchestrate.jsonl` / `build.jsonl`) lives
under gitignored `specs/`, so anyone watching the issue on GitHub sees nothing
about the autonomous run. To close that gap, the autonomous loop structurally
initializes or updates a **single, continuously-edited GitHub issue comment**
before starting the OMP harness. The PO-agent then mirrors the START and DONE of
every skill it dispatches into that comment. Entries use plain English so a
non-expert can follow along; each begins with a timestamp, and names the skill,
input, sub-agent, goal, result, or short summary as applicable.

- **One entry point:** `shared/progress-comment.sh` (`start` / `done` / `note`).
  It creates the comment on first call, appends on later calls, persists only
  `.progress_comment_id` in workflow-state via `workflow-state.sh`, preserving
  the single-writer state contract for both the loop guard and PO-agent, and
  rolls over to a fresh comment near GitHub's 65 536-char limit.
- **Best-effort, never fatal:** any `gh`/state failure logs a WARN, emits a
  `step:"progress-comment"` JSONL row, and exits 0. It never triggers a HALT and
  never blocks a dispatch.
- **Opt-out:** set `MAKATO_PROGRESS_COMMENT_DISABLE=1` to make every call a
  silent no-op (local dry-runs).

See `agents/po-agent.md` § *Progress comment* for the per-skill agent/goal map.

## Skills

| Skill | Description | Input | Output | Version |
|-------|-------------|-------|--------|---------|
| [workflow-state](skills/workflow-state/SKILL.md) | Read and write PO-agent resumable session state at specs/\<key\>-\<slug\>/workflow-state-\<issue\>.json (per-issue layout, #173). Provides eight subcommands (init / read / write / patch / append-lesson / append-halt / recall-lessons / summarise-lessons) via shared/workflow-state.sh, backed by a JSON Schema draft-07 contract. `recall-lessons` aggregates lessons from two sources: `specs/*/workflow-state-*.json` and the committed memory store at `.makato/memory/*.jsonl`; supports optional `--bundles` / `--labels` filters and sorts by scope asc, occurrences DESC, recency DESC (#470). (autonomous) | Subcommand name, spec key (or repo for recall-lessons), issue number for mutating subcommands, and subcommand-specific args (branch, JSON payload, jq path, lesson fields). State file must exist for all subcommands except init. | Mutating subcommands atomically overwrite specs/\<key\>-\<slug\>/workflow-state-\<issue\>.json; read/recall-lessons print JSON to stdout; summarise-lessons writes specs/\<key\>-\<slug\>/lessons-YYYYMMDD-issue-\<issue\>.md and prints its path. Legacy workflow-state.json files are migrated in place on first read. | 1.6.0 |
| [kill-switch](skills/kill-switch/SKILL.md) | Operator and budget kill-switches for the autonomous PO-agent. Composes four checks at every outer-loop boundary: HALT-file presence, GitHub claude-halt label, per-task token budget, and daily token-budget ceiling. Also coordinates HALT-007B proactive context handoff via scripts/context-handoff.sh. (autonomous) | Subcommand (poll / handoff / record-budget / reset-daily-budget) and spec key; for record-budget also a delta-tokens integer. Reads workflow-state.json and .claude/state/daily-budget-{date}.json. | poll exits 0 (continue) or non-zero with HALT code appended to halt_audit[] and needs-human-review label applied; record-budget increments budget_consumed_tokens and daily ledger; handoff delegates to context-handoff.sh. | 1.0.0 |
| [loop](skills/loop/SKILL.md) | Autonomous polling driver for the PO-agent. Polls a GitHub Projects v2 board for items at Status=Ready (or a comma-separated --status list for multi-status dispatch, #688) and dispatches the PO-agent serially. Board Status=Ready is the sole dispatch signal — the pre-poll status:ready-for-dev label→board promotion pass has been removed (#688). KEY derivation falls back to \<issue\>-\<title-slug\> when the body carries no to-issues provenance (#232). Single-threaded: next item is only picked up after current workflow-state.json reaches current_phase: done or a HALT fires. (autonomous) | .claude/config.json with github_project block populated; optional --status \<NAME\> (comma-separated for multi-status), --interval \<S\>, --dry-run, --once flags. Reads board via gh project item-list and specs/\*/workflow-state.json for in-flight detection. | Serially dispatches po-agent per untracked Ready issue; writes .claude/state/loop-status.json as operator-facing audit after each cycle. | 1.6.0 |
| [session-status](skills/session-status/SKILL.md) | Read-only SessionStart hook reference. Documents hooks/session-status.sh, which scans specs/\*/workflow-state.json and prints a one-line banner per active workflow at session open — phase, budget %, HALT status, stale marker. (autonomous) | No direct invocation — fires automatically via SessionStart hook wired in .claude/settings.json. Reads specs/\*/workflow-state.json and ~/.claude/HALT. | Prints per-workflow banner to stdout at session start; no file mutations. | 1.0.0 |
| [resolve-pr-conflict](skills/resolve-pr-conflict/SKILL.md) | Detect and resolve a merge conflict on an open PR branch inside the PO-agent worktree — rebase-first, then a partitioned merge fallback (union merge for append-only files like CHANGELOG/AUTHORS/\*.jsonl via scripts/resolve-append-only-conflict.sh, -X ours for the rest), HALT-008 when irreconcilable. Invoked by the PO-agent after a conflict signal or CI rebase-check failure. Returns R1 envelope. (autonomous) | Work item key (spec folder prefix) and optionally --autonomous flag. Reads worktree_path from workflow-state.json; requires gh CLI authenticated and git fetch access. | R1 envelope (success or failure); on success the feature branch is rebased/merged and force-pushed; on HALT the worktree is retained, needs-human-review label applied, lesson appended to workflow-state. | 1.2.0 |
| [promote-ready](skills/promote-ready/SKILL.md) | Dependency-aware Ready promotion (#268). Reads the cross-issue dependency graph from specs/\<slug\>/created-issues.json (issues[].blocked_by[]; fallback stories.json dependencies.blockedBy via sequence→githubIssue), reads live board Status via gh project item-list, computes right-now-unblocked issues (all blocked_by predecessors Done), arranges topological waves, and after interactive approval promotes them to Status=Ready — idempotent, forward-only. Never recommends two issues sharing one specs/ folder at once (plan.md collision, #173). Closes the "FIFO only in v1" gap left by loop (#33). Operator tool — not wired into loop's per-tick path. | Optional SLUG (exact folder / KEY-slug / bare slug); optional --dry-run, --yes. Reads .claude/config.json github_project block, specs/\*/created-issues.json (fallback stories.json), and the board via gh project item-list. | Prints a recommendation (waves / promote-now / collision-deferred / still-blocked / already-progressing); on approval sets selected issues to Status=Ready via gh project item-edit. --dry-run / plan mutates nothing. | 1.0.0 |

## Agents

| Agent | Model | Permission | Purpose | Dispatched by |
|-------|-------|------------|---------|---------------|
| [po-agent](agents/po-agent.md) | claude-sonnet | bypassPermissions | Outer-loop driver — reads a GitHub Issue, resolves the spec folder (Step 1a auto-materializes a missing/stub plan.md via the light-planner agent for plan-tier:light issues before halting, #200), builds sub-task list, dispatches build-implement-tdd / build-implement-goal per task, polls CI and review decisions for fix loops, patches workflow-state, manages git worktree lifecycle, captures structured lessons, routes merge-conflict pushes through resolve-pr-conflict. Sole writer of workflow-state.json. Terminates on merged PR or documented HALT code. | loop skill (scripts/loop.sh) |
| [context-summariser](agents/context-summariser.md) | claude-haiku | read-only (bypassPermissions with Write/Edit/Bash/NotebookEdit/Task disallowed) | Produces a <=500-token session summary for HALT-007B context-ceiling handoff. Input is workflow-state.json plus the current task description only — never source files. Output is the session_summary string injected into the fresh Claude session. | scripts/context-handoff.sh (via po-agent) |
| [task-file-scout](agents/task-file-scout.md) | claude-haiku | read-only (bypassPermissions with Write/Edit/Bash/NotebookEdit disallowed) | Per-task pre-read agent — given a sub-task's predicted changed files and bundle-resolved rule paths from inject-context, reads up to 8 files and returns a ~500-token structured summary (key_patterns, naming_conventions, test_file_paths, existing_exports, warnings) injected into the coder's SCOUT_SUMMARY. Distinct from makato-build/knowledge-scout. | build-implement-tdd Step 6 (per coder dispatch) |
| [documentation-agent](agents/documentation-agent.md) | claude-sonnet | bypassPermissions (Edit/Write on src/, lib/, app/ blocked at frontmatter level via disallowedTools path patterns) | Post-merge documentation pass — reads merged PR diff and commit history, appends CHANGELOG entry (Keep a Changelog format), conditionally updates README on public-API change, marks verified AC checkboxes `[x]` on the linked Issue from the PR's `makato:ac-verdicts` block (Step 4a), closes parent and child Issues via gh issue close, advances Projects v2 board to Done via issue-to-project sync-lifecycle, emits docs_coverage_warning when src/ diff outpaces docs/ diff by 2x. Never writes workflow-state.json. | workflows/post-merge.yml (GitHub Actions, on pull_request.closed + merged=true) |
| [light-planner](agents/light-planner.md) | claude-sonnet | bypassPermissions | Lightweight planning-lane plan producer (#212) — given a plan-tier:light issue body + bounded target-repo context, writes a full plan.md (non-empty ## Tasks + ## Acceptance criteria) that build-refine's plan-only path consumes, or returns a thin_body R1 so seed-issue re-tiers the issue to full. Writes exactly one file (plan.md); never touches source, labels, seed-manifest.json, or the board — seed-issue owns those and gates promotion on scripts/validate-plan-body.sh. Runs locally under the operator's Claude at seed time. | seed-issue (Step 8.5); po-agent (Step 1a HALT-006 auto-materialize, #200) |

## Hooks

| Hook | Trigger | Purpose |
|------|---------|---------|
| [check-halt.sh](hooks/check-halt.sh) | PreToolUse(Bash) | Block any Bash tool call when ~/.claude/HALT (or $MAKATO_HALT_FILE) exists — universal operator kill-switch (HALT-000). Exits non-zero to block the tool call so the PO-agent observes the HALT at the next outer-loop boundary. |
| [session-status.sh](hooks/session-status.sh) | SessionStart | Scan specs/\*/workflow-state.json and print a one-line banner per active workflow (issue, phase, budget %, HALT count, updated_at, stale marker). Prints HALT ACTIVE first if ~/.claude/HALT exists. Read-only — never mutates state. |
| [clock-out.sh](hooks/clock-out.sh) | manual operator call | Human-session clock-out: appends a `lessons_learned` entry to `workflow-state.json` via `workflow-state.sh append-lesson`, patches `resume_point` so the next session has a plain-English pointer to where work left off, and prints the git commit command the operator should paste. Does NOT commit automatically — the operator stays in control. Not wired in settings.json. See [clock-out-smoke-tests.sh](hooks/clock-out-smoke-tests.sh). |
| [session-status-smoke-tests.sh](hooks/session-status-smoke-tests.sh) | Smoke test | Validates session-status.sh output shape on synthetic workflow-state.json fixtures. |

## Scripts

- **scripts/context-handoff.sh** — HALT-007B proactive context-ceiling handoff lifecycle: check budget vs context_warn_tokens, enforce handoff cap (MAKATO_MAX_HANDOFFS), checkpoint workflow-state, dispatch context-summariser, emit .claude/state/resume-{KEY}.sh, and detached self-restart. The emitted resume script invokes `claude --resume <session-UUID>` using the `last_session_id` persisted by loop.sh (#616) — NOT the spec KEY, which `--resume` rejects. Falls back to HALT-007 when restart fails, the handoff cap is exceeded, or no `last_session_id` was captured (resume impossible → human needed).
- **scripts/tests/context-handoff-smoke-tests.sh** — Smoke tests for context-handoff.sh covering the check/cap/checkpoint/emit/restart lifecycle paths.
- **scripts/loop.sh** — Implementation of the loop skill — polls GitHub Projects v2 board for Ready items (board Status=Ready is the sole dispatch signal; the pre-poll status:ready-for-dev → board Ready promotion pass is removed as of #688, via `_gh_project_item_list`, a bounded exponential-backoff retry wrapper that distinguishes a failed poll from an empty queue so a rate-limit/429 never masquerades as no-work — #289), applies in-flight filter against specs/\*/workflow-state.json, dispatches PO-agent serially via `claude --dangerously-skip-permissions -p` (KEY derived from to-issues provenance or, failing that, \<issue\>-\<title-slug\> per #232), writes .claude/state/loop-status.json (including a `poll_healthy`/`last_poll_error` transient-error state on poll failure). After every dispatch it persists the Claude session UUID as `last_session_id` in workflow-state so the stall-recovery and HALT-007B handoff paths can `claude --resume <UUID>` correctly (#616). Two per-tick orphan-recovery passes run before polling: `_reconcile_orphaned_in_progress` (#368) recovers board cards In progress with NO local workflow-state, and `_reconcile_orphaned_stale` (#616) recovers a run whose workflow-state IS present (`current_phase != done`) but whose owning process is dead (`.loop-owner.pid` fails `kill -0`) and whose `updated_at` is older than `MAKATO_ORPHAN_STALE_SECS` (default 3600s; `MAKATO_ORPHAN_DETECT_DISABLE=1` to disable) — both route to Blocked + needs-human-review. The pre-poll reap pass (#265) removes merged worktrees and, via `_reap_orphan_specs`, prunes orphaned untracked `specs/<slug>/` folders for done/closed issues (`MAKATO_LOOP_REAP_SPECS=0` to disable; audit in `last_reap_specs_count`/`reap_specs_pruned`). Exposes run/poll/next/status/dispatch/auto-seed/check-halt/remove-worktrees subcommands, plus `-h`/`--help` for a subcommand + flag overview. Helper and `cmd_*` functions live in `scripts/functions.sh` (sourced at startup); tunable parameters and their environment-variable overrides live in `config/config.yml` (parsed by `config/parse-config.py`) and are documented in `config/config.md`.
- **scripts/functions.sh** — All `loop.sh` helper and `cmd_*` functions except `cmd_run`. Sourced by `loop.sh`; not run standalone. Path overridable via `MAKATO_LOOP_FUNCTIONS`.
- **config/config.yml** + **config/parse-config.py** — Declarative source of truth for every `loop.sh` tunable; the parser emits `NAME="${ENV:-default}"` bash assignments (PyYAML when present, stdlib fallback otherwise) so each parameter keeps its original env override. Paths overridable via `MAKATO_LOOP_CONFIG_YML` / `MAKATO_LOOP_CONFIG_PARSER`. Full docs in **config/config.md**.
- **scripts/tests/test_parse_config.py** — pytest coverage for `parse-config.py`: known-default emission, empty-default and fixed-value handling, export-only-where-declared, stdlib/PyYAML parity, and env-override round-trip through bash. Run in CI via the `scripts/tests/` pytest step.
- **scripts/tests/loop-smoke-tests.sh** — Smoke tests for loop.sh — offline scenarios (T1–T42) covering HALT-file detection, dry-run dispatch, in-flight filtering, board Status filtering, non-Issue exclusion, KEY derivation incl. the #232 title fallback (T27), the #231 label→board promotion pass with its exclusion guard (T28), the #259 synchronous board-claim CAS (T30), the #265 merged-worktree reaper (T31–T38), the #289 board-poll rate-limit resilience (T39–T42: retry-then-succeed, exhaustion returns non-zero, cmd_poll rc 75, transient-error state), the orphaned-specs pruning pass (T84–T90: done→prune, closed→prune, open→skip, tracked→skip, dryrun→keep, disabled→skip, promote-before-prune), the #531 stall-resume paths (T-RESUME-1..5) plus the #616 skip-on-missing-UUID (T-RESUME-616), and the #616 orphan-stale detection (T-STALE-1..4: dead+stale→reconcile, fresh→skip, alive-owner→skip, disabled→skip). Uses MAKATO_LOOP_GH_OVERRIDE / MAKATO_LOOP_ISSUE_BODY_OVERRIDE / MAKATO_LOOP_ISSUE_TITLE_OVERRIDE / MAKATO_LOOP_PROMOTE_OVERRIDE / MAKATO_LOOP_POLL_TEST_CMD / MAKATO_LOOP_REAP_SPECS_GH_OVERRIDE for offline fixture injection. Run in CI via .github/workflows/validate.yml.
- **scripts/tests/loop-progress-comment-smoke-tests.sh** — Offline fake-GitHub/fake-harness coverage for the structural pre-dispatch progress-comment guard: the integer comment id is persisted before the harness starts, and GitHub failure warns without blocking dispatch.
- **scripts/promote-ready.sh** — Implementation of the promote-ready skill (#268) — dependency-aware Ready promotion. Loads the cross-issue dependency graph from specs/\<slug\>/created-issues.json (issues[].blocked_by[]; fallback stories.json dependencies.blockedBy translated via sequence→githubIssue), reads live board Status via `GH_HOST=<host> gh project item-list`, computes right-now-unblocked issues (every blocked_by predecessor Done), arranges topological waves, applies the plan.md single-folder collision guard (#173), and — after interactive approval (or --yes) — promotes selected issues to Status=Ready via gh project item-edit (idempotent, forward-only, warn-not-fail). `plan` / `--dry-run` prints the recommendation without mutating the board. Reads .claude/config.json → github_project (no hardcoded IDs). Exposes run / plan subcommands.
- **scripts/tests/promote-ready-smoke-tests.sh** — Smoke tests for promote-ready.sh — thirteen offline scenarios (T1–T13) covering graph load, unblocked/wave computation, non-Done blocker stays blocked, the plan.md collision guard, --dry-run no-mutation (isolated via --yes), forward-only skip of Ready/In progress/In review/Done, live promote of exactly the recommended set, the stories.json sequence→githubIssue fallback (with missing-githubIssue warning), off-board promotability, an unfiled stories.json blocker keeping the dependent issue blocked, dependency-cycle termination, the empty-graph "(no issues in graph)" message, and a clean no-such-slug run on bash 3.2. Uses MAKATO_PROMOTE_GH_OVERRIDE / MAKATO_PROMOTE_EDIT_TEST_FILE for offline fixture injection — `gh` is never invoked. Run in CI via .github/workflows/validate.yml.
- **scripts/loop-halt-watch.sh** — Operator-side macOS HALT notifier. Runs **independently of `loop.sh`** (surviving a loop crash) and polls a watched repo's `.claude/state/` every 30s (`MAKATO_WATCH_INTERVAL`), firing a macOS notification (via `terminal-notifier`, falling back to `osascript`) on three latched transitions so an unattended run never fails silently: (1) **HALT-000** — `~/.claude/HALT` appears or `.last_halt_at` in `loop-status.json` advances (clean HALT exit); (2) **process death** — the PID in `loop.pid` stops responding to `kill -0` while `queue_depth > 0`; (3) **watchdog kill** — `.last_watchdog_kill` in `loop-status.json` changes. State at startup is the baseline, so pre-existing events never fire — only genuine transitions do. Each transition notifies exactly once (latched, re-armed on recovery). Opt-in and **not** started by `loop run`; deploy per-repo via `com.makato.loop-halt-watch.plist.template` (below) or run by hand with `MAKATO_WATCH_ONCE=1` for a single poll. Notifications are stubbable via `MAKATO_WATCH_NOTIFY_CMD` for offline tests.
- **scripts/tests/loop-halt-watch-smoke-tests.sh** — Smoke tests for loop-halt-watch.sh — seven offline scenarios (T1 baseline-clean no-fire, T2 HALT file appears at runtime, T3 last_halt_at advances, T4 dead PID + queued work, T5 pre-existing watchdog kill is baseline, T5b watchdog kill changes at runtime, T6 pre-existing last_halt_at is baseline). Notifications are captured via the `MAKATO_WATCH_NOTIFY_CMD` stub — no real notification fires and neither `terminal-notifier` nor `osascript` is invoked. Run in CI via .github/workflows/validate.yml.
- **scripts/com.makato.loop-halt-watch.plist.template** — launchd plist template for the HALT notifier (one agent per watched repo). Substitute `{{WATCHER_SCRIPT}}` (absolute path to loop-halt-watch.sh in the makato plugin checkout), `{{WATCH_REPO}}` (the watched repo root — usually a *different* repo that has no copy of the script), and `{{REPO_LABEL}}` (a unique per-repo suffix), copy to `~/Library/LaunchAgents/com.makato.loop-halt-watch.<repo>.plist`, then `launchctl bootstrap gui/$(id -u) <plist>`. `RunAtLoad` + `KeepAlive` (starts at login, restarts on crash, survives reboot); `PATH` includes `/opt/homebrew/bin` so `terminal-notifier` resolves under launchd. Manage with `launchctl bootout` / `kickstart -k gui/$(id -u)/<label>`. Do **not** also launch the watcher by hand (`nohup`) while launchd owns it — that spawns a duplicate. Full install steps are in the template header comment. Opt-in; install only when you want on-screen HALT notifications.

## GitHub Actions Workflows

| Workflow | Purpose |
|----------|---------|
| [workflows/post-merge.yml](workflows/post-merge.yml) | Triggered on pull_request.closed where merged=true targeting the default branch. Dispatches documentation-agent with the merged PR number to produce post-merge artefacts: CHANGELOG entry, README update, Issue closure, Projects v2 board advance to Done, docs-coverage retrospective. Consumers copy this file to .github/workflows/. |
| [workflows/loop-cron.yml](../../.github/workflows/loop-cron.yml) | Fires `loop.sh run --once` on the `[self-hosted, makato]` runner every 10 minutes — "loop survives machine-off" fallback when the operator's local terminal is not running. Requires `ANTHROPIC_API_KEY` and `GH_TOKEN`/`MAKATO_TOKEN` secrets. Without `ANTHROPIC_API_KEY` the cron ticks fail silently (auth error in `claude` subprocess) but **do not affect the local `loop run`** path. Disable temporarily with `gh workflow disable loop-cron.yml`; re-enable with `gh workflow enable loop-cron.yml`. Cross-machine double-dispatch is prevented by the board CAS claim (Status → In Progress). Smoke tests: `scripts/tests/loop-cron-smoke-tests.sh` (T-CRON-1 to T-CRON-5). |

## Shared Resources

- **shared/workflow-state.sh** — Canonical shell helper implementing all eight workflow-state subcommands (init/read/write/patch/append-lesson/append-halt/recall-lessons/summarise-lessons) with jq mutations, python3+jsonschema validation, and atomic file writes. `recall-lessons` extended in #470 with optional `--bundles`/`--labels` filters and reads from `.makato/memory/*.jsonl` committed store.
- **shared/progress-comment.sh** — Best-effort helper (start/done/note) that maintains a single live, human-readable GitHub issue comment narrating each dispatched skill (plain English, timestamped). Persists only `.progress_comment_id` via workflow-state.sh; any `gh`/state failure is a WARN, never a HALT. Opt-out via `MAKATO_PROGRESS_COMMENT_DISABLE=1`.
- **shared/progress-comment-smoke-tests.sh** — Offline smoke tests (gh stubbed via `MAKATO_PC_GH_STUB`) covering comment creation, in-place edit, START/DONE/note formatting, best-effort gh-failure, refetch fallback, size rollover, opt-out, and unknown-subcommand handling.
- **shared/worktree.sh** — Git worktree lifecycle helper for the PO-agent — implements create/resume/cleanup-on-success/retain-on-HALT subcommands. Patches workflow-state.json:.worktree_path and sets worktree_retained/worktree_retain_reason fields.
- **shared/worktree-smoke-tests.sh** — Smoke tests for worktree.sh covering create, resume, path resolution, cleanup, and retain lifecycle paths.
- **skills/workflow-state/references/workflow-state.schema.json** — JSON Schema draft-07 contract for workflow-state.json — additionalProperties: false, defines all top-level fields including worktree lifecycle fields, sub_tasks[], halt_audit[], lessons_learned[], and budget/handoff counters.
- **skills/workflow-state/references/smoke-tests.sh** — Smoke tests for workflow-state.sh covering all eight subcommands, duplicate-init refusal, invalid-write halts, lessons schema validation, and recall/summarise operations.
- **skills/kill-switch/references/daily-budget.schema.json** — JSON Schema for the per-day token ledger at .claude/state/daily-budget-{YYYY-MM-DD}.json — tracks consumed_tokens, runs[], ceiling_tokens, and updated_at.

## Integration Tests

| Test | What it covers |
|------|---------------|
| [tests/test_change_memory_recall_integration.sh](tests/test_change_memory_recall_integration.sh) | End-to-end write → promote → recall pipeline for the change-memory contract: write-lessons.sh appends a record, promote-lessons.sh lifts scope:generalizable records into the correct tier store (semantic vs. procedural), and workflow-state.sh recall-lessons surfaces the promoted record. Also asserts scope:local records are not promoted and that the change-lane key shape (`<slug>-<N>`) is preserved through the pipeline. Cross-plugin seam between makato-build (write-lessons.sh) and makato-orchestrate (promote-lessons.sh, workflow-state.sh). Contract documented in [docs/contracts/change-memory-recall-contract.md](../../../../docs/contracts/change-memory-recall-contract.md). |

## Notable Governance Files

| File | Purpose |
|------|---------|
| [halt-conditions.md](halt-conditions.md) | Authoritative HALT code table (HALT-000 through HALT-013, plus HALT-007B and HALT-STRUCTURAL) — trigger, action, recovery, and whether needs-human-review label is applied for each code. |
| [never-patterns.md](never-patterns.md) | Nine universal NEVER rules (e.g. never bypass pre-commit, never force-push default branch, never write target-repo source files, never run more than MAX_OUTER_ITERATIONS) that every skill and agent in this plugin must honour in autonomous mode, each with an associated HALT code. |
| [AGENTS.md](AGENTS.md) | Contributor routing guide — defines goal/how/why, boundary, what belongs/does not belong, design principles, security model, agent table, skill authoring conventions, file structure, autonomous invocation contract, versioning, and PR checklist. |
| [.claude-plugin/plugin.json](.claude-plugin/plugin.json) | Plugin metadata file — name, description, author. No version field (repo versioned via release-please + git tags). |

## Plugin Connections

| Direction | Plugin | What flows |
|-----------|--------|-----------|
| Consumes from | makato-plan | specs/\<key\>/stories.json, created-issues.json, and plan.md — must exist before PO-agent dispatch. Does not invoke makato-plan skills; planning must complete before orchestration begins. |
| Dispatches to | makato-build | build-refine -> build-implement-tdd (or build-implement-goal) -> build-review --round (PO-owned review loop, ADR-0014) -> build-verify -> build-push-to-git -> build-create-pr -> build-address-pr-comments, all with --autonomous. Uses inject-context (via scout) and build-log.sh shared helper for orchestrate.jsonl entries. |
| Complements | makato-plan | Syncs GitHub Projects v2 board lifecycle transitions (In Progress -> In review -> Done) via issue-to-project sync-lifecycle when the PO-agent's lifecycle milestones fire. On HALT, PO-agent applies needs-human-review label; issue-to-project keeps the board in sync. |

## Prerequisites / MCP Servers

No MCP servers required — the plugin operates via gh CLI and the Claude Code sub-agent dispatch mechanism.

External prerequisites:

- gh CLI authenticated with project OAuth scope against the target repo
- .claude/config.json with github_project block (owner, number, host) populated via makato-plan:issue-to-project --init
- GitHub Projects v2 board with a Status single-select field containing a Ready option
- specs/\<key\>-\<slug\>/ folder with plan.md or decompose artifacts and machine-readable acceptance criteria
- bash, jq, python3 + jsonschema available on the execution host
- claude binary available as $MAKATO_CLAUDE_BIN (default: claude)
- Consumer repo .claude/settings.json wired with check-halt.sh (PreToolUse/Bash hook — required, see kill-switch SKILL.md § Lever 1 for the exact JSON block) and session-status.sh (SessionStart) hooks

## Installation

```bash
claude --plugin-dir ./plugins/makato-orchestrate
```

## Version

Managed by release-please at repo level; per-skill versions live in SKILL.md frontmatter.
