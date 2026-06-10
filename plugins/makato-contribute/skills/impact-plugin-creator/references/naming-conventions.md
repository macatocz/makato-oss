# Naming Conventions

## Plugin Directories

- Format: `makato-<kebab-case-name>`
- Pattern: `^makato-[a-z][a-z0-9-]*$`
- Examples: `makato-core`, `makato-contribute`, `makato-specify`

## Skill Directories

- Format: kebab-case
- Pattern: `^[a-z][a-z0-9-]*$`
- Examples: `scaffold-plugin`, `makato-guide`, `review-spec`, `generate-tests`
- No underscores, no uppercase, no dots

## Files

| File | Convention |
|------|-----------|
| `SKILL.md` | Always uppercase filename |
| `plugin.json` | Always lowercase |
| Reference files | `kebab-case.md` |
| Template files | `kebab-case.md` or `kebab-case.json` |
| `AGENTS.md` | Always uppercase |
| `CLAUDE.md` | Always uppercase |
| `README.md` | Always uppercase |
| `CHANGELOG.md` | Always uppercase |

## plugin.json Skill Paths

Skill paths in the `skills` array are relative from the plugin root:

```json
{
  "skills": [
    "skills/my-skill-name",
    "skills/another-skill"
  ]
}
```

## Validation

The `check-naming.sh` script validates:
- Plugin directory names match the `makato-*` pattern
- Skill directory names match kebab-case pattern
- File naming follows conventions
