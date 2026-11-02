"""Tests for task_schedule.py — dependency-aware PO-agent task scheduling (#153).

Stdlib-only + pytest. Run from repo root:
  python3 -m pytest plugins/makato-orchestrate/scripts/tests/test_task_schedule.py -q
"""

from __future__ import annotations

import hashlib
import json
import subprocess
import sys
from pathlib import Path
from typing import Any

import pytest

SCRIPT = Path(__file__).resolve().parents[1] / "task_schedule.py"

# (number, mode, blockedBy, optional reviewRisk, optional atomicGroup).
TaskSpec = tuple[Any, ...]


def _plan(tasks: list[TaskSpec], run_order: str = "[tdd, goal]", placement: str = "body") -> str:
    front = ["---", "mode: mixed", f"runOrder: {run_order}", "---", ""] if placement == "frontmatter" else []
    mode_section = ["## Implementation Mode", "", "**Mode:** mixed"]
    if placement == "body":
        mode_section.append(f"**runOrder:** {run_order}")
    lines = [*front, "# Implementation Plan: #1", "", *mode_section, "", "## Tasks", ""]
    for spec in tasks:
        number, mode, blocked_by, *metadata = spec
        lines += [f"### Task {number}: Title {number}", f"**Mode:** {mode}"]
        if blocked_by is not None:
            lines.append(f"**blockedBy:** {blocked_by}")
        if metadata and metadata[0] is not None:
            lines.append(f"**reviewRisk:** {metadata[0]}")
        if len(metadata) > 1 and metadata[1] is not None:
            lines.append(f"**atomicGroup:** {metadata[1]}")
        lines += ["**commitMessage:** `feat: task`", ""]
    return "\n".join([*lines, "## Acceptance Criteria Coverage", ""])


def _run(
    tmp_path: Path,
    command: str,
    plan: str,
    sub_tasks: list[dict[str, Any]],
    extra_args: list[str] | None = None,
    state_path: Path | None = None,
) -> subprocess.CompletedProcess[str]:
    plan_path = tmp_path / "plan-1.md"
    plan_path.write_text(plan, encoding="utf-8")
    state_arg = str(state_path) if state_path is not None else "-"
    return subprocess.run(
        [sys.executable, str(SCRIPT), command, "--plan", str(plan_path), "--state", state_arg, *(extra_args or [])],
        input=None if state_path is not None else json.dumps({"sub_tasks": sub_tasks}),
        capture_output=True,
        text=True,
        check=False,
    )


def _fingerprint(label: str) -> str:
    return hashlib.sha256(label.encode("utf-8")).hexdigest()


def _rows(complete: set[int]) -> list[dict[str, Any]]:
    return [{"id": task_id, "status": "complete"} for task_id in sorted(complete)]


def _checkpoint(
    tmp_path: Path,
    plan: str,
    complete: set[int],
    checkpoint_path: Path,
    fingerprint: str,
) -> dict[str, Any]:
    result = _run(
        tmp_path,
        "checkpoint",
        plan,
        _rows(complete),
        ["--checkpoint", str(checkpoint_path), "--fingerprint", fingerprint],
    )
    assert result.returncode == 0, result.stderr
    return json.loads(result.stdout)


def _ledger_verifier(path: Path) -> Path:
    path.write_text(
        """import json
import sys

arguments = dict(zip(sys.argv[2::2], sys.argv[3::2]))
with open(arguments["--state"], encoding="utf-8") as ledger:
    receipt = json.load(ledger)["checkpoint_receipts"][-1]
if (
    ",".join(receipt["task_ids"]) != arguments["--task-ids"]
    or receipt["input_fingerprint"] != arguments["--fingerprint"]
    or receipt["pass_id"] != arguments["--pass-id"]
):
    print("checkpoint receipt mismatch", file=sys.stderr)
    raise SystemExit(2)
json.dump(receipt, sys.stdout)
""",
        encoding="utf-8",
    )
    return path


def _accept_checkpoint(
    tmp_path: Path,
    plan: str,
    checkpoint_path: Path,
    fingerprint: str,
    task_ids: list[int],
    state_path: Path,
    review_state: Path,
    review_loop: Path,
    receipt: dict[str, Any],
) -> subprocess.CompletedProcess[str]:
    return _run(
        tmp_path,
        "accept-checkpoint",
        plan,
        [],
        [
            "--checkpoint",
            str(checkpoint_path),
            "--fingerprint",
            fingerprint,
            "--task-ids",
            ",".join(str(task_id) for task_id in task_ids),
            "--review-loop",
            str(review_loop),
            "--review-state",
            str(review_state),
            "--worktree",
            str(tmp_path / "worktree"),
            "--review-base",
            "base-commit",
            "--receipt",
            json.dumps(receipt, separators=(",", ":")),
        ],
        state_path=state_path,
    )


