#!/usr/bin/env python3
"""Dependency-aware one-task-per-dispatch scheduling for the PO-agent (#153).

The ``next`` and ``sync`` commands preserve dependency-aware one-task-per-dispatch
scheduling. ``checkpoint`` deterministically decides when completed work needs a
delta review; ``accept-checkpoint`` persists successfully reviewed task IDs only in
a private review-local file, never in workflow-state.

Checkpoint decisions use three pending completed tasks by default, with early
review for auth, money, persistence, public-contract, or unknown risks. An
explicit ``atomicGroup: none`` declares a standalone boundary; named groups wait
until every member completes. Omitted or unknown boundary metadata defers delta
reviews until all plan tasks complete, where final review takes over.

Commands read the plan from --plan and workflow-state JSON from --state (- for
stdin). Checkpoint commands also take --checkpoint and --fingerprint; an invalid
plan, state, checkpoint, or evidence exits 2 with the reason on stderr.
"""

from __future__ import annotations

import argparse
import fcntl
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any, NamedTuple

MODES = ("tdd", "goal")
SKILLS = {"tdd": "build-implement-tdd", "goal": "build-implement-goal"}
CHECKPOINT_INTERVAL = 3
CHECKPOINT_VERSION = 1
_HIGH_RISK = {"auth", "money", "persistence", "public-contract"}
_UNKNOWN_BOUNDARY_MARKERS = {"unknown", "unknown-boundary", "unknown-cutover"}
_SECTION_RE = re.compile(r"^## ")
_TASK_RE = re.compile(r"^### Task (\d+):\s*(.*?)\s*$")
_FIELD_RE = re.compile(r"^\*\*(Mode|blockedBy|reviewRisk|atomicGroup):\*\*\s*(.*?)\s*$", re.IGNORECASE)
_RUN_ORDER_RE = re.compile(r"^(?:\*\*runOrder:\*\*|runOrder:)\s*(.*?)\s*$")
_MODE_VALUE_RE = re.compile(r"^(tdd|goal)\b", re.IGNORECASE)
_ID_LIST_RE = re.compile(r"^\[(.*?)\]")
_FINGERPRINT_RE = re.compile(r"^[0-9a-f]{64}$")


class PlanError(ValueError):
    """The plan or workflow state cannot be scheduled."""


class Task(NamedTuple):
    id: int
    title: str
    mode: str
    blocked_by: tuple[int, ...]
    review_risk: tuple[str, ...] = ()
    atomic_group: str | None = None


class Plan(NamedTuple):
    tasks: tuple[Task, ...]
    run_order: tuple[str, ...]  # every mode, preferred first


def _parse_run_order(value: str) -> tuple[str, ...]:
    if value.strip().upper() in {"", "N/A"}:
        return ()
    modes = tuple(part.strip().lower() for part in value.strip().strip("[]").split(",") if part.strip())
    if len(set(modes)) != len(modes) or any(mode not in MODES for mode in modes):
        raise PlanError(f"runOrder must list distinct modes from {list(MODES)}; found {value!r}")
    return modes


def _parse_ids(value: str, task_id: int, task_count: int) -> tuple[int, ...]:
    match = _ID_LIST_RE.match(value)
    if not match:
        raise PlanError(f"Task {task_id}: **blockedBy:** must be a list such as [] or [2, 3]")
    ids: list[int] = []
    for part in filter(None, (item.strip() for item in match.group(1).split(","))):
        if not part.isdigit() or not 1 <= int(part) <= task_count or int(part) == task_id:
            raise PlanError(f"Task {task_id}: blockedBy entry {part!r} is not another task in this plan")
        ids.append(int(part))
    return tuple(ids)


def _parse_review_risk(value: str | None) -> tuple[str, ...]:
    if value is None:
        return ()
    raw = value.strip()
    if raw.startswith("[") and raw.endswith("]"):
        raw = raw[1:-1]
    risks = tuple(part.strip().lower().replace("_", "-").replace(" ", "-") for part in raw.split(",") if part.strip())
    return tuple(dict.fromkeys(risks)) or ("unknown",)


