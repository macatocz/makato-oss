# to-issues Skill Redesign — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rewrite the `to-issues` skill so any makato repo with `.claude/config.json` can produce richly-labelled GitHub issues on `github.com` and a machine-readable `created-issues.json` artifact, and update `build-create-pr` to auto-inject `Closes #N` from that artifact.

**Architecture:** A two-story epic shipped in a single PR. Story 1 rewrites `plugins/makato-plan/skills/to-issues/` end-to-end: SKILL.md becomes config-driven with a 4-dimension label taxonomy (type/tier/tech/module), three new reference files (`label-taxonomy.md`, `issue-template.md`, `created-issues.schema.json`), a `DRY_RUN=1` mode for fresh-repo verification, and a 2.4.0 → 3.0.0 breaking-change bump. Story 2 extends `plugins/makato-build/skills/build-create-pr/` to read the artifact and inject `Closes #N` into the PR body Links section (no regression when absent). Verification is static (grep, JSON-Schema validation, diff snapshots) — no test runtime is added because skills are markdown + bash directives, not code.

**Tech Stack:** Markdown, JSON Schema (draft-07), `gh` CLI, `python3` (for JSON parsing — already required), bash. No new dependencies.

## Global Constraints

- Skill home: `plugins/makato-plan/skills/to-issues/` (D8 — stays in `makato-plan`).
- Self-contained: no `../` paths leaving the skill directory; only `../shared` references inside the plugin are permitted, and `to-issues` does not currently use shared/.
- Target host: `github.com` only — no `GH_HOST=github.concur.com`, `GH_ENTERPRISE_TOKEN`, or `TLS bypass` references anywhere in skill files.
- Version bumps: `to-issues` SKILL.md frontmatter `2.4.0` → `3.0.0`; `build-create-pr` SKILL.md frontmatter `1.2.0` → `1.3.0`.
- Conventional-commit titles: `feat(makato-plan): …` for Story 1 commits and `feat(makato-build): …` for Story 2 commits. Breaking-change body footer `BREAKING CHANGE: …` on the SKILL.md rewrite commit.
- Project-name resolution: read `.claude/config.json` `"project"` key; silent fallback to `"sagibeast"` on missing file/key; halt with error on malformed JSON. Mirror makato-core/create-issue v1.1.0 byte-for-byte.
- Label taxonomy merge policy (D14): config additions (`labels.tech`, `labels.modules`) are union-with-defaults; conflicting names log a warning and keep the default.
- ADR matching (D16): lowercase-token intersection between story title/body and ADR folder slug; ≥1 distinct token match; emit ALL matching folders as module labels.
- Type inference (D17): explicit keyword table in `references/label-taxonomy.md`; default `feat` when no keyword matches.
- Autonomous-mode log location (D15): stdout, prefixed `[to-issues:auto]`, one line per inference decision per issue.
- Partial-failure semantics (D13): halt batch on first `gh issue create` failure; persist partial artifact with only successful entries; print resume hint; no automatic rollback.
- Legacy migration (D18): if `.claude/rules/project-information.md` exists, emit a warning identifying it and the new `config.json` path before continuing; do not auto-migrate.
- Slug resolution in `build-create-pr` (D19): reuse the existing `specs/<work-item-key>-*/` glob; lexically-latest on multiple matches; skip silently on none.
- `Closes #N` dedupe (D20): when both an explicit `GH#N` reference and `created-issues.json` exist, dedupe so each `Closes #N` appears at most once; `created-issues.json` wins ties.
- Malformed artifact handling (D21): log a single warning naming the artifact path and validation error; create the PR with current behavior (no Closes injection); never block PR creation.

---

## File Structure

| Status | Path | Responsibility |
|--------|------|----------------|
| Modify | `plugins/makato-plan/skills/to-issues/SKILL.md` | Full rewrite: config.json read, github.com target, 4D taxonomy, ADR mapping, dep-ordered creation, DRY_RUN, partial-failure, autonomous-mode log, migration warning, version 3.0.0 |
| Create | `plugins/makato-plan/skills/to-issues/references/label-taxonomy.md` | Default taxonomy (type/tier/tech/module), type-inference keyword table, ADR-matching algorithm spec, config-extension contract, label merge policy |
| Create | `plugins/makato-plan/skills/to-issues/references/issue-template.md` | Versioned `{{PLACEHOLDER}}` body template — single source of truth for issue body format |
| Create | `plugins/makato-plan/skills/to-issues/references/created-issues.schema.json` | JSON Schema (draft-07) for the artifact: `slug`, `schema_version`, `issues[]` with `issue_number`, `url`, `title`, `labels`, `blocked_by` |
| Delete | `plugins/makato-plan/skills/to-issues/references/project-info-format.md` | Obsolete mechanism — replaced by `.claude/config.json` |
| Modify | `plugins/makato-plan/CHANGELOG.md` | Add `to-issues` 3.0.0 entry under the existing skill changelog grouping with a BREAKING marker |
| Modify | `plugins/makato-build/skills/build-create-pr/SKILL.md` | Add artifact-detection step, Step 5 PR body injection, Step 6 Case 4 (created-issues.json), dedupe rule, schema-validation guard; bump 1.2.0 → 1.3.0 |
| Modify | `plugins/makato-build/skills/build-create-pr/references/pr-description-guide.md` | Add row to the Links table for `created-issues.json` injection |
| Modify | `plugins/makato-build/CHANGELOG.md` | Add `build-create-pr` 1.3.0 entry |
| Keep | `plugins/makato-plan/skills/to-issues/references/slice-patterns.md` | Reference still useful — no concur content; keep as-is |

---

## Task 1: JSON Schema for `created-issues.json`

**Files:**
- Create: `plugins/makato-plan/skills/to-issues/references/created-issues.schema.json`
- Test: `specs/to-issues-skill-redesign/fixtures/schema-test.sh` (throwaway verification script; not committed)

**Interfaces:**
- Consumes: (nothing — first task)
- Produces: JSON Schema at `plugins/makato-plan/skills/to-issues/references/created-issues.schema.json` consumed by Task 4 (SKILL.md references it) and Task 7 (build-create-pr validates against it). Artifact shape: `{ schema_version: string, slug: string, issues: Array<{ issue_number: integer, url: string, title: string, labels: string[], blocked_by: integer[] }> }`. `schema_version` is the literal string `"1"`.

- [ ] **Step 1: Write the failing check**

