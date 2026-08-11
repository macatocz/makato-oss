"""Tests for scripts/promote-lessons.sh (AC-1 through AC-5).

Tests call the shell script via subprocess with a temp directory as SPECS_DIR
and a temp file as MEMORY_FILE. Fully offline — no git remote access required.

Schema note (confirmed from workflow-state.sh):
  workflow-state-N.json lessons_learned[] entries use the field `description`
  for the lesson body (schema: {ts, cycle, trigger, description, files_affected}).
  change-lessons.jsonl entries use the field `text` (change-lane format).
  Both are stored under the `text` key in the output procedural.jsonl record.
"""

from __future__ import annotations

import json
import os
import subprocess
from pathlib import Path

REPO_ROOT = Path(__file__).parent.parent
SCRIPT = REPO_ROOT / "plugins" / "makato-orchestrate" / "scripts" / "promote-lessons.sh"


def _run(
    issue_number: str,
    specs_dir: str,
    memory_file: str,
    semantic_memory_file: str | None = None,
    **kwargs,
) -> subprocess.CompletedProcess:
    """Invoke promote-lessons.sh with three (or four) positional arguments."""
    env = {**os.environ}
    env["MAKATO_PROMOTE_REPO_OVERRIDE"] = "macatocz/makato-test"
    env.update(kwargs.get("extra_env", {}))
    argv = ["bash", str(SCRIPT), issue_number, specs_dir, memory_file]
    if semantic_memory_file is not None:
        argv.append(semantic_memory_file)
    return subprocess.run(
        argv,
        capture_output=True,
        text=True,
        env=env,
        cwd=str(REPO_ROOT),
    )


def _make_workflow_state(specs_dir: Path, issue_number: int, lessons: list[dict]) -> Path:
    """Create a minimal workflow-state-<N>.json in a matching spec folder.

    Lessons use the workflow-state schema: {ts, cycle, trigger, description, files_affected}.
    The `scope` field is optional (change-lane only); absent scope means skip.
    """
    folder = specs_dir / f"123-example-{issue_number}"
    folder.mkdir(parents=True, exist_ok=True)
    ws = folder / f"workflow-state-{issue_number}.json"
    ws.write_text(json.dumps({"lessons_learned": lessons}))
    return ws


def _make_change_lessons(specs_dir: Path, issue_number: int, records: list[dict]) -> Path:
    """Create a change-lessons.jsonl in the matching spec folder.

    Records use the change-lane format: {text, tags, scope, ...}.
    """
    folder = specs_dir / f"123-example-{issue_number}"
    folder.mkdir(parents=True, exist_ok=True)
    cl = folder / "change-lessons.jsonl"
    cl.write_text("\n".join(json.dumps(r) for r in records) + "\n")
    return cl


class TestPromoteLessonsGeneralizable:
    """AC-1, AC-2: generalizable records are promoted to MEMORY_FILE."""

    def test_generalizable_record_is_promoted(self, tmp_path):
        """A workflow-state lesson with scope=generalizable is written to MEMORY_FILE.

        workflow-state schema uses `description` for the body; output record uses `text`.
        """
        specs_dir = tmp_path / "specs"
        memory_file = tmp_path / "procedural.jsonl"
        memory_file.touch()

        # workflow-state schema: {ts, cycle, trigger, description, files_affected}
        # scope is added by change-lane; for workflow-state records with scope it's
        # present when the po-agent explicitly records it.
        lesson = {
            "ts": "2026-07-20T10:00:00Z",
            "cycle": 1,
            "trigger": "merge",
            "description": "Always run tests before merging",
            "files_affected": [],
            "scope": "generalizable",
        }
        _make_workflow_state(specs_dir, 471, [lesson])

        result = _run("471", str(specs_dir), str(memory_file))
        assert result.returncode == 0, f"stderr: {result.stderr}"

        lines = [line for line in memory_file.read_text().splitlines() if line.strip()]
        assert len(lines) == 1, f"Expected 1 line, got {len(lines)}: {lines}"
        record = json.loads(lines[0])
        # Body is stored under `text` canonical key (per #470)
        assert record["text"] == "Always run tests before merging"
        assert record["scope"] == "generalizable"
        assert record["tier"] == "procedural"
        assert record["occurrences"] == 1
        assert record["source_issue"] == 471

    def test_promoted_record_has_repo_sha_and_date(self, tmp_path):
        """AC-4: promoted record includes repo_sha (short) and date (YYYY-MM-DD)."""
        import re

        specs_dir = tmp_path / "specs"
        memory_file = tmp_path / "procedural.jsonl"
        memory_file.touch()

        lesson = {
            "ts": "2026-07-20T10:00:00Z",
            "cycle": 1,
            "trigger": "merge",
            "description": "Use atomic writes",
            "files_affected": [],
            "scope": "generalizable",
        }
        _make_workflow_state(specs_dir, 471, [lesson])

        result = _run("471", str(specs_dir), str(memory_file))
        assert result.returncode == 0, f"stderr: {result.stderr}"

        lines = [line for line in memory_file.read_text().splitlines() if line.strip()]
        assert len(lines) == 1
        record = json.loads(lines[0])

        assert "repo_sha" in record, "Missing repo_sha field"
        assert len(record["repo_sha"]) >= 7, f"repo_sha too short: {record['repo_sha']}"

        assert "date" in record, "Missing date field"
        assert re.match(r"^\d{4}-\d{2}-\d{2}$", record["date"]), f"Bad date format: {record['date']}"


