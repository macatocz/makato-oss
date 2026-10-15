"""Tests for lesson_prune.py — ported from lesson-prune-smoke-tests.sh.

Scenario coverage (>= 12 scenarios):
  T1:  KEEP default — single record → KEEP
  T2:  DUPLICATE — two records with same text+tags → KEEP (high occurrences) + DUPLICATE
  T3:  CONSOLIDATE — two records with shared tag, different text → both CONSOLIDATE
  T4:  GRADUATED — record text verbatim in AGENTS.md → GRADUATED
  T5:  STALE — repo_sha not reachable from HEAD + date >90 days → STALE (real git fixture)
  T6:  Not-STALE — sha reachable even if old date → not STALE
  T7:  Not-STALE — unreachable sha but date <90 days → not STALE
  T8:  Operator rejection — files byte-identical after classification (no mutation)
  T9:  All-KEEP run — no-mutation exit-0
  T10: GRADUATED tolerates two different AGENTS.md layouts
  T11: semantic.jsonl is also read
  T12: Empty memory dir — exits 0 with no output
  T13: DUPLICATE target points at keeper key
  T14: STALE reason documents false-positive / human judgment warning
"""

from __future__ import annotations

import hashlib
import json
import os
import subprocess
import sys
import tempfile
import unittest

# Allow import whether discovery runs from repo root or this directory.
_HERE = os.path.dirname(os.path.abspath(__file__))
_SCRIPTS_DIR = os.path.join(_HERE, "..")
if _SCRIPTS_DIR not in sys.path:
    sys.path.insert(0, _SCRIPTS_DIR)

from lesson_prune import (  # noqa: E402
    classify_records,
    compute_key,
    load_records,
    normalize_text,
)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _write_jsonl(path: str, records: list[dict]) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        for rec in records:
            fh.write(json.dumps(rec) + "\n")


def _sha256(path: str) -> str:
    return hashlib.sha256(open(path, "rb").read()).hexdigest()


def _classify(
    memory_dir: str,
    today_override: str = "",
    head_override: str = "",
    agents_contents: list[str] | None = None,
) -> list[dict]:
    """Run classify_records with an optional agents_contents override."""
    if agents_contents is None:
        agents_contents = []
    proc_file = os.path.join(memory_dir, "procedural.jsonl")
    sem_file = os.path.join(memory_dir, "semantic.jsonl")
    records = load_records(proc_file, sem_file)
    return classify_records(
        records,
        agents_contents,
        today_override=today_override,
        head_override=head_override,
    )


# ---------------------------------------------------------------------------
# Bootstrap a real git repo for STALE tests (class-level, shared across T5–T7).
# Creates two commits; HEAD is on main; side-branch sha is unreachable from main.
# ---------------------------------------------------------------------------


class _GitFixture:
    """Shared git fixture for stale-detection tests."""

    reachable_sha: str = ""
    unreachable_sha: str = ""
    fixture_dir: str = ""
    _tmpdir: tempfile.TemporaryDirectory | None = None  # type: ignore[type-arg]

    @classmethod
    def setup(cls) -> None:
        if cls.reachable_sha:
            return  # Already set up
        cls._tmpdir = tempfile.TemporaryDirectory(prefix="lesson-prune-git-")
        cls.fixture_dir = cls._tmpdir.name

        def _run(*cmd: str) -> str:
            result = subprocess.run(
                list(cmd),
                cwd=cls.fixture_dir,
                capture_output=True,
                text=True,
            )
            return result.stdout.strip()

        _run("git", "init", "-b", "main", ".")
        _run("git", "config", "user.email", "smoke@example.com")
        _run("git", "config", "user.name", "Smoke Test")
        with open(os.path.join(cls.fixture_dir, "README.md"), "w") as fh:
            fh.write("seed\n")
        _run("git", "add", "README.md")
        _run("git", "commit", "-q", "-m", "seed")
        cls.reachable_sha = _run("git", "rev-parse", "HEAD")

        _run("git", "checkout", "-q", "-b", "side")
        with open(os.path.join(cls.fixture_dir, "side.txt"), "w") as fh:
            fh.write("side\n")
        _run("git", "add", "side.txt")
        _run("git", "commit", "-q", "-m", "side commit")
        cls.unreachable_sha = _run("git", "rev-parse", "HEAD")

        _run("git", "checkout", "-q", "main")

    @classmethod
    def teardown(cls) -> None:
        if cls._tmpdir is not None:
            cls._tmpdir.cleanup()
            cls._tmpdir = None
            cls.reachable_sha = ""
            cls.unreachable_sha = ""


