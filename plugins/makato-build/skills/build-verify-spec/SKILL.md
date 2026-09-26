---
name: build-verify-spec
description: >-
  Spec-level verify skill — confirm implementation satisfies plan artifacts.
  Reads plan.md checkboxes (COMPLETENESS), stories.json successScenarios
  (CORRECTNESS), and spec-delta.md MODIFIED sections (COHERENCE) and emits a
  structured three-section report. Any unchecked task or GAP finding halts
  with exit 1 before build-push-to-git. Invoked by po-agent Step 6 between
  build-verify and build-push-to-git. Triggers: verify-spec, spec-check,
  AC-coverage, plan-completeness, HALT-011.
version: "1.0.0"
argument-hint: "<SPEC_KEY> [<diff-file>]"
allowed-tools:
  - Bash
metadata:
  authors: [makato-build]
  last_updated: "2026-08-05"
---

## When to Use

Use after `build-verify` and before `build-push-to-git`. This step answers:
*"Does the implementation actually do what plan.md and stories.json promised?"*

`build-verify` validates quality gates (lint, unit tests, integration tests). It does
not answer whether the implementation satisfies the spec artifacts. `build-verify-spec`
fills that gap with three-dimensional verification:

- **COMPLETENESS** — are all tasks in `plan.md` checked off?
- **CORRECTNESS** — does the implementation satisfy each `successScenarios` entry in `stories.json`?
- **COHERENCE** — are MODIFIED requirements from `spec-delta.md` respected by the diff?

po-agent integrates this skill into Step 6 of its pipeline between `build-verify`
and `build-push-to-git`.

## Expert: How Verification Works

Understanding the matching algorithm is essential for interpreting verdicts correctly.

**COMPLETENESS** scans *only* the `## Tasks` section of `plan-<N>.md`. Checkboxes in
other sections (`## Definition of Done`, `## Background`, etc.) are explicitly ignored.
The `## Tasks` heading match is case-insensitive. Any new `##`-level heading terminates
the section scan. This means DoD checkboxes never count toward the COMPLETENESS total —
a fully checked DoD with incomplete tasks still exits 1.

**CORRECTNESS** uses keyword overlap. For each `successScenarios` entry, the verifier
concatenates `title + given + when + then`, strips a 40-word stop list, and checks what
fraction of the remaining tokens appear anywhere in the raw diff text. Threshold:
**≥ 40%** keyword overlap → CONFIRMED; else GAP.

Critical stop-word detail: `"code"`, `"test"`, `"plan"`, `"spec"`, `"task"`, `"diff"`,
`"file"` are all stop words. A scenario whose text is dominated by these terms produces
a near-empty keyword list, which scores as GAP regardless of the diff content.
Words under three characters are also excluded (regex: `[a-z_][a-z0-9_]{2,}`).

**COHERENCE** runs the same algorithm on each `SHALL:` statement in `spec-delta.md`'s
`## MODIFIED Requirements` section, but with two thresholds:
- **≥ 35%** keyword overlap → CONFIRMED
- **20–35%** → SUGGESTION (non-blocking, exit 0)
- **< 20%** → GAP (blocking, exit 1)

The SUGGESTION band exists specifically for `spec-delta.md` entries whose SHALL statements
use more abstract language than the code implements — partial evidence that warrants review
but does not block push.

**Exit 2** is a usage or environment error (spec folder not found, unreadable plan file,
missing `build_verify_spec.py`). It indicates a configuration problem, not a spec failure.
Fix the invocation before interpreting any verdicts.

## Input

- `SPEC_KEY` — the spec folder key (e.g. `gap-006`). Resolves to `specs/<SPEC_KEY>-*/`
  via prefix-match glob; falls back to `specs/<SPEC_KEY>/` exact match.
- `DIFF_FILE` (optional) — path to a git diff file. When absent, the skill runs
  `git diff HEAD` in the current worktree. Pass `-` to read from stdin.

**REPO_ROOT override:** Set the `REPO_ROOT` env var to bypass `git rev-parse --show-toplevel`.
Required in CI environments or autonomous-mode worktrees where the default resolution
would find the wrong root.

The skill reads from the spec folder:
- `plan-<N>.md` — per-issue implementation plan (picks the highest-N file;
  falls back to `plan.md` for legacy single-plan specs)
- `stories.json` — story manifest (reads `stories[].description.successScenarios`)
- `spec-delta.md` (optional) — MODIFIED requirement sections; absent is a no-op

## Output

Three-section structured report to stdout:

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
- `2` — usage/environment error (missing spec folder, unreadable plan file, missing Python module)

SUGGESTION findings (COHERENCE keyword overlap 20–35%) are surfaced but non-blocking (exit 0).

## Decision Framework

When the script returns, triage by section and verdict:

