---
name: create-workflow-schema
description: >-
  Interactive wizard that generates .claude/workflow-schema.yml — a customised
  makato-build pipeline definition listing skill artifacts and their dependency
  order for the current repository. Use when adding, removing, or reordering
  build pipeline steps, or inserting a custom artifact into the default sequence.
  Triggers: workflow-schema, pipeline steps, build pipeline, customize build,
  add build step, remove build step, reorder pipeline.
version: "1.2.0"
argument-hint: ""
allowed-tools: [Bash]
metadata:
  Authors: [makato-core]
  last_updated: "2026-08-05"
---

# create-workflow-schema

## When to Use

- You want to customise the makato-build pipeline for this repository by adding,
  removing, or reordering skill artifacts.
- You want to insert a custom artifact (e.g. `security-audit`, `deploy-preview`)
  at a specific position in the pipeline.
- The repository does not yet have `.claude/workflow-schema.yml` and you want the
  default pipeline documented and editable locally.

## Do NOT Use (Do NOT Load)

- `.claude/workflow-schema.yml` already exists and you only want to edit it
  manually — open the file directly and refer to `docs/workflow-schema.md`.
- You only want to run the build pipeline without customising it — `build-start`
  uses the built-in default automatically when no schema file is present.
- You are outside a git repository — Step 1 will abort; resolve that first.

## Do NOT Load References During Normal Execution

Load `references/workflow-schema-field-reference.md` ONLY when:
- The user asks about a specific YAML field (`after:`, `required:`, `description:`)
- The user asks about multi-dependency or diamond-DAG edge cases
- The user hits a loader parse error and needs to diagnose it
- Any question not answered by the main skill body

Do NOT load it during normal wizard execution (Steps 1–9).

## Output

Creates `.claude/workflow-schema.yml` in the repository root.

The generated file can be edited manually at any time. The schema format is
documented in `docs/workflow-schema.md`.

## Mindset

**Pipeline architecture, not configuration.** Every field in the schema is a
dependency-graph node, not just an ordered list. The `after:` edges define the
DAG — `workflow-schema-loader.sh` topologically sorts them before dispatch; the
YAML order in the file is irrelevant. Design around semantics, not position.

**`required: true/false` answers one question:** "Will the pipeline be in a
meaningful unchecked state if this artifact is skipped?" Artifacts that gate
correctness (`verify`, `sensors`, `push-to-git`) are always `required: true`.
Artifacts that add quality but whose absence is safe (`grill-with-docs`,
`address-pr-comments`) default to `required: false` — flip them to `required: true`
only when team policy mandates them for every build.

**Custom artifact placement:** Insert after the artifact whose output you consume,
before the artifact that depends on your output. A `security-audit` that reads
source code goes after `implement-tdd`/`implement-goal` and before `sensors` —
not after `create-pr` where the code is already pushed.

**YAML subset constraint:** The hand-written parser in `workflow-schema-loader.sh`
handles only the restricted artifact schema (`id`, `skill`, `required`,
`description`, `after`). Descriptions must be inline-quoted strings (`"..."`);
multi-line block scalars (`>`, `|`) are silently truncated.

## Anti-patterns

**NEVER compute `SCHEMA_PATH` with `pwd` or a relative path.**
`pwd` shifts when this skill is invoked inside a sub-agent with a different cwd.
`git rev-parse --show-toplevel` gives the canonical root that
`workflow-schema-loader.sh` expects as its first positional argument. A path
mismatch causes the loader to silently fall back to the built-in default,
discarding your customisations without an error.

**NEVER skip the loader validation in Step 8.**
`workflow-schema-loader.sh` is the only gate that catches dependency cycles.
`build-start` trusts the loader's topologically sorted output without
re-validating; an undetected cycle enters the pipeline dispatcher as a
perpetual retry loop with no actionable error surface. There is no
second chance to catch this before a build session starts.

**NEVER add an `after:` reference to an artifact ID that does not exist in the
schema.**
The loader's cycle-detection DFS only traverses known nodes — unknown `after:`
IDs are silently skipped with `continue` (see `detect_cycle` in the loader).
A typo in an `after:` value produces an invisible missing-dependency: the
dependent artifact dispatches immediately instead of waiting, producing a
silent ordering violation in parallel pipeline configurations.

**NEVER include duplicate artifact `id` values.**
The loader's topological sort visits each ID once. A duplicate entry shadows the
first: only one definition reaches the sorted output, silently dropping the
other's `skill` and `required` settings from the assembled pipeline.

**NEVER write `after: []` for an artifact with no dependencies.**
Omit the `after:` key entirely. The hand-written parser does not reliably
recognise the empty-list form and may emit a parse warning or treat the artifact
as having a dependency on an empty string.

## Workflow

### Step 1 — Resolve repository root

```bash
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
```

If this fails: abort with "Cannot create workflow schema — not inside a git
repository."

### Step 2 — Check for existing schema

Check whether `.claude/workflow-schema.yml` already exists:

