---
name: to-issues
description: >-
  Use when user wants to convert a plan into issues, create implementation tickets, or break
  down a feature into GitHub issues. Generic across makato consumers — reads `.claude/config.json`
  for project name, targets `github.com`, applies a 10-dimension label taxonomy
  (type/tier/tech/module/severity/phase/effort/priority/points/status), maps stories to ADR folders by
  name pattern, and emits `specs/{slug}/created-issues.json` for downstream plugins.
  Do NOT use for: adding already-created issues to a project board (use issue-to-project),
  managing issue lifecycle/status transitions (use makato-orchestrate), or editing issues
  after creation (use gh issue edit directly).
license: MIT
version: "3.11.1"
argument-hint: "[optional: feature slug] [--dry-run] [--interactive|--autonomous] [--repo owner/repo] [--store <id>]"
allowed-tools: Bash(gh *) Bash(git *) Bash(python3 *) Read Write Grep Glob
hooks: ["convert to issues", "break into issues", "create github issues", "turn this into tickets", "issue breakdown", "create implementation tickets", "decompose into issues", "publish stories", "create issues from stories.json"]
metadata:
  Authors: makato contributors
  last_updated: "2026-07-19"
  mcp_server: none
---

# To Issues

Create GitHub issues on **github.com** from a shaped `stories.json`. Each issue carries a 10-dimension label set — type / tier / tech / module / severity / phase / effort / priority / points / status (the last is sparse, emitted only when non-default; the five prioritization dimensions are sparse-by-default too — emitted only when they can be resolved from `stories[].labels[]`, `stories[].storyPoints`, or a legacy `metadata` block) — an architecture-mapped module annotation, and a body rendered from a versioned template. Writes `specs/{slug}/created-issues.json` as a machine-readable handoff for downstream skills (e.g. `build-create-pr`, `issue-to-project`).

**Breaking change vs. 2.x:** the skill no longer targets the 2.x enterprise GitHub host, no longer reads or writes `project-information.md`, and now requires a `.claude/config.json` at the repo root (silent fallback to `"sagibeast"` is provided).

## Tools

| Tool | Purpose |
|------|---------|
| `Bash(gh *)` | Create labels and issues on github.com |
| `Bash(git *)` | Resolve repo root and remote URL |
| `Bash(python3 *)` | Parse `.claude/config.json` and `stories.json`, validate `created-issues.json` against the schema |
| `Read` | Load stories.json, references, and the legacy project-information.md (for migration warning) |
| `Write` | Write `created-issues.json` |
| `Grep`, `Glob` | Scan ADR folders for module-name matches |

## Reference Files

- **MANDATORY** — load `references/label-taxonomy.md` for the 10-dimension taxonomy (`type:` / `tier:` / `tech:` / `module:` / `severity:` / `phase:` / `effort:` / `priority:` / `points:` / `status:`), type-inference table, ADR-match algorithm, config-extension contract, and the sparse `status:` inference rules in `## Status Dimension`.
- **MANDATORY** — load `references/issue-template.md` for the body template (single edit point for issue body format).
- **MANDATORY** — load `references/created-issues.schema.json` as the validation schema for the output artifact.
- **MANDATORY** — load `references/plan-template.md` before Step 5 whenever the batch contains at least one story that is NOT `type:future-enhancement`. The template is the sole source of truth for the `plan-${ISSUE_NUMBER}.md` scaffold written by Step 5; loading it late (after Step 3 inference resolves the type) is intentional — batches composed entirely of `type:future-enhancement` stories skip plan emission entirely and do not need this file.
- `references/slice-patterns.md` — only when a slice boundary is ambiguous or the caller asks about vertical-slicing strategy.
- `references/fixtures/` — **Do NOT Load**: contains test-only smoke-test fixtures (`artifact-guard-smoke-tests.sh`, `cross-repo-smoke-tests.sh`, `v2-schema-smoke-tests.sh`, `plan-emission-fixture.stories.json`, `v2-schema-regression.stories.json`, `cross-repo-config.json`) used for skill regression testing and CI validation. These are not runtime inputs and must not be loaded during normal skill execution.

## Process

### Step 0 — Resolve repo, target, and project name

```bash
REPO_ROOT="$(git rev-parse --show-toplevel)" || { echo "Not a git repo — aborting" >&2; exit 1; }
REMOTE_URL="$(git -C "$REPO_ROOT" remote get-url origin)"
TARGET_REPO="$(echo "$REMOTE_URL" | sed -E 's|.*github\.com[:/]||; s|\.git$||')"
```

**Cross-repo flag resolution (v3.11.0+):** After deriving the default `TARGET_REPO` from the git remote, apply `--repo` / `--store` overrides when either flag is present on the CLI.

`--repo` and `--store` are **mutually exclusive** — passing both is an error:

```bash
if [[ -n "${ARG_REPO:-}" && -n "${ARG_STORE:-}" ]]; then
  echo "[to-issues] ERROR: --repo and --store are mutually exclusive. Pass one or the other." >&2
  exit 1
fi
```

