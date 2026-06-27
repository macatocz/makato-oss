---
name: to-issues
description: >-
  Use when user wants to convert a plan into issues, create implementation tickets, or break
  down a feature into GitHub issues. Generic across makato consumers — reads `.claude/config.json`
  for project name, targets `github.com`, applies a 10-dimension label taxonomy
  (type/tier/tech/module/severity/phase/effort/priority/points/status), maps stories to ADR folders by
  name pattern, and emits `specs/{slug}/created-issues.json` for downstream plugins.
license: MIT
version: "3.4.0"
argument-hint: "[optional: feature slug] [--dry-run] [--interactive|--autonomous]"
allowed-tools: Bash(gh *) Bash(git *) Bash(python3 *) Read Write Grep Glob
hooks: ["convert to issues", "break into issues", "create github issues", "turn this into tickets", "issue breakdown", "create implementation tickets", "decompose into issues", "publish stories", "create issues from stories.json"]
metadata:
  Authors: makato contributors
  last_updated: "2026-06-27"
  mcp_server: none
---

# To Issues

Create GitHub issues on **github.com** from a shaped `stories.json`. Each issue carries a 9-dimension label set — type / tier / tech / module / severity / phase / effort / priority / status (the last is sparse, emitted only when non-default; the four prioritization dimensions are sparse-by-default too — emitted only when `stories[].metadata` is present) — an architecture-mapped module annotation, and a body rendered from a versioned template. Writes `specs/{slug}/created-issues.json` as a machine-readable handoff for downstream skills (e.g. `build-create-pr`, `issue-to-project`).

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

- **MANDATORY** — load `references/label-taxonomy.md` for the 9-dimension taxonomy (`type:` / `tier:` / `tech:` / `module:` / `severity:` / `phase:` / `effort:` / `priority:` / `status:`), type-inference table, ADR-match algorithm, config-extension contract, and the sparse `status:` inference rules in `## Status Dimension`.
- **MANDATORY** — load `references/issue-template.md` for the body template (single edit point for issue body format).
- **MANDATORY** — load `references/created-issues.schema.json` as the validation schema for the output artifact.
- `references/slice-patterns.md` — only when a slice boundary is ambiguous or the caller asks about vertical-slicing strategy.

## Process

### Step 0 — Resolve repo, target, and project name

```bash
REPO_ROOT="$(git rev-parse --show-toplevel)" || { echo "Not a git repo — aborting" >&2; exit 1; }
REMOTE_URL="$(git -C "$REPO_ROOT" remote get-url origin)"
TARGET_REPO="$(echo "$REMOTE_URL" | sed -E 's|.*github\.com[:/]||; s|\.git$||')"

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

1. **type**: regex match the story title + scope against the inference table, top-to-bottom; first match wins; default `type:feat`.
2. **tier**: copy `stories[].phase` verbatim, prefixed `tier:`. **Skip this dimension entirely when `type:future-enhancement` was inferred** — future-enhancement issues are pre-phase and carry no `tier:` label. In autonomous mode log `[to-issues:auto] story <n>: tier skipped (type:future-enhancement)`.
3. **tech**: match story title + scope against the default tech keyword map AND any `labels.tech` patterns from `.claude/config.json`. Defaults evaluate first; config entries are appended (D14 union-with-defaults). Multiple matches → multiple `tech:` labels.
4. **module**: tokenize the story (title + scope + background, lowercased, alphanumeric runs ≥3 chars). For each ADR folder slug, emit `module:<slug>` when at least one slug token appears in the story's token set. Emit ALL matching modules. If none match, log `[to-issues:auto] story <n>: no module match` and omit the dimension.
5. **severity / phase / effort / priority / points** *(v3.3.0+, all optional)*: read `stories[].metadata.{severity, phase, effort, priority, points}` and emit one label per resolved value:
   - `metadata.severity` ∈ {`critical`, `high`, `medium`, `low`} → `severity:<value>` verbatim.
   - `metadata.phase` ∈ {`1`, `2`, `3`, `4`, `5`} → `phase:<value>` verbatim. **Bare digits only — no `p` prefix** (reserved for `priority:*`). For backward compatibility, `"p1"` through `"p5"` are auto-normalized to `"1"` through `"5"` with a soft-warn `[to-issues:auto] story <n>: metadata.phase="p1" auto-normalized to "1" (the "p" prefix is reserved for priority:*)`.
   - `metadata.effort` ∈ {`s`, `m`, `l`, `xl`} → `effort:<value>` verbatim.
   - `metadata.priority` ∈ {`p0`, `p1`, `p2`, `p3`} → `priority:<value>` verbatim. **If `metadata.priority` is absent AND `metadata.severity` is present, derive via the severity→priority map** (`critical→p0`, `high→p1`, `medium→p2`, `low→p3`) and log `[to-issues:auto] story <n>: priority:<derived> derived from severity:<value>`.
   - `metadata.points` *(v3.4.0+)* — if present, must be a positive integer → `points:<value>` verbatim. **If `metadata.points` is absent AND `metadata.effort` is present, derive via the SIZE_MAP** (`s→1`, `m→3`, `l→8`, `xl→13`) and log `[to-issues:auto] story <n>: points:<derived> derived from effort:<value>`. Non-positive or non-integer values log `[to-issues:auto] story <n>: metadata.points=<value> not a positive integer — skipped` and are omitted.
   - Any other value outside the documented enum logs `[to-issues:auto] story <n>: <field>=<value> not in enum — skipped` and is omitted (the issue is still created).
   - When `stories[].metadata` is absent entirely, all five labels are omitted silently (no warning — these dimensions are sparse-by-default).
6. **status**: emit `status:blocked` when ANY of the following hold, otherwise omit the `status:` dimension entirely (sparse — see `references/label-taxonomy.md` `## Status Dimension`):
   - The story's `dependencies.blockedBy` contains an integer ID that is unresolved at the point of issue creation. "Unresolved" means: (a) the upstream story has no corresponding GitHub issue yet AND (b) the upstream story was not created earlier in the current batch's topological order. Dangling references (ID not in batch at all) also emit `status:blocked` with a soft-warning log line.
   - The story was inferred as `type:future-enhancement` in bullet 1 above (per v3.1.0).
   - The story's `stories[].labels` array contains the literal string `status:blocked` (explicit operator override).
   When an explicit `stories[].labels` value contradicts inference (e.g. the operator wrote `status:todo` on a story that would otherwise infer `status:blocked`), the explicit value wins; log `[to-issues:auto] story <n>: status inference (<inferred>) overridden by explicit label (<explicit>)`.
   `status:in-progress` and `status:done` are taxonomy values but are **never** auto-emitted by this skill — lifecycle transitions belong to a future `manage-github-project` skill.

