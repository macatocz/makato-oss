---
name: create-workflow-schema
description: >-
  Interactive wizard for .claude/workflow-schema.yml — customise the makato-build artifact pipeline
  and preserve independent per-skill OMP role/effort settings. Use when adding, removing, or
  reordering build steps, inserting custom artifacts, or generating the local workflow schema.
  Triggers: workflow-schema, pipeline steps, build pipeline, customize build, add build step, remove
  build step, reorder pipeline, skill execution settings, skill role, skill effort.
version: "1.3.0"
argument-hint: ""
allowed-tools: [Bash]
metadata:
  Authors: [makato-core]
  last_updated: "2026-10-15"
---

# create-workflow-schema

## When to Use

- You want to customise the makato-build pipeline by adding, removing, or reordering skill
  artifacts.
- You want to insert a custom artifact (e.g. `security-audit`, `deploy-preview`) at a specific
  position in the pipeline.
- You want to understand or preserve per-skill OMP role/effort settings in
  `.claude/workflow-schema.yml`.
- The repository does not yet have a local workflow schema and you want the default artifact
  pipeline documented and editable.

## Do NOT Use (Do NOT Load)

- `.claude/workflow-schema.yml` already exists and you only want to edit it manually — open the file
  directly and refer to `docs/workflow-schema.md`.
- You only want to run the build pipeline without customising it — `build-start` uses the built-in
  default automatically when no schema file is present.
- You are outside a git repository — Step 1 will abort; resolve that first.

## Do NOT Load References During Normal Execution

Load `references/workflow-schema-field-reference.md` ONLY when:

- The user asks about a specific YAML field (`after:`, `required:`, `description:`,
  `skill_execution`, `role`, or `effort`)
- The user asks about multi-dependency or diamond-DAG edge cases
- The user hits a loader parse or execution-config error and needs to diagnose it
- Any question not answered by the main skill body

Do NOT load it during normal wizard execution (Steps 1–9).

## Output

Creates `.claude/workflow-schema.yml` in the repository root.

The generated file can be edited manually at any time. The schema format is documented in
`docs/workflow-schema.md`.

## Mindset

**Pipeline architecture, not configuration.** Every field in the schema is a dependency-graph node,
not just an ordered list. The `after:` edges define the DAG — `workflow-schema-loader.sh`
topologically sorts them before dispatch; the YAML order in the file is irrelevant. Design around
semantics, not position.

**`required: true/false` answers one question:** "Will the pipeline be in a meaningful unchecked
state if this artifact is skipped?" Artifacts that gate correctness (`verify`, `sensors`,
`push-to-git`) are always `required: true`. Artifacts that add quality but whose absence is safe
(`grill-with-docs`, `address-pr-comments`) default to `required: false` — flip them to
`required: true` only when team policy mandates them for every build.

**Custom artifact placement:** Insert after the artifact whose output you consume, before the
artifact that depends on your output. A `security-audit` that reads source code goes after
`implement-tdd`/`implement-goal` and before `sensors` — not after `create-pr` where the code is
already pushed.

**YAML parsing boundaries:** `workflow-schema-loader.sh` uses its restricted hand-written parser
only for the `artifacts` list (`id`, `skill`, `required`, `description`, and `after`). It stops at
each top-level section boundary. `skill_execution` is parsed separately by the shared resolver using
PyYAML; Python 3 and the PyYAML package are runtime dependencies. Quote plugin-qualified setting
keys.

## Anti-patterns

**NEVER compute `SCHEMA_PATH` with `pwd` or a relative path.** `pwd` shifts when this skill is
invoked inside a sub-agent with a different cwd. `git rev-parse --show-toplevel` gives the canonical
root that `workflow-schema-loader.sh` expects as its first positional argument. A path mismatch
causes the loader to silently fall back to the built-in default, discarding your customisations
without an error.

**NEVER skip the loader validation in Step 8.** `workflow-schema-loader.sh` is the only gate that
catches dependency cycles. `build-start` trusts the loader's topologically sorted output without
re-validating; an undetected cycle enters the pipeline dispatcher as a perpetual retry loop with no
actionable error surface. There is no second chance to catch this before a build session starts.

**NEVER add an `after:` reference to an artifact ID that does not exist in the schema.** The
loader's cycle-detection DFS only traverses known nodes — unknown `after:` IDs are silently skipped
with `continue` (see `detect_cycle` in the loader). A typo in an `after:` value produces an
invisible missing-dependency: the dependent artifact dispatches immediately instead of waiting,
producing a silent ordering violation in parallel pipeline configurations.

**NEVER include duplicate artifact `id` values.** The loader's topological sort visits each ID once.
A duplicate entry shadows the first: only one definition reaches the sorted output, silently
dropping the other's `skill` and `required` settings from the assembled pipeline.

