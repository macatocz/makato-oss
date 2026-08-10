<!-- markdownlint-disable MD013 MD032 MD040 -->
# makato-orchestrate — Contributor Guide

## Hard Constraints

- **PO-agent is the only `bypassPermissions` agent in this plugin.** Never add elevated permissions to any other agent without documenting the reason here and in README.md.
- **PO-agent must never edit target-repo source files.** It orchestrates only — source-file writes belong to `coder` in `makato-build`. A PR adding source-file writes to PO-agent must be rejected at code review (NEVER 4).
- **PO-agent is the sole writer of `workflow-state.json`.** Sub-agents return R1 envelopes; PO-agent patches state. Concurrent writes are a design failure, not a race to manage.
- **HALT codes over silent failures.** Every exit path must be enumerated. When a ceiling fires, the issue receives `needs-human-review`, state captures the audit, and the run terminates cleanly.
- **HALT-file poll fires at every outer-loop boundary.** A `~/.claude/HALT` file stops the next iteration. Never skip this check.
- **R1 contract is mandatory for every sub-agent dispatch.** PO-agent parses `status` and `data`; it never scrapes prose.
- **`documentation-agent` and `context-summariser` carry `skill_routing: disabled`.** Do not remove these flags — they exempt these non-technical agents from F4 telemetry and skill-recommendation injection.
- **Sub-agents dispatched by this plugin inherit `makato-build`'s permission matrix.** Do not re-declare permission modes for agents defined in `makato-build`.
- **`spec/` artefact paths are gitignored except `build.jsonl`.** PO-agent must never commit files under `specs/<key>/` other than `build.jsonl`.

## Goal

Autonomous control plane that drives a GitHub Issue from ready-for-dev through to a merged PR unattended.