```bash
SCHEMA_PATH="$REPO_ROOT/.claude/workflow-schema.yml"
```

If it exists, ask via `AskUserQuestion`:

> **"A workflow schema already exists at `.claude/workflow-schema.yml`. What would you like to do?"**
>
> 1. Edit it manually — open the file in your editor (this wizard exits)
> 2. Regenerate it — run this wizard and overwrite the existing file

If (1): print the path and exit. If (2): continue.

### Step 3 — Present the built-in default artifacts

Read `plugins/makato-build/config/default-workflow-schema.yml`. If the file does
not exist, abort: "Default schema not found — ensure the makato-build plugin is
installed at `plugins/makato-build/`."

Display its artifact list as a readable table (columns: ID, SKILL, REQUIRED,
AFTER). Then ask via `AskUserQuestion`:

> **"The table above is the built-in default pipeline. How do you want to proceed?"**
>
> 1. Keep all defaults as-is (generates a schema identical to the built-in)
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

From the artifact list read in Step 3, filter for entries where `required: false`.
Present that filtered set to the user, then ask via `AskUserQuestion`:

> **"Which optional artifacts do you want to make required for this repo?"**
>
> *(Present each optional artifact as a numbered option, plus a final option: "None — keep all as optional")*

Collect the list of IDs the user selects. Each must be a valid artifact ID from
Step 3.

### Step 5 — Interview: custom artifacts

Ask via `AskUserQuestion`:

> **"Do you want to add custom artifacts to the pipeline?"**
>
> 1. Yes — add one or more custom artifacts
> 2. No — proceed with the current artifact list

If (2): proceed to Step 6.

If (1): loop collecting custom artifacts until the user is done. For each, ask:

1. Ask via `AskUserQuestion`: *"Custom artifact ID (kebab-case, e.g. `security-audit`):"* — free text; validate kebab-case and uniqueness against current list.
2. Ask via `AskUserQuestion`: *"Skill name (e.g. `build-sensors`, or plugin-qualified `my-plugin:my-skill`):"* — free text.
3. Ask via `AskUserQuestion`: **"Is this artifact required?"** with options: `1. Yes (required: true)` / `2. No (required: false)`.
4. Ask via `AskUserQuestion`: *"Short description (optional — press Enter to skip):"* — free text, may be empty.
5. Ask via `AskUserQuestion`: **"Insert this artifact AFTER which existing artifact?"** — present current artifact IDs as numbered options.

Validate:
- ID must be kebab-case and not already in the artifact list.
- The `after` artifact ID must exist in the current list.

After each custom artifact, ask via `AskUserQuestion`:

> **"Add another custom artifact?"**
>
> 1. Yes
> 2. No — proceed to confirmation

### Step 6 — Confirm and generate

Show the user a preview of the final artifact order as a table (same format as
Step 3). Ask via `AskUserQuestion`:

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

Construct the YAML file from the confirmed artifact list. Follow this template
exactly — one entry per artifact in dependency-topological order:

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
    after: [<dep1>, <dep2>]    # omit if no dependencies
```

Rules for the generated file:
- Omit the `after:` line entirely for artifacts with no dependencies.
- Use `after: [<id>]` for a single dependency, `after: [<id1>, <id2>]` for multiple.
- Use `true`/`false` (not `yes`/`no`) for the `required:` field.
- Use inline-quoted strings for `description:`; do not use block scalars (`>`, `|`).
- Preserve original `description` values from the default schema for unmodified
  artifacts; use the user-supplied description for custom artifacts.

Write to `$REPO_ROOT/.claude/workflow-schema.yml`.

### Step 8 — Validate and confirm

Run `workflow-schema-loader.sh` to confirm the generated file is valid:

```bash
PLUGIN_ROOT="$(git rev-parse --show-toplevel)/plugins/makato-build"
output="$(bash "$PLUGIN_ROOT/scripts/workflow-schema-loader.sh" "$REPO_ROOT" 2>&1)"
exit_code=$?
```

If `exit_code` is 0: tell the user:

> "Schema written to `.claude/workflow-schema.yml` and validated.
> `workflow-schema-loader.sh` resolved `<N>` artifacts successfully.
>
> `build-start` will now use this schema to assemble the pipeline."

If `exit_code` is 1: tell the user:

> "Schema was written but validation failed: `<loader output>`
>
> Please edit `.claude/workflow-schema.yml` to fix the error before running
> `build-start`."
>
> Load `references/workflow-schema-field-reference.md` now to diagnose the error.
> Common causes: duplicate `id`, `after:` referencing a missing ID, or a cycle
> in the DAG (A after B, B after A).

### Step 9 — Offer next step

Ask via `AskUserQuestion`:

> **"Would you like to open `.claude/workflow-schema.yml` for review now?"**
>
> 1. Yes — show me the file path
> 2. No — I'm done

If (1): print the full file path so the user can open it. This wizard does not
open editors directly.

Tell the user: "Run `/build-start` to begin a build session using the new schema."
