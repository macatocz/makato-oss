<!-- markdownlint-disable MD013 -->
# Changelog — makato-doc

Changes are grouped by skill/component. Within each group, latest version on top. Each version block lists one sub-bullet per logical change. Until per-PR version automation is in place, entries land here on merge to main; release-please will date and version them at the next release cut.

---

## Plugin-level

- **Added** `makato-doc` plugin — extracted the documentation-authoring skills (`context7`, `crafting-effective-readmes`, `markdown`, `writing-clearly-and-concisely`) out of `makato-core`, so documentation concerns live in one plugin and can be applied as cross-cutting obligations. Skill directories moved via `git mv` (history preserved); skill identifiers unchanged, only the `plugin:skill` prefix changed from `makato-core:` to `makato-doc:`.
- **Added** `config/skill-bundles.yml` — bundles `doc-skills`, `doc-readme`, `doc-markdown`, `doc-code-docs` route this plugin's skill files, README files, lint-bearing markdown, and source files (import/require-bearing) to the appropriate documentation skills. Wide globs (`plugins/**/*.md`, `**/*.py`) carry `contains:` predicates per the skill-bundle authoring rule.
- **Added** `AGENTS.md` § *Documentation-skill obligations* — states when `context7` (every code-creating agent), `crafting-effective-readmes` (README changes), and `markdown` + `writing-clearly-and-concisely` (any `.md`) are mandatory. Mirrored suite-wide in the repo-root `AGENTS.md` § *Documentation skills*.

---

## `context7` — Library documentation lookup

- Moved from `makato-core` unchanged (v1.0.0).

## `crafting-effective-readmes` — README authoring

- Moved from `makato-core` unchanged (v1.4.1).

## `markdown` — Markdown authoring + linting

- Moved from `makato-core` unchanged (v1.3.1).

## `writing-clearly-and-concisely` — Prose editing

- Moved from `makato-core` unchanged (v1.4.0).
