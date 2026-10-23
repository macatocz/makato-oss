# Workflow Schema Format

The makato-build workflow schema controls two separate concerns for build dispatch: the `artifacts`
DAG that `build-start` assembles for a story session, and optional per-skill execution role/effort
settings. When `.claude/workflow-schema.yml` is present, `workflow-schema-loader.sh` returns the
topologically ordered artifacts with resolved `role` and `effort` fields. When no local schema is
present, the built-in defaults in `plugins/makato-build/config/default-workflow-schema.yml` are
used. A local file containing only `skill_execution` overrides still uses the built-in artifact
list.

Issue: #563

---

## File location

```text
<repo-root>/.claude/workflow-schema.yml
```

The loader searches for this path. Absence is not an error — the built-in default is returned
silently.

---

## Top-level fields

| Field             | Type    | Required              | Description                                                                                                           |
| ----------------- | ------- | --------------------- | --------------------------------------------------------------------------------------------------------------------- |
| `version`         | string  | yes                   | Schema format version. Currently "1.0".                                                                               |
| `artifacts`       | list    | for a custom pipeline | Pipeline artifacts. Omit only for an execution-only override; the loader then retains the built-in default artifacts. |
| `skill_execution` | mapping | no                    | Per-skill OMP role and thinking-effort defaults/overrides. May appear before or after `artifacts`.                    |

---

## `skill_execution`: provider-neutral role and effort

This top-level mapping controls **skill dispatch only**. It does not set concrete model selectors;
OMP's `modelRoles` remains the authority that maps a role alias to one or more available models.
Built-in defaults are field-wise merged in this order:

1. Built-in `skill_execution.defaults`
2. Built-in `skill_execution.skills[plugin:skill]`
3. Project `skill_execution.defaults`
4. Project `skill_execution.skills[plugin:skill]`

A later value overrides only the field it supplies; role and effort are resolved independently. The
defaults are `role: DEFAULT` and `effort: inherit`. Skill keys are plugin-qualified and should be
quoted in YAML because they contain a colon:

```yaml
version: "1.0"
skill_execution:
  defaults:
    role: DEFAULT
    effort: inherit
  skills:
    "makato-plan:create-prd":
      role: PLAN
      effort: high
    "makato-change:resolve-review":
      role: REVIEW
      effort: medium
    "makato-build:build-review":
      role: REVIEW
      effort: high
```

- `role` is a provider-neutral OMP role name. The loader emits it uppercase; the launcher passes its
  lowercase alias (`PLAN` → `@plan`). Any valid configured role is allowed. `DEFAULT` uses
  `@default`; `PLAN` uses the built-in `@plan` role. `REVIEW` is a custom role: users must configure
  `modelRoles.review` themselves. The skill dispatcher does not create or change global OMP
  configuration; the profile installer (`scripts/select-model-profile.sh`) is an explicit user
  action that merges into it.
- `effort` accepts `off`, `minimal`, `low`, `medium`, `high`, `xhigh`, `max`, `auto`, and `inherit`.
  `inherit` omits the thinking flag; other values are passed as the per-run thinking selection.
- A project may contain only `skill_execution` to adjust execution without copying the artifact
  list. If it contains artifacts too, the two sections may be in either order. Execution-only
  schemas retain all built-in artifacts.
- The loader accepts any artifact skill name, including unregistered custom skills. Such skills
  receive the merged defaults and any exact project override; custom artifacts remain valid without
  registering a skill in the built-in catalog.

Configure concrete models separately in OMP's `config.yml`:

```yaml
modelRoles:
  default: openai/gpt-4.1-mini
  plan: anthropic/claude-sonnet-4-5
  review: anthropic/claude-sonnet-4-5 # custom role; configure explicitly
```

`modelRoles.review` is not a built-in alias. Choose model selectors supported by your OMP
installation and save this yourself (for example, through `/models` or the intended global/project
config). The skill resolver never writes global or project OMP model settings. Nested agents keep
their own shared role from `config/agent-roles.yml` (OMP `task.agentModelOverrides`, Claude Code
`model:` alias): per-skill settings select the outer skill's model and do not rewrite the models
used for agents that skill dispatches.

A normal file read or direct slash-skill invocation does not inspect this schema or switch the
current conversation's model. For headless/autonomous OMP workflow dispatches, use `run-skill.py`;
it resolves the skill's role/effort and runs OMP with `--model @role`, optional `--thinking LEVEL`,
`--plugin-dir PATH`, `--cwd PATH`, and (by default) `--print`. A human-driven interactive workflow
uses an explicit clean-context slash-skill handoff instead of launching a child from an agent tool
shell. The launcher's own invocation syntax is shown in the runtime section below.