def _next(tmp_path: Path, plan: str, complete: set[int]) -> dict[str, Any]:
    rows = [{"id": task_id, "status": "complete"} for task_id in sorted(complete)]
    result = _run(tmp_path, "next", plan, rows)
    assert result.returncode == 0, result.stderr
    return json.loads(result.stdout)


def _passes(tmp_path: Path, plan: str) -> list[tuple[str, list[int]]]:
    complete: set[int] = set()
    tasks: list[tuple[str, list[int]]] = []
    while (task := _next(tmp_path, plan, complete))["status"] == "ready":
        tasks.append((task["mode"], task["task_ids"]))
        complete.update(task["task_ids"])
    return tasks


def test_mixed_plan_dispatches_one_ready_task_per_pass(tmp_path: Path) -> None:
    plan = _plan([(1, "tdd", "[]"), (2, "goal", "[1]"), (3, "tdd", "[2]"), (4, "tdd", "[1]"), (5, "goal", "[3]")])

    assert _passes(tmp_path, plan) == [
        ("tdd", [1]),
        ("tdd", [4]),
        ("goal", [2]),
        ("tdd", [3]),
        ("goal", [5]),
    ]


def test_single_mode_dependency_chain_dispatches_one_task_per_pass(tmp_path: Path) -> None:
    plan = _plan([(1, "tdd", "[]"), (2, "tdd", "[1]"), (3, "tdd", "[2]")], run_order="N/A")

    assert _passes(tmp_path, plan) == [("tdd", [1]), ("tdd", [2]), ("tdd", [3])]


@pytest.mark.parametrize("placement", ["body", "frontmatter"])
@pytest.mark.parametrize(
    ("run_order", "expected_mode"),
    [("[goal, tdd]", "goal"), ("[tdd, goal]", "tdd"), ("N/A", "tdd")],
)
def test_run_order_chooses_among_ready_modes(tmp_path: Path, placement: str, run_order: str, expected_mode: str) -> None:
    plan = _plan([(1, "tdd", "[]"), (2, "goal", "[]")], run_order=run_order, placement=placement)

    task = _next(tmp_path, plan, complete=set())

    expected_task_id = 2 if expected_mode == "goal" else 1
    assert (task["mode"], task["skill"], task["task_ids"]) == (expected_mode, f"build-implement-{expected_mode}", [expected_task_id])


def test_unfinished_tasks_are_rescheduled_but_accepted_ones_are_not(tmp_path: Path) -> None:
    plan = _plan([(1, "tdd", "[]"), (2, "tdd", "[1]"), (3, "tdd", "[]")])
    rows = [{"id": 1, "status": "complete"}, {"id": 2, "status": "in_progress"}, {"id": 3, "status": "pending"}]

    result = _run(tmp_path, "next", plan, rows)

    assert json.loads(result.stdout)["task_ids"] == [2]


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


def test_checkpoint_runs_after_about_three_dependency_coherent_tasks(tmp_path: Path) -> None:
    plan = _plan([(task_id, "tdd", "[]" if task_id == 1 else f"[{task_id - 1}]", "normal", "none") for task_id in range(1, 16)])
    checkpoint_path = tmp_path / "review" / "accepted_checkpoints.json"
    fingerprint = _fingerprint("first-review-input")

    first = _checkpoint(tmp_path, plan, {1}, checkpoint_path, fingerprint)
    second = _checkpoint(tmp_path, plan, {1, 2}, checkpoint_path, fingerprint)
    third = _checkpoint(tmp_path, plan, {1, 2, 3}, checkpoint_path, fingerprint)

    assert (first["due"], first["reason"], first["pending_ids"]) == (False, "below-threshold", [1])
    assert (second["due"], second["reason"], second["pending_ids"]) == (False, "below-threshold", [1, 2])
    assert (third["due"], third["reason"], third["task_ids"]) == (True, "completed-task-threshold", [1, 2, 3])
    assert third["accepted_ids"] == []
    assert not checkpoint_path.exists()


@pytest.mark.parametrize("risk", ["auth", "money", "persistence", "public-contract", "unrecognized-risk"])
def test_checkpoint_routes_high_or_unknown_risk_early(tmp_path: Path, risk: str) -> None:
    plan = _plan(
        [
            (1, "tdd", "[]", risk, "none"),
            (2, "tdd", "[1]", "normal", "none"),
        ]
    )
    decision = _checkpoint(
        tmp_path,
        plan,
        {1},
        tmp_path / "accepted_checkpoints.json",
        _fingerprint(risk),
    )

    expected_reason = f"risk:{risk}" if risk in {"auth", "money", "persistence", "public-contract"} else "risk:unknown"
    assert (decision["due"], decision["reason"], decision["task_ids"]) == (True, expected_reason, [1])


