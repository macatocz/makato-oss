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

import fcntl
import json
import os
import subprocess
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).parent.parent
SCRIPT = REPO_ROOT / "plugins" / "makato-orchestrate" / "scripts" / "promote-lessons.sh"


def _run(
    issue_number: str,
    specs_dir: str | None = None,
    memory_file: str | None = None,
    semantic_memory_file: str | None = None,
    **kwargs,
) -> subprocess.CompletedProcess:
    """Invoke promote-lessons.sh with three (or four) positional arguments."""
    env = {**os.environ}
    env["MAKATO_PROMOTE_REPO_OVERRIDE"] = "macatocz/makato-test"
    env.update(kwargs.get("extra_env", {}))
    argv = ["bash", str(SCRIPT), issue_number]
    if specs_dir is not None:
        argv.append(specs_dir)
    if memory_file is not None:
        argv.append(memory_file)
    if semantic_memory_file is not None:
        argv.append(semantic_memory_file)
    return subprocess.run(
        argv,
        capture_output=True,
        text=True,
        env=env,
        cwd=kwargs.get("cwd", str(REPO_ROOT)),
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


class TestPromoteLessonsOccurrences:
    """Occurrences count source events, not invocations of the promoter."""

    def test_replaying_source_is_idempotent_and_new_event_counts(self, tmp_path):
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
        state = _make_workflow_state(specs_dir, 471, [lesson])

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
        assert record["occurrences"] == 1
        assert lines_after_first == lines_after_second

        state.write_text(json.dumps({"lessons_learned": [lesson, {**lesson, "ts": "2026-07-21T10:00:00Z"}]}))
        result = _run("471", str(specs_dir), str(memory_file))
        assert result.returncode == 0, result.stderr
        assert json.loads(memory_file.read_text())["occurrences"] == 2


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

    def test_semantic_replay_is_idempotent_and_independent_of_procedural(self, tmp_path):
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
        assert json.loads(sem_lines[0])["occurrences"] == 1
        assert procedural.read_text() == ""

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


def _write_raw(folder, records):
    folder.mkdir(parents=True, exist_ok=True)
    path = folder / "change-lessons.jsonl"
    path.write_text("".join(json.dumps(record) + "\n" for record in records))
    return path


def _records(path):
    return [json.loads(line) for line in path.read_text().splitlines() if line.strip()]


def test_exact_slug_preserves_capture_identity_and_recall_metadata(tmp_path):
    specs = tmp_path / "specs"
    memory = tmp_path / "memory" / "procedural.jsonl"
    lesson = {
        "event_id": "capture-887",
        "ts": "2026-10-14T10:00:00Z",
        "text": "Keep tenant authorization inside the service boundary",
        "description": "Keep tenant authorization inside the service boundary",
        "tags": ["authorization"],
        "scope": "generalizable",
        "tier": "procedural",
        "key": "admin-console",
        "repo": "macatocz/sagibeast",
        "issue_number": 887,
        "bundle": "python",
        "label": "security",
        "files_affected": ["body/auth.py"],
    }
    _write_raw(specs / "admin-console", [lesson])
    _write_raw(specs / "admin-console-extra", [{**lesson, "text": "Unrelated sibling", "event_id": "other"}])

    result = _run("admin-console", str(specs), str(memory))
    assert result.returncode == 0, result.stderr
    records = _records(memory)
    assert [record["text"] for record in records] == [lesson["text"]]
    record = records[0]
    for field in ("repo", "tier", "scope", "bundle", "label", "ts", "files_affected"):
        assert record[field] == lesson[field]
    assert record["source_key"] == "admin-console"
    assert record["source_issue"] == 887
    assert len(record["key"]) == 64
    assert record["source_events"][0]["event_id"] == "capture-887"


def test_numeric_lookup_finds_slug_state_and_filters_shared_raw_issues(tmp_path):
    specs = tmp_path / "specs"
    folder = specs / "admin-console"
    memory = tmp_path / "procedural.jsonl"
    folder.mkdir(parents=True)
    for issue in (887, 888):
        (folder / f"workflow-state-{issue}.json").write_text(json.dumps({"issue_number": issue, "lessons_learned": [{"scope": "generalizable", "description": f"State lesson {issue}"}]}))
    _write_raw(folder, [{"scope": "generalizable", "text": f"Raw lesson {issue}", "issue_number": issue, "key": "admin-console"} for issue in (887, 888)])

    result = _run("887", str(specs), str(memory))
    assert result.returncode == 0, result.stderr
    records = _records(memory)
    assert {record["text"] for record in records} == {"State lesson 887", "Raw lesson 887"}
    assert {record["source_issue"] for record in records} == {887}

    result = _run("admin-console", str(specs), str(memory))
    assert result.returncode == 0, result.stderr
    assert {record["text"] for record in _records(memory)} == {"State lesson 887", "Raw lesson 887", "State lesson 888", "Raw lesson 888"}
    assert {record["occurrences"] for record in _records(memory)} == {1}


def _shared_spec(tmp_path, raw_records):
    folder = tmp_path / "specs" / "admin-console"
    for issue in (887, 888):
        folder.mkdir(parents=True, exist_ok=True)
        (folder / f"workflow-state-{issue}.json").write_text(json.dumps({"issue_number": issue, "lessons_learned": []}))
    raw = _write_raw(folder, raw_records)
    return tmp_path / "specs", raw


LEGACY = {"scope": "generalizable", "text": "Owner is unknown", "key": "admin-console"}
ATTRIBUTED = {"scope": "generalizable", "text": "Owner is known", "key": "admin-console", "issue_number": 888, "event_id": "new-888"}


def test_spec_key_promotion_keeps_legacy_unattributed_beside_attributed(tmp_path):
    specs, raw = _shared_spec(tmp_path, [LEGACY, ATTRIBUTED])
    memory = tmp_path / "procedural.jsonl"
    before = raw.read_bytes()

    result = _run("admin-console", str(specs), str(memory))
    assert result.returncode == 0, result.stderr
    records = {record["text"]: record for record in _records(memory)}
    assert set(records) == {"Owner is unknown", "Owner is known"}
    legacy, known = records["Owner is unknown"], records["Owner is known"]
    # Unknown attribution is never invented, but path/key provenance remains.
    assert "source_issue" not in legacy
    assert all("issue_number" not in event for event in legacy["source_events"])
    assert legacy["source_key"] == "admin-console"
    assert legacy["source_events"][0]["path"] == "admin-console/change-lessons.jsonl"
    assert legacy["source_events"][0]["key"] == "admin-console"
    assert known["source_issue"] == 888
    assert known["source_events"][0]["issue_number"] == 888
    assert raw.read_bytes() == before

    # Replay is idempotent for both attributed and legacy records.
    snapshot = memory.read_text()
    assert _run("admin-console", str(specs), str(memory)).returncode == 0
    assert memory.read_text() == snapshot
    assert {record["occurrences"] for record in _records(memory)} == {1}


def test_numeric_promotion_skips_ambiguous_legacy_with_warning_but_promotes_attributed(tmp_path):
    specs, raw = _shared_spec(tmp_path, [LEGACY, ATTRIBUTED, {**ATTRIBUTED, "text": "Other issue", "issue_number": 887, "event_id": "new-887"}])
    memory = tmp_path / "procedural.jsonl"
    before = raw.read_bytes()

    result = _run("888", str(specs), str(memory))
    assert result.returncode == 0, result.stderr
    assert "warning" in result.stderr and "admin-console/change-lessons.jsonl" in result.stderr
    assert [record["text"] for record in _records(memory)] == ["Owner is known"]
    assert _records(memory)[0]["source_issue"] == 888
    assert raw.read_bytes() == before

    # Another numeric issue must not claim the legacy record either.
    result = _run("887", str(specs), str(memory))
    assert result.returncode == 0, result.stderr
    assert {record["text"] for record in _records(memory)} == {"Owner is known", "Other issue"}
    assert "Owner is unknown" not in memory.read_text()


def test_numeric_promotion_with_only_ambiguous_legacy_warns_and_writes_nothing(tmp_path):
    specs, _ = _shared_spec(tmp_path, [LEGACY])
    memory = tmp_path / "procedural.jsonl"
    result = _run("887", str(specs), str(memory))
    assert result.returncode == 0, result.stderr
    assert "warning" in result.stderr
    assert not memory.exists() or memory.read_text() == ""


def test_legacy_attribution_does_not_fall_back_to_folder_name_in_shared_spec(tmp_path):
    folder = tmp_path / "specs" / "887-admin-console"
    for issue in (887, 888):
        folder.mkdir(parents=True, exist_ok=True)
        (folder / f"workflow-state-{issue}.json").write_text(json.dumps({"lessons_learned": []}))
    _write_raw(folder, [{**LEGACY, "key": "887-admin-console"}])
    memory = tmp_path / "procedural.jsonl"

    result = _run("887", str(tmp_path / "specs"), str(memory))
    assert result.returncode == 0, result.stderr
    assert not memory.exists() or memory.read_text() == ""
    result = _run("887-admin-console", str(tmp_path / "specs"), str(memory))
    assert result.returncode == 0, result.stderr
    assert "source_issue" not in _records(memory)[0]


def test_invalid_explicit_issue_still_fails_in_shared_spec_with_legacy_records(tmp_path):
    specs, raw = _shared_spec(tmp_path, [LEGACY, {**ATTRIBUTED, "issue_number": "abc"}])
    memory = tmp_path / "procedural.jsonl"
    for key in ("admin-console", "888"):
        result = _run(key, str(specs), str(memory))
        assert result.returncode != 0
        assert "issue_number must be a positive integer" in result.stderr
    assert not memory.exists() or memory.read_text() == ""


def test_default_paths_use_main_checkout_from_worktree_subdirectory(tmp_path):
    main = tmp_path / "main"
    main.mkdir()
    subprocess.run(["git", "init", "-q", str(main)], check=True)
    subprocess.run(["git", "-C", str(main), "-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "--allow-empty", "-qm", "fixture"], check=True)
    worktree = tmp_path / "worktree"
    subprocess.run(["git", "-C", str(main), "worktree", "add", "--detach", "-q", str(worktree)], check=True)
    cwd = worktree / "nested"
    cwd.mkdir()
    _write_raw(main / "specs" / "471-example", [{"scope": "generalizable", "tier": tier, "text": f"Main checkout {tier}"} for tier in ("procedural", "semantic")])

    result = _run("471", cwd=cwd)
    assert result.returncode == 0, result.stderr
    for tier in ("procedural", "semantic"):
        records = _records(main / ".makato" / "memory" / f"{tier}.jsonl")
        assert [record["text"] for record in records] == [f"Main checkout {tier}"]
    assert not (worktree / ".makato").exists()
    assert not (cwd / ".makato").exists()


def test_target_root_override_selects_linked_checkout_stores_and_provenance(tmp_path):
    main = tmp_path / "main"
    main.mkdir()
    subprocess.run(["git", "init", "-q", str(main)], check=True)
    commit = ["-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "--allow-empty", "-qm"]
    subprocess.run(["git", "-C", str(main), *commit, "main fixture"], check=True)
    target = tmp_path / "target"
    subprocess.run(["git", "-C", str(main), "worktree", "add", "-q", "-b", "target", str(target)], check=True)
    subprocess.run(["git", "-C", str(target), *commit, "target-only fixture"], check=True)
    target_sha = subprocess.run(["git", "-C", str(target), "rev-parse", "--short", "HEAD"], check=True, capture_output=True, text=True).stdout.strip()
    for root in (main, target):
        _write_raw(root / "specs" / "471-example", [{"scope": "generalizable", "text": f"Lesson in {root.name}"}])

    result = _run("471", cwd=main, extra_env={"MAKATO_TARGET_REPO_ROOT": str(target)})
    assert result.returncode == 0, result.stderr
    records = _records(target / ".makato" / "memory" / "procedural.jsonl")
    assert [record["text"] for record in records] == ["Lesson in target"]
    assert records[0]["repo_sha"] == target_sha
    assert not (main / ".makato").exists()


def test_invalid_target_root_fails_before_touching_any_store(tmp_path):
    not_a_directory = tmp_path / "not-a-directory"
    not_a_directory.write_text("file\n")
    result = _run("471", cwd=tmp_path, extra_env={"MAKATO_TARGET_REPO_ROOT": str(not_a_directory)})
    assert result.returncode != 0
    assert "promote-lessons: target repository root is not a directory:" in result.stderr
    assert not (tmp_path / ".makato").exists()


def test_explicit_procedural_path_keeps_semantic_store_beside_it(tmp_path):
    specs = tmp_path / "specs"
    procedural = tmp_path / "durable" / "procedural.jsonl"
    _make_change_lessons(specs, 471, [{"scope": "generalizable", "tier": "semantic", "text": "A durable semantic fact"}])
    result = _run("471", str(specs), str(procedural), cwd=tmp_path)
    assert result.returncode == 0, result.stderr
    assert [record["text"] for record in _records(procedural.with_name("semantic.jsonl"))] == ["A durable semantic fact"]
    assert not (tmp_path / ".makato").exists()


@pytest.mark.parametrize("source_kind", ["raw", "state", "store"])
def test_malformed_json_fails_without_changing_sources_or_either_store(tmp_path, source_kind):
    specs = tmp_path / "specs"
    folder = specs / "471-example"
    procedural = tmp_path / "procedural.jsonl"
    semantic = tmp_path / "semantic.jsonl"
    raw = _write_raw(folder, [{"scope": "generalizable", "tier": "semantic", "text": "Valid new lesson"}])
    state = folder / "workflow-state-471.json"
    state.write_text(json.dumps({"lessons_learned": []}))
    procedural.write_text(json.dumps({"key": "legacy", "text": "Keep existing metadata", "bundle": "python"}) + "\n")
    semantic.write_text("[]\n" if source_kind == "store" else "")
    if source_kind == "raw":
        raw.write_text(raw.read_text() + "{broken json\n")
    elif source_kind == "state":
        state.write_text("{broken json")
    before = {path: path.read_bytes() for path in (raw, state, procedural, semantic)}

    result = _run("471", str(specs), str(procedural), str(semantic))
    assert result.returncode != 0, result.stderr
    assert {path: path.read_bytes() for path in before} == before


def test_event_id_survives_source_reordering_and_new_identical_event_counts(tmp_path):
    specs = tmp_path / "specs"
    memory = tmp_path / "procedural.jsonl"
    base = {"scope": "generalizable", "text": "Use service-owned authorization", "issue_number": 471}
    raw = _write_raw(specs / "471-example", [{**base, "event_id": "first"}])
    result = _run("471", str(specs), str(memory))
    assert result.returncode == 0, result.stderr
    raw.write_text(json.dumps({**base, "event_id": "second"}) + "\n" + raw.read_text())
    for _ in range(2):
        result = _run("471", str(specs), str(memory))
        assert result.returncode == 0, result.stderr
    record = _records(memory)[0]
    assert record["occurrences"] == 2
    assert {source["event_id"] for source in record["source_events"]} == {"first", "second"}


def test_concurrent_promotions_wait_for_store_lock_and_preserve_all_events(tmp_path):
    specs = tmp_path / "specs"
    memory = tmp_path / "procedural.jsonl"
    for issue in (471, 472):
        _make_change_lessons(specs, issue, [{"scope": "generalizable", "text": "Concurrent recurring lesson", "event_id": f"event-{issue}"}])
    lock_path = memory.with_name(memory.name + ".lock")
    with lock_path.open("a") as lock, ThreadPoolExecutor(max_workers=2) as pool:
        fcntl.flock(lock, fcntl.LOCK_EX)
        futures = [pool.submit(_run, str(issue), str(specs), str(memory)) for issue in (471, 472)]
        try:
            time.sleep(0.3)
            assert not any(future.done() for future in futures), "Promotion must not read or replace a store while its lock is held"
            memory.write_text(json.dumps({"key": "retained", "text": "Existing durable lesson", "occurrences": 4, "bundle": "python"}) + "\n")
        finally:
            fcntl.flock(lock, fcntl.LOCK_UN)
        results = [future.result(timeout=15) for future in futures]
    assert [result.returncode for result in results] == [0, 0], [result.stderr for result in results]
    records = {record["text"]: record for record in _records(memory)}
    assert records["Existing durable lesson"]["occurrences"] == 4
    assert records["Existing durable lesson"]["bundle"] == "python"
    assert records["Concurrent recurring lesson"]["occurrences"] == 2
    assert {source["issue_number"] for source in records["Concurrent recurring lesson"]["source_events"]} == {471, 472}


def test_raw_capture_lock_prevents_reading_a_partial_append(tmp_path):
    specs = tmp_path / "specs"
    memory = tmp_path / "procedural.jsonl"
    raw = _write_raw(specs / "471-example", [{"scope": "generalizable", "text": "Existing capture", "event_id": "first"}])
    pending = json.dumps({"scope": "generalizable", "text": "Concurrent capture", "event_id": "second"}) + "\n"
    split = len(pending) // 2
    with raw.open("a") as writer, ThreadPoolExecutor(max_workers=1) as pool:
        fcntl.flock(writer, fcntl.LOCK_EX)
        writer.write(pending[:split])
        writer.flush()
        future = pool.submit(_run, "471", str(specs), str(memory))
        try:
            time.sleep(0.3)
            assert not future.done(), "Promotion must wait for an in-progress raw capture"
            writer.write(pending[split:])
            writer.flush()
        finally:
            fcntl.flock(writer, fcntl.LOCK_UN)
        result = future.result(timeout=15)
    assert result.returncode == 0, result.stderr
    assert {record["text"] for record in _records(memory)} == {"Existing capture", "Concurrent capture"}
