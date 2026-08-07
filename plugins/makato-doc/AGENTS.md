# makato-doc — Contributor Guide

## Hard Constraints

- **Never author source code.** Documentation skills produce prose, markdown, and structure — not implementation code.
- **Suite infrastructure (issue filing, plugin discovery, codebase navigation) belongs in `makato-core`, not here.** Do not duplicate those utilities.
- **Workflow logic and domain-specific skills belong in their respective plugins.** makato-doc handles documentation only.
- **Documentation written must not contradict the source of truth** (`AGENTS.md`, skill SKILL.md frontmatter, `CHANGELOG.md`). When in doubt, read before writing.
- **Skills that run as standalone build sessions must emit JSONL audit entries** — session start, each major step, session end. Doc-utility skills (context7, markdown, crafting-effective-readmes, writing-clearly-and-concisely) are invoked from within makato-build or makato-change sessions; the invoking skill's `build.jsonl` already covers the audit trail for those invocations. The self-emit requirement applies to any future doc skill that runs as a standalone build session (i.e. has its own `session start`/`session end` lifecycle rather than being called as a sub-step).

## Goal

Provide the documentation-authoring skills every makato plugin relies on — library
reference lookup, README crafting, markdown authoring/linting, and prose editing.
These skills were extracted from `makato-core` so that documentation concerns live in
one plugin and can be treated as cross-cutting obligations for the whole suite.

## What Belongs Here

- Skills that produce or improve human-facing documentation and prose
- Skills that fetch external reference material used while writing code or docs
- Shared style guides / templates backing those skills (inside each skill directory)

## What Does NOT Belong Here

- Suite infrastructure (issue filing, plugin discovery, codebase navigation → `makato-core`)
- Workflow logic or domain-specific skills (belong in a workflow/domain plugin)
- Anything that authors code rather than documentation

## Documentation-skill obligations

These four skills are **cross-cutting obligations**, not opt-in conveniences. The same
rules are stated suite-wide in the repo-root `AGENTS.md` (§ *Documentation skills*, emitted
by `scripts/regenerate-agents.sh`) so every agent sees them:

| Skill | When it is mandatory |
|-------|----------------------|
| `context7` | **Every code-creating agent**, before writing code that touches a library, framework, SDK, or API — look up current docs via Context7 instead of relying on training data. |
| `crafting-effective-readmes` | Whenever a `README.md` is created or updated. |
| `markdown` | Whenever any `.md` file is authored or edited (structure, fences, lint compliance). |
| `writing-clearly-and-concisely` | Whenever prose is written or edited in any `.md` (or commit/error messages). |

`config/skill-bundles.yml` encodes the machine-routable subset of these obligations
(`doc-code-docs` → context7 near source files; `doc-readme` → README skills; `doc-markdown`
→ markdown on lint-bearing files). Broad "every file" coverage that a `contains:`-guarded
glob cannot express precisely is carried by the AGENTS.md rules above — that is the
authoritative source.

## Skill Authoring

- Self-contained: all references/templates inside the skill directory
- No `../` paths outside the skill dir (except `../shared/` within this plugin, if added)
- Frontmatter required: name, description, version (semver)

## File Structure

```
makato-doc/
├── .claude-plugin/plugin.json
├── config/skill-bundles.yml
├── skills/
│   ├── context7/                      # Library documentation lookup via Context7 MCP
│   ├── crafting-effective-readmes/    # README authoring guide
│   ├── markdown/                      # Markdown authoring + linting
│   └── writing-clearly-and-concisely/ # Strunk-style prose editing
├── CLAUDE.md
├── AGENTS.md
├── CHANGELOG.md
└── README.md
```

## Versioning

- No `version` in plugin.json (repo versioned via release-please + git tags)
- Skill versions: bumped in SKILL.md frontmatter per feature PR
- CHANGELOG.md: updated with each PR

## PR Checklist

- [ ] Serves documentation authoring, not code authoring or suite infrastructure
- [ ] Skills are self-contained (no `../` escapes)
- [ ] Skill frontmatter present (name, description, version-semver)
- [ ] `config/skill-bundles.yml` bundles keep plugin-prefixed names; wide globs carry `contains:`
- [ ] Documentation-skill obligations kept in sync with repo-root AGENTS.md § *Documentation skills*
- [ ] CHANGELOG updated
- [ ] Conventional commit title: `type(makato-doc): description`
