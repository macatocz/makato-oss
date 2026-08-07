---
name: sync-from-upstream
description: >-
  Use when synchronizing new or updated content from an upstream impact-market
  repo into the makato repo — applies naming remaps, strips
  impact-market-specific tooling references, and validates each migrated file
  against makato conventions before writing. Trigger keywords: upstream sync,
  migrate skill, migrate plugin, impact-market, daff-build, daff-shape, daff-cr.
version: "1.0.1"
argument-hint: "[upstream-repo-path]"
allowed-tools: [Bash]
metadata:
  last_updated: "2026-08-05"
---

# sync-from-upstream

Migrate skills, agents, and plugin files from an upstream impact-market repo into makato while applying all naming remaps, tooling substitutions, and makato conventions. Produces a change plan for user review before any files are written.

## When to Use

- New content (skills, agents, references, shared files) appears in impact-market that should be adopted in makato
- Existing upstream content was updated and the delta needs to be pulled in
- A brand-new plugin in impact-market should be ported as a makato plugin

## When NOT to Use

- makato-specific additions (LangGraph skills, dotx-schema, manage-pdf, manage-microsoft-excel) — these have no upstream equivalent; do not "reverse-sync" them
- Content that was deliberately diverged — check `@references/deliberate-divergences.md` first

---

## Workflow

### Phase 1: Scope Discovery

#### Step 1: Confirm Repositories

Invoke `AskUserQuestion` with:
- question: "What is the path to the upstream impact-market repository?"
- options: ["../impact-market (default)", "Specify a custom path"]

Resolve both paths absolutely and verify they exist:
- Upstream: `<upstream-root>/plugins/`
- Makato: `<makato-root>/plugins/`

**Error: upstream repo not found** — if the resolved path does not exist or has no `plugins/` subdirectory, halt immediately and report the full path tried. Do not proceed to Step 2.

#### Step 2: Map Upstream Plugins to Makato Plugins

> MANDATORY: Load `@references/plugin-map.md` at this step, before mapping any plugin.
> Do NOT load this reference after Step 3 — plugin mapping is only needed during discovery.

For each upstream plugin directory (`daff-*`), look up its makato counterpart in the loaded plugin-map.

If the upstream plugin has no mapping entry, invoke `AskUserQuestion` with:
- question: "Plugin '<name>' has no makato counterpart. How should it be handled?"
- options: ["Create a new makato plugin for it", "Skip this plugin"]

#### Step 3: Compute the Sync Delta

For each plugin pair, compare upstream files against makato files:

1. **New in upstream only** — candidate for migration
2. **Different content** — candidate for update (show diff summary)
3. **Identical** — skip (no change needed)
4. **Only in makato** — makato-specific; preserve untouched

Use `find <plugin>/skills -name "*.md"` and `find <plugin>/agents -name "*.md"` for both sides. Also check: `shared/`, `hooks/`, `contracts/`, `.claude-plugin/plugin.json`, `README.md`, `AGENTS.md`, `CLAUDE.md`.

Group results:
```
NEW (upstream only):
  daff-contribute/skills/daff-skill-creator  →  makato-contribute/skills/makato-skill-creator [REMAPPED]

UPDATED (content changed):
  daff-build/skills/build-start/SKILL.md     →  makato-build/skills/build-start/SKILL.md

MAKATO-ONLY (skip):
  makato-build/skills/langgraph-*
  makato-core/skills/dotx-schema-extractor
  makato-core/skills/manage-microsoft-excel
  makato-core/skills/manage-pdf
```

**Error: no changes found** — if all files are identical or makato-only, report "No sync needed — upstream is identical to makato for all mapped plugins" and stop.

Present the delta summary, then invoke `AskUserQuestion` with:
- question: "Proceed with migration planning for these items?"
- options: ["yes — plan all", "no — abort", "select — I will name specific items to include"]

---

### Phase 2: Build Migration Plan

> MANDATORY: Load `@references/deliberate-divergences.md` before planning any file — new or updated. Do NOT skip for new files: a new upstream file may replicate a behavior makato intentionally changed.

#### Step 4: Apply Naming Remaps

> MANDATORY: Load `@references/naming-map.md` now. Apply every substitution category in that file — brand, tooling, issue-tracking, documentation-platform, internal-tool — to all file content, frontmatter, prose, and code comments.
> Do NOT load naming-map.md in Phase 1; no substitutions are applied during discovery.

**Critical semantic traps** — substitutions that silently corrupt meaning if applied mechanically:

- `impact` as a plain noun ("the impact if wrong", "high-impact change") must **never** become `makato`. Only replace `impact-market` (the org/repo name).
- `shape` as a verb or generic noun ("the shape of the data", "repositories.yml using the shape defined in") must **never** become `plan`. Only replace `daff-shape` (the plugin name).
- When a substitution would change the semantic meaning of a sentence, rewrite the sentence to be makato-accurate rather than doing a mechanical find-replace.

#### Step 5: Validate Per-File Rules

> MANDATORY: Load `@references/validation-rules.md` now. Apply every check defined there.
> Do NOT load validation-rules.md before Step 5 — files are not ready to validate until substitutions are complete.

Key checks (full detail in validation-rules.md):
1. SKILL.md frontmatter: `name` matches `[a-z0-9-]`; `description` starts with "Use when"
2. plugin.json: `name` matches `^makato-[a-z][a-z0-9-]*$`; `author.name` is `"makato Team"`
3. No garbled substitutions — cross-check against the semantic trap list in Step 4

#### Step 6: Present Migration Plan

Show a structured plan:

