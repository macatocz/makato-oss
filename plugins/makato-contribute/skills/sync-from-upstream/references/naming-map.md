# Naming Map

Complete substitution table for migrating content from impact-market to makato.

## Plugin Brand Substitutions

Applied everywhere: file content, YAML frontmatter, prose, code blocks, comments.

| From (impact-market) | To (makato) |
|----------------------|-------------|
| `daff-build` | `makato-build` |
| `daff-shape` | `makato-plan` |
| `daff-cr` | `makato-change` |
| `daff-core` | `makato-core` |
| `daff-contribute` | `makato-contribute` |
| `daff-suite` | `makato-suite` |
| `daff-guide` | `makato-guide` |
| `daff-skill-creator` | `makato-skill-creator` |
| `daff-plugin-creator` | `makato-plugin-creator` |
| `daff` (standalone brand name) | `makato` |

## Team / Author Substitutions

| From | To |
|------|----|
| `DCP AI Team` | `makato Team` |
| `DCP DAFF Team` | `makato Team` |
| `DCP makato Team` | `makato Team` |

## Repository / Host Substitutions

| From | To |
|------|----|
| `github.tools.sap` | `github.com` |
| `--hostname github.tools.sap` | *(remove entire flag)* |
| `DCP/daff` | `sagibeast/makato` |
| `DCP/<anything>` in repo paths | `sagibeast/<anything>` |
| `https://pages.github.tools.sap/DCP/…` | `https://github.com/sagibeast/makato` |

## Issue Tracking Substitutions

| From | To |
|------|-----|
| `Jira` / `JIRA` / `jira` (the tool) | `GitHub Issues` |
| `ITDB-KEY` | `ISSUE-KEY` |
| `ITDB-1234` / `ITDB-{key}` | `ISSUE-1234` / `ISSUE-{key}` |
| `ITDB` as project name | `GitHub Issues` |
| `DCP-1234` as example issue key | `ISSUE-1234` |
| `JIRA_KEY` variable name | `ISSUE_KEY` |
| `argument-hint: "[JIRA-KEY]"` | `argument-hint: "[ISSUE-KEY]"` |
| `mcp__plugin_daff-core_jira__get_issue` | `gh issue view` |
| `mcp__plugin_daff-core_jira__get_remote_links` | `gh pr list` / GitHub API |
| `mcp__plugin_daff-core_jira__*` | Equivalent `gh` CLI command |
| `Use the Jira MCP tool only` | `Use the GitHub gh CLI` |
| `PR link should exist in Jira` | `PR link should exist as GitHub issue comment or linked PR` |
| `@DCPAT-` test tag | *(remove — no equivalent)* |

## Documentation Platform Substitutions

| From | To |
|------|-----|
| `Confluence` (the platform) | *(remove reference, or replace with "GitHub wiki" if the concept must be preserved)* |
| `DCPL` (Confluence space) | *(remove)* |
| "publish to Confluence" | "publish to GitHub" |
| `dcp-story-panels.md` template | *(remove — no equivalent)* |
| Confluence spec page | GitHub Issue or repository wiki |
| `confluence-page-template.md` | *(remove reference)* |

## Words That Must NOT Be Replaced

These words look like brand names but are plain English in many contexts:

| Word | Context where NOT to replace |
|------|------------------------------|
| `impact` | As noun: "the impact if wrong", "high-impact change", "business impact" |
| `shape` | As noun/verb: "the shape of the data", "shape the spec", "using the shape defined in" |
| `plan` | General noun — do not change to something else |
| `Jira` | When used as a generic synonym for "issue tracker" in non-tool-specific prose — use judgment |
| `DCP` | If used as a domain concept unrelated to the team name (unlikely, but check context) |

## Pattern Examples

**Correct:**
```
# Before (impact-market)
Run `/daff-cr:orchestrate` to start the change request workflow.
JIRA_KEY stored in memory.

# After (makato)
Run `/makato-change:orchestrate` to start the change request workflow.
ISSUE_KEY stored in memory.
```

**Correct (do NOT replace "impact" as noun):**
```
# Before (impact-market)
Assess the impact if wrong.

# After (makato) — unchanged, "impact" is a plain noun
Assess the impact if wrong.
```

**Incorrect (garbled substitution — avoid this):**
```
# Wrong
Assess the makato if wrong.   ← "impact" was blindly replaced
```
