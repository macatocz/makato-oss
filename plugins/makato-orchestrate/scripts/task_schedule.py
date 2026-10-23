#!/usr/bin/env python3
"""Dependency-aware one-task-per-dispatch scheduling for the PO-agent (#153).

The next command prints the next dependency-ready task as JSON:

    {"status": "ready", "mode": "goal", "skill": "build-implement-goal", "task_ids": [6]}
    {"status": "complete", "task_ids": []}

The task is the first dependency-ready task in the first ready mode from
runOrder. Each task gets its own implementation run and durable workflow-state
checkpoint, including same-mode dependency chains.

The sync command prints sub_tasks[] aligned with the plan: accepted (complete) rows
are kept verbatim; every other row takes the plan's current title and mode; new plan
tasks are appended as pending. A plan that drops an accepted task is rejected.

Both commands read the plan from --plan and workflow-state JSON from --state
(- for stdin). An invalid plan or state exits 2 with the reason on stderr.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from typing import Any, NamedTuple

MODES = ("tdd", "goal")
SKILLS = {"tdd": "build-implement-tdd", "goal": "build-implement-goal"}

_SECTION_RE = re.compile(r"^## ")
_TASK_RE = re.compile(r"^### Task (\d+):\s*(.*?)\s*$")
_FIELD_RE = re.compile(r"^\*\*(Mode|blockedBy):\*\*\s*(.*?)\s*$", re.IGNORECASE)
_RUN_ORDER_RE = re.compile(r"^(?:\*\*runOrder:\*\*|runOrder:)\s*(.*?)\s*$")
_MODE_VALUE_RE = re.compile(r"^(tdd|goal)\b", re.IGNORECASE)
_ID_LIST_RE = re.compile(r"^\[(.*?)\]")


class PlanError(ValueError):
    """The plan or workflow state cannot be scheduled."""


class Task(NamedTuple):
    id: int
    title: str
    mode: str
    blocked_by: tuple[int, ...]


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
        tasks.append(Task(position, entry["title"], mode.group(1).lower(), blocked_by))
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


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Dependency-aware PO-agent task scheduling (#153).")
    parser.add_argument("command", choices=("next", "sync"))
    parser.add_argument("--plan", required=True, help="path to plan-<ISSUE_NUMBER>.md")
    parser.add_argument("--state", required=True, help="workflow-state JSON path, or - for stdin")
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
        result: Any = next_task(plan, rows) if args.command == "next" else sync_sub_tasks(plan, rows)
    except (OSError, json.JSONDecodeError, PlanError) as exc:
        print(f"task_schedule: {exc}", file=sys.stderr)
        return 2
    json.dump(result, sys.stdout)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