**NEVER write `after: []` for an artifact with no dependencies.** Omit the `after:` key entirely.
The hand-written parser does not reliably recognise the empty-list form and may emit a parse warning
or treat the artifact as having a dependency on an empty string.

## Workflow

### Step 1 — Resolve repository root

```bash
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
```

If this fails: abort with "Cannot create workflow schema — not inside a git repository."

### Step 2 — Check for existing schema

Check whether `.claude/workflow-schema.yml` already exists:

```bash
SCHEMA_PATH="$REPO_ROOT/.claude/workflow-schema.yml"
```

If it exists, read and retain its complete top-level `skill_execution` block verbatim before
offering regeneration. Preserve all local defaults and skill keys, including custom or currently
unregistered skill keys; do not replace it with the built-in map. If the existing file contains only
`skill_execution` and no `artifacts`, use the built-in artifact list in Step 3 while retaining that
block.

Ask via `AskUserQuestion`:

> **"A workflow schema already exists at `.claude/workflow-schema.yml`. What would you like to
> do?"**
>
> 1. Edit it manually — open the file in your editor (this wizard exits)
> 2. Regenerate it — run this wizard and overwrite the existing file

If (1): print the path and exit without changing the file. If (2): use the retained
`skill_execution` block when writing the regenerated schema in Step 7.

### Step 3 — Present artifacts and the skill execution catalog

Read `plugins/makato-build/config/default-workflow-schema.yml`. If the file does not exist, abort:
"Default schema not found — ensure the makato-build plugin is installed at `plugins/makato-build/`."

Present two **separate** tables, in this order:

1. Display the `artifacts` list as the build-pipeline table (columns: ID, SKILL, REQUIRED, AFTER).
   These entries alone define pipeline membership and order.
2. Separately read `skill_execution.skills` and display every one of the built-in entries,
   grouped by plugin (`makato-plan`, `makato-change`, `makato-build`), as a skill execution table
   (columns: PLUGIN, SKILL, ROLE, EFFORT). Also show `skill_execution.defaults` as the fallback. Do
   not filter this catalog to skills used by the artifact list, and do not present its entries as
   pipeline artifacts.

Explain that these skills are independently launchable workflow skills from the three plugins; the
`skill_execution` settings control their per-run model role and effort, while `artifacts` controls
only build-pipeline inclusion and dependencies. Custom artifact skills remain supported even when
they do not appear in the built-in skill catalog. Role names map through the user's OMP `modelRoles`
configuration; `REVIEW` is custom and must be configured by the user. The catalog is informational
in this wizard; do not write to or modify OMP configuration.

If an existing project schema is being regenerated, its complete local `skill_execution` block must
remain separate from the built-in catalog and be preserved verbatim (Step 2). If no local block
exists, built-in execution values remain active implicitly; do not copy all defaults into the
project schema.

Then ask via `AskUserQuestion` about the **artifact table**:

> **"The artifact table above is the built-in default pipeline. How do you want to proceed?"**
>
> 1. Keep the default artifact list (built-in skill execution settings stay active)
> 2. Remove optional artifacts (exclude required:false steps from the schema)
> 3. Mark optional artifacts as required for this repo
> 4. Add custom artifacts at specific positions
> 5. Combine: mark some as required AND add custom artifacts

Record the user's selection. Choices 1 or 2-5 set which interview steps follow:

- Choice 1: skip Steps 4 and 5, go directly to Step 6.
- Choice 2: ask which optional artifacts to exclude; skip Step 5 unless combined.
- Choice 3: proceed to Step 4.
- Choice 4: skip Step 4, proceed to Step 5.
- Choice 5: proceed to Steps 4 and 5.

### Step 4 — Interview: required-flag overrides

From the artifact list read in Step 3, filter for entries where `required: false`. Present that
filtered set to the user, then ask via `AskUserQuestion`:

> **"Which optional artifacts do you want to make required for this repo?"**
>
> _(Present each optional artifact as a numbered option, plus a final option: "None — keep all as
> optional")_

Collect the list of IDs the user selects. Each must be a valid artifact ID from Step 3.

### Step 5 — Interview: custom artifacts

Ask via `AskUserQuestion`:

> **"Do you want to add custom artifacts to the pipeline?"**
>
> 1. Yes — add one or more custom artifacts
> 2. No — proceed with the current artifact list

If (2): proceed to Step 6.

If (1): loop collecting custom artifacts until the user is done. For each, ask:

1. Ask via `AskUserQuestion`: _"Custom artifact ID (kebab-case, e.g. `security-audit`):"_ — free
   text; validate kebab-case and uniqueness against current list.
2. Ask via `AskUserQuestion`: _"Skill name (e.g. `build-sensors`, or plugin-qualified
   `my-plugin:my-skill`):"_ — free text.
