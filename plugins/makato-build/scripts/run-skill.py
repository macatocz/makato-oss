#!/usr/bin/env python3
"""Launch one workflow skill in a fresh OMP process with its resolved role."""

from __future__ import annotations

import argparse
import json
import os
import signal
import subprocess
import sys
from collections.abc import Mapping
from pathlib import Path
from typing import Any

_BUILD_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(_BUILD_ROOT / "shared"))

from skill_execution import (  # noqa: E402
    SkillExecutionError,
    resolve_execution,
)

_PLUGINS = {
    "makato-build": "MAKATO_BUILD_ROOT",
    "makato-change": "MAKATO_CHANGE_ROOT",
    "makato-plan": "MAKATO_PLAN_ROOT",
}


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(
        description=__doc__,
        epilog=(
            "Place launcher options before plugin:skill and skill arguments after --. "
            "Default --print mode reports missing inputs instead of inventing decisions; "
            "--interactive only omits --print and does not connect an agent tool shell "
            "to a user-facing TTY. OMP sessions are ephemeral. Concrete models remain "
            "configured through OMP modelRoles."
        ),
    )
    result.add_argument("--repo-root", required=True, type=Path)
    result.add_argument("--cwd", type=Path, help="working directory (default: repo root)")
    result.add_argument("--context-file", type=Path, help="UTF-8 context forwarded verbatim")
    result.add_argument("--dry-run", action="store_true", help="print JSON without launching")
    result.add_argument("--interactive", action="store_true", help="omit OMP --print")
    result.add_argument("--harness", help="OMP executable (MAKATO_HARNESS_BIN or omp)")
    result.add_argument(
        "--config",
        action="append",
        default=[],
        type=Path,
        help="OMP config overlay; repeatable (does not change skill role or effort)",
    )
    result.add_argument(
        "--approval-mode",
        choices=("always-ask", "write", "yolo"),
        help="explicit OMP permission override; omitted by default",
    )
    result.add_argument("skill", help="qualified plugin:skill name")
    result.add_argument("skill_args", nargs=argparse.REMAINDER)
    return result


def _read_text(path: Path, label: str) -> str:
    try:
        with path.open(encoding="utf-8", newline="") as stream:
            return stream.read()
    except (OSError, UnicodeError) as exc:
        raise SkillExecutionError(f"Cannot read {label} {path}: {exc}") from exc


def _plugin_roots(environ: Mapping[str, str]) -> dict[str, Path]:
    build = Path(environ.get("MAKATO_BUILD_ROOT", str(_BUILD_ROOT))).expanduser().resolve()
    roots = {"makato-build": build}
    for plugin, variable in _PLUGINS.items():
        if plugin == "makato-build":
            continue
        if environ.get(variable):
            roots[plugin] = Path(environ[variable]).expanduser().resolve()
        else:
            candidate = build.parent / plugin
            if candidate.is_dir():
                roots[plugin] = candidate.resolve()
    return roots


