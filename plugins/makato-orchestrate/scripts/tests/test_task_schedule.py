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


def test_checkpoint_acceptance_requires_publication_even_if_source_matches(tmp_path: Path) -> None:
    plan = _plan([(number, "tdd", "[]", "normal", "none") for number in range(1, 5)])
    fingerprint = _fingerprint("unpublished")
    workflow = tmp_path / "workflow.json"
    workflow.write_text(json.dumps({"sub_tasks": _rows({1, 2, 3})}))
    receipt = {
        "task_ids": ["1", "2", "3"],
        "input_fingerprint": fingerprint,
        "pass_id": "P-1",
        "scope": "delta",
        "checkpoint_verified": True,
        "final_review": False,
        "snapshot": "source-snapshot",
    }
    ledger = tmp_path / "ledger.json"
    ledger.write_text(json.dumps({"checkpoint_receipts": [receipt]}))
    checkpoint = tmp_path / "accepted.json"
    result = _accept_checkpoint(tmp_path, plan, checkpoint, fingerprint, [1, 2, 3], workflow, ledger, _ledger_verifier(tmp_path / "review_loop.py"), receipt)
    assert result.returncode == 2
    assert not checkpoint.exists()


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
        "delivery_fingerprint": fingerprint,
        "audit_transition": {"schema": "review-audit-transition-v1"},
        "pass_id": "P-3",
        "scope": "delta",
        "checkpoint_verified": True,
        "final_review": False,
        "snapshot": "snapshot-three",
        "checkpoint_scope": {"pre_snapshot": None, "scope_files": ["app.py"]},
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
        "delivery_fingerprint": fingerprint,
        "audit_transition": {"schema": "review-audit-transition-v1"},
        "pass_id": "P-4",
        "scope": "delta",
        "checkpoint_verified": True,
        "final_review": False,
        "snapshot": "snapshot-four",
        "checkpoint_scope": {"pre_snapshot": None, "scope_files": ["app.py"]},
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


def test_real_published_checkpoint_accepts_live_delivery_and_preserves_anchor_snapshot(tmp_path: Path) -> None:
    build_shared = SCRIPT.parents[2] / "makato-build/shared"
    sys.path.insert(0, str(build_shared))
    import review_loop
    import review_scope

    repo = tmp_path / "worktree"
    repo.mkdir()

    def git(*args: str) -> str:
        return subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True, check=True).stdout.strip()

    git("init", "-q")
    git("config", "user.name", "Checkpoint Test")
    git("config", "user.email", "checkpoint@example.invalid")
    (repo / "app.py").write_text("value = 1\n")
    audit = repo / "specs/GH-1/build.jsonl"
    audit.parent.mkdir(parents=True)
    audit.write_text("{}\n")
    (audit.parent / "plan-1.md").write_text("Issue 1 plan\n")
    git("add", ".")
    git("commit", "-qm", "base")
    (repo / "app.py").write_text("value = 2\n")
    ledger = repo / ".git/review-ledger.json"
    review_loop.init(str(ledger), "GH-1", "HEAD")
    anchor = review_loop.gate(str(ledger), "review", str(repo), "HEAD")["input_fingerprint"]
    reviewer = {
        "schema": "r1",
        "agent": "diff-reviewer",
        "status": "success",
        "summary": "Independent delta review",
        "files_changed": [],
        "tests_written": [],
        "errors": [],
        "tool_calls_used": 0,
        "data": {
            "reviewer_id": "delta-reviewer",
            "input_fingerprint": anchor,
            "files_reviewed": 1,
            "file_citations": [{"file": "app.py", "line": 1}],
            "critical_count": 0,
            "major_count": 0,
            "findings": [],
        },
    }
    artifact = tmp_path / "review.json"
    artifact.write_text(json.dumps(reviewer))
    review_loop.merge(str(ledger), 1, "delta", 0, None, [str(artifact)], input_fingerprint=anchor)
    evidence = tmp_path / "checkpoint-evidence.json"
    evidence.write_text(
        json.dumps(
            {
                "input_fingerprint": anchor,
                "pass_id": "P-1",
                "scope": "delta",
                "task_ids": ["1", "2", "3"],
                "checkpoint_verified": True,
                "final_review": False,
                "reviewer_id": "independent-verifier",
                "independent": True,
                "dispositions": [],
                "evidence": "Reviewed completed task behavior.",
                "citations": [{"file": "app.py", "line": 1}],
            }
        )
    )
    source = review_loop.gate(str(ledger), "checkpoint", str(repo), "HEAD", evidence_path=str(evidence))["checkpoint_receipt"]
    delivery = review_loop.publish_audit(str(ledger), str(repo), "HEAD")
    live = review_scope.fingerprint(str(repo), "HEAD")["sha256"]
    assert anchor != live == delivery["delivery_fingerprint"]
    plan = _plan([(number, "tdd", "[]", "normal", "none") for number in range(1, 5)])
    workflow = tmp_path / "workflow-state.json"
    workflow.write_text(json.dumps({"sub_tasks": _rows({1, 2, 3})}))
    checkpoint = tmp_path / "accepted.json"
    args = [
        "--checkpoint",
        str(checkpoint),
        "--fingerprint",
        live,
        "--task-ids",
        "1,2,3",
        "--review-loop",
        str(build_shared / "review_loop.py"),
        "--review-state",
        str(ledger),
        "--worktree",
        str(repo),
        "--review-base",
        "HEAD",
        "--receipt",
        json.dumps(delivery["checkpoint_receipt"]),
    ]
    for _ in range(2):
        accepted = _run(tmp_path, "accept-checkpoint", plan, [], args, state_path=workflow)
        assert accepted.returncode == 0, accepted.stderr
        assert json.loads(accepted.stdout)["snapshot"] == source["snapshot"]
        assert json.loads(checkpoint.read_text())["fingerprint"] == live
    stale_args = list(args)
    stale_args[stale_args.index("--fingerprint") + 1] = anchor
    assert _run(tmp_path, "accept-checkpoint", plan, [], stale_args, state_path=workflow).returncode == 2
    forged_args = list(args)
    forged_args[forged_args.index("--receipt") + 1] = json.dumps({**delivery["checkpoint_receipt"], "snapshot": "forged"})
    assert _run(tmp_path, "accept-checkpoint", plan, [], forged_args, state_path=workflow).returncode == 2


