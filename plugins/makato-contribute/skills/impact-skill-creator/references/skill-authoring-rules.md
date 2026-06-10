# Skill Authoring Rules

## Directory Structure

Every skill lives in its own directory under `skills/`:

```
skills/<skill-name>/
├── SKILL.md              # Main skill definition (required)
├── references/           # Read-only context files (optional)
└── templates/            # Output templates (optional)
```

## SKILL.md Structure

1. **YAML frontmatter** (required fields: name, description, version)
2. **"When to Use" section** — clear scope: when to invoke, when NOT to invoke
3. **"Workflow" section** — numbered steps, each concrete and actionable
4. **Reference loads** — `@references/filename.md` at point of use within workflow steps

## Key Rules

- References loaded at point of use, not front-loaded at the top
- Each step must be actionable ("Generate X", "Ask the user Y", "Validate Z")
- Avoid vague steps ("Handle errors", "Process input")
- Include validation points within the workflow
- Keep skills focused: one transformation per skill

## Versioning

- Bump `version` in frontmatter when behavior changes
- MAJOR: breaking change in output format or behavior
- MINOR: new capability or behavior change
- PATCH: wording fix, typo, reference update
- New skills always start at `"1.0.0"`

## Constraint Placement

- Place constraints inline at the workflow step where they apply
- Write constraints as positive instructions ("Use X", "Reject Y if Z") within the step text
- Scope-boundary constraints ("this skill does not do X") belong in "When NOT to Use"
- Do NOT accumulate a "NEVER" section at end of file — end-of-file content is at highest risk of being dropped during context compaction (only first 5,000 tokens are kept)
- Do NOT include "Composes With" sections — upstream/downstream relationships are expressed through artifact-loading steps and handoff steps
- Do NOT include pipeline diagrams — static metadata that does not instruct behavior
- If a constraint applies to multiple steps, place it at the earliest step and reference briefly in later steps if critical

## Testing

```bash
claude --plugin-dir ./plugins/<plugin-name>
```

Trigger the skill with one of the phrases embedded in its description to test.
