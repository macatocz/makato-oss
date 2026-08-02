---
name: build-explore
description: >-
  Read-only thinking-partner skill — understands a problem area, surveys
  the current implementation, proposes 2-4 solution alternatives with
  trade-offs, and recommends an approach. Blocks all file writes so the
  exploration never leaves unintended side-effects. Use before /build-start
  when the approach is unclear, when you want to stress-test options before
  committing to a plan, or when a new contributor needs orientation on an
  area. Do NOT use when an approach is already decided and implementation
  is ready to begin.
version: "1.0.0"
argument-hint: "[topic or file path]"
allowed-tools: Read Glob Bash(grep *) Bash(find *) Bash(ls *) Bash(cat *) Bash(head *) Bash(tail *)
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

## Allowed Tools

This skill is read-only. The `allowed-tools` frontmatter restricts available
tools to: `Read`, `Glob`, `Bash(grep *)`, `Bash(find *)`, `Bash(ls *)`,
`Bash(cat *)`, `Bash(head *)`, `Bash(tail *)`.

`Write`, `Edit`, and any file-mutating or git-commit tools are NOT available.
This is enforced by the frontmatter — not by convention.

## Workflow

### Step 1 — Identify the topic

Read the argument or ask:

> "What problem or area should we explore? (file path, feature name, or
> free-form description)"

Set `TOPIC` from the argument or the user's answer.

### Step 2 — Survey the current implementation

Use `Glob`, `Bash(find *)`, `Bash(grep *)`, and `Read` to locate and read
the relevant files. Aim to understand:

- Where the current behaviour lives (entry points, core logic, data flow)
- Key abstractions, contracts, and naming conventions in the area
- Existing tests — what is already covered and what is not
- Any constraints visible in the code (TODO comments, feature flags, deprecated
  paths)

Do not read more than needed — stop when you have a clear enough picture to
reason about solutions.

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

**Notes:** Any caveats, prerequisites, or open questions specific to this
alternative.

### Alternative 2: \<short name\>

**Approach:** One sentence on what this alternative does.

**Trade-offs:**

| Aspect | Assessment |
|--------|-----------|
| Complexity | Low / Medium / High |
| Risk | Low / Medium / High |
| Test coverage impact | Describe briefly |
| Reversibility | Easy / Moderate / Hard |

**Notes:** Any caveats, prerequisites, or open questions specific to this
alternative.

Add Alternative 3 and Alternative 4 when genuinely distinct options exist.
Do not pad with weak variations — two strong alternatives are better than
four thin ones.

---

## Recommended Approach

State which alternative you recommend and why. Connect the recommendation
to the constraints and trade-offs observed above. Be direct — one clear
recommendation, not a hedge.

## Open Questions

List any questions that would change the recommendation if answered
differently. Format as a bulleted list. If there are none, write "None."

---

Ready to proceed? Run `/build-start` to begin implementation.
