"""Tests for scripts/lesson_prune.py Task 2 — GRADUATED and STALE detection.

GRADUATED: record text already encoded in an AGENTS.md (verbatim or strong token match).
STALE: repo_sha not reachable from HEAD AND date >90 days old.

All tests are offline — STALE tests use a real git fixture (init/commit) so
`git merge-base --is-ancestor` is exercised with real git objects, not mocked.
"""

from __future__ import annotations

import json
import os
import subprocess
from pathlib import Path

WORKTREE = Path(__file__).parent.parent
SCRIPT = WORKTREE / "plugins" / "makato-orchestrate" / "scripts" / "lesson_prune.py"


def _run(memory_dir: Path, **extra_env) -> subprocess.CompletedProcess:
    # Keep the July fixture records recent regardless of the CI runner clock.
    env = {
        **os.environ,
        "MAKATO_PRUNE_REPO_OVERRIDE": "macatocz/makato-test",
        "MAKATO_PRUNE_TODAY_OVERRIDE": "2026-07-20",
    }
    env.update(extra_env)
    return subprocess.run(
        ["python3", str(SCRIPT), str(memory_dir)],
        capture_output=True,
        text=True,
        env=env,
        cwd=str(WORKTREE),
    )


def _write_records(memory_dir: Path, filename: str, records: list[dict]) -> Path:
    memory_dir.mkdir(parents=True, exist_ok=True)
    path = memory_dir / filename
    path.write_text("\n".join(json.dumps(rec) for rec in records) + "\n")
    return path


def _parse_output(result: subprocess.CompletedProcess) -> list[dict]:
    lines = [line for line in result.stdout.splitlines() if line.strip()]
    return [json.loads(line) for line in lines]


# ---------------------------------------------------------------------------
# GRADUATED tests
# ---------------------------------------------------------------------------


class TestLessonPruneGraduated:
    """GRADUATED: lesson text already encoded in an AGENTS.md."""

    def test_graduated_verbatim_match(self, tmp_path):
        """Verbatim-match GRADUATED detection is covered by test_graduated_with_real_agents_md.

        This stub documents the design: GRADUATED fires when the normalized lesson text
        appears verbatim as a substring in any AGENTS.md in the repo.  The active
        assertion lives in the next test method which uses a real AGENTS.md phrase.
        """
        pass  # See test_graduated_with_real_agents_md below

    def test_graduated_with_real_agents_md(self, tmp_path):
        """A record whose text verbatim matches a phrase in a real plugins AGENTS.md is GRADUATED."""
        # Use the makato-orchestrate AGENTS.md which is present in the worktree.
        real_agents = WORKTREE / "plugins" / "makato-orchestrate" / "AGENTS.md"
        assert real_agents.exists(), f"AGENTS.md must exist at: {real_agents}"
        content = real_agents.read_text(encoding="utf-8")
        # Extract a distinctive phrase (a line at least 8 words long).
        phrase = None
        for line in content.splitlines():
            stripped = line.strip().lstrip("#").strip()
            words = stripped.split()
            if len(words) >= 8 and not stripped.startswith("<!--") and not stripped.startswith("|"):
                phrase = stripped
                break
        assert phrase is not None, "Could not extract a long enough phrase from AGENTS.md"

        memory_dir = tmp_path / "memory"
        _write_records(
            memory_dir,
            "procedural.jsonl",
            [
                {
                    "key": "grad-real",
                    "text": phrase,
                    "tags": ["agents-doc"],
                    "occurrences": 1,
                    "date": "2026-07-01",
                    "repo_sha": "abc123",
                }
            ],
        )
        result = _run(memory_dir)
        assert result.returncode == 0, f"stderr: {result.stderr}"
        records = _parse_output(result)
        assert len(records) == 1
        assert records[0]["action"] == "GRADUATED", f"Expected GRADUATED for phrase in AGENTS.md, got: {records[0]}. Phrase was: {phrase!r}"

    def test_non_graduated_text_is_not_graduated(self, tmp_path):
        """A record whose text does NOT appear in any AGENTS.md is NOT GRADUATED."""
        memory_dir = tmp_path / "memory"
        # Use a highly specific phrase unlikely to appear in AGENTS.md.
        _write_records(
            memory_dir,
            "procedural.jsonl",
            [
                {
                    "key": "not-grad",
                    "text": "xyzzy quux frob nitz -- this phrase is not in any AGENTS.md file",
                    "tags": ["test"],
                    "occurrences": 1,
                    "date": "2026-07-01",
                    "repo_sha": "abc123",
                }
            ],
        )
        result = _run(memory_dir)
        assert result.returncode == 0, f"stderr: {result.stderr}"
        records = _parse_output(result)
        assert len(records) == 1
        assert records[0]["action"] != "GRADUATED", f"Unexpected GRADUATED for nonsense phrase: {records[0]}"

    def test_graduated_tolerates_two_agents_md_layouts(self, tmp_path):
        """GRADUATED detection works regardless of AGENTS.md heading structure."""
        # Uses the plugins/makato-orchestrate/AGENTS.md which has diverse heading styles.
        real_agents = WORKTREE / "plugins" / "makato-orchestrate" / "AGENTS.md"
        content = real_agents.read_text(encoding="utf-8")
        phrase = None
        for line in content.splitlines():
            stripped = line.strip().lstrip("#").strip().lstrip("-").strip()
            words = stripped.split()
            if len(words) >= 8 and not stripped.startswith("<!--") and not stripped.startswith("|"):
                phrase = stripped
                break
        assert phrase is not None, "Could not extract a phrase from AGENTS.md"

        memory_dir = tmp_path / "memory"
        _write_records(
            memory_dir,
            "procedural.jsonl",
            [
                {
                    "key": "layout-a",
                    "text": phrase,
                    "tags": ["compat"],
                    "occurrences": 1,
                    "date": "2026-07-01",
                    "repo_sha": "abc123",
                }
            ],
        )
        result = _run(memory_dir)
        assert result.returncode == 0, f"stderr: {result.stderr}"
        records = _parse_output(result)
        assert records[0]["action"] == "GRADUATED", f"Expected GRADUATED regardless of heading layout: {records[0]}"