```bash
mkdir -p /tmp/to-issues-fixtures
cat > /tmp/to-issues-fixtures/sample.json <<'EOF'
{
  "schema_version": "1",
  "slug": "to-issues-skill-redesign",
  "issues": [
    {
      "issue_number": 42,
      "url": "https://github.com/owner/repo/issues/42",
      "title": "[to-issues] Generic rewrite",
      "labels": ["type:feat", "tier:foundation", "tech:python", "module:to-issues"],
      "blocked_by": []
    },
    {
      "issue_number": 43,
      "url": "https://github.com/owner/repo/issues/43",
      "title": "[build-create-pr] Closes injection",
      "labels": ["type:feat", "tier:happy-path", "tech:bash", "module:build-create-pr"],
      "blocked_by": [42]
    }
  ]
}
EOF

python3 -c "
import json, sys
try:
    import jsonschema
except ImportError:
    print('jsonschema not installed — installing now')
    import subprocess; subprocess.check_call([sys.executable, '-m', 'pip', 'install', '--quiet', 'jsonschema'])
    import jsonschema
schema = json.load(open('plugins/makato-plan/skills/to-issues/references/created-issues.schema.json'))
sample = json.load(open('/tmp/to-issues-fixtures/sample.json'))
jsonschema.validate(sample, schema)
print('PASS')
"
```

Expected: FAIL with `FileNotFoundError: ... created-issues.schema.json` — file does not exist yet.

- [ ] **Step 2: Create the schema file**

Write `plugins/makato-plan/skills/to-issues/references/created-issues.schema.json`:

```json
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "$id": "https://github.com/zstary/makato/plugins/makato-plan/skills/to-issues/references/created-issues.schema.json",
  "title": "created-issues.json",
  "description": "Machine-readable handoff emitted by the to-issues skill. Consumed by build-create-pr to auto-inject Closes #N into PR bodies.",
  "type": "object",
  "required": ["schema_version", "slug", "issues"],
  "additionalProperties": false,
  "properties": {
    "schema_version": {
      "type": "string",
      "const": "1",
      "description": "Schema version. Bump when the shape changes in a non-backwards-compatible way."
    },
    "slug": {
      "type": "string",
      "minLength": 1,
      "description": "The kebab-case feature slug — the spec folder name without the leading work-item key."
    },
    "issues": {
      "type": "array",
      "items": {
        "type": "object",
        "required": ["issue_number", "url", "title", "labels", "blocked_by"],
        "additionalProperties": false,
        "properties": {
          "issue_number": {
            "type": "integer",
            "minimum": 1,
            "description": "GitHub issue number (real on a normal run; synthetic 1,2,3... in DRY_RUN=1 mode)."
          },
          "url": {
            "type": "string",
            "format": "uri",
            "description": "Canonical issue URL on github.com."
          },
          "title": {
            "type": "string",
            "minLength": 1
          },
          "labels": {
            "type": "array",
            "items": { "type": "string", "minLength": 1 },
            "description": "Flat label list — entries follow the `dimension:value` convention (e.g. type:feat, tier:foundation, tech:python, module:to-issues)."
          },
          "blocked_by": {
            "type": "array",
            "items": { "type": "integer", "minimum": 1 },
            "description": "Issue numbers (not story sequences) of upstream blockers — references real, already-created issues from earlier in the same batch."
          }
        }
      }
    }
  }
}
```

- [ ] **Step 3: Re-run the check — should PASS**

```bash
python3 -c "
import json, jsonschema
schema = json.load(open('plugins/makato-plan/skills/to-issues/references/created-issues.schema.json'))
sample = json.load(open('/tmp/to-issues-fixtures/sample.json'))
jsonschema.validate(sample, schema)
print('PASS')
"
```

Expected output: `PASS`

- [ ] **Step 4: Negative test — invalid fixture must FAIL validation**

```bash
cat > /tmp/to-issues-fixtures/bad.json <<'EOF'
{ "schema_version": "1", "slug": "x", "issues": [{ "url": "no-number", "title": "t", "labels": [], "blocked_by": [] }] }
EOF
python3 -c "
import json, jsonschema
schema = json.load(open('plugins/makato-plan/skills/to-issues/references/created-issues.schema.json'))
bad = json.load(open('/tmp/to-issues-fixtures/bad.json'))
try:
    jsonschema.validate(bad, schema)
    print('UNEXPECTED PASS — schema is too loose'); exit(1)
except jsonschema.ValidationError as e:
    print('PASS — caught:', e.message)
"
```

Expected: `PASS — caught: 'issue_number' is a required property`

- [ ] **Step 5: Commit**

```bash
git add plugins/makato-plan/skills/to-issues/references/created-issues.schema.json
git commit -m "feat(makato-plan): add created-issues.json schema (to-issues v3 contract)"
```

---

## Task 2: Label taxonomy reference

**Files:**
- Create: `plugins/makato-plan/skills/to-issues/references/label-taxonomy.md`

**Interfaces:**
- Consumes: nothing (pure documentation reference).
- Produces: A reference document Task 4 (SKILL.md rewrite) links to as the canonical source of: (a) 4-dimension label taxonomy values for type/tier/tech/module, (b) keyword→type inference table, (c) ADR folder-matching algorithm spec, (d) `config.json` extension contract for `labels.tech` and `labels.modules`, (e) label-conflict merge policy.

- [ ] **Step 1: Failing check — file does not exist**

```bash
test -f plugins/makato-plan/skills/to-issues/references/label-taxonomy.md && echo "EXISTS (should fail)" || echo "MISSING (expected)"
```

Expected: `MISSING (expected)`

- [ ] **Step 2: Create the file**

Write `plugins/makato-plan/skills/to-issues/references/label-taxonomy.md`:

````markdown
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
| `\\b(fix\|bug\|broken\|regression\|hotfix\|patch)\\b` | `type:fix` |
| `\\b(docs?\|readme\|changelog\|comment)\\b` | `type:docs` |
| `\\b(refactor\|rename\|reorganize\|cleanup)\\b` | `type:refactor` |
| `\\b(test\|spec\|coverage)\\b` | `type:test` |
| `\\b(chore\|deps?\|bump\|ci\|build)\\b` | `type:chore` |
| (no match) | `type:feat` |

Evaluation order is top-to-bottom; first match wins. In autonomous mode (per D10), apply the inferred label silently and log the decision to stdout prefixed `[to-issues:auto]`. In interactive mode, propose the inferred label and ask the user to confirm or override.