When `--repo <owner/repo>` is passed, override `TARGET_REPO` directly:

```bash
if [[ -n "${ARG_REPO:-}" ]]; then
  TARGET_REPO="$ARG_REPO"
  echo "[to-issues] target_repo override via --repo: $TARGET_REPO"
fi
```

When `--store <id>` is passed, look up `id` in `.claude/config.json → stores[]` and resolve `TARGET_REPO` from that entry's `repo` field. If the `id` is absent from `stores[]`, abort and list the known IDs:

```bash
if [[ -n "${ARG_STORE:-}" ]]; then
  TARGET_REPO="$(python3 -c "
import json, sys
try:
    cfg = json.load(open('$REPO_ROOT/.claude/config.json'))
except FileNotFoundError:
    print('[to-issues] ERROR: .claude/config.json not found — cannot resolve --store', file=sys.stderr)
    sys.exit(1)
except json.JSONDecodeError as e:
    print(f'[to-issues] ERROR: malformed config.json: {e}', file=sys.stderr)
    sys.exit(2)
stores = cfg.get('stores', [])
for entry in stores:
    if entry.get('id') == '$ARG_STORE':
        repo = entry.get('repo', '')
        if not repo:
            print(f'[to-issues] ERROR: store \\'$ARG_STORE\\' has no repo field', file=sys.stderr)
            sys.exit(1)
        print(repo)
        sys.exit(0)
known = ', '.join(e.get('id', '<unnamed>') for e in stores) or '(none)'
print(f'[to-issues] ERROR: unknown store id \\'$ARG_STORE\\'; known store IDs: {known}', file=sys.stderr)
sys.exit(1)
  ")" || exit $?
  echo "[to-issues] target_repo resolved via --store=$ARG_STORE: $TARGET_REPO"
fi
```

When neither `--repo` nor `--store` is passed, `TARGET_REPO` retains the git-remote-derived value (unchanged behaviour).

**`.claude/config.json` `stores[]` schema** (v3.11.0+):

```json
{
  "stores": [
    {
      "id": "acme",
      "repo": "acme-corp/platform",
      "description": "optional human-readable label"
    }
  ]
}
```

Each entry requires `id` (unique string key) and `repo` (`owner/repo` on github.com). `description` is optional and informational only.

```bash
PROJECT_NAME="$(python3 -c "
import json
try:
    d = json.load(open('$REPO_ROOT/.claude/config.json'))
    print(d.get('project', 'sagibeast'))
except FileNotFoundError:
    print('sagibeast')
except json.JSONDecodeError as e:
    import sys; print(f'malformed config.json: {e}', file=sys.stderr); sys.exit(2)
")"

echo "[to-issues] target_repo=$TARGET_REPO project=$PROJECT_NAME"
```

If `python3` exits 2 (malformed JSON), abort the entire skill — do not silently fall back.

**Constraint:** `GH_HOST` MUST be set to `github.com` only. Do not target a 2.x enterprise GitHub host, set `GH_HOST` to an enterprise endpoint, use `GH_ENTERPRISE_TOKEN`, or apply any TLS bypass. That wiring was removed in v3.

**Legacy-migration warning (D18):**

```bash
if [[ -f "$REPO_ROOT/.claude/rules/project-information.md" ]]; then
  echo "[to-issues] WARNING: legacy .claude/rules/project-information.md detected." >&2
  echo "[to-issues] to-issues v3 reads the project name from .claude/config.json instead." >&2
  echo "[to-issues] Copy the project value into .claude/config.json and delete project-information.md." >&2
fi
```

Continue execution — the warning is informational, not blocking.

**Mode detection (D10):**

The skill runs in `--interactive` mode by default. Switch to `--autonomous` when (a) the user passes `--autonomous` on the CLI, OR (b) the caller provides a context bundle with a `task_id` field, OR (c) `$AGENT_ID` is exported. In autonomous mode, all inference decisions are applied silently and logged to stdout with the `[to-issues:auto]` prefix; no confirmation prompts are issued.

### Step 1 — Locate inputs

- Primary input: `specs/<slug>/stories.json`. If the user passed a slug argument, use `specs/<slug>/stories.json`. Otherwise, glob `specs/*/stories.json` and pick the most recently modified.
- Fallback inputs (only when stories.json is absent): `plan.md` in the same folder, or the conversation context — degrade gracefully by treating each plan task as a story with `phase: foundation`, `labels: []`, no scope, and an empty `outOfScope`.

Read the resolved `stories.json` with `python3 -c "import json; json.load(open('...'))"` and abort with the parse error if invalid.

After parsing, validate required fields before any `gh` call:

```python
for i, story in enumerate(stories):
    if not story.get("summary", "").strip():
        print(f"[to-issues] ERROR: story {i} has no summary — aborting before any gh calls", file=sys.stderr)
        sys.exit(1)
    if not story.get("phase"):
        print(f"[to-issues] WARN: story {i} ('{story.get('summary', '')}') has no phase — tier: label will be omitted")
```

`summary` is mandatory (it becomes the issue title — a blank title is a 422 API error). `phase` is required for `tier:` but its absence is a soft-warn, not an abort, because `type:future-enhancement` stories intentionally omit it.