```
Migration Plan
==============

FILES TO CREATE (new in upstream):
  plugins/makato-change/skills/analyze/references/question-identification-guide.md
    - Source: daff-cr/skills/analyze/references/question-identification-guide.md
    - Substitutions: JIRA_KEY→ISSUE_KEY (3), daff-cr→makato-change (1)

FILES TO UPDATE (content changed):
  plugins/makato-build/skills/build-start/SKILL.md
    - Upstream diff: +15 -3 lines
    - Substitutions: daff-shape→makato-plan (4), DCP-1234→ISSUE-1234 (2)

FILES TO SKIP (makato-only):
  plugins/makato-build/skills/langgraph-fundamentals/ (no upstream equivalent)
  plugins/makato-build/skills/langgraph-agent-patterns/ (no upstream equivalent)

PLUGIN.JSON UPDATES:
  plugins/makato-change/.claude-plugin/plugin.json
    - name: "daff-cr" → "makato-change" (currently wrong)
    - author.name: "DCP DAFF Team" → "makato Team"
```

Invoke `AskUserQuestion` with:
- question: "Approve this migration plan?"
- options: ["yes — execute now", "no — abort", "edit — I will describe changes to the plan"]

**If "edit" is selected:** invoke `AskUserQuestion` to ask what changes to make (free text). Apply requested edits and re-present the revised plan (loop back to Step 6). Do NOT proceed to Phase 3 until the user selects "yes".

Do NOT write any files until the user explicitly approves.

---

### Phase 3: Execute

#### Step 7: Write Files

For each approved file:
1. Apply all substitutions from Step 4
2. Write to the makato path
3. Report each file written: `✓ written: plugins/<path>`

If writing an **update** (not a new file): show the diff summary to the user before overwriting. Only overwrite after per-file confirmation.

#### Step 8: Verify plugin.json Fields

For any plugin where new skills were added, verify that `.claude-plugin/plugin.json` has the correct `name`, `description`, and `author` fields per `@references/naming-map.md`.

Do NOT add a `skills` array — Claude Code discovers skills from the directory structure automatically. No real `plugin.json` in the makato repo contains a `skills` field; adding one would introduce a stale field that `plugin-json-template.md` explicitly forbids.
```

#### Step 9: Post-Migration Validation

After all files are written, run final grep-based checks across all written files:

```bash
grep -rn "daff\|ITDB\|Confluence\|DCP\|github\.tools\.sap" <written files>
```

Report findings. For each hit:
- **False positive** (e.g., the word appears inside a code block explicitly describing the upstream system): note it and explain
- **Real miss**: fix it immediately, then re-run the grep to confirm clean

#### Step 10: Summary

Print a migration summary:

```
Sync Complete
=============
✓ Created: 3 files
✓ Updated: 2 files
  Skipped: 8 files (makato-only)
⚠ Manual review needed: 1 file (see notes)

Notes:
- makato-change/skills/orchestrate/SKILL.md: Jira MCP tool calls replaced
  with gh CLI equivalents — verify tool names match your environment.
```

---

## Anti-patterns

**NEVER overwrite makato-only additions with upstream content**
WHY: makato has LangGraph skills, dotx-schema-extractor, manage-pdf, and other files with no upstream equivalent. Overwriting them deletes working production skills. The MAKATO-ONLY classification in Step 3 exists precisely for this reason; skipping it is silent data loss.

**NEVER apply brand substitutions mechanically across all occurrences**
WHY: The words `impact`, `shape`, and `DCP` are plain English in many contexts. Blind find-replace produces `"the makato if wrong"` (mangled from `"the impact if wrong"`) and `"using the plan defined in"` (mangled from `"using the shape defined in"`). These pass the Step 9 grep check but silently corrupt meaning that only a careful human reader would catch — often much later.

**NEVER write files before the user approves the migration plan**
WHY: Substitution rules touch hundreds of strings across multiple files simultaneously. A missed deliberate-divergence entry or a garbled sentence discovered after writing requires a rollback or a second corrective pass. The approval gate in Step 6 is the only point where structural problems (wrong target path, divergence collision, skipped file) are visible before any disk state changes.

**NEVER skip loading `@references/deliberate-divergences.md` before planning updates**
WHY: Some makato files diverge intentionally from upstream — e.g., skill-plan.html is placed in `references/` in makato but explicitly excluded in upstream ADR-0014. Syncing without checking this reference silently restores upstream behavior that was deliberately overridden, breaking downstream workflows that depend on makato's behavior.

**NEVER add migration-provenance comments to migrated files**
WHY: Comments like `# migrated from daff` add noise with no utility — the git history captures the commit context. More critically, they contain the word `daff` and will fail the brand-cleanliness grep in Step 9, triggering false-positive remediation work that obscures real misses.

**NEVER bump a SKILL.md version for a purely mechanical sync**
WHY: Version bumps signal behavioral changes to consumers. A sync that only substitutes `daff-cr → makato-change` does not change what the skill does; bumping the version misleads operators who use version diffs to assess upgrade impact.

---

## Known Divergences

Load `@references/deliberate-divergences.md` for the complete and authoritative list. High-priority cases to check on every sync:

| makato file | Upstream file | Divergence |
|-------------|---------------|------------|
| `makato-skill-creator` Step 14 | `daff-skill-creator` Step 14 | makato copies skill-plan.html into references; upstream does not |
| `create-prd` argument-hint | `daff-shape`: `[ITDB-KEY]` | makato uses `[slug]` (no ITDB) |
| `makato-plan/publish` | `daff-shape/publish` | makato: GitHub Issues only; upstream: Jira + Confluence |
| `makato-core/skills/excalidraw/` | `daff-shape` excalidraw | makato hosts in core AND plan — update both locations |
