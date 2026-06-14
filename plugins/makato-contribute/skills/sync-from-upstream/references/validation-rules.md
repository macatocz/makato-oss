# Validation Rules

Rules to verify after applying substitutions to any migrated file.

## 1. SKILL.md Frontmatter

- `name:` — must match `^[a-z][a-z0-9-]*$` (no uppercase, no underscores, no spaces)
- `description:` — must start with "Use when"
- Total frontmatter must be ≤ 1024 characters
- `version:` — must be present

## 2. plugin.json

- `name:` — must match `^makato-[a-z][a-z0-9-]*$`
- `author.name:` — must be `"makato Team"` (not "DCP AI Team", "DCP DAFF Team", etc.)
- `description:` — must not reference Jira, Confluence, or ITDB
- `skills` array — paths must exist on disk after migration

## 3. Brand Cleanliness Check

After migration, grep each written file for these patterns and flag any hit:

```bash
grep -in "daff\|ITDB\|Confluence\|github\.tools\.sap" <file>
```

For each match:
- Determine if it is a real miss or a false positive (e.g., explaining the upstream context)
- Real misses must be fixed before the migration is considered complete

## 4. DCP References

```bash
grep -in "\bDCP\b\|DCP-[0-9]\|DCP/" <file>
```

Allowed exceptions:
- `DCPL` in a comment explaining what was removed (for historical context in CHANGELOG files only)
- Inside a code block that is explicitly showing the before/after substitution

## 5. Semantic Integrity Check

These are mechanical rules that catch garbled substitutions:

| Pattern to find | Likely cause | Fix |
|-----------------|--------------|-----|
| `the makato if wrong` | "impact" noun replaced | Restore "impact" |
| `makato-market` | Redundant replacement | Should be just `makato` or `impact-market` |
| `using the plan defined in` (when context is file schema shape) | "shape" noun replaced with "plan" | Restore "shape" or rephrase |
| `makato if` followed by a conditional | "impact if" phrase mangled | Check surrounding context |

## 6. Cross-Plugin References

After migration, all cross-plugin skill invocations must use the correct makato namespace:

| Old pattern | Expected pattern |
|-------------|-----------------|
| `/daff-cr:orchestrate` | `/makato-change:orchestrate` |
| `/daff-shape:decompose` | `/makato-plan:decompose` |
| `/daff-build:build-start` | `/makato-build:build-start` |
| `use daff-shape for features` | `use makato-plan for features` |
| `use daff-fix for bugs` | `use makato-fix for bugs` (or remove if skill doesn't exist yet) |

## 7. Agent Files

Agent `.md` files must not reference upstream-only MCP tool names:

```bash
grep -in "mcp__plugin_daff-core_jira" <agent-file>
```

Replace Jira MCP calls with `gh issue view` / `gh api` equivalents.

## 8. Introduced-by-Sync Hygiene

Do not add these to migrated files:
- Comments saying "migrated from daff" — the git history captures this
- Version bumps to SKILL.md frontmatter unless the content actually changed beyond substitutions
- Empty sections or placeholder text