@pytest.fixture
def checkpoint_source(tmp_path: Path):
    """Exercise the source CLI, publication and scheduler, without a fake verifier."""
    shared = SCRIPT.parents[2] / "makato-build/shared"
    repo = tmp_path / "source-worktree"
    repo.mkdir()

    def git(*args: str) -> str:
        return subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True, check=True).stdout.strip()

    git("init", "-q")
    git("config", "user.name", "Scope Test")
    git("config", "user.email", "scope@example.invalid")
    for name, text in {"app.py": "VALUE = 1\n", "second.py": "VALUE = 1\n", "caller.py": "from app import VALUE\n"}.items():
        (repo / name).write_text(text)
    audit = repo / "specs/GH-1/build.jsonl"
    audit.parent.mkdir(parents=True)
    audit.write_text("{}\n")
    (audit.parent / "plan-1.md").write_text("Issue 1 plan\n")
    git("add", ".")
    git("commit", "-qm", "base")
    base = git("rev-parse", "HEAD")
    ledger = repo / ".git/review.json"

    def cli(*args: str, ok: bool = True):
        result = subprocess.run([sys.executable, str(shared / "review_loop.py"), *args], capture_output=True, text=True)
        if ok:
            assert result.returncode == 0, result.stderr
            return json.loads(result.stdout)
        return result

    cli("init", "--state", str(ledger), "--story", "GH-1", "--review-base", base)
    serial = 0
    anchor = ""

    def review(files: list[str], *, count: int | None = None, lens: str | None = None, contexts: tuple[str, ...] | list[str] = (), lens_files: dict[str, list[str]] | None = None):
        nonlocal serial, anchor
        serial += 1
        args = [arg for path in contexts for arg in ("--context-path", path)]
        anchor = cli("gate", "--state", str(ledger), "--event", "review", "--worktree", str(repo), "--review-base", base, *args)["input_fingerprint"]
        envelope = {
            "schema": "r1",
            "agent": "diff-reviewer",
            "status": "success",
            "summary": "Actual source checkpoint scope review.",
            "files_changed": [],
            "tests_written": [],
            "errors": [],
            "tool_calls_used": 0,
            "data": {
                "reviewer_id": f"reviewer-{serial}",
                "input_fingerprint": anchor,
                "files_reviewed": len(files) if count is None else count,
                "file_citations": [{"file": name, "line": 1} for name in files],
                "lens": lens,
                "critical_count": 0,
                "major_count": 0,
                "findings": [],
            },
        }
        artifacts = []
        for number, (name, paths) in enumerate((lens_files or {lens: files}).items()):
            data = {**envelope["data"], "lens": name, "files_reviewed": len(paths) if count is None else count, "file_citations": [{"file": path, "line": 1} for path in paths]}
            artifact = tmp_path / f"scope-review-{serial}-{number}.json"
            artifact.write_text(json.dumps({**envelope, "data": data}))
            artifacts.append(str(artifact))
        return cli("merge", "--state", str(ledger), "--pass", str(serial), "--scope", "delta", "--after-round", "0", "--fingerprint", anchor, *artifacts)

    def checkpoint(task_ids=("1", "2", "3"), *, ok=True):
        evidence = tmp_path / "scope-evidence.json"
        evidence.write_text(
            json.dumps(
                {
                    "input_fingerprint": anchor,
                    "pass_id": f"P-{serial}",
                    "scope": "delta",
                    "task_ids": list(task_ids),
                    "checkpoint_verified": True,
                    "final_review": False,
                    "reviewer_id": "independent-scope-verifier",
                    "independent": True,
                    "dispositions": [],
                    "evidence": "Independent completed-task verification.",
                    "citations": [{"file": "app.py", "line": 1}],
                    # These are deliberately untrusted assertions, not mechanical coverage.
                    "checkpoint_scope": {"pre_snapshot": None, "scope_files": ["app.py"]},
                }
            )
        )
        return cli("gate", "--state", str(ledger), "--event", "checkpoint", "--worktree", str(repo), "--review-base", base, "--evidence", str(evidence), ok=ok)

    def publish(*, ok=True):
        return cli("publish-audit", "--state", str(ledger), "--worktree", str(repo), "--review-base", base, ok=ok)

    accepted = tmp_path / "accepted-scope.json"

    def accept(delivery, completed=frozenset({1, 2, 3}), task_ids="1,2,3"):
        plan = _plan([(number, "tdd", "[]", "normal", "none") for number in range(1, 8)])
        return _run(
            tmp_path,
            "accept-checkpoint",
            plan,
            _rows(completed),
            [
                "--checkpoint",
                str(accepted),
                "--fingerprint",
                delivery["delivery_fingerprint"],
                "--task-ids",
                task_ids,
                "--review-loop",
                str(shared / "review_loop.py"),
                "--review-state",
                str(ledger),
                "--worktree",
                str(repo),
                "--review-base",
                base,
                "--receipt",
                json.dumps(delivery["checkpoint_receipt"]),
            ],
        )

    return repo, ledger, review, checkpoint, publish, accept, accepted