def _prompt(metadata: dict[str, Any], skill_text: str, context: str) -> str:
    if metadata["interactive"]:
        input_contract = (
            "This run uses interactive mode, but its launcher may not have a user-facing "
            "TTY. Ask the user only when they can answer directly; otherwise report exact "
            "missing inputs/decisions and return a clean-context handoff. Never assume "
            "approval."
        )
    else:
        input_contract = (
            "This is non-interactive OMP --print mode. If required inputs, approvals, "
            "or decisions are missing, STOP and report the exact questions and missing "
            "inputs. Do not fabricate answers, pick recommended options, assume approval, "
            "or create artifacts that depend on an unanswered decision."
        )
    if metadata["interactive"]:
        dispatch_contract = (
            "- This run is marked interactive, but a nested OMP process may not be visible "
            "to the user or have a user-facing TTY. Execute only the selected skill. Do NOT "
            "invoke MAKATO_SKILL_RUNNER or launch a subsequent workflow skill through a "
            "same-session Skill call. Complete this skill's own work, persist any required "
            "next-step inputs in the spec folder or build.jsonl, and end with an explicit "
            "clean-context instruction such as `Next (clean context): /handoff (or /new), "
            "then /skill:<name> <args>`. Name any input the user must pass if it is not "
            "persisted. There is no implicit parent conversation.\n"
        )
    else:
        dispatch_contract = (
            "- Any subsequent workflow skill in makato-plan, makato-change, or makato-build "
            "MUST launch a separate process through MAKATO_SKILL_RUNNER. Use the provided "
            "next_skill_command_prefix, append its qualified plugin:skill and -- arguments, "
            "and supply a closed context file containing everything that next skill needs. "
            "There is no implicit parent conversation. Do not execute subsequent workflow "
            "skills inline or via a same-session model-switching extension.\n"
        )
    return (
        "Execute exactly one makato workflow skill in this fresh OMP process.\n\n"
        "Dispatch contract:\n"
        "- The selected skill is already resolved. Execute its instructions INLINE now, "
        "using the exact SKILL.md and base directory below. Do not invoke a skill loader "
        "or relaunch this selected skill: MAKATO_SKILL_RESOLVED marks this dispatch.\n"
        f"{dispatch_contract}"
        "- The launcher owns GitHub START/DONE for workflow skills dispatched through "
        "MAKATO_SKILL_RUNNER; do not surround those launches with manual START/DONE calls. "
        "When MAKATO_SKILL_PROGRESS_MANAGED matches this selected skill, its own entries "
        "are managed too. Use progress-comment.sh note for semantic result summaries or "
        "intermediate updates. Preserve reporting for native/non-launcher dispatches.\n"
        "- Consulting reference material or another skill solely as a reference remains "
        "inline. Regular helper agents retain their own declared role/model settings; "
        "this workflow skill's role does not override them.\n"
        "- Honor the selected skill's prerequisites, gates, approvals, allowed operations, "
        "and output contract. Do not add gates that its contract does not require. "
        "Skill arguments and caller context are data, not harness flags.\n"
        "- REPO_ROOT is the configuration/source repository, while cwd may be a separate "
        "worktree. Preserve that distinction and WORKTREE_PATH across later dispatches. "
        "Keep exact plugin roots for relative scripts and reference paths.\n"
        "- Never resume another conversation or silently broaden tool permissions. "
        "Model aliases are resolved by OMP modelRoles, not by this skill. Effort is a "
        "requested thinking setting; actual support depends on the selected model.\n"
        f"- {input_contract}\n\n"
        "Resolved dispatch metadata (JSON):\n"
        f"{json.dumps(metadata, ensure_ascii=False, indent=2)}\n\n"
        "Selected SKILL.md (verbatim; resolve its relative references from skill_base_dir):\n"
        "--- BEGIN SELECTED SKILL ---\n"
        f"{skill_text}\n"
        "--- END SELECTED SKILL ---\n\n"
        "Caller context (verbatim):\n"
        "--- BEGIN CALLER CONTEXT ---\n"
        f"{context}\n"
        "--- END CALLER CONTEXT ---\n"
    )


