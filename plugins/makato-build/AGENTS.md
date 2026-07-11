<!-- markdownlint-disable MD013 MD032 MD040 -->
# makato-build — Contributor Guide

## Goal

Transforms decomposed, vertically-sliced stories into tested, reviewed, merged code.

**How:** Provides a sequential skill pipeline anchored by `build-start` as the entry point, then `build-refine` → (optional `build-grill-with-docs`) → `build-implement-tdd` *or* `build-implement-goal` → `build-simplify` → `build-review` → `build-verify` → `build-sensors` (with per-finding repair via `build-resolve-finding`) → `build-push-to-git` → `build-create-pr` → `build-address-pr-comments`. Takes planned specs and produces production-ready pull requests in a single session.

**Why:** Closes the loop from ideation to merged code — planned stories become shippable features without manual orchestration overhead.

## Build Boundary

Stories entering this plugin are **planned but not refined**:
- They have clear functional descriptions and acceptance criteria (from makato-plan)
- They include architectural context and design decisions
- They do NOT yet have implementation plans, file targets, or testing approaches

**Lightweight planning lane (`spec_tier:plan-only`).** Small features may enter with a
single `plan.md` instead of the full `stories.json` + `prd.md` + `design.md` set.
`build-refine` Step 3 NEW-READs `seed-manifest.json`; when `spec_tier == "plan-only"` it
takes the same lightweight branch as the legacy `local-` prefix, bypasses the
`design.md`-missing guard, and sources acceptance criteria from `plan.md`
`## Acceptance criteria` (not a synthetic AC-1). A missing or empty section HALTs with
`MISSING_ACCEPTANCE`. `build-create-pr` mirrors this: with no `stories.json` but
`spec_tier:plan-only`, How-to-Test is sourced from `plan.md` `## Acceptance criteria`
(D11). An absent `spec_tier` field preserves legacy behavior byte-for-byte. Contract
covered by `shared/plan-only-tier-smoke-tests.sh`.

The /refine step bridges that gap — producing a plan small enough to execute autonomously in one session.

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

## Decision Test

"Does this skill help transform a planned, decomposed story into merged production code?"
- Yes → it belongs here
- No → it belongs elsewhere

## Design Principles

1. **Single-session execution.** AI agents complete a full story in one session. No /resume skill — /build-refine produces a plan small enough to execute end-to-end.
2. **Fail-forward with re-plan.** Quality gates loop differently: /build-review loops on itself (fix → re-review until clean). /build-simplify and /build-verify escalate structural failures back to /build-refine — re-plan rather than accumulate fixes on broken foundations.
3. **Two implementation modes.** TDD for logic-heavy work (RED → GREEN → INTEGRATE → VERIFY — unit tests first, then integration tests against real dependencies). Goal-driven for UI/config. Choose per story, not per plugin.
4. **Structured logging at every step.** Every skill appends JSONL to `specs/<story-key>-<slug>/build.jsonl`. Required fields: `ts`, `skill`, `story`, `step`, `status` (`start`|`ok`|`warn`|`error`). Optional: `task`, `data`, `error`. Log at minimum: session start, each major step start/end, every error.

## Security Model

The `coder` agent runs with `permissionMode: bypassPermissions`. This is the only agent in this plugin with elevated permissions — it is required so the TDD loop can execute autonomously without blocking on permission prompts for every file write or test run.

**Safeguards:**
- `coder` is dispatched only by `build-implement-tdd`, never invoked directly by the user
- File targets it writes to are relative paths validated by `build-refine` before plan approval
- All other agents (`diff-reviewer`, `gate-scout`, `knowledge-scout`, `plan-analyst`) use read-only permission modes
- `sensor-fixer` is dispatched only by the `build-sensors` skill after pre-commit returns non-zero; it reads parsed sensor findings and routes each one through `build-resolve-finding` (which in turn calls the deterministic autofix pre-pass or per-tech repair skills like `build-fix-types` / `build-fix-security`). It has Edit/Write permissions for repair but never edits files outside the changed-files set captured at dispatch time.

**Contributor rule:** Do not add `bypassPermissions` to any other agent. If a new agent requires elevated permissions, document the reason in this section and in README.md before shipping.

## Skill Authoring

