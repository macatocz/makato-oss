---
name: makato-skill-creator
description: Create a complete, working skill inside an existing makato plugin with full guardrails and validation — create skill, new skill, add skill to plugin, write a skill
version: "1.1.2"
---
# makato-skill-creator

## When to Use

Use when a contributor wants to add a fully-realized skill to an existing makato plugin. This skill does not generate empty stubs — it creates complete, working skills with real workflows, references, and templates, all validated against makato suite guardrails.

## Workflow

This skill follows a strict 3-phase workflow: **Plan → Present → Build**. No files are created until the user explicitly approves the plan.

---

### Phase 1: Plan

#### Step 1: Identify Target Plugin

Ask the user: **"Which makato plugin should this skill be added to?"**

Validate:

1. The plugin exists: check `plugins/<name>/.claude-plugin/plugin.json`
2. Read the plugin's `plugin.json` to get: name, description (goal statement), existing skills
3. Read the plugin's `AGENTS.md` to understand what belongs and the decision test

If the plugin doesn't exist, suggest using `makato-plugin-creator` first.

#### Step 2: Define the Skill's Purpose

Ask the user:

1. **What should this skill accomplish?** (the transformation or outcome)
2. **What inputs does it need from the user?** (questions to ask, files to read, context needed)
3. **What outputs does it produce?** (files, artifacts, decisions, suggestions)
4. **What is the skill name?** (kebab-case, e.g., `review-spec`, `generate-tests`)

Validate the skill name:

- Load @references/naming-conventions.md
- Must match pattern: `^[a-z][a-z0-9-]*$`
- Must not already exist in the plugin's `skills/` directory

#### Step 3: Goal Alignment Check

Load @references/decision-test-pattern.md

Apply the decision test:

- Read the parent plugin's goal statement from `plugin.json` description field
- Ask: **"Does this skill demonstrably serve the goal: '`<goal>`'?"**
- If clearly aligned → proceed
- If unclear → discuss with the user, explain which plugin might be more appropriate
- If misaligned → recommend a different plugin or suggest creating a new one

#### Step 4: Design the Skill Workflow

Based on the user's description, design a multi-step workflow:

1. Break the skill's function into concrete, numbered steps
2. Each step must be actionable (not vague — "Generate X" not "Handle X")
3. Include validation points where the skill should check its work
4. Identify what reference files the skill needs (domain knowledge, rules, examples)
5. Identify what template files the skill needs (structured output patterns)
6. Consider error paths and edge cases

Load @references/skill-authoring-rules.md to ensure the workflow design follows conventions.

#### Step 5: Plan References and Templates

For each piece of domain knowledge the skill needs:

- Plan a reference file in `references/` (focused on one topic, under 100 lines)
- References are read-only context loaded at point of use

For each structured output the skill produces:

- Plan a template file in `templates/` (with `<placeholder>` syntax)

Load @references/self-containment-rules.md to verify all planned files will be local to the skill directory.

---

### Phase 2: Present (Interactive HTML Review)

#### Step 6: Generate HTML Plan

Create an interactive HTML plan file at `/tmp/makato-skill-plan-<skill-name>.html`.

Use @references/plan-template.html as the structural template. Fill in the following sections:

1. **Goal Alignment** (first section, prominent):

   - Parent plugin name and goal statement
   - How this skill serves the plugin's goal
   - Where this skill fits in the plugin's existing skill workflow
2. **Skill Identity**:

   - Name, description (with trigger words embedded), version
   - Complete frontmatter preview
3. **Workflow Steps**:

   - Each step as a collapsible section
   - Step number, title, and full description
   - Any `@references/` loads noted inline
4. **Reference Files Planned**:

   - Filename, purpose, content summary for each
5. **Template Files Planned** (if any):

   - Filename, purpose, placeholder fields
6. **File Tree**:

   - Visual directory structure of what will be created
7. **Validation Checks**:

   - List of scripts that will run
   - What each checks for

Each section includes a comment textarea for the user to annotate.
A "Copy Feedback" button at the bottom aggregates all non-empty comments into structured text.

#### Step 7: Open and Collect Feedback

Automatically open the HTML file in the browser:

- macOS: `open /tmp/makato-skill-plan-<skill-name>.html`
- Linux: `xdg-open /tmp/makato-skill-plan-<skill-name>.html`

Tell the user:

> "I've opened the skill plan in your browser. Review each section and add comments in the text areas for anything you'd like changed. When done, click 'Copy Feedback' and paste it back here."

#### Step 8: Iterate on Feedback

When the user pastes feedback:

1. Parse the structured comments (section → feedback mapping)
2. Address each piece of feedback
3. Regenerate the HTML plan with changes
4. Re-open in browser
5. Repeat until the user says they approve (e.g., "looks good", "approved", "build it")

---

### Phase 3: Build

Only proceed after explicit user approval.

#### Step 9: Create SKILL.md

Load @references/frontmatter-spec.md for field requirements.
Load @references/skill-authoring-rules.md for structure conventions.

Write the complete `SKILL.md` with:

- Valid YAML frontmatter (name, description with trigger words, version)
- "When to Use" section with clear scope definition
- "Workflow" section with numbered steps and detailed instructions
- `@references/` loads at point of use (not front-loaded)

Place at: `plugins/<plugin>/skills/<skill-name>/SKILL.md`

#### Step 10: Create Reference Files

For each planned reference:

- Write the file to `plugins/<plugin>/skills/<skill-name>/references/<filename>.md`
- Content must be self-contained and under 100 lines
- Each reference covers one focused topic

#### Step 11: Create Template Files (if any)

For each planned template:

- Write the file to `plugins/<plugin>/skills/<skill-name>/templates/<filename>`
- Use `<placeholder-name>` syntax for variable parts

#### Step 12: Update Parent Plugin Files

1. Add entry to `plugins/<plugin>/CHANGELOG.md`:

   ```markdown
   ### Added
   - `<skill-name>` skill (<one-line description>)
   ```
2. Update the skills table in `plugins/<plugin>/README.md` if one exists.

**Do NOT modify `plugin.json`** — skills are auto-loaded from the directory structure.

#### Step 13: Validate

Run validation scripts:
```bash
./scripts/check-skill-frontmatter.sh plugins/<plugin>/skills/<skill-name>
./scripts/check-self-contained.sh plugins/<plugin>/skills/<skill-name>
./scripts/check-naming.sh
```

If any check fails:

1. Report the specific error
2. Fix the issue
3. Re-run the failing check
4. Repeat until all pass

#### Step 14: Persist Skill Plan

Copy the final approved HTML plan into the new skill's references:

```bash
cp /tmp/makato-skill-plan-<skill-name>.html plugins/<plugin>/skills/<skill-name>/references/skill-plan.html
```

This preserves the design rationale, workflow decisions, and feedback iterations for future reference when modifying the skill.

#### Step 15: Summary

Present to the user:

1. **Files created** — full list with paths (including `references/skill-plan.html`)
2. **Parent files updated** — CHANGELOG, README
3. **Validation result** — all checks passed
4. **Test command**: `claude --plugin-dir ./plugins/<plugin-name>`
5. **PR title suggestion**: `feat(<plugin-name>): add <skill-name> skill`