### Step 2 — Discover ADR folders

```bash
ARCH_PATH="$(python3 -c "
import json
try:
    d = json.load(open('$REPO_ROOT/.claude/config.json'))
    print(d.get('architecture_path', 'specs/Architecture'))
except FileNotFoundError:
    print('specs/Architecture')
")"

if [[ -d "$REPO_ROOT/$ARCH_PATH" ]]; then
  if [[ "$(uname)" == "Darwin" ]]; then
    ADR_FOLDERS="$(find "$REPO_ROOT/$ARCH_PATH" -mindepth 1 -maxdepth 1 -type d | xargs -n1 basename | sed -E 's/[^A-Za-z0-9]+/-/g; s/^-+|-+$//g' | tr '[:upper:]' '[:lower:]')"
  else
    ADR_FOLDERS="$(find "$REPO_ROOT/$ARCH_PATH" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sed -E 's/[^A-Za-z0-9]+/-/g; s/^-+|-+$//g' | tr '[:upper:]' '[:lower:]')"
  fi
else
  ADR_FOLDERS=""
fi
```

Output is a newline-separated list of lowercase-hyphenated ADR slugs.

**Constraint:** read folder names only — do NOT read ADR file contents. Module matching is intentionally a folder-name-only signal (D5).

### Step 3 — Infer labels per story

For each story in `stories.json.stories[]`, apply the algorithm in `references/label-taxonomy.md`:

