<!-- markdownlint-disable MD013 MD032 MD040 -->
# makato-plan — Contributor Guide

## Hard Constraints

- **Never include implementation or coding skills.** Planning skills shape and decompose; they do not write source code or tests. Implementation belongs in `makato-build`.
- **Never add sprint/iteration management or backlog grooming.** makato-plan produces specs and stories; project management and status transitions belong to `makato-orchestrate`.
- **Read-only agents (`context-scout`) must carry `disallowedTools: Write, Edit, Bash, NotebookEdit`.** Never grant write access to a read-only agent.
- **All output artifacts (`stories.json`, `prd.md`, `design.md`, `created-issues.json`) are the authoritative inputs for `makato-build`.** Do not bypass them by writing plan-tier content directly into source trees.
- **`to-issues` is the canonical bridge to GitHub and must be idempotent.** Do not write ad-hoc issue-creation code; re-running must not create duplicates.
- **`decompose` output (`stories.json`) must not be mutated after `to-issues` has run.** It is the authoritative contract between shaping and development.
- **Opus-model skills must not be downgraded without a quality experiment.** Interview quality is the dominant cost driver — do not change a skill's model to save tokens without measurement.
- **`acceptanceTestCases[]` is QA-refined, not PO opinion.** Never substitute `successScenarios[]` for the test oracle — they serve distinct roles.
- **Cross-skill resources must live in `shared/` via symlink**, never via `../` paths. Cross-plugin sharing is not permitted.

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
- **Model selection:** long-form skills that drive multi-round interviews, run sub-agents in parallel, or make judgment-heavy slicing/architecture decisions declare `model: opus` (currently: brainstorming, grill, create-prd, create-architecture, create-prototype, create-ux, decompose). Short, structure-bound skills (to-issues, issue-to-project, create-acceptance-tests, excalidraw) inherit the session default. Don't change a skill's model without an explicit quality experiment — interview quality is the dominant cost, not token spend.
- **Cross-skill resources** live in `shared/` at the plugin root. Each consuming skill carries a symlink `skills/<name>/shared` → `../../shared`, so skill files reference resources as plain `shared/<file>.md` (no `../`). Claude Code's plugin cache preserves symlinks that resolve within the plugin's own directory ([docs](https://code.claude.com/docs/en/plugins-reference#share-files-within-a-marketplace-with-symlinks)) — no env-var dance needed. To add a new consumer: `cd plugins/makato-plan/skills/<name> && ln -s ../../shared shared`.
  - **Windows contributors:** ensure `git config --global core.symlinks true` (default on modern installs). To create the symlink without git, use `mklink /D shared ..\..\shared` from an elevated Command Prompt, or enable Developer Mode for unprivileged symlink creation.
  - Current contracts:
    - `shared/terminology.md` — plugin-level definitions for terms used in skill prose (audience: contributors and consumers reading the skills)
    - `shared/repositories-yml-schema.md` — schema for `repositories.yml` (used by create-prd, create-architecture, create-prototype, decompose)
    - `shared/scenario-schema.md` — Gherkin scenario shape (used by decompose's `successScenarios[]` and create-acceptance-tests' `acceptanceTestCases[]`)
    - `shared/refinement-contract.md` — rules for "Refine" update mode (used by create-prd, create-architecture, create-prototype, decompose)
- The plugin-level terminology reference is for human readers (consumers and contributors). Skills do **not** reference it at runtime — `@`-mentions in SKILL.md don't auto-load file content, and forcing a Read on every skill run wastes context. When introducing a term that needs explanation in a skill, add it to `shared/terminology.md` first; the runtime path for making this content available to agents is tracked separately (see GitHub issues).
- Distinct from the per-spec glossary written by `stress-test-artifact`: that file (`specs/{KEY}-{slug}/glossary.md`) is a runtime, feature-scoped artifact populated during interviews and read by other plan skills on entry. See the `stress-test-artifact` skill for its format and write-back rules.

## Agents

makato-plan dispatches read-only specialists for context discovery, multi-perspective story review, and artifact authoring:

| Agent                  | Model  | Purpose                                                                                                              | Used By                                  |
| ---------------------- | ------ | -------------------------------------------------------------------------------------------------------------------- | ---------------------------------------- |
| **context-scout**      | haiku  | Scan `context/{REPO_NAME}/` for files relevant to the current feature; returns a structured manifest                 | most plan skills                         |
| **acceptance-writer**  | sonnet | Refine draft Gherkin scenarios from decompose into polished, manually-testable acceptance test cases                 | create-acceptance-tests                  |
| **dev-reviewer**       | sonnet | Lead-developer perspective for Three Amigos review — challenges feasibility, dependencies, estimates                 | decompose (Three Amigos simulation), stress-test-artifact (story review)                     |
| **po-reviewer**        | sonnet | Product-owner perspective — challenges value delivery, scope boundaries, user outcomes, phase assignment             | decompose (Three Amigos simulation), stress-test-artifact (story review)                     |
| **qa-reviewer**        | sonnet | QA perspective — challenges testability, identifies edge cases, produces draft Gherkin scenarios                     | stress-test-artifact (story review), decompose          |
| **prototype-builder**  | opus   | Generate high-fidelity interactive HTML prototypes from design context and UX decisions                              | create-prototype, create-ux              |
| **doc-writer**         | sonnet | Generate styled HTML review documents and write canonical markdown artifacts from structured input                   | most plan skills                         |

### Agent Design Principles

- Read-only by default. Skills that mutate artifacts (PRD, ADRs, GitHub issues) own those writes; agents return content for the calling skill to commit.
- Model selection: haiku for discovery/scanning, sonnet for review/synthesis, opus only for prototype-builder (creative generation).
- Agent versioning: bump `version` in agent frontmatter per feature PR.

## File Structure

```
makato-plan/
├── .claude-plugin/
│   └── plugin.json
├── agents/
│   ├── acceptance-writer.md
│   ├── context-scout.md
│   ├── dev-reviewer.md
│   ├── doc-writer.md
│   ├── po-reviewer.md
│   ├── prototype-builder.md
│   └── qa-reviewer.md
├── skills/
│   ├── brainstorming/
│   ├── create-acceptance-tests/
│   ├── create-architecture/
│   ├── create-prd/
│   ├── create-prototype/
│   ├── create-ux/
│   ├── decompose/
│   ├── excalidraw/
│   ├── stress-test-artifact/
│   ├── issue-to-project/
│   └── to-issues/
├── shared/
│   ├── refinement-contract.md
│   ├── repositories-yml-schema.md
│   ├── scenario-schema.md
│   └── terminology.md
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

## Skill Routing — recommended_skills[] emission (agent-skill-routing #146)

`decompose` emits an optional `recommended_skills[]` array per sub-task in `stories.json`
when the sub-task title or description matches an archetype key in
`plugins/makato-plan/config/task-skill-map.json` (Step 7.11 of the decompose SKILL.md).

**Contract rules:**

- Match is case-insensitive substring against archetype keys.
- If matched: the sub-task carries `"recommended_skills": ["plugin:skill-id", ...]`.
- If no match: the field is **omitted entirely** — callers check `if "recommended_skills" in sub_task` (presence, not truthiness); an empty array is never written.
- **Backward-compatible**: when `task-skill-map.json` is absent or unreadable, decompose silently skips the lookup and produces `stories.json` without `recommended_skills` on any sub-task.
- Downstream consumers (`build-refine` → `build-implement-tdd` / `build-implement-goal` → `coder`) treat `recommended_skills` as an optional pass-through field. They never HALT on its absence.

`plugins/makato-plan/config/task-skill-map.json` is the authoritative source. It contains
≥ 200 archetype entries covering all 11 plugin domains, maintained manually; auto-generation
from F1 aggregate data is out of scope (see #146).

## PR Checklist

- [ ] Serves the plugin goal: shapes features into functionally-clear stories
- [ ] Skills are self-contained
- [ ] README Workflow section updated (new/changed skills must be documented with their step, input, and output)
- [ ] CHANGELOG updated
- [ ] Conventional commit title: `type(makato-plan): description`