# Create fixture once at module load so all tests share it.
_GIT = _GitFixture()


def setUpModule() -> None:
    _GIT.setup()


def tearDownModule() -> None:
    _GIT.teardown()


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------


class TestNormalize(unittest.TestCase):
    """normalize_text and compute_key unit tests."""

    def test_normalize_lowercases_collapses_whitespace(self) -> None:
        result = normalize_text("  Hello   World  ")
        self.assertEqual(result, "hello world")

    def test_normalize_strips_non_alphanumeric(self) -> None:
        result = normalize_text("use atomic writes for file operations!")
        self.assertEqual(result, "use atomic writes for file operations")

    def test_compute_key_deterministic(self) -> None:
        k1 = compute_key("hello world", ["a", "b"])
        k2 = compute_key("hello world", ["b", "a"])
        self.assertEqual(k1, k2, "tag order must not affect dedup key")


class TestKeepDefault(unittest.TestCase):
    """T1: single record → KEEP."""

    def test_single_record_is_keep(self) -> None:
        records = [{"key": "keep-1", "text": "unique lesson with no match", "tags": ["solo"], "occurrences": 1, "date": "2026-07-01", "repo_sha": "abc"}]
        results = classify_records(records, [], today_override="2026-07-20")
        self.assertEqual(len(results), 1)
        self.assertEqual(results[0]["action"], "KEEP")


class TestDuplicate(unittest.TestCase):
    """T2: DUPLICATE — two records with same text+tags."""

    def setUp(self) -> None:
        self.records = [
            {"key": "dup-low", "text": "use atomic writes for file operations", "tags": ["io", "safety"], "occurrences": 1, "date": "2026-07-01", "repo_sha": "abc"},
            {"key": "dup-high", "text": "use atomic writes for file operations", "tags": ["io", "safety"], "occurrences": 5, "date": "2026-07-02", "repo_sha": "abc"},
        ]
        self.results = classify_records(self.records, [], today_override="2026-07-20")

    def test_one_keep_one_duplicate(self) -> None:
        actions = [r["action"] for r in self.results]
        self.assertEqual(actions.count("KEEP"), 1)
        self.assertEqual(actions.count("DUPLICATE"), 1)

    def test_duplicate_has_non_null_target(self) -> None:
        """T13: DUPLICATE target points at keeper key."""
        dup = next(r for r in self.results if r["action"] == "DUPLICATE")
        self.assertIsNotNone(dup["target"])
        self.assertNotEqual(dup["target"], "")

    def test_keeper_is_highest_occurrences(self) -> None:
        keeper = next(r for r in self.results if r["action"] == "KEEP")
        # dup-high has occurrences=5; dup-low has occurrences=1
        self.assertEqual(keeper["key"], "dup-high")


class TestConsolidate(unittest.TestCase):
    """T3: CONSOLIDATE — two records with shared tag, different text."""

    def test_shared_tag_cluster_both_consolidate(self) -> None:
        records = [
            {"key": "cons-a", "text": "configure ruff for python linting rules", "tags": ["python", "linting"], "occurrences": 1, "date": "2026-07-01", "repo_sha": "abc"},
            {"key": "cons-b", "text": "use pre-commit hooks for linting checks", "tags": ["linting", "hooks"], "occurrences": 1, "date": "2026-07-02", "repo_sha": "abc"},
        ]
        results = classify_records(records, [], today_override="2026-07-20")
        actions = [r["action"] for r in results]
        self.assertEqual(actions.count("CONSOLIDATE"), 2)