| Verdict | Section | Action |
|---|---|---|
| CRITICAL: unchecked task(s) | COMPLETENESS | Escalate to `build-refine` — implementation gap |
| CRITICAL: N GAP finding(s) | CORRECTNESS | Escalate to `build-refine` — AC not satisfied |
| CRITICAL: N COHERENCE GAP | COHERENCE | Escalate to `build-refine` — MODIFIED requirement absent from diff |
| SUGGESTION | COHERENCE | Surface to human reviewer; non-blocking — do NOT HALT |
| All UNTESTABLE | any | Diff is empty — re-run with an explicit diff path or `git diff HEAD~1..HEAD` |
| Exit 2 | n/a | Fix invocation (SPEC_KEY, REPO_ROOT) before interpreting results |

**HALT-011** fires on exit 1. po-agent stamps `needs-human-review` and stops before
`build-push-to-git`. Route CRITICAL findings to `build-refine`, not to manual plan edits.

## Anti-patterns

**NEVER treat a SUGGESTION finding as blocking before push.** SUGGESTION means COHERENCE
keyword overlap scored 20–35% — partial evidence, not absence. Only GAP (< 20%) exits 1.
Manually halting on SUGGESTION triggers HALT-011 and `needs-human-review` for requirements
that may well be satisfied; it adds a human review cycle on a non-issue.

**NEVER interpret CONFIRMED as semantic proof that the feature is implemented.** The
verifier scans the raw diff text including context lines and deleted (`-`) lines. A diff
that *removes* an implementation still carries the feature's terminology in its `-` lines
and can score CONFIRMED at the 40% threshold. CONFIRMED means keyword co-occurrence, not
runtime correctness — `build-verify` owns that guarantee.

**NEVER pass `git diff HEAD~1` or a commit-range diff as the diff argument.** The
verifier expects `git diff HEAD` (all staged and unstaged changes vs the last commit).
A commit-range diff covers only already-committed code; work still in the index or
working tree becomes invisible, and newly introduced domain symbols will not appear,
producing false GAP verdicts for code that is present but not yet committed.

**NEVER run `build-verify-spec` before `build-verify` completes successfully.** Spec
verification runs keyword matching against the diff, not against compiled artifacts. If
`build-verify` found failing tests or lint errors the diff may contain stub code or
patched-out tests whose terminology generates false CONFIRMED verdicts for scenarios
those stubs do not actually satisfy.

**NEVER mark tasks complete in `plan-<N>.md` to clear a COMPLETENESS CRITICAL without
completing the implementation first.** The checkbox audit is the honesty signal that
prevents unfinished code reaching push. A false tick silences the gate and lets
incomplete work enter the PR, where it surfaces during review at higher remediation cost.

**NEVER assume a GAP for a scenario that looks implemented means the code is wrong.**
If the scenario text uses only stop-word vocabulary (e.g. all of `given`, `when`, `then`,
`code`, `test`, `file`) the keyword extractor returns an empty word list and the verifier
always returns GAP regardless of the diff content. Verify by checking whether the
scenario's non-stop terms appear in the diff before escalating to `build-refine`.

## Executable Reference

MANDATORY: read `references/build-verify-spec.sh` before the first invocation in a
session — confirm the argument order and any env-var overrides in effect. Do NOT load
it for verdict interpretation; the SKILL.md body covers all semantics.

```bash
"$MAKATO_BUILD_ROOT/skills/build-verify-spec/references/build-verify-spec.sh" \
  <SPEC_KEY> [<diff-file>]
```

Load `references/build-verify-spec-smoke-tests.sh` ONLY when diagnosing unexpected
exit 2 behavior or malformed output from the script internals — not from a spec failure.
Do NOT load it for normal invocation or verdict triage.

## Edge Cases

| Situation | Behavior | Fix |
|---|---|---|
| `plan-<N>.md` absent, no `plan.md` either | exit 2 with error | Verify SPEC_KEY; confirm spec folder contains a plan file |
| `stories.json` absent | CORRECTNESS skipped (OK) | Normal for plan-only tier specs |
| `stories.json` malformed JSON | One synthetic GAP verdict; exit 1 | Fix JSON syntax, then re-run |
| `successScenarios` array empty or key absent | CORRECTNESS skipped | No correctness check run |
| `spec-delta.md` absent | COHERENCE skipped (OK) | Normal; spec had no MODIFIED requirements |
| Diff is empty (all changes committed, nothing staged) | All verdicts UNTESTABLE; exit 0 | Pass an explicit diff: `git show HEAD > diff.txt` or `git diff HEAD~1..HEAD > diff.txt` |
| Multiple `plan-<N>.md` files | Picks highest-N alphabetically | Confirm the target issue's plan is the latest file |
| `REPO_ROOT` not a git repo and env var unset | exit 2 | Set `REPO_ROOT` to the repo root |

## Integration Point — po-agent Step 6

po-agent invokes this skill after `build-verify` succeeds and before `build-push-to-git`.
Any exit 1 halts with HALT-011 before push.

```
build-verify → build-verify-spec → build-push-to-git
```

When `build-verify-spec` exits 1, po-agent applies `needs-human-review` and emits
HALT-011 (`build-verify-spec: CRITICAL finding — spec not satisfied`).

## Not in Scope

- Runtime/integration verification — that is `build-verify`'s job
- Automated fix of GAP findings — escalates to `build-refine`
- Verification of non-plan-tier issues (future enhancement)