1. **type** *(v3.6.0+)*: resolve with precedence **(a) explicit `stories[].labels[]` entry → (b) text heuristic**. (a) If `stories[].labels[]` contains a `type:<value>` string with `<value>` in the enum {`feat`, `fix`, `docs`, `refactor`, `test`, `chore`, `future-enhancement`}, emit it verbatim — the explicit label wins and the heuristic is skipped (in autonomous mode log `[to-issues:auto] story <n>: type:<value> from labels[] (explicit)`). An out-of-enum `type:<value>` is ignored and falls through to (b) — never abort (same tolerance the five prioritization dimensions in bullet 5 apply to out-of-enum values; a soft-warn `[to-issues:auto] story <n>: type=<value> not in enum — falling back to heuristic` is logged). (b) Otherwise regex match the **inference text** — `summary` + `description.scope` + `description.background` (v2.0 field paths; there is no top-level `title` or flat `scope`) — against the inference table, top-to-bottom; first match wins; default `type:feat` (in autonomous mode log `[to-issues:auto] story <n>: type:<value> inferred via heuristic`). This is the same **explicit label > inference** precedence the skill already applies to `status:` (see `## Status Dimension`) and to the five prioritization dimensions (bullet 5) — extended to `type:` per #272 so a `decompose`-authored `type:` prefix is authoritative over the text heuristic. Backward-compatible: a legacy `stories.json` with no `type:` prefix resolves exactly as before via (b).
2. **tier**: copy `stories[].phase` verbatim, prefixed `tier:`. **Skip this dimension entirely when `type:future-enhancement` was inferred** — future-enhancement issues are pre-phase and carry no `tier:` label. In autonomous mode log `[to-issues:auto] story <n>: tier skipped (type:future-enhancement)`.
3. **tech**: match the same **inference text** (`summary` + `description.scope` + `description.background`) against the default tech keyword map AND any `labels.tech` patterns from `.claude/config.json`. Defaults evaluate first; config entries are appended (D14 union-with-defaults). Multiple matches → multiple `tech:` labels.
4. **module**: tokenize the **inference text** (`summary` + `description.scope` + `description.background`, lowercased, alphanumeric runs ≥3 chars), then apply the **informative-token filter** per `references/label-taxonomy.md` (`## ADR Folder-Match Algorithm`) — a language-neutral document-frequency filter that drops tokens appearing in more than half the batch (`df > N/2` and `df ≥ 2`), so batch-universal connectives (`and`, `und`, `a`, …) cannot drive a match in any language. For each ADR folder slug, emit `module:<slug>` when at least one **informative** slug token appears in the story's token set. Emit ALL matching modules. If none match, log `[to-issues:auto] story <n>: no module match` and omit the dimension.
5. **severity / phase / effort / priority / points** *(v3.5.0+, all optional)*: resolve each dimension from the story's v2.0 fields, with a legacy `stories[].metadata.*` fallback for backward compatibility. **Resolution precedence per dimension: (a) explicit `stories[].labels[]` entry → (b) legacy `stories[].metadata.<field>` → (c) derivation from another v2.0 field → (d) omit.** The v2.0 schema (`decompose/references/stories-json-schema.md`) has **no `metadata` object** — it carries `storyPoints`, `phase`, and a free-form `labels[]`; the five dimensions below are therefore *derived*, not read from a `metadata` block that no longer exists. See `references/label-taxonomy.md` `## Prioritization Dimensions` for the full resolution table.
   - **severity**: if `stories[].labels[]` contains a `severity:<value>` string with `<value>` ∈ {`critical`, `high`, `medium`, `low`}, emit it verbatim; else if legacy `metadata.severity` is present and in-enum, emit `severity:<value>`; else omit.
   - **phase**: if `stories[].labels[]` contains a `phase:<n>` string with `<n>` ∈ {`1`–`5`}, emit it verbatim; else if legacy `metadata.phase` is present, emit `phase:<value>` (**bare digits only — no `p` prefix**, which is reserved for `priority:*`; legacy `"p1"`–`"p5"` auto-normalize to `"1"`–`"5"` with a soft-warn `[to-issues:auto] story <n>: metadata.phase="p1" auto-normalized to "1" (the "p" prefix is reserved for priority:*)`); else omit. **Do not derive `phase:` from `stories[].phase`** — that field is the vertical-slice tier (foundation/happy-path/edge-cases) and already drives `tier:`, not the numeric cross-plan `phase:`.
   - **effort**: if `stories[].labels[]` contains an `effort:<value>` string with `<value>` ∈ {`s`, `m`, `l`, `xl`}, emit it verbatim; else if legacy `metadata.effort` is present and in-enum, emit `effort:<value>`; else if a positive-integer points signal exists *(v3.8.0+)* — an explicit `points:<n>` label, legacy `metadata.points`, or `stories[].storyPoints` — **derive** via the points→effort range map (`n≤1→s`, `2–5→m`, `6–10→l`, `n≥11→xl`) and log `[to-issues:auto] story <n>: effort:<value> derived from points:<n>`; else omit. This reads the points *signal* directly (not the resolved `points:` label from the next bullet), so it is order-independent and non-circular with the `points`-from-`effort` SIZE_MAP path (which only fires when no points signal exists).
   - **priority**: if `stories[].labels[]` contains a `priority:<value>` string with `<value>` ∈ {`p0`–`p3`}, emit it verbatim; else if legacy `metadata.priority` is present and in-enum, emit it; else if a `severity` was resolved above, **derive** via the severity→priority map (`critical→p0`, `high→p1`, `medium→p2`, `low→p3`) and log `[to-issues:auto] story <n>: priority:<derived> derived from severity:<value>`; else if a `tier:` was resolved (bullet 2) *(v3.7.0+)*, **derive** via the tier→priority map (`foundation→p0`, `happy-path→p1`, `edge-cases→p3`) and log `[to-issues:auto] story <n>: priority:<derived> derived from tier:<value>`; else omit. Severity wins over tier (a resolved severity never falls through to tier-derivation). Tier-derivation cannot fire for `type:future-enhancement` stories — they carry no `tier:` label.
   - **points**: if `stories[].labels[]` contains a `points:<n>` string with a positive-integer `<n>`, emit it verbatim; else if legacy `metadata.points` is a positive integer, emit `points:<value>`; else if `stories[].storyPoints` is a positive integer, **derive** `points:<storyPoints>` verbatim and log `[to-issues:auto] story <n>: points:<value> derived from storyPoints`; else if a resolved `effort` exists, derive via the SIZE_MAP (`s→1`, `m→3`, `l→8`, `xl→13`) and log `[to-issues:auto] story <n>: points:<derived> derived from effort:<value>`; else omit. Non-positive or non-integer inputs log `[to-issues:auto] story <n>: points source <value> not a positive integer — skipped` and are omitted.
   - Any label-array or legacy-metadata value outside the documented enum logs `[to-issues:auto] story <n>: <field>=<value> not in enum — skipped` and is omitted (the issue is still created).
   - When none of the five dimensions resolve for a story, all five labels are omitted silently (no warning — these dimensions are sparse-by-default).
6. **dependency labels** *(v3.9.0+, value-bearing format v3.12.0+)*: apply `blocked-by:N` and `blocking:N` per `references/label-taxonomy.md` `## Dependency Dimension`:
   - **`blocked-by:N`**: for each blocker issue number in `RESOLVED_BLOCKED_BY[]`, emit a separate label `blocked-by:<N>` (no `#` prefix — numeric only, safe in shell without quoting). E.g. two blockers #42 and #43 → labels `blocked-by:42` and `blocked-by:43`. Applied alongside `status:blocked` — the two signals are additive. In autonomous mode log `[to-issues:auto] story <n>: adding label "blocked-by:<N>"`.
   - **`blocking:N`**: applied **retroactively** to each upstream issue via `gh issue edit --add-label "blocking:<DOWNSTREAM_ISSUE_NUMBER>"` after the downstream issue is created. Applied per-blocker: upstream #42 gets `blocking:<DOWNSTREAM>`. The `blocking:N` label is **not** included in a story's own label set during inference — it is a cross-issue signal applied to blockers, not to the blocked story itself. In autonomous mode log `[to-issues:auto] story <n>: patching blocking:<DOWNSTREAM> onto upstream #<N>`.
   - Both labels are created on-demand (pattern labels — not pre-created). The label name is derived at runtime from the resolved issue number; no hard-coded set of `blocked-by:*` labels exists.

