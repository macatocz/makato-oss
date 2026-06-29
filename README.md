# makato

Development AI Suite

## Contributor onboarding

This repo is a monorepo of Claude Code plugins. Each plugin under `plugins/` owns its own
`AGENTS.md` with the rules that govern that plugin's surface. Before editing files under
`plugins/<name>/`, read that plugin's `AGENTS.md` first.

A repo-root **routing index** is generated on demand from each plugin's `AGENTS.md`. It lives at
the repo root as `AGENTS.md` / `CLAUDE.md` and is intentionally **gitignored** — the file is a
per-checkout local artefact, not part of the plugin distribution.

```bash
./scripts/regenerate-agents.sh
```

Run after adding or removing a plugin. The output is idempotent — re-running produces
byte-identical content unless a plugin's `AGENTS.md` or `plugin.json` description changed.

To have it run on every Claude Code SessionStart, add a hook to your own
`.claude/settings.local.json` (gitignored, so it is your personal preference and does not impose
on other contributors):

```jsonc
{
  "hooks": {
    "SessionStart": [
      {"hooks": [{"type": "command",
                  "command": "${CLAUDE_PROJECT_DIR}/scripts/regenerate-agents.sh"}]}
    ]
  }
}
```

## Smoke tests

The repo ships a small **pytest harness** scoped narrowly to skill smoke tests
and existing per-plugin unit tests. It is NOT a declaration that "makato is a
Python package" — plugin distribution remains via Claude Code's plugin
marketplace. The harness exists so contract-critical skills (`build-simplify`'s
no-test-runner handling, `inject_context.resolve_bundles`, the
`dotx-schema-extractor` curation pipeline) regress on every change.

Run from the repo root:

```bash
python3 -m pytest
```

The harness discovers tests in three locations declared in `pyproject.toml` →
`[tool.pytest.ini_options].testpaths`:

- `tests/` — repo-level smoke tests (e.g. `test_smoke_build_simplify.py`)
- `plugins/makato-build/shared/` — context-bundle resolver unit tests
- `plugins/makato-sagibeast/skills/dotx-schema-extractor/tests/` — curation tests

Adding a test runner to plugins that don't already have one is explicitly
out of scope — the harness only covers existing pytest-collectable code.
