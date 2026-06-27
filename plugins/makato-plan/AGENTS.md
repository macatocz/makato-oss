<!-- markdownlint-disable MD013 MD032 MD040 -->
# makato-plan — Contributor Guide

## Goal

Transforms raw feature requests into vertically-sliced GitHub issues through structured discovery, interviews, architectural analysis, and UX design — producing acceptance-tested stories ready for development.

**How:** Guides users through progressive interviews and grilling sessions that brainstorm, analyze, produce a PRD, define architecture, design UX, decompose work into sliced stories, write acceptance tests, and publish those stories as GitHub issues wired to a GitHub Projects v2 board.

**Why:** Ensures features are thoroughly understood, architecturally sound, and broken into actionable work before development begins, reducing rework and misalignment.

## Shaping Boundary

Shaped = functionally clear, not implementation-planned. Stories exiting this plugin have:
- A clear functional description
- Acceptance criteria (including Gherkin-style tests where appropriate)
- Architectural context and guidance

They do NOT have:
- Detailed task breakdowns
- Implementation plans or technical refinement
- Sprint-level estimation

Development teams own that next step.

## What Belongs Here

- Skills, agents, hooks, and MCP servers that conduct structured interviews/grilling sessions to extract and clarify feature requirements
- Skills that produce PRDs, architecture documents, or design decisions from discovery output
- Skills and agents that decompose features into PI-sized epics and vertically-sliced stories with acceptance criteria
- Skills that gather and consolidate existing material (docs, context, prior art) about a feature
- Skills, hooks, and MCP servers that create or update GitHub issues and project-board items from shaped output

## What Does NOT Belong Here

- Implementation/coding skills (those belong in development-phase plugins)
- Detailed implementation task breakdowns or technical refinement beyond architectural guidance
- Skills that validate or review already-written code or PRs
- Sprint/iteration management or backlog grooming during development
- Skills that create makato plugins or skills (those belong in makato-contribute)
- Generic brainstorming or ideation not tied to a specific feature

## Decision Test

"Does this help transform a raw feature into shaped, functionally-clear stories with acceptance criteria?"
- Yes → it belongs here
- No → it belongs elsewhere

## Skill Authoring

- Self-contained: all references/templates inside the skill directory
- No `../` paths in skill files. Cross-skill content is exposed via a `shared/` symlink at the skill root that targets `../../shared` (the plugin-level `shared/` directory).
- References loaded at point of use, not front-loaded
- Frontmatter required: name, description, version
- **Model selection:** long-form skills that drive multi-round interviews, run sub-agents in parallel, or make judgment-heavy slicing/architecture decisions declare `model: opus` (currently: brainstorming, grill, create-prd, create-architecture, create-prototype, decompose). Short, structure-bound skills (publish, create-acceptance-tests) inherit the session default. Don't change a skill's model without an explicit quality experiment — interview quality is the dominant cost, not token spend.
- **Cross-skill resources** live in `shared/` at the plugin root. Each consuming skill carries a symlink `skills/<name>/shared` → `../../shared`, so skill files reference resources as plain `shared/<file>.md` (no `../`). Claude Code's plugin cache preserves symlinks that resolve within the plugin's own directory ([docs](https://code.claude.com/docs/en/plugins-reference#share-files-within-a-marketplace-with-symlinks)) — no env-var dance needed. To add a new consumer: `cd plugins/makato-plan/skills/<name> && ln -s ../../shared shared`.
  - **Windows contributors:** ensure `git config --global core.symlinks true` (default on modern installs). To create the symlink without git, use `mklink /D shared ..\..\shared` from an elevated Command Prompt, or enable Developer Mode for unprivileged symlink creation.
  - Current contracts:
    - `shared/terminology.md` — plugin-level definitions for terms used in skill prose (audience: contributors and consumers reading the skills)
    - `shared/repositories-yml-schema.md` — schema for `repositories.yml` (used by create-prd, create-architecture, create-prototype, decompose)
    - `shared/scenario-schema.md` — Gherkin scenario shape (used by decompose's `successScenarios[]` and create-acceptance-tests' `acceptanceTestCases[]`)
    - `shared/refinement-contract.md` — rules for "Refine" update mode (used by create-prd, create-architecture, create-prototype, decompose)
- The plugin-level terminology reference is for human readers (consumers and contributors). Skills do **not** reference it at runtime — `@`-mentions in SKILL.md don't auto-load file content, and forcing a Read on every skill run wastes context. When introducing a term that needs explanation in a skill, add it to `shared/terminology.md` first; the runtime path for making this content available to agents is tracked separately (see GitHub issues).
- Distinct from the per-spec glossary written by `grill`: that file (`specs/{KEY}-{slug}/glossary.md`) is a runtime, feature-scoped artifact populated during interviews and read by other plan skills on entry. See the `grill` skill for its format and write-back rules.

## File Structure

```
makato-plan/
├── .claude-plugin/
│   └── plugin.json
├── skills/
├── shared/
├── CLAUDE.md
├── AGENTS.md
├── CHANGELOG.md
└── README.md
```

## Versioning

- No `version` in plugin.json (repo versioned via release-please + git tags)
- Skill versions: bumped in SKILL.md frontmatter per feature PR
- Agent versions: bumped in agent frontmatter per feature PR
- CHANGELOG.md: updated with each PR

## PR Checklist

- [ ] Serves the plugin goal: shapes features into functionally-clear stories
- [ ] Skills are self-contained
- [ ] README Workflow section updated (new/changed skills must be documented with their step, input, and output)
- [ ] CHANGELOG updated
- [ ] Conventional commit title: `type(makato-plan): description`
