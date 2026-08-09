---
name: build-explore
description: >-
  Read-only thinking-partner skill — understands a problem area, surveys
  the current implementation, proposes 2-4 solution alternatives with
  trade-offs, and recommends an approach. Blocks all file writes so the
  exploration never leaves unintended side-effects. Use before /build-start
  when the approach is unclear, when you want to stress-test options before
  committing to a plan, or when a new contributor needs orientation on an
  area. Trigger keywords: explore, survey, options, approach, trade-offs,
  orient me, what are the ways. Do NOT use when an approach is already
  decided and implementation is ready to begin.
version: "1.1.0"
argument-hint: "[topic, file path, GitHub issue #NNN, or issue URL]"
allowed-tools: Read Glob Bash(grep *) Bash(find *) Bash(ls *) Bash(cat *) Bash(head *) Bash(tail *)
metadata:
  authors: [makato-build]
  last_updated: "2026-08-05"
---

# build-explore

## When to Use

Use `build-explore` when you need to think through a problem before committing to
an implementation approach — and you want the thinking to be grounded in the
actual codebase, not assumptions.

**Good triggers:**
- "I'm not sure how to approach this"
- "Show me the options before we start building"
- "Orient me on this area of the code"
- "What are the trade-offs between X and Y here?"

**Do NOT use when:**
- An approach is already decided — go straight to `/build-start`
- You need to make code changes — this skill is intentionally read-only
- The topic spans more than two cross-plugin contracts simultaneously — see Anti-patterns

## Allowed Tools

This skill is read-only. The `allowed-tools` frontmatter restricts available
tools to: `Read`, `Glob`, `Bash(grep *)`, `Bash(find *)`, `Bash(ls *)`,
`Bash(cat *)`, `Bash(head *)`, `Bash(tail *)`.

`Write`, `Edit`, and any file-mutating or git-commit tools are NOT available.
This is enforced by the frontmatter — not by convention.

## Workflow

### Step 1 — Identify the topic

If an argument was passed when invoking this skill, classify it by shape
(see Input Shape Decision Tree below) and derive the topic from it directly.

Otherwise use the `AskUserQuestion` tool with selectable options:

```
What should we explore?
Options:
  A) A GitHub issue — paste the issue number or URL (e.g. #123, https://github.com/.../issues/123)
  B) A specific file or directory path
  C) A feature or module name (freeform description)
  D) Two specific approaches to compare (name them)
```

Set `TOPIC` from the argument or the user's answer. If the answer is too vague
to locate any files (e.g., "the auth stuff"), ask one follow-up to narrow the
scope before reading — do not start surveying a broad area blindly.

#### Input Shape Decision Tree

```
Argument provided?
├── Yes: GitHub issue URL or "#NNN"
│     → gh issue view <N> --json title,body,labels
│       read specs/<N>-<slug>/ if it exists (plan.md, stories.json)
│       derive TOPIC from issue title + body
├── Yes: file path (starts with / or ./ or contains /)
│     → Read the file, derive TOPIC from its name and imports
├── Yes: freeform text
│     → use as TOPIC directly, proceed to Step 2
└── No  → AskUserQuestion (above)
```

### Step 2 — Survey the current implementation

Use `Glob`, `Bash(find *)`, `Bash(grep *)`, and `Read` to locate and read
the relevant files. Apply the **makato-specific survey signals** below before
falling back to generic grep.

#### makato-specific survey signals (read these first)

These files contain non-obvious context that generic code-reading misses:

1. **`specs/<key>-<slug>/`** — check `plan.md`, `stories.json`, `build.jsonl`
   (if the folder exists). `build.jsonl` reveals prior failed attempts; prior
   `HALT` codes mean a specific constraint blocked this path before.

2. **`spec_tier` field in `seed-manifest.json` or issue labels** — `plan-only`
   stories arrive with only `plan.md`; `full-tier` stories have `stories.json`
   + `prd.md` + `design.md`. The tier tells you the *depth* of prior shaping
   and whether acceptance criteria live in `plan.md ## Acceptance criteria` vs
   `stories.json description.successScenarios`.

3. **`bypassPermissions` boundaries** — only the `coder` agent runs elevated.
   If an alternative would require any other agent to write files autonomously,
   note the permission escalation risk explicitly in the trade-offs. Check
   `agents/*.md` for the permission mode of any agent the alternative would touch.

4. **Cross-plugin contracts** — if the area touches `makato-orchestrate` loop
   (workflow-state.json, dispatch signals) or `makato-plan` artifacts
   (stories.json schema), look for the contract definition in the other plugin's
   AGENTS.md before assessing reversibility. Cross-plugin changes that appear
   local (e.g., adding a field to `build.jsonl`) often break downstream readers.

5. **`config/context-bundles.yml`** — if the topic affects files that live
   in a named bundle, `inject-context` will automatically supply their rules
   to the coder. Check whether the relevant bundle rule already constrains
   the approach.

6. **TODO/FIXME/HACK comments + feature flags** — `grep -r "TODO\|FIXME\|HACK\|# noqa\|# type: ignore"` in the target area surfaces known debt. A "temporary" workaround that predates the feature you are exploring may be the reason the approach is non-obvious.

Aim to understand:

- Where the current behaviour lives (entry points, core logic, data flow)
- Key abstractions, contracts, and naming conventions in the area
- Existing tests — what is already covered and what is not
- Any constraints visible in the code (TODO comments, feature flags, deprecated paths)

