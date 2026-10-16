"""Emit the Needs Planning reshape signal when structural_halt_cycles reaches threshold (#348).

Usage:
  python3 emit_needs_planning_signal.py <KEY> <ISSUE_NUMBER>

  KEY          composite key (e.g. "348-makato-orchestrate-emit-a-durable-needs")
  ISSUE_NUMBER GitHub issue number (e.g. 348)

What it does:
  1. Reads structural_halt_cycles from workflow-state-<ISSUE_NUMBER>.json.
  2. Compares to MAKATO_STRUCTURAL_RESHAPE_THRESHOLD (default 2).
  3. Below threshold: exits 0, no-op.
  4. At/above threshold:
     a) Applies `needs-reshape` label via `gh issue edit --add-label`.
        Creates the label with colour #0075ca if absent.
     b) Attempts to set board Status to Needs Planning via `gh project item-edit`
        using the `needs_planning` option ID from .claude/config.json.
        Degrades gracefully to label-only when the option ID is absent or null
        or when the `gh` call fails.
     c) Emits a JSONL entry to build.jsonl via build-log.sh.

Test hooks (all optional — names MUST match bash script exactly):
  MAKATO_EMIT_NPS_SPECS_DIR           Override specs/ root.
  MAKATO_EMIT_NPS_CONFIG_FILE         Override .claude/config.json path.
  MAKATO_EMIT_NPS_GH_DRY_RUN         "1" → skip actual gh calls, echo to stdout.
  MAKATO_EMIT_NPS_GH_ITEM_ID         When SET (even to empty), _get_item_id returns
                                       this value instead of calling gh project item-list.
  MAKATO_EMIT_NPS_GH_ITEM_ADD_RESULT When set in dry-run, item-add returns this ID.
  MAKATO_EMIT_NPS_GH_ITEM_ADD_FAIL   "1" in dry-run → item-add returns empty (simulates failure).

Exit codes:
  0  success or no-op (below threshold; board/label soft failures are WARN)
  1  unrecoverable input error (missing KEY or ISSUE_NUMBER, invalid integer)
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path


def _now() -> str:
    """Return ISO-8601 UTC timestamp with millisecond precision."""
    n = datetime.now(timezone.utc)
    return n.strftime("%Y-%m-%dT%H:%M:%S.") + f"{n.microsecond // 1000:03d}Z"


def _repo_root() -> str:
    """Return the selected target root, else preserve git/cwd fallback behaviour."""
    target_repo_root = os.environ.get("MAKATO_TARGET_REPO_ROOT")
    if target_repo_root:
        try:
            target_root = Path(target_repo_root).resolve(strict=True)
        except (OSError, RuntimeError):
            raise SystemExit(
                "emit-needs-planning-signal: target repository root is not a directory: "
                f"{target_repo_root}"
            )
        if not target_root.is_dir():
            raise SystemExit(
                "emit-needs-planning-signal: target repository root is not a directory: "
                f"{target_repo_root}"
            )
        try:
            target_repo = subprocess.run(
                ["git", "-C", str(target_root), "rev-parse", "--show-toplevel"],
                capture_output=True,
                text=True,
                timeout=10,
            )
        except Exception:
            raise SystemExit(
                "emit-needs-planning-signal: target repository root is not a git checkout: "
                f"{target_root}"
            )
        if target_repo.returncode != 0:
            raise SystemExit(
                "emit-needs-planning-signal: target repository root is not a git checkout: "
                f"{target_root}"
            )
        return str(target_root)
    try:
        result = subprocess.run(
            ["git", "rev-parse", "--git-common-dir"],
            capture_output=True,
            text=True,
            check=True,
        )
        git_common_dir = result.stdout.strip()
        if git_common_dir:
            parent = os.path.abspath(os.path.join(git_common_dir, ".."))
            # Validate it looks like a repo root.
            if os.path.isdir(parent):
                return parent
    except Exception:
        pass
    try:
        result = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            capture_output=True,
            text=True,
            check=True,
        )
        return result.stdout.strip()
    except Exception:
        return os.getcwd()


def _resolve_build_plugin_root(repo_root: str) -> Path | None:
    """Find the build plugin from the installed orchestrate plugin or target repo."""
    script_plugin_root = Path(__file__).resolve().parent.parent
    configured_orchestrate_root = os.environ.get("MAKATO_ORCHESTRATE_ROOT")
    source_plugin_root = (
        Path(configured_orchestrate_root) if configured_orchestrate_root else script_plugin_root
    )
    cache_parent = script_plugin_root.parent
    candidates = []

    configured_build_root = os.environ.get("MAKATO_BUILD_ROOT")
    if configured_build_root:
        candidates.append(Path(configured_build_root))
    candidates.extend(
        (
            source_plugin_root.parent / "makato-build",
            cache_parent / "makato-build",
            *cache_parent.glob("makato-suite___makato-build___*"),
            Path(repo_root) / "plugins" / "makato-build",
        )
    )

    for candidate in candidates:
        if (candidate / ".claude-plugin" / "plugin.json").is_file():
            return candidate
    return None


def _resolve_spec_folder(specs_dir: str, key: str) -> str:
    """Resolve spec folder: find specs/<KEY>-*/ then fall back to specs/<KEY>/."""
    if os.path.isdir(specs_dir):
        try:
            for entry in os.listdir(specs_dir):
                if entry.startswith(key + "-") and os.path.isdir(os.path.join(specs_dir, entry)):
                    return os.path.join(specs_dir, entry)
        except OSError:
            pass
    direct = os.path.join(specs_dir, key)
    if os.path.isdir(direct):
        return direct
    return direct  # Return even if absent — callers handle missing state.


def read_workflow_state(spec_folder: str, issue: str, ws_script: str) -> dict:
    """Read workflow-state-<issue>.json from spec_folder or via workflow-state.sh.

    Returns the parsed dict, or raises RuntimeError if state is missing/empty.
    """
    state_file = os.path.join(spec_folder, f"workflow-state-{issue}.json")
    if os.path.isfile(state_file):
        with open(state_file, encoding="utf-8") as fh:
            return json.load(fh)

    # Try workflow-state.sh fallback.
    if os.path.isfile(ws_script):
        try:
            result = subprocess.run(
                [ws_script, "read", os.path.basename(spec_folder), issue],
                capture_output=True,
                text=True,
            )
            text = result.stdout.strip()
            if text and text != "{}":
                return json.loads(text)
        except Exception:
            pass

    return {}


def read_needs_planning_option(config_file: str) -> tuple[str, str, str, str]:
    """Read project config from .claude/config.json.

    Returns (needs_planning_option_id, project_owner, project_number, status_field_id).
    Any of these may be empty string if not present.
    """
    if not os.path.isfile(config_file):
        return "", "", "", ""
    try:
        with open(config_file, encoding="utf-8") as fh:
            cfg = json.load(fh)
    except Exception:
        return "", "", "", ""

    gp = cfg.get("github_project") or {}
    fields = gp.get("fields") or {}
    status_field = fields.get("status") or {}
    opts = status_field.get("options") or {}

    # Try both config locations where the option ID may live.
    np_id = ""
    for val in [
        opts.get("needs_planning"),
        (gp.get("options") or {}).get("needs_planning"),
    ]:
        if val and val != "null":
            np_id = str(val)
            break

    owner = str(gp.get("owner") or "")
    number = str(gp.get("number") or "")
    sf_id = str(gp.get("status_field_id") or (fields.get("status") or {}).get("id") or "")
    return np_id, owner, number, sf_id


def apply_label(issue: str, repo: str, dry_run: bool) -> bool:
    """Apply the needs-reshape label. Returns True on success."""
    if dry_run:
        print(f"gh issue edit {issue} --repo {repo} --add-label needs-reshape")
        return True
    if not repo:
        return False
    # Ensure label exists.
    subprocess.run(
        [
            "gh",
            "label",
            "create",
            "needs-reshape",
            "--repo",
            repo,
            "--color",
            "0075ca",
            "--description",
            "Issue has hit the structural-HALT recurrence threshold; needs planning pass",
        ],
        capture_output=True,
    )
    result = subprocess.run(
        ["gh", "issue", "edit", issue, "--repo", repo, "--add-label", "needs-reshape"],
        capture_output=True,
    )
    return result.returncode == 0


def get_item_id(
    project_number: str,
    project_owner: str,
    issue_number: str,
    dry_run: bool,
) -> str:
    """Get the board item ID for the linked issue.

    Honours MAKATO_EMIT_NPS_GH_ITEM_ID env var (test hook — triggers even when set to empty).
    """
    if "MAKATO_EMIT_NPS_GH_ITEM_ID" in os.environ:
        return os.environ["MAKATO_EMIT_NPS_GH_ITEM_ID"]
    if dry_run:
        return ""
    try:
        result = subprocess.run(
            [
                "gh",
                "project",
                "item-list",
                project_number,
                "--owner",
                project_owner,
                "--format",
                "json",
                "--jq",
                f".items[] | select(.content.number == {issue_number}) | .id",
            ],
            capture_output=True,
            text=True,
        )
        lines = result.stdout.strip().splitlines()
        return lines[0].strip() if lines else ""
    except Exception:
        return ""


def item_add(
    project_number: str,
    project_owner: str,
    repo: str,
    issue_number: str,
    dry_run: bool,
) -> str:
    """Add issue to board and return the new item ID. Empty on failure."""
    if dry_run:
        if os.environ.get("MAKATO_EMIT_NPS_GH_ITEM_ADD_FAIL") == "1":
            return ""
        add_result = os.environ.get("MAKATO_EMIT_NPS_GH_ITEM_ADD_RESULT", "")
        if add_result:
            print(f"gh project item-add {project_number} --owner {project_owner} --url https://github.com/{repo}/issues/{issue_number}")
        return add_result
    try:
        result = subprocess.run(
            [
                "gh",
                "project",
                "item-add",
                project_number,
                "--owner",
                project_owner,
                "--url",
                f"https://github.com/{repo}/issues/{issue_number}",
                "--format",
                "json",
            ],
            capture_output=True,
            text=True,
        )
        if result.returncode == 0:
            data = json.loads(result.stdout)
            return str(data.get("id") or "")
    except Exception:
        pass
    return ""


def set_board_status(
    item_id: str,
    project_number: str,
    project_owner: str,
    status_field_id: str,
    option_id: str,
    dry_run: bool,
) -> bool:
    """Set board item Status to Needs Planning. Returns True on success."""
    if dry_run:
        print(f"gh project item-edit --id {item_id} --project-id {project_number} --owner {project_owner} --field-id {status_field_id} --single-select-option-id {option_id}")
        return True
    try:
        result = subprocess.run(
            [
                "gh",
                "project",
                "item-edit",
                "--id",
                item_id,
                "--project-id",
                project_number,
                "--owner",
                project_owner,
                "--field-id",
                status_field_id,
                "--single-select-option-id",
                option_id,
            ],
            capture_output=True,
        )
        return result.returncode == 0
    except Exception:
        return False


def emit_log_entry(
    build_log_script: str,
    key: str,
    structural_halt_cycles: int,
    threshold: int,
    label_applied: bool,
    board_applied: bool,
    warn_reason: str,
) -> None:
    """Emit JSONL entry to build.jsonl via build-log.sh."""
    if not os.path.isfile(build_log_script):
        return
    ts = _now()
    status = "warn" if warn_reason else "ok"
    entry = json.dumps(
        {
            "ts": ts,
            "skill": "emit-needs-planning-signal",
            "story": key,
            "step": "emit-needs-planning",
            "status": status,
            "data": {
                "structural_halt_cycles": structural_halt_cycles,
                "threshold": threshold,
                "label_applied": label_applied,
                "board_applied": board_applied,
                "warn_reason": warn_reason,
            },
        }
    )
    try:
        subprocess.run([build_log_script, key, entry], capture_output=True)
    except Exception:
        pass


def run(key: str, issue_number: str) -> int:
    """Main logic. Returns exit code."""
    repo_root = _repo_root()

    specs_dir = os.environ.get("MAKATO_EMIT_NPS_SPECS_DIR", os.path.join(repo_root, "specs"))
    config_file = os.environ.get(
        "MAKATO_EMIT_NPS_CONFIG_FILE",
        os.path.join(repo_root, ".claude", "config.json"),
    )
    dry_run = os.environ.get("MAKATO_EMIT_NPS_GH_DRY_RUN") == "1"
    threshold_str = os.environ.get("MAKATO_STRUCTURAL_RESHAPE_THRESHOLD", "2")
    try:
        threshold = int(threshold_str)
    except ValueError:
        threshold = 2

    script_dir = Path(__file__).resolve().parent
    ws_script = str(script_dir.parent / "shared" / "workflow-state.sh")
    build_root = _resolve_build_plugin_root(repo_root)
    build_log_script = str(build_root / "shared" / "build-log.sh") if build_root else ""

    spec_folder = _resolve_spec_folder(specs_dir, key)

    # Read workflow state.
    try:
        state = read_workflow_state(spec_folder, issue_number, ws_script)
    except Exception:
        state = {}

    if not state:
        print(
            f"emit-needs-planning-signal: workflow-state-{issue_number}.json not found for KEY={key}",
            file=sys.stderr,
        )
        return 1

    structural_halt_cycles = state.get("structural_halt_cycles", 0)
    try:
        structural_halt_cycles = int(structural_halt_cycles)
    except (TypeError, ValueError):  # fmt: skip
        structural_halt_cycles = 0

    # Threshold check: no-op when below threshold.
    if structural_halt_cycles < threshold:
        return 0

    # At or above threshold — emit the Needs Planning signal.
    repo = state.get("repo", "") or ""

    label_applied = False
    board_applied = False
    warn_reasons: list[str] = []

    # (a) Apply needs-reshape label.
    if apply_label(issue_number, repo, dry_run):
        label_applied = True
    else:
        warn_reasons.append("label-apply-failed")

    # (b) Attempt to set board Status.
    np_id, project_owner, project_number, status_field_id = read_needs_planning_option(config_file)

    if np_id and np_id != "null":
        if project_owner and project_number and status_field_id:
            item_id = get_item_id(project_number, project_owner, issue_number, dry_run)

            if not item_id and repo:
                item_id = item_add(project_number, project_owner, repo, issue_number, dry_run)

            if item_id:
                if set_board_status(item_id, project_number, project_owner, status_field_id, np_id, dry_run):
                    board_applied = True
                else:
                    warn_reasons.append("board-status-failed")
            else:
                warn_reasons.append("board-item-not-found")
        else:
            warn_reasons.append("board-config-incomplete")
    else:
        warn_reasons.append("needs-planning-option-id-absent")

    warn_reason = ",".join(warn_reasons)

    # (c) Emit JSONL log entry.
    emit_log_entry(
        build_log_script,
        key,
        structural_halt_cycles,
        threshold,
        label_applied,
        board_applied,
        warn_reason,
    )

    # Always exit 0 — board/label failures are WARN only.
    return 0


def main(argv: list[str] | None = None) -> int:
    """Entry point. Returns exit code."""
    args = argv if argv is not None else sys.argv[1:]

    if len(args) < 2:
        print(
            "emit-needs-planning-signal: key required (e.g. 348-makato-orchestrate-emit-a-durable-needs)",
            file=sys.stderr,
        )
        return 1

    key = args[0]
    issue_number = args[1]

    if not issue_number or not issue_number.lstrip("0").isdigit() or int(issue_number) < 1:
        print(
            f"emit-needs-planning-signal: ISSUE_NUMBER must be a positive integer (got '{issue_number}')",
            file=sys.stderr,
        )
        return 1

    return run(key, issue_number)


if __name__ == "__main__":
    raise SystemExit(main())