def _parse_atomic_group(value: str | None, task_id: int) -> str | None:
    if value is None:
        return "unknown"
    group = value.strip().strip("`").strip()
    if not group:
        raise PlanError(f"Task {task_id}: **atomicGroup:** must name the whole cutover group or be none")
    if group.casefold() == "none":
        return None
    return group.casefold()


def _check_acyclic(tasks: tuple[Task, ...]) -> None:
    remaining = {task.id: set(task.blocked_by) for task in tasks}
    while remaining:
        free = [task_id for task_id, deps in remaining.items() if not deps & remaining.keys()]
        if not free:
            raise PlanError(f"blockedBy cycle among tasks {sorted(remaining)}")
        for task_id in free:
            del remaining[task_id]


def parse_plan(text: str) -> Plan:
    """Parse ``## Tasks`` entries and ``runOrder`` from a refined plan."""
    run_order: tuple[str, ...] | None = None
    entries: list[dict[str, Any]] = []
    in_tasks = False
    for line in text.splitlines():
        if _SECTION_RE.match(line):
            in_tasks = line.strip() == "## Tasks"
        elif not in_tasks:
            if run_order is None and (match := _RUN_ORDER_RE.match(line)):
                run_order = _parse_run_order(match.group(1))
        elif match := _TASK_RE.match(line):
            entries.append({"id": int(match.group(1)), "title": match.group(2)})
        elif entries and (match := _FIELD_RE.match(line)):
            entries[-1].setdefault(match.group(1).lower(), match.group(2))
    if not entries:
        raise PlanError("no '### Task N:' entries under '## Tasks'")

    tasks: list[Task] = []
    for position, entry in enumerate(entries, start=1):
        if entry["id"] != position:
            raise PlanError(f"tasks must be numbered 1..N in order; found Task {entry['id']} at position {position}")
        mode = _MODE_VALUE_RE.match(entry.get("mode", ""))
        if not mode:
            raise PlanError(f"Task {position}: **Mode:** must be tdd or goal")
        if "blockedby" not in entry:
            raise PlanError(f"Task {position}: **blockedBy:** is missing")
        blocked_by = _parse_ids(entry["blockedby"], position, len(entries))
        review_risk = _parse_review_risk(entry.get("reviewrisk"))
        atomic_group = _parse_atomic_group(entry.get("atomicgroup"), position)
        tasks.append(Task(position, entry["title"], mode.group(1).lower(), blocked_by, review_risk, atomic_group))
    _check_acyclic(tuple(tasks))
    preferred = run_order or ()
    return Plan(tuple(tasks), preferred + tuple(mode for mode in MODES if mode not in preferred))


def _rows_by_id(state: Any) -> dict[int, dict[str, Any]]:
    rows = state.get("sub_tasks") if isinstance(state, dict) else None
    if rows is None:
        return {}
    if not isinstance(rows, list):
        raise PlanError("workflow-state sub_tasks must be an array")
    return {row["id"]: row for row in rows if isinstance(row, dict) and isinstance(row.get("id"), int)}


def _is_complete(row: dict[str, Any] | None) -> bool:
    return bool(row) and row.get("status") == "complete"


def next_task(plan: Plan, rows: dict[int, dict[str, Any]]) -> dict[str, Any]:
    """Return one next dependency-ready task, or complete when all are done."""
    done = {task.id for task in plan.tasks if _is_complete(rows.get(task.id))}
    pending = [task for task in plan.tasks if task.id not in done]
    if not pending:
        return {"status": "complete", "task_ids": []}
    # An acyclic graph always has a pending task whose dependencies are all done.
    ready_modes = {task.mode for task in pending if done.issuperset(task.blocked_by)}
    mode = next(mode for mode in plan.run_order if mode in ready_modes)
    task = next(task for task in pending if task.mode == mode and done.issuperset(task.blocked_by))
    return {"status": "ready", "mode": mode, "skill": SKILLS[mode], "task_ids": [task.id]}


