<!-- markdownlint-disable MD013 -->
# Label Taxonomy

> Single source of truth for the 10-dimension label set applied by `to-issues`. Edit this file to extend defaults; edit `.claude/config.json` to add repo-specific labels without forking this file. The `status:` dimension is **sparse** — emitted only when the status is non-default; the other nine (`type:` / `tier:` / `tech:` / `module:` / `severity:` / `phase:` / `effort:` / `priority:` / `points:`) are emitted whenever a value can be resolved.

## The 10 Dimensions

Every issue created by `to-issues` carries one label from each applicable dimension. The first four (`type:` / `tier:` / `tech:` / `module:`) and the five prioritization dimensions (`severity:` / `phase:` / `effort:` / `priority:` / `points:`) are emitted whenever a value can be resolved; the tenth (`status:`) is sparse — emitted only when the status is non-default (see `Status Dimension` below). A dimension with no resolved value is omitted (the issue is still created).

| Dimension | Source | Examples |
|-----------|--------|----------|
| **type** | **(v3.6.0+)** Explicit `stories[].labels[]` `type:*` (in-enum) → text-heuristic inference over `summary` + `description.scope` + `description.background` (see resolution rule + table below) | `type:feat`, `type:fix`, `type:docs`, `type:refactor`, `type:test`, `type:chore`, `type:future-enhancement` |
| **tier** | `stories[].phase` in `stories.json` (skipped entirely for `type:future-enhancement` — those issues are pre-phase) | `tier:foundation`, `tier:happy-path`, `tier:edge-cases` |
| **tech** | Default keyword list, extensible via `config.json` `labels.tech` | `tech:python`, `tech:bash`, `tech:sql`, `tech:fastapi`, `tech:temporal`, `tech:langgraph`, `tech:pydantic-ai`, `tech:harness`, `tech:skill`, `tech:html`, `tech:react` |
| **module** | ADR folder-name match (see algorithm), extensible via `config.json` `labels.modules` | `module:to-issues`, `module:auth-service`, `module:billing` |
| **severity** *(v3.3.0+)* | `stories[].labels[]` `severity:*` → legacy `metadata.severity` (enum: `critical` / `high` / `medium` / `low`) | `severity:critical`, `severity:high`, `severity:medium`, `severity:low` |
| **phase** *(v3.3.0+)* | `stories[].labels[]` `phase:*` → legacy `metadata.phase` (enum: `1`–`5`) — distinct from `tier:`, this is execution-order classification not vertical-slice classification; never derived from `stories[].phase`. Bare digits — **not** P-prefixed (the `p` prefix is reserved for `priority:*`). | `phase:1`, `phase:2`, `phase:3`, `phase:4`, `phase:5` |
| **effort** *(v3.3.0+; points-derivation v3.8.0+)* | `stories[].labels[]` `effort:*` → legacy `metadata.effort` → derived from a points signal (`points:*` label / `metadata.points` / `storyPoints`) via the range map — t-shirt sizing | `effort:s`, `effort:m`, `effort:l`, `effort:xl` |
| **points** *(v3.4.0+)* | `stories[].labels[]` `points:*` → legacy `metadata.points` → derived from `stories[].storyPoints` → derived from `effort` via SIZE_MAP — consumed by `issue-to-project` for the Estimate number field | `points:1`, `points:3`, `points:8`, `points:13` |
| **priority** *(v3.3.0+; tier-derivation v3.7.0+)* | `stories[].labels[]` `priority:*` → legacy `metadata.priority` → derived from `severity` → derived from `tier:` (foundation→p0, happy-path→p1, edge-cases→p3) | `priority:p0`, `priority:p1`, `priority:p2`, `priority:p3` |
| **status** *(sparse)* | Inferred from `dependencies.blockedBy` + `type:future-enhancement` + explicit `stories[].labels` (see `Status Dimension` below) | `status:blocked` *(auto)*, `status:todo` / `status:in-progress` / `status:done` *(reserved for future `manage-github-project` skill — not auto-emitted)* |

## Type Inference Table