7. **status**: emit `status:blocked` when ANY of the following hold, otherwise omit the `status:` dimension entirely (sparse — see `references/label-taxonomy.md` `## Status Dimension`):
   - The story's `dependencies.blockedBy` contains an integer ID that is unresolved at the point of issue creation. "Unresolved" means: (a) the upstream story has no corresponding GitHub issue yet AND (b) the upstream story was not created earlier in the current batch's topological order. Dangling references (ID not in batch at all) also emit `status:blocked` with a soft-warning log line.
   - The story was inferred as `type:future-enhancement` in bullet 1 above (per v3.1.0).
   - The story's `stories[].labels` array contains the literal string `status:blocked` (explicit operator override).
   When an explicit `stories[].labels` value contradicts inference (e.g. the operator wrote `status:todo` on a story that would otherwise infer `status:blocked`), the explicit value wins; log `[to-issues:auto] story <n>: status inference (<inferred>) overridden by explicit label (<explicit>)`.
   `status:in-progress` and `status:done` are taxonomy values but are **never** auto-emitted by this skill — lifecycle transitions belong to a future `manage-github-project` skill.

8. **QARefinement label (S5 safety net)**: before finalizing the label set, check each story's
   `successScenarios` and `acceptanceTestCases` arrays. If either is non-empty and `QARefinement`
   is not already in `labels[]`, add it. If both are empty and `QARefinement` IS in `labels[]`,
   remove it. This is a safety net for legacy `stories.json` files that predate the `decompose`
   auto-apply in Step 7.5. In autonomous mode log `[to-issues:auto] story <n>: QARefinement
   label <added|removed> (safety net)`.

In `--interactive` mode, after inference for **all** stories (not story-by-story — reduce round-trips), present a numbered table of proposed label sets and use **AskUserQuestion** with the question:

> "Story labels are ready. For each story below, choose: confirm all / edit <story-N> <label>=<value> / skip <story-N>."

Accepted response values:
- `confirm` — proceed to creation with all inferred labels as shown.
- `edit <story-N> <dimension>=<value>` — override one label dimension for story N, re-display affected row, re-ask.
- `skip <story-N>` — exclude story N from the batch (log `[to-issues] story <n> skipped by operator`; it is NOT written to `created-issues.json`).

Only the label set is editable at this step — `summary`, `phase`, `storyPoints`, and dependency graphs are upstream contract fields that this skill does not mutate.

In `--autonomous` mode, log every inferred label to stdout (one line per story, prefixed `[to-issues:auto] story <n>:`).

### Step 4 — Ensure required labels exist on the repo

```bash
EXISTING_LABELS="$(GH_HOST=github.com gh label list --repo "$TARGET_REPO" --limit 200 --json name --jq '.[].name')"
```

For each unique label across all stories, if it is not in `EXISTING_LABELS`, create it using the colors documented in `references/label-taxonomy.md`:

```bash
GH_HOST=github.com gh label create "<label>" --repo "$TARGET_REPO" --color "<hex>" --description "Auto-created by to-issues v3"
```

Pattern labels `blocked-by:N` and `blocking:N` are created on-demand during Step 5 issue creation — no pre-creation step needed. The label name is derived at runtime from the resolved issue number; no hard-coded set of `blocked-by:*` or `blocking:*` labels exists.

Skip silently when the label already exists; never overwrite color or description.

### Step 5 — Create issues in dependency order

Topologically sort `stories[]` by the `dependencies.blockedBy` graph. Process stories in topo-sorted order so that when a story refers to its blockers, those blockers already have real issue numbers.

For each story:

