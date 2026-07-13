# makato-orchestrate

**Goal:** Drive a GitHub Issue from ready-for-dev through to a merged PR without human intervention.

**How:** The plugin hosts the PO-agent and the supporting infrastructure that bridges makato-plan
output to makato-build execution — workflow-state for resumable session state, kill-switch for
operator and budget controls, a polling loop as the unattended entry point, a session-status hook
for restart resumability, and resolve-pr-conflict for autonomous merge-conflict handling. Four
agents (po-agent, context-summariser, scout, documentation-agent) and five skills cover the full
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
- context-summariser and scout agents supporting the PO-agent loop
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
GitHub Issue (Status: Ready on Projects v2 board)
        │
        ▼
┌───────────────────────────┐
│           loop            │  Entry: loop --autonomous
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
| documentation-agent | Merged PR diff + commit history | CHANGELOG entry; README patch; closed Issues; board advanced to Done |

### Live progress comment on the issue

The PO-agent's machine audit trail (`orchestrate.jsonl` / `build.jsonl`) lives
under gitignored `specs/`, so anyone watching the issue on GitHub sees nothing
about the autonomous run. To close that gap, the PO-agent mirrors the START and
DONE of every skill it dispatches into a **single, continuously-edited GitHub
issue comment**, written in plain English so a non-expert can follow along. Every
entry begins with a timestamp; a START entry names the skill, its input, the
sub-agent used, and a one-line goal; a DONE entry gives the result and a short
summary.

- **One entry point:** `shared/progress-comment.sh` (`start` / `done` / `note`).
  It creates the comment on first call, appends on later calls, persists only
  `.progress_comment_id` in workflow-state (via `workflow-state.sh`, so the
  PO-agent stays the sole writer of state), and rolls over to a fresh comment
  near GitHub's 65 536-char limit.
- **Best-effort, never fatal:** any `gh`/state failure logs a WARN, emits a
  `step:"progress-comment"` JSONL row, and exits 0. It never triggers a HALT and
  never blocks a dispatch.
- **Opt-out:** set `MAKATO_PROGRESS_COMMENT_DISABLE=1` to make every call a
  silent no-op (local dry-runs).

See `agents/po-agent.md` § *Progress comment* for the per-skill agent/goal map.

## Skills

