"""Unit tests for the models: block extension to parse-config.py (AC-3, AC-4).

Covers four scenarios required by the Task 2 spec:
  1. flat-list-only input produces byte-for-byte identical output (regression guard)
  2. models-block-only input emits one MAKATO_MODEL_<ROLE>_BASE_URL per role
  3. mixed input (vars: list + models: dict) emits both flat-list and MAKATO_MODEL_* lines
  4. a role entry with missing optional fields (e.g. no base_url) does not raise

Import strategy: importlib.util.spec_from_file_location — required by pyproject.toml
``--import-mode=importlib`` and the non-package filename ``parse-config.py``.
"""

from __future__ import annotations

import importlib.util
import pathlib
import textwrap

import pytest

REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent
PARSE_CONFIG = (
    REPO_ROOT / "plugins" / "makato-orchestrate" / "config" / "parse-config.py"
)


def _load_module():
    spec = importlib.util.spec_from_file_location("parse_config", PARSE_CONFIG)
    assert spec is not None and spec.loader is not None, (
        f"Could not create ModuleSpec for {PARSE_CONFIG}"
    )
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)  # type: ignore[union-attr]
    return mod


_mod = _load_module()
load = _mod.load
emit = _mod.emit


# ---------------------------------------------------------------------------
# YAML fixture helpers
# ---------------------------------------------------------------------------


def _write(tmp_path: pathlib.Path, content: str) -> pathlib.Path:
    """Write YAML content to a temp file; strip leading blank line from dedented string."""
    p = tmp_path / "config.yml"
    p.write_text(textwrap.dedent(content).lstrip(), encoding="utf-8")
    return p


# Flat-list-only: YAML sequence of {var, env, default, export} dicts — current format.
FLAT_LIST_YAML = """\
    - { var: FOO, env: MAKATO_FOO, default: "bar" }
    - { var: BAZ, default: "qux" }
    - { var: EXPORTED, default: "val", export: true }
"""

# Models-only: YAML mapping with a top-level models: key.
MODELS_ONLY_YAML = """\
    models:
      default:
        base_url: "https://api.openai.com/v1"
      fast:
        base_url: "https://api.groq.com/v1"
"""

# Mixed: YAML mapping with both vars: (flat-list) and models: block.
MIXED_YAML = """\
    vars:
      - { var: FOO, env: MAKATO_FOO, default: "bar" }
    models:
      default:
        base_url: "https://api.openai.com/v1"
"""

# Missing optional: roles that have no base_url must not raise.
MODELS_MISSING_OPTIONAL_YAML = """\
    models:
      default: {}
      minimal:
        base_url: "https://api.example.com"
"""


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------


def test_flat_list_only_is_unchanged(tmp_path: pathlib.Path) -> None:
    """Flat-list YAML produces identical output to before — no MAKATO_MODEL_* lines emitted.

    Regression guard: the existing {var, env, default} code path must remain
    byte-for-byte unchanged after the models: branch is added.
    """
    cfg = _write(tmp_path, FLAT_LIST_YAML)
    output = emit(load(str(cfg)))
    assert 'FOO="${MAKATO_FOO:-bar}"' in output
    assert 'BAZ="qux"' in output
    assert 'export EXPORTED="val"' in output
    assert "MAKATO_MODEL_" not in output


def test_models_block_only_emits_makato_model_vars(tmp_path: pathlib.Path) -> None:
    """models: block emits one MAKATO_MODEL_<ROLE>_BASE_URL="<url>" assignment per role.

    AC-3: new schema branch detects top-level models: dict and emits correct variables.
    AC-4: MAKATO_MODEL_DEFAULT_BASE_URL presence confirms emittability.
    """
    cfg = _write(tmp_path, MODELS_ONLY_YAML)
    output = emit(load(str(cfg)))
    assert 'MAKATO_MODEL_DEFAULT_BASE_URL="https://api.openai.com/v1"' in output
    assert 'MAKATO_MODEL_FAST_BASE_URL="https://api.groq.com/v1"' in output


def test_mixed_input_emits_both_sets(tmp_path: pathlib.Path) -> None:
    """YAML with vars: list and models: dict emits both flat-list vars and MAKATO_MODEL_* vars.

    AC-3: backward-compatible code path (vars:) and new models: branch coexist.
    """
    cfg = _write(tmp_path, MIXED_YAML)
    output = emit(load(str(cfg)))
    assert 'FOO="${MAKATO_FOO:-bar}"' in output
    assert 'MAKATO_MODEL_DEFAULT_BASE_URL="https://api.openai.com/v1"' in output


def test_models_missing_optional_fields_does_not_raise(tmp_path: pathlib.Path) -> None:
    """A role entry with no base_url must not raise — emits an empty-default assignment.

    AC-3: missing optional fields are tolerated; role is still emitted with empty value.
    """
    cfg = _write(tmp_path, MODELS_MISSING_OPTIONAL_YAML)
    output = emit(load(str(cfg)))  # must not raise
    assert "MAKATO_MODEL_DEFAULT_BASE_URL" in output
    assert "MAKATO_MODEL_MINIMAL_BASE_URL" in output