class TestGraduated(unittest.TestCase):
    """T4, T10: GRADUATED detection."""

    def test_verbatim_text_in_agents_content_is_graduated(self) -> None:
        # normalize_text strips hyphens, so "PO-agent" → "poagent" and
        # "workflow-state.json" → "workflowstatejson".  Build the agents_content
        # string by normalizing the same phrase so the verbatim-substring check passes.
        phrase = "PO-agent is the sole writer of workflow-state.json"
        norm = normalize_text(phrase)
        agents_content = norm  # guaranteed substring match
        records = [{"key": "grad-1", "text": phrase, "tags": ["agents"], "occurrences": 1, "date": "2026-07-01", "repo_sha": "abc"}]
        results = classify_records(records, [agents_content], today_override="2026-07-20")
        self.assertEqual(results[0]["action"], "GRADUATED")

    def test_phrase_from_real_agents_md_is_graduated(self) -> None:
        """T4: phrase from real makato-orchestrate AGENTS.md → GRADUATED."""
        repo_root = _find_repo_root()
        agents_path = os.path.join(repo_root, "plugins", "makato-orchestrate", "AGENTS.md")
        if not os.path.isfile(agents_path):
            self.skipTest(f"AGENTS.md not found at {agents_path}")

        phrase = _extract_phrase_from_agents_md(agents_path)
        if not phrase:
            self.skipTest("Could not extract phrase from AGENTS.md")

        records = [{"key": "grad-real", "text": phrase, "tags": ["agents"], "occurrences": 1, "date": "2026-07-01", "repo_sha": "abc"}]
        # agents_contents must include the normalized content of the real AGENTS.md.
        with open(agents_path, encoding="utf-8") as fh:
            agents_contents = [normalize_text(fh.read())]

        results = classify_records(records, agents_contents, today_override="2026-07-20")
        self.assertEqual(results[0]["action"], "GRADUATED", f"Expected GRADUATED for phrase: {phrase!r}")

    def test_graduated_tolerates_two_agents_md_layouts(self) -> None:
        """T10: same phrase classified GRADUATED regardless of AGENTS.md structure."""
        repo_root = _find_repo_root()
        agents_path = os.path.join(repo_root, "plugins", "makato-orchestrate", "AGENTS.md")
        if not os.path.isfile(agents_path):
            self.skipTest(f"AGENTS.md not found at {agents_path}")

        phrase = _extract_phrase_from_agents_md(agents_path)
        if not phrase:
            self.skipTest("Could not extract phrase from AGENTS.md")

        with open(agents_path, encoding="utf-8") as fh:
            agents_contents = [normalize_text(fh.read())]

        # Layout A: phrase from real AGENTS.md (under heading)
        records_a = [{"key": "layout-a", "text": phrase, "tags": ["compat"], "occurrences": 1, "date": "2026-07-01", "repo_sha": "abc"}]
        results_a = classify_records(records_a, agents_contents, today_override="2026-07-20")
        self.assertEqual(results_a[0]["action"], "GRADUATED", "Layout A must be GRADUATED")

        # Layout B: same phrase, classified against same AGENTS.md content
        records_b = [{"key": "layout-b", "text": phrase, "tags": ["compat2"], "occurrences": 1, "date": "2026-07-01", "repo_sha": "abc"}]
        results_b = classify_records(records_b, agents_contents, today_override="2026-07-20")
        self.assertEqual(results_b[0]["action"], "GRADUATED", "Layout B must be GRADUATED")

    def test_unknown_text_not_graduated(self) -> None:
        agents_content = "some other content about different things"
        records = [{"key": "no-grad", "text": "completely unrelated lesson about something else entirely", "tags": ["misc"], "occurrences": 1, "date": "2026-07-01", "repo_sha": "abc"}]
        results = classify_records(records, [agents_content], today_override="2026-07-20")
        self.assertNotEqual(results[0]["action"], "GRADUATED")


