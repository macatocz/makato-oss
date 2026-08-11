"""Regression test for #99 — ``specs/**/build.jsonl`` ships in-repo.

Issue #99 (and AC #2 of #58) asserts that the makato-build JSONL audit trail
must be reproducible from a fresh checkout, not just from the original
operator's working tree. Before the fix, ``.gitignore`` excluded ``specs/``
unconditionally, so every ``build.jsonl`` written by ``shared/build-log.sh``
was invisible to any reviewer who hadn't replayed the skill locally.

This test pins the negation pattern by running ``git check-ignore`` against
the actual repo-root ``.gitignore`` on three synthetic paths that mirror the
file types a build session produces:

* ``specs/<key>/build.jsonl`` MUST be tracked (the audit trail ships).
* ``specs/<key>/plan.md`` MUST stay ignored (personal scratch).
* ``specs/<key>/fixtures/anything.json`` MUST stay ignored (nested scratch).

Running ``git check-ignore`` directly is more durable than asserting on the
``.gitignore`` text — the patterns can be reshuffled or rewritten as long as
the *behaviour* this test pins still holds.
"""

from __future__ import annotations

import pathlib
import subprocess

REPO_ROOT = pathlib.Path(__file__).resolve().parents[1]


def _check_ignore(path: str) -> tuple[bool, str]:
    """Return ``(is_ignored, matched_rule)`` for ``path`` per repo-root ``.gitignore``.

    ``git check-ignore --no-index -v`` prints the *last* matching pattern even
    when that pattern is a negation (``!foo``). Exit code 0 means a pattern
    matched (positive *or* negative); exit 1 means no pattern matched at all
    (i.e. tracked by default). To know whether the path actually ships, we
    look at the matched rule itself: a leading ``!`` after the
    ``file:line:`` prefix is a re-include, so the path is NOT ignored.
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
    # Format: ``<source>:<line>:<pattern>\t<pathname>``. Split off the pattern.
    pattern = rule_line.split("\t", 1)[0].split(":", 2)[-1]
    is_negation = pattern.startswith("!")
    return (not is_negation), rule_line


def test_build_jsonl_is_tracked() -> None:
    """``specs/**/build.jsonl`` MUST be re-included by the negation rule."""
    ignored, rule = _check_ignore("specs/ISSUE-58-smoke/build.jsonl")
    assert not ignored, f"specs/<key>/build.jsonl should ship in-repo (#99); .gitignore matched rule: {rule}"


def test_build_jsonl_in_deep_subdir_is_tracked() -> None:
    """The negation must hold at any depth — ``find`` resolves nested folders."""
    ignored, rule = _check_ignore("specs/some-key/subdir/build.jsonl")
    assert not ignored, f"specs/**/build.jsonl must be tracked at any depth (#99); .gitignore matched rule: {rule}"


def test_plan_md_stays_ignored() -> None:
    """Personal artefacts under ``specs/`` must stay local (#99 § Proposed fix Option 1)."""
    ignored, rule = _check_ignore("specs/ISSUE-58-smoke/plan.md")
    assert ignored, "specs/<key>/plan.md must stay gitignored (#99); .gitignore did not match"
    assert "specs/" in rule, f"unexpected matching rule: {rule}"


def test_nested_fixture_stays_ignored() -> None:
    """Nested non-``build.jsonl`` files (fixtures, dumps, sketches) stay local."""
    ignored, rule = _check_ignore("specs/some-key/fixtures/anything.json")
    assert ignored, "Nested fixtures under specs/<key>/ must stay gitignored (#99); .gitignore did not match"