The loader uses a restricted parser for `artifacts`; the shared execution resolver uses PyYAML.
Python 3 and the PyYAML package are runtime dependencies.

---

## `artifacts[]` entry fields

| Field         | Type         | Required | Description                                                                                                                                                        |
| ------------- | ------------ | -------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `id`          | string       | yes      | Unique identifier for this artifact within the schema. Used in `after:` dependency references.                                                                     |
| `skill`       | string       | yes      | The makato-build skill invoked for this artifact (e.g. `build-refine`, `build-verify`). Custom artifacts may name any skill path.                                  |
| `required`    | boolean      | yes      | When `true`, the skill MUST be run; when `false`, the skill is optional and may be skipped by the runner.                                                          |
| `description` | string       | no       | Human-readable summary of what this artifact produces.                                                                                                             |
| `after`       | list[string] | no       | IDs of artifacts that must complete before this one may start. Omit entirely for the entry point; do not write `after: []`. Forms the dependency edges of the DAG. |

### Dependency syntax (`after:`)

`after:` accepts a YAML list of artifact `id` strings:

```yaml
after: [implement-tdd, implement-goal]
```

Or in block style:

```yaml
after:
  - implement-tdd
  - implement-goal
```

The loader validates the `after:` list for cycles (both direct and transitive). A circular
dependency causes the loader to exit 1 with the full cycle path in the error message.

### `required` vs optional artifacts

- `required: true` — the skill MUST appear in every pipeline execution.
- `required: false` — the skill is optional. The caller decides whether to invoke it based on
  context (e.g. `grill-with-docs` is optional; `address-pr-comments` is only needed after review
  feedback arrives).

---

## Annotated example

The following schema adds a custom `security-audit` artifact between `verify` and `push-to-git`,
and marks `grill-with-docs` as required for this repo:

```yaml
version: "1.0"

artifacts:
  - id: refine
    skill: build-refine
    required: true
    description: "Bridge planned story to implementation plan"

  - id: grill-with-docs
    skill: build-grill-with-docs
    required: true # overridden to required for this repo
    description: "Align plan vocabulary to domain model"
    after: [refine]

  - id: implement-tdd
    skill: build-implement-tdd
    required: false
    description: "TDD inner loop"
    after: [refine]

  - id: implement-goal
    skill: build-implement-goal
    required: false
    description: "Goal-driven inner loop"
    after: [refine]

  - id: simplify
    skill: build-simplify
    required: true
    after: [implement-tdd, implement-goal]

  - id: review
    skill: build-review
    required: true
    after: [simplify]

  - id: verify
    skill: build-verify
    required: true
    after: [review]

  - id: security-audit # custom artifact not in the built-in default
    skill: security-audit
    required: true
    description: "Internal security scan before commit and push"
    after: [verify]

  - id: push-to-git
    skill: build-push-to-git
    required: true
    after: [security-audit] # now depends on the custom step

  - id: create-pr
    skill: build-create-pr
    required: true
    after: [push-to-git]

  - id: address-pr-comments
    skill: build-address-pr-comments
    required: false
    after: [create-pr]
```

---

## Cycle detection

The loader uses depth-first search to detect circular dependencies before returning the ordered
artifact list.

**Direct cycle** (`A → B → A`):

```yaml
artifacts:
  - id: A
    skill: build-refine
    required: true
    after: [B]
  - id: B
    skill: build-verify
    required: true
    after: [A]
```

Error output:

```text
workflow-schema-loader: cycle detected: A -> B -> A
```

**Transitive cycle** (`A → B → C → A`):

```yaml
artifacts:
  - id: A
    skill: build-refine
    required: true
    after: [C]
  - id: B
    skill: build-verify
    required: true
    after: [A]
  - id: C
    skill: build-sensors
    required: true
    after: [B]
```

Error output:

```text
workflow-schema-loader: cycle detected: A -> C -> B -> A
```

The loader exits 1 on any cycle. Fix the schema before running `build-start`.

---

## Creating a schema interactively

Run `/makato-core:create-workflow-schema` to launch the interactive wizard. It shows the built-in
artifact list and, separately, all built-in skill-execution entries grouped by plugin. When
regenerating, the wizard preserves the complete project-local `skill_execution` block verbatim; it
omits a local block when none was present so built-in settings remain active.

---

## Running skills with resolved settings

Use `plugins/makato-build/scripts/run-skill.py` for a schema-aware skill dispatch. Reading a
`SKILL.md` or invoking a slash skill directly does not inspect the schema or switch the current
conversation model.

