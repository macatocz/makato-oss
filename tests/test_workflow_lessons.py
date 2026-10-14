"""Exercise issue-scoped lesson capture and reports through the real CLI."""

from __future__ import annotations

import json
import os
import subprocess
from pathlib import Path

WS = Path(__file__).resolve().parents[1] / "plugins/makato-orchestrate/shared/workflow-state.sh"
REPO = "example/lesson-fixture"
KEY = "shared-feature"


def run_ws(root: Path, *args: str, env_overrides: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
    env = {key: value for key, value in os.environ.items() if key not in {"SPECS_DIR", "MAKATO_MEMORY_ROOT", "SCHEMA_PATH", "MAKATO_PROMOTE_REPO_OVERRIDE"}}
    if env_overrides:
        env.update(env_overrides)
    return subprocess.run(["bash", str(WS), *args], cwd=root, env=env, capture_output=True, text=True, check=False)


def init_issue(root: Path, issue: int = 887) -> Path:
    result = run_ws(root, "init", KEY, REPO, "fix/lesson-fixture", str(issue))
    assert result.returncode == 0, result.stderr
    return root / "specs" / KEY


def raw_lesson(text: str, issue: int = 887) -> dict:
    return {
        "ts": "2026-10-14T10:30:00.000Z",
        "tier": "semantic",
        "scope": "generalizable",
        "text": text,
        "tags": ["python"],
        "key": KEY,
        "repo": REPO,
        "issue_number": issue,
    }


def write_raw(folder: Path, records: list[dict]) -> None:
    (folder / "change-lessons.jsonl").write_text("".join(json.dumps(record) + "\n" for record in records), encoding="utf-8")


def test_summary_combines_workflow_and_raw_lessons_for_requested_issue(tmp_path: Path) -> None:
    folder = init_issue(tmp_path)
    init_issue(tmp_path, 888)
    append = run_ws(tmp_path, "append-lesson", KEY, "887", "1", "sensor", "Run static analysis with the project's selected interpreter", "pyproject.toml")
    assert append.returncode == 0, append.stderr
    write_raw(folder, [raw_lesson("The worker consumes the shared queue"), raw_lesson("Other issue's private context", 888)])

    result = run_ws(tmp_path, "summarise-lessons", KEY, "887")

    assert result.returncode == 0, result.stderr
    report = Path(result.stdout.strip()).read_text(encoding="utf-8")
    assert "Run static analysis with the project's selected interpreter" in report
    assert "The worker consumes the shared queue" in report
    assert "Other issue's private context" not in report
    assert "change-lessons.jsonl" in report
    assert "pyproject.toml" in report


def test_summary_reads_raw_lessons_without_workflow_state(tmp_path: Path) -> None:
    folder = tmp_path / "specs" / KEY
    folder.mkdir(parents=True)
    write_raw(folder, [raw_lesson("The operator chooses the tenant before importing")])

    result = run_ws(tmp_path, "summarise-lessons", KEY, "887")

    assert result.returncode == 0, result.stderr
    report = Path(result.stdout.strip()).read_text(encoding="utf-8")
    assert "The operator chooses the tenant before importing" in report
    assert REPO in report


def test_failed_summary_preserves_previous_report(tmp_path: Path) -> None:
    folder = init_issue(tmp_path)
    write_raw(folder, [raw_lesson("Previously validated capture")])
    result = run_ws(tmp_path, "summarise-lessons", KEY, "887")
    assert result.returncode == 0, result.stderr
    report_path = Path(result.stdout.strip())
    before = report_path.read_bytes()
    raw_path = folder / "change-lessons.jsonl"
    raw_path.write_text('{"text": invalid JSON}\n', encoding="utf-8")

    result = run_ws(tmp_path, "summarise-lessons", KEY, "887")

    assert result.returncode != 0
    assert report_path.read_bytes() == before
    assert not result.stdout.strip()


def test_unreadable_raw_source_does_not_create_empty_report(tmp_path: Path) -> None:
    folder = init_issue(tmp_path)
    (folder / "change-lessons.jsonl").mkdir()

    result = run_ws(tmp_path, "summarise-lessons", KEY, "887")

    assert result.returncode != 0
    assert not list(folder.glob("lessons-*.md"))
    assert "change-lessons.jsonl" in result.stderr


def test_summary_rejects_unattributable_shared_feature_capture(tmp_path: Path) -> None:
    folder = init_issue(tmp_path)
    init_issue(tmp_path, 888)
    lesson = raw_lesson("Do not assign this legacy capture to either issue")
    del lesson["issue_number"]
    write_raw(folder, [lesson])

    result = run_ws(tmp_path, "summarise-lessons", KEY, "887")

    assert result.returncode != 0
    assert "issue_number" in result.stderr
    assert not list(folder.glob("lessons-*.md"))


def test_summary_attributes_legacy_capture_only_to_sole_workflow_issue(tmp_path: Path) -> None:
    folder = init_issue(tmp_path)
    lesson = raw_lesson("Only this issue owns the feature capture")
    del lesson["issue_number"]
    write_raw(folder, [lesson])

    result = run_ws(tmp_path, "summarise-lessons", KEY, "887")

    assert result.returncode == 0, result.stderr
    assert lesson["text"] in Path(result.stdout.strip()).read_text(encoding="utf-8")


def test_append_generalizable_semantic_lesson_is_immediately_recallable(tmp_path: Path) -> None:
    folder = init_issue(tmp_path)
    append = run_ws(
        tmp_path,
        "append-lesson",
        KEY,
        "887",
        "1",
        "review_comment",
        "Tenant identity comes from the verified issuer",
        "body/auth.py",
        "--tier",
        "semantic",
        "--scope",
        "generalizable",
        "--tags",
        "identity, security",
        "--bundle",
        "python",
        "--label",
        "auth",
        env_overrides={"MAKATO_PROMOTE_REPO_OVERRIDE": REPO},
    )

    assert append.returncode == 0, append.stderr
    state = json.loads((folder / "workflow-state-887.json").read_text(encoding="utf-8"))
    lesson = state["lessons_learned"][0]
    assert lesson["tier"] == "semantic"
    assert lesson["scope"] == "generalizable"
    assert lesson["tags"] == ["identity", "security"]
    assert lesson["bundle"] == "python"
    assert lesson["label"] == "auth"
    assert lesson["files_affected"] == ["body/auth.py"]
    memory_file = tmp_path / ".makato/memory/semantic.jsonl"
    captured = [json.loads(line) for line in memory_file.read_text(encoding="utf-8").splitlines()]
    assert [(item["description"], item["bundle"], item["label"]) for item in captured] == [(lesson["description"], "python", "auth")]
    (folder / "workflow-state-887.json").unlink()
    recalled = run_ws(tmp_path, "recall-lessons", REPO, "5", "--labels", "auth")
    assert recalled.returncode == 0, recalled.stderr
    assert [item["description"] for item in json.loads(recalled.stdout)] == [lesson["description"]]
