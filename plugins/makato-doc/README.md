# makato-doc

Documentation-authoring skills for the makato suite — library reference lookup, README
crafting, markdown authoring/linting, and Strunk-style prose editing. Extracted from
`makato-core` so documentation concerns live in one plugin and can be applied as
cross-cutting obligations across the suite.

## When to use

1. `context7` — look up current library/API documentation **before** writing code, instead
   of relying on training data.
2. `crafting-effective-readmes` — create, update, or review any `README.md`.
3. `markdown` — author and lint `.md` files (fences, tables, markdownlint compliance).
4. `writing-clearly-and-concisely` — tighten prose in docs, commit messages, and error text.

See [AGENTS.md](AGENTS.md) § *Documentation-skill obligations* (and the repo-root `AGENTS.md`
§ *Documentation skills*) for when each of these is **mandatory** rather than optional.

## Skills

| Skill | Description | Input | Output | Version |
|-------|-------------|-------|--------|---------|
| [`context7`](skills/context7/SKILL.md) | Retrieve up-to-date documentation for software libraries, frameworks, and components via the Context7 API. Use instead of training data for API syntax, code examples, or version-specific behaviour. | Library name and a specific query (e.g. `react / useState hook usage`); requires Context7 MCP server. | Current documentation snippets and code examples fetched from Context7 API, returned as inline text. | 1.0.0 |
| [`crafting-effective-readmes`](skills/crafting-effective-readmes/SKILL.md) | Guide for creating, updating, or reviewing README files for any project type (OSS, internal, personal, config). Applies template selection, style guide, and section-checklist workflow. (interactive) | Path to existing README or `new`; project type is inferred or asked. Loads internal templates and style guide from skill directory. | Written or updated `README.md` file on disk. | 1.4.1 |
| [`markdown`](skills/markdown/SKILL.md) | Author and lint `.md` files, fix markdownlint errors, and set up markdown tooling. Runs prettier then markdownlint in fixed order; loads `lint-rules.md` reference for violation diagnosis. (interactive) | File or directory path to format/validate; requires prettier and markdownlint-cli to be installed. | Formatted `.md` files on disk with lint violations fixed; suppression annotations added where warranted. | 1.3.1 |
| [`writing-clearly-and-concisely`](skills/writing-clearly-and-concisely/SKILL.md) | Edit prose for clarity using Strunk's rules, avoiding common AI writing patterns (passive voice, sentence-length convergence, puffery). Covers commit messages, error messages, and documentation. (interactive) | Text inline or a file path to edit. Loads `elements-of-style/` sections on demand. | Edited prose returned inline or written to file via Edit tool. | 1.4.0 |

## Skill routing

`config/skill-bundles.yml` maps changed-file globs to these skills for automatic injection:

| Bundle | Fires on | Injects |
|--------|----------|---------|
| `doc-code-docs` | source files (`**/*.py`, `**/*.ts[x]`, `**/*.js`) containing import/require statements | `context7` |
| `doc-readme` | `README.md`, `plugins/*/README.md` | `crafting-effective-readmes`, `writing-clearly-and-concisely` |
| `doc-markdown` | `plugins/**/*.md` mentioning markdownlint / MD013 / MD040 | `markdown` |
| `doc-skills` | this plugin's own skill files | all four |

Broad "every relevant agent" coverage that a `contains:`-guarded glob cannot express precisely
is carried by the AGENTS.md rules, which are the authoritative source.

## Dependencies

- Context7 MCP server (`plugin:context7`) — required by the `context7` skill. No MCP servers are
  bundled with makato-doc itself.

## Relationship to other plugins

| Direction | Plugin | What |
|-----------|--------|------|
| Produces for | `makato-build` | `context7` before writing code; `markdown` / `crafting-effective-readmes` / `writing-clearly-and-concisely` for doc tasks |
| Produces for | `makato-change` | same documentation obligations during change execution |
| Produces for | `makato-plan` | `context7` for library lookups; doc skills for artifact authoring |
| Sibling of | `makato-core` | core keeps suite infrastructure (`create-issue`, `makato-guide`, `map-codebase-context`) |
