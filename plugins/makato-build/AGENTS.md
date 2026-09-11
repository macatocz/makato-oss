<!-- markdownlint-disable MD013 MD032 MD040 -->
# makato-build — Contributor Guide

## Hard Constraints

- **`coder` is the only `bypassPermissions` agent.** Never grant elevated permissions to any other agent without explicit documentation and code-review approval in this section.
- **`coder` dispatched only by `build-implement-tdd` or `build-implement-goal`.** Never invoke it directly from user prompts or other skills.
- **`sensor-fixer` must never edit files outside the changed-files set** captured at dispatch time. File targets are validated by `build-refine` before plan approval.
- **`diff-reviewer` is the sole AC-verdict judge.** `build-review` and `build-create-pr` are transport-only — they copy verdicts, never re-evaluate them.
- **`build.jsonl` is the only `specs/` artefact committed to the repo.** Never log secrets, credentials, file paths outside the repo, or any content you would not paste into a public PR.
- **`PLAN_CONTEXT.Hard Constraints` always overrides advisory inputs.** `RECOMMENDED_SKILLS`, `SCOUT_SUMMARY`, and `TEST_ORACLE` are advisory and never override hard constraints.
- **No hotfixes or ad-hoc changes.** Route defect fixes to `makato-change`; route new shaping work to `makato-plan`.
- **Skill files must not use `../` paths outside their skill directory** (except `../shared/` within this plugin).
- **`build-implement-goal` does not participate in the `TEST_ORACLE` chain.** That chain is TDD-only; do not add oracle propagation to goal-mode flows.

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
  - Every skill MUST append JSONL log entries to `specs/<story-key>-<slug>/build.jsonl` via the resolved plugin-root helper — minimum: session start, each major step, session end. See the Logging section in README.md for the schema.
  - Log every agent decision that deviates from the happy path using `status: "decision"` or `status: "warn"` — classification choices (fixable vs structural), escalations, gate retries, workarounds, and baseline-gate user choices. A future session reading `build.jsonl` must be able to reconstruct what went wrong and why.
  - Resolve the installed plugin root before invoking helpers. Use the runner-provided
    `CLAUDE_PLUGIN_ROOT`, `OMP_PLUGIN_ROOT`, or `PLUGIN_ROOT` (or the explicit
    `MAKATO_BUILD_ROOT` context field) and invoke
    `<MAKATO_BUILD_ROOT>/shared/build-log.sh`; never assume the consumer repository's
    CWD is the plugin root. The source-checkout fallback is
    `REPO_ROOT/plugins/makato-build`.
  - **`build.jsonl` is the only file under `specs/` that ships in-repo** (#99). The repo-root `.gitignore` excludes `specs/**/*` but re-includes `specs/**/build.jsonl` so the audit trail of every skill run is reviewable from a fresh checkout. Plan, stories, project-sync, fixtures, and every other artefact under `specs/<key>/` stay local. Treat `build.jsonl` as a committed evidence file: do not log secrets, credentials, file paths outside the repo, or any content you would not paste into a public PR.

## File Structure

```text
makato-build/
├── .claude-plugin/plugin.json
├── agents/    coder, diff-reviewer, gate-scout, knowledge-scout, plan-analyst, runtime-qa, sensor-fixer
│              runtime-qa: autonomous Playwright MCP QA agent — exercises built app against ACs, scores CRITICAL/MAJOR/ADVISORY findings, blocks push on CRITICAL
│              (+ RETURN-CONTRACT.md — R1 envelope spec shared by all build agents)
├── hooks/     pre-commit / testing hooks
├── skills/    build-start, build-refine, build-grill-with-docs, build-implement-{tdd,goal},
│              build-simplify, build-verify, build-sensors, build-resolve-finding,
│              build-fix-{types,security}, build-push-to-git, build-create-pr,
│              build-address-pr-comments, definition-of-done, inject-context
├── shared/    build-log.sh (suite-wide JSONL helper), runtime-context.sh,
│              spec_folder.py, context-bundles.yml, finding-routes.json,
│              inject_context.py (+ tests), parse-sarif.py, smoke-test scripts
├── CLAUDE.md, AGENTS.md, AUTONOMOUS-MODE.md, CHANGELOG.md, README.md
```

`coder` runs at `bypassPermissions`. See each skill's SKILL.md for its step contract.

## Versioning

- No `version` in plugin.json (repo versioned via release-please + git tags)
- Skill versions: bumped in SKILL.md frontmatter per feature PR
- Agent versions: bumped in agent frontmatter per feature PR
- CHANGELOG.md: updated with each PR

## Skill Routing — recommended_skills[] propagation chain (agent-skill-routing #146)

> **Documentation-skill obligations (suite-wide):** the **coder** MUST use `makato-doc`'s
> `context7` to check current API docs before writing code; `.md`/README work MUST use `markdown` /
> `crafting-effective-readmes` / `writing-clearly-and-concisely`. See repo-root `AGENTS.md` § *Documentation skills*.

`build-refine`, `build-implement-tdd`, `build-implement-goal`, `sensor-fixer`, and `coder`
implement the downstream half of the agent-skill-routing chain. `build-refine` copies a
sub-task's `recommended_skills` from `stories.json` (decompose v1.2.0+) verbatim into the plan
task; the implement skills forward it as `RECOMMENDED_SKILLS` in the coder/​sensor-fixer dispatch
bundle. The coder invokes each listed skill sequentially before RED/BUILD as advisory context
(weight = `SCOUT_SUMMARY`; never overrides Hard Constraints; missing skill → warn+skip, never
HALT). **Omit the field entirely when absent — never write an empty array.**

**Skill-passport writer + advisory gate (F3 / #147):** routed agents write a passport node to
`specs/<key>-*/skill-passport.json` (gated by `should_emit_f4_log` in `shared/skill_passport.py`).
`build-verify` Step 9 compares `skills_invoked_transitively` against `skills_expected` (from the
final diff via `skill-bundles.yml`) and emits one advisory `build.jsonl` warning per missing skill.
**Advisory only — never fails the build (NFR-R2).** Absent/malformed passport → note + proceed.

## TEST_ORACLE propagation chain (acceptanceTestCases → coder RED)

A second optional chain, structurally parallel to `recommended_skills[]`, gives makato-plan's
`acceptanceTestCases[]` a downstream consumer. The two acceptance fields play distinct roles:
`successScenarios[]` (PO-authored) = **what to build** (build-refine numbers them AC-1, AC-2… and
drives decomposition); `acceptanceTestCases[]` (QA-refined) = **how to verify** = the `TEST_ORACLE`.

Chain: **build-refine** copies a non-empty `acceptanceTestCases[]` verbatim into a
`## Acceptance Test Oracle` section of `plan.md` (each `(maps to AC-N)`; no new AC numbers) →
**plan-analyst** returns that section verbatim (sole reader of `plan.md`) → **build-implement-tdd**
forwards it as `TEST_ORACLE` in the coder bundle → **coder** filters by the task's `**Satisfies:**`
AC links and implements matching scenarios as RED tests (coverage floor, not ceiling).

**Contract:** optional end-to-end (absent → byte-for-byte prior behaviour); advisory (never
overrides Hard Constraints); **TDD-only** — `build-implement-goal` is excluded (goal-mode writes
tests after build).

## ac_verdicts propagation chain (diff-reviewer → PR body → issue checkboxes)

A third optional chain carries a per-AC **verified/gap verdict** from adversarial review to the
post-merge point where the linked Issue's AC checkboxes flip `[x]` — so a checked box means
*"reviewer confirmed code + test coverage"*, not merely *"PR merged"*. Its consumer lives in the
sibling `makato-orchestrate` plugin (`documentation-agent`).

Chain: **diff-reviewer** (v1.1.0+) emits one `{ac_id, ac_text, verified, evidence, reason}` per AC
(`verified:true` needs BOTH code AND a test) in R1 `data.ac_verdicts[]` → **build-review** copies it
into a `step:"ac-verification"` `build.jsonl` entry (the only durable local record) →
**build-create-pr** renders it into a `## AC Verification` PR-body block behind a `makato:ac-verdicts`
marker (sole transport to the GHA runner) → **documentation-agent** post-merge flips matched verified
boxes `- [ ]` → `- [x]`.

**Contract:** optional end-to-end; transport-only downstream (diff-reviewer is sole judge,
documentation-agent sole checkbox writer); forward-only (never unchecks; unverified ACs stay `- [ ]`).

## PR Checklist

- [ ] Serves the plugin goal: transforms planned stories into merged code
- [ ] Skills are self-contained
- [ ] No resume/orchestration logic — single-session execution only
- [ ] Skill emits JSONL log entries (session start, each step, session end)
- [ ] README Workflow section updated (new/changed skills must document their step, input, output)
- [ ] CHANGELOG updated
- [ ] Conventional commit title: `type(makato-build): description`