**How:** Hosts the PO-agent and supporting infrastructure (workflow-state, kill-switch, session-status, loop, resolve-pr-conflict) that coordinate `makato-plan` decomposition output and `makato-build` `--autonomous` skills into a single outer loop with retry, HALT, and audit semantics. **Current status:** all four agents (po-agent, context-summariser, task-file-scout, documentation-agent) and all five skills (workflow-state, kill-switch, loop, session-status, resolve-pr-conflict) are shipped. Open GAPs tracked in README.md cover follow-on enhancements, not core functionality.

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
| **task-file-scout** | haiku | read-only | Per-task pre-read agent — given a task's `CHANGED_FILES` plus the bundle rules resolved by `inject-context`, opens ≤ 8 files and returns a ~500-token structured summary (`key_patterns`, `naming_conventions`, `test_file_paths`, `existing_exports`, `warnings`) injected into the coder's `SCOUT_SUMMARY` input. Disjoint from `makato-build/knowledge-scout` (repo-wide, plan-time). | `build-implement-tdd` Step 6 (per coder dispatch) |
| **documentation-agent** | sonnet | bypassPermissions | Post-merge documentation pass — reads merged PR diff and commits, appends a CHANGELOG entry (Keep a Changelog format), conditionally updates README on public-API change, marks verified acceptance-criteria checkboxes `[x]` on the linked Issue from the PR's `makato:ac-verdicts` block (Step 4a), applies spec-delta.md ADDED/MODIFIED/REMOVED operations to `docs/specs/<capability>.md` (Step 4c — living-spec sync), closes parent and child Issues via `gh issue close`, advances the Projects v2 board to Done via `issue-to-project sync-lifecycle`, emits a `docs_coverage_warning` when `src/` diff lines outpace `docs/` diff lines by 2×, updates the domain quality scorecard `specs/master/<domain>-quality.md` via `generate_quality_doc.py` (Step 7.6, best-effort), and regenerates the repo-root `PROGRESS.md` epic roadmap from `loop-status.json` + GitHub epic issues via `generate_progress.py` (Step 7.5, best-effort). Frontmatter denies `Edit`/`Write` on `src/`, `lib/`, `app/`; issue-body checkbox edits are `gh` API mutations, forward-only (`[ ]`→`[x]` for matched verified ACs only). | `workflows/post-merge.yml` (GHA) |
| **light-planner** | sonnet | bypassPermissions | Lightweight planning-lane plan producer (#212) — given a `plan-tier:light` issue body + bounded repo context, writes a full `plan.md` (non-empty `## Tasks` + `## Acceptance criteria`) that `build-refine`'s plan-only path consumes, or returns a `thin_body` R1 so seed-issue re-tiers to full. Writes exactly one file (`plan.md`); never touches source, labels, manifest, or the board — seed-issue owns those and gates promotion on `scripts/validate-plan-body.sh`. Runs locally at seed time. | `seed-issue` (Step 8.5) |

*po-agent, context-summariser, task-file-scout, and documentation-agent are shipped (GAP-006 / #32, GAP-004 / #30, GAP-013 / #29, GAP-012 / #35). light-planner ships with #212.*

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
├── agents/       context-summariser, documentation-agent, light-planner, po-agent, task-file-scout
├── hooks/        check-halt, clock-out, session-status (+ *-smoke-tests.sh)
├── scripts/      loop, promote-ready, context-handoff, should-materialize-spec, validate-plan-body,
│                 emit-reshape-request, mark-ac-checkboxes, sync-living-specs, resolve-append-only-conflict,
│                 generate-{run,layer,progress}-report, generate-quality-doc
│   └── tests/    *-smoke-tests.sh and *-integration-tests.sh twins for all scripts/
├── skills/       workflow-state, kill-switch, loop, promote-ready, resolve-pr-conflict,
│                 session-status, quality-doc, archive-spec, lesson-prune
├── shared/       workflow-state.sh, progress-comment.sh, post-halt-comment.sh, worktree.sh (+ smoke-tests)
├── workflows/    post-merge.yml
├── halt-conditions.md, never-patterns.md
├── CLAUDE.md, AGENTS.md, CHANGELOG.md, README.md
```

Every script ships with a `*-smoke-tests.sh` twin in `scripts/tests/`. Each feature traces to a GAP-/# tracking issue —
see the per-file `## Infrastructure` contracts below and CHANGELOG for provenance. The `skills/`,
`agents/`, and `hooks/` directories mix shipped files with `.gitkeep` stubs that land per their issues.

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

## Infrastructure

Two GitHub Actions workflows drive autonomous dispatch on a **self-hosted runner labelled `makato`**
(cloud `ubuntu-latest` is unsupported — the worktree reaper needs local disk). Both require secrets
`ANTHROPIC_API_KEY` and `GH_TOKEN`/`MAKATO_TOKEN`, and the `claude` CLI on the runner.

- **`webhook-dispatch.yml`** — fires `loop.sh dispatch <N>` the moment `status:ready-for-dev` is
  applied, removing the ~300 s poll lag. Concurrency group per issue (`cancel-in-progress: false`).
- **`loop-cron.yml`** — fires `loop.sh run --once` every 10 min as a "loop survives machine-off"
  fallback. Concurrency group `loop-cron`.

The two paths are **additive** — neither blocks the other. Same-machine double-dispatch is prevented
by `_within_dispatch_guard` + the `in_flight_issues` file scan; **cross-machine** dispatch is
serialised by a board CAS claim (`MAKATO_LOOP_CLAIM_ON_DISPATCH=1`, a `gh project item-edit` Status
move to In Progress — the authoritative mutex). `_pre_dispatch_plan_guard` runs on every invocation
(no `MAKATO_LOOP_GATE_DISABLE` bypass). `loop-cron-smoke-tests.sh` asserts the five YAML invariants
(T-CRON-1..5). The workflow files are the source of truth for exact wiring.

## PR Checklist

- [ ] Serves the plugin goal: drives a decomposed Issue to a merged PR unattended
- [ ] Skills are self-contained
- [ ] No skill writes target-repo source files (orchestration only — dispatch `makato-build` for code edits)
- [ ] PO-agent remains the sole writer of `workflow-state.json`
- [ ] Skill emits JSONL log entries to `orchestrate.jsonl` (session start, each step, session end)
- [ ] README Workflow section updated (new/changed skills/agents must document their step, input, output, HALT codes)
- [ ] CHANGELOG updated
- [ ] Conventional commit title: `type(makato-orchestrate): description`