def sync_sub_tasks(plan: Plan, rows: dict[int, dict[str, Any]]) -> list[dict[str, Any]]:
    """Align ``sub_tasks[]`` with the plan without altering accepted tasks."""
    plan_ids = {task.id for task in plan.tasks}
    dropped = sorted(task_id for task_id, row in rows.items() if task_id not in plan_ids and _is_complete(row))
    if dropped:
        raise PlanError(f"plan no longer contains accepted task(s) {dropped}")
    synced: list[dict[str, Any]] = []
    for task in plan.tasks:
        row = rows.get(task.id)
        if row is not None and _is_complete(row):
            synced.append(row)
        else:
            base = {"status": "pending", "agent_result": None, **(row or {})}
            synced.append({**base, "id": task.id, "description": task.title, "phase": task.mode})
    return synced


def _completed_ids(plan: Plan, rows: dict[int, dict[str, Any]]) -> set[int]:
    plan_ids = {task.id for task in plan.tasks}
    unknown = sorted(task_id for task_id, row in rows.items() if task_id not in plan_ids and _is_complete(row))
    if unknown:
        raise PlanError(f"workflow-state contains completed task(s) absent from plan: {unknown}")
    done = {task.id for task in plan.tasks if _is_complete(rows.get(task.id))}
    for task in plan.tasks:
        if task.id in done and not done.issuperset(task.blocked_by):
            raise PlanError(f"completed task {task.id} has incomplete dependencies {sorted(set(task.blocked_by) - done)}")
    return done


def _validate_fingerprint(fingerprint: str) -> None:
    if not _FINGERPRINT_RE.fullmatch(fingerprint):
        raise PlanError("fingerprint must be a lowercase 64-character SHA-256")


def _empty_checkpoint() -> dict[str, Any]:
    return {"version": CHECKPOINT_VERSION, "accepted_ids": [], "fingerprint": None, "snapshot": None}


def _load_checkpoint(path: Path) -> dict[str, Any]:
    try:
        raw = path.read_text(encoding="utf-8")
    except FileNotFoundError:
        return _empty_checkpoint()
    except OSError as exc:
        raise PlanError(f"cannot read review checkpoint {path}: {exc}") from exc
    try:
        document = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise PlanError(f"review checkpoint is invalid JSON: {exc}") from exc
    if not isinstance(document, dict):
        raise PlanError("review checkpoint must be an object")
    if type(document.get("version")) is not int or document["version"] != CHECKPOINT_VERSION:
        raise PlanError(f"review checkpoint version {document.get('version')!r} is incompatible; migrate it explicitly")
    if set(document) != {"version", "accepted_ids", "fingerprint", "snapshot"}:
        raise PlanError("review checkpoint fields are invalid; migrate it explicitly")
    accepted_ids = document["accepted_ids"]
    if not isinstance(accepted_ids, list) or any(type(task_id) is not int or task_id < 1 for task_id in accepted_ids):
        raise PlanError("review checkpoint accepted_ids must be positive integer IDs")
    if len(accepted_ids) != len(set(accepted_ids)):
        raise PlanError("review checkpoint accepted_ids contains duplicates")
    fingerprint = document["fingerprint"]
    if fingerprint is not None:
        if not isinstance(fingerprint, str):
            raise PlanError("review checkpoint fingerprint must be a SHA-256 or null")
        _validate_fingerprint(fingerprint)
    snapshot = document["snapshot"]
    if snapshot is not None and (not isinstance(snapshot, str) or not snapshot):
        raise PlanError("review checkpoint snapshot must be a non-empty string or null")
    if bool(accepted_ids) != (fingerprint is not None and snapshot is not None):
        raise PlanError("review checkpoint acceptance metadata is incomplete; migrate it explicitly")
    return document


