# makato-build

**Goal**: Transforms decomposed, vertically-sliced stories into tested, reviewed, merged code.

**How**: Provides a sequential skill pipeline anchored by `start` as the entry point, then
`refine` → (optional `grill-with-docs`) → `implement-tdd` *or* `implement-goal` → `simplify` →
`review` → `verify` → `sensors` (with per-finding repair via `resolve-finding`) → `push-to-git` →
`create-pr` → `address-pr-comments`. Takes planned specs and produces production-ready pull
requests in a single session.

**Why**: Closes the loop from ideation to merged code — planned stories become shippable features
without manual orchestration overhead.

## Build Boundary

Stories entering this plugin are **planned but not refined**:

- They have clear functional descriptions and acceptance criteria (from makato-plan)
- They include architectural context and design decisions
- They do NOT yet have implementation plans, file targets, or testing approaches

The /refine step bridges that gap — producing a plan small enough to execute autonomously in one
session.

## What Belongs Here

- Skills that refine planned stories into implementation plans
- Skills that implement code via TDD or goal-driven approaches
- Skills that review, simplify, and verify implementations
- Skills that commit, push, and create pull requests from implementations
- Skills that address PR review feedback

## What Does NOT Belong Here

- Hotfixes, small defects, or ad-hoc code changes (out of scope — no dedicated plugin yet)
- Shaping work (PRDs, architecture, prototypes, decomposition — that's makato-plan)
- Plugin/skill scaffolding (that's makato-contribute)
- CI/CD pipeline configuration or deployment automation
- Project management or issue tracker state machine transitions

## Design Principles

1. **Single-session execution.** Unlike human workflows that need "resume" capabilities, AI agents
   execute a full story implementation in one session. There is no /resume skill — each story is
   implemented end-to-end in a single invocation. The /refine step produces a plan small enough to
   complete autonomously.

2. **Fail-forward with re-plan.** Quality gates have different loop behaviors: /review loops on
   itself (fix findings → re-review until clean). /verify and /simplify escalate structural
   failures back to /refine — update the plan and re-implement on clean foundations rather than
   accumulating fixes. The threshold: "Can I fix this without changing the implementation
   approach?" If yes, fix in place. If no, re-plan.

3. **Two implementation modes.** TDD (RED → GREEN → INTEGRATE → VERIFY) is the default for
   logic-heavy work where behavior can be encoded as tests upfront. Goal-driven (/implement-goal)
   is for UI-heavy work, configuration changes, or tasks where TDD adds friction without value.
   The choice is per-story, not per-plugin.

4. **Structured logging at every step.** Every skill appends JSONL entries to
   `spec/<story-key>/build.jsonl` — one event per line, append-only. This makes every session
   replayable and debuggable after the fact. Required fields: `ts` (ISO 8601), `skill`, `story`,
   `step`, `status` (`start` | `ok` | `warn` | `error`). Optional: `task`, `data`
   (step-specific payload), `error` (message when status is `error`). Skills must log at minimum:
   session start, each major step start/completion, and any error with full context.

## Workflow

Skills follow a sequential build pipeline. Each phase produces output that feeds the next.
Quality gates (/simplify, /review, /verify) can loop back to earlier phases when issues are
structural.

### Phases

0. **Start** — entry point, validate prerequisites
   - [x] `start` (interactive) — validates git state, validates spec prerequisites, captures
     implementation mode (TDD vs goal), initializes `build.jsonl`, and kicks off `refine`
   - Input: work item key (GitHub Issue number or spec slug)
   - Output: validated session state — clean git, spec folder exists with required artifacts,
     implementation mode recorded
   - Note: Required entry point for any full build session. Use `refine` directly only when
     resuming a session whose prerequisites were already validated.

1. **Refine** — bridge from planned to implementable
   - [ ] `refine` (interactive)
   - Input: GitHub Issue or stories.json + full spec folder from makato-plan
     context, the architecture doc for technical approach, decisions for constraints. Reads the
     actual code, identifies files to change, determines test strategy. Plan must be small enough
     for single-session execution.

2. **Align** — reconcile spec language with codebase language
   *(optional, recommended for complex stories)*
   - [x] `grill-with-docs` (interactive)
   - Input: Implementation plan + spec artifacts + target codebase
   - Output: enriched `spec/<key>/glossary.md` (codebase `_Code_:` annotations on conflicting
     terms, new terms appended) + ADRs for hard-to-reverse decisions
   - Note: Challenges the refinement plan against the actual domain model and code. Flags
     terminology conflicts ("your spec says 'cancellation' but the codebase calls this
     'revocation'"). Enriches the feature `glossary.md` (written by `/makato-plan:grill`) with
     `_Code_:` annotations — one file, one truth. Creates ADRs only when decisions are hard to
     reverse, surprising without context, and involve genuine trade-offs. Inspired by
     [Matt Pocock's grill-with-docs](https://github.com/mattpocock/skills/blob/main/skills/engineering/grill-with-docs/SKILL.md).

3. **Implement** — write the code (choose one mode per story)
   - [ ] `implement-tdd` (autonomous) — RED → GREEN → INTEGRATE → VERIFY cycle per task
   - [ ] `implement-goal` (autonomous) — goal-driven execution for UI/config work
   - Input: Implementation plan from /refine
   - Output: Working code with unit tests + integration tests (TDD) or working code with tests
     written after (goal)
   - Note: TDD is default for backend/logic. Goal-driven for frontend/config. Both produce tested
     code — they differ in sequencing.
   - TDD cycle per task:
     - **RED**: Write failing unit tests (isolated, dependencies mocked) AND failing integration
       tests (real dependencies, cross-component boundary)
     - **GREEN**: Implement until unit tests pass
     - **INTEGRATE**: Make integration tests pass against real dependencies
     - **VERIFY**: Full suite (unit + integration + pre-existing) passes before moving to next task

4. **Simplify** — fight complexity creep
   - [ ] `simplify` (interactive)
   - Input: Implemented code from /implement-*
   - Output: Simplified code — removed unnecessary abstractions, reduced indirection, cleaner
     interfaces
   - Note: AI-generated code tends toward over-engineering. This step explicitly counters that.
     Reviews for: premature generalization, unnecessary wrappers, dead code, complexity that
     doesn't serve acceptance criteria. *Scoped to the build pipeline (post-implement, pre-review);
     distinct from the suite-level `simplify` skill which is a general-purpose code review tool.*

5. **Review** — adversarial quality check
   - [ ] `review` (autonomous)
   - Input: Current branch diff vs. main
   - Output: Review report (CRITICAL / SUGGESTION / NITPICK findings)
   - Note: Cynical, skeptical review. 0 findings = suspicious (re-review). Auto-fixes mechanical
     issues (formatting, imports). CRITICAL findings are fixed, then /review re-runs until clean.
     The review loop is self-contained — it does not proceed to /verify until all findings are
     resolved.

6. **Verify** — quality gates
   - [ ] `verify` (autonomous)
   - Input: Current working tree
   - Output: Gate results (PASS/FAIL per gate, coverage report)
   - Note: Runs build → lint → unit tests → integration tests → coverage check. The "does it
     actually work?" gate. Unit and integration suites are run separately so failures are
     attributable. If gates fail with fixable issues → fix and re-run /verify. If gates fail with
     structural issues (unfixable without changing approach) → back to /refine to re-plan.

7. **Sensors** — pre-commit findings repair loop
   - [x] `sensors` (autonomous) — runs pre-commit sensors against staged/all/changed files,
     parses findings, dispatches `sensor-fixer` agent until clean or `MAX_LOOPS=5`
   - [x] `resolve-finding` (per-finding) — decision tree resolving one sensor finding via 4
     branches: autofix, tech-skill route, safe-automated action (redact/upgrade/suppress), or
     carry-over to draft PR
   - Input: Sensors triggered by pre-commit hook (or an autonomous fixer re-running them after
     edits)
   - Output: Clean pre-commit run, or a draft PR carrying the residual findings forward with
     audit log entries
   - Note: This is gate-0 for `push-to-git`. The loop is bounded by `MAX_LOOPS` and per-finding
     repair branches keep retries focused — a single unfixable finding doesn't block the others.

8. **Ship** — get code into review
   - [ ] `push-to-git` (autonomous) — atomic conventional commits, push to remote
   - [ ] `create-pr` (interactive) — PR with template, issue links, acceptance mapping
   - Input: Verified working tree (all gates passed)
   - Output: GitHub PR URL ready for human review
   - Note: Each commit is one logical change, individually bisectable. PR description generated
     from spec + acceptance criteria mapping.

9. **Respond** — handle review feedback
   - [ ] `address-pr-comments` (interactive) — classify and resolve PR review feedback
   - Input: PR with review comments
   - Output: Fixes committed, pushed, reply comments posted
   - Note: Handles all PR comments — human reviewers and automated bots (CI failures, security
     scanners, lint bots, Hyperspace). Classifies each (MUST-FIX / SHOULD-FIX / CONSIDER /
     OUT-OF-SCOPE). Presents classification for approval. Implements fixes grouped by file/theme.
     If feedback is structural → recommend re-plan.

### Quality Gate Decision Logic

At each quality gate (/simplify, /review, /verify, /address-pr-comments), issues are classified:

- **/simplify** — issues too large to simplify in place → back to /refine (re-plan)
- **/review** — CRITICAL findings → fix them, re-run /review (loop until clean)
- **/verify** — gates fail, fixable → fix, re-run /verify. Gates fail, structural → back to
  /refine (re-plan)
- **/address-pr-comments** — feedback is structural → back to /refine (re-plan)

The threshold for re-plan: "Can I fix this without changing the implementation approach?"
If yes, fix it. If no, re-plan.

### Logging

Every skill appends structured events to `spec/<story-key>/build.jsonl` (append-only, one JSON
object per line). This file is the audit trail for the entire build session — replayable,
diffable, and parseable for post-session debugging.

**Schema:**

```json
{"ts": "2026-05-22T10:30:00.123Z", "skill": "implement-tdd", "story": "STORY-1", "step": "red-phase", "task": 1, "status": "start", "data": {}}
{"ts": "2026-05-22T10:30:05.456Z", "skill": "implement-tdd", "story": "STORY-1", "step": "red-phase", "task": 1, "status": "ok", "data": {"unit_tests": 3, "integration_tests": 2}}
{"ts": "2026-05-22T10:31:00.789Z", "skill": "implement-tdd", "story": "STORY-1", "step": "green-phase", "task": 1, "status": "error", "data": {}, "error": "Compilation failed: cannot find symbol 'OrderStatus'"}
```

**Required fields:** `ts` (ISO 8601 with milliseconds), `skill`, `story`, `step`, `status`

**Optional fields:** `task` (task index within plan), `data` (step-specific structured payload),
`error` (verbatim error message when status is `error`)

**Status values:** `start` | `ok` | `warn` | `error`

**Minimum log events per skill run:**

- Session start (status: `start`, step: `session`)
- Each major step start and completion
- Every error with full context in `error` field
- Session end with summary (status: `ok` or `error`, step: `session`)

### Flow Diagram

```text
stories.json + spec/ artifacts (from makato-plan)
         │
         ▼
┌─────────────────┐
│     /refine     │◄───────────────────────────────────────┐
│  (interactive)  │                                        │
└────────┬────────┘                                        │
         │ implementation plan                             │
         ▼                                                 │
┌─────────────────┐                                        │
│/grill-with-docs │ (optional)                             │
│  (interactive)  │                                        │
└────────┬────────┘                                        │
         │ plan + glossary.md + ADRs                       │
         ▼                                                 │
┌─────────────────┐                                        │
│  /implement-tdd │  ← OR →  /implement-goal               │
│  (autonomous)   │          (autonomous)                  │
└────────┬────────┘                                        │
         │ working code                                    │
         ▼                                                 │
┌─────────────────┐         ┌──────────────┐               │
│    /simplify    │────────▶│ issues too   │── yes ────────┘
│  (interactive)  │         │   large?     │
└────────┬────────┘         └──────────────┘
         │ simplified              │ no
         ▼                         ▼
┌─────────────────┐◄──────── (fix findings)
│    /review      │
│  (autonomous)   │─── CRITICAL findings? ── yes ──┐
└────────┬────────┘                                │
         │ clean (no criticals)                    │
         │                              ┌──────────┘
         │                              │ fix, then
         │                              └─▶ re-run /review
         ▼
┌─────────────────┐
│    /verify      │─── gates fail? ─┐
│  (autonomous)   │                 │
└────────┬────────┘                 ├── fixable → fix, re-run /verify
         │ all gates pass           │
         │                          └── structural → back to /refine ──┐
         ▼                                                             │
┌─────────────────┐                                                    │
│  /push-to-git   │                                              (re-plan)
│  (autonomous)   │
└────────┬────────┘
         │ remote branch
         ▼
┌─────────────────┐
│   /create-pr    │
│  (interactive)  │
└────────┬────────┘
         │ PR URL
         ▼
┌─────────────────┐
│/address-pr-     │─── feedback structural? ── yes → back to /refine
│  comments       │
│  (interactive)  │─── no → fix, push, done
└─────────────────┘
```

**Important:** Every PR that adds or modifies a skill MUST update this workflow section.

## Skills

| Skill | Description | Version |
| --- | --- | --- |
| `start` | Entry point for a full build session — validates git state, validates spec prerequisites, captures implementation mode, initializes the build log, and kicks off `refine` | 1.0.0 |
| `grill-with-docs` | Align implementation plan terminology to the codebase domain model — probes codebase for canonical names, adversarial alignment interview, enriches `spec/<key>/glossary.md` with `_Code_:` annotations for codebase conflicts, ADR routing via three-criteria test | 1.1.0 |
| `refine` | Bridge a planned work item to an implementation plan — tasks, file targets, unit/integration test strategy, acceptance mapping; reads target repo AGENTS.md/CLAUDE.md as hard constraints | 1.1.0 |
| `implement-tdd` | Execute a refined plan using TDD — RED → GREEN → INTEGRATE → VERIFY per task, autonomous, tracer bullet phase for multi-layer stories, conditional coverage gate | 1.1.0 |
| `implement-goal` | Execute goal-mode tasks from a refined plan — BUILD → VERIFY RUNTIME → TEST → VERIFY, autonomous, for UI/config/migration work | 1.0.0 |
| `simplify` | Review implemented code for complexity that doesn't serve the ACs — interactive, presents findings for approval, checks against local repo patterns | 1.1.0 |
| `build-fix-types` | Per-finding type-error repair dispatched by `build-resolve-finding` for `pyright:*` / `mypy:*` findings — 6-branch decision tree (Narrow → Annotate → TypeVar/Generic → Protocol → cast → type: ignore with reason). Hard rule: branch 6 only when no rule pattern matches branches 1–5; bare `# type: ignore` forbidden | 1.0.0 |
| `review` | Adversarial quality review — auto-fixes mechanical issues, loops on CRITICAL findings until clean, zero-findings recheck requires source citations | 1.0.0 |
| `verify` | Sequential gate pipeline: build → lint → unit → integration → conditional coverage; re-runs from failed gate; structural failures escalate to /refine | 1.0.0 |
| `sensors` | Run pre-commit sensors against staged/all/changed files, parse findings, dispatch `sensor-fixer` agent until clean or MAX_LOOPS=5 | 1.0.0 |
| `resolve-finding` | Per-finding decision tree resolving a single sensor finding via 4 branches — autofix, tech-skill route, safe-automated action (redact/upgrade/suppress), or carry-over to draft PR | 1.0.0 |
| `push-to-git` | Atomic conventional commits from plan task structure; one commit per task with tests bundled; interactive push confirmation before affecting remote | 1.0.0 |
| `create-pr` | Draft PR description from spec artifacts (ACs → How to Test, tasks → What changed); optional GitHub issue linking; interactive draft review before opening | 1.0.0 |
| `address-pr-comments` | Classify and resolve all PR comments (human and bot); four-tier classification (MUST-FIX/SHOULD-FIX/CONSIDER/OUT-OF-SCOPE); structural feedback escalates to /refine | 1.0.0 |

## Planned Agents *(speculative — not yet in plugin.json)*

| Agent | Model | Purpose |
| --- | --- | --- |
| coder | TBD | Executes implementation tasks (TDD cycles, file changes) |
| tester | TBD | Writes tests, verifies coverage, runs gate checks |
| reviewer | TBD | Adversarial code review with minimum-findings enforcement |

## Planned Hooks *(speculative — not yet in plugin.json)*

| Hook | Trigger | Purpose |
| --- | --- | --- |
| pre-commit | Before commit | Run tests, lint, type-check to catch issues before they enter history |
| post-implement | After /implement-* | Auto-run /simplify to prevent complexity from accumulating |

## File Structure

```text
makato-build/
├── .claude-plugin/plugin.json
├── agents/
│   └── (coder, tester, reviewer)
├── hooks/
│   └── (pre-commit, post-implement, etc.)
├── skills/
│   └── (refine, implement-tdd, implement-goal, etc.)
├── shared/
├── CLAUDE.md
├── AGENTS.md
├── CHANGELOG.md
└── README.md
```

## Integration Points

- **Consumes from makato-plan** (via disk artifacts in `spec/<key>/`):
  - `stories.json` — vertically-sliced stories with acceptance criteria
  - `prd.md` — functional requirements, goals, scope, success metrics
  - `design.md` — architecture, component design, technical decisions
  - `decisions.md` — trade-offs and rejected alternatives
  - `prototype.html` — (if exists) UI reference for frontend stories
- **Integrates with**: GitHub CLI (PRs), Git
- **Produces**: enriched `spec/<story-key>/glossary.md` (codebase `_Code_:` annotations via
  `grill-with-docs`), ADRs (hard-to-reverse decisions),
  `spec/<story-key>/build.jsonl` (structured build audit log)
- **Does NOT depend on**: makato-contribute (independent plugin, no runtime coupling)
- **Does NOT invoke**: makato-plan skills at runtime (consumes artifacts only, no cross-plugin
  calls)

## Installation

### For makato-suite contributors (local development)

```bash
claude --plugin-dir ./plugins/makato-build
```

### For external users (install into your project)

```bash
claude plugin add makato-build --source https://github.com/zstary/makato/tree/main/plugins/makato-build
```