## Default `tech` Keyword Map

Match each pattern against the lowercased story title + scope. Multiple matches → multiple `tech:` labels on the same issue.

| Pattern (case-insensitive, word-boundary) | Label |
|-------------------------------------------|-------|
| `\\bpython\\b` | `tech:python` |
| `\\bbash\\b` | `tech:bash` |
| `\\b(sql\|postgres\|sqlite\|duckdb)\\b` | `tech:sql` |
| `\\bfastapi\\b` | `tech:fastapi` |
| `\\btemporal\\b` | `tech:temporal` |
| `\\blanggraph\\b` | `tech:langgraph` |
| `\\bpydantic[- ]?ai\\b` | `tech:pydantic-ai` |
| `\\b(harness\|hook)\\b` | `tech:harness` |
| `\\bskill\\b` | `tech:skill` |
| `\\bhtml\\b` | `tech:html` |
| `\\b(react\|jsx\|tsx)\\b` | `tech:react` |
| `\\bgh\\b\|\\bgithub cli\\b` | `tech:gh-cli` |

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
      { "pattern": "\\bnext(\\\\.js)?\\b", "label": "tech:next" },
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
````

- [ ] **Step 3: Verify the file**

```bash
test -f plugins/makato-plan/skills/to-issues/references/label-taxonomy.md && echo "EXISTS (PASS)"
grep -q "## Type Inference Table" plugins/makato-plan/skills/to-issues/references/label-taxonomy.md && echo "type table PASS"
grep -q "## ADR Folder-Match Algorithm" plugins/makato-plan/skills/to-issues/references/label-taxonomy.md && echo "ADR algo PASS"
grep -q "## Config-Extension Contract" plugins/makato-plan/skills/to-issues/references/label-taxonomy.md && echo "contract PASS"
```

Expected: four `PASS` lines.

- [ ] **Step 4: Commit**

```bash
git add plugins/makato-plan/skills/to-issues/references/label-taxonomy.md
git commit -m "feat(makato-plan): add label-taxonomy reference for to-issues v3"
```

---

## Task 3: Issue body template

**Files:**
- Create: `plugins/makato-plan/skills/to-issues/references/issue-template.md`

**Interfaces:**
- Consumes: nothing (pure template).
- Produces: Versioned body template with `{{PLACEHOLDER}}` syntax. SKILL.md (Task 4) loads this file and substitutes placeholders. Placeholders defined here: `{{TITLE}}`, `{{STORY_SUMMARY}}`, `{{STORY_BACKGROUND}}`, `{{STORY_SCOPE}}`, `{{STORY_PHASE}}`, `{{LABELS_LIST}}`, `{{SUCCESS_SCENARIOS}}`, `{{OUT_OF_SCOPE}}`, `{{DEFINITION_OF_DONE}}`, `{{BLOCKED_BY_LINE}}`, `{{BLOCKS_LINE}}`, `{{RELATED_LINE}}`, `{{ARCH_MODULES_LIST}}`, `{{FEATURE_SLUG}}`.

- [ ] **Step 1: Failing check**

```bash
test -f plugins/makato-plan/skills/to-issues/references/issue-template.md && echo EXISTS || echo "MISSING (expected)"
```

Expected: `MISSING (expected)`

- [ ] **Step 2: Create the file**

Write `plugins/makato-plan/skills/to-issues/references/issue-template.md`:

````markdown
<!-- to-issues issue-template v1 — edit this file to change the body of every issue produced by the to-issues skill. -->

> *This issue was generated by the `to-issues` skill from `specs/{{FEATURE_SLUG}}/stories.json`. Edit story-level details in stories.json and re-run; edit body structure in `plugins/makato-plan/skills/to-issues/references/issue-template.md`.*

## Summary

{{STORY_SUMMARY}}

## Background

{{STORY_BACKGROUND}}

## Scope

{{STORY_SCOPE}}

## Phase

`{{STORY_PHASE}}`

## Labels

{{LABELS_LIST}}

## Architecture Modules

{{ARCH_MODULES_LIST}}

## Acceptance Criteria (draft Gherkin)

{{SUCCESS_SCENARIOS}}

## Out of Scope

{{OUT_OF_SCOPE}}

## Definition of Done

{{DEFINITION_OF_DONE}}

## Dependencies

{{BLOCKED_BY_LINE}}
{{BLOCKS_LINE}}
{{RELATED_LINE}}

---

*Feature slug: `{{FEATURE_SLUG}}` — produced by to-issues v3.x.*
````

- [ ] **Step 3: Verify placeholders are all present**

```bash
for ph in TITLE STORY_SUMMARY STORY_BACKGROUND STORY_SCOPE STORY_PHASE LABELS_LIST SUCCESS_SCENARIOS OUT_OF_SCOPE DEFINITION_OF_DONE BLOCKED_BY_LINE BLOCKS_LINE RELATED_LINE ARCH_MODULES_LIST FEATURE_SLUG; do
  grep -q "{{${ph}}}" plugins/makato-plan/skills/to-issues/references/issue-template.md && echo "${ph} PASS" || echo "${ph} MISSING"
done
```

Expected: 13 `PASS` lines and 1 `MISSING` line for `TITLE` (the title becomes the GitHub issue title via `gh --title`, not part of the body; documented in SKILL.md). If any other placeholder is `MISSING`, the file is incomplete — fix before committing.

- [ ] **Step 4: Commit**

```bash
git add plugins/makato-plan/skills/to-issues/references/issue-template.md
git commit -m "feat(makato-plan): add issue-template reference for to-issues v3"
```

---

## Task 4: Rewrite `to-issues` SKILL.md

**Files:**
- Modify: `plugins/makato-plan/skills/to-issues/SKILL.md` (full replacement)

**Interfaces:**
- Consumes: `references/created-issues.schema.json` (Task 1), `references/label-taxonomy.md` (Task 2), `references/issue-template.md` (Task 3).
- Produces: The user-facing skill entry-point. Calling agents/users run the skill expecting it to: (a) read `.claude/config.json`, (b) load `stories.json`, (c) infer labels per `label-taxonomy.md`, (d) render bodies per `issue-template.md`, (e) call `gh issue create` against `github.com`, (f) write `specs/{slug}/created-issues.json` validated against `created-issues.schema.json`. Frontmatter version is `"3.0.0"`.

