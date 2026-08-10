# makato Python Standards

> **Scope**: All Python files in the makato repo (`plugins/*/shared/*.py`, `scripts/*.py`, `tests/*.py`).
> **Enforced by**: ruff (lint + format), pyright (type-checking), pytest (test runner).

## Test framework

**pytest is the test runner** (declared in `pyproject.toml → [tool.pytest.ini_options]` with `--import-mode=importlib`). It runs in CI (`.github/workflows/validate.yml`) and via the `pytest-fast` / `pytest-slow` pre-commit hooks. Run the full suite with:

```bash
python3 -m pytest
```

Two test styles coexist and are both collected by pytest:

- **`unittest.TestCase` classes** — the established style in `plugins/makato-build/shared/`. Methods are prefixed `test_`; skip with `@unittest.skip` / `@unittest.skipIf` / `@unittest.skipUnless`. See `plugins/makato-build/shared/test_inject_context.py` as the canonical example. Do not rewrite these into native pytest.
- **Native pytest functions** — used in `plugins/makato-orchestrate/scripts/tests/` (e.g. `test_mark_ac_checkboxes.py` uses `pytest.raises`). Acceptable for new test directories added to `testpaths`.

`testpaths` in `pyproject.toml` is authoritative for what gets collected — add a new directory there when introducing tests outside the existing paths.

## Module structure

- **Stdlib only** unless the module's docstring explicitly declares an optional dependency (e.g. `# Optional: prefer vendored sarif-om when available, but never required.`). Optional imports are wrapped in `try/except ImportError`.
- Every public Python module begins with a module-level docstring describing its purpose, contract, and return shape.
- `from __future__ import annotations` is the first import when forward references are needed.
- `__all__` is declared at module bottom when the module is a library (not a script).

## `inject_context.py` patterns

`inject_context.py` is the canonical "pure-function, typed-exception, stdlib-only" reference:

- Public functions are **pure**: they accept typed inputs, return typed outputs, and raise only documented exceptions. No global state mutation.
- Return shape is a **typed tuple**: `(rules: list[str], warning: dict | None)`. Callers destructure immediately.
- Errors that require the orchestration loop to halt carry a `halt_code` attribute on the exception: `BundleResolutionError(message, halt_code="HALT-006")`.
- Resolution contract is documented in the module docstring as a numbered list, one item per invariant. The tests mirror this numbering.

## Shared helper scripts under `plugins/*/shared/`

- Shell scripts (`.sh`) are invoked from skills and by CI — they are NOT Python and do not need Python imports.
- Python helpers (`inject_context.py`, `parse-sarif.py`, `inject_skills.py`, `skill_passport.py`, `skill_routing.py`) are **importable libraries** not CLI entry points, unless the module declares a `__main__` block or `# CLI:` section in its docstring.
- Test files are co-located: `test_<module>.py` lives in the same `shared/` directory as `<module>.py`.
- When a helper has both a library API and a CLI, the CLI is gated with `if __name__ == "__main__":`. See `parse-sarif.py` (`--selftest` flag) as the canonical pattern.

## YAML config

Load YAML via PyYAML (`import yaml`). PyYAML is the only non-stdlib dependency used in the shared helpers. Integration tests that require PyYAML guard with `@unittest.skipUnless(yaml_available, "PyYAML not installed")`.

## `BundleResolutionError` / `halt_code` contract

Exceptions that require the outer loop (PO-agent) to stop processing carry a `halt_code` string attribute. Values are from `plugins/makato-orchestrate/halt-conditions.md`. The calling skill or agent is responsible for translating the exception into a `build.jsonl` entry and returning R1 `failure` with the matching `data.halt_code`.

## R1 envelope (Python-emitting agents)

Python agents emit R1 as the **last fenced `\`\`\`json` block** of their output. The authoritative schema lives in `plugins/makato-build/agents/RETURN-CONTRACT.md`. Required fields:

```python
r1 = {
    "schema": "r1",
    "agent": "<agent-name from frontmatter>",
    "status": "success | partial | failure",
    "summary": "<one-line synthesis, ≤ 240 chars>",
    "files_changed": [],   # list[str], repo-relative paths, never null
    "tests_written": [],   # list[str], never null
    "errors": [],          # list[str], empty when status == "success"
    "tool_calls_used": 0,  # int, best-effort, never omit
    "data": {},            # dict, agent-specific, never null
}
```

No prose may appear after the R1 block. The block must be valid `json.loads()`-parseable JSON (no comments, no trailing commas).

## Type annotations

- Use `from __future__ import annotations` for forward references.
- Prefer built-in generics (`list[str]`, `dict | None`) over `typing.List`, `typing.Dict` (Python 3.10+ style, compatible with 3.12+).
- `Iterable` from `typing` is accepted for function parameters that iterate a sequence without random access.
- `@dataclass` is the preferred way to declare structured data (see `PassportNode` in `skill_passport.py`, `Finding` in `parse-sarif.py`).

## Linting / formatting

- **ruff** handles both lint and format (`ruff check` + `ruff format`). Do not run black or isort separately.
- **pyright** for static type-checking. Errors are hard failures in CI.
- Line length: 88 characters (ruff default). Docstrings may exceed this for readability.