def test_checkpoint_does_not_review_mid_atomic_cutover(tmp_path: Path) -> None:
    plan = _plan(
        [
            (1, "tdd", "[]", "normal", "schema-writer-cutover"),
            (2, "tdd", "[1]", "normal", "schema-writer-cutover"),
            (3, "tdd", "[2]", "normal", "none"),
        ]
    )
    checkpoint_path = tmp_path / "accepted_checkpoints.json"
    fingerprint = _fingerprint("cutover")

    middle = _checkpoint(tmp_path, plan, {1}, checkpoint_path, fingerprint)
    boundary = _checkpoint(tmp_path, plan, {1, 2}, checkpoint_path, fingerprint)
    final = _checkpoint(tmp_path, plan, {1, 2, 3}, checkpoint_path, fingerprint)

    assert (middle["due"], middle["reason"], middle["pending_ids"]) == (
        False,
        "atomic-cutover-incomplete:schema-writer-cutover",
        [1],
    )
    assert (boundary["due"], boundary["reason"]) == (False, "below-threshold")
    assert (final["due"], final["reason"]) == (False, "final-review-required")


def test_omitted_atomic_boundary_conservatively_defers_checkpoint(tmp_path: Path) -> None:
    plan = _plan(
        [
            (1, "tdd", "[]", "normal", "none"),
            (2, "tdd", "[1]", "normal"),
            (3, "tdd", "[2]", "normal", "none"),
        ]
    )

    decision = _checkpoint(
        tmp_path,
        plan,
        {1},
        tmp_path / "accepted_checkpoints.json",
        _fingerprint("unknown-boundary"),
    )

    assert (decision["due"], decision["reason"]) == (False, "atomic-cutover-unknown")


def test_checkpoint_rejects_accepted_ids_without_receipt_metadata(tmp_path: Path) -> None:
    plan = _plan([(1, "tdd", "[]", "normal", "none"), (2, "tdd", "[1]", "normal", "none")])
    checkpoint_path = tmp_path / "review" / "accepted_checkpoints.json"
    checkpoint_path.parent.mkdir()
    checkpoint_path.write_text(
        json.dumps({"version": 1, "accepted_ids": [1], "fingerprint": None, "snapshot": None}),
        encoding="utf-8",
    )
    workflow_state = tmp_path / "workflow-state.json"
    workflow_state.write_text(json.dumps({"sub_tasks": _rows({1})}), encoding="utf-8")

    result = _run(
        tmp_path,
        "checkpoint",
        plan,
        [],
        ["--checkpoint", str(checkpoint_path), "--fingerprint", _fingerprint("invalid-checkpoint")],
        state_path=workflow_state,
    )

    assert result.returncode == 2
    assert "acceptance metadata is incomplete" in result.stderr


def test_checkpoint_rejects_completed_task_with_incomplete_dependencies(tmp_path: Path) -> None:
    plan = _plan([(1, "tdd", "[]"), (2, "tdd", "[1]"), (3, "tdd", "[2]")])
    result = _run(
        tmp_path,
        "checkpoint",
        plan,
        [{"id": 2, "status": "complete"}],
        ["--checkpoint", str(tmp_path / "accepted_checkpoints.json"), "--fingerprint", _fingerprint("bad-state")],
    )

    assert result.returncode == 2
    assert "incomplete dependencies" in result.stderr
    assert result.stdout == ""


def test_explicit_unknown_atomic_boundary_defers_until_final_review(tmp_path: Path) -> None:
    plan = _plan(
        [
            (1, "tdd", "[]", "normal", "unknown"),
            (2, "tdd", "[1]", "normal", "none"),
            (3, "tdd", "[2]", "normal", "none"),
        ]
    )
    decision = _checkpoint(
        tmp_path,
        plan,
        {1},
        tmp_path / "accepted_checkpoints.json",
        _fingerprint("explicit-unknown-boundary"),
    )

    assert (decision["due"], decision["reason"]) == (False, "atomic-cutover-unknown")
    final = _checkpoint(
        tmp_path,
        plan,
        {1, 2, 3},
        tmp_path / "accepted_checkpoints.json",
        _fingerprint("explicit-unknown-boundary"),
    )
    assert (final["due"], final["reason"]) == (False, "final-review-required")


