<!-- markdownlint-disable MD013 -->
# Label Taxonomy

> Single source of truth for the 10-dimension label set applied by `to-issues`. Edit this file to extend defaults; edit `.claude/config.json` to add repo-specific labels without forking this file. The `status:` dimension is **sparse** — emitted only when the status is non-default; the other nine (`type:` / `tier:` / `tech:` / `module:` / `severity:` / `phase:` / `effort:` / `priority:` / `points:`) are emitted whenever a value can be resolved.

## The 10 Dimensions

Every issue created by `to-issues` carries one label from each applicable dimension. The first four (`type:` / `tier:` / `tech:` / `module:`) and the five prioritization dimensions (`severity:` / `phase:` / `effort:` / `priority:` / `points:`) are emitted whenever a value can be resolved; the tenth (`status:`) is sparse — emitted only when the status is non-default (see `Status Dimension` below). A dimension with no resolved value is omitted (the issue is still created).

| Dimension | Source | Examples |
|-----------|--------|----------|
| **type** | Inferred from story title/body keywords (see table below) | `type:feat`, `type:fix`, `type:docs`, `type:refactor`, `type:test`, `type:chore`, `type:future-enhancement` |
| **tier** | `stories[].phase` in `stories.json` (skipped entirely for `type:future-enhancement` — those issues are pre-phase) | `tier:foundation`, `tier:happy-path`, `tier:edge-cases` |
| **tech** | Default keyword list, extensible via `config.json` `labels.tech` | `tech:python`, `tech:bash`, `tech:sql`, `tech:fastapi`, `tech:temporal`, `tech:langgraph`, `tech:pydantic-ai`, `tech:harness`, `tech:skill`, `tech:html`, `tech:react` |
| **module** | ADR folder-name match (see algorithm), extensible via `config.json` `labels.modules` | `module:to-issues`, `module:auth-service`, `module:billing` |
| **severity** *(v3.3.0+)* | `stories[].metadata.severity` (enum: `critical` / `high` / `medium` / `low`) | `severity:critical`, `severity:high`, `severity:medium`, `severity:low` |
| **phase** *(v3.3.0+)* | `stories[].metadata.phase` (enum: `1`–`5`) — distinct from `tier:`, this is execution-order classification not vertical-slice classification. Bare digits — **not** P-prefixed (the `p` prefix is reserved for `priority:*` to keep board chips visually distinguishable). | `phase:1`, `phase:2`, `phase:3`, `phase:4`, `phase:5` |
| **effort** *(v3.3.0+)* | `stories[].metadata.effort` (enum: `s` / `m` / `l` / `xl`) — t-shirt sizing | `effort:s`, `effort:m`, `effort:l`, `effort:xl` |
| **points** *(v3.4.0+)* | `stories[].metadata.points` if explicit (integer), else derived from `effort` via SIZE_MAP — consumed by `issue-to-project` to write the Project board's Estimate number field | `points:1`, `points:3`, `points:8`, `points:13` |
| **priority** *(v3.3.0+)* | `stories[].metadata.priority` if explicit, else derived from `severity` via the severity→priority map below | `priority:p0`, `priority:p1`, `priority:p2`, `priority:p3` |
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

## Prioritization Dimensions (v3.3.0+)

Four new dimensions are sourced from `stories[].metadata` in `stories.json` — each is optional, each emits at most one label per issue. Values come from a free-form metadata block in stories.json so authors can hand-edit without juggling label strings:

```json
{
  "stories": [
    {
      "id": "GAP-002",
      "summary": "Add R1 structured-JSON return contract to all sub-agents",
      "metadata": {
        "severity": "critical",
        "phase":    "p1",
        "effort":   "m",
        "priority": "p0"
      },
      "dependencies": { "blockedBy": [] }
    }
  ]
}
```

All four fields are optional. Any value outside the documented enum below logs a soft-warn (`[to-issues:auto] story <n>: <field>=<value> not in enum — skipped`) and is omitted from the label set without aborting.

### `severity:*` — operational urgency

Pure pass-through from `stories[].metadata.severity`. Enum: `critical` / `high` / `medium` / `low`. The label `severity:<value>` is emitted verbatim. Use to filter "what must we fix" lists.

### `phase:*` — execution order across the plan

Pure pass-through from `stories[].metadata.phase`. Enum: `1` / `2` / `3` / `4` / `5` (**bare digits, no `p` prefix** — the `p` prefix is reserved for `priority:*` so the two cannot be visually confused on board chips, in labels, or in issue bodies). Lower numbers run earlier. This is **distinct from `tier:`**: `tier:` classifies a story's vertical-slice position (foundation/happy-path/edge-cases — copied from `stories[].phase`, which is `to-issues`-internal terminology), while `phase:` classifies cross-story execution order in the larger plan. Both can coexist on the same issue.

For backward compatibility, `metadata.phase` values `"p1"` through `"p5"` are accepted on input and normalized to `"1"` through `"5"` before label emission, with a soft-warn: `[to-issues:auto] story <n>: metadata.phase="p1" auto-normalized to "1" (the "p" prefix is reserved for priority:*)`. New stories.json files should write bare digits.

