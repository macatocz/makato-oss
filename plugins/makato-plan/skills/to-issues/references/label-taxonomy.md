<!-- markdownlint-disable MD013 -->
# Label Taxonomy

> Single source of truth for the 5-dimension label set applied by `to-issues`. Edit this file to extend defaults; edit `.claude/config.json` to add repo-specific labels without forking this file. The `status:` dimension is **sparse** — emitted only when the status is non-default; the other four (`type:` / `tier:` / `tech:` / `module:`) are emitted whenever a value can be resolved.

## The 5 Dimensions

Every issue created by `to-issues` carries one label from each applicable dimension. The first four (`type:` / `tier:` / `tech:` / `module:`) are emitted whenever a value can be resolved; the fifth (`status:`) is sparse — emitted only when the status is non-default (see `Status Dimension` below). A dimension with no resolved value is omitted (the issue is still created).

| Dimension | Source | Examples |
|-----------|--------|----------|
| **type** | Inferred from story title/body keywords (see table below) | `type:feat`, `type:fix`, `type:docs`, `type:refactor`, `type:test`, `type:chore`, `type:future-enhancement` |
| **tier** | `stories[].phase` in `stories.json` (skipped entirely for `type:future-enhancement` — those issues are pre-phase) | `tier:foundation`, `tier:happy-path`, `tier:edge-cases` |
| **tech** | Default keyword list, extensible via `config.json` `labels.tech` | `tech:python`, `tech:bash`, `tech:sql`, `tech:fastapi`, `tech:temporal`, `tech:langgraph`, `tech:pydantic-ai`, `tech:harness`, `tech:skill`, `tech:html`, `tech:react` |
| **module** | ADR folder-name match (see algorithm), extensible via `config.json` `labels.modules` | `module:to-issues`, `module:auth-service`, `module:billing` |
| **status** *(sparse)* | Inferred from `dependencies.blockedBy` + `type:future-enhancement` + explicit `stories[].labels` (see `Status Dimension` below) | `status:blocked` *(auto)*, `status:todo` / `status:in-progress` / `status:done` *(reserved for future `manage-github-project` skill — not auto-emitted)* |

## Type Inference Table

Match the lowercased story title concatenated with the story scope text against the **first** matching regex. Default is `type:feat`.

| Pattern (case-insensitive, word-boundary) | Label |
|-------------------------------------------|-------|
| `\b(fix\|bug\|broken\|regression\|hotfix\|patch)\b` | `type:fix` |
| `\b(docs?\|readme\|changelog\|comment)\b` | `type:docs` |
| `\b(refactor\|rename\|reorganize\|cleanup)\b` | `type:refactor` |
| `\b(test\|spec\|coverage)\b` | `type:test` |
| `\b(chore\|deps?\|bump\|ci\|build)\b` | `type:chore` |
| `\b(future\|someday\|eventually\|parked\|deferred\|icebox\|backlog)\b` | `type:future-enhancement` |
| `\b(wait[- ]until\|after[- ]we\|once[- ]we)\b` or `\bwhen\b.*\bthen\b` | `type:future-enhancement` |
| `\bv[2-9]\b` or `\bvnext\b` or `\bmilestone[- ][2-9]\b` | `type:future-enhancement` |
| (no match) | `type:feat` |

Evaluation order is top-to-bottom; first match wins. In autonomous mode (per D10), apply the inferred label silently and log the decision to stdout prefixed `[to-issues:auto]`. In interactive mode, propose the inferred label and ask the user to confirm or override.

### `type:future-enhancement` semantics

A `type:future-enhancement` issue is **real work parked until a condition is met** — it is created so contributors can scan and promote it later, but it is not actionable now. Treatment rules:

- **No `tier:` label.** Future-enhancement issues are pre-phase; phase classification (`foundation` / `happy-path` / `edge-cases`) only applies once an issue is promoted to actionable.
- **`tech:` and `module:` labels still apply** so the issue surfaces in the right area filters.
- **Trigger condition (optional).** If `stories[].description.trigger` is set in `stories.json` (free-form string), the issue body adds a `## Trigger Condition` section quoting it verbatim. If absent, no section is rendered — the keywords in the story text speak for themselves.
- **Promotion path.** When a maintainer is ready to act on a future-enhancement, they edit the issue title to drop the trigger keyword, remove the `type:future-enhancement` label, and re-run `to-issues` on the updated story (which will then infer `type:feat` and apply the proper `tier:`). There is no automatic promotion — that is by design.

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

