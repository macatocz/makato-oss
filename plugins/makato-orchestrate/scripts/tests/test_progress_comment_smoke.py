"""The actual offline progress fixture must not mutate its source checkout."""

import os
import shutil
import subprocess
from pathlib import Path

import pytest

SOURCE = Path(__file__).resolve().parents[4]


@pytest.mark.parametrize("git_routing", ("default", "index", "repository"))
def test_progress_smoke_preserves_tracked_history_unrelated_edits_and_index(tmp_path: Path, git_routing: str) -> None:
    source = tmp_path / "source"
    source.mkdir()
    for name in ("makato-build", "makato-orchestrate"):
        shutil.copytree(SOURCE / "plugins" / name, source / "plugins" / name, ignore=shutil.ignore_patterns("__pycache__", "*.pyc"))
    env = {key: value for key, value in os.environ.items() if not key.startswith(("MAKATO_", "GIT_")) and key not in ("SPECS_DIR", "WORKTREE_PATH")}

    def git(*args: str) -> None:
        subprocess.run(["git", *args], cwd=source, env=env, capture_output=True, check=True)

    git("init", "-q")
    git("config", "user.name", "Smoke Safety")
    git("config", "user.email", "smoke@example.invalid")
    history = source / "specs/progress-comment-smoke/build.jsonl"
    history.parent.mkdir(parents=True)
    historical = b'{"skill":"po-agent","issue":350,"step":"session","status":"start"}\n'
    history.write_bytes(historical)
    unrelated = source / "user.txt"
    unrelated.write_bytes(b"base\n")
    git("add", ".")
    git("commit", "-qm", "tracked source and history")
    unrelated.write_bytes(b"staged user edit\n")
    git("add", "user.txt")
    unrelated.write_bytes(b"unstaged user edit\n")
    index = (source / ".git/index").read_bytes()
    config = (source / ".git/config").read_bytes()
    objects = set((source / ".git/objects").rglob("*"))
    smoke_env = dict(env)
    if git_routing != "default":
        smoke_env["GIT_INDEX_FILE"] = str(source / ".git/index")
    if git_routing == "repository":
        smoke_env.update(
            GIT_DIR=str(source / ".git"),
            GIT_WORK_TREE=str(source),
            GIT_COMMON_DIR=str(source / ".git"),
            GIT_OBJECT_DIRECTORY=str(source / ".git/objects"),
        )
    result = subprocess.run(["bash", str(source / "plugins/makato-orchestrate/shared/progress-comment-smoke-tests.sh")], cwd=source, env=smoke_env, capture_output=True, text=True, timeout=120)
    assert result.returncode == 0, result.stdout + result.stderr
    assert history.exists(), "progress smoke deleted tracked historical audit"
    assert history.read_bytes() == historical
    assert unrelated.read_bytes() == b"unstaged user edit\n"
    assert (source / ".git/index").read_bytes() == index
    assert (source / ".git/config").read_bytes() == config
    assert set((source / ".git/objects").rglob("*")) == objects
    assert list(history.parent.iterdir()) == [history], "progress smoke wrote consumer state inside source specs"