- [ ] **Step 1: Failing checks — current file still has concur refs**

```bash
grep -c "concur" plugins/makato-plan/skills/to-issues/SKILL.md
```

Expected output: a non-zero number (≥8 lines currently contain `concur`).

- [ ] **Step 2: Replace the file with the v3 rewrite**

Write `plugins/makato-plan/skills/to-issues/SKILL.md` with the following content (full replacement — overwrite the existing file in one shot):

````markdown
---
name: to-issues
description: >-
  Use when user wants to convert a plan into issues, create implementation tickets, or break
  down a feature into GitHub issues. Generic across makato consumers — reads `.claude/config.json`
  for project name, targets `github.com`, applies a 4-dimension label taxonomy
  (type/tier/tech/module), maps stories to ADR folders by name pattern, and emits
  `specs/{slug}/created-issues.json` for downstream plugins.
license: MIT
argument-hint: "[optional: feature slug] [--dry-run] [--interactive|--autonomous]"
allowed-tools: Bash(gh *) Bash(git *) Bash(python3 *) Read Write Grep Glob
hooks: ["convert to issues", "break into issues", "create github issues", "turn this into tickets", "issue breakdown", "create implementation tickets", "decompose into issues", "publish stories", "create issues from stories.json"]
metadata:
  Authors: makato contributors
  version: "3.0.0"
  last_updated: "2026-06-23"
  mcp_server: none
---

# To Issues

Create GitHub issues on **github.com** from a shaped `stories.json`. Each issue carries a 4-dimension label set (type / tier / tech / module), an architecture-mapped module annotation, and a body rendered from a versioned template. Writes `specs/{slug}/created-issues.json` as a machine-readable handoff for downstream skills (e.g. `build-create-pr`).

**Breaking change vs. 2.x:** the skill no longer targets `github.concur.com`, no longer reads or writes `project-information.md`, and now requires a `.claude/config.json` at the repo root (silent fallback to `"sagibeast"` is provided).

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

- **MANDATORY** — load `references/label-taxonomy.md` for the 4-dimension taxonomy, type-inference table, ADR-match algorithm, and config-extension contract.
- **MANDATORY** — load `references/issue-template.md` for the body template (single edit point for issue body format).
- **MANDATORY** — load `references/created-issues.schema.json` as the validation schema for the output artifact.
- `references/slice-patterns.md` — only when a slice boundary is ambiguous or the caller asks about vertical-slicing strategy.

## Process

### Step 0 — Resolve repo, target, and project name

```bash
REPO_ROOT="$(git rev-parse --show-toplevel)" || { echo "Not a git repo — aborting" >&2; exit 1; }
REMOTE_URL="$(git -C "$REPO_ROOT" remote get-url origin)"
TARGET_REPO="$(echo "$REMOTE_URL" | sed -E 's|.*github\\.com[:/]||; s|\\.git$||')"

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
  ADR_FOLDERS="$(find "$REPO_ROOT/$ARCH_PATH" -mindepth 1 -maxdepth 1 -type d -printf '%f\\n' | sed -E 's/[^A-Za-z0-9]+/-/g; s/^-+|-+$//g; s/.*/\\L&/')"
else
  ADR_FOLDERS=""
fi
```

Note: on macOS `find` lacks `-printf` — use `find ... -type d | xargs -n1 basename` instead. Detect with `uname` and branch accordingly. Output is a newline-separated list of lowercase-hyphenated ADR slugs.

### Step 3 — Infer labels per story

For each story in `stories.json.stories[]`, apply the algorithm in `references/label-taxonomy.md`:

1. **type**: regex match the story title + scope against the inference table, top-to-bottom; first match wins; default `type:feat`.
2. **tier**: copy `stories[].phase` verbatim, prefixed `tier:`.
3. **tech**: match story title + scope against the default tech keyword map AND any `labels.tech` patterns from `.claude/config.json`. Defaults evaluate first; config entries are appended (D14 union-with-defaults). Multiple matches → multiple `tech:` labels.
4. **module**: tokenize the story (title + scope + background, lowercased, alphanumeric runs ≥3 chars). For each ADR folder slug, emit `module:<slug>` when at least one slug token appears in the story's token set. Emit ALL matching modules. If none match, log `[to-issues:auto] story <n>: no module match` and omit the dimension.

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
   - `{{STORY_PHASE}}` → `phase`.
   - `{{LABELS_LIST}}` → bulleted list, one label per line.
   - `{{ARCH_MODULES_LIST}}` → bulleted list of matched module slugs (or the literal text `_no module match_`).
   - `{{SUCCESS_SCENARIOS}}` → render each `successScenarios[]` entry as a Gherkin block (`*Scenario N: {title}*\\nGiven {given}\\nWhen {when}\\nThen {then}\\nAnd {and[i]}...`).
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
   ISSUE_URL="$(GH_HOST=github.com gh issue create \\
     --repo "$TARGET_REPO" \\
     --title "[$PROJECT_NAME] $STORY_TITLE" \\
     --body-file "$TMPFILE" \\
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
open('$ARTIFACT', 'w').write(json.dumps(artifact, indent=2) + '\\n')
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

## NEVER

- **NEVER target `github.concur.com` or set `GH_HOST=github.concur.com`** — v3 is github.com-only by D1. The 2.x compatibility wiring (GH_HOST, GH_ENTERPRISE_TOKEN, TLS bypass) is removed.
- **NEVER write back to `.claude/rules/project-information.md`** — that file is obsolete; `config.json` is read-only canonical. Emit the migration warning when the legacy file is detected, but do not modify it.
- **NEVER create issues out of dependency order** — `gh issue create` assigns sequential numbers, so a blocked issue must reference a real upstream number. Topo-sort first.
- **NEVER auto-override a default label with a config-supplied one of the same name** — the default wins; log the conflict instead (D14).
- **NEVER continue past a partial failure** — halt the batch, persist what was created, exit non-zero. Rollback of created GitHub issues is out of scope; the user resumes manually.
- **NEVER skip schema validation of the artifact** — a malformed `created-issues.json` would silently break `build-create-pr` downstream.
- **NEVER read ADR file contents** — folder names only (D5). Module matching is intentionally a folder-only signal.
- **NEVER prompt the user in autonomous mode** — all decisions are silent + logged. Prompting blocks the calling pipeline.
````

- [ ] **Step 3: Verify the rewrite — zero concur references and version 3.0.0**