def test_checkpoint_acceptance_verifies_ledger_and_skips_unchanged_diff(tmp_path: Path) -> None:
    plan = _plan([(task_id, "tdd", "[]" if task_id == 1 else f"[{task_id - 1}]", "normal", "none") for task_id in range(1, 16)])
    fingerprint = _fingerprint("accepted-input")
    checkpoint_path = tmp_path / "review" / "accepted_checkpoints.json"
    workflow_state = tmp_path / "workflow-state.json"
    workflow_state.write_text(json.dumps({"sub_tasks": _rows({1, 2, 3})}, indent=2) + "\n", encoding="utf-8")
    original_workflow_state = workflow_state.read_bytes()
    receipt = {
        "task_ids": ["1", "2", "3"],
        "input_fingerprint": fingerprint,
        "pass_id": "P-3",
        "scope": "delta",
        "checkpoint_verified": True,
        "final_review": False,
        "snapshot": "snapshot-three",
        "reviewer_id": "diff-reviewer",
        "independent": True,
        "dispositions": [],
    }
    review_state = tmp_path / "ledger.json"
    review_state.write_text(json.dumps({"checkpoint_receipts": [receipt]}), encoding="utf-8")
    review_loop = _ledger_verifier(tmp_path / "review_loop.py")

    accepted = _accept_checkpoint(
        tmp_path,
        plan,
        checkpoint_path,
        fingerprint,
        [1, 2, 3],
        workflow_state,
        review_state,
        review_loop,
        receipt,
    )

    assert accepted.returncode == 0, accepted.stderr
    assert json.loads(accepted.stdout) == {
        "status": "accepted",
        "task_ids": [1, 2, 3],
        "accepted_ids": [1, 2, 3],
        "fingerprint": fingerprint,
        "snapshot": "snapshot-three",
    }
    checkpoint_bytes = checkpoint_path.read_bytes()
    assert json.loads(checkpoint_bytes) == {
        "version": 1,
        "accepted_ids": [1, 2, 3],
        "fingerprint": fingerprint,
        "snapshot": "snapshot-three",
    }
    assert workflow_state.read_bytes() == original_workflow_state

    skipped = _checkpoint(tmp_path, plan, {1, 2, 3, 4}, checkpoint_path, fingerprint)
    repeated = _checkpoint(tmp_path, plan, {1, 2, 3, 4}, checkpoint_path, fingerprint)

    assert (skipped["due"], skipped["reason"], skipped["pending_ids"], skipped["task_ids"]) == (
        False,
        "unchanged-fingerprint",
        [4],
        [],
    )
    assert repeated == skipped
    assert checkpoint_path.read_bytes() == checkpoint_bytes
    assert workflow_state.read_bytes() == original_workflow_state

    # A task reopened after acceptance cannot be reaccepted using the old receipt,
    # even when its source bytes still match the old fingerprint.
    workflow_state.write_text(json.dumps({"sub_tasks": _rows({1, 2})}), encoding="utf-8")
    reopened = _accept_checkpoint(
        tmp_path,
        plan,
        checkpoint_path,
        fingerprint,
        [1, 2, 3],
        workflow_state,
        review_state,
        review_loop,
        receipt,
    )
    assert reopened.returncode == 2
    assert "accepted incomplete task" in reopened.stderr
    assert checkpoint_path.read_bytes() == checkpoint_bytes


def test_checkpoint_acceptance_rejects_receipt_not_recorded_in_ledger(tmp_path: Path) -> None:
    plan = _plan([(task_id, "tdd", "[]" if task_id == 1 else f"[{task_id - 1}]", "normal", "none") for task_id in range(1, 4)])
    fingerprint = _fingerprint("receipt-input")
    checkpoint_path = tmp_path / "review" / "accepted_checkpoints.json"
    workflow_state = tmp_path / "workflow-state.json"
    workflow_state.write_text(json.dumps({"sub_tasks": _rows({1, 2, 3})}), encoding="utf-8")
    receipt = {
        "task_ids": ["1", "2", "3"],
        "input_fingerprint": fingerprint,
        "pass_id": "P-4",
        "scope": "delta",
        "checkpoint_verified": True,
        "final_review": False,
        "snapshot": "snapshot-four",
        "reviewer_id": "diff-reviewer",
        "independent": True,
        "dispositions": [],
    }
    review_state = tmp_path / "ledger.json"
    review_state.write_text(
        json.dumps({"checkpoint_receipts": [{**receipt, "pass_id": "P-3"}]}),
        encoding="utf-8",
    )
    review_loop = _ledger_verifier(tmp_path / "review_loop.py")

    result = _accept_checkpoint(
        tmp_path,
        plan,
        checkpoint_path,
        fingerprint,
        [1, 2, 3],
        workflow_state,
        review_state,
        review_loop,
        receipt,
    )

    assert result.returncode == 2
    assert "review ledger rejected" in result.stderr
    assert not checkpoint_path.exists()
