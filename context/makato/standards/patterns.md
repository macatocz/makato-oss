# makato Structural Patterns

> **Scope**: Plugin shell skill authoring, R1 envelope contract, JSONL audit logging, the `spec_tier:plan-only` lightweight lane, and `{repo}` token substitution in `context-bundles.yml`. Applies across all plugins in the makato monorepo.

## Plugin Shell Skill Authoring

Skills are self-contained directories under `plugins/<plugin>/skills/<skill-name>/`:

- A skill's only mandatory file is `SKILL.md` (with `name:`, `description:`, `version:` frontmatter).
- **No `../` paths** outside the skill directory, except `../shared/` (the plugin's shared helpers). Cross-plugin references (e.g. `../../makato-orchestrate/shared/`) are not allowed — they couple plugins and break copying.
- References and templates live under `<skill-name>/references/` and are loaded at the **point of use** in the SKILL.md steps, not front-loaded at the top of the file.
- Shell scripts inside a skill (e.g. `references/smoke-tests.sh`) use relative paths within the script's own directory; absolute paths that survive `cd` are sourced from `$REPO_ROOT`.
- `shared/build-log.sh` is called as a bare relative path from within the plugin directory — do not use `../shared/build-log.sh` or an absolute path in skill prose. Claude resolves it from the plugin root context.

### Skill directory layout (canonical)

```
plugins/<plugin>/skills/<skill-name>/
├── SKILL.md              # Required: skill entry point
├── references/           # Optional: templates, rules, smoke-test scripts
│   ├── *.md             # Rule files loaded at point of use
│   └── *-smoke-tests.sh # Smoke-test scripts
└── (no ../  paths beyond ../shared/)
```

## R1 Envelope Contract

Every agent that emits structured output emits an R1 JSON block as the **last fenced ` ```json ` block** of its final message. The authoritative spec lives in `plugins/makato-build/agents/RETURN-CONTRACT.md`.

### Required fields

```json
{
  "schema": "r1",
  "agent": "<agent-name from frontmatter>",
  "status": "success | partial | failure",
  "summary": "<one-line synthesis, ≤ 240 chars>",
  "files_changed": [],
  "tests_written": [],
  "errors": [],
  "tool_calls_used": 0,
  "data": {}
}
```

### Emission rules

- `schema` is the literal string `"r1"`. `agent` equals the agent's frontmatter `name:`.
- The R1 block must be valid `JSON.parse()`-parseable JSON — no comments, no trailing commas.
- No prose may appear after the R1 block.
- `files_changed`, `tests_written`, and `errors` are always lists — never `null`.
- Caller parse rule: take the last ` ```json ` block; if `schema != "r1"` or parse fails → treat as `failure`.

## JSONL Audit Log Pattern

Every skill appends structured JSONL to `specs/<key>-<slug>/build.jsonl` via `shared/build-log.sh`. This file is the only spec artifact committed to the repo (`specs/**/build.jsonl` is git-tracked; everything else under `specs/` is gitignored).

### Minimum required events

Every skill run MUST emit at minimum:

1. **Session start** — `step:"session"`, `status:"start"` before any task execution.
2. **Each major step** — one entry per phase (baseline, build, verify-runtime, test, verify-task, etc.).
3. **Session end** — `step:"session"`, `status:"ok"` (or `"error"`) as the last entry.

### Decision and warning entries

Log every deviation from the happy path with `status:"decision"` or `status:"warn"`. Examples: fixable-vs-structural classification, gate retries, workarounds, baseline-gate user choices. A future session reading `build.jsonl` must reconstruct what happened and why.

### Entry shape

```json
{
  "ts": "2026-07-14T19:21:45.608Z",
  "skill": "build-implement-tdd",
  "story": "348-makato-orchestrate-emit-a-durable-needs",
  "step": "session",
  "status": "start",
  "task": 1,
  "data": {}
}
```

`task` and `data` are optional. `issue` (int) replaces `story` in orchestrate-level events.

## `spec_tier:plan-only` Lightweight Lane

A story enters the lightweight lane when `seed-manifest.json` carries `spec_tier:"plan-only"`. In this mode:

- `build-refine` Step 3 detects `spec_tier == "plan-only"` and **skips the `design.md`-missing guard** — no `MISSING_ACCEPTANCE` halt for an absent `design.md`.
- Acceptance criteria are sourced from `plan.md` `## Acceptance criteria` (not from `stories.json` successScenarios). The section **must be non-empty** — an absent or empty section halts with `MISSING_ACCEPTANCE`.
- `build-create-pr`'s "How to Test" section is sourced from `plan.md` `## Acceptance criteria` when `stories.json` is absent (D11).
- An absent `spec_tier` field preserves legacy behavior byte-for-byte (existing full-tier stories are unaffected).

This lane is for small, well-scoped features where a `plan.md` alone is sufficient — no `stories.json`, `prd.md`, or `design.md` required. Validated by `shared/plan-only-tier-smoke-tests.sh`.

## `{repo}` Token Substitution in `context-bundles.yml`

Rule paths in `plugins/makato-build/config/context-bundles.yml` use the literal token `{repo}` as a placeholder for the target repo name:

```yaml
bundles:
  - name: python
    globs:
      - "**/*.py"
    rules:
      - "context/{repo}/standards/python.md"
      - "context/{repo}/standards/naming.md"
```

At resolution time, `knowledge-scout` substitutes `{repo}` with the target repo name (e.g. `makato`) to produce concrete paths like `context/makato/standards/python.md`.

Substitution is performed by the caller (knowledge-scout / inject-context skill) **after** `resolve_bundles()` returns the raw rule list. The `inject_context.py` resolver returns paths with the literal `{repo}` token intact — substitution is never done inside the Python module.

This lets a single `context-bundles.yml` serve every repo that uses `inject-context`, with each repo providing its own `context/<repo-name>/` directory.
