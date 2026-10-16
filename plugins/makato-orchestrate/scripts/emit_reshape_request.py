"""Emit specs/<key>-<slug>/reshape-request.json after a structural HALT fires.

Reads workflow-state-<ISSUE_NUMBER>.json from the resolved spec folder,
filters halt_audit[] and lessons_learned[] to structural entries, counts
reshape cycles, and emits the reshape-request.json atomically.  Appends a
step="emit-reshape-request" entry to orchestrate.jsonl.

Usage:
  python3 emit_reshape_request.py <KEY> <ISSUE_NUMBER>

  KEY          composite key (e.g. "349-makato-orchestrate-serialize-structural")
  ISSUE_NUMBER GitHub issue number (e.g. 349) — must be a positive integer

Structural HALT codes: HALT-003, HALT-STRUCTURAL, HALT-010,
and HALT-008 ONLY when data.origin == "outer_iteration".

Test hooks (all optional):
  MAKATO_EMIT_RESHAPE_SPECS_DIR   override specs/ root (tests)

Exit codes:
  0  success
  1  error (missing args, missing state file, validation failure)
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path

# ---------------------------------------------------------------------------
# Structural HALT filter
# ---------------------------------------------------------------------------

_STRUCTURAL_CODES = frozenset({"HALT-003", "HALT-STRUCTURAL", "HALT-010"})


def is_structural_halt(entry: dict) -> bool:
    """Return True when a halt_audit entry is structural.

    Structural codes: HALT-003, HALT-STRUCTURAL, HALT-010,
    and HALT-008 ONLY when data.origin == "outer_iteration".
    """
    code = entry.get("code", "")
    if code in _STRUCTURAL_CODES:
        return True
    if code == "HALT-008":
        data = entry.get("data") or {}
        return data.get("origin") == "outer_iteration"
    return False


def filter_structural_halts(halt_audit: list) -> list:
    """Return only structural halt entries from halt_audit[]."""
    return [e for e in halt_audit if is_structural_halt(e)]


# ---------------------------------------------------------------------------
# Lessons trail filter
# ---------------------------------------------------------------------------


def filter_lessons_trail(lessons_learned: list) -> list:
    """Return only lessons with trigger == 'halt'."""
    return [e for e in lessons_learned if e.get("trigger") == "halt"]


# ---------------------------------------------------------------------------
# Last CRITICAL errors extraction
# ---------------------------------------------------------------------------


def extract_last_critical_errors(sub_tasks: list) -> list[str]:
    """Extract CRITICAL error strings from the last sub_task with a non-null agent_result.

    Returns a list of strings that contain "CRITICAL" (case-insensitive).
    Returns an empty list when no matching errors are found.
    """
    # Reverse to find the last sub_task with a non-null agent_result.
    for task in reversed(sub_tasks):
        agent_result = task.get("agent_result")
        if agent_result is None:
            continue
        errors = agent_result.get("errors") or []
        critical = [e for e in errors if isinstance(e, str) and re.search(r"critical", e, re.IGNORECASE)]
        return critical
    return []


# ---------------------------------------------------------------------------
# Repo root resolution (mirrors workflow-state.sh logic)
# ---------------------------------------------------------------------------


def resolve_repo_root() -> str:
    """Resolve REPO_ROOT from the common git dir (works from worktrees)."""
    try:
        result = subprocess.run(
            ["git", "rev-parse", "--git-common-dir"],
            capture_output=True,
            text=True,
            timeout=10,
        )
        if result.returncode == 0:
            git_common_dir = result.stdout.strip()
            if git_common_dir:
                return str(Path(git_common_dir).parent.resolve())
    except Exception:
        pass
    try:
        result = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            capture_output=True,
            text=True,
            timeout=10,
        )
        if result.returncode == 0:
            return result.stdout.strip()
    except Exception:
        pass
    return os.getcwd()


# ---------------------------------------------------------------------------
# Spec folder resolution
# ---------------------------------------------------------------------------


def resolve_spec_folder(specs_dir: str, key: str) -> str:
    """Return the spec folder path for a given KEY.

    Tries specs/<KEY>-*/ first (glob), then specs/<KEY>/, then falls back
    to specs/<KEY>/ (may not exist yet — caller creates it).
    """
    if os.path.isdir(specs_dir):
        for entry in sorted(os.listdir(specs_dir)):
            candidate = os.path.join(specs_dir, entry)
            if os.path.isdir(candidate) and entry.startswith(key + "-"):
                return candidate
    fallback = os.path.join(specs_dir, key)
    return fallback


# ---------------------------------------------------------------------------
# Timestamp helper
# ---------------------------------------------------------------------------


def now_iso() -> str:
    """Return current UTC timestamp in ISO-8601 with milliseconds."""
    n = datetime.now(timezone.utc)
    return n.strftime("%Y-%m-%dT%H:%M:%S.") + f"{n.microsecond // 1000:03d}Z"


# ---------------------------------------------------------------------------
# Schema validation (stdlib or jsonschema when available)
# ---------------------------------------------------------------------------


def _minimal_schema_check(data: dict, schema_path: str) -> tuple[bool, str]:
    """Minimal stdlib schema check: validates required fields and types only.

    The .sh used jsonschema when available, falling back to a no-op.
    Here we implement the same contract: try jsonschema; if absent, run a
    minimal hand-rolled check against the required fields in the schema.
    """
    try:
        import jsonschema  # type: ignore

        try:
            schema = json.loads(Path(schema_path).read_text(encoding="utf-8"))
            jsonschema.validate(data, schema)
            return True, ""
        except jsonschema.ValidationError as e:
            return False, f"schema validation failed: {e.message}"
    except ImportError:
        # Degraded: run minimal required-field check without jsonschema.
        sys.stderr.write("emit-reshape-request: WARN — jsonschema not installed; degraded: schema-unvalidated (install jsonschema to enable full validation)\n")
        required = [
            "schema_version",
            "issue_key",
            "issue_number",
            "issue_slug",
            "structural_halt_cycles",
            "reshape_cycles",
            "halt_history",
            "lessons_trail",
            "emitted_at",
        ]
        for field in required:
            if field not in data:
                return False, f"missing required field: {field}"
        if data.get("schema_version") != "v1":
            return False, f"schema_version must be 'v1', got {data.get('schema_version')!r}"
        if not isinstance(data.get("issue_number"), int):
            return False, "issue_number must be an integer"
        return True, ""


# ---------------------------------------------------------------------------
# Build reshape-request payload
# ---------------------------------------------------------------------------


def build_reshape_request(
    key: str,
    issue_number: int,
    state: dict,
    reshape_cycles: int,
    emitted_at: str,
) -> dict:
    """Build the reshape-request.json payload dict.

    Does NOT include last_critical_errors when the list is empty (schema: optional).
    """
    issue_slug = key.split("-", 1)[1] if "-" in key else key

    halt_audit = state.get("halt_audit") or []
    structural_halts = filter_structural_halts(halt_audit)
    structural_halt_cycles = len(structural_halts)

    lessons_learned = state.get("lessons_learned") or []
    lessons_trail = filter_lessons_trail(lessons_learned)

    sub_tasks = state.get("sub_tasks") or []
    last_critical_errors = extract_last_critical_errors(sub_tasks)

    payload: dict = {
        "schema_version": "v1",
        "issue_key": key,
        "issue_number": issue_number,
        "issue_slug": issue_slug,
        "structural_halt_cycles": structural_halt_cycles,
        "reshape_cycles": reshape_cycles,
        "halt_history": structural_halts,
        "lessons_trail": lessons_trail,
        "emitted_at": emitted_at,
    }
    # Conditionally add last_critical_errors only when non-empty.
    if last_critical_errors:
        payload["last_critical_errors"] = last_critical_errors

    return payload


# ---------------------------------------------------------------------------
# orchestrate.jsonl append
# ---------------------------------------------------------------------------


def append_orchestrate_log(
    spec_folder: str,
    key: str,
    issue_number: int,
    structural_halt_cycles: int,
    ts: str,
) -> None:
    """Append a step="emit-reshape-request" entry to orchestrate.jsonl."""
    log_entry = {
        "ts": ts,
        "skill": "emit-reshape-request",
        "story": key,
        "step": "emit-reshape-request",
        "status": "ok",
        "data": {
            "issue_number": issue_number,
            "structural_halt_cycles": structural_halt_cycles,
        },
    }
    orchestrate_log = os.path.join(spec_folder, "orchestrate.jsonl")
    os.makedirs(os.path.dirname(orchestrate_log), exist_ok=True)
    with open(orchestrate_log, "a", encoding="utf-8") as fh:
        fh.write(json.dumps(log_entry, separators=(",", ":")) + "\n")


# ---------------------------------------------------------------------------
# main entry point
# ---------------------------------------------------------------------------


def main(argv: list[str] | None = None) -> int:
    """Emit reshape-request.json for a structural HALT event.

    Returns 0 on success, 1 on error.
    """
    parser = argparse.ArgumentParser(
        description=("Emit specs/<key>-<slug>/reshape-request.json after a structural HALT fires on a PO-agent run."),
        prog="emit_reshape_request",
    )
    parser.add_argument(
        "key",
        help="Composite key (e.g. '349-makato-orchestrate-serialize-structural')",
    )
    parser.add_argument(
        "issue_number",
        help="GitHub issue number (e.g. 349) — must be a positive integer",
    )
    args = parser.parse_args(argv)

    key = args.key
    issue_number_str = args.issue_number

    # Validate ISSUE_NUMBER is a positive integer.
    if not re.match(r"^[1-9][0-9]*$", issue_number_str):
        print(
            f"emit-reshape-request: ISSUE_NUMBER must be a positive integer (got {issue_number_str!r})",
            file=sys.stderr,
        )
        return 1
    issue_number = int(issue_number_str)

    repo_root = resolve_repo_root()

    specs_dir = os.environ.get("MAKATO_EMIT_RESHAPE_SPECS_DIR") or os.path.join(repo_root, "specs")
    script_dir = Path(__file__).resolve().parent
    schema_path = str(script_dir / "emit-reshape-request.schema.json")
    ws_script = str(script_dir.parent / "shared" / "workflow-state.sh")

    # Resolve spec folder.
    spec_folder = resolve_spec_folder(specs_dir, key)

    # Read workflow-state.
    state_file = os.path.join(spec_folder, f"workflow-state-{issue_number}.json")
    state_json: str | None = None

    if os.path.isfile(state_file):
        with open(state_file, encoding="utf-8") as fh:
            state_json = fh.read()
    else:
        # Fallback to workflow-state.sh read for production callers.
        if os.path.isfile(ws_script):
            try:
                result = subprocess.run(
                    ["bash", ws_script, "read", key, str(issue_number)],
                    capture_output=True,
                    text=True,
                    timeout=30,
                )
                state_json = result.stdout.strip()
            except Exception:
                pass

    if not state_json or state_json == "{}":
        print(
            f"emit-reshape-request: workflow-state-{issue_number}.json not found for KEY={key}",
            file=sys.stderr,
        )
        return 1

    try:
        state = json.loads(state_json)
    except json.JSONDecodeError as e:
        print(f"emit-reshape-request: JSON parse error reading workflow-state: {e}", file=sys.stderr)
        return 1

    # Count reshape_cycles from any prior reshape-request.json.
    prior_reshape = os.path.join(spec_folder, "reshape-request.json")
    reshape_cycles = 0
    if os.path.isfile(prior_reshape):
        try:
            prior_data = json.loads(Path(prior_reshape).read_text(encoding="utf-8"))
            reshape_cycles = (prior_data.get("reshape_cycles") or 0) + 1
        except Exception:
            reshape_cycles = 0

    ts = now_iso()

    # Build payload.
    payload = build_reshape_request(key, issue_number, state, reshape_cycles, ts)

    # Validate against schema.
    valid, err_msg = _minimal_schema_check(payload, schema_path)
    if not valid:
        print(f"emit-reshape-request: {err_msg}", file=sys.stderr)
        return 1

    # Atomic write.
    os.makedirs(spec_folder, exist_ok=True)
    output_str = json.dumps(payload, indent=2) + "\n"
    with tempfile.NamedTemporaryFile(
        mode="w",
        encoding="utf-8",
        prefix="reshape-request.json.",
        suffix=".tmp",
        dir=spec_folder,
        delete=False,
    ) as tmp_fh:
        tmp_name = tmp_fh.name
        tmp_fh.write(output_str)

    os.replace(tmp_name, prior_reshape)
    print(f"emit-reshape-request: wrote {prior_reshape}", file=sys.stderr)

    # Append orchestrate.jsonl entry.
    structural_halt_cycles = payload["structural_halt_cycles"]
    append_orchestrate_log(spec_folder, key, issue_number, structural_halt_cycles, ts)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
