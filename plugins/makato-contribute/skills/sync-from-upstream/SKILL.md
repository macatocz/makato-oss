---
name: sync-from-upstream
description: Use when synchronizing new or updated content from an upstream impact-market repo into the makato repo — applies naming remaps, strips impact-market-specific tooling references, and validates each migrated file against makato conventions before writing.
version: "1.0.0"
argument-hint: "[upstream-repo-path]"
---

# sync-from-upstream

Migrate skills, agents, and plugin files from an upstream impact-market repo into makato while applying all naming remaps, tooling substitutions, and makato conventions. Produces a change plan for user review before any files are written.

## When to Use

- New content (skills, agents, references, shared files) appears in impact-market that should be adopted in makato
- Existing upstream content was updated and the delta needs to be pulled in
- A brand-new plugin in impact-market should be ported as a makato plugin

## When NOT to Use

- makato-specific additions (LangGraph skills, dotx-schema, manage-pdf, manage-microsoft-excel) — these have no upstream equivalent; do not "reverse-sync" them
- Content that was deliberately diverged (see `@references/deliberate-divergences.md`) — check first

---

## Workflow

### Phase 1: Scope Discovery

#### Step 1: Confirm Repositories

Ask the user: **"What is the path to the upstream impact-market repository?"** (default: `../impact-market` relative to the makato root).

Resolve both paths absolutely and verify they exist:
- Upstream: `<upstream-root>/plugins/`
- Makato: `<makato-root>/plugins/`

#### Step 2: Map Upstream Plugins to Makato Plugins

Load `@references/plugin-map.md`.

For each upstream plugin directory (`daff-*`), determine its makato counterpart:

| Upstream | Makato |
|----------|--------|
| `daff-build` | `makato-build` |
| `daff-shape` | `makato-plan` |
| `daff-cr` | `makato-change` |
| `daff-core` | `makato-core` |
| `daff-contribute` | `makato-contribute` |

If the upstream plugin has no mapping entry, ask the user whether to create a new makato plugin or skip.

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

Present the delta to the user. Ask: **"Proceed with migration planning for these items? (yes / no / select)"**

---

### Phase 2: Build Migration Plan

#### Step 4: Apply Naming Remaps

For every file scheduled for migration, apply all renames from `@references/naming-map.md`:

**Brand substitutions (apply everywhere — file content, frontmatter, prose, code comments):**

| From | To |
|------|----|
| `daff` (as brand) | `makato` |
| `daff-build` | `makato-build` |
| `daff-shape` | `makato-plan` |
| `daff-cr` | `makato-change` |
| `daff-core` | `makato-core` |
| `daff-contribute` | `makato-contribute` |
| `daff-guide` | `makato-guide` |
| `daff-suite` | `makato-suite` |
| `daff-skill-creator` | `makato-skill-creator` |
| `daff-plugin-creator` | `makato-plugin-creator` |

**Do NOT blindly replace the word "daff" in all positions** — apply only when used as a brand/plugin identifier. The word may also appear in variable names or unrelated prose.

**Tooling substitutions:**

| From | To |
|------|----|
| `github.tools.sap` | `github.com` |
| `--hostname github.tools.sap` | *(remove this flag entirely)* |
| `DCP/<repo>` or `DCP/daff` | `sagibeast/makato` |
| `DCP AI Team` / `DCP DAFF Team` / `DCP makato Team` | `makato Team` |
| `DCP/` prefix in issue/PR references | *(remove — use bare repo path)* |

**Issue tracking substitutions:**

| From | To |
|------|----|
| `JIRA` / `Jira` / `jira` (as the tool/platform) | `GitHub Issues` |
| `ITDB-KEY` / `ITDB-1234` / `ITDB key` | `ISSUE-KEY` |
| `ITDB` (as the issue tracking project) | `GitHub Issues` |
| `DCP-55800` / `DCP-1234` (as example story keys) | `ISSUE-1234` (use generic format) |
| `mcp__plugin_daff-core_jira__*` | `gh issue view` / GitHub API |
| `JIRA_KEY` variable name | `ISSUE_KEY` |
| Jira MCP tool calls | GitHub `gh` CLI equivalents |
| `argument-hint: "[JIRA-KEY]"` | `argument-hint: "[ISSUE-KEY]"` |

**Documentation platform substitutions:**

| From | To |
|------|----|
| `Confluence` / `confluence` | *(remove — no equivalent in makato)* |
| `DCPL` (Confluence space) | *(remove)* |
| "publish to Confluence" | "publish to GitHub" or remove |

