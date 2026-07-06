# Build-Simplify Smoke Fixture — `BSS-001`

This fixture is the **synthetic implementation plan** consumed by
`tests/test_smoke_build_simplify.py` (#64 Part B). It is NOT a real spec and
does NOT live under `specs/` directly — `specs/**/*` is gitignored except for
`build.jsonl` (see `.gitignore` and #99), so a `plan.md` checked into `specs/`
would never reach the repo. The test materializes a temporary
`specs/BSS-001-build-simplify-smoke/` at runtime, copies this `plan.md` and the
synthetic diff fixture into it, and exercises the 7-step JSONL contract
documented in `plugins/makato-build/skills/build-simplify/SKILL.md` § Workflow.

## Story

**BSS-001 — Verify build-simplify no-test-runner handling (GAP-064 Part A)**

The synthetic anti-pattern below reproduces the **Wrapper for Wrapper's Sake**
entry from `plugins/makato-build/skills/build-simplify/references/simplification-patterns.md`.
The skill, dispatched against this fixture in autonomous mode WITHOUT a test
runner discoverable by `gate-scout`, MUST:

1. Step 3 outcome (b) — log `step:"baseline", status:"skip"` with
   `test_suite_present: false`
2. Step 7 short-circuit — log `step:"verify", status:"skip"` with
   `degraded_confidence: true`
3. Step 7a autonomous-mode no-op (the synthetic diff is `.ts` so the gate
   *would* fire interactively; in autonomous mode it emits an
   `autonomous_bypass` JSONL entry instead of prompting)
4. Step 8 — log session end with both flags carried in `data`
5. R1 envelope — `data.test_suite_present: false`, `data.degraded_confidence: true`,
   `status: "partial"` (autonomous mode + code-file touch)

If the autonomous-mode dispatch tried to run a test command against this
fixture, the skill would crash mid-session (no `pyproject.toml` / `package.json`
inside the synthetic spec folder) — that crash is exactly the failure mode
Part A closes.

## Acceptance criteria

- **AC1** — Step 3 emits a `status:"skip"` row with `test_suite_present: false`
  when no test runner is discovered.
- **AC2** — Step 7 short-circuits when `test_suite_present == false`.
- **AC3** — Step 7a emits the autonomous-mode bypass entry (does NOT prompt
  the user) when code files are touched.
- **AC4** — Step 8 R1 envelope carries `test_suite_present` and
  `degraded_confidence` in `data`.
- **AC5** — The full session arc is reconstructable from `build.jsonl`:
  `session:start → baseline → analyze → review → [apply] → verify → session:end`.

## Tasks

### Task 1 — synthetic Wrapper for Wrapper's Sake removal

- **mode**: tdd (irrelevant for the smoke test — `build-simplify` does not run TDD)
- **file_targets**: `synthetic/user_service_wrapper.ts`
- **acceptance**: the `UserServiceWrapper` class is removed; callers use the
  wrapped `UserService` directly.
- **commitMessage**: `refactor(synthetic): inline UserServiceWrapper`
