"""Exercise the to-issues artifact → build-create-pr CLI contract (#163)."""

from __future__ import annotations

import json
import subprocess  # nosec B404 — CLI regression uses a fixed interpreter and repository script.
import sys
from pathlib import Path

import pytest

_REPO_ROOT = Path(__file__).resolve().parent.parent
_SCRIPT = _REPO_ROOT / "plugins" / "makato-build" / "shared" / "closes_injection.py"
_SCHEMA = _REPO_ROOT / "plugins" / "makato-plan" / "skills" / "to-issues" / "references" / "created-issues.schema.json"
_RESOLVER = _SCRIPT.with_name("spec_folder.py")


@pytest.fixture
def artifact(tmp_path: Path) -> Path:
    path = tmp_path / "created-issues.json"
    path.write_text(
        json.dumps(
            {
                "schema_version": "1",
                "slug": "shared-module",
                "issues": [{"issue_number": number, "url": f"https://github.com/o/r/issues/{number}", "title": f"[p] Story {number}", "labels": [], "blocked_by": []} for number in (1273, 1274)],
            }
        ),
        encoding="utf-8",
    )
    return path


def _run(artifact: Path, *args: str, schema: Path | None = _SCHEMA) -> dict:
    result = subprocess.run(  # nosec B603 — shell=False; all arguments are test-owned fixtures.
        [sys.executable, str(_SCRIPT), str(artifact), "--schema", str(schema) if schema else "", *args],
        capture_output=True,
        text=True,
        check=True,
        timeout=15,
    )
    return json.loads(result.stdout)


def test_dispatch_selects_only_current_issue_from_schema_valid_artifact(artifact: Path) -> None:
    result = _run(artifact, "--key", "shared-module", "--issue", "1274")
    assert result["closes"] == [1274]
    assert result["closes_injected"] == 1
    assert result["artifact_issues"] == 2
    assert result["artifact_status"] == "valid"
    assert result["artifact_warning"] is None
    assert result["scope_warning"] is None


@pytest.mark.parametrize("key", ["GH#1274", "gh-1274", "#1274", "1274"])
def test_github_key_resolves_folder_then_selects_current_issue(artifact: Path, key: str) -> None:
    root = artifact.parent
    folder = root / "specs" / "shared-module"
    folder.mkdir(parents=True)
    artifact.rename(folder / artifact.name)
    resolved = subprocess.run(  # nosec B603 — fixed resolver CLI, no shell or external input.
        [sys.executable, str(_RESOLVER), str(root), key], capture_output=True, text=True, check=True, timeout=15
    )
    assert Path(resolved.stdout.strip()) == folder.resolve()
    result = _run(Path(resolved.stdout.strip()) / "created-issues.json", "--key", key)
    assert result["closes"] == [1274]
    assert result["closes_injected"] == 1


def test_explicit_dispatch_issue_takes_precedence_over_key(artifact: Path) -> None:
    result = _run(artifact, "--key", "GH#1273", "--issue", "1274")
    assert result["issue"] == 1274
    assert result["closes"] == [1274]


@pytest.mark.parametrize("key", ["", "shared-module", "DCP-1274"])
def test_unresolved_shared_folder_injects_nothing_and_warns(artifact: Path, key: str) -> None:
    result = _run(artifact, "--key", key, "--issue", "")
    assert result["issue"] is None
    assert result["closes"] == []
    assert result["closes_injected"] == 0
    assert result["scope_warning"]


def test_stale_workflow_state_is_not_current_issue(artifact: Path) -> None:
    (artifact.parent / "workflow-state-1273.json").write_text('{"issue_number":1273}', encoding="utf-8")
    result = _run(artifact, "--key", "shared-module")
    assert result["issue"] is None
    assert result["closes"] == []
    assert result["scope_warning"]


def test_resolved_issue_missing_from_artifact_injects_nothing(artifact: Path) -> None:
    result = _run(artifact, "--issue", "1330")
    assert result["issue"] == 1330
    assert result["closes"] == []
    assert result["closes_injected"] == 0
    assert result["scope_warning"]


def test_single_issue_artifact_retains_legacy_injection(artifact: Path) -> None:
    data = json.loads(artifact.read_text(encoding="utf-8"))
    data["issues"] = data["issues"][:1]
    artifact.write_text(json.dumps(data), encoding="utf-8")
    result = _run(artifact)
    assert result["closes"] == [1273]
    assert result["closes_injected"] == 1
    assert result["scope_warning"] is None


def test_workflow_issues_prevent_single_entry_fallback_in_shared_folder(artifact: Path) -> None:
    data = json.loads(artifact.read_text(encoding="utf-8"))
    data["issues"] = data["issues"][:1]
    artifact.write_text(json.dumps(data), encoding="utf-8")
    for number in (1273, 1274):
        (artifact.parent / f"workflow-state-{number}.json").write_text("{}", encoding="utf-8")
    result = _run(artifact)
    assert result["closes"] == []
    assert result["closes_injected"] == 0
    assert result["scope_warning"]


def test_duplicate_current_issue_contributes_only_one_close(artifact: Path) -> None:
    data = json.loads(artifact.read_text(encoding="utf-8"))
    data["issues"].append(data["issues"][1])
    artifact.write_text(json.dumps(data), encoding="utf-8")
    result = _run(artifact, "--key", "GH#1274", "--issue", "1274")
    assert result["closes"] == [1274]
    assert result["closes_injected"] == 1


@pytest.mark.parametrize("content", ['{"issues":', '{"issues":[{"issue_number":1274}]}'])
def test_malformed_or_schema_invalid_artifact_is_nonblocking(artifact: Path, content: str) -> None:
    artifact.write_text(content, encoding="utf-8")
    result = _run(artifact, "--issue", "1274")
    assert result["artifact_status"] == "malformed"
    assert result["closes"] == []
    assert result["closes_injected"] == 0
    assert result["artifact_warning"]


def test_missing_artifact_is_nonblocking(tmp_path: Path) -> None:
    result = _run(tmp_path / "created-issues.json", "--issue", "1274")
    assert result["artifact_status"] == "missing"
    assert result["closes"] == []
    assert result["closes_injected"] == 0


def test_unavailable_schema_keeps_scoped_injection_with_advisory(artifact: Path) -> None:
    result = _run(artifact, "--issue", "1274", schema=None)
    assert result["artifact_status"] == "valid"
    assert result["closes"] == [1274]
    assert result["artifact_warning"]


@pytest.mark.parametrize("number", [True, 0, "1274"])
def test_structural_validation_without_schema_rejects_invalid_issue_numbers(artifact: Path, number: object) -> None:
    artifact.write_text(json.dumps({"issues": [{"issue_number": number}]}), encoding="utf-8")
    result = _run(artifact, "--issue", "1274", schema=None)
    assert result["artifact_status"] == "malformed"
    assert result["closes"] == []
    assert result["closes_injected"] == 0
