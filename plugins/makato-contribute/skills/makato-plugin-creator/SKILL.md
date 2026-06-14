---
name: makato-plugin-creator
description: Create a complete, working makato plugin with governance files populated from an interview process — create plugin, new plugin, scaffold plugin, create a new plugin
version: "2.2.1"
---

# makato-plugin-creator

## When to Use

Use when a contributor wants to create a new plugin for the makato suite. This skill does not generate empty scaffolds — it conducts a structured interview, validates suite alignment, presents a plan for review, and produces a complete plugin with fully populated governance documentation ready for skill development.

## Workflow

This skill follows a strict 3-phase workflow: **Plan → Present → Build**. No files are created until the user explicitly approves the plan.

---

### Phase 1: Plan

#### Step 1: Interview — Plugin Identity

Ask the contributor for:
1. **Plugin name** — must be `makato-<kebab-case-name>` (e.g., `makato-specify`, `makato-review`)
2. **Goal statement** — one sentence: what does this plugin transform or provide?
3. **How** — one sentence: what mechanism does it use?
4. **Why** — one sentence: what value does this deliver?
5. **Author** — default: "makato AI team"

Validate:
- Load @references/naming-conventions.md
- Name matches pattern: `^makato-[a-z][a-z0-9-]*$`
- Name is not already taken (check `plugins/` directory)
- Goal is a single sentence

#### Step 2: Interview — Governance Boundaries

Load @references/plugin-architecture-rules.md to understand what governance data is needed.

Ask the contributor:
1. **What belongs in this plugin?** (2-5 concrete bullet points)
2. **What does NOT belong?** (2-5 concrete bullet points)
3. **Decision test** — a single question that can be asked of any proposed skill

Provide examples from existing plugins:
- makato-core: "Does this serve one toolkit's goal, or the entire suite?"
- makato-contribute: "Does this help a contributor produce correct, goal-aligned content for the makato suite?"

The contributor should produce something specific like: "Does this skill help [transform X into Y]?"

#### Step 3: Interview — Infrastructure Needs

Ask:
1. Does this plugin require any MCP servers? If yes, gather: server name, command, args, env vars.
2. Will skills in this plugin share large resources? (determines whether to include `shared/` directory)

#### Step 4: Suite Alignment Check

Before proceeding, verify the proposed plugin fits the makato suite:
1. List existing plugins and their goals for the contributor
2. Check for goal overlap with existing plugins
3. Verify the goal represents a single, coherent responsibility
4. If concerns arise, discuss and resolve before continuing

#### Step 5: Plan File Content

Based on all gathered information, synthesize planned content for each output file:
- `plugin.json` — name, version 0.1.0, description = goal, author, empty skills array
- `CLAUDE.md` — single `@AGENTS.md` pointer
- `AGENTS.md` — full governance (goal + how + why, belongs, doesn't belong, decision test, skill authoring, file structure, versioning, PR checklist)
- `README.md` — goal + how + why, belongs, doesn't belong, skills placeholder, prerequisites (if MCP), installation
- `CHANGELOG.md` — initial [0.1.0] entry with today's date
- `.mcp.json` — only if MCP servers were declared

---

### Phase 2: Present (Interactive HTML Review)

#### Step 6: Generate HTML Plan

Create an interactive HTML plan file at `/tmp/makato-plugin-plan-<plugin-name>.html`.

Use @references/plan-template.html as the structural template. Fill in these sections:

1. **Plugin Identity** — name, goal, how, why, author
2. **Governance** — belongs, doesn't belong, decision test (displayed prominently)
3. **AGENTS.md Preview** — full rendered content as it will appear
4. **README.md Preview** — full rendered content as it will appear
5. **plugin.json Preview** — formatted JSON
6. **Infrastructure** — MCP servers (shown only if declared)
7. **File Tree** — visual directory structure of what will be created
8. **Validation Checks** — scripts that will run and what they verify

Each section includes a comment textarea. A "Copy Feedback" button aggregates all non-empty comments.

#### Step 7: Open and Collect Feedback

Open the HTML file in the browser:
- macOS: `open /tmp/makato-plugin-plan-<plugin-name>.html`
- Linux: `xdg-open /tmp/makato-plugin-plan-<plugin-name>.html`

Tell the user:
> "I've opened the plugin plan in your browser. Review each section and add comments in the text areas for anything you'd like changed. When done, click 'Copy Feedback' and paste it back here."

#### Step 8: Iterate on Feedback

When the user pastes feedback:
1. Parse the structured comments (section → feedback mapping)
2. Address each piece of feedback
3. Regenerate the HTML plan with changes
4. Re-open in browser
5. Repeat until the user approves (e.g., "looks good", "approved", "build it")

---

### Phase 3: Build

Only proceed after explicit user approval.

#### Step 9: Create Directory Structure

Create:
```
plugins/<plugin-name>/
├── .claude-plugin/
└── skills/
```

#### Step 10: Generate plugin.json

Load @references/plugin-json-template.md

Write to `plugins/<plugin-name>/.claude-plugin/plugin.json` with all interview data.

#### Step 11: Generate CLAUDE.md

Write a single line:
```
@AGENTS.md
```

#### Step 12: Generate AGENTS.md

Load @references/agents-template.md

Write the full AGENTS.md populated from interview data. Every section must contain concrete, specific content — no placeholders or generic text.

#### Step 13: Generate README.md, CHANGELOG.md, and .mcp.json

Load @references/readme-template.md and @references/changelog-template.md

Write `README.md` with all interview data populated.
Write `CHANGELOG.md` with today's date and initial entry.
If MCP servers were declared: write `.mcp.json` at the plugin root and include a Prerequisites section in README.

#### Step 14: Register in Marketplace

Add the new plugin to `.claude-plugin/marketplace.json` in the `plugins` array:
```json
{
  "name": "<plugin-name>",
  "source": "./plugins/<plugin-name>",
  "description": "<goal-statement>"
}
```

This ensures the plugin is discoverable via the marketplace. Without this step, users cannot install the plugin through normal marketplace flows.

#### Step 15: Validate and Summarize

Run validation scripts:
```bash
./scripts/check-plugin-structure.sh plugins/<plugin-name>
./scripts/check-naming.sh
```

If any check fails: report the error, fix it, re-run until all pass.

Present to the user:
1. **Files created** — full list with paths
2. **Marketplace** — registered in `.claude-plugin/marketplace.json`
3. **Validation result** — all checks passed
4. **Test command**: `claude --plugin-dir ./plugins/<plugin-name>`
5. **Next steps**: "Add skills using `makato-skill-creator`"
6. **PR title suggestion**: `feat(<plugin-name>): initial plugin with governance`
