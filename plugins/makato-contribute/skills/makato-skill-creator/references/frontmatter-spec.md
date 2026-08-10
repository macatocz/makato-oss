# SKILL.md Frontmatter Specification

## Required Fields

| Field | Type | Rules |
|-------|------|-------|
| `name` | string | Kebab-case, must match the skill directory name |
| `description` | string | What the skill does and when to use it. Include trigger words inline. Under 200 characters recommended. |
| `version` | string | Semver in quotes, e.g., `"1.0.0"` |

## Optional Fields

| Field | Type | Rules |
|-------|------|-------|
| `model` | string | Model override (e.g., `opus`, `sonnet`, `haiku`) |
| `argument-hint` | string | Hint shown in autocomplete (e.g., `[issue-number]`) |
| `disable-model-invocation` | boolean | Prevent Claude from auto-invoking |
| `user-invocable` | boolean | Hide from `/` menu if false |
| `allowed-tools` | list | Tools allowed without permission prompts |
| `deprecated` | boolean | Mark skill as deprecated |
| `deprecated_since` | string | Version when deprecation started |

## Format Example

```yaml
---
name: my-skill-name
description: One-line description with trigger words inline. Use when user wants to do X or says Y.
version: "1.0.0"
modelRole: advisor
argument-hint: "[target]"
---
```

## Description Best Practices

The `description` field is how Claude decides when to load the skill. Follow Anthropic's pattern:
- **What + When** in a single line: what the skill does, then when to use it
- Embed trigger words naturally: "brainstorm, explore ideas, creative exploration"
- Put the key use case first (truncated at 1,536 chars in skill listing)
- No YAML multiline (`>-`) — keep it as a single string

## Validation Rules

- `name` must match regex: `^[a-z][a-z0-9-]*$`
- `name` must exactly match the directory name containing SKILL.md
- `version` must be valid semver (MAJOR.MINOR.PATCH) wrapped in quotes
- `description` should be concise and include trigger words inline

## Common Mistakes

- Forgetting quotes around version: `version: 1.0.0` → INVALID (parsed as float)
- Using underscores in name: `my_skill` → INVALID (must be kebab-case)
- Using `>-` for description: works but single line is preferred
- Using a separate `triggers` field: embed trigger words in description instead
