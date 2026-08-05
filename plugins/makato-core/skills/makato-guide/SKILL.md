---
name: makato-guide
description: >-
  Discover installed makato plugins, list available skills, and help users find
  the right tool for their task — help, guide, what can makato do, list plugins,
  find skill, makato overview. Do NOT use when the user is asking about a
  specific codebase file, module, or implementation detail (use
  map-codebase-context instead).
version: "1.3.0"
metadata:
  authors: [makato-core]
  last_updated: "2026-08-05"
argument-hint: "[plugin name | task description | 'overview']"
---

# makato-guide

## Mindset

Treat `plugin.json` + `SKILL.md` frontmatter as the **only** authoritative sources. Never infer from training-data knowledge of makato — skills, plugins, and descriptions change with every release. If a file is absent, that information does not exist; do not fill the gap from memory.

## When to Use

- User asks what makato can do or which plugins are available
- User needs to know which skill handles a specific task
- User is new to makato and wants an orientation
- User wants to understand the plugin landscape before starting work

## Discovery

Scan `plugins/` at the repository root for directories matching `makato-*`.

For each discovered plugin directory:
1. Read `.claude-plugin/plugin.json` — extract `name`, `description` (the goal statement), `skills[]`, `version`; if the file is present but not valid JSON, skip the plugin and surface a warning naming the directory
2. For each entry in `skills[]`, read its `SKILL.md` — extract frontmatter `name`, `description`
3. Flag any skill with `deprecated: true` in its `SKILL.md` frontmatter (not in plugin.json)
4. Missing `plugin.json` → skip silently; missing `SKILL.md` → list skill as "undocumented"
5. Name collision: if two plugins declare skills with identical `name` values, retain both entries tagged with their plugin name — do NOT silently drop one; present both tagged in all responses

## Query Routing

```
Query type?
├── General ("what can makato do", "overview", "list plugins", "help")
│   → MANDATORY: load @references/suite-overview.md
│   → Present full plugin table (name / goal / skill count / version) + skills by plugin
│
├── Named plugin ("what skills does makato-plan have?")
│   → Filter discovery to that plugin only; Do NOT load suite-overview.md
│
├── Specific capability ("how do I create a plugin?", "I need to write a spec")
│   → Do NOT load suite-overview.md
│   → Match: exact skill name > keyword in skill name > keyword in skill description
│   → Single match: name the skill + exact invoke ("Use skill <name>" or "/<name>")
│   → Multiple matches: use AskUserQuestion with a selectable list of 2-3 candidates
│     (skill name + plugin name + one-line description per option); do not auto-select
│   → Name collision (same skill name in two plugins): use AskUserQuestion with both
│     options tagged by plugin name; never silently resolve to one
│   → No match: say so explicitly; suggest makato-skill-creator (adds skill to existing
│     plugin) or scaffold-plugin in makato-contribute (creates new plugin)
│
└── Named skill from an uninstalled plugin
    → Confirm the plugin directory is absent from plugins/; do not suggest the skill as
      ready to invoke; provide install command: claude --plugin-dir ./plugins/makato-<name>
```

## Invoke Guidance

- Deprecated skill found: always prepend a deprecation warning before any recommendation
- Skill found: state the exact invoke form (e.g., `Use skill makato-skill-creator` or `/build-start`)
- Expanding capabilities: `makato-skill-creator` adds a skill to an existing plugin; `scaffold-plugin` (in `makato-contribute`) creates an entirely new plugin — these are distinct tools often confused with each other

## Anti-Patterns

**NEVER write or modify any file during this skill.** `makato-guide` is declared read-only in AGENTS.md; any write would corrupt artifacts that the autonomous loop depends on and violates the plugin contract.

**NEVER fabricate a skill name that is not present in a discovered `SKILL.md`.** Only names found via plugin.json + SKILL.md frontmatter are valid; invented names produce broken slash commands (`/no-such-skill` silently fails) and erode user trust in the guide permanently.

**NEVER recommend a deprecated skill without a visible deprecation warning.** Deprecated skills may have breaking contracts or be removed entirely; a silent recommendation traps users in a dead-end workflow that cannot be completed.

**NEVER present the full suite table in response to a narrow specific-capability query.** Dumping all plugins when the user asked "how do I create a plugin?" forces the user to scan irrelevant rows; repeated noise trains users to stop invoking the guide.

**NEVER imply a skill from an uninstalled plugin is ready to invoke.** The user has no invocation path until the plugin directory exists under `plugins/`; always confirm presence before recommending, and provide the install command when absent.

**NEVER reuse or cache discovery results from a previous invocation.** `plugin.json` and `SKILL.md` change silently after a plugin install or update; a stale scan can recommend skills from the wrong plugin version, skills that no longer exist, or miss newly installed plugins entirely — with no error visible to the user.
