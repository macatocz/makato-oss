<!-- markdownlint-disable MD013 MD032 MD040 -->
# makato-orchestrate — Contributor Guide

## Goal

Autonomous control plane that drives a GitHub Issue from ready-for-dev through to a merged PR unattended.

**How:** Hosts the PO-agent and supporting infrastructure (workflow-state, kill-switch, session-status, loop, resolve-pr-conflict) that coordinate `makato-plan` decomposition output and `makato-build` `--autonomous` skills into a single outer loop with retry, HALT, and audit semantics. **Current status:** all four agents (po-agent, context-summariser, scout, documentation-agent) and all five skills (workflow-state, kill-switch, loop, session-status, resolve-pr-conflict) are shipped. Open GAPs tracked in README.md cover follow-on enhancements, not core functionality.

**Why:** Closes the orchestration gap identified in the AgenticSystem PRD (GAP-001 → GAP-015). `makato-build` lands tested code per story; `makato-plan` shapes stories. Without an outer driver, every transition between them requires a human. The PO-agent is that driver.

## Orchestrate Boundary

Issues entering this plugin are **decomposed and shaped**:

- They are a single GitHub Issue tagged `status:ready-for-dev`
- A corresponding `specs/<key>-<slug>/` spec folder exists with at minimum `plan.md` or the upstream artifacts `decompose` would have emitted
- Acceptance criteria are machine-readable (Gherkin or AC checklist)

PO-agent reads that input, builds a sub-task list, drives `makato-build` skills one task at a time, and exits on either a merged PR or a HALT condition.

## What Belongs Here

- The PO-agent definition and its dispatch loop
- Workflow-state schema and read/write skill (the only writer of state)
- Kill-switch infrastructure: HALT file poll, GitHub label poll, token-budget ceiling
- Session-status hook for restart resumability
- The autonomous `loop` skill (entry point for unattended runs)
- HALT-code dispatch tables and `needs-human-review` labelling logic

## What Does NOT Belong Here

- Any source-code edits to the target repository — PO-agent orchestrates, never implements (`coder.md` lives in `makato-build`)
- Planning / shaping skills — PRD, architecture, decomposition (those live in `makato-plan`)
- Quality-gate skills — review, simplify, verify (those live in `makato-build`)
- Hotfixes or ad-hoc changes (those belong in `makato-change`)
- CI/CD pipeline configuration

## Decision Test

"Does this skill or agent help drive a decomposed GitHub Issue to a merged PR unattended?"

- Yes → it belongs here
- No → it belongs elsewhere

## Design Principles

1. **Single source of truth for state.** The PO-agent is the sole writer of `workflow-state.json`. Sub-agents (`coder`, `diff-reviewer`, etc.) return R1 envelopes; PO-agent patches state. Concurrent writes are a design failure, not a race to manage.
2. **HALT codes over silent failures.** Every exit path is enumerated. Sub-task retry budgets are bounded; outer-iteration counter is bounded; budget ceilings are bounded. When any ceiling fires, the issue gets `needs-human-review`, state captures the audit, and the run terminates.
3. **R1 contract end-to-end.** Every sub-agent dispatched by the PO-agent returns the R1 envelope defined in `plugins/makato-build/agents/RETURN-CONTRACT.md`. PO-agent parses `status` and `data`; never scrapes prose.
4. **Resumability via state, not memory.** A run can be killed at any time and resumed from `workflow-state.json`. The session-status hook restores context on session start. No in-memory state persists across runs.

## Security Model

The PO-agent runs with `permissionMode: bypassPermissions` and `maxTurns: 100`. This is the only agent in this plugin with elevated permissions — it is required so the outer loop can dispatch sub-agents and patch state without per-turn prompts in a fully unattended run.

**Safeguards:**