**Resolution precedence (v3.6.0+, #272).** `type:` resolves in two ordered steps:

1. **Explicit label wins.** If `stories[].labels[]` carries a `type:<value>` string whose `<value>` is in the enum {`feat`, `fix`, `docs`, `refactor`, `test`, `chore`, `future-enhancement`}, emit it verbatim and **skip the heuristic**. This is the authoritative path when the upstream `decompose` skill (v1.3.0+) emits `type:` from the story's intent — it knows the story's scope, so it beats a text guess. In autonomous mode log `[to-issues:auto] story <n>: type:<value> from labels[] (explicit)`. An out-of-enum `type:<value>` is **ignored** (not an abort) and falls through to step 2, with a soft-warn `[to-issues:auto] story <n>: type=<value> not in enum — falling back to heuristic` — the same out-of-enum tolerance the five prioritization dimensions apply.
2. **Heuristic fallback.** When no explicit in-enum `type:` label is present (e.g. a legacy `stories.json` predating #272), match the lowercased **inference text** against the table below. This preserves byte-for-byte backward compatibility.

This mirrors the **explicit label > inference** pattern already used for `status:` (`## Status Dimension`) and the five prioritization dimensions (`## Prioritization Dimensions`).

Match the lowercased **inference text** — the story `summary` concatenated with `description.scope` and `description.background` (v2.0 field paths — there is no top-level `title` or flat `scope`) — against the **first** matching regex. Default is `type:feat`.

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

### Canonical enum, legacy aliases, and `plan-tier:change`

The `type:` enum emitted by `to-issues` is exactly: `type:feat`, `type:fix`, `type:docs`, `type:refactor`, `type:test`, `type:chore`, `type:future-enhancement`. These are the only values this skill writes.

**Legacy aliases (do not emit; recognised only for backward compatibility).** Issues filed before the enum consolidation carry ad-hoc `type:*` labels that are *not* in the enum. They were migrated to the canonical set:

| Legacy label | Canonical | Rationale |
|--------------|-----------|-----------|
| `type:feature` | `type:feat` | Same meaning; enum uses the short form. `classify-plan-tier.sh` rule 4 still recognises both. |
| `type:correctness` | `type:fix` | Correctness/validation defects are fixes. |
| `type:governance` | `type:chore` | Policy/process work is a chore. |
| `type:rollout` | `type:chore` | Migration/rollout is a chore. |
| `type:tracer` | `type:feat` | Tracer-bullet foundation is feature work. |

**`type:change` is NOT a `type:` enum value — it is a routing signal, not a work-kind.** It belongs to the orthogonal `plan-tier:` dimension (`plan-tier:light` / `plan-tier:full` / `plan-tier:change`), assigned by `.github/scripts/classify-plan-tier.sh` (the project-board classifier, #211), not by this skill. The classifier decides `full` vs `light` from a **decomposition signal, never body length**: `full` fires only on `effort:xl`, `points:>=13` (the repo's Fibonacci split point, #554), or an `epic:*`/`phase:*` label; everything else (that is not `change`) defaults to `light`. A `plan-tier:change` card routes to `makato-change:orchestrate` instead of the `makato-build` pipeline; it co-exists with a work-kind `type:*` label (e.g. `type:fix` + `plan-tier:change` is valid — the fix is routed through the change lane). The loop dispatch router treats `plan-tier:change` as authoritative over any `type:*` label (see #760).

### `type:future-enhancement` semantics

A `type:future-enhancement` issue is **real work parked until a condition is met** — it is created so contributors can scan and promote it later, but it is not actionable now. Treatment rules:

- **No `tier:` label.** Future-enhancement issues are pre-phase; phase classification (`foundation` / `happy-path` / `edge-cases`) only applies once an issue is promoted to actionable.
- **`tech:` and `module:` labels still apply** so the issue surfaces in the right area filters.
- **Trigger condition (optional).** If `stories[].description.trigger` is set in `stories.json` (free-form string), the issue body adds a `## Trigger Condition` section quoting it verbatim. If absent, no section is rendered — the keywords in the story text speak for themselves.
- **Promotion path.** When a maintainer is ready to act on a future-enhancement, they edit the issue title to drop the trigger keyword, remove the `type:future-enhancement` label, and re-run `to-issues` on the updated story (which will then infer `type:feat` and apply the proper `tier:`). There is no automatic promotion — that is by design.

## Default `tech` Keyword Map

Match each pattern against the lowercased **inference text** (story `summary` + `description.scope` + `description.background`). Multiple matches → multiple `tech:` labels on the same issue.

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

For each story, derive a **token set** by lowercasing the **inference text** — `summary` + `description.scope` + `description.background` (v2.0 field paths; there is no top-level `title` or flat `scope`/`background`) — splitting on non-alphanumerics and discarding tokens shorter than 3 characters. A folder matches when **at least one of its *informative* slug tokens appears in the story's token set** (informativeness defined below). All matching folders emit a `module:<slug>` label.

### Informative-token filter (document frequency)

A slug token only counts as a match when it actually **distinguishes** one module from another. A token that appears in almost every story carries no signal — it cannot tell modules apart — so it must not drive a match. The classic example is the connective `and`: it survives the "≥3 chars" filter and, because it occurs in nearly every story, it would otherwise match any ADR slug that contains it (observed live: `module:11-data-privacy-and-confidentiality` on all 10 platform-core issues, matched purely on `and`).

The filter is **language-neutral** — it never enumerates stopwords, so it works identically for English, Czech, German, or any other language. Instead it measures how common a token is across the batch being processed:

1. Let `N` = the number of stories in the current `to-issues` batch.
2. For each token, compute `df(token)` = the number of stories whose inference text contains it (document frequency).
3. A token is **uninformative** — and is dropped from *both* the story token set and every ADR slug's token set before matching — when it appears in **more than half of the stories** in the batch **and in at least two** (`df(token) > N/2` **and** `df(token) ≥ 2`). Connectives (`and`, `und`, `a`, `pro`, …) are near-universal, so they cross this threshold in any language; distinctive domain terms (`privacy`, `brain`, `contract`) sit in only a handful of stories and survive.

Worked example on a 2-story batch where both stories contain `and` but only one mentions `privacy`:

- `df("and") = 2`, `N = 2` → `2 > 1` and `2 ≥ 2` → **uninformative, dropped**. No story matches the `and`-bearing slug on `and`.
- `df("privacy") = 1` → `1 > 1` is false → **informative, kept**. The story that mentions privacy still matches `11-data-privacy-and-confidentiality` on `privacy` / `confidentiality` / `data`.
- `df("brain") = 1` → kept → the skeleton story matches `06-brain-body-contract` on `brain` / `body`.

**Known trade-off — frequency is a proxy for distinctiveness, not distinctiveness itself.** The filter drops a token purely on how *common* it is in the batch; it never measures whether the token is *meaningful*. That proxy holds when the batch is topically diverse (connectives are everywhere, domain terms are rare) but inverts on a **small, single-topic batch**: if a genuinely distinctive term appears in more than half the stories it crosses the same `df > N/2` threshold and is dropped — a silent **false negative** on the correct module. Concretely, a 2-story batch both about billing (`"Billing invoice generation"` + `"Billing refund handling"`) gives `df("billing") = 2 > 1` → `billing` is dropped → neither story matches `12-billing-service`. This is the opposite failure from the `and` case (a miss, not a false hit), and it is the unavoidable cost of a word-list-free, language-neutral heuristic. When it bites, fall back to the two reliable paths: an explicit `module:<slug>` in `stories[].labels[]`, a `labels.modules` regex in `.claude/config.json`, or — if the whole batch shares a term you still want matched — add nothing to `module_stopwords` and instead label the module explicitly. Module-match is best-effort by design (see below); it is not the source of truth.

**Small-batch degeneracy (`N = 1`).** With a single story, `df` of every token is 1, so `df ≥ 2` is never satisfied and nothing is filtered — the frequency signal is undefined for one document. In that case matching falls back to the plain ≥3-char token overlap, so a lone story could match an `and`-bearing slug on `and`. The blast radius is one issue (not a whole batch), and it self-corrects the moment the batch has ≥2 topically-varied stories. This is an accepted limitation of a best-effort convenience signal (see below).

**Optional deterministic override.** Teams that want per-story determinism regardless of batch size may set `.claude/config.json` `labels.module_stopwords` (a string array, default empty). Any token listed there is dropped before matching, in addition to the frequency filter. This is purely opt-in — the default behavior enumerates no words and assumes no language.

### Why module-match is best-effort

`module:<slug>` is a **convenience signal**, intentionally shallow: it reads ADR folder *names* only, never their contents (D5). The reliable ways to bind a module are (a) an explicit `module:<slug>` in `stories[].labels[]`, or (b) a regex pattern in `.claude/config.json` `labels.modules`. The frequency-filtered folder-name match is the cheap layer on top — good enough to auto-surface issues in the right area filter, not a source of truth. When it is wrong or absent, the two explicit paths override it.

If no folder matches, the issue is created with no `module:` label and the autonomous-mode log records `no module match`. No ADR file content is read — folder names only (D5).

## Prioritization Dimensions (v3.3.0+)

These five dimensions are **resolved**, not read from a single `metadata` object. The `stories.json` **v2.0 schema** (`decompose/references/stories-json-schema.md`) carries no `metadata` block — it carries `storyPoints`, `phase` (the vertical-slice tier), and a free-form `stories[].labels[]`. Each dimension is optional and emits at most one label per issue, resolved by the following **precedence** (first hit wins):

1. **Explicit `stories[].labels[]` entry** — the operator wrote e.g. `"severity:high"` or `"points:5"` directly into the story's `labels` array.
2. **Legacy `stories[].metadata.<field>`** — for backward compatibility with v1-era hand-authored stories.json that still carries a `metadata` block. New v2.0 files should not add one.
3. **Derivation** from another v2.0 field (see per-dimension rules below).
4. **Omit** — no label for that dimension.

> **Legacy example (v1-era `metadata` block — still honored via precedence step 2, but not produced by v2.0 `decompose`):**
>
> ```json
> {
>   "stories": [
>     {
>       "summary": "Add R1 structured-JSON return contract to all sub-agents",
>       "metadata": { "severity": "critical", "phase": "1", "effort": "m" },
>       "dependencies": { "blockedBy": [] }
>     }
>   ]
> }
> ```

Any label-array or legacy-metadata value outside the documented enum below logs a soft-warn (`[to-issues:auto] story <n>: <field>=<value> not in enum — skipped`) and is omitted from the label set without aborting.

### `severity:*` — operational urgency

Resolution: explicit `labels[]` `severity:<value>` → legacy `metadata.severity` → omit (no derivation source). Enum: `critical` / `high` / `medium` / `low`. The label `severity:<value>` is emitted verbatim. Use to filter "what must we fix" lists.

### `phase:*` — execution order across the plan

Resolution: explicit `labels[]` `phase:<n>` → legacy `metadata.phase` → omit. Enum: `1` / `2` / `3` / `4` / `5` (**bare digits, no `p` prefix** — the `p` prefix is reserved for `priority:*` so the two cannot be visually confused on board chips, in labels, or in issue bodies). Lower numbers run earlier. This is **distinct from `tier:`**: `tier:` classifies a story's vertical-slice position (foundation/happy-path/edge-cases — copied from `stories[].phase`), while `phase:` classifies cross-story execution order in the larger plan. Both can coexist on the same issue. **`phase:` is never derived from `stories[].phase`** — that field is the vertical-slice tier and already drives `tier:`.

For backward compatibility, legacy `metadata.phase` values `"p1"` through `"p5"` are accepted on input and normalized to `"1"` through `"5"` before label emission, with a soft-warn: `[to-issues:auto] story <n>: metadata.phase="p1" auto-normalized to "1" (the "p" prefix is reserved for priority:*)`. New stories.json files should write bare digits in `labels[]`.

### `effort:*` — t-shirt sizing

Resolution:

1. **Explicit `labels[]`** — if `stories[].labels[]` contains `effort:<value>` with `<value>` ∈ {`s`, `m`, `l`, `xl`}, emit it verbatim.
2. **Legacy `metadata.effort`** — same enum, emitted verbatim.
3. **Derived from a points signal** *(v3.8.0+)* — if no explicit/legacy effort BUT a positive-integer points signal is available (an explicit `points:<n>` label, legacy `metadata.points`, or the v2.0 `stories[].storyPoints` field), derive via the range map below and log `[to-issues:auto] story <n>: effort:<value> derived from points:<n>`. This is the **primary path for v2.0 stories.json**, which always carries `storyPoints` — it gives every sized story a human-readable t-shirt chip by default without an operator hand-assigning `effort:*`.
4. **Omit** otherwise.

| points `<n>` | derived `effort:*` |
|---|---|
| `n ≤ 1` | `effort:s` |
| `2 ≤ n ≤ 5` | `effort:m` |
| `6 ≤ n ≤ 10` | `effort:l` |
| `n ≥ 11` | `effort:xl` |

Enum meaning: `s` (< 1 day) / `m` (1–3 days) / `l` (3–5 days) / `xl` (> 1 week). Use for capacity planning and to flag stories that should be re-decomposed before pickup.

**Range map vs SIZE_MAP — why they differ.** `points:*` derives *from* `effort:*` via the exact-anchor `SIZE_MAP` (`s→1`, `m→3`, `l→8`, `xl→13`). The reverse (`effort` from `points`) cannot reuse those exact anchors because most integers (2, 4, 5, 6, 7, …) are not anchor values — so it uses the **range** map above, whose buckets are centred on the SIZE_MAP anchors (`m` covers 2–5 around anchor 3, `l` covers 6–10 around anchor 8). The two directions are **not circular**: `points`-from-`effort` (`## points:*` step 4) only fires when *no* points signal exists, which is exactly the case where `effort`-from-`points` cannot fire either — so at most one direction ever runs for a given story.

**Why effort and points both exist:** `effort:*` is for humans (t-shirt sizes scan well in the issue list and on board chips); `points:*` is for the Project board's Estimate **number** field. See `## points:*` below for the full rationale — the two are kept as separate axes so an operator can re-estimate `points:` without changing the human-readable t-shirt size.

### `priority:*` — board-display priority (consumed by `issue-to-project`)

Resolution:

1. **Explicit `labels[]`** — if `stories[].labels[]` contains `priority:<value>` with `<value>` ∈ {`p0`, `p1`, `p2`, `p3`}, emit it verbatim.
2. **Legacy `metadata.priority`** — same enum, emitted verbatim.
3. **Derived from severity** — if no explicit/legacy priority BUT a `severity` was resolved, derive via the severity map below.
4. **Derived from tier** *(v3.7.0+)* — if no explicit/legacy priority AND no `severity` was resolved BUT a `tier:` was resolved (from `stories[].phase`), derive via the tier map below. This gives every actionable, tier-classified story a board-display priority by default, so the Priority field is populated on `issue-to-project` sync without an operator hand-assigning `priority:*` or `severity:*` per story.
5. **Omit** otherwise.

| `severity:*` | derived `priority:*` |
|---|---|
| `severity:critical` | `priority:p0` |
| `severity:high` | `priority:p1` |
| `severity:medium` | `priority:p2` |
| `severity:low` | `priority:p3` |

| `tier:*` | derived `priority:*` |
|---|---|
| `tier:foundation` | `priority:p0` |
| `tier:happy-path` | `priority:p1` |
| `tier:edge-cases` | `priority:p3` |

When severity-derivation fires, the autonomous-mode log records `[to-issues:auto] story <n>: priority:<value> derived from severity:<value>`. When tier-derivation fires, it records `[to-issues:auto] story <n>: priority:<value> derived from tier:<value>`. Severity always wins over tier — a story with a resolved `severity` never falls through to tier-derivation. When the explicit value contradicts a would-be derived value (e.g. `severity:medium` + `priority:p0`, or `tier:foundation` + `priority:p2`), the explicit value wins silently — operator intent is the source of truth.

**Why tier maps to p0/p1/p3 (not p2):** the tier axis has three values, priority has four. `foundation` slices are the critical spine everything else blocks on → `p0`. `happy-path` slices are the mainline deliverable → `p1`. `edge-cases` are deferrable hardening → `p3`. `p2` is intentionally left unmapped from tier so an operator can hand-assign it as a deliberate "medium, between mainline and deferrable" signal without it looking auto-derived. Because `type:future-enhancement` issues carry no `tier:` label (they are pre-phase), tier-derivation never fires for them — they omit `priority:*` exactly as before.

**Why both severity and priority exist:** `severity:*` describes the issue intrinsically; `priority:*` is what gets written to the GitHub Project board's Priority field by `issue-to-project` (it picks up the label via the `signal_prefix: "priority"` resolver). Keeping them as separate axes means severity stays correct even when an operator manually re-prioritizes p0/p1/p2/p3 to fit current capacity.

### `points:*` — story-point estimate (consumed by `issue-to-project` for the Estimate field) *(v3.4.0+)*

Resolution:

1. **Explicit `labels[]`** — if `stories[].labels[]` contains `points:<n>` with a positive-integer `<n>`, emit it verbatim.
2. **Legacy `metadata.points`** — a positive integer, emitted verbatim.
3. **Derived from `storyPoints`** *(v3.5.0+)* — if no explicit/legacy points BUT `stories[].storyPoints` is a positive integer (a required v2.0 field), derive `points:<storyPoints>` verbatim and log `[to-issues:auto] story <n>: points:<value> derived from storyPoints`. This is the **primary path for v2.0 stories.json**, which always carries `storyPoints`.
4. **Derived from effort** — if none of the above BUT a resolved `effort` exists, derive via the SIZE_MAP below.
5. **Omit** otherwise.

| `effort:*` | derived `points:*` |
|---|---|
| `effort:s`  | `points:1` |
| `effort:m`  | `points:3` |
| `effort:l`  | `points:8` |
| `effort:xl` | `points:13` |

When derivation fires, the autonomous-mode log records `[to-issues:auto] story <n>: points:<value> derived from storyPoints` (or `derived from effort:<value>` when the effort path was used). When the explicit value contradicts a would-be derived value, the explicit value wins silently — operator intent is the source of truth.

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
    ],
    "module_stopwords": ["pro", "nebo", "und"]
  }
}
```

**Merge policy:** union-with-defaults. Config additions are appended to the default list and evaluated after defaults. If a config entry produces a `label` that collides with a default-produced label for the same dimension, the default wins and the autonomous-mode log emits `[to-issues:auto] label conflict ignored: <label> from config`. There is no override path — to remove a default, edit this file.

`labels.module_stopwords` (string array, default empty) is the **opt-in** companion to the language-neutral document-frequency filter in `## ADR Folder-Match Algorithm`: its tokens are dropped from module matching in addition to the frequency-filtered ones. Use it only when you need per-story determinism independent of batch size (e.g. small batches where the `df ≥ 2` guard never fires) — the default matcher enumerates no words and assumes no language.

