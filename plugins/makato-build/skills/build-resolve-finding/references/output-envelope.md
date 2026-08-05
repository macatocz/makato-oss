# Output envelope reference

Full shape returned to `sensor-fixer` by this skill.

```json
{
  "action": "autofix | skill | autofix-then-skill | redact-and-issue | upgrade-or-ignore | suppress-with-reason | carry-over",
  "outcome": "resolved | failed | carry-over",
  "skill_used": "<skill name or null>",
  "retried": false,
  "escalated": false,
  "jsonl_entry": {
    "ts": "<ISO-8601>",
    "tool": "<tool>",
    "rule": "<rule>",
    "path": "<path>",
    "line": 123,
    "branch": "1|2|3a|3b|3c|4",
    "outcome": "resolved | failed | carry-over"
  }
}
```

## Field notes

- `action` — verbatim value from `finding-routes.json` (or `"carry-over"` when Branch 4
  triggers); `"autofix-then-skill"` resolves to Branch 2 with `route.fallback_skill` but
  the label is preserved for audit.
- `skill_used` — non-null only for Branch 2 outcomes; `null` for all other branches.
- `jsonl_entry` — produced by this skill but **not written by this skill** — the caller
  (`sensor-fixer`) appends it to the run log.
- `retried`/`escalated` — reserved; currently always `false` (model-level escalation
  is a future concern tracked in #287).