3. Ask via `AskUserQuestion`: **"Is this artifact required?"** with options:
   `1. Yes (required: true)` / `2. No (required: false)`.
4. Ask via `AskUserQuestion`: _"Short description (optional — press Enter to skip):"_ — free text,
   may be empty.
5. Ask via `AskUserQuestion`: **"Insert this artifact AFTER which existing artifact?"** — present
   current artifact IDs as numbered options.

Validate:

- ID must be kebab-case and not already in the artifact list.
- The `after` artifact ID must exist in the current list.
- Accept custom skill names even when absent from the built-in execution entries; use a
  plugin-qualified name to distinguish duplicate skill names.

After each custom artifact, ask via `AskUserQuestion`:

> **"Add another custom artifact?"**
>
> 1. Yes
> 2. No — proceed to confirmation

### Step 6 — Confirm and generate

Show the user the final artifact order as a table (same format as Step 3). Separately show the
preserved project `skill_execution` block that will be written verbatim. If no local block exists,
state that the built-in execution settings remain active and the project file will omit
`skill_execution`. Never fold execution entries into the artifact table or claim that they add
pipeline steps. Ask via `AskUserQuestion`:

> **"Generate `.claude/workflow-schema.yml` with these settings?"**
>
> 1. Yes — write the file
> 2. No — cancel (run the wizard again to restart)

If (2): abort. If (1): proceed to Step 7.

### Step 7 — Write .claude/workflow-schema.yml

Ensure the directory exists before writing:

```bash
mkdir -p "$REPO_ROOT/.claude"
```

Construct the YAML file from the confirmed artifact list. Follow this template exactly — one entry
per artifact in dependency-topological order:

```yaml
# Workflow schema for <repo-name>.
# Generated by /makato-core:create-workflow-schema.
# Edit manually or re-run the wizard to update.
# See docs/workflow-schema.md for format documentation.

version: "1.0"

artifacts:
  - id: <id>
    skill: <skill>
    required: <true|false>
    description: "<description>"
    after: [<dep1>, <dep2>] # omit if no dependencies
```

Rules for the generated file:

- Omit the `after:` line entirely for artifacts with no dependencies.
- Use `after: [<id>]` for a single dependency, `after: [<id1>, <id2>]` for multiple.
- Use `true`/`false` (not `yes`/`no`) for the `required:` field.
- Use inline-quoted strings for `description:`; do not use block scalars (`>`, `|`).
- Preserve original `description` values from the default schema for unmodified artifacts; use the
  user-supplied description for custom artifacts.
- If the existing project schema contains a `skill_execution` block, copy the entire project block
  verbatim to the generated file, including defaults and custom skill keys. It may appear before or
  after `artifacts`.
- If there was no local `skill_execution` block, omit it. Do not copy the built-in map into the
  project file; the built-in execution settings remain active implicitly.
- An execution-only local schema has no `artifacts` block and receives the built-in artifact list;
  on regeneration, start from that same built-in artifact table.

Write to `$REPO_ROOT/.claude/workflow-schema.yml`.

### Step 8 — Validate and confirm

Run `workflow-schema-loader.sh` to confirm the generated file is valid:

```bash
PLUGIN_ROOT="$(git rev-parse --show-toplevel)/plugins/makato-build"
output="$(bash "$PLUGIN_ROOT/scripts/workflow-schema-loader.sh" "$REPO_ROOT" 2>&1)"
exit_code=$?
```

If `exit_code` is 0: tell the user:

> "Schema written to `.claude/workflow-schema.yml` and validated. `workflow-schema-loader.sh`
> resolved <N> artifacts with role/effort fields.
>
> `build-start` will use the schema's artifact DAG. Launch an individual skill through
> `plugins/makato-build/scripts/run-skill.py` to apply its execution settings."

If `exit_code` is 1: tell the user:

> "Schema was written but validation failed: `<loader output>`
>
> Please edit `.claude/workflow-schema.yml` to fix the error before running `build-start`.
>
> Load `references/workflow-schema-field-reference.md` now to diagnose the error. Common causes:
> duplicate artifact `id`, `after:` referencing a missing ID, a DAG cycle, invalid
> `skill_execution.role/effort`, duplicate/malformed YAML, or missing PyYAML (a runtime dependency).

### Step 9 — Offer next step

Ask via `AskUserQuestion`:

> **"Would you like to open `.claude/workflow-schema.yml` for review now?"**
>
> 1. Yes — show me the file path
> 2. No — I'm done

If (1): print the full file path so the user can open it. This wizard does not open editors
directly.

Tell the user: "Run `/build-start` to begin a build session using the new schema."