class TestPromoteLessonsLocalSkipped:
    """AC-2: records with scope != 'generalizable' are not promoted."""

    def test_local_scope_is_skipped(self, tmp_path):
        """A workflow-state lesson with scope=local is not written to MEMORY_FILE."""
        specs_dir = tmp_path / "specs"
        memory_file = tmp_path / "procedural.jsonl"
        memory_file.touch()

        lesson = {
            "ts": "2026-07-20T10:00:00Z",
            "cycle": 1,
            "trigger": "ci_failure",
            "description": "This is a local note",
            "files_affected": [],
            "scope": "local",
        }
        _make_workflow_state(specs_dir, 471, [lesson])

        result = _run("471", str(specs_dir), str(memory_file))
        assert result.returncode == 0, f"stderr: {result.stderr}"

        lines = [line for line in memory_file.read_text().splitlines() if line.strip()]
        assert len(lines) == 0, f"Expected no lines, got: {lines}"

    def test_missing_scope_is_skipped(self, tmp_path):
        """A workflow-state lesson with no scope field is not promoted."""
        specs_dir = tmp_path / "specs"
        memory_file = tmp_path / "procedural.jsonl"
        memory_file.touch()

        # Standard workflow-state schema — no scope field (common case)
        lesson = {
            "ts": "2026-07-20T10:00:00Z",
            "cycle": 1,
            "trigger": "halt",
            "description": "No scope field here",
            "files_affected": [],
        }
        _make_workflow_state(specs_dir, 471, [lesson])

        result = _run("471", str(specs_dir), str(memory_file))
        assert result.returncode == 0, f"stderr: {result.stderr}"

        lines = [line for line in memory_file.read_text().splitlines() if line.strip()]
        assert len(lines) == 0, f"Expected no lines, got: {lines}"


class TestPromoteLessonsDuplicateBumpsOccurrences:
    """AC-3: when the same lesson is promoted twice, occurrences is incremented."""

    def test_duplicate_bumps_occurrences(self, tmp_path):
        """Promoting the same generalizable lesson twice results in occurrences=2."""
        specs_dir = tmp_path / "specs"
        memory_file = tmp_path / "procedural.jsonl"
        memory_file.touch()

        lesson = {
            "ts": "2026-07-20T10:00:00Z",
            "cycle": 1,
            "trigger": "merge",
            "description": "Always write tests first",
            "files_affected": [],
            "scope": "generalizable",
            "tags": ["testing", "tdd"],
        }
        _make_workflow_state(specs_dir, 471, [lesson])

        # First promotion
        result = _run("471", str(specs_dir), str(memory_file))
        assert result.returncode == 0, f"First run stderr: {result.stderr}"

        lines_after_first = [line for line in memory_file.read_text().splitlines() if line.strip()]
        assert len(lines_after_first) == 1, f"Expected 1 line after first run: {lines_after_first}"

        # Second promotion of same lesson
        result = _run("471", str(specs_dir), str(memory_file))
        assert result.returncode == 0, f"Second run stderr: {result.stderr}"

        lines_after_second = [line for line in memory_file.read_text().splitlines() if line.strip()]
        assert len(lines_after_second) == 1, f"Expected still 1 line (dedup) after second run, got {len(lines_after_second)}: {lines_after_second}"
        record = json.loads(lines_after_second[0])
        assert record["occurrences"] == 2, f"Expected occurrences=2, got {record['occurrences']}"