```bash
grep -c "concur" plugins/makato-plan/skills/to-issues/SKILL.md
grep -E '^version:' plugins/makato-plan/skills/to-issues/SKILL.md
grep -E '^  version:' plugins/makato-plan/skills/to-issues/SKILL.md
grep -c "label-taxonomy.md" plugins/makato-plan/skills/to-issues/SKILL.md
grep -c "issue-template.md" plugins/makato-plan/skills/to-issues/SKILL.md
grep -c "created-issues.schema.json" plugins/makato-plan/skills/to-issues/SKILL.md
```

Expected output:
- `grep -c concur` → `0`
- `grep -E '^version:'` → no match (frontmatter uses `metadata.version`, not top-level)
- `grep -E '^  version:'` → `  version: "3.0.0"`
- Each `grep -c <reference>.md` → `≥1`

- [ ] **Step 4: Run `grep -r concur` against the whole skill folder — must be zero**

```bash
grep -r "concur" plugins/makato-plan/skills/to-issues/ && echo "FAIL — concur still present" || echo "PASS — no concur references"
```

Expected: `PASS — no concur references` (silent grep, no matches, then `PASS`).

- [ ] **Step 5: Commit**

```bash
git add plugins/makato-plan/skills/to-issues/SKILL.md
git commit -m "feat(makato-plan)!: rewrite to-issues as generic marketplace skill (v3.0.0)

BREAKING CHANGE: to-issues now targets github.com only. The 2.x github.concur.com / GH_ENTERPRISE_TOKEN / project-information.md wiring is removed. The project name is read from .claude/config.json (fallback 'sagibeast'). All issues now carry a 4-dimension label set (type/tier/tech/module) inferred from the story text and ADR folder names. A specs/<slug>/created-issues.json artifact is written for downstream skills (build-create-pr) to consume. Set DRY_RUN=1 to exercise the skill without calling the GitHub API."
```

---

## Task 5: Delete obsolete reference + CHANGELOG entry

**Files:**
- Delete: `plugins/makato-plan/skills/to-issues/references/project-info-format.md`
- Modify: `plugins/makato-plan/CHANGELOG.md` (insert a `to-issues` 3.0.0 block under the existing skill grouping)

**Interfaces:**
- Consumes: Nothing.
- Produces: A clean references/ folder with no obsolete mechanism file, plus a changelog entry the release-please bot indexes.

- [ ] **Step 1: Failing check — file still exists, changelog has no 3.0.0 entry**

```bash
test -f plugins/makato-plan/skills/to-issues/references/project-info-format.md && echo "still present (need to delete)"
grep -c "^## \`to-issues\` skill" plugins/makato-plan/CHANGELOG.md && grep -c "^- \\*\\*3.0.0\\*\\*$" plugins/makato-plan/CHANGELOG.md
```

Expected: `still present (need to delete)` printed; second grep returns `0` for the 3.0.0 marker.

- [ ] **Step 2: Delete the obsolete reference**

```bash
git rm plugins/makato-plan/skills/to-issues/references/project-info-format.md
```

- [ ] **Step 3: Insert the changelog entry**

Locate the `plugins/makato-plan/CHANGELOG.md` heading for the `to-issues` skill. If a `## \`to-issues\` skill` section already exists, prepend the new version block; if not, create the section near the top of the file (after the file header).

Insert this block (place it as the latest version, i.e. above any pre-existing version blocks for the skill):

```markdown
## `to-issues` skill

- **3.0.0** (BREAKING)
  - Retarget `github.com` only — removed all `GH_HOST=github.concur.com`, `GH_ENTERPRISE_TOKEN`, and TLS-bypass references including the `compatibility:` frontmatter line
  - Project name now read from `.claude/config.json` (`"project"` key, fallback `"sagibeast"`); legacy `.claude/rules/project-information.md` is detected and a migration warning is emitted, but the file is no longer written
  - Added 4-dimension label taxonomy in new `references/label-taxonomy.md` — `type` inferred from story keywords (default `feat`), `tier` from `stories[].phase`, `tech` from extensible keyword map, `module` from ADR folder-name pattern match (no ADR content reads)
  - Added `references/issue-template.md` — versioned `{{PLACEHOLDER}}` body template; single edit point for issue body format
  - Added `references/created-issues.schema.json` — JSON Schema (draft-07) for the new `specs/<slug>/created-issues.json` artifact consumed by `makato-build/build-create-pr`
  - Added `DRY_RUN=1` mode — prints assembled `gh` commands and writes a schema-valid artifact with synthetic issue numbers without touching the GitHub API
  - Removed `references/project-info-format.md` (obsolete mechanism)
  - Defined partial-failure semantics: halt batch on first `gh issue create` failure, persist partial artifact, exit non-zero (no rollback)
  - Migration: copy your project name into `.claude/config.json` (`{ "project": "<name>" }`); delete `.claude/rules/project-information.md` if present
```

- [ ] **Step 4: Verify**

```bash
test -f plugins/makato-plan/skills/to-issues/references/project-info-format.md && echo "FAIL — file still there" || echo "PASS — deleted"
grep -c "3.0.0" plugins/makato-plan/CHANGELOG.md
grep -c "BREAKING" plugins/makato-plan/CHANGELOG.md
```

Expected: `PASS — deleted`; both `grep -c` outputs ≥1.

- [ ] **Step 5: Commit**

```bash
git add plugins/makato-plan/skills/to-issues/references/project-info-format.md plugins/makato-plan/CHANGELOG.md
git commit -m "chore(makato-plan): remove obsolete project-info-format reference; add to-issues 3.0.0 changelog"
```

---

## Task 6: Story 1 end-to-end DRY_RUN verification

**Files:**
- Create (temporary, NOT committed): `/tmp/to-issues-fixtures/stories.json`, `/tmp/to-issues-fixtures/config.json`

**Interfaces:**
- Consumes: Tasks 1–5 (all of Story 1).
- Produces: Empirical proof that a fresh-repo invocation in DRY_RUN mode produces a schema-valid `created-issues.json` with all 4 label dimensions populated and zero network calls. No new committed files.

- [ ] **Step 1: Build the fixture stories.json (use the real one)**

The real `specs/to-issues-skill-redesign/stories.json` is a perfect fixture — 2 stories, foundation + happy-path, dep between them. Reuse it.

```bash
SLUG=to-issues-skill-redesign
test -f "specs/$SLUG/stories.json" && echo "fixture stories.json PASS" || echo "MISSING"
```