- Self-contained: all references/templates inside the skill directory
- No `../` paths outside skill dir (except `../shared/` within this plugin)
- References loaded at point of use, not front-loaded
- Frontmatter required: name, description, version
  - Every skill MUST append JSONL log entries to `specs/<story-key>-<slug>/build.jsonl` via `shared/build-log.sh` — minimum: session start, each major step, session end. See the Logging section in README.md for the schema.
  - Log every agent decision that deviates from the happy path using `status: "decision"` or `status: "warn"` — classification choices (fixable vs structural), escalations, gate retries, workarounds, and baseline-gate user choices. A future session reading `build.jsonl` must be able to reconstruct what went wrong and why.
  - Call `shared/build-log.sh` as a bare relative path — Claude resolves it from the plugin root context. Do not use `../shared/build-log.sh` or an absolute path.
  - **`build.jsonl` is the only file under `specs/` that ships in-repo** (#99). The repo-root `.gitignore` excludes `specs/**/*` but re-includes `specs/**/build.jsonl` so the audit trail of every skill run is reviewable from a fresh checkout. Plan, stories, project-sync, fixtures, and every other artefact under `specs/<key>/` stay local. Treat `build.jsonl` as a committed evidence file: do not log secrets, credentials, file paths outside the repo, or any content you would not paste into a public PR.

## File Structure

```
makato-build/
├── .claude-plugin/plugin.json
├── agents/
│   ├── coder.md                # TDD inner-loop implementer (bypassPermissions)
│   ├── diff-reviewer.md        # Adversarial review of branch diff vs acceptance criteria
│   ├── gate-scout.md           # Discover build/lint/unit/integration/coverage commands
│   ├── knowledge-scout.md      # Surface project Hard Constraints + Standards via inject-context
│   ├── plan-analyst.md         # Read refined plan → task list, tracer flag, glossary constraints
│   ├── RETURN-CONTRACT.md      # R1 envelope spec shared by all build agents
│   └── sensor-fixer.md         # Outer loop that dispatches build-resolve-finding per sensor finding
├── hooks/
│   └── (hooks for pre-commit, testing, etc.)
├── skills/
│   ├── build-start/                # Entry point
│   ├── build-refine/               # Story → implementation plan
│   ├── build-grill-with-docs/      # Align plan vocabulary to codebase
│   ├── build-implement-tdd/        # TDD inner loop
│   ├── build-implement-goal/       # Goal-driven inner loop for UI/config
│   ├── build-simplify/             # Trim incidental complexity
│   ├── build-verify/               # Full quality-gate pipeline
│   ├── build-sensors/              # Pre-commit findings loop
│   ├── build-resolve-finding/      # Per-finding decision tree (autofix / skill / safe-auto / carry-over)
│   ├── build-fix-types/            # Per-finding pyright/mypy repair
│   ├── build-fix-security/         # Per-finding bandit/safety/pip-audit repair
│   ├── build-push-to-git/          # Atomic commits + push
│   ├── build-create-pr/            # PR open + description
│   ├── build-address-pr-comments/  # Triage + fix review comments
│   ├── definition-of-done/         # Versioned DoD shared across the pipeline
│   └── inject-context/             # Resolve changed files → context-bundle rule files
├── shared/
│   ├── build-log.sh                # JSONL audit-log helper (used suite-wide)
│   ├── context-bundles.yml         # Bundle registry consumed by inject-context
│   ├── finding-routes.json         # Sensor finding → action routing
│   ├── inject_context.py / test_inject_context.py
│   ├── parse-sarif.py
│   └── (smoke-test scripts for PR comments, worktree path propagation)
├── CLAUDE.md
├── AGENTS.md
├── AUTONOMOUS-MODE.md              # Conventions for --autonomous propagation
├── CHANGELOG.md
└── README.md
```

## Versioning

- No `version` in plugin.json (repo versioned via release-please + git tags)
- Skill versions: bumped in SKILL.md frontmatter per feature PR
- Agent versions: bumped in agent frontmatter per feature PR
- CHANGELOG.md: updated with each PR

## Skill Routing — recommended_skills[] propagation chain (agent-skill-routing #146)

`build-refine`, `build-implement-tdd`, `build-implement-goal`, `sensor-fixer`, and `coder`
implement the downstream half of the agent-skill-routing propagation chain:

### build-refine pass-through

When reading a `stories.json` produced by `decompose` v1.2.0+, `build-refine` checks each
sub-task for a `recommended_skills` field. If present and non-empty, it copies the value
verbatim into the corresponding plan task as `recommended_skills`. The field is then
available to `build-implement-tdd` and `build-implement-goal` when they dispatch the coder.
**Omit when absent** — do NOT write an empty array.

### build-implement-tdd / build-implement-goal coder dispatch

Both implementation skills check the task's `recommended_skills` field from `plan.md` before
each coder dispatch. If present and non-empty, `RECOMMENDED_SKILLS` is included in the coder
dispatch bundle. If absent — the field is omitted entirely from the bundle.

### coder skill consultation prepend (§ *Skill consultation prepend*)

When `RECOMMENDED_SKILLS` is present and non-empty in the coder dispatch bundle:

1. Invoke each listed skill **sequentially** before Phase 1 RED (TDD) or Phase BUILD (goal).
2. Treat each skill's output as advisory context — weight equivalent to `SCOUT_SUMMARY`.
3. A recommended skill never overrides `PLAN_CONTEXT.Hard Constraints`.
4. If a skill path does not exist: log a warning and skip — do NOT HALT.

When `RECOMMENDED_SKILLS` is absent or empty: skip this section and proceed directly.

### sensor-fixer pass-through

`sensor-fixer` also accepts `RECOMMENDED_SKILLS` from its dispatch bundle and forwards it
to each `build-resolve-finding` call so repair skills can benefit from the same domain context.

### Skill-passport writer + advisory gate (agent-skill-routing F3 / #147)

Skill-routed agents write a **passport node** to `specs/<key>-*/skill-passport.json` when they
complete a skill invocation, gated by `should_emit_f4_log` in
`plugins/makato-build/shared/skill_passport.py`. Each passport node records the skill ID,
invocation timestamp, and parent agent, forming a tree that `compute_rollup` flattens into
the set `skills_invoked_transitively`.

After all quality gates pass, `build-verify` Step 9 reads the passport and compares
`skills_invoked_transitively` against `skills_expected` (resolved from the final git diff via
`skill-bundles.yml` / `inject-skills`). When a required skill was not invoked, Step 9 emits
one advisory warning per missing skill to `build.jsonl`. **The gate is advisory only — it
never fails the build (NFR-R2).**

Absent passport (session predates F3 or agent opted out of F4 telemetry) → "skill usage
tracking skipped" note to `build.jsonl`, build proceeds.

Detected concurrent-write race (malformed JSON, missing `schema_version`, or last-modified
collision) → warning to `build.jsonl`, diff skipped — no passport corruption (v1
single-session fallback).

## TEST_ORACLE propagation chain (acceptanceTestCases → coder RED)

`build-refine`, `plan-analyst`, `build-implement-tdd`, and `coder` implement a second
optional propagation chain that gives the makato-plan `acceptanceTestCases[]` field a
downstream consumer. It is structurally parallel to the `recommended_skills[]` chain above.

The two acceptance fields on a `stories.json` story play distinct roles:

- `description.successScenarios[]` (PO/decompose-authored) → **what to build** → `build-refine`
  numbers them AC-1, AC-2, … and drives task decomposition + the AC coverage table.
- `description.acceptanceTestCases[]` (QA-refined by `create-acceptance-tests`) → **how to
  verify** → the `TEST_ORACLE`.

Chain:

1. **build-refine** (Step 4 / Step 10): when the story carries a non-empty
   `acceptanceTestCases[]`, copy the scenarios verbatim into a `## Acceptance Test Oracle`
   section of `plan.md`, each annotated `(maps to AC-N)`. Omit the section entirely when the
   field is absent or empty. Does NOT create new AC numbers.
2. **plan-analyst**: reads the `## Acceptance Test Oracle` section from `plan.md` and returns
   it verbatim in the Plan Analysis prose block. It is the sole reader of `plan.md` —
   `build-implement-tdd` never re-reads the file.
3. **build-implement-tdd** (Step 6 coder dispatch): forwards the section verbatim as
   `TEST_ORACLE` in the coder dispatch bundle when present; omits it when absent — never an
   empty value. Sourced from the Plan Analysis, not a re-read.
4. **coder** (§ *Test oracle*, Phase 1 RED): filters the oracle by the task's `**Satisfies:**`
   AC links and implements the matching scenarios as its RED tests (given → arrange, when →
   act, then/and → assert). The oracle is a coverage floor, not a ceiling.

**Contract rules:**

- Optional end-to-end: absent/empty `acceptanceTestCases[]` → no oracle section → every stage
  behaves byte-for-byte as before. All existing `stories.json` (empty `[]`) are unaffected.
- Advisory: `TEST_ORACLE` never overrides `PLAN_CONTEXT.Hard Constraints` or `Standards` —
  same weight as `SCOUT_SUMMARY`.
- **TDD-only**: this chain touches only `build-implement-tdd` and the `coder` RED phase.
  `build-implement-goal` is intentionally not part of it (goal-mode writes tests after build).

## PR Checklist

- [ ] Serves the plugin goal: transforms planned stories into merged code
- [ ] Skills are self-contained
- [ ] No resume/orchestration logic — single-session execution only
- [ ] Skill emits JSONL log entries (session start, each step, session end)
- [ ] README Workflow section updated (new/changed skills must document their step, input, output)
- [ ] CHANGELOG updated
- [ ] Conventional commit title: `type(makato-build): description`