class TestPromoteLessonsChangeLearnSource:
    """AC-1: change-lessons.jsonl is also read as a source."""

    def test_change_lessons_jsonl_is_read(self, tmp_path):
        """A generalizable entry from change-lessons.jsonl is promoted.

        change-lessons.jsonl uses `text` field (change-lane format).
        """
        specs_dir = tmp_path / "specs"
        memory_file = tmp_path / "procedural.jsonl"
        memory_file.touch()

        # change-lessons.jsonl uses {text, tags, scope, ...} format
        entry = {
            "text": "Validate inputs at boundary",
            "tags": ["validation"],
            "scope": "generalizable",
        }
        _make_change_lessons(specs_dir, 471, [entry])

        result = _run("471", str(specs_dir), str(memory_file))
        assert result.returncode == 0, f"stderr: {result.stderr}"

        lines = [line for line in memory_file.read_text().splitlines() if line.strip()]
        assert len(lines) == 1, f"Expected 1 promoted line, got {len(lines)}: {lines}"
        record = json.loads(lines[0])
        # change-lessons.jsonl `text` field maps to `text` in output record
        assert record["text"] == "Validate inputs at boundary"
        assert record["scope"] == "generalizable"


class TestPromoteLessonsNoOp:
    """AC-1: when no generalizable records exist, script exits 0."""

    def test_no_sources_exits_zero(self, tmp_path):
        """With no workflow-state and no change-lessons.jsonl, script exits 0."""
        specs_dir = tmp_path / "specs"
        specs_dir.mkdir()
        memory_file = tmp_path / "procedural.jsonl"
        memory_file.touch()

        result = _run("471", str(specs_dir), str(memory_file))
        assert result.returncode == 0, f"Expected exit 0, got {result.returncode}. stderr: {result.stderr}"

        lines = [line for line in memory_file.read_text().splitlines() if line.strip()]
        assert len(lines) == 0, f"Expected memory file untouched, got: {lines}"

    def test_all_local_scope_exits_zero_empty(self, tmp_path):
        """With only local-scope lessons, script exits 0 and MEMORY_FILE stays empty."""
        specs_dir = tmp_path / "specs"
        memory_file = tmp_path / "procedural.jsonl"
        memory_file.touch()

        _make_workflow_state(
            specs_dir,
            471,
            [
                {
                    "ts": "2026-07-20T10:00:00Z",
                    "cycle": 1,
                    "trigger": "halt",
                    "description": "Only for this issue",
                    "files_affected": [],
                    "scope": "local",
                },
            ],
        )

        result = _run("471", str(specs_dir), str(memory_file))
        assert result.returncode == 0, f"stderr: {result.stderr}"

        lines = [line for line in memory_file.read_text().splitlines() if line.strip()]
        assert len(lines) == 0, f"Expected empty memory file, got: {lines}"

    def test_memory_dir_is_created_if_missing(self, tmp_path):
        """If the MEMORY_FILE parent directory doesn't exist, script creates it."""
        specs_dir = tmp_path / "specs"
        specs_dir.mkdir()
        memory_file = tmp_path / "new_dir" / "procedural.jsonl"
        # Do NOT create tmp_path/new_dir — script must create it.

        result = _run("471", str(specs_dir), str(memory_file))
        assert result.returncode == 0, f"Expected exit 0, got {result.returncode}. stderr: {result.stderr}"