Expected: `fixture stories.json PASS`.

- [ ] **Step 2: Verify config.json exists with project key**

```bash
python3 -c "
import json
d = json.load(open('.claude/config.json'))
assert 'project' in d, 'missing project key'
print('PASS — project:', d['project'])
"
```

Expected: `PASS — project: sagibeast`.

- [ ] **Step 3: Confirm SKILL.md spells out the DRY_RUN contract**

```bash
grep -q "DRY_RUN" plugins/makato-plan/skills/to-issues/SKILL.md && echo "PASS"
```

Expected: `PASS`.

- [ ] **Step 4: Simulate the artifact a DRY_RUN invocation would produce**

A real `/to-issues` invocation lives in the agent harness, not in plain bash. To verify the skill's DRY_RUN contract independently, hand-craft the expected artifact and validate it against the schema. This proves the schema accepts the shape the skill commits to producing:

```bash
mkdir -p /tmp/to-issues-fixtures
cat > /tmp/to-issues-fixtures/expected-dry-run-artifact.json <<'EOF'
{
  "schema_version": "1",
  "slug": "to-issues-skill-redesign",
  "issues": [
    {
      "issue_number": 1,
      "url": "https://github.com/zstary/makato/issues/1",
      "title": "[sagibeast] [to-issues] Generic skill rewrite with 4D label taxonomy, ADR folder mapping, and created-issues.json artifact",
      "labels": ["type:feat", "tier:foundation", "tech:python", "tech:bash", "tech:gh-cli", "tech:skill", "module:to-issues"],
      "blocked_by": []
    },
    {
      "issue_number": 2,
      "url": "https://github.com/zstary/makato/issues/2",
      "title": "[sagibeast] [build-create-pr] Auto-inject Closes #N from created-issues.json into PR body",
      "labels": ["type:feat", "tier:happy-path", "tech:bash", "tech:gh-cli", "tech:skill", "module:build-create-pr"],
      "blocked_by": [1]
    }
  ]
}
EOF

python3 -c "
import json, jsonschema
schema = json.load(open('plugins/makato-plan/skills/to-issues/references/created-issues.schema.json'))
artifact = json.load(open('/tmp/to-issues-fixtures/expected-dry-run-artifact.json'))
jsonschema.validate(artifact, schema)
# Also check every label has the dimension:value shape
for issue in artifact['issues']:
    for label in issue['labels']:
        assert ':' in label, f'flat label {label!r}'
    dims = {l.split(':',1)[0] for l in issue['labels']}
    assert {'type','tier','tech','module'} <= dims, f'issue {issue[\"issue_number\"]} missing dimensions: only {dims}'
print('PASS — artifact shape and 4D coverage verified')
"
```

Expected: `PASS — artifact shape and 4D coverage verified`.

- [ ] **Step 5: Confirm DoD #1 — no SKILL.md edit required to work in a fresh repo**

```bash
# Simulate "fresh repo": only .claude/config.json + stories.json need to exist.
# Verify SKILL.md never references repo-specific paths that would require editing.
grep -E "(impact|concur|sagibeast)" plugins/makato-plan/skills/to-issues/SKILL.md | grep -v "fallback to 'sagibeast'" | grep -v "default.*sagibeast" || echo "PASS — no hardcoded repo-specific refs left to edit"
```

Expected: `PASS — no hardcoded repo-specific refs left to edit`.

- [ ] **Step 6: No commit — this task is verification only**

This task creates no committed files. The temp fixture in `/tmp/to-issues-fixtures/` is discarded. If any step fails, the failure feeds back into Task 1–5: typically a schema fix (Task 1) or a SKILL.md adjustment (Task 4).

---

## Task 7: Update `build-create-pr` to inject `Closes #N`

**Files:**
- Modify: `plugins/makato-build/skills/build-create-pr/SKILL.md`
- Modify: `plugins/makato-build/skills/build-create-pr/references/pr-description-guide.md`
- Modify: `plugins/makato-build/CHANGELOG.md`

**Interfaces:**
- Consumes: `specs/<key>-*/created-issues.json` produced by Story 1 (Tasks 1–5); validates against `plugins/makato-plan/skills/to-issues/references/created-issues.schema.json` (Task 1).
- Produces: A `build-create-pr` v1.3.0 that, when run on a branch whose spec folder contains a valid `created-issues.json`, injects `Closes #N` for each artifact entry into the PR body Links section; deduped against any user-supplied `GH#N`; falls back to current v1.2.0 behavior when the artifact is absent, malformed, or schema-invalid.

- [ ] **Step 1: Failing checks**

```bash
grep -c "created-issues.json" plugins/makato-build/skills/build-create-pr/SKILL.md
grep -c "1.3.0" plugins/makato-build/CHANGELOG.md
```

Expected: both outputs are `0`.

- [ ] **Step 2: Modify SKILL.md — bump version, add artifact step, add Step 6 Case 4**

In `plugins/makato-build/skills/build-create-pr/SKILL.md`:

**2a.** Replace the frontmatter `version` line:

Find:
```
version: "1.2.0"
```
Replace with:
```
version: "1.3.0"
```

**2b.** Inside Step 1, after the existing `Read from the resolved spec folder (...)` block (lines 27–32), append the artifact-detection paragraph. Locate the `git log main..HEAD --oneline` line and INSERT the following block immediately above it:

```markdown
- `created-issues.json` — handoff artifact emitted by `/makato-plan:to-issues` (optional)

When `created-issues.json` exists in the spec folder, validate it against the schema at `plugins/makato-plan/skills/to-issues/references/created-issues.schema.json`:

```bash
python3 - <<'PY'
import json, sys
try:
    import jsonschema
except ImportError:
    import subprocess; subprocess.check_call([sys.executable, '-m', 'pip', 'install', '--quiet', 'jsonschema'])
    import jsonschema
SCHEMA = json.load(open('plugins/makato-plan/skills/to-issues/references/created-issues.schema.json'))
ART = json.load(open('$SPEC_FOLDER/created-issues.json'))
jsonschema.validate(ART, SCHEMA)
print('[build-create-pr] artifact valid: %d issues' % len(ART['issues']))
PY
```

If validation fails (invalid JSON or schema mismatch), log a single warning:
`[build-create-pr] WARNING: specs/<slug>/created-issues.json is malformed (<error>) — continuing without Closes injection`
…and proceed with the current v1.2.0 behavior. Never block PR creation on artifact problems (D21).
```

