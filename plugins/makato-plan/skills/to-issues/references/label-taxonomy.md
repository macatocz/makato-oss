<!-- markdownlint-disable MD013 -->
# Label Taxonomy

> Single source of truth for the 4-dimension label set applied by `to-issues`. Edit this file to extend defaults; edit `.claude/config.json` to add repo-specific labels without forking this file.

## The 4 Dimensions

Every issue created by `to-issues` carries exactly one label from each of these dimensions where a value can be resolved. A dimension with no resolved value is omitted (the issue is still created).

| Dimension | Source | Examples |
|-----------|--------|----------|
| **type** | Inferred from story title/body keywords (see table below) | `type:feat`, `type:fix`, `type:docs`, `type:refactor`, `type:test`, `type:chore` |
| **tier** | `stories[].phase` in `stories.json` | `tier:foundation`, `tier:happy-path`, `tier:edge-cases` |
| **tech** | Default keyword list, extensible via `config.json` `labels.tech` | `tech:python`, `tech:bash`, `tech:sql`, `tech:fastapi`, `tech:temporal`, `tech:langgraph`, `tech:pydantic-ai`, `tech:harness`, `tech:skill`, `tech:html`, `tech:react` |
| **module** | ADR folder-name match (see algorithm), extensible via `config.json` `labels.modules` | `module:to-issues`, `module:auth-service`, `module:billing` |

## Type Inference Table

Match the lowercased story title concatenated with the story scope text against the **first** matching regex. Default is `type:feat`.

| Pattern (case-insensitive, word-boundary) | Label |
|-------------------------------------------|-------|
| `\b(fix\|bug\|broken\|regression\|hotfix\|patch)\b` | `type:fix` |
| `\b(docs?\|readme\|changelog\|comment)\b` | `type:docs` |
| `\b(refactor\|rename\|reorganize\|cleanup)\b` | `type:refactor` |
| `\b(test\|spec\|coverage)\b` | `type:test` |
| `\b(chore\|deps?\|bump\|ci\|build)\b` | `type:chore` |
| (no match) | `type:feat` |

Evaluation order is top-to-bottom; first match wins. In autonomous mode (per D10), apply the inferred label silently and log the decision to stdout prefixed `[to-issues:auto]`. In interactive mode, propose the inferred label and ask the user to confirm or override.

## Default `tech` Keyword Map

Match each pattern against the lowercased story title + scope. Multiple matches → multiple `tech:` labels on the same issue.

| Pattern (case-insensitive, word-boundary) | Label |
|-------------------------------------------|-------|
| `\bpython\b` | `tech:python` |
| `\bbash\b` | `tech:bash` |
| `\b(sql\|postgres\|sqlite\|duckdb)\b` | `tech:sql` |
| `\bfastapi\b` | `tech:fastapi` |
| `\btemporal\b` | `tech:temporal` |
| `\blanggraph\b` | `tech:langgraph` |
| `\bpydantic[- ]?ai\b` | `tech:pydantic-ai` |
| `\b(harness\|hook)\b` | `tech:harness` |
| `\bskill\b` | `tech:skill` |
| `\bhtml\b` | `tech:html` |
| `\b(react\|jsx\|tsx)\b` | `tech:react` |
| `\bgh\b\|\bgithub cli\b` | `tech:gh-cli` |

## ADR Folder-Match Algorithm (D16)

The `architecture_path` is read from `.claude/config.json` `"architecture_path"` (fallback: `specs/Architecture/`). For each direct child folder of that path, derive a **slug** by lowercasing and replacing non-alphanumerics with hyphens (e.g. `06-Brain-Body-Contract` → `06-brain-body-contract`).

For each story, derive a **token set** by lowercasing the title + scope + background fields, splitting on non-alphanumerics, and discarding tokens shorter than 3 characters. A folder matches when **at least one of its slug tokens appears in the story's token set**. All matching folders emit a `module:<slug>` label.

If no folder matches, the issue is created with no `module:` label and the autonomous-mode log records `no module match`. No ADR file content is read — folder names only (D5).

## Config-Extension Contract (D14)

`.claude/config.json` may extend (never override) the defaults:

```json
{
  "project": "my-team",
  "architecture_path": "docs/adr",
  "labels": {
    "tech": [
      { "pattern": "\\bnext(\\.js)?\\b", "label": "tech:next" },
      { "pattern": "\\btailwind\\b", "label": "tech:tailwind" }
    ],
    "modules": [
      { "pattern": "\\bauth(entication)?\\b", "label": "module:auth-service" }
    ]
  }
}
```

**Merge policy:** union-with-defaults. Config additions are appended to the default list and evaluated after defaults. If a config entry produces a `label` that collides with a default-produced label for the same dimension, the default wins and the autonomous-mode log emits `[to-issues:auto] label conflict ignored: <label> from config`. There is no override path — to remove a default, edit this file.

## GitHub Label Creation

`to-issues` calls `gh label list --repo "$TARGET_REPO"` before creating issues. Any label needed by the plan but absent from the repo is created via `gh label create` with the following default colors:

| Prefix     | Color (hex) |
|------------|-------------|
| `type:`    | `1D76DB` (blue) |
| `tier:`    | `5319E7` (purple) |
| `tech:`    | `0E8A16` (green) |
| `module:`  | `BFD4F2` (light blue) |

Existing labels with the same name are reused as-is — colors are not overwritten.