In `--interactive` mode, after inference for each story, present the proposed label set and ask `confirm / edit / skip` before proceeding to creation. In `--autonomous` mode, log every inferred label to stdout (one line per story, prefixed `[to-issues:auto] story <n>:`).

### Step 4 — Ensure required labels exist on the repo

```bash
EXISTING_LABELS="$(GH_HOST=github.com gh label list --repo "$TARGET_REPO" --limit 200 --json name --jq '.[].name')"
```

For each unique label across all stories, if it is not in `EXISTING_LABELS`, create it using the colors documented in `references/label-taxonomy.md`:

```bash
GH_HOST=github.com gh label create "<label>" --repo "$TARGET_REPO" --color "<hex>" --description "Auto-created by to-issues v3"
```

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
   - `{{METADATA_BLOCK}}` *(v3.3.0+)* → human-readable rendering of `stories[].metadata`. When the metadata dict has any of `severity`, `phase`, `effort`, `priority`, `points`, render one bold line per present key:

     ```
     **Severity:** CRITICAL
     **Phase:** 1
     **Effort:** M
     **Points:** 3 *(derived from effort)*
     **Priority:** p0 *(derived from severity)*
     ```

     Values render uppercase for `severity` (`critical → CRITICAL`), **bare digits** for `phase` (`1`–`5`; if the input was the deprecated `p1` form, render `1`), uppercase for `effort` (`m → M`), bare integer for `points`, and lowercase for `priority` (`p0`). **Phase never carries the `p` prefix in the rendered body, the label, or the metadata block — the `p` prefix is reserved for priority so a reader scanning the body cannot mistake `Phase: P0` for `Priority: P0`.** When `priority` was derived (not explicit), append the `*(derived from severity)*` suffix; when `points` was derived, append `*(derived from effort)*`. When `metadata` is absent or all five fields are absent, substitute the EMPTY STRING (no heading). This block lives **inside the existing `## Details` section** of the issue template — no new section heading is emitted.
   - `{{TRIGGER_CONDITION_BLOCK}}` → when `description.trigger` is a non-empty string on the story, render:

     ```
     ## Trigger Condition

     {{description.trigger}}
     ```

     When `description.trigger` is absent or empty, substitute the EMPTY STRING (no heading, no placeholder text). This keeps the body clean for the common case.
   - `{{LABELS_LIST}}` → bulleted list, one label per line.
   - `{{ARCH_MODULES_LIST}}` → bulleted list of matched module slugs (or the literal text `_no module match_`).
   - `{{SUCCESS_SCENARIOS}}` → render each `successScenarios[]` entry as a Gherkin block (`*Scenario N: {title}*\nGiven {given}\nWhen {when}\nThen {then}\nAnd {and[i]}...`).
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
     --title "[$PROJECT_NAME] $STORY_TITLE" \
     --body-file "$TMPFILE" \
     $(printf -- '--label %q ' "${LABELS_ARRAY[@]}"))"
   ISSUE_NUMBER="$(basename "$ISSUE_URL")"
   ```
4. Append the new entry to an in-memory list with `issue_number`, `url`, `title`, `labels`, `blocked_by`.

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

### Step 7 — Hand off

Print the final summary:

```
[to-issues] Created N issues for slug '<slug>' on github.com/$TARGET_REPO.
[to-issues] Artifact: specs/<slug>/created-issues.json
[to-issues] Next: implement the work and run /makato-build:build-create-pr — it will auto-inject Closes #N for each issue when you create the PR.
```

## Autonomous Execution

Autonomous mode activates when ANY of:
- `--autonomous` is passed on the CLI.
- A context bundle with a `task_id` field is provided.
- `$AGENT_ID` is exported in the environment.

In autonomous mode:
- **Never prompt the user** — all inference decisions apply silently.
- **Log every choice** to stdout, prefixed `[to-issues:auto]`. Format: `[to-issues:auto] story <n> title="<...>" type=<...> tier=<...> tech=[...] module=[...] body_bytes=<n>`.
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