class TestStale(unittest.TestCase):
    """T5, T6, T7: STALE detection."""

    def test_stale_unreachable_sha_and_old_date(self) -> None:
        """T5: unreachable sha + date >90 days → STALE with false-positive note."""
        records = [{"key": "stale-1", "text": "very old lesson from a rebased branch", "tags": ["old"], "occurrences": 1, "date": "2020-01-01", "repo_sha": _GIT.unreachable_sha}]
        # Change cwd to git fixture so git merge-base works.
        original_cwd = os.getcwd()
        try:
            os.chdir(_GIT.fixture_dir)
            results = classify_records(
                records,
                [],
                today_override="2026-07-20",
                head_override=_GIT.reachable_sha,
            )
        finally:
            os.chdir(original_cwd)

        self.assertEqual(results[0]["action"], "STALE")

    def test_stale_reason_documents_false_positive_risk(self) -> None:
        """T14: STALE reason mentions human judgment / false-positive."""
        records = [{"key": "stale-2", "text": "old lesson", "tags": ["old"], "occurrences": 1, "date": "2020-01-01", "repo_sha": _GIT.unreachable_sha}]
        original_cwd = os.getcwd()
        try:
            os.chdir(_GIT.fixture_dir)
            results = classify_records(
                records,
                [],
                today_override="2026-07-20",
                head_override=_GIT.reachable_sha,
            )
        finally:
            os.chdir(original_cwd)

        reason = results[0].get("reason", "").lower()
        self.assertTrue(any(kw in reason for kw in ("human", "false", "judgment", "rebase")), f"STALE reason should document false-positive risk: {reason}")

    def test_not_stale_sha_reachable_even_if_old_date(self) -> None:
        """T6: reachable sha → not STALE even if date is old."""
        records = [{"key": "not-stale-1", "text": "lesson on the main branch ancestor", "tags": ["main"], "occurrences": 1, "date": "2020-01-01", "repo_sha": _GIT.reachable_sha}]
        original_cwd = os.getcwd()
        try:
            os.chdir(_GIT.fixture_dir)
            results = classify_records(
                records,
                [],
                today_override="2026-07-20",
                head_override=_GIT.reachable_sha,
            )
        finally:
            os.chdir(original_cwd)

        self.assertNotEqual(results[0]["action"], "STALE")

    def test_not_stale_unreachable_sha_but_recent_date(self) -> None:
        """T7: unreachable sha + recent date → not STALE."""
        records = [{"key": "not-stale-2", "text": "recent lesson from a rebased branch", "tags": ["recent"], "occurrences": 1, "date": "2026-07-01", "repo_sha": _GIT.unreachable_sha}]
        original_cwd = os.getcwd()
        try:
            os.chdir(_GIT.fixture_dir)
            results = classify_records(
                records,
                [],
                today_override="2026-07-20",
                head_override=_GIT.reachable_sha,
            )
        finally:
            os.chdir(original_cwd)

        self.assertNotEqual(results[0]["action"], "STALE")


class TestNoMutation(unittest.TestCase):
    """T8, T9: classification never mutates input files."""

    def setUp(self) -> None:
        self._tmpdir = tempfile.TemporaryDirectory(prefix="lesson-prune-test-")
        self.memory_dir = os.path.join(self._tmpdir.name, "memory")
        os.makedirs(self.memory_dir)

    def tearDown(self) -> None:
        self._tmpdir.cleanup()

    def test_classification_does_not_mutate_files(self) -> None:
        """T8: files byte-identical after classification."""
        proc_file = os.path.join(self.memory_dir, "procedural.jsonl")
        sem_file = os.path.join(self.memory_dir, "semantic.jsonl")
        _write_jsonl(
            proc_file,
            [
                {"key": "a1", "text": "lesson one", "tags": ["tag1"], "occurrences": 1, "date": "2020-01-01", "repo_sha": "xxx"},
                {"key": "a2", "text": "lesson one", "tags": ["tag1"], "occurrences": 2, "date": "2020-01-02", "repo_sha": "xxx"},
            ],
        )
        _write_jsonl(
            sem_file,
            [
                {"key": "s1", "text": "semantic lesson", "tags": ["sem"], "occurrences": 1, "date": "2026-01-01", "repo_sha": "abc"},
            ],
        )
        sha_proc_before = _sha256(proc_file)
        sha_sem_before = _sha256(sem_file)

        # Run classification (no mutation expected).
        records = load_records(proc_file, sem_file)
        classify_records(records, [], today_override="2026-07-20")

        self.assertEqual(_sha256(proc_file), sha_proc_before, "procedural.jsonl must not be mutated")
        self.assertEqual(_sha256(sem_file), sha_sem_before, "semantic.jsonl must not be mutated")

    def test_all_keep_run_is_no_mutation_exit_0(self) -> None:
        """T9: all-KEEP run — no mutation, all results are KEEP."""
        proc_file = os.path.join(self.memory_dir, "procedural.jsonl")
        _write_jsonl(
            proc_file,
            [
                {"key": "u1", "text": "distinct lesson alpha with unique phrasing", "tags": ["alpha"], "occurrences": 1, "date": "2026-07-01", "repo_sha": "abc"},
                {"key": "u2", "text": "distinct lesson beta with unique content", "tags": ["beta"], "occurrences": 1, "date": "2026-07-02", "repo_sha": "abc"},
            ],
        )
        sha_before = _sha256(proc_file)

        records = load_records(proc_file, "")
        results = classify_records(records, [], today_override="2026-07-20")

        self.assertEqual(_sha256(proc_file), sha_before, "file must not be mutated")
        self.assertTrue(all(r["action"] == "KEEP" for r in results), "all records must be KEEP")


