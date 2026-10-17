"""Exercise lesson capture through the public CLI in real git worktrees."""

import json
import os
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
WRITER = ROOT / "plugins/makato-build/shared/write-lessons.sh"
ORCHESTRATE = ROOT / "plugins/makato-orchestrate"


def run(*args, cwd, env=None):
    return subprocess.run(args, cwd=cwd, env=env, capture_output=True, text=True, check=False)


@pytest.fixture
def repo(tmp_path):
    main = tmp_path / "main"
    main.mkdir()
    for command in (
        ("git", "init", "-q"),
        ("git", "remote", "add", "origin", "https://github.com/example/consumer.git"),
        ("git", "-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "--allow-empty", "-qm", "fixture"),
    ):
        result = run(*command, cwd=main)
        assert result.returncode == 0, result.stderr
    spec = main / "specs" / "admin-console"
    spec.mkdir(parents=True)
    worktree = tmp_path / "worktree"
    result = run("git", "worktree", "add", "-qb", "feature", str(worktree), cwd=main)
    assert result.returncode == 0, result.stderr
    env = {**os.environ, "MAKATO_ORCHESTRATE_ROOT": str(ORCHESTRATE)}
    return main, worktree, spec, env


def records(path):
    return [json.loads(line) for line in path.read_text().splitlines() if line.strip()] if path.exists() else []


@pytest.mark.parametrize("tier", ["procedural", "semantic"])
def test_capture_is_durable_without_merge_and_recalls_from_worktree(repo, tier):
    main, worktree, spec, env = repo
    text = "Run browser verification from the frontend package root."
    result = run("bash", str(WRITER), "admin-console", tier, "generalizable", text, "frontend,verification", cwd=worktree, env=env)
    assert result.returncode == 0, result.stderr
    saved = records(main / ".makato" / "memory" / f"{tier}.jsonl")
    assert [entry["text"] for entry in saved] == [text]
    assert saved[0]["repo"] == "example/consumer"
    assert saved[0]["tier"] == tier
    assert not (worktree / ".makato").exists()
    assert records(spec / "change-lessons.jsonl")[0]["text"] == text
    recall = run("bash", str(ORCHESTRATE / "shared/workflow-state.sh"), "recall-lessons", "example/consumer", "20", cwd=worktree, env=env)
    assert recall.returncode == 0, recall.stderr
    assert text in [entry.get("text") for entry in json.loads(recall.stdout)]
    replay = run("bash", str(ORCHESTRATE / "scripts/promote-lessons.sh"), "admin-console", cwd=worktree, env=env)
    assert replay.returncode == 0, replay.stderr
    assert records(main / ".makato" / "memory" / f"{tier}.jsonl")[0]["occurrences"] == 1


def test_local_capture_does_not_enter_shared_memory(repo):
    main, worktree, spec, env = repo
    result = run("bash", str(WRITER), "admin-console", "procedural", "local", "Temporary fixture detail.", cwd=worktree, env=env)
    assert result.returncode == 0, result.stderr
    assert records(spec / "change-lessons.jsonl")[0]["scope"] == "local"
    for tier in ("procedural", "semantic"):
        assert records(main / ".makato/memory" / f"{tier}.jsonl") == []


def test_shared_spec_requires_issue_identity_before_writing(repo):
    _, worktree, spec, env = repo
    for number in (886, 887):
        (spec / f"workflow-state-{number}.json").write_text(json.dumps({"issue_number": number, "lessons_learned": []}))
    result = run("bash", str(WRITER), "admin-console", "semantic", "generalizable", "Gateway fact.", cwd=worktree, env=env)
    assert result.returncode != 0
    assert "--issue" in result.stderr
    assert not (spec / "change-lessons.jsonl").exists()


def test_capture_preserves_explicit_issue_and_recall_filters(repo):
    main, worktree, spec, env = repo
    for number in (886, 887):
        (spec / f"workflow-state-{number}.json").write_text(json.dumps({"issue_number": number, "lessons_learned": []}))
    result = run(
        "bash",
        str(WRITER),
        "admin-console",
        "semantic",
        "generalizable",
        "Gateway uses the API boundary.",
        "gateway",
        "--issue",
        "887",
        "--bundle",
        "backend",
        "--label",
        "area:gateway",
        cwd=worktree,
        env=env,
    )
    assert result.returncode == 0, result.stderr
    assert records(spec / "change-lessons.jsonl")[0]["issue_number"] == 887
    saved = records(main / ".makato/memory/semantic.jsonl")
    assert saved[0]["source_issue"] == 887
    assert saved[0]["bundle"] == "backend"
    recall = run("bash", str(ORCHESTRATE / "shared/workflow-state.sh"), "recall-lessons", "example/consumer", "20", "--bundles", "backend", cwd=worktree, env=env)
    assert recall.returncode == 0, recall.stderr
    assert [entry["text"] for entry in json.loads(recall.stdout)] == ["Gateway uses the API boundary."]


def test_missing_promoter_reports_failure_but_retains_captured_evidence(repo):
    main, worktree, spec, env = repo
    env["MAKATO_ORCHESTRATE_ROOT"] = str(main / "not-installed")
    result = run("bash", str(WRITER), "admin-console", "semantic", "generalizable", "Evidence must survive a promotion failure.", cwd=worktree, env=env)
    assert result.returncode != 0
    assert "promot" in result.stderr.lower()
    assert records(spec / "change-lessons.jsonl")[0]["text"] == "Evidence must survive a promotion failure."


@pytest.mark.parametrize("key", ["../escape", "/tmp/outside", ".", ".."])
def test_capture_rejects_spec_path_escape(repo, key):
    _, worktree, _, env = repo
    result = run("bash", str(WRITER), key, "procedural", "local", "Must stay in specs.", cwd=worktree, env=env)
    assert result.returncode != 0