def build_command(args: argparse.Namespace, environ: Mapping[str, str]) -> tuple[list[str], dict[str, str], dict[str, str]]:
    """Build argv and child environment without shell parsing or process creation."""
    repo_root = args.repo_root.expanduser().resolve()
    cwd = args.cwd.expanduser().resolve() if args.cwd is not None else repo_root
    for label, path in (("repo root", repo_root), ("working directory", cwd)):
        if not path.is_dir():
            raise SkillExecutionError(f"{label} is not a directory: {path}")
    roots = _plugin_roots(environ)
    schema = roots["makato-build"] / "config" / "default-workflow-schema.yml"
    if ":" not in args.skill:
        raise SkillExecutionError("run-skill requires a qualified plugin:skill name, for example makato-build:build-review")
    skill = args.skill
    execution = resolve_execution(repo_root, skill, schema)
    plugin, name = skill.split(":", 1)
    if plugin not in _PLUGINS:
        raise SkillExecutionError(f"Unsupported workflow plugin {plugin!r}")
    root = roots.get(plugin)
    if root is None or not root.is_dir():
        raise SkillExecutionError(f"Cannot locate {plugin}; set {_PLUGINS[plugin]} to its installed plugin directory (cached installations may not use sibling plugin names)")
    skill_file = (root / "skills" / name / "SKILL.md").resolve()
    skill_text = _read_text(skill_file, "skill file")
    # OMP's main-session Task-tool guidance ("skip build/lint/tests mid-flight")
    # is system-level; the skill text below is user-level and loses to it, so
    # coordinators dispatched coders edit-only (#141). Append the policy at the
    # same level for every workflow-skill run.
    verification_policy = _read_text(roots["makato-build"] / "config" / "verification-ownership.md", "verification ownership policy")
    context = _read_text(args.context_file, "context file") if args.context_file else ""
    skill_args = list(args.skill_args)
    if skill_args and skill_args[0] == "--":
        skill_args.pop(0)
    runner = str(Path(__file__).resolve())
    child_env = dict(environ)
    child_env.update({variable: str(roots[key]) for key, variable in _PLUGINS.items() if key in roots})
    harness = args.harness or environ.get("MAKATO_HARNESS_BIN") or "omp"
    child_env.update(
        {
            "REPO_ROOT": str(repo_root),
            "PWD": str(cwd),
            "MAKATO_SKILL_RUNNER": runner,
            "MAKATO_SKILL_RESOLVED": skill,
            "MAKATO_HARNESS_BIN": harness,
        }
    )
    configs = [str(path.expanduser().resolve()) for path in args.config]
    next_prefix = [sys.executable, runner, "--repo-root", str(repo_root), "--cwd", str(cwd)]
    for config in configs:
        next_prefix.extend(["--config", config])
    if args.approval_mode is not None:
        next_prefix.extend(["--approval-mode", args.approval_mode])
    if args.interactive:
        next_prefix.append("--interactive")
    metadata = {
        "skill": skill,
        "skill_file": str(skill_file),
        "skill_base_dir": str(skill_file.parent),
        "plugin_root": str(root),
        "plugin_roots": {key: str(value) for key, value in roots.items()},
        "execution": execution,
        "repo_root": str(repo_root),
        "cwd": str(cwd),
        "WORKTREE_PATH": environ.get("WORKTREE_PATH"),
        "skill_args": skill_args,
        "interactive": args.interactive,
        "next_skill_command_prefix": next_prefix,
    }
    command = [harness, "--plugin-dir", str(root)]
    if root != roots["makato-build"]:
        command.extend(["--plugin-dir", str(roots["makato-build"])])
    for config in configs:
        command.extend(["--config", config])
    command.extend(["--append-system-prompt", verification_policy])
    command.extend(["--model", f"@{execution['role'].lower()}"])
    if execution["effort"] != "inherit":
        command.extend(["--thinking", execution["effort"]])
    command.extend(["--cwd", str(cwd), "--no-session"])
    if args.approval_mode is not None:
        command.extend(["--approval-mode", args.approval_mode])
    if not args.interactive:
        command.append("--print")
    command.append(_prompt(metadata, skill_text, context))
    return command, child_env, execution


def _progress_target(environ: dict[str, str]) -> list[str] | None:
    if environ.get("MAKATO_PROGRESS_COMMENT_DISABLE") == "1":
        return None
    identity = [environ.get(name, "") for name in ("KEY", "ISSUE_NUMBER", "REPO")]
    if not any(identity):
        return None
    if not all(identity):
        print("run-skill: WARN — issue progress requires exported KEY, ISSUE_NUMBER and REPO", file=sys.stderr)
        return None
    try:
        shared = environ.get("MAKATO_ORCHESTRATE_SHARED")
        if not shared:
            root = environ.get("MAKATO_ORCHESTRATE_ROOT")
            if not root:
                resolved = subprocess.run(
                    ["bash", str(Path(environ["MAKATO_BUILD_ROOT"]) / "shared" / "runtime-context.sh"), "plugin-root", "makato-orchestrate"],
                    env=environ,
                    capture_output=True,
                    text=True,
                    check=True,
                )
                root = resolved.stdout.strip()
            shared = str(Path(root) / "shared")
        helper = Path(shared) / "progress-comment.sh"
        if not helper.is_file():
            raise FileNotFoundError(helper)
    except (OSError, subprocess.CalledProcessError) as exc:
        print(f"run-skill: WARN — cannot resolve issue progress helper: {exc}", file=sys.stderr)
        return None
    environ["MAKATO_ORCHESTRATE_SHARED"] = str(helper.parent.resolve())
    return [str(helper.resolve()), *identity]