def checkpoint_decision(
    plan: Plan,
    rows: dict[int, dict[str, Any]],
    checkpoint: dict[str, Any],
    fingerprint: str,
) -> dict[str, Any]:
    """Return a deterministic checkpoint decision without changing either input."""
    _validate_fingerprint(fingerprint)
    done = _completed_ids(plan, rows)
    plan_ids = {task.id for task in plan.tasks}
    accepted = set(checkpoint["accepted_ids"])
    unknown_accepted = sorted(accepted - plan_ids)
    if unknown_accepted:
        raise PlanError(f"review checkpoint refers to task(s) absent from plan: {unknown_accepted}")
    incomplete_accepted = sorted(accepted - done)
    if incomplete_accepted:
        raise PlanError(f"review checkpoint accepted incomplete task(s): {incomplete_accepted}")
    ordered_accepted = [task.id for task in plan.tasks if task.id in accepted]
    ordered_complete = [task.id for task in plan.tasks if task.id in done]
    pending = [task_id for task_id in ordered_complete if task_id not in accepted]
    base = {
        "due": False,
        "reason": "",
        "task_ids": [],
        "completed_ids": ordered_complete,
        "pending_ids": pending,
        "accepted_ids": ordered_accepted,
        "accepted_fingerprint": checkpoint["fingerprint"],
        "accepted_snapshot": checkpoint["snapshot"],
        "fingerprint": fingerprint,
    }
    if not pending:
        base["reason"] = "no-new-completions"
        return base
    if len(done) == len(plan.tasks):
        base["reason"] = "final-review-required"
        return base

    unknown_boundary = any(task.atomic_group in _UNKNOWN_BOUNDARY_MARKERS for task in plan.tasks)
    if unknown_boundary:
        base["reason"] = "atomic-cutover-unknown"
        return base
    incomplete_groups = sorted(
        {
            task.atomic_group
            for task in plan.tasks
            if task.atomic_group is not None and task.id in done and any(member.atomic_group == task.atomic_group and member.id not in done for member in plan.tasks)
        }
    )
    if incomplete_groups:
        base["reason"] = f"atomic-cutover-incomplete:{incomplete_groups[0]}"
        return base
    if checkpoint["fingerprint"] == fingerprint:
        base["reason"] = "unchanged-fingerprint"
        return base

    risk_reasons: list[str] = []
    known_risks = _HIGH_RISK | {"low", "normal", "none", "routine"}
    pending_set = set(pending)
    for task in plan.tasks:
        if task.id not in pending_set:
            continue
        for risk in task.review_risk:
            if risk in _HIGH_RISK:
                risk_reasons.append(risk)
            elif risk not in known_risks:
                risk_reasons.append("unknown")
    if risk_reasons:
        base["due"] = True
        base["reason"] = "risk:" + ",".join(dict.fromkeys(risk_reasons))
    elif len(pending) >= CHECKPOINT_INTERVAL:
        base["due"] = True
        base["reason"] = "completed-task-threshold"
    else:
        base["reason"] = "below-threshold"
    if base["due"]:
        base["task_ids"] = pending
    return base


