# makato-ux — Contributor Guide

## Goal

Transform built code into a production UX platform.

**How:** Discovers existing code and design system, applies the prototype
pattern from create-prototype, and produces a deployable UI layer —
HTML/CSS, React components, and JavaScript — verified by browser-based
testing via Playwright.

**Why:** Provides a graphical interface above code artifacts without
requiring UX skills from the engineer — closing the gap between working
backend code and a shippable user-facing product.

## What Belongs Here

- Frontend deployment — bundling, hosting, and CI/CD for UI artifacts
- UI design — translating specs and design tokens into styled components
- Webapp testing — browser-based functional and visual regression tests
  via Playwright
- HTML/CSS creation — markup and styling for UI surfaces
- React and JavaScript — component authoring, state management, and
  interactivity

## What Does NOT Belong Here

- Prototypes and mockups — exploratory HTML for UX validation only
  (use makato-plan/create-prototype)
- Diagrams and flowcharts — architecture or workflow visualizations
  (use makato-plan)
- Backend or API implementation — server logic, database, infrastructure
  (use makato-build)
- Story decomposition or planning (use makato-plan)

## Decision Test

"Does this skill help create or refine the production UI layer for built code?"

- Yes → it belongs here
- No → it belongs elsewhere

## Skill Authoring

- Self-contained: all references/templates inside the skill directory
- No `../` paths in skill files. To share content across skills, add a
  `shared/` symlink at the skill root pointing to the plugin's `shared/`
  directory (Claude Code preserves within-plugin symlinks in the install
  cache).
- References loaded at point of use, not front-loaded
- Frontmatter required: name, description, version

## File Structure

```text
plugins/makato-ux/
├── .claude-plugin/
│   └── plugin.json
├── .mcp.json               # Playwright MCP — enables browser-driven testing
├── shared/                 # empty — add shared references (design tokens, test patterns) here when needed
├── skills/
│   ├── e2e-testing-patterns/   # Playwright end-to-end patterns
│   ├── frontend-design/        # Visual design guidance + production UI patterns
│   └── webapp-testing/         # Browser-based functional + visual regression
├── AGENTS.md
├── CHANGELOG.md
├── CLAUDE.md
└── README.md
```

## Versioning

- No `version` in plugin.json (repo versioned via release-please + git tags)
- Skill versions: bumped in SKILL.md frontmatter per feature PR
- CHANGELOG.md: updated with each PR

## PR Checklist

- [ ] Serves the plugin goal: "create or refine the production UI layer"
- [ ] Skills are self-contained (no `../` paths)
- [ ] CHANGELOG updated
- [ ] Conventional commit title: `type(makato-ux): description`
- [ ] Playwright MCP dependency documented if skill uses browser testing
