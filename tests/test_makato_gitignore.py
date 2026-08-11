"""Tests for T3: .gitignore negation for the committed memory store (AC-5).

The .makato/memory/semantic.jsonl and .makato/memory/procedural.jsonl files
must be committed (not ignored). All other *.jsonl files under .makato/ must
remain gitignored.
"""

from __future__ import annotations

import pathlib
import subprocess

REPO_ROOT = pathlib.Path(__file__).resolve().parents[1]


def _check_ignore(path: str) -> tuple[bool, str]:
    """Return (is_ignored, matched_rule) for path per repo-root .gitignore.

    Uses the same helper contract as test_specs_gitignore.py.
    A leading '!' in the matched pattern means it's a re-include (not ignored).
    """
    result = subprocess.run(
        ["git", "check-ignore", "--no-index", "-v", path],
        cwd=REPO_ROOT,
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode not in (0, 1):
        raise RuntimeError(f"git check-ignore failed for {path!r}: rc={result.returncode} stderr={result.stderr!r}")
    if result.returncode == 1:
        # No pattern matched — path is not ignored by any rule.
        return False, ""
    rule_line = result.stdout.strip()
    # Format: <source>:<line>:<pattern>\t<pathname>. Split off the pattern.
    pattern = rule_line.split("\t", 1)[0].split(":", 2)[-1]
    is_negation = pattern.startswith("!")
    return (not is_negation), rule_line


def test_semantic_jsonl_is_committed() -> None:
    """.makato/memory/semantic.jsonl must NOT be ignored (AC-5)."""
    ignored, rule = _check_ignore(".makato/memory/semantic.jsonl")
    assert not ignored, f".makato/memory/semantic.jsonl should be committed, not ignored; .gitignore matched rule: {rule}"


def test_procedural_jsonl_is_committed() -> None:
    """.makato/memory/procedural.jsonl must NOT be ignored (AC-5)."""
    ignored, rule = _check_ignore(".makato/memory/procedural.jsonl")
    assert not ignored, f".makato/memory/procedural.jsonl should be committed, not ignored; .gitignore matched rule: {rule}"


def test_episodic_jsonl_stays_ignored() -> None:
    """Episodic *.jsonl files under .makato/ must stay gitignored (AC-5)."""
    ignored, _rule = _check_ignore(".makato/memory/episode-2026-07-19.jsonl")
    assert ignored, "Episodic .makato/memory/*.jsonl files must stay gitignored (AC-5); got not-ignored"


def test_other_makato_jsonl_stays_ignored() -> None:
    """Any non-committed .makato/**/*.jsonl must stay gitignored."""
    ignored, _rule = _check_ignore(".makato/cache/something.jsonl")
    assert ignored, "Non-committed .makato/**/*.jsonl must stay gitignored; got not-ignored"
