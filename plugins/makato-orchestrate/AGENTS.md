<!-- markdownlint-disable MD013 MD032 MD040 -->
# makato-orchestrate — Contributor Guide

## Goal

Autonomous control plane that drives a GitHub Issue from ready-for-dev through to a merged PR unattended.

**How:** Hosts the PO-agent and supporting infrastructure (workflow-state, kill-switch, session-status, loop) that coordinate `makato-plan` decomposition output and `makato-build` `--autonomous` skills into a single outer loop with retry, HALT, and audit semantics.

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

- PO-agent's `disallowedTools` explicitly bans `Edit` and `Write` against target-repo source files. State-file writes are scoped to `specs/<key>-<slug>/workflow-state.json`. Sub-agents write source files; PO-agent never does.
- HALT-file poll fires at every outer-loop boundary. A user dropping a file at `~/.claude/HALT` stops the next iteration cleanly.
- GitHub kill-switch label (`autonomous:halt`) is polled on the same boundary.
- Token-budget ceiling and outer-iteration counter (HALT-008 at `outer_iterations >= 3`) cap blast radius even without external intervention.
- The session-status hook is read-only and prints a one-line resumption banner; it does not mutate state.

**Contributor rule:** Do not add `bypassPermissions` to any other agent in this plugin. Sub-agents this plugin dispatches live in `makato-build` and inherit that plugin's permission matrix.

## Agents

makato-orchestrate hosts the top-level orchestrator and supporting read-only scouts:

| Agent | Model | Permission Mode | Purpose | Used By |
|-------|-------|-----------------|---------|---------|
| **po-agent** | sonnet | bypassPermissions | Outer loop driver — reads a GitHub Issue, builds sub-task list, dispatches `coder` per task, patches workflow-state, terminates on PR-merged or HALT | `loop` |
| **scout** | haiku | read-only | (planned) Read-only discovery agent for issue context (linked PRs, dependent issues, prior session state) | `po-agent` |

*Both rows are scaffold-only stubs until GAP-006 (#32) and follow-up issues land their definitions.*

## Skill Authoring

- Self-contained: all references/templates inside the skill directory
- No `../` paths outside the skill dir (except `../shared/` within this plugin)
- References loaded at point of use, not front-loaded
- Frontmatter required: `name`, `description`, `version`
- Every skill that mutates workflow-state MUST emit a JSONL audit entry per write — schema mirrors `makato-build`'s `build.jsonl` convention. See README.md for the schema.
- The orchestrate equivalent log is `specs/<key>-<slug>/orchestrate.jsonl`. Skills append via a shared helper (TBD: `shared/orchestrate-log.sh`).

## File Structure

```text
makato-orchestrate/
├── .claude-plugin/plugin.json
├── agents/
│   ├── po-agent.md                       (GAP-006 / #32 — stub until then)
│   └── scout.md                          (follow-up — stub)
├── hooks/
│   └── session-status.sh                 (GAP-007 follow-up — stub)
├── skills/
│   ├── workflow-state/SKILL.md           (GAP-003 / #26)
│   ├── kill-switch/SKILL.md              (GAP-004 / #30)
│   ├── loop/SKILL.md                     (autonomous entry point)
│   └── session-status/SKILL.md           (GAP-007 follow-up)
├── shared/
├── CLAUDE.md
├── AGENTS.md
├── CHANGELOG.md
└── README.md
```

The `skills/`, `agents/`, `hooks/`, and `shared/` directories exist at scaffold time but are empty (or contain only `.gitkeep`) until their owning issues land.

## --autonomous Invocation Contract

Skills and agents inside this plugin treat `--autonomous` as their default execution mode. The flag is **propagated, not toggled**:

- `loop --autonomous <issue-number>` is the user-facing entry point
- `loop` dispatches `po-agent` with the autonomous bundle (issue number, spec path, max-iterations override, budget ceiling)
- `po-agent` invokes `makato-build` skills (`build-refine`, `build-implement-tdd`, `build-create-pr`, `build-address-pr-comments`, `build-push-to-git`) with `--autonomous` per the conventions in `plugins/makato-build/AUTONOMOUS-MODE.md`
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
