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
  pipeline. WHEN: after every 3-5 plugin additions, periodic harness
  health review, or when AGENTS.md bloat or permissionMode drift is
  suspected. TRIGGERS: harness audit, AGENTS.md bloat, permissionMode
  drift, harness health, agent whitelist check.
version: "1.0.0"
argument-hint: "[--non-interactive]"
allowed-tools: Read Bash Glob
metadata:
  Authors: Zdenek Stary
  last_updated: "2026-08-05"
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

### Mode selection

```
Has the user asked to run a quick classification only (no report)?
  YES → run Step 1 + Step 2 only, skip Step 3 and Step 4
        (or pass --non-interactive flag directly to the script)
  NO  → run full workflow Steps 1–4

Does output include MOVE-TO-SKILL findings?
  YES → MANDATORY: load plugins/makato-orchestrate/skills/lesson-prune/SKILL.md
        for guidance on analogous operator-gated curation of content stores
  NO  → Do NOT load lesson-prune/SKILL.md; no sub-skills are pre-loaded by default

Is the user running against a repo other than the current working tree?
  YES → pass REPO_ROOT explicitly in Step 1 (e.g. /path/to/repo)
  NO  → omit; git rev-parse --show-toplevel is used automatically
```

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

**MOVE-TO-SKILL heuristic:** fires on heading text containing `contract`, `propagation`,
`dispatch table`, `runtime contract`, or `dispatch chain` — body text is not scanned.
A section whose heading does not match but whose body describes runtime contracts
is still BLOAT, not MOVE-TO-SKILL.

### Classification Tiebreakers

These edge cases have fixed resolution — two audit runs must produce the same result:

| Situation | Resolution |
|---|---|
| AGENTS.md total lines = exactly 150 | KEEP — threshold check is `total ≤ 150`; 151+ triggers bloat scan |
| Canonical heading appears as a sub-section (`### Hard Constraints` inside `## Deployment`) | KEEP — canonical check normalizes and strips heading level markers |
| `#NNN` or `specs/` ref appears only inside a code fence | KEEP — ref regex scans all text including code blocks; one match anywhere suppresses BLOAT |
| Section heading matches canonical set but section is empty (0 lines) | KEEP — canonical check runs before line count; empty canonical sections are structural |
| New write-capable agent not yet in script whitelist | READ_WRITE_MISMATCH — the SKILL.md table and `scripts/harness-audit.sh` WRITE_CAPABLE_AGENTS set must be updated together; doc-only update creates persistent false positives |

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

## Anti-patterns

Each item below is a non-obvious failure mode. Generic warnings are omitted.

**NEVER classify a section REDUNDANT because two plugins cover the same topic.**
REDUNDANT requires near-identical sentences or constraints — not shared subject matter.
Cross-plugin boundary repetition is intentional: each plugin must be self-contained.
Misapplying REDUNDANT silently deletes the deliberate isolation that prevents
cross-plugin coupling; the section's presence in two places is signal, not noise.

**NEVER conclude a section is BLOAT solely because it contains an embedded code block
or table.**
The 150-line threshold counts all lines including markup. A section with 80 prose lines
and a 40-line code example totals 120 lines of content — but the cross-ref check and
canonical check still apply to those 120 lines. A code block that is the entire value
of the section (showing the canonical file layout, for instance) should prompt a
MOVE-TO-SKILL check before a BLOAT verdict, not a reflexive extraction.

**NEVER update the SKILL.md write-capable whitelist without also updating
`WRITE_CAPABLE_AGENTS` in `scripts/harness-audit.sh`.**
The script is the authoritative classifier. A doc-only update leaves the script
producing READ_WRITE_MISMATCH for every agent added; the next audit will produce
findings that cannot be resolved because the whitelist change never landed in code.

**NEVER invoke this skill from an automated pipeline or CI job.**
The approval gate at Step 3 checks `sys.stdin.isatty()`. Non-TTY stdin exits 0
with no output — not a report. Wiring harness-audit into automation produces
silent no-ops, creating false assurance that a real audit ran.

**NEVER surface a BLOAT finding for a section where `refs > 0` is present but
the ref lands inside a commented-out line or a `<!-- -->` HTML comment.**
The ref regex `#\d+|specs/` matches any occurrence in file text, including HTML
comments. A `<!-- TODO: link to #123 -->` comment is not a meaningful spec reference.
If all refs in a section are inside comments, treat refs as 0 for audit purposes
and classify normally by threshold.

## Workflow

### Step 1 — Classify

```bash
REPO_ROOT="${1:-$(git rev-parse --show-toplevel)}"
FINDINGS="$(bash "$REPO_ROOT/plugins/makato-contribute/scripts/harness-audit.sh" "$REPO_ROOT")"
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

Note: a plugin with no `agents/` directory emits only AGENTS.md findings. A plugin
missing its `AGENTS.md` entirely emits no findings for that plugin — the audit is
silent on absent files; the pre-commit gate enforces presence at commit time.

### Step 1b — Guard against script failure

Check the exit code and output of Step 1 before continuing:

| Condition | Action |
|---|---|
| Exit non-zero | Halt with: `harness-audit.sh failed (exit N). Check that REPO_ROOT is a valid makato repo and that Python 3 is available.` |
| `$FINDINGS` is empty and `plugins/` dir exists | Print: `No AGENTS.md or agent files found under plugins/. Nothing to audit.` and exit 0. |
| Any line in `$FINDINGS` is not valid JSON | Halt with: `harness-audit.sh emitted malformed output on line N: <line>. Run the script directly and inspect stderr for the cause.` |

The script exits 0 in all classification-only scenarios (including empty plugins dir).
A non-zero exit signals a fatal environment problem (Python not found, I/O error).

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

Use `AskUserQuestion` with the following options:

> Review findings above. Proceed with the detailed per-finding report?

- **Yes** — print the full detailed findings and any recommended actions (Step 4).
- **No** — print "No further action taken." and exit 0.

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
REPO_ROOT=$(git rev-parse --show-toplevel)
bash "$REPO_ROOT/plugins/makato-contribute/scripts/harness-audit.sh" "$REPO_ROOT"
```

### Non-interactive (safe for scripts)

```bash
/makato-contribute:harness-audit --non-interactive
```

## Smoke tests

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
bash "$REPO_ROOT/plugins/makato-contribute/scripts/harness-audit-smoke-tests.sh"
```

Covers: KEEP/BLOAT/OK/MISSING_PM/READ_WRITE_MISMATCH/known-write-capable,
non-interactive flag, empty plugins dir.

## See also

- `scripts/harness-audit.sh` — classification helper (pure classification, stdout-only)
- `scripts/harness-audit-smoke-tests.sh` — offline smoke tests
- `plugins/makato-orchestrate/skills/lesson-prune/SKILL.md` — analogous operator-gated
  curation skill for memory stores. **MANDATORY: load this when the audit produces any
  MOVE-TO-SKILL findings** — it documents the same human-gated curation contract for a
  different artifact type. **Do NOT load** for BLOAT-only or MISSING_PM-only runs.