**2c.** Update Step 3's PR-title and Links section. Locate Step 3's PR title rule:
```
Append ` (DCP-1234)` or ` (#42)` when a work item key is available.
```
Leave the title rule unchanged.

Inside Step 3, find the line `**Links**: see Step 6 for issue tracker handling.` and replace it with:
```
**Links**: see Step 6 for issue tracker handling. When `created-issues.json` is present and valid, the Links section receives an auto-injected `Closes #N` line per artifact entry (in artifact order), deduped against any user-supplied `GH#N` reference — see Step 6 Case 4.
```

**2d.** Add Step 6 Case 4. Locate `**Case 3 — No issue reference provided:**` and INSERT the following block immediately above the Step 7 heading:

```markdown
**Case 4 — `created-issues.json` present and schema-valid:**

For each entry in `issues[]`, add `Closes #<issue_number>` to the PR body's Links section in artifact order, before calling `gh pr create` in Step 5.

**Dedupe rule (D20):** if Case 2 already added a `Closes #N` for the same issue number (because the user passed `GH#N`), do not duplicate — the artifact entry wins by being canonical; the user-supplied reference is dropped from the Links section to avoid two lines pointing at the same issue.

**No artifact, malformed artifact, or schema-invalid artifact (D21):** skip injection entirely. Log a warning (as in Step 1) and create the PR with the current Step 6 Case 1–3 behavior. Never block PR creation on artifact problems.
```

**2e.** Update the Step 7 log line to include the new fields. Locate:
```
shared/build-log.sh "<key>" '{"ts":"<ISO8601>","skill":"build-create-pr","story":"<key>","step":"session","status":"ok","data":{"pr_url":"<url>","issue_linked":true|false,"issue_type":"jira"|"github"|"none"}}'
```
Replace with:
```
shared/build-log.sh "<key>" '{"ts":"<ISO8601>","skill":"build-create-pr","story":"<key>","step":"session","status":"ok","data":{"pr_url":"<url>","issue_linked":true|false,"issue_type":"jira"|"github"|"none","closes_injected":<N>,"artifact_status":"valid"|"missing"|"malformed"}}'
```

- [ ] **Step 3: Modify pr-description-guide.md — add row to Links table**

In `plugins/makato-build/skills/build-create-pr/references/pr-description-guide.md`, locate the Links Section table. The current table (lines 70–74) has rows for "GitHub issue provided" and "No reference". REPLACE the table with:

```markdown
| Situation                                                  | What to write                                                                                                                |
| ---------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------- |
| GitHub issue reference provided (`GH#42`)                  | `Closes #42` or `Fixes #42` (embed in PR body before creating)                                                               |
| `specs/<slug>/created-issues.json` present and schema-valid | One `Closes #N` per artifact entry in artifact order; dedupe against any user-supplied `GH#N` (artifact wins ties)            |
| Artifact malformed or schema-invalid                       | Skip injection; log `[build-create-pr] WARNING: ... — continuing without Closes injection`; never block PR creation          |
| No reference                                               | `N/A`                                                                                                                        |
```

Reference the schema location for discoverability — at the BOTTOM of the file (after the existing content), append:

```markdown

## Cross-Plugin Contract — `created-issues.json`

The handoff artifact this skill reads is produced by `/makato-plan:to-issues` (v3.0.0+). Its shape is defined by `plugins/makato-plan/skills/to-issues/references/created-issues.schema.json` — when changing this skill's parsing logic, validate against that schema rather than duck-typing the file.
```

- [ ] **Step 4: Modify makato-build CHANGELOG.md — add `build-create-pr` 1.3.0 entry**

In `plugins/makato-build/CHANGELOG.md`, find the `## \`build-create-pr\` skill` section (or the position equivalent to the other skill groupings) and prepend:

```markdown
## `build-create-pr` skill

- **1.3.0**
  - Auto-inject `Closes #N` into the PR body's Links section when `specs/<slug>/created-issues.json` is present and validates against the schema shipped by `to-issues` v3.0.0+ (path: `plugins/makato-plan/skills/to-issues/references/created-issues.schema.json`)
  - Dedupe against user-supplied `GH#N` references — artifact wins ties (D20)
  - Malformed or schema-invalid artifacts log a single warning and fall back to v1.2.0 behavior; PR creation is never blocked (D21)
  - Step 7 log entry adds `closes_injected` (count) and `artifact_status` (`valid` / `missing` / `malformed`) fields under `data`
  - Updated `references/pr-description-guide.md` Links Section table with the new artifact-driven row
```

If a `## \`build-create-pr\` skill` section already exists, prepend the `**1.3.0**` block above any pre-existing version blocks instead of duplicating the heading.

- [ ] **Step 5: Verify all three edits**

```bash
grep -c "created-issues.json" plugins/makato-build/skills/build-create-pr/SKILL.md
grep -E '^version: "1.3.0"$' plugins/makato-build/skills/build-create-pr/SKILL.md && echo "version PASS"
grep -c "Case 4" plugins/makato-build/skills/build-create-pr/SKILL.md
grep -c "closes_injected" plugins/makato-build/skills/build-create-pr/SKILL.md
grep -c "Cross-Plugin Contract" plugins/makato-build/skills/build-create-pr/references/pr-description-guide.md
grep -c "^- \\*\\*1.3.0\\*\\*$" plugins/makato-build/CHANGELOG.md
```

Expected: every `grep -c` returns `≥1`; the `version PASS` line prints.

- [ ] **Step 6: Commit**

```bash
git add plugins/makato-build/skills/build-create-pr/SKILL.md plugins/makato-build/skills/build-create-pr/references/pr-description-guide.md plugins/makato-build/CHANGELOG.md
git commit -m "feat(makato-build): inject Closes #N from created-issues.json into PR body (v1.3.0)"
```

---

## Task 8: Story 2 end-to-end verification

**Files:**
- Create (temporary, NOT committed): `/tmp/to-issues-fixtures/pr-body-expected.md`

**Interfaces:**
- Consumes: Tasks 1–7.
- Produces: Empirical proof that the cross-plugin loop closes — Story 1's artifact shape is exactly what Story 2 consumes, and the dedupe + malformed-fallback rules are documented.

- [ ] **Step 1: Verify the schema reference in build-create-pr resolves**

```bash
test -f plugins/makato-plan/skills/to-issues/references/created-issues.schema.json && echo "schema PASS"
grep -q "plugins/makato-plan/skills/to-issues/references/created-issues.schema.json" plugins/makato-build/skills/build-create-pr/SKILL.md && echo "ref PASS"
grep -q "plugins/makato-plan/skills/to-issues/references/created-issues.schema.json" plugins/makato-build/skills/build-create-pr/references/pr-description-guide.md && echo "guide-ref PASS"
```

Expected: three `PASS` lines.

- [ ] **Step 2: Validate Story 1's expected artifact still passes Story 2's parser shape assumptions**

The artifact has `slug`, `schema_version`, and an `issues[]` array. build-create-pr iterates `issues[]` and reads `issue_number`. Confirm by parsing the dry-run fixture from Task 6:

```bash
python3 -c "
import json
art = json.load(open('/tmp/to-issues-fixtures/expected-dry-run-artifact.json'))
assert 'issues' in art and isinstance(art['issues'], list)
for i in art['issues']:
    assert 'issue_number' in i and isinstance(i['issue_number'], int)
print('PASS — build-create-pr can iterate', len(art['issues']), 'entries')
"
```

Expected: `PASS — build-create-pr can iterate 2 entries`.

- [ ] **Step 3: Simulate the Links section build-create-pr would emit**

```bash
python3 - <<'PY' > /tmp/to-issues-fixtures/pr-body-expected.md
import json
art = json.load(open('/tmp/to-issues-fixtures/expected-dry-run-artifact.json'))
lines = ['## Links', '']
for issue in art['issues']:
    lines.append(f"- Closes #{issue['issue_number']}")
print('\n'.join(lines))
PY
cat /tmp/to-issues-fixtures/pr-body-expected.md
```

Expected output:
```
## Links

- Closes #1
- Closes #2
```

- [ ] **Step 4: Simulate the dedupe rule with a user-supplied GH#1**

```bash
python3 - <<'PY'
import json
art = json.load(open('/tmp/to-issues-fixtures/expected-dry-run-artifact.json'))
user_supplied = {1}  # user passed GH#1
artifact_numbers = [i['issue_number'] for i in art['issues']]
final = []
seen = set()
# Artifact wins — emit those first; user-supplied numbers not in artifact get appended
for n in artifact_numbers + sorted(user_supplied):
    if n in seen: continue
    seen.add(n); final.append(f"Closes #{n}")
print('\\n'.join(final))
assert final == ['Closes #1', 'Closes #2'], f'dedupe failed: {final}'
print('PASS — dedupe rule honored (artifact wins ties; user-supplied #1 dropped)')
PY
```

Expected last line: `PASS — dedupe rule honored (artifact wins ties; user-supplied #1 dropped)`.

- [ ] **Step 5: Simulate the malformed-artifact fallback**

```bash
python3 - <<'PY'
import json, jsonschema
schema = json.load(open('plugins/makato-plan/skills/to-issues/references/created-issues.schema.json'))
bad = {"schema_version": "1", "slug": "x"}  # missing 'issues'
try:
    jsonschema.validate(bad, schema)
    print('FAIL — schema let it through'); exit(1)
except jsonschema.ValidationError as e:
    # build-create-pr would print this exact shape of warning and continue
    print(f"[build-create-pr] WARNING: specs/x/created-issues.json is malformed ({e.message}) — continuing without Closes injection")
    print('PASS — fallback path exercised')
PY
```

Expected last two lines:
```
[build-create-pr] WARNING: specs/x/created-issues.json is malformed ('issues' is a required property) — continuing without Closes injection
PASS — fallback path exercised
```

- [ ] **Step 6: No commit — this task is verification only**

Failures here feed back into Task 7: typically a missing schema reference in `build-create-pr` (fix the grep target) or a mis-stated dedupe rule (fix the case-4 paragraph).

---

## Self-Review (run after Task 8)

After all tasks complete, walk this checklist:

1. **Spec coverage** — for each Story 1 DoD item:
   - "Running the skill on a fresh repo ... a single invocation, without editing SKILL.md" → Task 4 + Task 6 step 5.
   - "grep -r 'concur' returns zero matches" → Task 4 step 4.
   - "Three new references exist and are referenced from SKILL.md" → Tasks 1/2/3 + Task 4 step 3.
   - "DRY_RUN=1 invocation prints commands and produces schema-valid artifact" → Task 4 (DRY_RUN section in SKILL.md) + Task 6 step 4.
   - "Legacy .claude/rules/project-information.md emits warning" → Task 4 (Step 0 migration block).
   - "makato-plan CHANGELOG 3.0.0 entry with BREAKING marker" → Task 5 step 3.
   - For each Story 2 DoD item:
     - "PR body Links contains Closes #N when artifact valid" → Task 7 Step 6 Case 4 + Task 8 step 3.
     - "No regression when absent / malformed" → Task 7 Step 1 fallback paragraph + Task 8 step 5.
     - "makato-build CHANGELOG entry" → Task 7 step 4.
     - "Cross-plugin schema reference in build-create-pr" → Task 7 step 3.

2. **Placeholder scan** — search for "TBD", "TODO", "fill in", "Similar to", "etc." across this plan. Confirm none remain.

3. **Type consistency**:
   - `created-issues.json` shape: `{ schema_version, slug, issues: [{ issue_number, url, title, labels, blocked_by }] }` — used consistently in Task 1 schema, Task 4 Step 6 writer, Task 7 Step 2 reader, Task 8 fixtures. ✓
   - Label dimension prefixes: `type:`, `tier:`, `tech:`, `module:` — Task 2 taxonomy, Task 4 Step 3 inference. ✓
   - SKILL.md frontmatter version: `metadata.version: "3.0.0"` (nested under `metadata:`) — matches existing 2.4.0 frontmatter shape. ✓
   - build-create-pr version: top-level `version: "1.3.0"` — matches existing frontmatter shape (it currently has `version: "1.2.0"` at top level). ✓
   - Env var: `DRY_RUN=1` only (not `DRYRUN`, not `--dry-run` for the env path). The CLI arg `--dry-run` parses to `DRY_RUN=1`. ✓

Fix any gaps inline.

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-06-23-to-issues-skill-redesign.md`. Two execution options:

**1. Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, review between tasks, fast iteration.

**2. Inline Execution** — Execute tasks in this session using executing-plans, batch execution with checkpoints.

Which approach?