## Status Dimension

The sagibeast GitHub Project board has a 4-value `Status` field that maps 1:1 to the four `status:*` labels:

| Project board status | Color | Description (from project board) | Label |
|---|---|---|---|
| Todo | green (`0E8A16`) | This item hasn't been started | `status:todo` *(default — usually omitted; GitHub Projects auto-applies Todo)* |
| In Progress | yellow | This is actively being worked on | `status:in-progress` *(reserved — not auto-emitted by to-issues)* |
| Done | deep purple | This has been completed | `status:done` *(reserved — not auto-emitted by to-issues)* |
| Blocked | red | Currently waiting until there is implemented prerequisity issue or when the project is in shape when it can be implemented | `status:blocked` *(auto-emitted on creation when applicable)* |

### What `to-issues` auto-emits

`to-issues` only auto-emits one `status:*` value on issue creation: **`status:blocked`**. It is emitted when ANY of the following apply:

1. **Unresolved upstream dependency.** The story has `dependencies.blockedBy` IDs that do not yet exist in the same batch and were not resolved by an earlier batch-mate. "Unresolved" is evaluated after topological sort; a blocker that was created earlier in the same `to-issues` run counts as resolved.
2. **`type:future-enhancement` was inferred** (per v3.1.0, PR #12). Future-enhancement issues are parked-until-condition-met, which matches the project board's Blocked description verbatim ("when the project is in shape when it can be implemented").
3. **Explicit operator override.** The story's `stories[].labels` array contains the literal string `status:blocked`.

`status:in-progress` and `status:done` are taxonomy values so the labels exist on the repo (and downstream skills can apply them), but they are **never** auto-emitted by `to-issues` — lifecycle transitions (PR opened → In Progress, PR merged → Done) are downstream of issue creation and belong to a separate `manage-github-project` skill (out of scope for this skill).

### Operator-override priority

If `stories[].labels` contains a literal `status:*` value, it is honored verbatim regardless of inference. When an explicit value contradicts an inferred one (e.g. story has `dependencies.blockedBy: [42]` AND `stories[].labels: ["status:todo"]`), the explicit value wins and the autonomous-mode log records:

```
[to-issues:auto] story <n>: status inference (blocked) overridden by explicit label (status:todo)
```

### Soft-warning for dangling `blockedBy`

If `dependencies.blockedBy` references an integer ID that doesn't exist anywhere in the batch and wasn't created earlier in the same run, the story is still emitted with `status:blocked`. The body's `Blocked by:` line will show `#<id> (_unresolved_)` for that ID; the autonomous-mode log records:

```
[to-issues:auto] story <n>: dangling blockedBy reference #<id> — issue still created with status:blocked, human follow-up required
```

This is a warning, not a halt — the human resolves the dangling reference manually.

## GitHub Label Creation

`to-issues` calls `gh label list --repo "$TARGET_REPO"` before creating issues. Any label needed by the plan but absent from the repo is created via `gh label create` with the following default colors:

| Prefix     | Color (hex) |
|------------|-------------|
| `type:`    | `1D76DB` (blue) |
| `type:future-enhancement` | `D4C5F9` (lavender — distinguishes from active `type:` work at a glance) |
| `tier:`    | `8B5CF6` (violet — migrated from original purple in v3.2.0 to free that hex for `status:done`) |
| `tech:`    | `0E8A16` (green) |
| `module:`  | `BFD4F2` (light blue) |
| `status:todo` | `0E8A16` (green — matches project board; same hue as `tech:` is acceptable since `status:todo` is reserved-never-auto-emitted) |
| `status:in-progress` | `FBCA04` (yellow — matches project board) |
| `status:done` | `5319E7` (deep purple — matches project board) |
| `status:blocked` | `B60205` (red — matches project board; aligns with GitHub's red-for-blocker convention) |

Existing labels with the same name are reused as-is — colors are not overwritten.
