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
│   └── (agents added via makato-skill-creator)
├── hooks/
│   └── (hooks for pre-commit, testing, etc.)
├── skills/
│   └── (skills added via makato-skill-creator)
├── shared/
├── CLAUDE.md
├── AGENTS.md
├── CHANGELOG.md
└── README.md
```

## Versioning

- No `version` in plugin.json (repo versioned via release-please + git tags)
- Skill versions: bumped in SKILL.md frontmatter per feature PR
- Agent versions: bumped in agent frontmatter per feature PR
- CHANGELOG.md: updated with each PR

## PR Checklist

- [ ] Serves the plugin goal: transforms planned stories into merged code
- [ ] Skills are self-contained
- [ ] No resume/orchestration logic — single-session execution only
- [ ] Skill emits JSONL log entries (session start, each step, session end)
- [ ] README Workflow section updated (new/changed skills must document their step, input, output)
- [ ] CHANGELOG updated
- [ ] Conventional commit title: `type(makato-build): description`