### `effort:*` — t-shirt sizing

Pure pass-through from `stories[].metadata.effort`. Enum: `s` (< 1 day) / `m` (1–3 days) / `l` (3–5 days) / `xl` (> 1 week). Use for capacity planning and to flag stories that should be re-decomposed before pickup.

### `priority:*` — board-display priority (consumed by `issue-to-project`)

Two-stage resolution:

1. **Explicit value** — if `stories[].metadata.priority` is one of `p0` / `p1` / `p2` / `p3`, emit `priority:<value>` verbatim.
2. **Derived from severity** — if `metadata.priority` is absent BUT `metadata.severity` is present, derive via the map below.

| `severity:*` | derived `priority:*` |
|---|---|
| `severity:critical` | `priority:p0` |
| `severity:high` | `priority:p1` |
| `severity:medium` | `priority:p2` |
| `severity:low` | `priority:p3` |

When derivation fires, the autonomous-mode log records `[to-issues:auto] story <n>: priority:<value> derived from severity:<value>`. When the explicit value contradicts the would-be derived value (e.g. `severity:medium` + `priority:p0`), the explicit value wins silently — operator intent is the source of truth.

**Why both severity and priority exist:** `severity:*` describes the issue intrinsically; `priority:*` is what gets written to the GitHub Project board's Priority field by `issue-to-project` (it picks up the label via the `signal_prefix: "priority"` resolver). Keeping them as separate axes means severity stays correct even when an operator manually re-prioritizes p0/p1/p2/p3 to fit current capacity.

### `points:*` — story-point estimate (consumed by `issue-to-project` for the Estimate field) *(v3.4.0+)*

Two-stage resolution, symmetric to `priority:*`:

1. **Explicit value** — if `stories[].metadata.points` is a positive integer, emit `points:<value>` verbatim.
2. **Derived from effort** — if `metadata.points` is absent BUT `metadata.effort` is present, derive via the SIZE_MAP below.

| `effort:*` | derived `points:*` |
|---|---|
| `effort:s`  | `points:1` |
| `effort:m`  | `points:3` |
| `effort:l`  | `points:8` |
| `effort:xl` | `points:13` |

When derivation fires, the autonomous-mode log records `[to-issues:auto] story <n>: points:<value> derived from effort:<value>`. When the explicit value contradicts the would-be derived value (e.g. `effort:m` + `points:5`), the explicit value wins silently — operator intent is the source of truth.

**Why points and effort both exist:** `effort:*` is for humans (t-shirt sizes scan well in the issue list and on board chips); `points:*` is for the Project board's Estimate **number** field, which expects an integer it can sum across cards. `issue-to-project` v2.4+ reads `points:*` via its number-field resolver (the `SIZE_MAP` constant in `references/field-type-routing.md` is the same map, kept in sync). Keeping the two axes separate means an operator can re-estimate a story (override `points:`) without changing the human-readable t-shirt size, the same way priority can be re-prioritized without changing severity.

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
| `severity:critical` | `B60205` (red — top urgency) |
| `severity:high`     | `D93F0B` (orange-red) |
| `severity:medium`   | `FBCA04` (amber) |
| `severity:low`      | `0E8A16` (green) |
| `phase:1` | `0E4FAB` (dark blue — do first) |
| `phase:2` | `1F6FE5` (blue) |
| `phase:3` | `5B9BF8` (medium blue) |
| `phase:4` | `9CC1FF` (light blue) |
| `phase:5` | `C7DBFF` (pale blue — last) |
| `effort:s`  | `C5DEF5` (pale purple) |
| `effort:m`  | `8AA9E0` (lavender) |
| `effort:l`  | `5076CB` (purple) |
| `effort:xl` | `1B3DA0` (deep purple — biggest) |
| `priority:p0` | `B60205` (red — matches severity:critical visually; this is the field the project board sorts on) |
| `priority:p1` | `D93F0B` (orange-red) |
| `priority:p2` | `FBCA04` (amber) |
| `priority:p3` | `0E8A16` (green) |
| `points:1`  | `EDEDED` (pale grey — small) |
| `points:2`  | `D4D4D4` (light grey) |
| `points:3`  | `BDBDBD` (grey) |
| `points:5`  | `9E9E9E` (mid grey) |
| `points:8`  | `757575` (dark grey) |
| `points:13` | `424242` (charcoal — large) |
| `points:21` | `212121` (near-black — extra large) |
| `status:todo` | `0E8A16` (green — matches project board; same hue as `tech:` is acceptable since `status:todo` is reserved-never-auto-emitted) |
| `status:in-progress` | `FBCA04` (yellow — matches project board) |
| `status:done` | `5319E7` (deep purple — matches project board) |
| `status:blocked` | `B60205` (red — matches project board; aligns with GitHub's red-for-blocker convention) |

Existing labels with the same name are reused as-is — colors are not overwritten.