```bash
python3 "$MAKATO_BUILD_ROOT/scripts/run-skill.py" \
  --repo-root "$REPO_ROOT" \
  --cwd "${WORKTREE_PATH:-$REPO_ROOT}" \
  --context-file "$CONTEXT_FILE" \
  makato-build:build-review -- "$WORK_ITEM_KEY"
```

`--repo-root PATH` is required. Optional launcher flags, all before the positional `plugin:skill`,
are `--cwd PATH`, `--context-file PATH`, `--interactive`, `--dry-run`, `--harness OMP_BINARY`,
repeatable `--config PATH` overlays, and explicit `--approval-mode always-ask|write|yolo`. Skill
arguments follow `--` and are passed as data. By default the runner starts OMP with `--print`;
`--interactive` only omits it and does not connect a child started from an agent tool shell to a
user-facing TTY. OMP sessions are fresh and ephemeral (`--no-session` is applied by the launcher).
`--approval-mode` is not set unless explicitly requested; the runner does not silently broaden
permissions. A config overlay does not override the schema's role or effort.

The launcher resolves the role and effort, then starts OMP using `--model @role`, adds
`--thinking LEVEL` unless effort is `inherit`, and supplies `--plugin-dir PATH`, `--cwd PATH`, and
`--print` in default non-interactive mode. Concrete model selectors remain in the user's OMP
`modelRoles` config; the runner does not edit global/project OMP settings. A `REVIEW` entry maps to
`@review` only when the user has configured that custom role. Nested agents keep their own shared
role from `config/agent-roles.yml` (OMP `task.agentModelOverrides`, Claude Code `model:` alias);
the outer skill's per-skill settings do not rewrite them.

`MAKATO_BUILD_ROOT` identifies the installed makato-build plugin directory, not the target
project. The launcher infers sibling makato-plan/makato-change directories in a checkout;
for separately cached installations, set `MAKATO_PLAN_ROOT` and `MAKATO_CHANGE_ROOT`
explicitly. Child runs inherit these roots and `MAKATO_SKILL_RUNNER`.

For GitHub-backed runs, export `KEY`, `ISSUE_NUMBER`, `REPO` (the issue's
`owner/repository`), and `MAKATO_ORCHESTRATE_ROOT` before launching. The launcher
uses the installed `shared/progress-comment.sh` to append START and DONE to the
same live issue comment for each execution, including failures and retries. An
explicit `MAKATO_ORCHESTRATE_SHARED` is also supported; otherwise the existing
runtime resolver discovers the orchestrate plugin when no root was supplied.
Child runs inherit the reporting context. Do not duplicate these lifecycle entries
manually; use `note` for validated R1 summaries or intermediate progress. DONE
reports the process outcome, not semantic skill success; the coordinator still
validates R1 and artifacts. Reporting preserves stdout/stderr and exit status,
forwards SIGINT/SIGTERM, and never makes a GitHub failure fatal. Local runs without
issue context and `--dry-run` do not post; `MAKATO_PROGRESS_COMMENT_DISABLE=1`
explicitly disables reporting. Partial issue context logs an actionable warning.

A fresh process has no parent conversation. Pass a complete UTF-8 context file containing
the issue/key, repository/worktree paths, artifact paths, decisions, and step-specific inputs.
In default `--print` mode, the launcher includes the selected skill verbatim and tells any
subsequent workflow skill to use the same launcher with another complete context bundle. In
`--interactive` mode, the selected skill runs inline but must not launch a subsequent workflow
skill; it persists the required next-step inputs and returns a clean-context `/handoff`/`/new`
plus `/skill:<name>` instruction. Reference reads and ordinary helper agents are not new workflow
dispatches. Non-interactive missing decisions are reported to the coordinator rather than
invented. Interactive questions are appropriate only when the user can answer directly; `--interactive`
does not make an agent tool-shell child visible to the user.

Repository artifacts and logs persist, but the ephemeral skill conversation cannot be resumed.
The autonomous change entry wrapper retains its own existing session/watchdog lifecycle.

---

## See also

- `plugins/makato-build/config/default-workflow-schema.yml` — built-in default
- `plugins/makato-build/scripts/workflow-schema-loader.sh` — parses and orders artifacts
- `plugins/makato-build/shared/skill_execution.py` — resolves role and effort
- `plugins/makato-build/scripts/run-skill.py` — starts a schema-aware skill run
- `plugins/makato-build/skills/build-start/SKILL.md` — the pipeline consumer