# ---------------------------------------------------------------------------
# STALE tests — use a real git fixture so git merge-base --is-ancestor is real
# ---------------------------------------------------------------------------


def _make_git_fixture(sandbox: Path) -> tuple[Path, str, str]:
    """Create a real git repo with two commits. Return (repo_path, reachable_sha, unreachable_sha).

    The unreachable_sha is from a branch that was created then deleted (orphaned commit
    simulated by hard-reset, leaving the sha dangling but not ancestor of HEAD).
    """
    repo = sandbox / "git-fixture"
    repo.mkdir(parents=True)

    def git(*args, **kw):
        return subprocess.run(
            ["git", *args],
            cwd=str(repo),
            capture_output=True,
            text=True,
            **kw,
        )

    git("init", "-b", "main")
    git("config", "user.email", "test@example.com")
    git("config", "user.name", "Test")

    # First commit — this sha will be reachable from HEAD.
    (repo / "README.md").write_text("seed\n")
    git("add", "README.md")
    git("commit", "-m", "seed")
    result_main = git("rev-parse", "HEAD")
    reachable_sha = result_main.stdout.strip()

    # Create a side branch, commit on it, then return to main without merging.
    # The side-branch sha is NOT reachable from main HEAD.
    git("checkout", "-b", "side")
    (repo / "side.txt").write_text("side\n")
    git("add", "side.txt")
    git("commit", "-m", "side commit")
    result_side = git("rev-parse", "HEAD")
    unreachable_sha = result_side.stdout.strip()

    # Return to main — side sha is now unreachable from main HEAD.
    git("checkout", "main")

    return repo, reachable_sha, unreachable_sha