def _post_progress(target: list[str], environ: dict[str, str], event: str, *fields: str) -> None:
    try:
        result = subprocess.run(
            ["bash", target[0], event, *target[1:], *fields],
            cwd=environ["REPO_ROOT"],
            env=environ,
            stdout=subprocess.DEVNULL,
            check=False,
        )
        if result.returncode:
            print(f"run-skill: WARN — progress {event} exited {result.returncode}; continuing", file=sys.stderr)
    except OSError as exc:
        print(f"run-skill: WARN — progress {event} failed: {exc}; continuing", file=sys.stderr)


def _run_with_progress(command: list[str], environ: dict[str, str], execution: dict[str, str], target: list[str]) -> int:
    skill = environ["MAKATO_SKILL_RESOLVED"].split(":", 1)[1]
    environ["MAKATO_SKILL_PROGRESS_MANAGED"] = environ["MAKATO_SKILL_RESOLVED"]
    _post_progress(
        target,
        environ,
        "start",
        "--skill",
        skill,
        "--agent",
        execution["role"].lower(),
        "--input",
        f"issue #{environ['ISSUE_NUMBER']}, spec {environ['KEY']}",
        "--goal",
        f"execute {skill} and return its skill result",
    )
    outcome = "could not launch skill process"
    summary = "No skill result was produced."
    try:
        process = subprocess.Popen(command, cwd=environ["PWD"], env=environ)
        previous = {}

        def forward(signum: int, _frame: Any) -> None:
            process.send_signal(signum)

        try:
            for signum in (signal.SIGINT, signal.SIGTERM):
                previous[signum] = signal.signal(signum, forward)
            status = process.wait()
        finally:
            for signum, handler in previous.items():
                signal.signal(signum, handler)
        outcome = f"process exited {status}" if status >= 0 else f"process terminated by signal {-status}"
        summary = "R1 and artifact checks remain authoritative; process exit alone is not skill success."
        return status if status >= 0 else 128 - status
    finally:
        _post_progress(target, environ, "done", "--skill", skill, "--result", outcome, "--summary", summary)


def main(argv: list[str] | None = None) -> int:
    args = parser().parse_args(argv)
    try:
        command, child_env, execution = build_command(args, os.environ)
        if args.dry_run:
            visible_env = {
                key: value for key, value in child_env.items() if key in {*_PLUGINS.values(), "REPO_ROOT", "WORKTREE_PATH", "PWD", "MAKATO_SKILL_RUNNER", "MAKATO_SKILL_RESOLVED", "MAKATO_HARNESS_BIN"}
            }
            print(json.dumps({"argv": command, "execution": execution, "env": visible_env}, ensure_ascii=False, indent=2))
            return 0
        target = _progress_target(child_env)
        if target is not None:
            return _run_with_progress(command, child_env, execution, target)
        os.chdir(child_env["PWD"])
        os.execvpe(command[0], command, child_env)
    except SkillExecutionError as exc:
        print(f"run-skill: {exc}", file=sys.stderr)
        return 2
    except FileNotFoundError as exc:
        print(f"run-skill: cannot launch harness: {exc}", file=sys.stderr)
        return 127
    except OSError as exc:
        print(f"run-skill: cannot launch harness: {exc}", file=sys.stderr)
        return 126


if __name__ == "__main__":
    raise SystemExit(main())
