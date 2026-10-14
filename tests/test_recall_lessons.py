"""Tests for T4–T6: recall-lessons bundle/label filtering and committed store reads (AC-1–AC-4).

These tests exercise `recall-lessons` via the shell script directly.
They are integration tests that require the full `workflow-state.sh` + `jq` toolchain.
"""

from __future__ import annotations

import json
import os
import subprocess
from pathlib import Path

WORKTREE = Path(__file__).parent.parent
WS = WORKTREE / "plugins" / "makato-orchestrate" / "shared" / "workflow-state.sh"
REPO_ROOT = WORKTREE  # workflow-state.sh uses git --git-common-dir which resolves to main


def _run_ws(*args: str, env: dict | None = None, cwd: str | None = None) -> subprocess.CompletedProcess:
    merged = {**os.environ}
    if env:
        merged.update(env)
    return subprocess.run(
        [str(WS), *args],
        cwd=cwd or str(WORKTREE),
        capture_output=True,
        text=True,
        env=merged,
    )


class TestRecallLessonsBackwardCompat:
    """AC-2: 2-arg call recall-lessons <REPO> [N] still works unchanged."""

    def test_two_arg_call_returns_empty_json_array_for_unknown_repo(self, tmp_path):
        # Ensure at least an empty result for a brand-new repo slug
        result = _run_ws("recall-lessons", "macatocz/nonexistent-470-test-repo", "3")
        assert result.returncode == 0, f"stderr: {result.stderr}"
        data = json.loads(result.stdout)
        assert isinstance(data, list)

    def test_two_arg_call_returns_lessons_for_known_repo(self, tmp_path):
        """2-arg recall with no bundle/label filters returns all lessons for the repo."""
        # This test uses the live specs/ folder's workflow-state files — it just
        # confirms the call signature still works without errors.
        result = _run_ws("recall-lessons", "macatocz/makato", "3")
        assert result.returncode == 0, f"rc={result.returncode} stderr={result.stderr}"
        data = json.loads(result.stdout)
        assert isinstance(data, list)


class TestRecallLessonsNoMemoryStore:
    """AC-3: Recall on a repo with no .makato/memory/ returns empty set."""

    def test_missing_memory_store_returns_empty(self, tmp_path):
        """When .makato/memory/ does not exist, recall exits 0 with [].

        MAKATO_MEMORY_ROOT is set to a temp dir that has no .makato/memory/ inside it.
        """
        # tmp_path has no .makato/memory/ subdirectory — AC-3 scenario.
        result = _run_ws(
            "recall-lessons",
            "macatocz/nonexistent-470-repo",
            "3",
            env={"MAKATO_MEMORY_ROOT": str(tmp_path)},
        )
        assert result.returncode == 0, f"stderr: {result.stderr}"
        data = json.loads(result.stdout)
        assert data == [], f"Expected empty list, got {data}"


class TestRecallLessonsMalformedLine:
    """AC-4: Malformed JSONL line is skipped, not fatal."""

    def test_malformed_line_skipped(self, tmp_path):
        """A malformed line between two valid records is silently skipped."""
        # MAKATO_MEMORY_ROOT is the repo-root equivalent; store is at .makato/memory/
        memory_dir = tmp_path / ".makato" / "memory"
        memory_dir.mkdir(parents=True)
        # Write a procedural.jsonl with good-bad-good structure
        proc = memory_dir / "procedural.jsonl"
        good1 = json.dumps(
            {
                "repo": "macatocz/test-470-malformed",
                "bundle": "python",
                "label": "testing",
                "scope": "generalizable",
                "occurrences": 2,
                "ts": "2026-07-19T10:00:00.000Z",
                "description": "Good lesson 1",
            }
        )
        bad = "{ this is not valid json !!!"
        good2 = json.dumps(
            {
                "repo": "macatocz/test-470-malformed",
                "bundle": "python",
                "label": "testing",
                "scope": "generalizable",
                "occurrences": 1,
                "ts": "2026-07-18T10:00:00.000Z",
                "description": "Good lesson 2",
            }
        )
        proc.write_text(f"{good1}\n{bad}\n{good2}\n")

        result = _run_ws(
            "recall-lessons",
            "macatocz/test-470-malformed",
            "5",
            env={"MAKATO_MEMORY_ROOT": str(tmp_path)},
        )
        assert result.returncode == 0, f"stderr: {result.stderr}"
        data = json.loads(result.stdout)
        descriptions = [d["description"] for d in data]
        assert "Good lesson 1" in descriptions, f"Good lesson 1 missing: {data}"
        assert "Good lesson 2" in descriptions, f"Good lesson 2 missing: {data}"
        assert len(data) == 2, f"Expected 2 lessons (malformed skipped), got {len(data)}: {data}"


