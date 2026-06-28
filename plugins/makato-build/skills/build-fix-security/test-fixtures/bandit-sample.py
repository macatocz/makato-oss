# Security-finding sample fixtures for build-fix-security
#
# Each function / block below intentionally violates one bandit rule so the
# sensor-fixer route can be exercised end-to-end. The expected branch is
# annotated next to each function name.
#
# Run bandit against this file from the repo root to reproduce the findings:
#   bandit -r plugins/makato-build/skills/build-fix-security/test-fixtures/bandit-sample.py
#
# See README.md in this directory for the full verification recipe including
# jq route-map checks.

from __future__ import annotations

import hashlib
import pickle
import random
import ssl
import subprocess
import yaml


# ---------------------------------------------------------------------------
# Branch 1 — Autofix: mechanical safe-function swap
# ---------------------------------------------------------------------------

def crypto_weak_hash(data: bytes) -> str:
    """Expected route: bandit:B303 → Branch 1 (Autofix, CWE-327).

    hashlib.md5 used for hashing — fix is to swap to hashlib.sha256.
    """
    return hashlib.md5(data).hexdigest()  # noqa: S324


def yaml_unsafe_load(stream: str) -> object:
    """Expected route: bandit:B506 (simple pattern) → Branch 1 (Autofix, CWE-502).

    yaml.load with default Loader — fix is to swap to yaml.safe_load.
    """
    return yaml.load(stream, Loader=yaml.Loader)  # noqa


def ssl_legacy_protocol() -> ssl.SSLContext:
    """Expected route: bandit:B502 → Branch 1 (Autofix, CWE-295).

    ssl.PROTOCOL_TLSv1 deprecated and insecure — fix is ssl.PROTOCOL_TLS_CLIENT.
    """
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLSv1)  # noqa
    return ctx


# ---------------------------------------------------------------------------
# Branch 2 — Refactor: structural fix required
# ---------------------------------------------------------------------------

def shell_injection(message: str) -> None:
    """Expected route: bandit:B602 → Branch 2 (Refactor, CWE-78).

    subprocess with shell=True and a variable argument — fix is args=[].
    """
    cmd = f"git commit -m '{message}'"
    subprocess.run(cmd, shell=True, check=True)  # noqa: S602,S603


# ---------------------------------------------------------------------------
# Branch 3 — Suppress: deterministic false-positive pattern
# ---------------------------------------------------------------------------

def test_assert_fp(value: int) -> None:
    """Expected route: bandit:B101 in test context → Branch 3 (Suppress).

    assert in a function whose name starts with test_ — canonical FP pattern.
    Note: bandit-sample.py is itself inside a test-fixtures/ directory so
    bandit treats this path as a test context. The fixture demonstrates
    the FP detection rule; the nosec annotation shows the expected output.
    """
    assert value > 0, "value must be positive"  # nosec B101: assert in test context — fixture file inside test-fixtures/


# ---------------------------------------------------------------------------
# Branch 4 — Carry-over: cannot safely auto-fix
# ---------------------------------------------------------------------------

def deserialize_untrusted(path: str) -> object:
    """Expected route: bandit:B301 → Branch 4 (Carry-over, CWE-502).

    pickle.load with an arbitrary file path — data origin unknown, structural.
    """
    with open(path, "rb") as fh:
        return pickle.load(fh)  # noqa: S301


def eval_dynamic(expression: str) -> object:
    """Expected route: bandit:B307 → Branch 4 (Carry-over, CWE-95).

    eval() with a dynamic string argument — always carry-over, never autofix.
    """
    return eval(expression)  # noqa: S307,PGH001
