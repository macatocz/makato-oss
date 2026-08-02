---
name: create-workflow-schema
description: >-
  Interactive wizard that generates .claude/workflow-schema.yml — a customised
  makato-build pipeline definition listing the skill artifacts and their
  dependency order for the current repository. Use when you want to add, remove,
  or reorder build pipeline steps, or insert a custom artifact into the default
  sequence.
version: "1.0.0"
argument-hint: ""
---

# create-workflow-schema

## When to Use

- You want to customise the makato-build pipeline for this repository by adding,
  removing, or reordering skill artifacts.
- You want to insert a custom artifact (e.g. `security-audit`, `deploy-preview`)
  at a specific position in the pipeline.
- The repository does not yet have `.claude/workflow-schema.yml` and you want the
  default pipeline documented and editable locally.

## When NOT to Use

- `.claude/workflow-schema.yml` already exists and you only want to edit it
  manually — open the file directly and refer to `docs/workflow-schema.md`.
- You only want to run the build pipeline without customising it — `build-start`
  uses the built-in default automatically when no schema file is present.

## Output

Creates `.claude/workflow-schema.yml` in the repository root.

The generated file can be edited manually at any time. The schema format is
documented in `docs/workflow-schema.md`.

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

If it exists: tell the user:

> "A workflow schema already exists at `.claude/workflow-schema.yml`.
>
> **(A) Edit it** — open the file in your editor (this wizard exits)
> **(B) Regenerate it** — run this wizard and overwrite the existing file"

Wait for the user's choice. If (A): print the path and exit. If (B): continue.

### Step 3 — Present the built-in default artifacts

Show the user the pipeline artifacts in the built-in default schema so they have a
concrete starting point. Read `plugins/makato-build/config/default-workflow-schema.yml`
and display its artifact list in a readable table:

```
ID                    SKILL                    REQUIRED  AFTER
refine                build-refine             yes       —
grill-with-docs       build-grill-with-docs    no        refine
implement-tdd         build-implement-tdd      no        refine
implement-goal        build-implement-goal     no        refine
simplify              build-simplify           yes       implement-tdd, implement-goal
review                build-review             yes       simplify
verify                build-verify             yes       review
sensors               build-sensors            yes       verify
push-to-git           build-push-to-git        yes       sensors
create-pr             build-create-pr          yes       push-to-git
address-pr-comments   build-address-pr-comments no       create-pr
```

Tell the user:

> "The table above is the built-in default pipeline. You can:
>
> 1. Keep all defaults as-is (generates a schema identical to the built-in)
> 2. Remove optional artifacts (mark required: false steps as absent)
> 3. Mark optional artifacts as required for this repo
> 4. Add custom artifacts at specific positions"

### Step 4 — Interview: required-flag overrides

Ask:

> "Are there any optional artifacts you want to make **required** for this repo?
> (Enter comma-separated IDs, or press Enter to skip)
> Optional artifacts: grill-with-docs, implement-tdd, implement-goal, address-pr-comments"

Collect the list of IDs the user names. Validate each against the default artifact
ID list. Warn if an unknown ID is entered and ask the user to correct it.

### Step 5 — Interview: custom artifacts

Ask:

> "Do you want to add any **custom artifacts** to the pipeline? (y/n)"

If yes, loop collecting custom artifacts until the user is done:

For each custom artifact, ask:

1. *"Custom artifact ID (kebab-case, e.g. `security-audit`):"*
2. *"Skill name (e.g. `security-audit`, `my-plugin:my-skill`):"*
3. *"Required? (y/n)"*
4. *"Short description (optional, press Enter to skip):"*
5. *"Insert AFTER which existing artifact ID? (e.g. `verify`)"*

Validate:
- ID must be kebab-case and not already in the artifact list.
- The `after` artifact ID must exist in the current list.

After each custom artifact: ask "Add another custom artifact? (y/n)".

### Step 6 — Confirm and generate

Show the user a preview of the final artifact order as a table (same format as
Step 3). Ask:

> "Generate `.claude/workflow-schema.yml` with these settings? (y/n)"

If no: abort and tell the user to run the wizard again.

If yes: proceed to Step 7.

### Step 7 — Write .claude/workflow-schema.yml

Construct the YAML file from the confirmed artifact list. Follow this template
exactly — one entry per artifact in dependency-topological order:

```yaml
# Workflow schema for <repo-name>.
# Generated by /makato-core:create-workflow-schema.
# Edit manually or re-run the wizard to update.
# See docs/workflow-schema.md for format documentation.
# Issue: #563

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
> `build-start`. See `docs/workflow-schema.md` for format documentation."

### Step 9 — Offer next step

Ask:

> "Would you like to open `.claude/workflow-schema.yml` for review now? (y/n)"

If yes: print the full file path so the user can open it. This wizard does not
open editors directly.

Tell the user: "Run `/build-start` to begin a build session using the new schema."
