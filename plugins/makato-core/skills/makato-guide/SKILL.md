---
name: makato-guide
description: Discover installed makato plugins, list available skills, and help users find the right tool for their task — help, guide, what can makato do, list plugins, find skill, makato overview
version: "1.1.0"
---

# makato-guide

## When to Use

- User asks what makato can do or what plugins are available
- User is new to makato and wants an overview of the suite
- User has a specific task and wants to know which skill handles it
- User wants to understand the relationship between plugins

## Workflow

### Step 1: Discover Installed Plugins

Scan the `plugins/` directory at the repository root for subdirectories matching `makato-*`.

For each discovered plugin directory:
1. Read `.claude-plugin/plugin.json`
2. Extract: `name`, `description` (the goal statement), `skills` array, `version`
3. Skip any directory without a valid `plugin.json` (incomplete or broken plugin)

### Step 2: Gather Skill Details

For each plugin with a non-empty `skills` array:
1. For each skill path listed, read `SKILL.md` in that directory
2. Extract from frontmatter: `name`, `description`
3. Note any skill marked `deprecated: true`
4. If `SKILL.md` is missing or malformed, list the skill as "undocumented"

### Step 3: Present Suite Overview

Load @references/suite-overview.md for architectural context.

Present a structured response:

1. **Suite introduction** (2-3 sentences: what makato is and its design philosophy)
2. **Installed plugins table**:
   - Plugin name
   - Goal statement
   - Number of skills
   - Version
3. **Skills by plugin**:
   - For each plugin, list skills with their one-line descriptions
   - Note deprecated skills with a warning
4. **Architecture note**: makato-core is the foundation; other plugins are independent toolkits

### Step 4: Handle Specific Queries

- If the user asked a **general question** ("what can makato do?", "help"): present the full overview from Step 3
- If the user asked about a **specific capability** ("how do I create a plugin?", "I need to write a spec"): match against skill descriptions to suggest the most relevant skill
- If **no skill matches** the user's need: say so clearly and suggest it may be a candidate for a new skill or plugin

### Step 5: Suggest Next Steps

Based on the user's situation:

- **Skill found**: Tell the user the skill name and how to invoke it (e.g., "Try: /makato-skill-creator")
- **Want to add capabilities**: Point to `makato-skill-creator` (creates skills in existing plugins) or `scaffold-plugin` (creates new plugins) in makato-contribute
- **Only makato-core installed**: Mention that additional toolkit plugins exist and explain how to install them with `claude --plugin-dir ./plugins/makato-<name>`