1. Render the body by substituting placeholders in `references/issue-template.md` (read fresh per skill invocation — never cache):
   - `{{FEATURE_SLUG}}` → the spec slug.
   - `{{STORY_SUMMARY}}` → `summary`.
   - `{{STORY_BACKGROUND}}` → `description.background`.
   - `{{STORY_SCOPE}}` → `description.scope`.
   - `{{STORY_PHASE}}` → `phase`. For `type:future-enhancement` stories, render this as `_n/a — future enhancement_` instead of the phase value (pre-phase work).
   - `{{METADATA_BLOCK}}` *(v3.3.0+)* → human-readable rendering of the **five prioritization dimensions resolved in Step 3 bullet 5** (severity / phase / effort / priority / points — resolved from `stories[].labels[]`, `stories[].storyPoints`, and any legacy `metadata.*`, NOT from a `metadata` object). When any of the five resolved, render one bold line per resolved dimension:

     ```
     **Severity:** CRITICAL
     **Phase:** 1
     **Effort:** M
     **Points:** 3 *(derived from storyPoints)*
     **Priority:** p0 *(derived from severity)*
     ```

     Values render uppercase for `severity` (`critical → CRITICAL`), **bare digits** for `phase` (`1`–`5`; if the input was the deprecated `p1` form, render `1`), uppercase for `effort` (`m → M`), bare integer for `points`, and lowercase for `priority` (`p0`). **Phase never carries the `p` prefix in the rendered body, the label, or the metadata block — the `p` prefix is reserved for priority so a reader scanning the body cannot mistake `Phase: P0` for `Priority: P0`.** When `priority` was derived (not explicit), append the `*(derived from severity)*` suffix; when `points` was derived, append `*(derived from storyPoints)*` or `*(derived from effort)*` per the source Step 3 bullet 5 used. When none of the five dimensions resolved, substitute the EMPTY STRING (no heading). This block lives **inside the existing `## Details` section** of the issue template — no new section heading is emitted.
   - `{{TRIGGER_CONDITION_BLOCK}}` → when `description.trigger` is a non-empty string on the story, render:

     ```
     ## Trigger Condition

     {{description.trigger}}
     ```

     When `description.trigger` is absent or empty, substitute the EMPTY STRING (no heading, no placeholder text). This keeps the body clean for the common case.
   - `{{LABELS_LIST}}` → bulleted list, one label per line.
   - `{{ARCH_MODULES_LIST}}` → bulleted list of matched module slugs (or the literal text `_no module match_`).
   - `{{SUCCESS_SCENARIOS}}` → render each `successScenarios[]` entry as a Gherkin block (`*Scenario N: {title}*\nGiven {given}\nWhen {when}\nThen {then}\nAnd {and[i]}...`). Note: `acceptanceTestCases[]` (written by `create-acceptance-tests`) is NOT rendered here — it is a QA artifact stored in `stories.json` for downstream tooling, not for the GitHub issue body.
   - `{{OUT_OF_SCOPE}}` → bulleted list of `description.outOfScope[]` (or `_none_` when empty).
   - `{{DEFINITION_OF_DONE}}` → checkbox list `- [ ] <item>` for each `definitionOfDone[]` entry.
   - `{{BLOCKED_BY_LINE}}` → `Blocked by: #<n1>, #<n2>` using real issue numbers from earlier in the batch (or `Blocked by: _none_`).
   - `{{BLOCKS_LINE}}` → `Blocks: _set by upstream story_` (cannot resolve forward-references; downstream skills may patch later).
   - `{{RELATED_LINE}}` → `Related: _none_`.
2. Write the rendered body to a temp file:
   ```bash
   TMPFILE="$(mktemp /tmp/to-issues-XXXXXX.md)"
   ```
3. Call:
   ```bash
   ISSUE_URL="$(GH_HOST=github.com gh issue create \
     --repo "$TARGET_REPO" \
     --title "[$PROJECT_NAME] $STORY_SUMMARY" \
     --body-file "$TMPFILE" \
     $(printf -- '--label %q ' "${LABELS_ARRAY[@]}"))"
   ISSUE_NUMBER="$(basename "$ISSUE_URL")"
   ```
4. **Retroactive `blocking:N` patch** — immediately after creating the issue, for each upstream issue referenced in `RESOLVED_BLOCKED_BY[]` (the real issue numbers resolved in step 1), create the per-dependency labels and apply them:
   ```bash
   for UPSTREAM_NUM in "${RESOLVED_BLOCKED_BY[@]}"; do
     GH_HOST=github.com gh label create "blocking:${ISSUE_NUMBER}" \
       --repo "$TARGET_REPO" --color "D93F0B" \
       --description "Blocks issue #${ISSUE_NUMBER}" 2>/dev/null || true
     GH_HOST=github.com gh issue edit "$UPSTREAM_NUM" \
       --repo "$TARGET_REPO" \
       --add-label "blocking:${ISSUE_NUMBER}" 2>/dev/null || true
   done
   ```
   This is a best-effort call (`|| true`) — a label-apply failure does not abort the batch. Log `[to-issues:auto] story <n>: patching blocking:<ISSUE_NUMBER> onto upstream #<UPSTREAM_NUM>` in autonomous mode.
5. **Plan emission** — after the issue is created and the blocking patch is applied, if the story does NOT carry the label `type:future-enhancement`, write `$REPO_ROOT/specs/$SLUG/plan-${ISSUE_NUMBER}.md` using the template at `references/plan-template.md`. Populate the template by substituting:
   - `{{ISSUE_NUMBER}}` → the created issue number (from `ISSUE_NUMBER`).
   - `{{STORY_SUMMARY}}` → the story's `summary` field.
   - `{{TASKS_LIST}}` → one markdown bullet per scope item from `description.scope`. When `scope` is a single string, split on `;` or `,` (trim whitespace from each piece); each piece becomes a `- <item>` bullet. When `scope` is an array, use each element directly as a `- <item>` bullet.
   - `{{AC_LIST}}` → one markdown bullet per `successScenarios[]` entry (using the `then` field as the bullet text; if `and[]` is non-empty on the scenario, append each `and[]` item as an additional sub-bullet indented with two spaces). When `acceptanceTestCases[]` is non-empty, append the `then` and `and[]` lines from those entries as additional bullets.

   The written plan file path is `$REPO_ROOT/specs/$SLUG/plan-${ISSUE_NUMBER}.md`. In autonomous mode, log: `[to-issues:auto] story <n>: wrote plan-<ISSUE_NUMBER>.md`

   For `type:future-enhancement` stories: skip this step entirely (no plan file is written).
