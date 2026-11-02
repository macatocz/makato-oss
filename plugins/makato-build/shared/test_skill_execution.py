"""Behavior tests for execution settings and the separate-process skill launcher."""

from __future__ import annotations

import importlib.util
import json
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path
from typing import Any, NamedTuple

import pytest
import yaml

_HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(_HERE))

from skill_execution import (  # noqa: E402
    SkillExecutionError,
    canonical_skill,
    resolve_execution,
)

_RUNNER_PATH = _HERE.parent / "scripts" / "run-skill.py"
_SPEC = importlib.util.spec_from_file_location("makato_run_skill", _RUNNER_PATH)
assert _SPEC is not None and _SPEC.loader is not None
_RUNNER = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(_RUNNER)


class Layout(NamedTuple):
    repo: Path
    build: Path
    plan: Path
    change: Path
    schema: Path


def _write_yaml(path: Path, data: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(yaml.safe_dump(data), encoding="utf-8")


def _built_in() -> dict[str, Any]:
    return {
        "version": "1.0",
        "artifacts": [{"id": "review", "skill": "build-review", "required": True}],
        "skill_execution": {
            "defaults": {"role": "DEFAULT", "effort": "inherit"},
            "skills": {
                "makato-plan:create-prd": {"role": "PLAN", "effort": "high"},
                "makato-change:analyze": {"role": "PLAN", "effort": "high"},
                "makato-build:build-review": {"role": "REVIEW", "effort": "high"},
                "makato-build:build-verify": {},
            },
        },
    }


@pytest.fixture
def layout(tmp_path: Path) -> Layout:
    repo = tmp_path / "repo with spaces"
    repo.mkdir()
    plugins = tmp_path / "plugin checkout"
    build = plugins / "makato-build"
    plan = plugins / "makato-plan"
    change = plugins / "makato-change"
    schema = build / "config" / "default-workflow-schema.yml"
    _write_yaml(schema, _built_in())
    (build / "config" / "verification-ownership.md").write_text("MAKATO VERIFICATION OWNERSHIP: test policy.\n", encoding="utf-8")
    for root, name in (
        (build, "build-review"),
        (build, "build-verify"),
        (plan, "create-prd"),
        (change, "analyze"),
    ):
        skill = root / "skills" / name / "SKILL.md"
        skill.parent.mkdir(parents=True)
        skill.write_text(
            f"---\nname: {name}\n---\n# {name}\nRetain this exact output contract and consult references/example.md.\n",
            encoding="utf-8",
        )
    return Layout(repo, build, plan, change, schema)


def _project(layout: Layout, execution: Any) -> None:
    _write_yaml(layout.repo / ".claude" / "workflow-schema.yml", {"skill_execution": execution})


def _resolve(layout: Layout, skill: str = "build-review", **kwargs: Any) -> dict[str, str]:
    return resolve_execution(layout.repo, skill, layout.schema, **kwargs)


def _environment(layout: Layout) -> dict[str, str]:
    env = dict(os.environ)
    for key in tuple(env):
        if key.startswith("MAKATO_REVIEW_"):
            env.pop(key)
    for key in (
        "MAKATO_PLAN_ROOT",
        "MAKATO_CHANGE_ROOT",
        "MAKATO_HARNESS_BIN",
        "KEY",
        "ISSUE_NUMBER",
        "REPO",
        "MAKATO_ORCHESTRATE_ROOT",
        "MAKATO_ORCHESTRATE_SHARED",
        "MAKATO_TARGET_REPO_ROOT",
        "MAKATO_PROGRESS_COMMENT_DISABLE",
        "MAKATO_PC_GH_STUB",
        "MAKATO_PC_GH_FAIL",
        "SPECS_DIR",
    ):
        env.pop(key, None)
    env["MAKATO_BUILD_ROOT"] = str(layout.build)
    return env


def _arguments(layout: Layout, *options: str, skill: str = "makato-build:build-review", data: tuple[str, ...] = ()) -> Any:
    return _RUNNER.parser().parse_args(["--repo-root", str(layout.repo), *options, skill, "--", *data])


def _command(layout: Layout, *options: str, skill: str = "makato-build:build-review", data: tuple[str, ...] = (), env: dict[str, str] | None = None) -> Any:
    return _RUNNER.build_command(
        _arguments(layout, *options, skill=skill, data=data),
        env if env is not None else _environment(layout),
    )


def _metadata(prompt: str) -> dict[str, Any]:
    body = prompt.split("Resolved dispatch metadata (JSON):\n", 1)[1]
    result, _ = json.JSONDecoder().raw_decode(body)
    return result


def test_orchestrate_metadata_is_durable_only_and_not_dispatchable(layout: Layout) -> None:
    env = _environment(layout)
    orchestrate = layout.repo.parent / "installed-orchestrate"
    env["MAKATO_ORCHESTRATE_ROOT"] = str(orchestrate)
    ordinary, _, _ = _command(layout, env=env)
    outer, _, _ = _command(layout, "--review-orchestrate-root", str(orchestrate), env=env)
    child, _, _ = _command(layout, "--runtime-child", env=env)
    assert "makato-orchestrate" not in _metadata(ordinary[-1])["plugin_roots"]
    assert _metadata(outer[-1])["plugin_roots"]["makato-orchestrate"] == str(orchestrate)
    assert outer == child
    assert "makato-orchestrate" not in _RUNNER._PLUGINS
    with pytest.raises(SkillExecutionError, match="Unknown skill 'makato-orchestrate:loop'"):
        _command(layout, skill="makato-orchestrate:loop", env=env)


def test_durable_main_freezes_roots_before_build_command(layout: Layout, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture) -> None:
    build = _HERE.parent
    orchestrate = _HERE.parents[1] / "makato-orchestrate"
    for key in tuple(os.environ):
        if key.startswith("MAKATO_REVIEW_") or key in ("MAKATO_BUILD_ROOT", "MAKATO_ORCHESTRATE_ROOT", "MAKATO_ORCHESTRATE_SHARED"):
            monkeypatch.delenv(key)
    native = _RUNNER.build_command
    observed = []

    def build_frozen(args, environ):
        observed.append({key: environ[key] for key in ("MAKATO_BUILD_ROOT", "MAKATO_ORCHESTRATE_ROOT", "MAKATO_ORCHESTRATE_SHARED")})
        return native(args, environ)

    monkeypatch.setattr(_RUNNER, "build_command", build_frozen)
    assert _RUNNER.main(["--repo-root", str(layout.repo), "--dry-run", "--review-orchestrate-root", str(orchestrate), "makato-build:build-review"]) == 0
    output = json.loads(capsys.readouterr().out)
    expected = {"MAKATO_BUILD_ROOT": str(build), "MAKATO_ORCHESTRATE_ROOT": str(orchestrate), "MAKATO_ORCHESTRATE_SHARED": str(orchestrate / "shared")}
    assert observed == [expected]
    assert {key: output["env"][key] for key in expected} == expected
    assert _metadata(output["argv"][-1])["plugin_roots"]["makato-orchestrate"] == str(orchestrate)


@pytest.mark.parametrize("missing", [None, "MAKATO_ORCHESTRATE_ROOT", "MAKATO_ORCHESTRATE_SHARED"])
def test_durable_progress_never_discovers_runtime_context(layout: Layout, monkeypatch: pytest.MonkeyPatch, missing: str | None) -> None:
    orchestrate = _HERE.parents[1] / "makato-orchestrate"
    env = _environment(layout)
    env.update(
        MAKATO_BUILD_ROOT=str(_HERE.parent),
        MAKATO_ORCHESTRATE_ROOT=str(orchestrate),
        MAKATO_ORCHESTRATE_SHARED=str(orchestrate / "shared"),
        MAKATO_REVIEW_LEDGER_STATE=str(layout.repo / "ledger.json"),
        KEY="DURABLE",
        ISSUE_NUMBER="186",
        REPO="offline/test",
    )
    if missing:
        env.pop(missing)

    def forbid_discovery(*args, **kwargs):
        raise AssertionError("durable progress called runtime-context")

    monkeypatch.setattr(_RUNNER.subprocess, "run", forbid_discovery)
    target = _RUNNER._progress_target(env)
    if missing:
        assert target is None
    else:
        assert target == [str(orchestrate / "shared/progress-comment.sh"), "DURABLE", "186", "offline/test"]


def test_builtin_role_and_effort_are_independent(layout: Layout) -> None:
    assert _resolve(layout) == {"role": "REVIEW", "effort": "high"}
    assert _resolve(layout, "create-prd") == {"role": "PLAN", "effort": "high"}
    assert _resolve(layout, "build-verify") == {"role": "DEFAULT", "effort": "inherit"}
    assert canonical_skill("build-review", layout.schema) == "makato-build:build-review"


@pytest.mark.parametrize(
    ("defaults", "specific", "expected"),
    [
        ({}, {}, {"role": "REVIEW", "effort": "high"}),
        ({"role": "FAST"}, {}, {"role": "FAST", "effort": "high"}),
        ({"effort": "low"}, {}, {"role": "REVIEW", "effort": "low"}),
        ({"role": "FAST", "effort": "low"}, {"role": "DEEP"}, {"role": "DEEP", "effort": "low"}),
        ({"role": "FAST", "effort": "low"}, {"effort": "inherit"}, {"role": "FAST", "effort": "inherit"}),
    ],
)
def test_project_precedence_is_field_wise(
    layout: Layout,
    defaults: dict[str, str],
    specific: dict[str, str],
    expected: dict[str, str],
) -> None:
    _project(layout, {"defaults": defaults, "skills": {"makato-build:build-review": specific}})
    assert _resolve(layout) == expected


def test_partial_builtin_skill_inherits_builtin_defaults(layout: Layout) -> None:
    builtin = _built_in()
    builtin["skill_execution"]["defaults"] = {"role": "fast", "effort": "medium"}
    builtin["skill_execution"]["skills"]["makato-build:build-review"] = {"role": "review"}
    _write_yaml(layout.schema, builtin)
    assert _resolve(layout) == {"role": "REVIEW", "effort": "medium"}


def test_hard_defaults_remain_when_builtin_defaults_are_absent(layout: Layout) -> None:
    builtin = _built_in()
    del builtin["skill_execution"]["defaults"]
    _write_yaml(layout.schema, builtin)
    assert _resolve(layout, "build-verify") == {"role": "DEFAULT", "effort": "inherit"}


def test_legacy_project_workflow_does_not_need_execution(layout: Layout) -> None:
    _write_yaml(layout.repo / ".claude" / "workflow-schema.yml", {"version": "1.0", "artifacts": [{"id": "custom", "skill": "custom"}]})
    assert _resolve(layout) == {"role": "REVIEW", "effort": "high"}


def test_role_only_execution_override_needs_no_artifacts(layout: Layout) -> None:
    _project(layout, {"skills": {"makato-build:build-review": {"role": "custom_review-2"}}})
    assert _resolve(layout) == {"role": "CUSTOM_REVIEW-2", "effort": "high"}


def test_unquoted_off_is_a_string_not_yaml_11_false(layout: Layout) -> None:
    path = layout.repo / ".claude" / "workflow-schema.yml"
    path.parent.mkdir()
    path.write_text("skill_execution:\n  defaults: {effort: off}\n", encoding="utf-8")
    assert _resolve(layout)["effort"] == "off"


@pytest.mark.parametrize("skill", ["unknown", "makato-plan:missing", "../create-prd", "@plan"])
def test_unknown_or_unsafe_skill_is_rejected(layout: Layout, skill: str) -> None:
    with pytest.raises(SkillExecutionError, match="[Uu]nknown skill|Invalid skill"):
        _resolve(layout, skill)


def test_ambiguous_unqualified_name_requires_qualification(layout: Layout) -> None:
    builtin = _built_in()
    builtin["skill_execution"]["skills"]["makato-plan:build-review"] = {"role": "PLAN"}
    _write_yaml(layout.schema, builtin)
    with pytest.raises(SkillExecutionError, match="Ambiguous.*makato-build:build-review"):
        _resolve(layout)
    assert _resolve(layout, "makato-plan:build-review")["role"] == "PLAN"


def test_unknown_project_skill_override_is_not_silently_ignored(layout: Layout) -> None:
    _project(layout, {"skills": {"makato-build:build-reveiw": {"role": "REVIEW"}}})
    with pytest.raises(SkillExecutionError, match="unknown skill.*build-reveiw"):
        _resolve(layout)


def test_schema_consumers_can_resolve_custom_artifact_skills(layout: Layout) -> None:
    _project(layout, {"defaults": {"effort": "low"}, "skills": {"custom:review": {"role": "audit"}}})
    assert _resolve(layout, "custom:review", allow_unknown=True) == {
        "role": "AUDIT",
        "effort": "low",
    }
    assert _resolve(layout, "custom-check", allow_unknown=True) == {
        "role": "DEFAULT",
        "effort": "low",
    }


@pytest.mark.parametrize(
    ("section", "match"),
    [
        (None, "skill_execution: expected a mapping"),
        ([], "expected a mapping"),
        ({"defaults": None}, "defaults: expected a mapping"),
        ({"skills": []}, "skills: expected a mapping"),
        ({"provider": "local"}, "unknown execution field.*provider"),
        ({"defaults": {"model": "provider/model"}}, "unknown execution field.*model"),
        ({"skills": {"makato-build:build-review": {"thinking": "high"}}}, "unknown execution field.*thinking"),
        ({"skills": {"build-review": {"role": "REVIEW"}}}, "qualified plugin:skill"),
        ({"skills": {"makato-build:build-review": None}}, "expected a mapping"),
        ({"defaults": {1: "high"}}, "string keys"),
    ],
)
def test_invalid_execution_structure_is_actionable(
    layout: Layout,
    section: Any,
    match: str,
) -> None:
    _project(layout, section)
    with pytest.raises(SkillExecutionError, match=match) as error:
        _resolve(layout)
    assert str(layout.repo / ".claude" / "workflow-schema.yml") in str(error.value)


@pytest.mark.parametrize("role", ["", "@plan", "provider/model", "PLAN:high", "two words", "--model", False, 42, None, ["PLAN"]])
def test_invalid_roles_cannot_be_provider_or_effort_settings(layout: Layout, role: Any) -> None:
    _project(layout, {"defaults": {"role": role}})
    with pytest.raises(SkillExecutionError, match=r"defaults.role: expected a model role"):
        _resolve(layout)


@pytest.mark.parametrize("effort", ["ultra", "High", False, True, 3, None, ["high"]])
def test_invalid_effort_is_rejected(layout: Layout, effort: Any) -> None:
    _project(layout, {"defaults": {"effort": effort}})
    with pytest.raises(SkillExecutionError, match=r"defaults.effort: expected one of"):
        _resolve(layout)


@pytest.mark.parametrize(
    "text",
    [
        "skill_execution:\n  defaults: {role: PLAN, role: REVIEW}\n",
        "skill_execution:\n  skills:\n    'makato-build:build-review': {}\n    'makato-build:build-review': {}\n",
        "version: 1\nversion: 2\n",
    ],
)
def test_duplicate_yaml_keys_are_rejected_at_every_level(layout: Layout, text: str) -> None:
    path = layout.repo / ".claude" / "workflow-schema.yml"
    path.parent.mkdir()
    path.write_text(text, encoding="utf-8")
    with pytest.raises(SkillExecutionError, match="duplicate key"):
        _resolve(layout)


@pytest.mark.parametrize(
    "text",
    [
        "skill_execution: [\n",
        "!!python/object/apply:os.system ['touch should-not-exist']",
        "- not-a-workflow-mapping\n",
    ],
)
def test_malformed_or_unsafe_yaml_is_rejected(layout: Layout, text: str) -> None:
    path = layout.repo / ".claude" / "workflow-schema.yml"
    path.parent.mkdir()
    path.write_text(text, encoding="utf-8")
    with pytest.raises(SkillExecutionError, match="invalid YAML|expected a mapping"):
        _resolve(layout)
    assert not (layout.repo / "should-not-exist").exists()


def test_invalid_builtin_config_is_rejected(layout: Layout) -> None:
    _write_yaml(layout.schema, {"skill_execution": {"defaults": {"effort": "ultra"}}})
    with pytest.raises(SkillExecutionError, match="default-workflow-schema.yml.*effort"):
        _resolve(layout)


def test_missing_builtin_schema_error_includes_path(layout: Layout) -> None:
    missing = layout.schema.with_name("missing.yml")
    with pytest.raises(SkillExecutionError, match="Cannot read workflow schema.*missing.yml"):
        resolve_execution(layout.repo, "build-review", missing)


def test_inherit_omits_thinking_without_omitting_role(layout: Layout) -> None:
    _project(layout, {"defaults": {"role": "CUSTOM", "effort": "inherit"}})
    command, _, _ = _command(layout)
    assert command[command.index("--model") + 1] == "@custom"
    assert "--thinking" not in command[:-1]


def test_repo_configuration_is_not_replaced_by_worktree_configuration(layout: Layout) -> None:
    worktree = layout.repo.parent / "separate worktree"
    worktree.mkdir()
    _project(layout, {"defaults": {"role": "ROOT_ROLE", "effort": "low"}})
    _write_yaml(worktree / ".claude" / "workflow-schema.yml", {"skill_execution": {"defaults": {"role": "WRONG", "effort": "max"}}})
    env = _environment(layout)
    env.update({"WORKTREE_PATH": str(worktree), "SOME_CALLER_STATE": "retained"})
    command, child, execution = _command(layout, "--cwd", str(worktree), env=env)
    assert execution == {"role": "ROOT_ROLE", "effort": "low"}
    assert command[command.index("--cwd") + 1] == str(worktree)
    assert child["REPO_ROOT"] == str(layout.repo)
    assert child["WORKTREE_PATH"] == str(worktree)
    assert child["PWD"] == str(worktree)
    assert child["SOME_CALLER_STATE"] == "retained"
    metadata = _metadata(command[-1])
    assert metadata["repo_root"] == str(layout.repo)
    assert metadata["cwd"] == str(worktree)
    assert metadata["WORKTREE_PATH"] == str(worktree)


def test_context_is_verbatim_and_skill_arguments_never_become_harness_flags(layout: Layout) -> None:
    context = "full context\r\n--model @different\n$(touch injected)\n'quoted'\tΩ"
    context_file = layout.repo / "caller context.txt"
    context_file.write_bytes(context.encode())
    dangerous = ("--model", "@different", "--thinking", "off", "--yolo", "$(touch injected)", "; exit 13", "path with spaces", "--", "")
    command, _, _ = _command(layout, "--context-file", str(context_file), data=dangerous)
    assert _metadata(command[-1])["skill_args"] == list(dangerous)
    assert context in command[-1]
    assert command[:-1].count("--model") == 1
    assert command[command.index("--model") + 1] == "@review"
    assert "--yolo" not in command[:-1]
    assert not (layout.repo / "injected").exists()


def test_interactive_mode_keeps_interviews_and_requires_clean_context_handoffs(layout: Layout) -> None:
    command, env, _ = _command(layout, "--interactive")
    assert "--print" not in command[:-1]
    assert "--interactive" in _metadata(command[-1])["next_skill_command_prefix"]
    assert "MAKATO_HEADLESS" not in env or env["MAKATO_HEADLESS"] == os.environ.get("MAKATO_HEADLESS")
    assert "Do NOT invoke MAKATO_SKILL_RUNNER" in command[-1]
    assert "Next (clean context)" in command[-1]
    assert "MUST launch a separate process through MAKATO_SKILL_RUNNER" not in command[-1]


def test_print_mode_keeps_runner_dispatch_contract(layout: Layout) -> None:
    command, _, _ = _command(layout)
    assert "--print" in command[:-1]
    assert "MUST launch a separate process through MAKATO_SKILL_RUNNER" in command[-1]
    assert "Do NOT invoke MAKATO_SKILL_RUNNER" not in command[-1]


def test_installed_non_sibling_plugin_roots_can_be_explicit(layout: Layout) -> None:
    installed = layout.repo.parent / "cache" / "suite___plan___1.2.3"
    installed.parent.mkdir()
    shutil.move(str(layout.plan), installed)
    env = _environment(layout)
    env["MAKATO_PLAN_ROOT"] = str(installed)
    command, child, _ = _command(layout, skill="makato-plan:create-prd", env=env)
    dirs = [command[index + 1] for index, value in enumerate(command[:-1]) if value == "--plugin-dir"]
    assert dirs == [str(installed), str(layout.build)]
    assert child["MAKATO_PLAN_ROOT"] == str(installed)
    assert _metadata(command[-1])["skill_file"] == str(installed / "skills" / "create-prd" / "SKILL.md")


def test_missing_installed_plugin_reports_its_root_variable(layout: Layout) -> None:
    shutil.rmtree(layout.plan)
    with pytest.raises(SkillExecutionError, match="set MAKATO_PLAN_ROOT"):
        _command(layout, skill="makato-plan:create-prd")


def test_missing_skill_file_is_an_error_not_an_empty_prompt(layout: Layout) -> None:
    (layout.build / "skills" / "build-review" / "SKILL.md").unlink()
    with pytest.raises(SkillExecutionError, match="Cannot read skill file.*SKILL.md"):
        _command(layout)


def test_missing_verification_policy_fails_before_launch(layout: Layout) -> None:
    (layout.build / "config" / "verification-ownership.md").unlink()
    with pytest.raises(SkillExecutionError, match="Cannot read verification ownership policy"):
        _command(layout)


def test_unqualified_launcher_argument_is_rejected(layout: Layout) -> None:
    with pytest.raises(SkillExecutionError, match="requires a qualified plugin:skill"):
        _command(layout, skill="build-review")


def test_dry_run_cli_resolves_config_without_executing_harness(layout: Layout) -> None:
    result = subprocess.run(
        [sys.executable, str(_RUNNER_PATH), "--repo-root", str(layout.repo), "--dry-run", "--harness", "/nonexistent/harness", "makato-build:build-review", "--", "--model", "bad"],
        env=_environment(layout),
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode == 0, result.stderr
    payload = json.loads(result.stdout)
    assert payload["execution"] == {"role": "REVIEW", "effort": "high"}
    assert payload["argv"][0] == "/nonexistent/harness"
    assert _metadata(payload["argv"][-1])["skill_args"] == ["--model", "bad"]
    assert payload["env"]["MAKATO_SKILL_RESOLVED"] == "makato-build:build-review"


def test_cli_configuration_errors_do_not_launch_harness(layout: Layout) -> None:
    _project(layout, {"defaults": {"effort": "ultra"}})
    result = subprocess.run(
        [sys.executable, str(_RUNNER_PATH), "--repo-root", str(layout.repo), "--harness", "/nonexistent/harness", "makato-build:build-review"],
        env=_environment(layout),
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode == 2
    assert "defaults.effort" in result.stderr and "cannot launch harness" not in result.stderr


@pytest.mark.parametrize(("binary", "status"), [("true", 0), ("false", 1)])
def test_real_exec_preserves_harness_exit_status(layout: Layout, binary: str, status: int) -> None:
    harness = shutil.which(binary)
    assert harness is not None
    result = subprocess.run(
        [sys.executable, str(_RUNNER_PATH), "--repo-root", str(layout.repo), "--harness", harness, "makato-build:build-review"],
        env=_environment(layout),
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode == status
    assert result.stdout == "" and result.stderr == ""


def test_real_exec_preserves_harness_stderr_without_wrapping(layout: Layout) -> None:
    harness = shutil.which("env")
    assert harness is not None
    command, child, _ = _command(layout, "--harness", harness)
    direct = subprocess.run(command, env=child, cwd=layout.repo, capture_output=True, check=False)
    launched = subprocess.run(
        [sys.executable, str(_RUNNER_PATH), "--repo-root", str(layout.repo), "--harness", harness, "makato-build:build-review"],
        env=_environment(layout),
        capture_output=True,
        check=False,
    )
    assert direct.returncode != 0
    assert launched.returncode == direct.returncode
    assert launched.stdout == direct.stdout
    assert launched.stderr == direct.stderr


def test_missing_harness_reports_127(layout: Layout) -> None:
    result = subprocess.run(
        [sys.executable, str(_RUNNER_PATH), "--repo-root", str(layout.repo), "--harness", "/nonexistent/harness", "makato-build:build-review"],
        env=_environment(layout),
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode == 127
    assert "cannot launch harness" in result.stderr


def _progress_environment(layout: Layout) -> dict[str, str]:
    env = _environment(layout)
    orchestrate = _HERE.parents[1] / "makato-orchestrate"
    stub = layout.repo / "github comments"
    stub.mkdir()
    env.update(
        {
            "KEY": "shared-feature",
            "ISSUE_NUMBER": "321",
            "REPO": "example/work-items",
            "MAKATO_ORCHESTRATE_ROOT": str(orchestrate),
            "MAKATO_PC_GH_STUB": str(stub),
            "SPECS_DIR": str(layout.repo / "specs"),
        }
    )
    subprocess.run(
        ["bash", str(orchestrate / "shared" / "workflow-state.sh"), "init", env["KEY"], env["REPO"], "feat/progress", env["ISSUE_NUMBER"]],
        cwd=layout.repo,
        env=env,
        capture_output=True,
        text=True,
        check=True,
    )
    return env


def _launch(layout: Layout, env: dict[str, str], harness: str, skill: str = "makato-build:build-review", *options: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(_RUNNER_PATH), "--repo-root", str(layout.repo), "--harness", harness, *options, skill],
        env=env,
        capture_output=True,
        text=True,
        check=False,
    )


def test_launcher_brackets_each_skill_in_the_same_issue_comment(layout: Layout) -> None:
    env = _progress_environment(layout)
    harness = layout.repo / "observe-progress"
    harness.write_text(
        f"#!{sys.executable}\n"
        "import os\nfrom pathlib import Path\n"
        "comments = list(Path(os.environ['MAKATO_PC_GH_STUB']).glob('comment-*.md'))\n"
        "assert len(comments) == 1, 'START must be published before execution'\n"
        "body = comments[0].read_text()\n"
        "assert 'START: build-review' in body and 'DONE: build-review' not in body\n"
        "print('skill output remains unchanged')\n",
        encoding="utf-8",
    )
    harness.chmod(0o755)
    first = _launch(layout, env, str(harness))
    assert first.returncode == 0, first.stderr
    assert first.stdout == "skill output remains unchanged\n"
    second = _launch(layout, env, shutil.which("false") or "false", "makato-plan:create-prd")
    assert second.returncode == 1, second.stderr
    comments = list(Path(env["MAKATO_PC_GH_STUB"]).glob("comment-*.md"))
    assert len(comments) == 1
    body = comments[0].read_text()
    assert body.index("START: build-review") < body.index("DONE: build-review") < body.index("START: create-prd") < body.index("DONE: create-prd")
    assert "process exited 0" in body and "process exited 1" in body
    state = json.loads((layout.repo / "specs" / env["KEY"] / "workflow-state-321.json").read_text())
    assert comments[0].name == f"comment-{state['progress_comment_id']}.md"


@pytest.mark.parametrize("case", ["disabled", "dry-run", "github-unavailable"])
def test_progress_cannot_change_execution_or_dry_run(layout: Layout, case: str) -> None:
    env = _progress_environment(layout)
    options = ("--dry-run",) if case == "dry-run" else ()
    if case == "disabled":
        env["MAKATO_PROGRESS_COMMENT_DISABLE"] = "1"
    if case == "github-unavailable":
        env["MAKATO_PC_GH_FAIL"] = "1"
    result = _launch(layout, env, shutil.which("false") or "false", "makato-build:build-review", *options)
    assert result.returncode == (0 if case == "dry-run" else 1), result.stderr
    assert not list(Path(env["MAKATO_PC_GH_STUB"]).glob("comment-*.md"))
    if case == "github-unavailable":
        assert "WARN" in result.stderr


def test_progress_records_launch_failure_without_claiming_skill_success(layout: Layout) -> None:
    env = _progress_environment(layout)
    result = _launch(layout, env, "/nonexistent/harness")
    assert result.returncode == 127
    comments = list(Path(env["MAKATO_PC_GH_STUB"]).glob("comment-*.md"))
    assert len(comments) == 1
    body = comments[0].read_text()
    assert "START: build-review" in body and "DONE: build-review" in body
    assert "could not launch" in body


def test_progress_forwards_termination_and_records_the_signal(layout: Layout) -> None:
    env = _progress_environment(layout)
    ready = layout.repo / "child-ready"
    harness = layout.repo / "wait-for-termination"
    harness.write_text(
        f"#!{sys.executable}\nimport os, time\nfrom pathlib import Path\nPath({str(ready)!r}).write_text(str(os.getpid()))\ntime.sleep(60)\n",
        encoding="utf-8",
    )
    harness.chmod(0o755)
    process = subprocess.Popen(
        [sys.executable, str(_RUNNER_PATH), "--repo-root", str(layout.repo), "--harness", str(harness), "makato-build:build-review"],
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    try:
        deadline = time.monotonic() + 10
        while not ready.exists() and process.poll() is None and time.monotonic() < deadline:
            time.sleep(0.02)
        assert ready.exists(), "skill did not reach its running state"
        process.terminate()
        stdout, stderr = process.communicate(timeout=10)
        assert process.returncode == 143, (stdout, stderr)
        child_pid = int(ready.read_text())
        with pytest.raises(ProcessLookupError):
            os.kill(child_pid, 0)
        comments = list(Path(env["MAKATO_PC_GH_STUB"]).glob("comment-*.md"))
        assert len(comments) == 1
        assert "process terminated by signal 15" in comments[0].read_text()
    finally:
        if process.poll() is None:
            process.kill()
            process.communicate()


def test_declared_custom_artifact_override_does_not_block_builtin_dispatch(layout: Layout) -> None:
    _write_yaml(
        layout.repo / ".claude" / "workflow-schema.yml",
        {
            "artifacts": [{"id": "audit", "skill": "custom:audit"}],
            "skill_execution": {"skills": {"custom:audit": {"role": "AUDIT", "effort": "low"}}},
        },
    )
    assert _resolve(layout) == {"role": "REVIEW", "effort": "high"}
    with pytest.raises(SkillExecutionError, match="Unknown skill"):
        _resolve(layout, "custom:audit")
