# Label Conventions

Two labels apply to every issue: a **type label** and a **plugin label** (omit the plugin label for `repo-wide`).

## Type Labels (already exist on zstary/makato)

| Issue type    | Label           |
|---------------|-----------------|
| Bug           | `bug`           |
| Feature       | `enhancement`   |
| Documentation | `documentation` |

Do not auto-create type labels — if one is missing, surface to the user.

## Plugin Labels

| Plugin scope        | Label                      | Color (hex) |
|---------------------|----------------------------|-------------|
| `makato-core`       | `plugin:makato-core`       | `0E8A16`    |
| `makato-plan`       | `plugin:makato-plan`       | `5319E7`    |
| `makato-contribute` | `plugin:makato-contribute` | `0075CA`    |
| `makato-build`      | `plugin:makato-build`      | `E4E669`    |
| `makato-change`     | `plugin:makato-change`     | `D93F0B`    |
| `makato-database`   | `plugin:makato-database`   | `0052CC`    |
| `makato-doc`        | `plugin:makato-doc`        | `BFD4F2`    |
| `makato-fastapi`    | `plugin:makato-fastapi`    | `009800`    |
| `makato-langgraph`  | `plugin:makato-langgraph`  | `C2E0C6`    |
| `makato-observability` | `plugin:makato-observability` | `FEF2C0` |
| `makato-orchestrate` | `plugin:makato-orchestrate` | `F9D0C4`  |
| `makato-sagibeast`  | `plugin:makato-sagibeast`  | `1D76DB`    |
| `makato-temporal`   | `plugin:makato-temporal`   | `CC317C`    |
| `makato-ux`         | `plugin:makato-ux`         | `FBCA04`    |

If a `plugin:*` label is missing, create it with the matching color and a description like `Affects <plugin> plugin`.

## Project Name Resolution

The GitHub project name is read from `<REPO_ROOT>/.claude/config.json`:

```json
{ "project": "<project-name>" }
```

Fallback: `"sagibeast"` when the file is absent or `"project"` key is missing.

**Rule:** Resolution is always autonomous — no user prompt, no confirmation. Applied silently. This is the canonical source; do not hardcode project names in skills.
