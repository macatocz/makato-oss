---
name: makato-skill-creator
description: Create a complete, working skill inside an existing makato plugin with full guardrails and validation — create skill, new skill, add skill to plugin, write a skill
version: "1.3.0"
allowed-tools: Read Write Glob Bash(./scripts/*) Bash(./plugins/*/pre-commit/*) Bash(python3 *) Bash(cp *) Bash(open *) Bash(xdg-open *)
---
# makato-skill-creator

## When to Use

Use when a contributor wants to add a fully-realized skill to an existing makato plugin. This skill does not generate empty stubs — it creates complete, working skills with real workflows, references, and templates, all validated against makato suite guardrails.

## Workflow

This skill follows a strict 3-phase workflow: **Plan → Present → Build**. No files are created until the user explicitly approves the plan.

---

### Phase 1: Plan

#### Step 1: Identify Target Plugin

Ask the user: **"Which makato plugin should this skill be added to?"**

Validate:

1. The plugin exists: check `plugins/<name>/.claude-plugin/plugin.json`
2. Read the plugin's `plugin.json` to get: name, description (goal statement), existing skills
3. Read the plugin's `AGENTS.md` to understand what belongs and the decision test

If the plugin doesn't exist, suggest using `makato-plugin-creator` first.

#### Step 2: Define the Skill's Purpose

Ask the user:

1. **What should this skill accomplish?** (the transformation or outcome)
2. **What inputs does it need from the user?** (questions to ask, files to read, context needed)
3. **What outputs does it produce?** (files, artifacts, decisions, suggestions)
4. **What is the skill name?** (kebab-case, e.g., `review-spec`, `generate-tests`)

Validate the skill name:

- Load @references/naming-conventions.md
- Must match pattern: `^[a-z][a-z0-9-]*$`
- Must not already exist in the plugin's `skills/` directory

#### Step 3: Goal Alignment Check

Load @references/decision-test-pattern.md

Apply the decision test:

- Read the parent plugin's goal statement from `plugin.json` description field
- Ask: **"Does this skill demonstrably serve the goal: '`<goal>`'?"**
- If clearly aligned → proceed
- If unclear → discuss with the user, explain which plugin might be more appropriate
- If misaligned → recommend a different plugin or suggest creating a new one

#### Step 4: Design the Skill Workflow

Based on the user's description, design a multi-step workflow:

1. Break the skill's function into concrete, numbered steps
2. Each step must be actionable (not vague — "Generate X" not "Handle X")
3. Include validation points where the skill should check its work
4. Identify what reference files the skill needs (domain knowledge, rules, examples)
5. Identify what template files the skill needs (structured output patterns)
6. Consider error paths and edge cases

Load @references/skill-authoring-rules.md to ensure the workflow design follows conventions.

#### Step 5: Plan References and Templates

For each piece of domain knowledge the skill needs:

- Plan a reference file in `references/` (focused on one topic, under 100 lines)
- References are read-only context loaded at point of use

For each structured output the skill produces:

- Plan a template file in `templates/` (with `<placeholder>` syntax)

Load @references/self-containment-rules.md to verify all planned files will be local to the skill directory.

---

### Phase 2: Present (Interactive HTML Review)

#### Step 6: Generate HTML Plan

Create an interactive HTML plan file at `/tmp/makato-skill-plan-<skill-name>.html`.

Use @references/plan-template.html as the structural template. Fill in the following sections:

1. **Goal Alignment** (first section, prominent):

   - Parent plugin name and goal statement
   - How this skill serves the plugin's goal
   - Where this skill fits in the plugin's existing skill workflow
2. **Skill Identity**:

   - Name, description (with trigger words embedded), version
   - Complete frontmatter preview
3. **Workflow Steps**:

   - Each step as a collapsible section
   - Step number, title, and full description
   - Any `@references/` loads noted inline
4. **Reference Files Planned**:

   - Filename, purpose, content summary for each
5. **Template Files Planned** (if any):

   - Filename, purpose, placeholder fields
6. **File Tree**:

   - Visual directory structure of what will be created
7. **Routing Registration** (both paths):

   - Whether the skill is **technical/routable** (register) or **interactive/meta**
     (skip) — state the verdict and the one-minute-test reasoning
   - If registering: (a) which `config/skill-bundles.yml` bundle gains the skill and
     whether it is a **domain** bundle (glob over user-authored source files) or the
     **self-dev** `<prefix>-skills` bundle — plus the glob/`contains`/`task_contains`
     used; and (b) which `task-skill-map.json` archetype key(s) gain the
     `<plugin>:<skill-name>` entry
   - If skipping: say so explicitly for BOTH paths, so the reviewer knows it was a
     decision
8. **Validation Checks**:

   - List of scripts that will run (including `validate-skill-bundles.sh`)
   - What each checks for

Each section includes a comment textarea for the user to annotate.
A "Copy Feedback" button at the bottom aggregates all non-empty comments into structured text.

#### Step 7: Open and Collect Feedback

Automatically open the HTML file in the browser:

- macOS: `open /tmp/makato-skill-plan-<skill-name>.html`
- Linux: `xdg-open /tmp/makato-skill-plan-<skill-name>.html`

Tell the user:

> "I've opened the skill plan in your browser. Review each section and add comments in the text areas for anything you'd like changed. When done, click 'Copy Feedback' and paste it back here."

#### Step 8: Iterate on Feedback

When the user pastes feedback:

1. Parse the structured comments (section → feedback mapping)
2. Address each piece of feedback
3. Regenerate the HTML plan with changes
4. Re-open in browser
5. Repeat until the user says they approve (e.g., "looks good", "approved", "build it")

---

### Phase 3: Build

Only proceed after explicit user approval.

#### Step 9: Create SKILL.md

Load @references/frontmatter-spec.md for field requirements.
Load @references/skill-authoring-rules.md for structure conventions.

Write the complete `SKILL.md` with:

- Valid YAML frontmatter (name, description with trigger words, version)
- "When to Use" section with clear scope definition
- "Workflow" section with numbered steps and detailed instructions
- `@references/` loads at point of use (not front-loaded)

**Author for skill-judge quality (avoid built-in point deductions):**

- **`allowed-tools` (skill-judge D4):** if any workflow step runs a shell command,
  declare `allowed-tools` in the frontmatter listing those tools (e.g.
  `allowed-tools: Read Bash Glob`). A skill that uses `Bash(...)` without
  `allowed-tools` both prompts the user on every invocation and loses 1–2 D4 points.
  Skills that run no shell commands omit the field.
- **`AskUserQuestion` (skill-judge D2):** when a step collects a *choice* from the
  user, instruct Claude to use the `AskUserQuestion` tool with selectable options
  rather than a freeform prose question. Prose like "ask the user what X they want"
  loses 2–3 D2 points and produces inconsistent answers. (Open-ended context the
  user must type freely — e.g. "what should this skill accomplish?" — stays prose.)
- **Anti-patterns inline (skill-judge D3, not a trailing NEVER list):** place
  domain-specific NEVER/WHY guidance at the workflow step it applies to, never in a
  trailing section (end-of-file content is dropped first under compaction).
- **Knowledge delta (skill-judge D1):** keep only expert-only knowledge in
  `SKILL.md`; move basics Claude already knows into `references/` behind an explicit
  load trigger.

Place at: `plugins/<plugin>/skills/<skill-name>/SKILL.md`

#### Step 10: Create Reference Files

For each planned reference:

- Write the file to `plugins/<plugin>/skills/<skill-name>/references/<filename>.md`
- Content must be self-contained and under 100 lines
- Each reference covers one focused topic

#### Step 11: Create Template Files (if any)

For each planned template:

- Write the file to `plugins/<plugin>/skills/<skill-name>/templates/<filename>`
- Use `<placeholder-name>` syntax for variable parts

#### Step 12: Register the Skill on Both Routing Paths (technical skills only)

A technical skill reaches a coder agent through **two independent routing paths**,
and a skill must be registered on **both** or it is only surfaced in narrow cases:

- **Glob bundle** (`plugins/<plugin>/config/skill-bundles.yml`) — its only consumer
  is `inject-skills`, which prepends the skill into a **programmatically-dispatched
  sub-agent's** system prompt when that agent touches files matching a glob (or a
  task matches `task_contains`). Fires for work that **touches existing files**.
- **Task-archetype map** (`plugins/makato-plan/config/task-skill-map.json`) — read
  by `decompose`, which emits `recommended_skills[]` per sub-task when the sub-task
  title matches an archetype key. Fires for **green-field** work where the domain
  files do not exist yet.

Only a **technical / routable** skill belongs on either path. An **interactive /
meta** skill (one a human invokes directly) must NOT be registered on either —
injecting it into a headless agent is pure noise.

Load @references/skill-bundles-rules.md for the bundle schema, naming convention,
and the wide-glob precision-filter gate. Load @references/routing-registration.md
for the two-path model, the domain-vs-self-dev bundle distinction, and the
task-map schema.

**Decision gate — apply the one-minute test first:**

1. **Could a headless coder agent, already mid-task, act on this skill's content
   with no human present?** If NO → the skill is interactive/meta. **Skip
   registration on both paths** (do not create or modify `skill-bundles.yml` or
   `task-skill-map.json`); note in the Step 16 summary that the skill was
   intentionally not registered, and why.
2. **Can you write a glob or `task_contains` predicate that fires only when this
   skill's domain is actually in play?** If NO → do not register (a skill that
   would only match a wide `**/*`-style glob with no precision filter is rejected
   by the pre-commit gate anyway).

Register **only if both answers are YES**. Quick signals:

- **Technical (register):** dispatched/invoked by another skill or agent; documents
  library/framework/SDK construction patterns; fixes/verifies/optimizes a concrete
  artifact; runs in AUTONOMOUS-MODE / headless-safe; value scales with a file-type
  match. Examples: `langgraph-*`, `manage-postgres`, `build-fix-types`, `build-verify`.
- **Interactive (skip):** first step is an interview/question; presents for approval
  or waits for human sign-off; is an entry-point/orchestrator/phase coordinator;
  produces a planning artifact for human review; manages GitHub issues/PRs/boards as
  its primary action. Examples: `brainstorming`, `stress-test-artifact`, `makato-skill-creator`,
  `sync-from-upstream`, `to-issues`, `loop`.

**If the skill is technical, perform BOTH registrations (12a glob + 12b task-map):**

##### Step 12a: Glob bundle — route on the files the skill's domain actually lives in

The most common mistake is appending the skill to **only** the self-referential
`<prefix>-skills` bundle (glob `plugins/<plugin>/skills/**/*.md`). That glob fires
only when someone edits the **makato plugin's own skill files** — never when a coder
writes a user's application code — so the skill stays effectively unroutable for real
work. That is exactly why the `makato-core` skills route only during
self-development. Avoid repeating it.

1. **Decide domain vs self-dev** (see @references/routing-registration.md):
   - Skill acts on **user-authored source files** (library/framework/SDK pattern,
     file-format handler, lint/type/security fixer) → you MUST add or extend a
     **domain bundle** whose glob matches those user files (e.g. `**/*graph*.py`
     with `contains: ["from langgraph"]`). Add the self-dev `<prefix>-skills` entry
     too only if editing the plugin's own docs should also surface it.
   - Skill acts **only on makato's own plugin files** (contributor tooling) → the
     self-dev `<prefix>-skills` bundle is the correct and only target.

2. **Check for an existing registry** at `plugins/<plugin>/config/skill-bundles.yml`.

3. **If a matching domain bundle already exists** (e.g. `langgraph`, `database-orm`,
   `fastapi`) — append `<skill-name>` to its `skills:` list. Do not create a
   near-duplicate bundle.

4. **If no matching bundle exists** — add one. For a domain bundle, write a glob over
   the user-code files plus a `contains:` (and, recommended, `task_contains:` that
   mirrors the Step 12b archetype triggers). For a self-dev skill, find or add the
   `<prefix>-skills` bundle (glob `plugins/<plugin>/skills/**/*.md`).

5. **If the file does NOT exist** — create it from @templates/skill-bundles.yml,
   substituting `<plugin>`, `<prefix>`, and seeding the appropriate bundle. (Do not
   blanket-seed interactive skills; apply the same decision gate to each existing
   skill you add.)

6. **Never add a `default` bundle** — `makato-build` owns the single suite-wide
   `default`. A per-plugin registry contains only that plugin's non-default bundles.

7. **Bundle names are globally unique** across the merged registry — a collision
   raises HALT-006. Always prefix any bundle you add with the plugin's short name
   (`<prefix>` = plugin name without `makato-`).

##### Step 12b: Task-archetype map — route on green-field task titles

Register the same technical skill in `plugins/makato-plan/config/task-skill-map.json`
so `decompose` recommends it for from-scratch tasks (where no domain files exist yet
for the Step 12a glob to match).

1. Open `plugins/makato-plan/config/task-skill-map.json`. Its schema is
   `{ "<archetype>": ["<plugin>:<skill-id>", ...] }`.
2. Add `<plugin>:<skill-name>` (fully-qualified — a bare id will not resolve) to
   every existing archetype key whose work would call for the skill.
3. If no existing archetype fits, add a new verb-first archetype key
   (e.g. `"implement-<domain>-<thing>"`) mapping to the skill.
4. Prefer extending existing keys over inventing near-duplicates. Never trim the
   file — it requires ≥ 200 entries and you are only adding.

#### Step 13: Update Parent Plugin Files

1. Add entry to `plugins/<plugin>/CHANGELOG.md`:

   ```markdown
   ### Added
   - `<skill-name>` skill (<one-line description>)
   ```
2. Update the skills table in `plugins/<plugin>/README.md` if one exists.

**Do NOT modify `plugin.json`** — skills are auto-loaded from the directory structure.

#### Step 14: Validate

Run validation scripts:
```bash
./scripts/check-skill-frontmatter.sh plugins/<plugin>/skills/<skill-name>
./scripts/check-self-contained.sh plugins/<plugin>/skills/<skill-name>
./scripts/check-naming.sh
```

Then validate the bundle registry you touched in Step 12a (the pre-commit gate that
also runs at commit time):
```bash
./plugins/makato-langgraph/pre-commit/validate-skill-bundles.sh plugins/<plugin>/config/skill-bundles.yml
```

If you edited `task-skill-map.json` in Step 12b, verify it still parses and that the
new entry uses the fully-qualified `<plugin>:<skill-id>` form:
```bash
python3 -c "import json,sys; d=json.load(open('plugins/makato-plan/config/task-skill-map.json')); assert any('<skill-name>' in v for v in d.values() if isinstance(v,list)), 'skill not found in any archetype'; print('task-skill-map OK:', len(d)-1, 'archetypes')"
```

If any check fails:

1. Report the specific error
2. Fix the issue
3. Re-run the failing check
4. Repeat until all pass

#### Step 15: Persist Skill Plan

Copy the final approved HTML plan into the new skill's references:

```bash
cp /tmp/makato-skill-plan-<skill-name>.html plugins/<plugin>/skills/<skill-name>/references/skill-plan.html
```

This preserves the design rationale, workflow decisions, and feedback iterations for future reference when modifying the skill.

#### Step 16: Summary

Present to the user:

1. **Files created** — full list with paths (including `references/skill-plan.html`)
2. **Parent files updated** — CHANGELOG, README, and (for a technical skill) both
   routing registrations: `config/skill-bundles.yml` (which bundle — domain or
   self-dev — gained the skill) and `plugins/makato-plan/config/task-skill-map.json`
   (which archetype keys gained the skill). For an interactive/meta skill, state
   explicitly that registration on both paths was intentionally skipped and why.
3. **Validation result** — all checks passed (including `validate-skill-bundles.sh`
   and the `task-skill-map.json` parse check when those registries were touched)
4. **Test command**: `claude --plugin-dir ./plugins/<plugin-name>`
5. **PR title suggestion**: `feat(<plugin-name>): add <skill-name> skill`
