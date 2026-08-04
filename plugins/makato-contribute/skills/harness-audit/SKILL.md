---
name: harness-audit
description: >-
  Operator-gated audit tool for the makato harness. Scans all
  plugins/*/AGENTS.md for line-count bloat and rules lacking spec/issue
  cross-references; scans all plugins/*/agents/*.md frontmatter for
  permissionMode and disallowedTools inconsistencies. Renders a
  classification table and a permissionMode report, then — only on
  explicit operator approval — reports findings. Never mutates files.
  Operator-only: never wired into any per-issue build lane or autonomous
  pipeline.
version: "1.0.0"
argument-hint: "[--non-interactive]"
allowed-tools: Read Bash Glob
---

<!-- markdownlint-disable MD013 -->

# harness-audit

> **Operator audit tool.** Human-gated. Never invoked per-issue or autonomously.
> Classifies AGENTS.md sections and agent frontmatter; no mutation in either path.

## When to Use

Use when you suspect AGENTS.md files have grown bloated, contain rules that lack
spec traceability, or when agent frontmatter permissionMode/disallowedTools
configurations may have drifted into inconsistent states. Typical cadence: after
every 3–5 plugin additions or during a periodic harness health review.

**Do NOT use** as an automated build step, a CI gate, or inside any autonomous
pipeline. This skill is operator-only: it requires a human to review findings
before any structural action is taken.

## Classification Classes

### AGENTS.md Section Classes

| Class | Meaning | Proposed action |
|---|---|---|
| **KEEP** | Section is within threshold and has a spec/issue cross-reference, or is a canonical structural section (Goal, What Belongs Here, Decision Test, Hard Constraints, etc.) | No change |
| **BLOAT** | Section exceeds meaningful size (contributes to >150 total lines) but has no `#NNN` or `specs/` cross-reference | Extract to a skill or reference doc |
| **REDUNDANT** | Content duplicated in another plugin's AGENTS.md or in a referenced spec | Consolidate and cross-link |
| **MOVE-TO-SKILL** | Section describes a propagation chain or runtime contract that belongs in a skill's SKILL.md, not in the plugin AGENTS.md | Move to a dedicated skill |

**Line threshold:** an AGENTS.md file totalling more than 150 lines is subject to bloat
scanning. Individual sections are classified BLOAT when: the file is over threshold AND
the section has no `#NNN` or `specs/` cross-reference AND it is not a canonical structural
section.

**Canonical structural sections** (always KEEP regardless of size or cross-ref):
`Goal`, `What Belongs Here`, `What Does NOT Belong Here`, `Decision Test`,
`Hard Constraints`, `File Structure`, `Versioning`, `PR Checklist`, `Skill Authoring`.

### permissionMode Report Classes

| Class | Meaning |
|---|---|
| **OK** | Agent has `bypassPermissions` + `disallowedTools` (read-only pattern) — OR — agent is a known write-capable agent with `bypassPermissions` and no `disallowedTools` |
| **MISSING_PM** | Agent frontmatter has no `permissionMode` field |
| **READ_WRITE_MISMATCH** | Agent has `bypassPermissions` but no `disallowedTools` and is NOT a known write-capable agent |

**Known write-capable agents** (hardcoded whitelist — update when adding new write-capable
agents): `coder`, `change-implementer`, `documentation-agent`, `po-agent`, `light-planner`,
`acceptance-writer`, `dev-reviewer`, `doc-writer`, `po-reviewer`, `prototype-builder`,
`qa-reviewer`.

## Workflow

### Step 1 — Classify

```bash
REPO_ROOT="${1:-$(git rev-parse --show-toplevel)}"
FINDINGS="$(bash plugins/makato-contribute/scripts/harness-audit.sh "$REPO_ROOT")"
```

The helper reads `$REPO_ROOT/plugins/*/AGENTS.md` and `$REPO_ROOT/plugins/*/agents/*.md`,
classifies each finding, and emits one JSON object per finding on stdout:

**AGENTS.md finding:**
```json
{"type":"agents-md","plugin":"<name>","section":"<heading>","lines":<N>,"refs":<N>,"action":"KEEP|BLOAT|REDUNDANT|MOVE-TO-SKILL","reason":"…"}
```

**permissionMode finding:**
```json
{"type":"permission","plugin":"<name>","agent":"<name>","permissionMode":"<val>","disallowedTools":"<val>","action":"OK|MISSING_PM|READ_WRITE_MISMATCH","reason":"…"}
```

### Step 2 — Render the classification tables

Parse `$FINDINGS` and display two tables.

**AGENTS.md classification table:**
```
AGENTS.md Audit (N sections across M plugin files)
──────────────────────────────────────────────────────────────────────
 # │ Plugin             │ Section              │ Lines │ Refs │ Action
───┼────────────────────┼──────────────────────┼───────┼──────┼──────────────────
 1 │ makato-build       │ Hard Constraints     │    12 │    0 │ KEEP (canonical)
 2 │ makato-build       │ Infrastructure       │    45 │    0 │ BLOAT
 3 │ makato-orchestrate │ Webhook dispatch...  │    38 │    1 │ KEEP (has ref)
──────────────────────────────────────────────────────────────────────
Actions: KEEP×N  BLOAT×N  REDUNDANT×N  MOVE-TO-SKILL×N
```

**permissionMode report:**
```
permissionMode Report (N agents across M plugins)
──────────────────────────────────────────────────────────────────────
 # │ Plugin       │ Agent            │ permissionMode      │ disallowedTools │ Action
───┼──────────────┼──────────────────┼─────────────────────┼─────────────────┼──────────────────
 1 │ makato-build │ coder            │ bypassPermissions   │ (none)          │ OK (write-capable)
 2 │ makato-build │ gate-scout       │ bypassPermissions   │ Write,Edit,...  │ OK (read-only)
 3 │ makato-build │ runtime-qa       │ (not set)           │ (none)          │ MISSING_PM
──────────────────────────────────────────────────────────────────────
Actions: OK×N  MISSING_PM×N  READ_WRITE_MISMATCH×N
```

If **all findings are KEEP/OK**: print "All AGENTS.md sections are KEEP and all agents
are OK — no issues found." and exit 0.

### Step 3 — Approval gate

Prompt:

```
Review findings above. Proceed with detailed report? [y/N]
```

- **y / yes**: print the full detailed findings and any recommended actions.
- **anything else / no input**: print "No further action taken." and exit 0.

When `--non-interactive` is passed (or stdin is not a TTY): treat as rejection
and exit 0. This makes the skill safe to call from scripts.

### Step 4 — Detailed report (on approval)

For each non-KEEP/non-OK finding, print a structured recommendation:

```
Finding #N — BLOAT
  Plugin:   makato-build
  Section:  Infrastructure
  Lines:    45
  Refs:     0
  Reason:   Section is large and has no #NNN or specs/ cross-reference.
  Action:   Consider extracting to a dedicated skill or reference doc,
            or adding a cross-reference to the relevant spec.

Finding #N — MISSING_PM
  Plugin:   makato-build
  Agent:    runtime-qa
  Current:  permissionMode not set
  Reason:   Agent frontmatter has no permissionMode field.
  Action:   Add permissionMode: bypassPermissions (or appropriate mode)
            and disallowedTools if read-only.
```

This skill never mutates any file. All recommended actions are advisory.

## Examples

### Run against the current repo

```bash
/makato-contribute:harness-audit
```

### Run against a specific repo root

```bash
/makato-contribute:harness-audit /path/to/repo
```

### Classification only (no approval prompt)

```bash
bash plugins/makato-contribute/scripts/harness-audit.sh
```

### Non-interactive (safe for scripts)

```bash
/makato-contribute:harness-audit --non-interactive
```

## Smoke tests

```bash
plugins/makato-contribute/scripts/harness-audit-smoke-tests.sh
```

Covers: KEEP/BLOAT/OK/MISSING_PM/READ_WRITE_MISMATCH/known-write-capable,
non-interactive flag, empty plugins dir.

## See also

- `scripts/harness-audit.sh` — classification helper (pure classification, stdout-only)
- `scripts/harness-audit-smoke-tests.sh` — offline smoke tests
- `plugins/makato-orchestrate/skills/lesson-prune/SKILL.md` — analogous operator-gated curation skill for memory stores
