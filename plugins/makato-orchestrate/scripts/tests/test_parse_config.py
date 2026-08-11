"""Tests for config/parse-config.py — config.yml → bash assignment emitter.

Verifies the emitted `NAME="${ENV:-default}"` lines preserve loop.sh's original
env-override contract, that `export` is applied only where declared, and that the
stdlib fallback matches the PyYAML path byte-for-byte. Stdlib-only + pytest:
  python3 -m pytest plugins/makato-orchestrate/scripts/tests/test_parse_config.py -v
"""

from __future__ import annotations

import importlib.util
import os
import subprocess
import sys

_CONFIG_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", "config"))
_PARSER = os.path.join(_CONFIG_DIR, "parse-config.py")
_CONFIG_YML = os.path.join(_CONFIG_DIR, "config.yml")


def _load_module():
    spec = importlib.util.spec_from_file_location("parse_config", _PARSER)
    assert spec is not None and spec.loader is not None
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def _emit_via_subprocess():
    out = subprocess.run(
        [sys.executable, _PARSER, _CONFIG_YML],
        capture_output=True,
        text=True,
        check=True,
    )
    return out.stdout.rstrip("\n")


def test_known_defaults_emitted():
    """A representative sample of vars emit the exact env-override contract."""
    out = _emit_via_subprocess()
    assert 'DEFAULT_INTERVAL="${MAKATO_LOOP_INTERVAL:-300}"' in out
    assert 'DEFAULT_STATUS="${MAKATO_LOOP_STATUS:-Ready}"' in out
    assert 'STALL_THRESHOLD_SECS="${MAKATO_LOOP_STALL_THRESHOLD:-300}"' in out
    assert 'MAX_STALL_RESTARTS="${MAKATO_MAX_STALL_RESTARTS:-3}"' in out
    assert 'STALL_BACKOFF_BASE_SECS="${MAKATO_STALL_BACKOFF_BASE:-60}"' in out


def test_empty_default_emits_empty_expansion():
    out = _emit_via_subprocess()
    assert 'MAKATO_LOOP_ALLOW_TODO="${MAKATO_LOOP_ALLOW_TODO:-}"' in out


def test_export_only_where_declared():
    out = _emit_via_subprocess()
    assert 'export CLAUDE_CODE_RETRY_WATCHDOG="${CLAUDE_CODE_RETRY_WATCHDOG:-1}"' in out
    assert 'export API_TIMEOUT_MS="${API_TIMEOUT_MS:-1200000}"' in out
    # A non-exported var must not carry the export prefix.
    assert "export DEFAULT_INTERVAL=" not in out


def test_fixed_value_without_env():
    """_PROMOTE_EXCLUSION_LABELS has no env key → literal assignment, no expansion."""
    out = _emit_via_subprocess()
    assert '_PROMOTE_EXCLUSION_LABELS="triage experimental status:blocked autonomous:halt needs-human-review needs-reshape"' in out


def test_stdlib_fallback_matches_pyyaml():
    """The flow-mapping fallback parser emits the same lines as the PyYAML path."""
    mod = _load_module()
    with open(_CONFIG_YML, encoding="utf-8") as fh:
        text = fh.read()
    stdlib_out = mod.emit(mod._parse_flow_mappings(text))
    # PyYAML path (mod.load uses yaml when importable).
    pyyaml_out = mod.emit(mod.load(_CONFIG_YML))
    assert stdlib_out == pyyaml_out


def test_env_override_wins_when_evaluated():
    """Evaluating the emitted assignments in bash honours a set env var."""
    lines = _emit_via_subprocess()
    script = f'{lines}\necho "$DEFAULT_INTERVAL"'
    r = subprocess.run(
        ["bash", "-c", script],
        capture_output=True,
        text=True,
        env={**os.environ, "MAKATO_LOOP_INTERVAL": "42"},
        check=True,
    )
    assert r.stdout.strip() == "42"


def test_default_applies_when_env_unset():
    lines = _emit_via_subprocess()
    script = f'{lines}\necho "$DEFAULT_INTERVAL"'
    env = {k: v for k, v in os.environ.items() if k != "MAKATO_LOOP_INTERVAL"}
    r = subprocess.run(["bash", "-c", script], capture_output=True, text=True, env=env, check=True)
    assert r.stdout.strip() == "300"