**Internal tool substitutions:**

| From | To |
|------|----|
| `@DCPAT-` tags | *(remove)* |
| `PI \| YY/QQ` component | *(keep — planning cadence concept is still valid)* |
| `github.tools.sap/DCP/makato` (README links) | `github.com/sagibeast/makato` |

#### Step 5: Validate Per-File Rules

After applying substitutions, check each migrated file against makato conventions (load `@references/validation-rules.md`):

1. **SKILL.md frontmatter**: `name` uses only `[a-z0-9-]`, `description` starts with "Use when...", max 1024 chars total
2. **plugin.json**: `name` matches `^makato-[a-z][a-z0-9-]*$`; `author.name` is `"makato Team"`
3. **No lingering brand terms**: grep for `daff`, `ITDB`, `DCP`, `Confluence`, `github.tools.sap`, `sagibeast/daff`
4. **No garbled substitutions**: watch for semantic distortion — e.g., `"the makato if wrong"` instead of `"the impact if wrong"`. The word "impact" as a noun (not a brand) must NOT be replaced.
5. **Cross-plugin references updated**: all `/daff-cr:orchestrate` → `/makato-change:orchestrate` style references updated

**Semantic substitution trap:** `impact` as a plain English noun (e.g., "the impact if wrong", "high-impact change") must never be replaced with `makato`. Only replace `impact-market` (the org/repo) and `daff` (the plugin brand prefix).

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

Ask: **"Approve this migration plan? (yes / no / edit)"**

Do NOT write any files until the user explicitly approves.

---

### Phase 3: Execute

#### Step 7: Write Files

For each approved file:
1. Apply all substitutions from Step 4
2. Write to the makato path
3. Report each file written: `✓ written: plugins/<path>`

If writing an **update** (not a new file): show the diff summary to the user before overwriting. Only overwrite after confirmation.

#### Step 8: Update plugin.json Skills Array

For any plugin where new skills were added, check `.claude-plugin/plugin.json` and add the new skill path to the `skills` array if not already present:

```json
{
  "skills": [
    "skills/existing-skill",
    "skills/new-skill"     ← add this
  ]
}
```

#### Step 9: Post-Migration Validation

After all files are written, run a final grep-based check across all written files:

```bash
grep -rn "daff\|ITDB\|Confluence\|DCP\|github\.tools\.sap" <written files>
```

Report findings. For each hit:
- If it's a **false positive** (e.g., the word appears inside a code block describing the upstream system): note it and explain
- If it's a **real miss**: fix it immediately

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

## Known Divergences

These are deliberate differences between makato and impact-market that must NOT be overwritten:

| makato file | Upstream file | Divergence |
|-------------|---------------|------------|
| `makato-build/skills/langgraph-*` | *(none)* | makato-only LangGraph skills |
| `makato-core/skills/dotx-schema-extractor/` | *(none)* | makato-only skill |
| `makato-core/skills/manage-microsoft-excel/` | *(none)* | makato-only skill |
| `makato-core/skills/manage-pdf/` | *(none)* | makato-only skill |
| `makato-core/skills/excalidraw/` | `daff-core` has none; `daff-shape` has one | Moved to core in makato |
| `makato-skill-creator` Step 14 | `daff-skill-creator` Step 14 | makato copies skill-plan.html into references; upstream does not |
| `create-prd` argument-hint | `daff-shape`: `[ITDB-KEY]` | makato uses `[slug]` (no ITDB) |

Load `@references/deliberate-divergences.md` for the full list before Phase 2.

---

## Semantic Substitution Rules

**Never replace blindly.** These words require context judgment:

| Word | When to replace | When NOT to replace |
|------|----------------|---------------------|
| `daff` | Used as plugin brand prefix (`daff-build`, `daff-shape`) | Part of an unrelated word or acronym |
| `impact` | Only in `impact-market` (org/repo name) | Plain noun: "the impact if wrong", "high-impact", "business impact" |
| `shape` | Only in `daff-shape` (plugin name) → `plan` | Used as a verb or general noun: "the shape of the data", "write repositories.yml using the shape defined in..." |
| `DCP` | Team name / Confluence space / key prefix | Acronym used for a different concept |
| `Jira` / `JIRA` | Issue tracker platform name | Generic noun meaning "issue list" in a non-tool-specific context |

When substitution would change the semantic meaning of a sentence, prefer rewriting the sentence to be makato-accurate rather than doing a mechanical find-replace.