- PO-agent's source-edit boundary is enforced by a **behavioural allow-list**, not by frontmatter denial. `disallowedTools` is currently all-or-nothing in Claude's agent frontmatter — there is no path-scoped denial — so `Write` and `Edit` cannot appear there (the agent legitimately needs them to mutate `workflow-state.json`, `orchestrate.jsonl`, the Step 1a HALT-006 seed stub `plan.md` + `seed-manifest.json` under gitignored `specs/` (#200), and the resume / daily-budget state files). The allow-list lives in `po-agent.md` § *Permission Boundary*, in `never-patterns.md` NEVER 4, and in this section. A PR adding source-file writes to PO-agent must be rejected at code review (NEVER 4 enforcement clause). `disallowedTools: NotebookEdit` is set in frontmatter — that denial doubles as a regression marker (a growing `disallowedTools` list tells reviewers to re-check the allow-list).
- HALT-file poll fires at every outer-loop boundary. A user dropping a file at `~/.claude/HALT` stops the next iteration cleanly.
- GitHub kill-switch label (`autonomous:halt`) is polled on the same boundary.
- Token-budget ceiling and outer-iteration counter (HALT-008 at `outer_iterations >= 3`) cap blast radius even without external intervention.
- The session-status hook is read-only and prints a one-line resumption banner; it does not mutate state.

**Contributor rule:** Do not add `bypassPermissions` to any other agent in this plugin. Sub-agents this plugin dispatches live in `makato-build` and inherit that plugin's permission matrix.

## Skill routing opt-out

`documentation-agent` and `context-summariser` carry `skill_routing: disabled` in their
frontmatter. This exempts them from the F4 telemetry log and from skill-recommendation
injection — both are non-technical agents that must not appear in the KPI1 adoption baseline.
See root `AGENTS.md` § *Skill routing opt-out* for the full contract and parser location.

## Agents

makato-orchestrate hosts the top-level orchestrator and supporting read-only scouts:

| Agent | Model | Permission Mode | Purpose | Used By |
|-------|-------|-----------------|---------|---------|
| **po-agent** | sonnet | bypassPermissions | Plan-level outer-loop driver — reads a GitHub Issue, resolves the spec folder, dispatches `build-implement-tdd` / `build-implement-goal` once per outer iteration, decides advance-vs-replan from the skill's R1, patches workflow-state, terminates on PR-merged or HALT | `loop` |
| **context-summariser** | haiku | read-only | ≤ 500-token session summary for HALT-007B handoff. Input: `workflow-state.json` + current task description ONLY. Source files explicitly out of scope. | `scripts/context-handoff.sh` (via po-agent) |
| **scout** | haiku | read-only | Per-task pre-read agent — given a task's `CHANGED_FILES` plus the bundle rules resolved by `inject-context`, opens ≤ 8 files and returns a ~500-token structured summary (`key_patterns`, `naming_conventions`, `test_file_paths`, `existing_exports`, `warnings`) injected into the coder's `SCOUT_SUMMARY` input. Disjoint from `makato-build/knowledge-scout` (repo-wide, plan-time). | `build-implement-tdd` Step 6 (per coder dispatch) |
| **documentation-agent** | sonnet | bypassPermissions | Post-merge documentation pass — reads merged PR diff and commits, appends a CHANGELOG entry (Keep a Changelog format), conditionally updates README on public-API change, closes parent and child Issues via `gh issue close`, advances the Projects v2 board to Done via `issue-to-project sync-lifecycle`, and emits a `docs_coverage_warning` when `src/` diff lines outpace `docs/` diff lines by 2×. Frontmatter denies `Edit`/`Write` on `src/`, `lib/`, `app/`. | `workflows/post-merge.yml` (GHA) |
| **light-planner** | sonnet | bypassPermissions | Lightweight planning-lane plan producer (#212) — given a `plan-tier:light` issue body + bounded repo context, writes a full `plan.md` (non-empty `## Tasks` + `## Acceptance criteria`) that `build-refine`'s plan-only path consumes, or returns a `thin_body` R1 so seed-issue re-tiers to full. Writes exactly one file (`plan.md`); never touches source, labels, manifest, or the board — seed-issue owns those and gates promotion on `scripts/validate-plan-body.sh`. Runs locally at seed time. | `seed-issue` (Step 8.5) |

*po-agent, context-summariser, scout, and documentation-agent are shipped (GAP-006 / #32, GAP-004 / #30, GAP-013 / #29, GAP-012 / #35). light-planner ships with #212.*

## Skill Authoring

- Self-contained: all references/templates inside the skill directory
- No `../` paths outside the skill dir (except `../shared/` within this plugin)
- References loaded at point of use, not front-loaded
- Frontmatter required: `name`, `description`, `version`
- Every skill that mutates workflow-state MUST emit a JSONL audit entry per write — schema mirrors `makato-build`'s `build.jsonl` convention. See README.md for the schema.
- The orchestrate equivalent log is `specs/<key>-<slug>/orchestrate.jsonl`. Skills append via `plugins/makato-build/shared/build-log.sh` (the same helper used by makato-build) — there is no separate orchestrate-log.sh. When orchestrate-specific log fields diverge enough to justify a dedicated helper, file an issue and add `shared/orchestrate-log.sh` then.

## File Structure

```text
makato-orchestrate/
├── .claude-plugin/plugin.json
├── agents/
│   ├── context-summariser.md             (GAP-004 / #30 — shipped)
│   ├── documentation-agent.md            (GAP-012 / #35 — shipped)
│   ├── light-planner.md                  (#212 — lightweight planning lane)
│   ├── po-agent.md                       (GAP-006 / #32 — shipped)
│   └── scout.md                          (GAP-013 / #29 — shipped)
├── hooks/
│   ├── check-halt.sh                     (GAP-004 / #30 — shipped)
│   ├── session-status.sh                 (GAP-014 / #31 — shipped)
│   └── session-status-smoke-tests.sh     (GAP-014 / #31 — shipped)
├── scripts/
│   ├── context-handoff.sh                (GAP-004 / #30 — shipped)
│   ├── context-handoff-smoke-tests.sh    (GAP-004 / #30 — shipped)
│   ├── loop.sh                           (GAP-007 / #33 — shipped)
│   ├── loop-smoke-tests.sh               (GAP-007 / #33 — shipped)
│   ├── should-materialize-spec.sh        (#200 — HALT-006 auto-materialize gate)
│   ├── should-materialize-spec-smoke-tests.sh (#200 — 12 asserts)
│   ├── validate-plan-body.sh             (#212 — promotion guard)
│   └── validate-plan-body-smoke-tests.sh (#212 — 13 asserts)
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
│   ├── loop/SKILL.md                     (GAP-007 / #33 — shipped)
│   ├── resolve-pr-conflict/SKILL.md      (GAP-016 / #45 — shipped)
│   └── session-status/SKILL.md           (GAP-014 / #31 — shipped)
├── shared/
│   ├── workflow-state.sh                 (GAP-003 / #26 — shipped)
│   ├── worktree.sh                       (GAP-017 / #46 — shipped)
│   └── worktree-smoke-tests.sh           (GAP-017 / #46 — shipped)
├── workflows/
│   └── post-merge.yml                    (GAP-012 / #35 — shipped)
├── halt-conditions.md                    (GAP-004 / #30 — shipped)
├── never-patterns.md                     (GAP-004 / #30 — shipped)
├── CLAUDE.md
├── AGENTS.md
├── CHANGELOG.md
└── README.md
```

The `skills/`, `agents/`, and `hooks/` directories contain a mix of shipped files and
`.gitkeep` placeholders for stubs that land per their tracking issues.

## --autonomous Invocation Contract

Skills and agents inside this plugin treat `--autonomous` as their default execution mode. The flag is **propagated, not toggled**:

- `loop --autonomous <issue-number>` is the user-facing entry point
- `loop` dispatches `po-agent` with the autonomous bundle (issue number, spec path, max-iterations override, budget ceiling)
- `po-agent` invokes `makato-build` skills (`build-refine`, `build-implement-tdd`, `build-create-pr`, `build-address-pr-comments`, `build-push-to-git`) with `--autonomous` per the conventions in `plugins/makato-build/AUTONOMOUS-MODE.md`
- `resolve-pr-conflict` runs inside the worktree when the outer loop detects a push rejection or CI rebase-check failure (GAP-016 / #45)
- Sub-agents inherit the flag via the dispatch context bundle; they do not re-parse argv

## Versioning

- No `version` in `plugin.json` (repo versioned via release-please + git tags)
- Skill versions: bumped in `SKILL.md` frontmatter per feature PR
- Agent versions: bumped in agent frontmatter per feature PR
- `CHANGELOG.md`: updated with each PR

## PR Checklist

- [ ] Serves the plugin goal: drives a decomposed Issue to a merged PR unattended
- [ ] Skills are self-contained
- [ ] No skill writes target-repo source files (orchestration only — dispatch `makato-build` for code edits)
- [ ] PO-agent remains the sole writer of `workflow-state.json`
- [ ] Skill emits JSONL log entries to `orchestrate.jsonl` (session start, each step, session end)
- [ ] README Workflow section updated (new/changed skills/agents must document their step, input, output, HALT codes)
- [ ] CHANGELOG updated
- [ ] Conventional commit title: `type(makato-orchestrate): description`