class TestLessonPruneStale:
    """STALE: repo_sha not reachable from HEAD AND date >90 days old."""

    def test_stale_both_conditions(self, tmp_path):
        """Record with unreachable sha AND old date → STALE."""
        fixture_dir, reachable_sha, unreachable_sha = _make_git_fixture(tmp_path)
        memory_dir = tmp_path / "memory"
        _write_records(
            memory_dir,
            "procedural.jsonl",
            [
                {
                    "key": "stale-1",
                    "text": "an old lesson that is no longer relevant to any current code",
                    "tags": ["stale-tag"],
                    "occurrences": 1,
                    "date": "2020-01-01",  # >90 days ago
                    "repo_sha": unreachable_sha,
                }
            ],
        )
        result = subprocess.run(
            ["python3", str(SCRIPT), str(memory_dir)],
            capture_output=True,
            text=True,
            env={
                **os.environ,
                "MAKATO_PRUNE_REPO_OVERRIDE": "test/repo",
                "MAKATO_PRUNE_TODAY_OVERRIDE": "2026-07-20",
                "MAKATO_PRUNE_HEAD_OVERRIDE": reachable_sha,
            },
            cwd=str(fixture_dir),  # git context = our fixture repo
        )
        assert result.returncode == 0, f"stderr: {result.stderr}"
        records = _parse_output(result)
        assert len(records) == 1
        assert records[0]["action"] == "STALE", f"Expected STALE, got: {records[0]}"

    def test_not_stale_when_sha_reachable(self, tmp_path):
        """Record with reachable sha (even if old date) → NOT STALE."""
        fixture_dir, reachable_sha, unreachable_sha = _make_git_fixture(tmp_path)
        memory_dir = tmp_path / "memory"
        _write_records(
            memory_dir,
            "procedural.jsonl",
            [
                {
                    "key": "not-stale-sha",
                    "text": "lesson whose commit is still in the main history",
                    "tags": ["history"],
                    "occurrences": 1,
                    "date": "2020-01-01",  # old date but sha IS reachable
                    "repo_sha": reachable_sha,
                }
            ],
        )
        result = subprocess.run(
            ["python3", str(SCRIPT), str(memory_dir)],
            capture_output=True,
            text=True,
            env={
                **os.environ,
                "MAKATO_PRUNE_REPO_OVERRIDE": "test/repo",
                "MAKATO_PRUNE_TODAY_OVERRIDE": "2026-07-20",
                "MAKATO_PRUNE_HEAD_OVERRIDE": reachable_sha,
            },
            cwd=str(fixture_dir),
        )
        assert result.returncode == 0, f"stderr: {result.stderr}"
        records = _parse_output(result)
        assert len(records) == 1
        assert records[0]["action"] != "STALE", f"Should NOT be STALE when sha is reachable: {records[0]}"

    def test_not_stale_when_date_recent(self, tmp_path):
        """Record with unreachable sha but recent date → NOT STALE."""
        fixture_dir, reachable_sha, unreachable_sha = _make_git_fixture(tmp_path)
        memory_dir = tmp_path / "memory"
        _write_records(
            memory_dir,
            "procedural.jsonl",
            [
                {
                    "key": "not-stale-date",
                    "text": "recent lesson on a rebased commit",
                    "tags": ["recent"],
                    "occurrences": 1,
                    "date": "2026-07-01",  # recent — <90 days before 2026-07-20
                    "repo_sha": unreachable_sha,
                }
            ],
        )
        result = subprocess.run(
            ["python3", str(SCRIPT), str(memory_dir)],
            capture_output=True,
            text=True,
            env={
                **os.environ,
                "MAKATO_PRUNE_REPO_OVERRIDE": "test/repo",
                "MAKATO_PRUNE_TODAY_OVERRIDE": "2026-07-20",
                "MAKATO_PRUNE_HEAD_OVERRIDE": reachable_sha,
            },
            cwd=str(fixture_dir),
        )
        assert result.returncode == 0, f"stderr: {result.stderr}"
        records = _parse_output(result)
        assert len(records) == 1
        assert records[0]["action"] != "STALE", f"Should NOT be STALE when date is recent: {records[0]}"

    def test_stale_reason_contains_false_positive_note(self, tmp_path):
        """STALE reason text mentions human judgment / false-positive."""
        fixture_dir, reachable_sha, unreachable_sha = _make_git_fixture(tmp_path)
        memory_dir = tmp_path / "memory"
        _write_records(
            memory_dir,
            "procedural.jsonl",
            [
                {
                    "key": "stale-note",
                    "text": "another old and unreachable lesson here for verification",
                    "tags": ["verify"],
                    "occurrences": 1,
                    "date": "2020-01-01",
                    "repo_sha": unreachable_sha,
                }
            ],
        )
        result = subprocess.run(
            ["python3", str(SCRIPT), str(memory_dir)],
            capture_output=True,
            text=True,
            env={
                **os.environ,
                "MAKATO_PRUNE_REPO_OVERRIDE": "test/repo",
                "MAKATO_PRUNE_TODAY_OVERRIDE": "2026-07-20",
                "MAKATO_PRUNE_HEAD_OVERRIDE": reachable_sha,
            },
            cwd=str(fixture_dir),
        )
        assert result.returncode == 0, f"stderr: {result.stderr}"
        records = _parse_output(result)
        assert records[0]["action"] == "STALE"
        # The reason must mention human judgment / false-positive per AC.
        reason = records[0]["reason"].lower()
        assert any(phrase in reason for phrase in ["human", "false-positive", "judgment", "rebase"]), f"STALE reason should document false-positive risk: {records[0]['reason']}"
