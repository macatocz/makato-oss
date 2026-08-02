---
name: build-verify-spec
description: >-
  Spec-level verify skill — confirm implementation satisfies plan artifacts.
  Reads plan.md checkboxes (COMPLETENESS), stories.json successScenarios
  (CORRECTNESS), and spec-delta.md MODIFIED sections (COHERENCE) and emits a
  structured three-section report. Any unchecked task or GAP finding halts
  with exit 1 before build-push-to-git. Invoked by po-agent Step 6 between
  build-verify and build-push-to-git.
version: "1.0.0"
argument-hint: "<SPEC_KEY> [<diff-file>]"
---

## When to Use

Use after `build-verify` and before `build-push-to-git`. This step answers:
*"Does the implementation actually do what plan.md and stories.json promised?"*

`build-verify` runs quality gates (lint, unit tests, integration tests). It does
not answer whether the implementation satisfies the spec artifacts. `build-verify-spec`
fills that gap with three-dimensional verification:

- **COMPLETENESS** — are all tasks in `plan.md` checked off?
- **CORRECTNESS** — does the implementation satisfy each `successScenarios` entry in `stories.json`?
- **COHERENCE** — are MODIFIED requirements from `spec-delta.md` respected by the diff?

po-agent integrates this skill into Step 6 of its pipeline between `build-verify`
and `build-push-to-git`.

## Input

- `SPEC_KEY` — the spec folder key (e.g. `gap-006`). Resolves to `specs/<SPEC_KEY>-*/`
  via prefix-match glob.
- `DIFF_FILE` (optional) — path to a git diff file. When absent, the skill runs
  `git diff HEAD` in the current worktree to obtain the diff. Pass `-` to read
  from stdin.

The skill reads from the spec folder:
- `plan-<N>.md` — the per-issue implementation plan (reads the latest if multiple)
- `stories.json` — the story manifest (reads `stories[].successScenarios`)
- `spec-delta.md` (optional) — MODIFIED requirement sections; absent is a no-op

## Output

Writes a three-section structured report to stdout:

```
=== COMPLETENESS ===
Tasks: N/M checked
[OK | CRITICAL: N unchecked task(s)]

=== CORRECTNESS ===
stories.json successScenarios: N scenarios
[per scenario: CONFIRMED | GAP | UNTESTABLE]
[OK | CRITICAL: N GAP finding(s)]

=== COHERENCE ===
spec-delta.md: [absent — skipped | N MODIFIED requirement(s)]
[per requirement: CONFIRMED | GAP | SUGGESTION]
[OK | suggestions-only OK]
```

Exit codes:
- `0` — all checks pass (COMPLETENESS OK, CORRECTNESS OK, COHERENCE OK or absent)
- `1` — CRITICAL finding: any unchecked task, any CORRECTNESS GAP, or any COHERENCE GAP

SUGGESTION findings (e.g. COHERENCE ambiguous matches) are surfaced but non-blocking (exit 0).

## Executable Reference

The implementation lives in `references/build-verify-spec.sh`. po-agent (and any
caller) invokes it directly:

```bash
plugins/makato-build/skills/build-verify-spec/references/build-verify-spec.sh \
  <SPEC_KEY> [<diff-file>]
```

## Integration Point — po-agent Step 6

po-agent invokes this skill after `build-verify` succeeds and before `build-push-to-git`.
Any exit 1 from this skill halts with HALT-011 before push.

```
build-verify → build-verify-spec → build-push-to-git
```

When `build-verify-spec` exits 1, po-agent applies `needs-human-review` and emits
HALT-011 (`build-verify-spec: CRITICAL finding — spec not satisfied`).

## Not in Scope

- Runtime/integration verification — that is `build-verify`'s job
- Automated fix of GAP findings — escalates to `build-refine`
- Verification of non-plan-tier issues (future enhancement)