**Read budget:** stop when you have a clear enough picture to reason about
solutions. For codebases where a single subsystem spans 20+ files, read
the entry point and its direct callers first; only descend into helpers when
an alternative would change them. If after reading 10 files the scope is
still expanding, note "survey truncated at 10 files — deeper reading deferred
to build-refine" in the report.

### Step 3 — Produce the exploration report

Write the full report in a single response using the structure below.
Do not stream partial sections — present the complete report at once.

> **Format rule:** every section heading below is required. If a section has
> nothing to say (e.g., "Open Questions" is genuinely empty), write "None."
> Do not omit the heading.

---

## Problem Summary

One paragraph describing the problem or question being explored. Concrete,
grounded in the code you just read.

## Current Implementation Overview

Brief description of how the relevant area currently works. Include:

- Key files / modules involved
- The primary code path (how data or control flows)
- Noteworthy constraints or technical debt observed
- Any prior `HALT` codes or failed attempts visible in `build.jsonl`

Keep this tight — 3-8 bullet points or a short paragraph. Not a file listing.

## Solution Alternatives

Present **2 to 4** distinct alternatives. For each one, use this format:

### Alternative 1: \<short name\>

**Approach:** One sentence on what this alternative does.

**Trade-offs:**

| Aspect | Assessment |
|--------|-----------|
| Complexity | Low / Medium / High |
| Risk | Low / Medium / High |
| Test coverage impact | Describe briefly |
| Reversibility | Easy / Moderate / Hard |
| Permission boundary impact | None / Note escalation if any |

**Notes:** Any caveats, prerequisites, or open questions specific to this
alternative. Flag if it would require a cross-plugin contract change.

### Alternative 2: \<short name\>

**Approach:** One sentence on what this alternative does.

**Trade-offs:**

| Aspect | Assessment |
|--------|-----------|
| Complexity | Low / Medium / High |
| Risk | Low / Medium / High |
| Test coverage impact | Describe briefly |
| Reversibility | Easy / Moderate / Hard |
| Permission boundary impact | None / Note escalation if any |

**Notes:** Any caveats, prerequisites, or open questions specific to this
alternative. Flag if it would require a cross-plugin contract change.

Add Alternative 3 and Alternative 4 when genuinely distinct options exist.
Do not pad with weak variations — two strong alternatives are better than
four thin ones.

**Edge case — no distinct alternatives:** if genuine exploration reveals only
one viable path (e.g., all other options are blocked by a hard constraint in
AGENTS.md or an existing cross-plugin contract), present that single option
and explain why the others were ruled out rather than fabricating alternatives.

---

## Recommended Approach

State which alternative you recommend and why. Connect the recommendation
to the constraints and trade-offs observed above. Be direct — one clear
recommendation, not a hedge.

**Genuinely tied case:** if two alternatives are indistinguishable after
examining the actual code, state the tie explicitly and identify the one
decision criterion that would break it (e.g., "depends on whether team
accepts a cross-plugin schema change").

## Open Questions

List any questions that would change the recommendation if answered
differently. Format as a bulleted list. If there are none, write "None."

---

Ready to proceed? Run `/build-start` to begin implementation.

## Anti-patterns

These are non-obvious failure modes that only experience with this pipeline
reveals. Each has an explicit WHY.

**NEVER pad alternatives with weak variations of the same approach.**
WHY: `build-refine` treats each alternative as a distinct implementation path
to plan. Weak variations (e.g., "same approach but with slightly different
naming") cause refine to plan two tasks that collapse into one, wasting a full
skill invocation and making the plan analyst flag a scope ambiguity.

**NEVER stream partial sections of the report.**
WHY: The report is for human consumption; there is no automated build-start integration.

**NEVER hedge the recommendation ("either A or B could work").**
WHY: the recommendation is a decision input, not a discussion. Hedging forces
the user to redo the trade-off analysis that explore was supposed to do.
`build-refine` needs exactly one approach to plan against; it will not branch
on a hedge.

**NEVER omit required headings even if a section is empty.**
WHY: The report is for human consumption; there is no automated build-start integration. A missing "## Open Questions" heading silently drops
questions that could affect the implementation; a missing "## Recommended
Approach" section leaves the reader without a clear direction.

**NEVER explore when the topic spans more than two cross-plugin contracts
simultaneously.**
WHY: exploration scope becomes unbounded — reading one contract surfaces another,
and the report is already stale by the time `build-refine` starts. The correct
path is to file a separate exploration per contract boundary and combine at
the `build-grill-with-docs` stage. Topics crossing `makato-orchestrate` loop
state AND `makato-plan` schema AND `makato-build` pipeline in one exploration
always produce recommendation drift.

**NEVER propose alternatives that require adding `bypassPermissions` to agents
other than `coder` without flagging this explicitly.**
WHY: the `coder` is the only `bypassPermissions` agent by design (AGENTS.md
hard constraint). An alternative that implicitly needs elevated permissions for
another agent will fail to implement and will cause a mid-session HALT in
`build-implement-tdd` when the agent cannot write files. Surface this as
a blocker in the trade-offs table, not a minor note.

**NEVER treat `build.jsonl` as a temporary local file.**
WHY: `build.jsonl` is the only `specs/` artifact committed to the repo
(`.gitignore` re-includes `specs/**/build.jsonl`). Alternatives that propose
changing its schema or moving it outside `specs/<key>/` will break the audit
trail that the orchestrate plugin reads post-merge. Always treat it as a
committed contract.