6. Append the new entry to an in-memory list with `issue_number`, `url`, `title`, `labels`, `blocked_by`.

**Partial-failure semantics (D13):** if any `gh issue create` call fails, stop the batch immediately. Persist the partial `created-issues.json` (Step 6) containing only the successfully-created entries. Print:

```
[to-issues] PARTIAL FAILURE — created N of M issues. Inspect specs/$SLUG/created-issues.json and re-run with the remaining stories, or delete the partial artifact to start over.
```

Exit with status 1. Do not attempt to delete the issues already created.

**DRY_RUN mode (D12):** when `DRY_RUN=1` is set in the environment, skip every `gh ... create` call. Print the assembled command to stdout instead and assign synthetic sequential issue numbers starting at 1 in batch order. The artifact is still written and is byte-equivalent to a real run apart from `issue_number` (synthetic) and `url` (constructed as `https://github.com/$TARGET_REPO/issues/<n>` — the same shape, with the synthetic number). No network call is made.

### Step 6 — Write the handoff artifact

```bash
ARTIFACT="$REPO_ROOT/specs/$SLUG/created-issues.json"
python3 - <<EOF
import json, jsonschema
artifact = {
    "schema_version": "1",
    "slug": "$SLUG",
    "issues": $ISSUES_JSON,
}
schema = json.load(open('$REPO_ROOT/plugins/makato-plan/skills/to-issues/references/created-issues.schema.json'))
jsonschema.validate(artifact, schema)
open('$ARTIFACT', 'w').write(json.dumps(artifact, indent=2) + '\n')
print(f"[to-issues] wrote {len(artifact['issues'])} issues to $ARTIFACT")
EOF
```

Validation failure on `created-issues.json` is a bug in this skill — abort the run with the validation error and DO NOT write the artifact.

### Step 6a — Stage and guard the planning artifacts (#527)

The autonomous build-refine lane (`makato-orchestrate` po-agent Step 1a
`materialize-refine`) only fires when `stories.json` is **git-tracked** — a
fresh clone/worktree of the target repo must carry it, or the po-agent
degrades to the tier-based fallback and a full-tier issue dead-ends at
HALT-006. So after writing `created-issues.json`, stage both planning
artifacts and fail loudly if either remains untracked:

```bash
STORIES="$REPO_ROOT/specs/$SLUG/stories.json"
CREATED="$REPO_ROOT/specs/$SLUG/created-issues.json"

# Stage both. `git add` respects .gitignore, so this is a no-op signal check:
# if the consumer repo's .gitignore still blocks specs/**/stories.json (i.e.
# it lacks the !specs/**/stories.json negation), the file stays untracked and
# the guard below fires with a precise remediation.
git -C "$REPO_ROOT" add -- "$STORIES" "$CREATED" 2>/dev/null || true

for f in "$STORIES" "$CREATED"; do
  # `git ls-files` lists a path only when it is tracked or staged. Empty
  # output => the artifact will NOT travel with a fresh clone.
  if [[ -z "$(git -C "$REPO_ROOT" ls-files -- "$f")" ]]; then
    cat >&2 <<MSG
[to-issues] HALT: $f is untracked after write.
[to-issues] The autonomous build-refine lane requires stories.json (and
[to-issues] created-issues.json) to be committed so they survive a fresh clone.
[to-issues] Your repo's .gitignore is blocking them. Add these negations AFTER
[to-issues] the '!specs/**/' directory-descent escape:
[to-issues]     !specs/**/stories.json
[to-issues]     !specs/**/created-issues.json
[to-issues] then re-run to-issues (or 'git add -f' the artifacts and commit).
MSG
    exit 1
  fi
done

echo "[to-issues] staged planning artifacts: stories.json, created-issues.json"
```

In autonomous mode log `[to-issues:auto] staged + guarded stories.json,
created-issues.json (tracked)`. The guard is a HALT (`exit 1`), not a warning —
an untracked `stories.json` silently disables the entire autonomous
materialize-refine path downstream, so surfacing it at emission time is the
only place a human sees the misconfiguration before a fresh-clone run fails.
`to-issues` **stages** the artifacts (`git add`); the commit itself belongs to
the operator's normal flow — the skill never commits or pushes.

### Step 7 — Hand off

Print the final summary:

```
[to-issues] Created N issues for slug '<slug>' on github.com/$TARGET_REPO.
[to-issues] Artifact: specs/<slug>/created-issues.json
[to-issues] Staged (git add): specs/<slug>/stories.json, specs/<slug>/created-issues.json — commit them so the autonomous build-refine lane can consume stories.json on a fresh clone (#527).
[to-issues] Next: implement one work item and run /makato-build:build-create-pr <key> --issue N — it injects Closes #N only for that work item, never sibling issues in the shared artifact.
```

## Anti-patterns

**NEVER derive `phase:` from `stories[].phase`.**
WHY: `stories[].phase` is the vertical-slice tier (`foundation`, `happy-path`, `edge-cases`) — it already drives `tier:`. Emitting it as `phase:` too would produce conflated labels where `phase:foundation` means *vertical position in a single feature*, which contradicts the numeric cross-plan sequencing that `phase:1`–`phase:5` encodes. Callers reading `phase:` expect to filter by release wave, not by slicing order.