@pytest.mark.parametrize("change", ["modified", "deleted", "untracked", "caller", "count", "lens"])
def test_source_checkpoint_rejects_incomplete_authoritative_scope(checkpoint_source, change: str) -> None:
    repo, _, review, checkpoint, _, _, accepted = checkpoint_source
    (repo / "app.py").write_text("VALUE = 2\n")
    if change == "modified":
        (repo / "second.py").write_text("VALUE = 2\n")
    elif change == "deleted":
        (repo / "second.py").unlink()
    elif change == "untracked":
        (repo / "new.py").write_text("VALUE = 2\n")
    files = ["app.py"] if change != "lens" else ["app.py", "caller.py"]
    review(files, count=100 if change == "count" else None, lens="contract-ac" if change == "lens" else None)
    gate = checkpoint()
    assert gate["next_action"] == "blocked", gate
    assert "coverage" in gate["reason"], gate
    assert "checkpoint_receipt" not in gate
    assert not accepted.exists()


@pytest.mark.parametrize("corruption", ["citations", "scope", "snapshot", "lenses"])
def test_source_checkpoint_rechecks_scope_at_publication_and_scheduler(checkpoint_source, corruption: str) -> None:
    repo, ledger, review, checkpoint, publish, accept, accepted = checkpoint_source
    (repo / "app.py").write_text("VALUE = 2\n")
    (repo / "second.py").write_text("VALUE = 2\n")
    review(["app.py", "second.py", "caller.py"])
    source = checkpoint()
    assert "checkpoint_receipt" in source, source
    complete = ledger.read_bytes()
    state = json.loads(complete)

    def corrupt(document):
        if corruption == "citations":
            document["passes"][-1]["file_citations"] = [{"file": "app.py", "line": 1}]
            document["passes"][-1]["files_reviewed"] = 100
        elif corruption == "lenses":
            document["passes"][-1].update(unscoped_full=False, review_lenses=["contract-ac"])
        else:
            receipts = [
                document["checkpoint_receipts"][-1],
                document["gate_history"][-1]["checkpoint_receipt"],
                document["audit_certificates"][-1]["checkpoint_receipt"],
            ]
            for receipt in receipts:
                if corruption == "scope":
                    receipt["checkpoint_scope"]["scope_files"] = ["app.py"]
                else:
                    receipt["snapshot"] = "not-a-source-tree"

    corrupt(state)
    ledger.write_text(json.dumps(state))
    prefix = (repo / "specs/GH-1/build.jsonl").read_bytes()
    rejected = publish(ok=False)
    assert rejected.returncode != 0, rejected.stdout
    assert "coverage" in rejected.stderr
    assert (repo / "specs/GH-1/build.jsonl").read_bytes() == prefix
    ledger.write_bytes(complete)
    delivery = publish()
    assert accept(delivery).returncode == 0
    accepted_bytes = accepted.read_bytes()
    published = json.loads(ledger.read_text())
    corrupt(published)
    ledger.write_text(json.dumps(published))
    rejected = accept(delivery)
    assert rejected.returncode == 2
    assert "coverage" in rejected.stderr
    assert accepted.read_bytes() == accepted_bytes