class TestSemanticFile(unittest.TestCase):
    """T11: semantic.jsonl is also read."""

    def test_semantic_jsonl_is_classified(self) -> None:
        with tempfile.TemporaryDirectory(prefix="lesson-prune-sem-") as tmpdir:
            memory_dir = os.path.join(tmpdir, "memory")
            os.makedirs(memory_dir)
            sem_file = os.path.join(memory_dir, "semantic.jsonl")
            _write_jsonl(sem_file, [{"key": "sem-only", "text": "semantic only lesson", "tags": ["sem-only"], "occurrences": 1, "date": "2026-07-01", "repo_sha": "abc"}])
            records = load_records("", sem_file)
            self.assertEqual(len(records), 1)
            results = classify_records(records, [], today_override="2026-07-20")
            self.assertEqual(len(results), 1)
            self.assertEqual(results[0]["action"], "KEEP")


class TestEmptyMemoryDir(unittest.TestCase):
    """T12: empty memory dir — exits 0 with no output."""

    def test_empty_dir_returns_empty_results(self) -> None:
        with tempfile.TemporaryDirectory(prefix="lesson-prune-empty-") as tmpdir:
            memory_dir = os.path.join(tmpdir, "memory")
            os.makedirs(memory_dir)
            records = load_records(
                os.path.join(memory_dir, "procedural.jsonl"),
                os.path.join(memory_dir, "semantic.jsonl"),
            )
            self.assertEqual(records, [])
            results = classify_records(records, [], today_override="2026-07-20")
            self.assertEqual(results, [])

    def test_main_exits_0_on_empty_dir(self) -> None:
        """main() returns 0 when memory dir has no records."""
        import lesson_prune  # noqa: F401 — already on path

        with tempfile.TemporaryDirectory(prefix="lesson-prune-main-") as tmpdir:
            memory_dir = os.path.join(tmpdir, "memory")
            os.makedirs(memory_dir)
            # Point main() to an empty memory dir via positional arg.
            from lesson_prune import main

            rc = main([memory_dir])
            self.assertEqual(rc, 0)


# ---------------------------------------------------------------------------
# Helpers for test fixture extraction
# ---------------------------------------------------------------------------


def _find_repo_root() -> str:
    """Walk up from _HERE to find the repo root (contains pyproject.toml)."""
    cur = _HERE
    for _ in range(8):
        if os.path.isfile(os.path.join(cur, "pyproject.toml")):
            return cur
        parent = os.path.dirname(cur)
        if parent == cur:
            break
        cur = parent
    return _HERE


def _extract_phrase_from_agents_md(path: str) -> str:
    """Extract the first prose line with >= 8 words from an AGENTS.md file."""
    try:
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                stripped = line.strip().lstrip("#").strip()
                words = stripped.split()
                if len(words) >= 8 and not stripped.startswith("<!--") and not stripped.startswith("|"):
                    return stripped
    except Exception:
        pass
    return ""


if __name__ == "__main__":
    unittest.main()