class TestRecallLessonsBundleFilter:
    """AC-1: Recall filtered to a bundle returns only matching lessons, correctly ordered."""

    def test_bundle_filter_excludes_non_matching(self, tmp_path):
        """Filtering to bundle=python must exclude infra-only lessons."""
        memory_dir = tmp_path / ".makato" / "memory"
        memory_dir.mkdir(parents=True)
        semantic = memory_dir / "semantic.jsonl"
        python_lesson = json.dumps(
            {
                "repo": "macatocz/makato",
                "bundle": "python",
                "scope": "generalizable",
                "occurrences": 3,
                "ts": "2026-07-19T12:00:00.000Z",
                "description": "Python-tagged lesson",
            }
        )
        infra_lesson = json.dumps(
            {
                "repo": "macatocz/makato",
                "bundle": "infra",
                "scope": "local",
                "occurrences": 5,
                "ts": "2026-07-19T13:00:00.000Z",
                "description": "Infra-only lesson",
            }
        )
        semantic.write_text(f"{python_lesson}\n{infra_lesson}\n")

        result = _run_ws(
            "recall-lessons",
            "macatocz/makato",
            "5",
            "--bundles",
            "python",
            env={"MAKATO_MEMORY_ROOT": str(tmp_path)},
        )
        assert result.returncode == 0, f"stderr: {result.stderr}"
        data = json.loads(result.stdout)
        descriptions = [d["description"] for d in data]
        assert "Python-tagged lesson" in descriptions
        assert "Infra-only lesson" not in descriptions, f"Infra lesson should be excluded: {data}"

    def test_bundle_filter_order_scope_then_occurrences_then_recency(self, tmp_path):
        """Order: scope asc (general before specific), then occurrences DESC, then ts DESC."""
        memory_dir = tmp_path / ".makato" / "memory"
        memory_dir.mkdir(parents=True)
        proc = memory_dir / "procedural.jsonl"
        lessons = [
            # scope=specific, high occurrences — should come AFTER general
            {
                "repo": "macatocz/makato",
                "bundle": "python",
                "scope": "local",
                "occurrences": 10,
                "ts": "2026-07-19T10:00:00.000Z",
                "description": "Specific-high-occ",
            },
            # scope=general, lower occurrences — should come FIRST (general < specific)
            {
                "repo": "macatocz/makato",
                "bundle": "python",
                "scope": "generalizable",
                "occurrences": 2,
                "ts": "2026-07-18T10:00:00.000Z",
                "description": "General-low-occ",
            },
            # scope=general, higher occurrences — should come before General-low-occ
            {
                "repo": "macatocz/makato",
                "bundle": "python",
                "scope": "generalizable",
                "occurrences": 5,
                "ts": "2026-07-17T10:00:00.000Z",
                "description": "General-high-occ",
            },
        ]
        proc.write_text("\n".join(json.dumps(item) for item in lessons) + "\n")

        result = _run_ws(
            "recall-lessons",
            "macatocz/makato",
            "5",
            "--bundles",
            "python",
            env={"MAKATO_MEMORY_ROOT": str(tmp_path)},
        )
        assert result.returncode == 0, f"stderr: {result.stderr}"
        data = json.loads(result.stdout)
        assert len(data) == 3, f"Expected 3 results, got {len(data)}: {data}"
        # generalizable scope lessons must precede local
        general_indices = [i for i, d in enumerate(data) if d["scope"] == "generalizable"]
        specific_indices = [i for i, d in enumerate(data) if d["scope"] == "local"]
        assert max(general_indices) < min(specific_indices), f"generalizable lessons must all precede local: {[d['description'] for d in data]}"
        # Within generalizable: higher occurrences first
        general_lessons = [d for d in data if d["scope"] == "generalizable"]
        assert general_lessons[0]["occurrences"] >= general_lessons[1]["occurrences"], f"Within general scope, occurrences not DESC: {general_lessons}"

    def test_no_bundle_filter_returns_all_bundles(self, tmp_path):
        """2-arg call (no bundle filter) returns lessons from all bundles (AC-2)."""
        memory_dir = tmp_path / ".makato" / "memory"
        memory_dir.mkdir(parents=True)
        semantic = memory_dir / "semantic.jsonl"
        lessons = [
            {
                "repo": "macatocz/makato",
                "bundle": "python",
                "scope": "generalizable",
                "occurrences": 1,
                "ts": "2026-07-19T10:00:00.000Z",
                "description": "Python lesson",
            },
            {
                "repo": "macatocz/makato",
                "bundle": "infra",
                "scope": "generalizable",
                "occurrences": 1,
                "ts": "2026-07-19T09:00:00.000Z",
                "description": "Infra lesson",
            },
        ]
        semantic.write_text("\n".join(json.dumps(item) for item in lessons) + "\n")

        # 2-arg call — no bundle/label args
        result = _run_ws(
            "recall-lessons",
            "macatocz/makato",
            "5",
            env={"MAKATO_MEMORY_ROOT": str(tmp_path)},
        )
        assert result.returncode == 0, f"stderr: {result.stderr}"
        data = json.loads(result.stdout)
        descriptions = [d["description"] for d in data]
        assert "Python lesson" in descriptions
        assert "Infra lesson" in descriptions

    def test_label_filter(self, tmp_path):
        """Filtering by label returns only matching lessons."""
        memory_dir = tmp_path / ".makato" / "memory"
        memory_dir.mkdir(parents=True)
        proc = memory_dir / "procedural.jsonl"
        lessons = [
            {
                "repo": "macatocz/makato",
                "bundle": "python",
                "label": "testing",
                "scope": "generalizable",
                "occurrences": 1,
                "ts": "2026-07-19T10:00:00.000Z",
                "description": "Testing-labeled lesson",
            },
            {
                "repo": "macatocz/makato",
                "bundle": "python",
                "label": "deploy",
                "scope": "generalizable",
                "occurrences": 1,
                "ts": "2026-07-19T09:00:00.000Z",
                "description": "Deploy-labeled lesson",
            },
        ]
        proc.write_text("\n".join(json.dumps(item) for item in lessons) + "\n")

        result = _run_ws(
            "recall-lessons",
            "macatocz/makato",
            "5",
            "--labels",
            "testing",
            env={"MAKATO_MEMORY_ROOT": str(tmp_path)},
        )
        assert result.returncode == 0, f"stderr: {result.stderr}"
        data = json.loads(result.stdout)
        descriptions = [d["description"] for d in data]
        assert "Testing-labeled lesson" in descriptions
        assert "Deploy-labeled lesson" not in descriptions, f"Deploy lesson should be filtered: {data}"