@pytest.mark.parametrize("corruption", ["raw-line", "raw-status", "raw-binding", "cached-citations"])
def test_source_checkpoint_revalidates_raw_r1_before_certification_publication_and_acceptance(checkpoint_source, corruption: str) -> None:
    repo, ledger, review, checkpoint, publish, accept, accepted = checkpoint_source
    (repo / "app.py").write_text("VALUE = 2\n")
    review(["app.py", "caller.py"])
    reviewed = ledger.read_bytes()

    def corrupt():
        document = json.loads(ledger.read_text())
        raw = document["raw_envelopes"][-1]
        if corruption == "raw-line":
            raw["envelope"]["data"]["file_citations"][0]["line"] = 0
        elif corruption == "raw-status":
            raw["envelope"]["status"] = "partial"
        elif corruption == "raw-binding":
            raw["input_fingerprint"] = "f" * 64
        else:
            document["passes"][-1]["file_citations"][0]["line"] = 2
        ledger.write_text(json.dumps(document))

    corrupt()
    gate = checkpoint(ok=False)
    if gate.returncode == 0:
        result = json.loads(gate.stdout)
        assert result["next_action"] == "blocked", result
        assert "checkpoint_receipt" not in result
    else:
        assert gate.returncode == 2, gate.stderr
    ledger.write_bytes(reviewed)
    assert "checkpoint_receipt" in checkpoint()
    certified = ledger.read_bytes()
    prefix = (repo / "specs/GH-1/build.jsonl").read_bytes()
    corrupt()
    assert publish(ok=False).returncode != 0
    assert (repo / "specs/GH-1/build.jsonl").read_bytes() == prefix
    ledger.write_bytes(certified)
    delivery = publish()
    published = ledger.read_bytes()
    for previously_accepted in (False, True):
        ledger.write_bytes(published)
        if previously_accepted:
            assert accept(delivery).returncode == 0
        before = accepted.read_bytes() if accepted.exists() else None
        corrupt()
        assert accept(delivery).returncode == 2
        assert (accepted.read_bytes() if accepted.exists() else None) == before


def test_source_checkpoint_subsequent_delta_cannot_hide_uncited_changes(checkpoint_source) -> None:
    repo, _, review, checkpoint, publish, accept, accepted = checkpoint_source
    (repo / "app.py").write_text("VALUE = 2\n")
    review(["app.py", "caller.py"])
    first = checkpoint()["checkpoint_receipt"]
    assert accept(publish()).returncode == 0
    accepted_bytes = accepted.read_bytes()
    (repo / "second.py").unlink()
    (repo / "new.py").write_text("VALUE = 3\n")
    review(["specs/GH-1/build.jsonl"])
    blocked = checkpoint(("4", "5", "6"))
    assert blocked["next_action"] == "blocked", blocked
    assert accepted.read_bytes() == accepted_bytes
    review(["second.py", "new.py", "specs/GH-1/build.jsonl"])
    second = checkpoint(("4", "5", "6"))["checkpoint_receipt"]
    assert second["checkpoint_scope"]["pre_snapshot"] == first["snapshot"]
    assert set(second["checkpoint_scope"]["scope_files"]) == {"second.py", "new.py", "specs/GH-1/build.jsonl"}
    delivery = publish()
    accepted_document = json.loads(accepted_bytes)
    accepted.write_text(json.dumps({**accepted_document, "snapshot": "foreign-baseline"}))
    foreign_bytes = accepted.read_bytes()
    rejected = accept(delivery, set(range(1, 7)), "4,5,6")
    assert rejected.returncode == 2
    assert "baseline" in rejected.stderr
    assert accepted.read_bytes() == foreign_bytes
    accepted.write_bytes(accepted_bytes)
    assert accept(delivery, set(range(1, 7)), "4,5,6").returncode == 0
    assert json.loads(accepted.read_text())["snapshot"] == second["snapshot"]


