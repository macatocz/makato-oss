# plugin.json Template

Generate the following, replacing placeholders with interview data:

```json
{
  "name": "<plugin-name>",
  "description": "<goal-statement>",
  "author": {
    "name": "<author-name>"
  }
}
```

Required fields:
- `name`: matches the directory name exactly (e.g., `makato-specify`)
- `description`: the goal statement (same as README)
- `author.name`: contributor or team name (default: "makato AI team")

Note: No `version` field — the repo is versioned via release-please and git tags.
Note: No `skills` field — Claude Code automatically discovers all skills in the plugin's `skills/` directory.
