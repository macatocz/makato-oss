"""Tests for task_schedule.py — dependency-aware PO-agent task scheduling (#153).

Stdlib-only + pytest. Run from repo root:
  python3 -m pytest plugins/makato-orchestrate/scripts/tests/test_task_schedule.py -q
"""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path
from typing import Any

import pytest

SCRIPT = Path(__file__).resolve().parents[1] / "task_schedule.py"

# (number, mode, blockedBy) — blockedBy None omits the field.
TaskSpec = tuple[int, str, str | None]


def _plan(tasks: list[TaskSpec], run_order: str = "[tdd, goal]", placement: str = "body") -> str:
    front = ["---", "mode: mixed", f"runOrder: {run_order}", "---", ""] if placement == "frontmatter" else []
    mode_section = ["## Implementation Mode", "", "**Mode:** mixed"]
    if placement == "body":
        mode_section.append(f"**runOrder:** {run_order}")
    lines = [*front, "# Implementation Plan: #1", "", *mode_section, "", "## Tasks", ""]
    for number, mode, blocked_by in tasks:
        lines += [f"### Task {number}: Title {number}", f"**Mode:** {mode}"]
        if blocked_by is not None:
            lines.append(f"**blockedBy:** {blocked_by}")
        lines += ["**commitMessage:** `feat: task`", ""]
    return "\n".join([*lines, "## Acceptance Criteria Coverage", ""])


def _run(tmp_path: Path, command: str, plan: str, sub_tasks: list[dict[str, Any]]) -> subprocess.CompletedProcess[str]:
    plan_path = tmp_path / "plan-1.md"
    plan_path.write_text(plan, encoding="utf-8")
    return subprocess.run(
        [sys.executable, str(SCRIPT), command, "--plan", str(plan_path), "--state", "-"],
        input=json.dumps({"sub_tasks": sub_tasks}),
        capture_output=True,
        text=True,
        check=False,
    )


def _next(tmp_path: Path, plan: str, complete: set[int]) -> dict[str, Any]:
    rows = [{"id": task_id, "status": "complete"} for task_id in sorted(complete)]
    result = _run(tmp_path, "next", plan, rows)
    assert result.returncode == 0, result.stderr
    return json.loads(result.stdout)


def _passes(tmp_path: Path, plan: str) -> list[tuple[str, list[int]]]:
    complete: set[int] = set()
    passes: list[tuple[str, list[int]]] = []
    while (group := _next(tmp_path, plan, complete))["status"] == "ready":
        passes.append((group["mode"], group["task_ids"]))
        complete.update(group["task_ids"])
    return passes


def test_mixed_plan_alternates_modes_at_cross_mode_dependencies(tmp_path: Path) -> None:
    plan = _plan([(1, "tdd", "[]"), (2, "goal", "[1]"), (3, "tdd", "[2]"), (4, "tdd", "[1]"), (5, "goal", "[3]")])

    assert _passes(tmp_path, plan) == [("tdd", [1, 4]), ("goal", [2]), ("tdd", [3]), ("goal", [5])]


def test_single_mode_dependency_chain_runs_in_one_pass(tmp_path: Path) -> None:
    plan = _plan([(1, "tdd", "[]"), (2, "tdd", "[1]"), (3, "tdd", "[2]")], run_order="N/A")

    assert _passes(tmp_path, plan) == [("tdd", [1, 2, 3])]


@pytest.mark.parametrize("placement", ["body", "frontmatter"])
@pytest.mark.parametrize(
    ("run_order", "expected_mode"),
    [("[goal, tdd]", "goal"), ("[tdd, goal]", "tdd"), ("N/A", "tdd")],
)
def test_run_order_chooses_among_ready_modes(tmp_path: Path, placement: str, run_order: str, expected_mode: str) -> None:
    plan = _plan([(1, "tdd", "[]"), (2, "goal", "[]")], run_order=run_order, placement=placement)

    group = _next(tmp_path, plan, complete=set())

    assert (group["mode"], group["skill"]) == (expected_mode, f"build-implement-{expected_mode}")


def test_unfinished_tasks_are_rescheduled_but_accepted_ones_are_not(tmp_path: Path) -> None:
    plan = _plan([(1, "tdd", "[]"), (2, "tdd", "[1]"), (3, "tdd", "[]")])
    rows = [{"id": 1, "status": "complete"}, {"id": 2, "status": "in_progress"}, {"id": 3, "status": "pending"}]

    result = _run(tmp_path, "next", plan, rows)

    assert json.loads(result.stdout)["task_ids"] == [2, 3]


def test_all_tasks_complete_reports_complete(tmp_path: Path) -> None:
    plan = _plan([(1, "tdd", "[]"), (2, "goal", "[1]")])

    assert _next(tmp_path, plan, complete={1, 2}) == {"status": "complete", "task_ids": []}


@pytest.mark.parametrize(
    "tasks",
    [
        pytest.param([(1, "tdd", "[2]"), (2, "goal", "[1]")], id="cycle"),
        pytest.param([(1, "tdd", "[]"), (2, "tdd", "[3]")], id="unknown-dependency"),
        pytest.param([(1, "tdd", "[1]")], id="self-dependency"),
        pytest.param([(1, "tdd", "[]"), (2, "goal", None)], id="missing-blockedBy"),
        pytest.param([(1, "mixed", "[]")], id="invalid-task-mode"),
        pytest.param([(1, "tdd", "[]"), (3, "tdd", "[1]")], id="non-contiguous-numbering"),
        pytest.param([], id="no-tasks"),
    ],
)
@pytest.mark.parametrize("command", ["next", "sync"])
def test_invalid_plan_graph_is_rejected(tmp_path: Path, tasks: list[TaskSpec], command: str) -> None:
    result = _run(tmp_path, command, _plan(tasks), [])

    assert (result.returncode, result.stdout) == (2, "")


def test_invalid_run_order_is_rejected(tmp_path: Path) -> None:
    result = _run(tmp_path, "next", _plan([(1, "tdd", "[]")], run_order="[tdd, ui]"), [])

    assert (result.returncode, result.stdout) == (2, "")


def test_sync_refreshes_unfinished_rows_and_preserves_accepted_rows(tmp_path: Path) -> None:
    accepted = {"id": 1, "description": "Old title 1", "phase": "tdd", "status": "complete", "agent_result": {"status": "success"}}
    escalated = {"id": 2, "description": "Old title 2", "phase": "tdd", "status": "pending", "agent_result": {"status": "failure"}}
    removed = {"id": 4, "description": "Old title 4", "phase": "tdd", "status": "pending", "agent_result": None}
    plan = _plan([(1, "goal", "[]"), (2, "goal", "[1]"), (3, "tdd", "[2]")])

    result = _run(tmp_path, "sync", plan, [accepted, escalated, removed])

    assert result.returncode == 0, result.stderr
    assert json.loads(result.stdout) == [
        accepted,
        {**escalated, "description": "Title 2", "phase": "goal"},
        {"id": 3, "description": "Title 3", "phase": "tdd", "status": "pending", "agent_result": None},
    ]


def test_sync_rejects_plan_that_drops_an_accepted_task(tmp_path: Path) -> None:
    rows = [{"id": 1, "status": "complete"}, {"id": 2, "status": "complete"}]

    result = _run(tmp_path, "sync", _plan([(1, "tdd", "[]")]), rows)

    assert (result.returncode, result.stdout) == (2, "")