def _write_checkpoint(path: Path, document: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(path.parent, 0o700)
    descriptor, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(document, handle, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
        directory_fd = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    except BaseException:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        raise


def _verify_checkpoint_receipt(
    review_loop: Path,
    review_state: Path,
    receipt: Any,
    task_ids: list[int],
    fingerprint: str,
    worktree: Path,
    review_base: str,
) -> None:
    if not isinstance(receipt, dict):
        raise PlanError("R1 checkpoint_receipt must be an object")
    required = {
        "task_ids",
        "input_fingerprint",
        "pass_id",
        "scope",
        "checkpoint_verified",
        "final_review",
        "snapshot",
        "delivery_fingerprint",
        "audit_transition",
        "checkpoint_scope",
    }
    if not required.issubset(receipt):
        raise PlanError(f"R1 checkpoint_receipt is missing {sorted(required - set(receipt))}")
    if (
        receipt["scope"] != "delta"
        or receipt["checkpoint_verified"] is not True
        or receipt["final_review"] is not False
        or receipt["delivery_fingerprint"] != fingerprint
        or not isinstance(receipt["audit_transition"], dict)
        or not receipt["audit_transition"]
        or not isinstance(receipt["pass_id"], str)
        or not receipt["pass_id"]
        or not isinstance(receipt["snapshot"], str)
        or not receipt["snapshot"]
    ):
        raise PlanError("R1 checkpoint_receipt is not a verified delta for the current fingerprint")
    scope = receipt["checkpoint_scope"]
    if (
        not isinstance(scope, dict)
        or set(scope) != {"pre_snapshot", "scope_files"}
        or (scope["pre_snapshot"] is not None and (not isinstance(scope["pre_snapshot"], str) or not scope["pre_snapshot"]))
        or not isinstance(scope["scope_files"], list)
        or not scope["scope_files"]
        or any(not isinstance(path, str) or not path for path in scope["scope_files"])
    ):
        raise PlanError("R1 checkpoint_receipt lacks authoritative scope coverage; migrate evidence explicitly")
    receipt_ids = receipt["task_ids"]
    if not isinstance(receipt_ids, list):
        raise PlanError("R1 checkpoint_receipt task_ids must be an array")
    try:
        normalized_ids = [int(task_id) for task_id in receipt_ids]
    except (TypeError, ValueError) as exc:
        raise PlanError("R1 checkpoint_receipt task_ids are invalid") from exc
    if normalized_ids != task_ids or any(str(task_id) != str(raw_id) for task_id, raw_id in zip(normalized_ids, receipt_ids)):
        raise PlanError("R1 checkpoint_receipt task IDs do not match the scheduler decision")
    result = subprocess.run(
        [
            sys.executable,
            str(review_loop),
            "checkpoint-receipt",
            "--state",
            str(review_state),
            "--task-ids",
            ",".join(str(task_id) for task_id in task_ids),
            "--fingerprint",
            receipt["input_fingerprint"],
            "--pass-id",
            receipt["pass_id"],
            "--worktree",
            str(worktree),
            "--review-base",
            review_base,
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        raise PlanError(f"review ledger rejected checkpoint receipt: {result.stderr.strip() or result.returncode}")
    try:
        verified_receipt = json.loads(result.stdout)
    except json.JSONDecodeError as exc:
        raise PlanError("review ledger returned malformed checkpoint receipt JSON") from exc
    if verified_receipt != receipt:
        raise PlanError("R1 checkpoint_receipt does not match the durable review ledger receipt")


def accept_checkpoint(
    plan: Plan,
    rows: dict[int, dict[str, Any]],
    checkpoint_path: Path,
    fingerprint: str,
    task_ids: list[int],
    *,
    review_loop: Path,
    review_state: Path,
    receipt: Any,
    worktree: Path,
    review_base: str,
) -> dict[str, Any]:
    """Persist task IDs only after the review ledger verifies a successful delta receipt."""
    _validate_fingerprint(fingerprint)
    if not task_ids or any(type(task_id) is not int or task_id < 1 for task_id in task_ids):
        raise PlanError("checkpoint acceptance requires positive integer task IDs")
    if len(task_ids) != len(set(task_ids)):
        raise PlanError("checkpoint acceptance requires unique task IDs")

    checkpoint_path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(checkpoint_path.parent, 0o700)
    lock_fd = os.open(f"{checkpoint_path}.lock", os.O_CREAT | os.O_RDWR, 0o600)
    try:
        os.fchmod(lock_fd, 0o600)
        fcntl.flock(lock_fd, fcntl.LOCK_EX)
        checkpoint = _load_checkpoint(checkpoint_path)
        decision = checkpoint_decision(plan, rows, checkpoint, fingerprint)
        requested = set(task_ids)
        ordered_ids = [task.id for task in plan.tasks if task.id in requested]
        if len(ordered_ids) != len(task_ids):
            raise PlanError("checkpoint acceptance contains task IDs absent from the plan")
        _verify_checkpoint_receipt(review_loop, review_state, receipt, ordered_ids, fingerprint, worktree, review_base)
        already_accepted = requested.issubset(set(checkpoint["accepted_ids"]))
        if already_accepted and checkpoint["fingerprint"] == fingerprint and isinstance(receipt, dict) and checkpoint["snapshot"] == receipt.get("snapshot"):
            return {
                "status": "accepted",
                "task_ids": ordered_ids,
                "accepted_ids": checkpoint["accepted_ids"],
                "fingerprint": fingerprint,
                "snapshot": checkpoint["snapshot"],
            }

        if receipt["checkpoint_scope"]["pre_snapshot"] != checkpoint["snapshot"]:
            raise PlanError("checkpoint scope baseline does not match the last accepted snapshot")
        if not decision["due"] or decision["task_ids"] != ordered_ids:
            raise PlanError("checkpoint decision changed; refusing to accept stale or unreviewed task IDs")
        accepted_ids = [task.id for task in plan.tasks if task.id in set(checkpoint["accepted_ids"]) | requested]
        document = {
            "version": CHECKPOINT_VERSION,
            "accepted_ids": accepted_ids,
            "fingerprint": fingerprint,
            "snapshot": receipt["snapshot"],
        }
        _write_checkpoint(checkpoint_path, document)
        return {
            "status": "accepted",
            "task_ids": ordered_ids,
            "accepted_ids": accepted_ids,
            "fingerprint": fingerprint,
            "snapshot": receipt["snapshot"],
        }
    finally:
        fcntl.flock(lock_fd, fcntl.LOCK_UN)
        os.close(lock_fd)


def _parse_cli_task_ids(value: str) -> list[int]:
    try:
        task_ids = [int(part) for part in value.split(",") if part]
    except ValueError as exc:
        raise PlanError("--task-ids must be comma-separated positive integers") from exc
    if not task_ids or any(task_id < 1 for task_id in task_ids) or len(task_ids) != len(set(task_ids)):
        raise PlanError("--task-ids must contain unique positive integers")
    return task_ids


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Dependency-aware PO-agent task scheduling (#153).")
    parser.add_argument("command", choices=("next", "sync", "checkpoint", "accept-checkpoint"))
    parser.add_argument("--plan", required=True, help="path to plan-<ISSUE_NUMBER>.md")
    parser.add_argument("--state", required=True, help="workflow-state JSON path, or - for stdin")
    parser.add_argument("--checkpoint", help="private review-local accepted_checkpoints.json path")
    parser.add_argument("--fingerprint", help="current lowercase SHA-256 review input fingerprint")
    parser.add_argument("--task-ids", help="comma-separated task IDs to accept after review")
    parser.add_argument("--review-loop", help="installed review_loop.py receipt verifier path")
    parser.add_argument("--review-state", help="private durable review ledger JSON path")
    parser.add_argument("--worktree", help="checkpoint worktree whose input fingerprint is validated")
    parser.add_argument("--review-base", help="merge-base SHA recorded in the review ledger")
    parser.add_argument("--receipt", help="compact JSON from R1 data.checkpoint_receipt")
    args = parser.parse_args(argv)
    try:
        with open(args.plan, encoding="utf-8") as handle:
            plan = parse_plan(handle.read())
        if args.state == "-":
            state = json.load(sys.stdin)
        else:
            with open(args.state, encoding="utf-8") as handle:
                state = json.load(handle)
        rows = _rows_by_id(state)
        if args.command == "next":
            result: Any = next_task(plan, rows)
        elif args.command == "sync":
            result = sync_sub_tasks(plan, rows)
        elif args.command == "checkpoint":
            if not args.checkpoint or not args.fingerprint:
                raise PlanError("checkpoint requires --checkpoint and --fingerprint")
            result = checkpoint_decision(plan, rows, _load_checkpoint(Path(args.checkpoint)), args.fingerprint)
        else:
            required = (
                args.checkpoint,
                args.fingerprint,
                args.task_ids,
                args.review_loop,
                args.review_state,
                args.receipt,
                args.worktree,
                args.review_base,
            )
            if any(value is None for value in required):
                raise PlanError("accept-checkpoint requires --checkpoint, --fingerprint, --task-ids, --review-loop, --review-state, --receipt, --worktree, and --review-base")
            result = accept_checkpoint(
                plan,
                rows,
                Path(args.checkpoint),
                args.fingerprint,
                _parse_cli_task_ids(args.task_ids),
                review_loop=Path(args.review_loop),
                review_state=Path(args.review_state),
                receipt=json.loads(args.receipt),
                worktree=Path(args.worktree),
                review_base=args.review_base,
            )
    except (OSError, json.JSONDecodeError, PlanError) as exc:
        print(f"task_schedule: {exc}", file=sys.stderr)
        return 2
    json.dump(result, sys.stdout)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
