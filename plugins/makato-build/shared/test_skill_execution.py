"""Behavior tests for execution settings and the separate-process skill launcher."""

from __future__ import annotations

import importlib.util
import json
import os
import shutil
import subprocess
import sys
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
    for key in ("MAKATO_PLAN_ROOT", "MAKATO_CHANGE_ROOT", "MAKATO_HARNESS_BIN"):
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


def test_interactive_mode_keeps_interviews_and_does_not_force_headless(layout: Layout) -> None:
    command, env, _ = _command(layout, "--interactive")
    assert "--print" not in command[:-1]
    assert "--interactive" in _metadata(command[-1])["next_skill_command_prefix"]
    assert "MAKATO_HEADLESS" not in env or env["MAKATO_HEADLESS"] == os.environ.get("MAKATO_HEADLESS")


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
