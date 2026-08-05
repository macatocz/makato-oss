# Config Schema — stores[] Field Constraints

Load this reference when validating store entries, diagnosing a malformed-JSON
failure, or auditing an existing `.claude/config.json` for schema compliance.

Source: `plugins/makato-plan/schemas/config.schema.json` (added in #565).

## stores[] Item Shape

```json
{
  "id":          "<string: required>",
  "repo":        "<string: required>",
  "description": "<string: required>"
}
```

`additionalProperties: false` — extra keys on a stores entry are schema
violations and will be stripped on the next `register` rewrite of that entry.

## Field Patterns

### id

Pattern: `^[a-z0-9][a-z0-9_-]*$`

- Must start with a lowercase letter or digit
- May contain lowercase letters, digits, hyphens, underscores
- NO uppercase, NO spaces, NO dots, NO slashes

Valid: `platform`, `infra-v2`, `my_repo`
Invalid: `Platform` (uppercase), `my repo` (space), `infra.v2` (dot)

**Critical:** The script does NOT validate this pattern on write. A
non-conforming id is stored silently and fails at invocation time when
`to-issues --store <id>` tokenises the argument list.

### repo

Pattern: `^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$`

- Exactly one `/` separating `owner` and `name`
- Both segments: alphanumeric plus `_`, `.`, `-`
- NO trailing slash, NO scheme, NO extra path segments

Valid: `macatocz/platform`, `my-org/repo.v2`
Invalid: `macatocz/platform/` (trailing slash), `https://github.com/org/repo` (URL)

### description

- Non-empty string, no pattern constraint
- Used as a human-readable label; whitespace is preserved

## Top-Level config.json Fields (coexisting with stores[])

The script reads the entire file, mutates only `stores`, and writes the full
document back — all other top-level fields are preserved. Known cohabitants:

| Field | Written by | Purpose |
|---|---|---|
| `project` | `init` / manual | Short project name used in issue titles |
| `github_project` | `issue-to-project --init` | GitHub Projects v2 board field IDs |
| `stores` | `manage-stores.sh` | This file's subject |

`additionalProperties: true` at the top level — other plugins may add fields;
`manage-stores.sh` never removes them.

## Malformed JSON Recovery

When `config.json` contains invalid JSON the script prints to stderr and exits 1
**without modifying the file**. Recovery options:

1. Fix the JSON manually using a validator (`python3 -m json.tool .claude/config.json`)
2. If the stores[] content is lost, delete the file and re-register all entries;
   the script recreates the file with `{"stores": []}` on the next `register`.
3. If other fields (`github_project`, `project`) must be preserved, repair the
   JSON before running any store command.
