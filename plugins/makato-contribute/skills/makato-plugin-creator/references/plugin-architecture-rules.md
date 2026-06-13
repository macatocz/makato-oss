# Plugin Architecture Rules

## What Makes a Plugin Well-Formed

A makato plugin is a self-contained unit with:
1. A single, clear goal statement (the boundary)
2. Governance documentation that makes the boundary enforceable
3. A file structure that validation scripts can check

## Required Governance Data

Every plugin MUST have clearly defined:

### Goal Statement
- One sentence describing a transformation or service
- Examples: "Transform X into Y", "Provide Z for contributors"
- This becomes the ONLY criterion for what belongs

### Belongs / Doesn't Belong
- 2-5 bullet points each, concrete and specific
- Bad: "relevant things" → Good: "Skills that validate spec structure"
- Bad: "irrelevant things" → Good: "End-user workflow tools"

### Decision Test
- A single question asked of any proposed skill
- Must reference the goal statement
- Standard form: "Does this [verb] the goal: '<goal>'?"
- Binary answer: Yes → belongs, No → doesn't belong

## Why This Matters

Without governance data, plugins accumulate unrelated skills.
The decision test makes boundary enforcement mechanical, not political.
Contributors can self-assess whether their skill belongs before opening a PR.

## Plugin Independence

- Toolkits never invoke each other at runtime
- Cross-plugin communication via disk contracts (schemas in makato-core)
- Each plugin is independently installable: `claude --plugin-dir ./plugins/<name>`
- No build step — the repository IS the installable artifact

## Suite Alignment

Before creating a plugin, verify:
- The goal doesn't overlap with an existing plugin
- The responsibility is focused enough for one plugin
- If a plugin would accumulate 10+ skills, consider splitting