**NEVER read ADR file contents during module matching.**
WHY: Module matching is intentionally a folder-name-only signal. Reading file bodies would (a) balloon context on large repos, (b) bleed private design decisions into label inference, and (c) couple this skill to the internal format of each ADR document. The folder slug is the public API; the file body is not.

**NEVER auto-emit `status:in-progress` or `status:done`.**
WHY: Lifecycle transitions are owned by `makato-orchestrate` (loop skill, promote-ready). If `to-issues` stamped issues `status:in-progress`, the promote-ready dependency check would skip them as already-started, breaking the dependency-wave ordering that the whole autonomous lane depends on.

**NEVER target an enterprise GitHub host (non-`github.com`) or set `GH_HOST` to anything other than `github.com`.**
WHY: The 2.x enterprise wiring (`GH_ENTERPRISE_TOKEN`, custom TLS) was removed in v3. Attempting it silently creates labels and issues on the wrong host, producing a split-brain state where `created-issues.json` references one host and the downstream build lane (which always calls `github.com`) targets another. The result is broken PR `Closes #N` links and board-sync failures with no obvious error.

**NEVER abort on a retroactive `blocking:N` label-patch failure.**
WHY: The upstream issue already exists and the downstream issue was just created — aborting would leave `created-issues.json` in a truncated state while the upstream issue is intact. The dependency information is advisory (used by `promote-ready` to drive wave ordering), not structural. A missed `blocking:N` patch is a cosmetic gap that `promote-ready --dry-run` can detect; aborting would sacrifice all remaining issues in the batch for a non-critical annotation.

**NEVER re-run to-issues against a slug that already has a `created-issues.json` without deleting or archiving the prior artifact first.**
WHY: `gh issue create` is not idempotent — GitHub has no duplicate-detection on title alone. A second run creates duplicate issues with identical titles. The artifact guard does not check for a pre-existing `created-issues.json`; that check belongs to the caller. The canonical recovery path is to delete the duplicate issues via `gh issue delete`, then delete `created-issues.json` and re-run from scratch.

**NEVER fall back silently when `stories[].summary` is missing or empty.**
WHY: `summary` is the GitHub issue title. A blank or absent title causes `gh issue create` to fail with an opaque API error (422 Unprocessable Entity). Checking upfront — before any network call — prevents partial-batch creation where the first N stories succeed and story N+1 fails with a title error, leaving a `PARTIAL_FAILURE` artifact that does not indicate the root cause. Emit `[to-issues] ERROR: story <n> has no summary — aborting before any gh calls` and exit 1 with `MISSING_INPUT`.

## Autonomous Execution

Autonomous mode activates when ANY of:
- `--autonomous` is passed on the CLI.
- A context bundle with a `task_id` field is provided.
- `$AGENT_ID` is exported in the environment.

In autonomous mode:
- **Never prompt the user** — all inference decisions apply silently.
- **Log every choice** to stdout, prefixed `[to-issues:auto]`. Format: `[to-issues:auto] story <n> title="<...>" type=<...> tier=<...> tech=[...] module=[...] body_bytes=<n>`.
- **Stage and guard the planning artifacts (Step 6a, #527)** — `git add` `stories.json` + `created-issues.json` and HALT with `UNTRACKED_ARTIFACTS` if either stays untracked (the consumer repo's `.gitignore` lacks the negations). This is a hard `exit 1`, not a warning — an untracked `stories.json` silently disables the downstream autonomous materialize-refine path.
- Skip out-of-scope stories — never invent stories that aren't in stories.json. If `stories.json` is empty, exit 0 and write an empty artifact `{ "schema_version": "1", "slug": "<slug>", "issues": [] }`.

### Return Format (R1, when called as a sub-skill)

```json
{
  "status": "COMPLETED" | "PARTIAL" | "FAILED",
  "summary": "Created N issues",
  "artifact_path": "specs/<slug>/created-issues.json",
  "issues_created": N,
  "target_repo": "owner/repo",
  "dry_run": true | false
}
```

### HALT Codes

| Code | Meaning |
|------|---------|
| `MISSING_INPUT` | No `stories.json` found and no fallback `plan.md` or context |
| `MALFORMED_CONFIG` | `.claude/config.json` exists but is not valid JSON |
| `GH_AUTH_FAILED` | `gh` CLI returns auth error — caller must run `gh auth login` |
| `SCHEMA_VALIDATION_FAILED` | Generated `created-issues.json` failed schema validation (skill bug — file an issue) |
| `PARTIAL_FAILURE` | `gh issue create` failed mid-batch; partial artifact persisted |
| `UNTRACKED_ARTIFACTS` | `stories.json` or `created-issues.json` remained untracked after write (Step 6a) — the consumer repo's `.gitignore` lacks the `!specs/**/stories.json` / `!specs/**/created-issues.json` negations, so the autonomous build-refine lane cannot consume them on a fresh clone (#527) |