def test_source_checkpoint_context_change_invalidates_prior_source_scope(checkpoint_source) -> None:
    repo, _, review, checkpoint, publish, accept, _ = checkpoint_source
    (repo / "second.py").write_text("VALUE = 2\n")
    context = "specs/GH-1/plan-1.md"
    review(["second.py", "context:" + context], contexts=[context])
    assert "checkpoint_receipt" in checkpoint()
    assert accept(publish()).returncode == 0
    (repo / context).write_text("Changed applicable constraints\n")
    review([context, "context:" + context, "specs/GH-1/build.jsonl"], contexts=[context])
    blocked = checkpoint(("4", "5", "6"))
    assert blocked["next_action"] == "blocked", blocked
    assert "coverage" in blocked["reason"]


def test_source_checkpoint_requires_each_lens_to_cover_the_same_scope(checkpoint_source) -> None:
    repo, _, review, checkpoint, publish, accept, _ = checkpoint_source
    (repo / "app.py").write_text("VALUE = 2\n")
    lenses = {name: ["app.py", "caller.py"] for name in ("security-privacy", "state-concurrency", "error-handling", "resources-performance", "contract-ac")}
    lenses["error-handling"] = ["app.py"]
    review([], lens_files=lenses)
    blocked = checkpoint()
    assert blocked["next_action"] == "blocked", blocked
    assert "coverage" in blocked["reason"]
    lenses["error-handling"] = ["app.py", "caller.py"]
    review([], lens_files=lenses)
    assert "checkpoint_receipt" in checkpoint()
    assert accept(publish()).returncode == 0


@pytest.mark.parametrize(
    "attributes,raw,changed",
    [
        ("*.txt text\n", b"first\r\nsecond\r\n", b"first\nsecond\n"),
        ("*.txt text eol=crlf\n", b"first\r\nsecond\r\n", b"first\nsecond\n"),
        ("*.txt filter=upper\n", b"first lower\nsecond lower\n", b"FIRST LOWER\nSECOND LOWER\n"),
    ],
)
@pytest.mark.parametrize("committed", [False, True])
def test_source_checkpoint_preserves_raw_filtered_identity_through_later_acceptance(checkpoint_source, attributes, raw, changed, committed) -> None:
    repo, ledger, review, checkpoint, publish, accept, accepted = checkpoint_source

    def git(*args):
        return subprocess.run(["git", "-C", str(repo), *args], capture_output=True, check=True).stdout

    git("config", "filter.upper.clean", "tr '[:lower:]' '[:upper:]'")
    git("config", "filter.upper.smudge", "cat")
    (repo / ".gitattributes").write_text(attributes)
    notes = repo / "notes.txt"
    notes.write_bytes(raw)
    if committed:
        git("add", ".gitattributes", "notes.txt")
        git("commit", "-qm", "normalized reviewed branch content")
    index = git("write-tree")
    review([".gitattributes", "notes.txt"])
    first_gate = checkpoint()
    assert "checkpoint_receipt" in first_gate, first_gate
    first = first_gate["checkpoint_receipt"]
    assert git("show", first["snapshot"] + ":notes.txt") == raw
    assert git("write-tree") == index
    assert notes.read_bytes() == raw
    before_publication = ledger.read_bytes()
    prefix = (repo / "specs/GH-1/build.jsonl").read_bytes()
    notes.write_bytes(changed)
    assert publish(ok=False).returncode != 0
    assert (repo / "specs/GH-1/build.jsonl").read_bytes() == prefix
    notes.write_bytes(raw)
    ledger.write_bytes(before_publication)
    delivery = publish()
    assert accept(delivery).returncode == 0
    accepted_bytes = accepted.read_bytes()
    notes.write_bytes(changed)
    assert accept(delivery).returncode == 2
    assert accepted.read_bytes() == accepted_bytes
    # A newly reviewed raw-only change remains a real delta, even if Git's
    # clean filter produces the same blob as the preceding reviewed bytes.
    review(["notes.txt", "specs/GH-1/build.jsonl"])
    second_gate = checkpoint(("4", "5", "6"))
    assert "checkpoint_receipt" in second_gate, second_gate
    second = second_gate["checkpoint_receipt"]
    assert second["checkpoint_scope"]["pre_snapshot"] == first["snapshot"]
    assert "notes.txt" in second["checkpoint_scope"]["scope_files"]
    assert git("show", second["snapshot"] + ":notes.txt") == changed
    assert accept(publish(), set(range(1, 7)), "4,5,6").returncode == 0
    assert json.loads(accepted.read_text())["snapshot"] == second["snapshot"]