class TestPromoteLessonsSemanticTier:
    """#494: generalizable records route by `tier` — semantic → semantic.jsonl."""

    def test_semantic_record_routes_to_semantic_file(self, tmp_path):
        """A tier=semantic generalizable record lands in semantic.jsonl, not procedural."""
        specs_dir = tmp_path / "specs"
        procedural = tmp_path / "procedural.jsonl"
        semantic = tmp_path / "semantic.jsonl"
        procedural.touch()
        semantic.touch()

        _make_change_lessons(
            specs_dir,
            494,
            [
                {
                    "text": "Socket path override is /var/run/app.sock",
                    "tags": ["infra"],
                    "scope": "generalizable",
                    "tier": "semantic",
                }
            ],
        )

        result = _run("494", str(specs_dir), str(procedural), str(semantic))
        assert result.returncode == 0, f"stderr: {result.stderr}"

        sem_lines = [line for line in semantic.read_text().splitlines() if line.strip()]
        proc_lines = [line for line in procedural.read_text().splitlines() if line.strip()]
        assert len(sem_lines) == 1, f"Expected 1 semantic record, got {sem_lines}"
        assert len(proc_lines) == 0, f"Procedural must stay empty, got {proc_lines}"
        rec = json.loads(sem_lines[0])
        assert rec["tier"] == "semantic", f"tier not preserved: {rec}"
        assert rec["text"] == "Socket path override is /var/run/app.sock"
        assert rec["scope"] == "generalizable"

    def test_procedural_record_still_routes_to_procedural(self, tmp_path):
        """Regression: tier=procedural (and absent tier) still land in procedural.jsonl."""
        specs_dir = tmp_path / "specs"
        procedural = tmp_path / "procedural.jsonl"
        semantic = tmp_path / "semantic.jsonl"
        procedural.touch()
        semantic.touch()

        _make_change_lessons(
            specs_dir,
            494,
            [
                {
                    "text": "Explicit procedural lesson",
                    "tags": ["shell"],
                    "scope": "generalizable",
                    "tier": "procedural",
                },
                {
                    "text": "Absent-tier lesson defaults to procedural",
                    "tags": ["shell"],
                    "scope": "generalizable",
                    # no tier field → defaults to procedural
                },
            ],
        )

        result = _run("494", str(specs_dir), str(procedural), str(semantic))
        assert result.returncode == 0, f"stderr: {result.stderr}"

        proc_lines = [line for line in procedural.read_text().splitlines() if line.strip()]
        sem_lines = [line for line in semantic.read_text().splitlines() if line.strip()]
        assert len(proc_lines) == 2, f"Expected 2 procedural records, got {proc_lines}"
        assert len(sem_lines) == 0, f"Semantic must stay empty, got {sem_lines}"
        for line in proc_lines:
            assert json.loads(line)["tier"] == "procedural"

    def test_semantic_dedup_is_per_file(self, tmp_path):
        """Promoting the same semantic record twice bumps occurrences in semantic.jsonl only."""
        specs_dir = tmp_path / "specs"
        procedural = tmp_path / "procedural.jsonl"
        semantic = tmp_path / "semantic.jsonl"
        procedural.touch()
        semantic.touch()

        rec = {
            "text": "Durable fact worth deduping",
            "tags": ["infra"],
            "scope": "generalizable",
            "tier": "semantic",
        }
        _make_change_lessons(specs_dir, 494, [rec])

        r1 = _run("494", str(specs_dir), str(procedural), str(semantic))
        assert r1.returncode == 0, f"stderr: {r1.stderr}"
        r2 = _run("494", str(specs_dir), str(procedural), str(semantic))
        assert r2.returncode == 0, f"stderr: {r2.stderr}"

        sem_lines = [line for line in semantic.read_text().splitlines() if line.strip()]
        assert len(sem_lines) == 1, f"Expected 1 deduped semantic record, got {sem_lines}"
        assert json.loads(sem_lines[0])["occurrences"] == 2

    def test_default_semantic_file_when_arg_omitted(self, tmp_path):
        """3-arg back-compat: omitting the semantic arg still promotes procedural records."""
        specs_dir = tmp_path / "specs"
        procedural = tmp_path / "procedural.jsonl"
        procedural.touch()

        _make_change_lessons(
            specs_dir,
            494,
            [
                {
                    "text": "Legacy three-arg caller lesson",
                    "tags": ["shell"],
                    "scope": "generalizable",
                    "tier": "procedural",
                }
            ],
        )

        # No 4th arg — the script defaults SEMANTIC_MEMORY_FILE; procedural still works.
        result = _run("494", str(specs_dir), str(procedural))
        assert result.returncode == 0, f"stderr: {result.stderr}"
        proc_lines = [line for line in procedural.read_text().splitlines() if line.strip()]
        assert len(proc_lines) == 1
