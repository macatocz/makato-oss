# makato-orchestrate

**Goal**: Autonomous control plane — drives a GitHub Issue from ready-for-dev through to a merged PR unattended.

**How**: Hosts the PO-agent and supporting infrastructure (workflow-state, kill-switch, session-status,
loop) that coordinate `makato-plan` decomposition output and `makato-build` `--autonomous` skills into
a single outer loop with retry, HALT, and audit semantics.

**Why**: Closes the orchestration gap identified in the AgenticSystem PRD (GAP-001 → GAP-015).
`makato-build` lands tested code per story; `makato-plan` shapes stories. Without an outer driver,
every transition between them requires a human. The PO-agent is that driver.

## Status

> **Scaffold + partial.** This plugin currently contains directory structure, governance docs,
> the workflow-state foundation, and the kill-switch / context-handoff surface from GAP-004.
> The remaining skills, agents, and hooks listed below land in follow-up issues:
>
> - GAP-003 (#26) — `skills/workflow-state/` ✓ **shipped**
> - GAP-004 (#30) — `skills/kill-switch/`, `scripts/context-handoff.sh`, `hooks/check-halt.sh`, `agents/context-summariser.md`, `halt-conditions.md`, `never-patterns.md` ✓ **shipped**
> - GAP-006 (#32) — `agents/po-agent.md` (the consumer of all the above)
> - GAP-007 (and onward) — `hooks/session-status.sh`, `skills/loop/`, `skills/session-status/`
>
> Tracking issue: [GAP-001 (#23)](https://github.com/macatocz/makato/issues/23).

## Orchestrate Boundary

Issues entering this plugin are **decomposed and shaped**:

- A single GitHub Issue tagged `status:ready-for-dev`
- A corresponding `specs/<key>-<slug>/` spec folder exists with at minimum `plan.md` or the
  upstream artifacts that `makato-plan/decompose` emits
- Acceptance criteria are machine-readable (Gherkin or AC checklist)

PO-agent reads that input, builds a sub-task list, drives `makato-build` skills one task at a time,
and exits on either a merged PR or a HALT condition.

## Integration Points

### Upstream — makato-plan

- Consumes `specs/<key>-<slug>/stories.json` and `specs/<key>-<slug>/plan.md`
- Reads `created-issues.json` for the GitHub Issue ↔ story mapping (canonical `Closes #<n>` source)
- Does **not** invoke `makato-plan` skills — planning must complete before PO-agent dispatch

### Downstream — makato-build

- Dispatches in order: `build-refine` → `build-implement-tdd` (or `build-implement-goal`) →
  `build-verify` → `build-push-to-git` → `build-create-pr` → `build-address-pr-comments`
- Every dispatch carries `--autonomous`; sub-skills bypass approval gates per
  `plugins/makato-build/AUTONOMOUS-MODE.md`
- Parses each sub-agent's R1 envelope per `plugins/makato-build/agents/RETURN-CONTRACT.md`

### Sibling — makato-plan/issue-to-project

- PO-agent surfaces lifecycle transitions; `issue-to-project sync-lifecycle` reflects them on the
  GitHub Projects v2 board (board status: `In Progress` → `In review` → `Done`)
- On HALT, PO-agent applies the `needs-human-review` label; `issue-to-project` keeps the board in
  sync via its webhook entry point

## --autonomous Invocation Contract

`--autonomous` is propagated, not toggled per skill:

| Layer | Trigger | Default |
|-------|---------|---------|
| User | `loop --autonomous <issue-number>` | Required for unattended runs |
| `loop` skill | Builds the dispatch bundle (issue, spec path, max-iters, budget) | Implicit when invoked with `--autonomous` |
| `po-agent` | Reads bundle; passes flag to each `build-*` dispatch | Implicit when bundle is autonomous |
| `build-*` skills | Bypass approval gates per AUTONOMOUS-MODE.md | Per-gate behavior is documented in that file |

Sub-agents inherit the flag via the dispatch context bundle; they do not re-parse argv.

## Skills *(scaffold — additional skills not yet shipping)*

| Skill | Description | Tracking issue |
|-------|-------------|----------------|
| `workflow-state` | Read / patch `specs/<key>-<slug>/workflow-state.json` — PO-agent is the sole writer | **Shipped** — GAP-003 (#26). Consumed by PO-agent in GAP-006 (#32). |
| `kill-switch` | HALT-file poll, GitHub `claude-halt` label poll, per-task budget, daily token ceiling, proactive context handoff shim | **Shipped** — GAP-004 (#30). Consumed by PO-agent in GAP-006 (#32). |
| `loop` | User-facing autonomous entry point — `loop --autonomous <issue-number>` | follow-up |
| `session-status` | Restartable session resumption — restores state on session start | follow-up |

## Agents *(partial — additional agents not yet shipping)*

| Agent | Model | Permission Mode | Purpose | Tracking issue |
|-------|-------|-----------------|---------|----------------|
| `context-summariser` | haiku | read-only (Read-only) | Produces ≤ 500-token session summary for HALT-007B handoff — input is workflow-state.json + current task description only, never source files | **Shipped** — GAP-004 (#30). Dispatched by PO-agent in GAP-006 (#32). |
| `po-agent` | sonnet | bypassPermissions | Outer-loop driver — reads Issue, builds sub-task list, dispatches `coder`, patches state, terminates on PR-merged or HALT | GAP-006 (#32) |
| `scout` | haiku | read-only | (planned) Read-only context discovery — linked PRs, dependent issues, prior state | follow-up |

## Hooks *(partial — additional hooks not yet shipping)*

| Hook | Trigger | Purpose | Tracking issue |
|------|---------|---------|----------------|
| `check-halt.sh` | PreToolUse(Bash) | Block tool call when `~/.claude/HALT` exists — universal kill-switch | **Shipped** — GAP-004 (#30) |
| `session-status.sh` | SessionStart | Read `workflow-state.json` and print a one-line banner if a run is in progress | follow-up |

## Kill-switch and HALT codes

GAP-004 (#30) introduces three operator-facing kill-switches and the HALT-007B proactive
context-handoff path. See:

- `halt-conditions.md` — full table of HALT codes (HALT-000 through HALT-010 plus HALT-007B
  and HALT-STRUCTURAL), with trigger / action / recovery per code.
- `never-patterns.md` — nine universal NEVER rules every skill and agent in this plugin must
  honour.
- `scripts/context-handoff.sh` — implementation of the HALT-007B lifecycle (checkpoint →
  summarise → emit resume script → detached self-restart).
- `skills/kill-switch/SKILL.md` — operator levers (HALT file, `claude-halt` label, env-var
  budgets, handoff cap) and the four-env-var matrix.

## Logging

Every skill appends structured events to `specs/<key>-<slug>/orchestrate.jsonl` (append-only, one
JSON object per line — same shape as `makato-build`'s `build.jsonl`).

**Schema:**

```json
{"ts": "2026-06-27T11:00:00.123Z", "skill": "loop", "issue": 32, "step": "dispatch", "status": "start", "data": {"iteration": 1}}
{"ts": "2026-06-27T11:00:00.456Z", "skill": "po-agent", "issue": 32, "step": "task", "status": "ok", "data": {"task_index": 0, "r1_status": "success"}}
{"ts": "2026-06-27T11:00:00.789Z", "skill": "kill-switch", "issue": 32, "step": "halt", "status": "warn", "data": {"halt_code": "HALT-008"}, "error": "outer_iterations >= 3"}
```

**Required fields:** `ts` (ISO 8601 with milliseconds), `skill`, `issue`, `step`, `status`.

**Optional fields:** `task_index`, `data` (step-specific payload), `error` (verbatim message when
status is `error` / `warn` with a HALT).

**Status values:** `start` | `ok` | `warn` | `error`.

## Workflow

> *Diagram and per-skill input/output details land alongside each follow-up issue.*

The high-level loop, paraphrased from GAP-006 acceptance criteria:

```text
GitHub Issue (status:ready-for-dev)
        │
        ▼
┌───────────────────────────┐
│        loop               │  ← user entry: loop --autonomous <issue>
│      (autonomous)         │
└──────────┬────────────────┘
           │
           ▼
┌───────────────────────────┐
│      po-agent             │
│  (sonnet, maxTurns=100)   │
└──────────┬────────────────┘
           │
   ┌───────┴───────────────────────────────────┐
   │ outer loop                                │
   │   for each sub-task:                      │
   │     - kill-switch.poll()  ───┐            │
   │     - dispatch coder         │ HALT?      │
   │     - parse R1 envelope      │   ▼        │
   │     - patch workflow-state   │ apply      │
   │     - retry on partial       │ needs-     │
   │   when all tasks success:    │ human-     │
   │     - dispatch build-create-pr│ review    │
   │     - exit                   │            │
   └──────────────────────────────┘
```

## File Structure

```text
makato-orchestrate/
├── .claude-plugin/plugin.json
├── agents/
│   ├── context-summariser.md             (GAP-004 / #30 — shipped)
│   └── (po-agent, scout — added per GAP-006 / follow-ups)
├── hooks/
│   ├── check-halt.sh                     (GAP-004 / #30 — shipped)
│   └── (session-status — added per follow-up)
├── scripts/
│   ├── context-handoff.sh                (GAP-004 / #30 — shipped)
│   └── context-handoff-smoke-tests.sh    (GAP-004 / #30 — shipped)
├── skills/
│   ├── workflow-state/                   (GAP-003 / #26 — shipped)
│   │   ├── SKILL.md
│   │   └── references/
│   │       ├── workflow-state.schema.json
│   │       └── smoke-tests.sh
│   ├── kill-switch/                      (GAP-004 / #30 — shipped)
│   │   ├── SKILL.md
│   │   └── references/
│   │       └── daily-budget.schema.json
│   └── (loop, session-status — added per follow-ups)
├── shared/
│   └── workflow-state.sh                 (GAP-003 / #26 — shipped)
├── halt-conditions.md                    (GAP-004 / #30 — shipped)
├── never-patterns.md                     (GAP-004 / #30 — shipped)
├── CLAUDE.md
├── AGENTS.md
├── CHANGELOG.md
└── README.md
```

## Versioning

- No `version` in `plugin.json` (repo versioned via release-please + git tags)
- Skill versions: bumped in `SKILL.md` frontmatter per feature PR
- Agent versions: bumped in agent frontmatter per feature PR
- CHANGELOG.md: updated with each PR

## See Also

- AgenticSystem PRD gap analysis: `.remember/agentic-gaps-issues.md` (on the
  `chore/sagibeast-alignment-sweep` branch)
- R1 return contract: `plugins/makato-build/agents/RETURN-CONTRACT.md`
- Autonomous-mode conventions: `plugins/makato-build/AUTONOMOUS-MODE.md`
- Lifecycle board sync: `plugins/makato-plan/skills/issue-to-project/SKILL.md`