class TestRecallLessonsCommittedStore:
    """T5: recall reads from MAKATO_MEMORY_ROOT committed store."""

    def test_reads_from_memory_root_semantic(self, tmp_path):
        """Lessons in semantic.jsonl under MAKATO_MEMORY_ROOT are returned."""
        memory_dir = tmp_path / ".makato" / "memory"
        memory_dir.mkdir(parents=True)
        lesson = {
            "repo": "macatocz/makato",
            "bundle": "python",
            "scope": "generalizable",
            "occurrences": 1,
            "ts": "2026-07-19T10:00:00.000Z",
            "description": "From semantic store",
        }
        (memory_dir / "semantic.jsonl").write_text(json.dumps(lesson) + "\n")

        result = _run_ws(
            "recall-lessons",
            "macatocz/makato",
            "5",
            env={"MAKATO_MEMORY_ROOT": str(tmp_path)},
        )
        assert result.returncode == 0, f"stderr: {result.stderr}"
        data = json.loads(result.stdout)
        assert any(d["description"] == "From semantic store" for d in data), f"semantic store lesson not found: {data}"

    def test_reads_from_memory_root_procedural(self, tmp_path):
        """Lessons in procedural.jsonl under MAKATO_MEMORY_ROOT are returned."""
        memory_dir = tmp_path / ".makato" / "memory"
        memory_dir.mkdir(parents=True)
        lesson = {
            "repo": "macatocz/makato",
            "bundle": "testing",
            "scope": "generalizable",
            "occurrences": 2,
            "ts": "2026-07-19T11:00:00.000Z",
            "description": "From procedural store",
        }
        (memory_dir / "procedural.jsonl").write_text(json.dumps(lesson) + "\n")

        result = _run_ws(
            "recall-lessons",
            "macatocz/makato",
            "5",
            env={"MAKATO_MEMORY_ROOT": str(tmp_path)},
        )
        assert result.returncode == 0, f"stderr: {result.stderr}"
        data = json.loads(result.stdout)
        assert any(d["description"] == "From procedural store" for d in data), f"procedural store lesson not found: {data}"


class TestRecallLessonsMetadataSources:
    """Captured tier stores remain visible through their persisted filter metadata."""

    def test_url_repo_argument_filters_procedural_and_semantic_sources(self, tmp_path):
        memory_dir = tmp_path / ".makato" / "memory"
        memory_dir.mkdir(parents=True)
        records = {
            "procedural.jsonl": {
                "repo": "macatocz/makato",
                "bundle": "shell",
                "label": "ops",
                "scope": "generalizable",
                "description": "Procedural captured lesson",
                "source_events": [{"bundle": "python", "label": "runtime"}],
            },
            "semantic.jsonl": {
                "repo": "macatocz/makato",
                "bundle": "go",
                "label": "ci",
                "scope": "generalizable",
                "description": "Semantic captured fact",
                "source_events": [{"bundle": "python", "label": "runtime"}],
            },
        }
        for filename, record in records.items():
            (memory_dir / filename).write_text(json.dumps(record) + "\n", encoding="utf-8")

        for repo, filter_name, filter_value in (
            ("https://github.com/macatocz/makato.git", "--bundles", "python"),
            ("git@github.com:macatocz/makato.git", "--labels", "runtime"),
        ):
            result = _run_ws(
                "recall-lessons",
                repo,
                "5",
                filter_name,
                filter_value,
                env={"MAKATO_MEMORY_ROOT": str(tmp_path)},
            )

            assert result.returncode == 0, result.stderr
            assert {record["description"] for record in json.loads(result.stdout)} == {
                "Procedural captured lesson",
                "Semantic captured fact",
            }