| Skill | Description | Input | Output | Version |
|-------|-------------|-------|--------|---------|
| [workflow-state](skills/workflow-state/SKILL.md) | Read and write PO-agent resumable session state at specs/\<key\>-\<slug\>/workflow-state-\<issue\>.json (per-issue layout, #173). Provides eight subcommands (init / read / write / patch / append-lesson / append-halt / recall-lessons / summarise-lessons) via shared/workflow-state.sh, backed by a JSON Schema draft-07 contract. (autonomous) | Subcommand name, spec key (or repo for recall-lessons), issue number for mutating subcommands, and subcommand-specific args (branch, JSON payload, jq path, lesson fields). State file must exist for all subcommands except init. | Mutating subcommands atomically overwrite specs/\<key\>-\<slug\>/workflow-state-\<issue\>.json; read/recall-lessons print JSON to stdout; summarise-lessons writes specs/\<key\>-\<slug\>/lessons-YYYYMMDD-issue-\<issue\>.md and prints its path. Legacy workflow-state.json files are migrated in place on first read. | 1.5.0 |
| [kill-switch](skills/kill-switch/SKILL.md) | Operator and budget kill-switches for the autonomous PO-agent. Composes four checks at every outer-loop boundary: HALT-file presence, GitHub claude-halt label, per-task token budget, and daily token-budget ceiling. Also coordinates HALT-007B proactive context handoff via scripts/context-handoff.sh. (autonomous) | Subcommand (poll / handoff / record-budget / reset-daily-budget) and spec key; for record-budget also a delta-tokens integer. Reads workflow-state.json and .claude/state/daily-budget-{date}.json. | poll exits 0 (continue) or non-zero with HALT code appended to halt_audit[] and needs-human-review label applied; record-budget increments budget_consumed_tokens and daily ledger; handoff delegates to context-handoff.sh. | 1.0.0 |
| [loop](skills/loop/SKILL.md) | Autonomous polling driver for the PO-agent. Polls a GitHub Projects v2 board for items at Status=Ready and dispatches the PO-agent serially. Before each poll it runs a pre-poll label→board promotion pass (#231): open status:ready-for-dev issues off-Ready and not carrying an exclusion label (triage/experimental/status:blocked/autonomous:halt) are promoted to Status=Ready, so hand-filed / auto-filed issues enter the queue without a manual seed-issue run. KEY derivation falls back to \<issue\>-\<title-slug\> when the body carries no to-issues provenance (#232). Single-threaded: next item is only picked up after current workflow-state.json reaches current_phase: done or a HALT fires. (autonomous) | .claude/config.json with github_project block populated; optional --status \<NAME\>, --interval \<S\>, --dry-run, --once flags. Reads board via gh project item-list and specs/\*/workflow-state.json for in-flight detection. | Serially dispatches po-agent per untracked Ready issue; writes .claude/state/loop-status.json as operator-facing audit after each cycle. | 1.5.0 |
| [session-status](skills/session-status/SKILL.md) | Read-only SessionStart hook reference. Documents hooks/session-status.sh, which scans specs/\*/workflow-state.json and prints a one-line banner per active workflow at session open — phase, budget %, HALT status, stale marker. (autonomous) | No direct invocation — fires automatically via SessionStart hook wired in .claude/settings.json. Reads specs/\*/workflow-state.json and ~/.claude/HALT. | Prints per-workflow banner to stdout at session start; no file mutations. | 1.0.0 |
| [resolve-pr-conflict](skills/resolve-pr-conflict/SKILL.md) | Detect and resolve a merge conflict on an open PR branch inside the PO-agent worktree — rebase-first, merge -X ours fallback, HALT-008 when irreconcilable. Invoked by the PO-agent after a conflict signal or CI rebase-check failure. Returns R1 envelope. (autonomous) | Work item key (spec folder prefix) and optionally --autonomous flag. Reads worktree_path from workflow-state.json; requires gh CLI authenticated and git fetch access. | R1 envelope (success or failure); on success the feature branch is rebased/merged and force-pushed; on HALT the worktree is retained, needs-human-review label applied, lesson appended to workflow-state. | 1.1.0 |

## Agents

| Agent | Model | Permission | Purpose | Dispatched by |
|-------|-------|------------|---------|---------------|
| [po-agent](agents/po-agent.md) | claude-sonnet | bypassPermissions | Outer-loop driver — reads a GitHub Issue, resolves the spec folder (Step 1a auto-materializes a missing/stub plan.md via the light-planner agent for plan-tier:light issues before halting, #200), builds sub-task list, dispatches build-implement-tdd / build-implement-goal per task, polls CI and review decisions for fix loops, patches workflow-state, manages git worktree lifecycle, captures structured lessons, routes merge-conflict pushes through resolve-pr-conflict. Sole writer of workflow-state.json. Terminates on merged PR or documented HALT code. | loop skill (scripts/loop.sh) |
| [context-summariser](agents/context-summariser.md) | claude-haiku | read-only (bypassPermissions with Write/Edit/Bash/NotebookEdit/Task disallowed) | Produces a <=500-token session summary for HALT-007B context-ceiling handoff. Input is workflow-state.json plus the current task description only — never source files. Output is the session_summary string injected into the fresh Claude session. | scripts/context-handoff.sh (via po-agent) |
| [scout](agents/scout.md) | claude-haiku | read-only (bypassPermissions with Write/Edit/Bash/NotebookEdit disallowed) | Per-task pre-read agent — given a sub-task's predicted changed files and bundle-resolved rule paths from inject-context, reads up to 8 files and returns a ~500-token structured summary (key_patterns, naming_conventions, test_file_paths, existing_exports, warnings) injected into the coder's SCOUT_SUMMARY. Distinct from makato-build/knowledge-scout. | build-implement-tdd Step 6 (per coder dispatch) |
| [documentation-agent](agents/documentation-agent.md) | claude-sonnet | bypassPermissions (Edit/Write on src/, lib/, app/ blocked at frontmatter level via disallowedTools path patterns) | Post-merge documentation pass — reads merged PR diff and commit history, appends CHANGELOG entry (Keep a Changelog format), conditionally updates README on public-API change, closes parent and child Issues via gh issue close, advances Projects v2 board to Done via issue-to-project sync-lifecycle, emits docs_coverage_warning when src/ diff outpaces docs/ diff by 2x. Never writes workflow-state.json. | workflows/post-merge.yml (GitHub Actions, on pull_request.closed + merged=true) |
| [light-planner](agents/light-planner.md) | claude-sonnet | bypassPermissions | Lightweight planning-lane plan producer (#212) — given a plan-tier:light issue body + bounded target-repo context, writes a full plan.md (non-empty ## Tasks + ## Acceptance criteria) that build-refine's plan-only path consumes, or returns a thin_body R1 so seed-issue re-tiers the issue to full. Writes exactly one file (plan.md); never touches source, labels, seed-manifest.json, or the board — seed-issue owns those and gates promotion on scripts/validate-plan-body.sh. Runs locally under the operator's Claude at seed time. | seed-issue (Step 8.5); po-agent (Step 1a HALT-006 auto-materialize, #200) |

## Hooks

| Hook | Trigger | Purpose |
|------|---------|---------|
| [check-halt.sh](hooks/check-halt.sh) | PreToolUse(Bash) | Block any Bash tool call when ~/.claude/HALT (or $MAKATO_HALT_FILE) exists — universal operator kill-switch (HALT-000). Exits non-zero to block the tool call so the PO-agent observes the HALT at the next outer-loop boundary. |
| [session-status.sh](hooks/session-status.sh) | SessionStart | Scan specs/\*/workflow-state.json and print a one-line banner per active workflow (issue, phase, budget %, HALT count, updated_at, stale marker). Prints HALT ACTIVE first if ~/.claude/HALT exists. Read-only — never mutates state. |
| [session-status-smoke-tests.sh](hooks/session-status-smoke-tests.sh) | Smoke test | Validates session-status.sh output shape on synthetic workflow-state.json fixtures. |

## Scripts

- **scripts/context-handoff.sh** — HALT-007B proactive context-ceiling handoff lifecycle: check budget vs context_warn_tokens, enforce handoff cap (MAKATO_MAX_HANDOFFS), checkpoint workflow-state, dispatch context-summariser, emit .claude/state/resume-{KEY}.sh, and detached self-restart. Falls back to HALT-007 when restart fails or cap is exceeded.
- **scripts/context-handoff-smoke-tests.sh** — Smoke tests for context-handoff.sh covering the check/cap/checkpoint/emit/restart lifecycle paths.
- **scripts/loop.sh** — Implementation of the loop skill — runs a pre-poll status:ready-for-dev → board Ready promotion pass (#231), polls GitHub Projects v2 board for Ready items, applies in-flight filter against specs/\*/workflow-state.json, dispatches PO-agent serially via `claude --dangerously-skip-permissions -p` (KEY derived from to-issues provenance or, failing that, \<issue\>-\<title-slug\> per #232), writes .claude/state/loop-status.json. Exposes run/poll/next/status/dispatch/promote-ready/check-halt subcommands.
- **scripts/loop-smoke-tests.sh** — Smoke tests for loop.sh — 28 offline scenarios (T1–T28) covering HALT-file detection, dry-run dispatch, in-flight filtering, board Status filtering, non-Issue exclusion, KEY derivation incl. the #232 title fallback (T27), and the #231 label→board promotion pass with its exclusion guard (T28). Uses MAKATO_LOOP_GH_OVERRIDE / MAKATO_LOOP_ISSUE_BODY_OVERRIDE / MAKATO_LOOP_ISSUE_TITLE_OVERRIDE / MAKATO_LOOP_PROMOTE_OVERRIDE for offline fixture injection. Run in CI via .github/workflows/validate.yml.

## GitHub Actions Workflows

| Workflow | Purpose |
|----------|---------|
| [workflows/post-merge.yml](workflows/post-merge.yml) | Triggered on pull_request.closed where merged=true targeting the default branch. Dispatches documentation-agent with the merged PR number to produce post-merge artefacts: CHANGELOG entry, README update, Issue closure, Projects v2 board advance to Done, docs-coverage retrospective. Consumers copy this file to .github/workflows/. |

## Shared Resources

- **shared/workflow-state.sh** — Canonical shell helper implementing all eight workflow-state subcommands (init/read/write/patch/append-lesson/append-halt/recall-lessons/summarise-lessons) with jq mutations, python3+jsonschema validation, and atomic file writes.
- **shared/progress-comment.sh** — Best-effort helper (start/done/note) that maintains a single live, human-readable GitHub issue comment narrating each dispatched skill (plain English, timestamped). Persists only `.progress_comment_id` via workflow-state.sh; any `gh`/state failure is a WARN, never a HALT. Opt-out via `MAKATO_PROGRESS_COMMENT_DISABLE=1`.
- **shared/progress-comment-smoke-tests.sh** — Offline smoke tests (gh stubbed via `MAKATO_PC_GH_STUB`) covering comment creation, in-place edit, START/DONE/note formatting, best-effort gh-failure, refetch fallback, size rollover, opt-out, and unknown-subcommand handling.
- **shared/worktree.sh** — Git worktree lifecycle helper for the PO-agent — implements create/resume/cleanup-on-success/retain-on-HALT subcommands. Patches workflow-state.json:.worktree_path and sets worktree_retained/worktree_retain_reason fields.
- **shared/worktree-smoke-tests.sh** — Smoke tests for worktree.sh covering create, resume, path resolution, cleanup, and retain lifecycle paths.
- **skills/workflow-state/references/workflow-state.schema.json** — JSON Schema draft-07 contract for workflow-state.json — additionalProperties: false, defines all top-level fields including worktree lifecycle fields, sub_tasks[], halt_audit[], lessons_learned[], and budget/handoff counters.
- **skills/workflow-state/references/smoke-tests.sh** — Smoke tests for workflow-state.sh covering all eight subcommands, duplicate-init refusal, invalid-write halts, lessons schema validation, and recall/summarise operations.
- **skills/kill-switch/references/daily-budget.schema.json** — JSON Schema for the per-day token ledger at .claude/state/daily-budget-{YYYY-MM-DD}.json — tracks consumed_tokens, runs[], ceiling_tokens, and updated_at.

## Notable Governance Files

| File | Purpose |
|------|---------|
| [halt-conditions.md](halt-conditions.md) | Authoritative HALT code table (HALT-000 through HALT-012, plus HALT-007B and HALT-STRUCTURAL) — trigger, action, recovery, and whether needs-human-review label is applied for each code. |
| [never-patterns.md](never-patterns.md) | Nine universal NEVER rules (e.g. never bypass pre-commit, never force-push default branch, never write target-repo source files, never run more than MAX_OUTER_ITERATIONS) that every skill and agent in this plugin must honour in autonomous mode, each with an associated HALT code. |
| [AGENTS.md](AGENTS.md) | Contributor routing guide — defines goal/how/why, boundary, what belongs/does not belong, design principles, security model, agent table, skill authoring conventions, file structure, autonomous invocation contract, versioning, and PR checklist. |
| [.claude-plugin/plugin.json](.claude-plugin/plugin.json) | Plugin metadata file — name, description, author. No version field (repo versioned via release-please + git tags). |

## Plugin Connections

| Direction | Plugin | What flows |
|-----------|--------|-----------|
| Consumes from | makato-plan | specs/\<key\>/stories.json, created-issues.json, and plan.md — must exist before PO-agent dispatch. Does not invoke makato-plan skills; planning must complete before orchestration begins. |
| Dispatches to | makato-build | build-refine -> build-implement-tdd (or build-implement-goal) -> build-verify -> build-push-to-git -> build-create-pr -> build-address-pr-comments, all with --autonomous. Uses inject-context (via scout) and build-log.sh shared helper for orchestrate.jsonl entries. |
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
- Consumer repo .claude/settings.json wired with check-halt.sh (PreToolUse) and session-status.sh (SessionStart) hooks

## Installation

```bash
claude --plugin-dir ./plugins/makato-orchestrate
```

## Version

Managed by release-please at repo level; per-skill versions live in SKILL.md frontmatter.