## Dependency Dimension

Two labels encode the **directed dependency edge** between issues. They are applied to individual issues (not to the batch as a whole) and are distinct from `status:blocked` — they capture *who blocks whom*, not whether an issue is currently waiting.

**Format rule:** labels use a numeric suffix with no `#` prefix — `blocked-by:42`, not `blocked-by:#42`. This makes them safe in shell without quoting, unambiguous in grep/regex, and queryable directly via `gh issue list --label "blocked-by:42"`.

| Label | Color | Direction | Applied to |
|-------|-------|-----------|------------|
| `blocked-by:N` | `B60205` (red) | Inbound — this issue is blocked by issue N | The **downstream** issue waiting on upstream issue N; one label per blocker (two blockers #42 and #43 → two labels `blocked-by:42` + `blocked-by:43`) |
| `blocking:N` | `D93F0B` (orange-red) | Outbound — this issue blocks downstream issue N | The **upstream** issue that must merge first; one label per dependent |

These are **pattern labels** — created on-demand at runtime from the resolved issue numbers. No hard-coded set of `blocked-by:*` or `blocking:*` labels is pre-created on the repo.

> **Deprecation:** The holé `blocked by` and `blocking` labels (no numeric suffix) were deprecated in v3.12.0. Migrate existing issues with `scripts/migrate-blocked-by-labels.sh`. New issues created by `to-issues` v3.12.0+ never carry the holé labels.

### What `to-issues` auto-emits

- **`blocked-by:N`**: applied to every issue whose `dependencies.blockedBy` is non-empty after topological resolution. One label per blocker — two blockers emit two separate `blocked-by:*` labels. Applied in addition to `status:blocked` (which signals "currently waiting") — the two labels serve different query surfaces: `status:blocked` answers "what's stuck?", `blocked-by:N` answers "what is waiting specifically on issue N?".
- **`blocking:N`**: applied **retroactively** to each upstream issue once the downstream issue has been created. Because `to-issues` processes stories in topological order (blockers first), an upstream issue exists before its dependents — the `blocking:N` label is applied via `gh issue edit --add-label "blocking:<DOWNSTREAM>"` after each downstream issue is created. One label per dependent.

### Removal lifecycle

- **`blocked-by:N`** is removed when issue N closes, via two orthogonal paths:
  - **Primary (immediate):** `blocked-by-cleanup.yml` GHA workflow fires on `issues: [closed]`, removes `blocked-by:N` from all open dependents, and promotes fully-unblocked issues to `status:ready-for-dev`.
  - **Safety net (operator-invoked):** `promote-ready.sh` `_reconcile_blocked_by_labels` pass removes stale `blocked-by:N` labels where N is already closed.
- **`blocking:N`** is removed from the upstream issue when issue N no longer has any `blocked-by:*` labels (i.e. N is itself fully unblocked or closed). This cleanup is performed by `blocked-by-cleanup.yml` (conservative: only when the dependent has no remaining `blocked-by:*` labels).

### What `seed-issue` emits

`seed-issue` supports a `--blocked-by N,M` flag. When supplied:
- Creates `blocked-by:N` labels on the repo (idempotent), applies them to the seeded issue, and retroactively patches `blocking:<SEEDED_ISSUE>` on each upstream issue.
- Implies `status:blocked` — the seeded issue is not promoted to `status:ready-for-dev` until all its blockers close.

Without `--blocked-by`, `seed-issue` applies no dependency labels — dependency wiring between manually-filed issues remains the operator's responsibility.

### Relationship to `status:blocked`

| Signal | Meaning | Who sets it | Who removes it |
|--------|---------|------------|----------------|
| `status:blocked` | Issue is currently waiting and should not be dispatched | `to-issues` auto, `seed-issue` (with `--blocked-by`) | `blocked-by-cleanup.yml` on full unblock; `promote-ready.sh` reconcile pass |
| `blocked-by:N` | Issue is waiting specifically on issue N | `to-issues` auto, `seed-issue --blocked-by` | `blocked-by-cleanup.yml` on issue N close; `promote-ready.sh` reconcile pass |
| `blocking:N` | This issue must merge before issue N can proceed | `to-issues` auto (retroactive), `seed-issue --blocked-by` (retroactive) | `blocked-by-cleanup.yml` when N is fully unblocked |

An issue may carry both `status:blocked` and `blocked-by:N` at creation time. Once all blockers close, the dependency labels are cleaned up automatically via `blocked-by-cleanup.yml` (primary) or `promote-ready.sh` reconcile (safety net).

---

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
| `blocked-by:*` | `B60205` (red — same hue as `status:blocked`; dependency labels and status share the red/orange palette) — created on-demand per blocker issue number |
| `blocking:*` | `D93F0B` (orange-red — same hue as `severity:high`; less urgent than the downstream `blocked-by:*`) — created on-demand per dependent issue number |

Existing labels with the same name are reused as-is — colors are not overwritten.
