"""Repo-wide PROGRESS.md roadmap generator from loop-status.json + GitHub epic issues (#601).

Reads `.claude/state/loop-status.json` for operational status:
  - active_workflow.issue (currently-running epic)
  - queue[] (queued issue numbers)
Falls back gracefully when the file is absent or unreadable.

Queries GitHub via:
  gh issue list --label type:epic --state all --json number,title,state,closedAt --limit 200

Classifies each epic:
  Done        — GitHub state == "CLOSED"
  In Progress — number matches active_workflow.issue OR appears in queue[]
  Not Started — open, not in loop queue

Emits PROGRESS.md at the repo root (the directory from which the script is
invoked). Sections: ## Done, ## In Progress, ## Not Started.
Footer: _Last updated: <ISO8601 UTC>. Source: loop-status.json + GitHub issues._

Never fatal: always exits 0. Writes warnings to stderr and includes a
<!-- PROGRESS.md generation warning: <msg> --> comment at top of file when
data is partial.

Environment / test hooks:
  MAKATO_LOOP_STATE_DIR        Override .claude/state/ location (mirrors loop.sh).
  MAKATO_PROGRESS_GH_OVERRIDE  Tests only: path to a JSON file holding the
                                pre-canned gh issue list result. When set, the
                                script reads this file instead of invoking gh.
  MAKATO_PROGRESS_OUT          Override output file path (tests only).
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
from datetime import datetime, timezone


def _now() -> str:
    """Return an ISO-8601 UTC timestamp with millisecond precision."""
    n = datetime.now(timezone.utc)
    return n.strftime("%Y-%m-%dT%H:%M:%S.") + f"{n.microsecond // 1000:03d}Z"


def _log(msg: str) -> None:
    """Write a prefixed message to stderr."""
    print(f"generate-progress: {msg}", file=sys.stderr)


def _repo_root() -> str:
    """Return repo root via git rev-parse, falling back to cwd."""
    try:
        result = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            capture_output=True, text=True, check=True,
        )
        return result.stdout.strip()
    except Exception:
        return os.getcwd()


def read_loop_status(status_file: str) -> tuple[str, list[int], list[str]]:
    """Read loop-status.json and return (active_issue, queue_numbers, warnings).

    active_issue is a string of digits or empty string.
    queue_numbers is a list of ints.
    warnings is a list of warning message strings.
    """
    warnings: list[str] = []
    active_issue = ""
    queue: list[int] = []

    if not os.path.isfile(status_file):
        warnings.append(
            f"loop-status.json absent at {status_file} — "
            "in-progress classification unavailable"
        )
        _log(f"WARN: loop-status.json not found at {status_file} — falling back to gh data only")
        return active_issue, queue, warnings

    try:
        with open(status_file, encoding="utf-8") as fh:
            data = json.load(fh)
    except Exception:
        warnings.append(f"loop-status.json unreadable at {status_file}")
        _log(f"WARN: loop-status.json unreadable at {status_file}")
        return active_issue, queue, warnings

    aw = data.get("active_workflow")
    if isinstance(aw, dict):
        issue_val = aw.get("issue")
        if issue_val is not None:
            try:
                num = int(issue_val)
                if num > 0:
                    active_issue = str(num)
            except (ValueError, TypeError):
                pass

    raw_queue = data.get("queue", [])
    if isinstance(raw_queue, list):
        for item in raw_queue:
            try:
                n = int(item)
                if n > 0:
                    queue.append(n)
            except (ValueError, TypeError):
                pass

    return active_issue, queue, warnings


def fetch_epics(gh_override: str | None) -> tuple[list[dict], list[str], bool]:
    """Fetch epic issues from GitHub or the test override file.

    Returns (epics, warnings, gh_failed).
    """
    warnings: list[str] = []

    if gh_override:
        if os.path.isfile(gh_override):
            try:
                with open(gh_override, encoding="utf-8") as fh:
                    data = json.load(fh)
                if isinstance(data, list):
                    return data, warnings, False
                warnings.append("MAKATO_PROGRESS_GH_OVERRIDE file is not a JSON array")
                return [], warnings, True
            except Exception:
                warnings.append(f"MAKATO_PROGRESS_GH_OVERRIDE file unreadable: {gh_override}")
                return [], warnings, True
        else:
            _log(f"WARN: MAKATO_PROGRESS_GH_OVERRIDE set but file not found: {gh_override}")
            warnings.append(f"MAKATO_PROGRESS_GH_OVERRIDE file not found: {gh_override}")
            return [], warnings, True

    # Real GitHub query.
    try:
        result = subprocess.run(
            [
                "gh", "issue", "list",
                "--label", "type:epic",
                "--state", "all",
                "--json", "number,title,state,closedAt",
                "--limit", "200",
            ],
            capture_output=True, text=True,
        )
        if result.returncode != 0:
            raise subprocess.CalledProcessError(result.returncode, "gh")
        data = json.loads(result.stdout)
        if not isinstance(data, list):
            _log("WARN: gh output is not a JSON array — treating as empty")
            warnings.append("gh issue list output was not a JSON array")
            return [], warnings, False
        return data, warnings, False
    except FileNotFoundError:
        _log("WARN: gh CLI not found — PROGRESS.md will be written with a warning comment")
        warnings.append("gh CLI not available — epic data unavailable")
        return [], warnings, True
    except subprocess.CalledProcessError:
        _log("WARN: gh issue list failed — PROGRESS.md will be written with a warning comment")
        warnings.append("gh issue list failed — epic data unavailable")
        return [], warnings, True
    except json.JSONDecodeError:
        _log("WARN: gh output is not valid JSON — treating as empty")
        warnings.append("gh issue list output was not valid JSON")
        return [], warnings, True


def classify_epics(
    epics: list[dict],
    active_issue: str,
    queue: list[int],
) -> tuple[list[str], list[str], list[str]]:
    """Classify each epic into Done, In Progress, Not Started.

    Returns (done_entries, in_progress_entries, not_started_entries).
    Each entry is a Markdown list item string.
    """
    in_progress_set: set[str] = set()
    if active_issue:
        in_progress_set.add(str(active_issue))
    for n in queue:
        in_progress_set.add(str(n))

    done: list[str] = []
    in_progress: list[str] = []
    not_started: list[str] = []

    for epic in epics:
        num = epic.get("number")
        title = epic.get("title", "")
        state = epic.get("state", "")

        if num is None:
            continue

        # Sanitize title: escape leading # to prevent heading interpretation.
        safe_title = str(title).replace("\\", "\\\\")
        entry = f"- **[{safe_title}](#{num})** (#{num})"

        if state == "CLOSED":
            done.append(entry)
        elif str(num) in in_progress_set:
            in_progress.append(entry)
        else:
            not_started.append(entry)

    return done, in_progress, not_started


def build_progress_md(
    done: list[str],
    in_progress: list[str],
    not_started: list[str],
    warnings: list[str],
    generated_at: str,
) -> str:
    """Build the full PROGRESS.md content string."""
    lines: list[str] = []

    for wmsg in warnings:
        lines.append(f"<!-- PROGRESS.md generation warning: {wmsg} -->")

    lines.append("# Roadmap Progress")
    lines.append("")

    lines.append("## In Progress")
    lines.append("")
    if in_progress:
        for entry in in_progress:
            lines.append(entry)
    else:
        lines.append("_No epics currently in progress._")
    lines.append("")

    lines.append("## Not Started")
    lines.append("")
    if not_started:
        for entry in not_started:
            lines.append(entry)
    else:
        lines.append("_No open epics outside the loop queue._")
    lines.append("")

    lines.append("## Done")
    lines.append("")
    if done:
        for entry in done:
            lines.append(entry)
    else:
        lines.append("_No closed epics found._")
    lines.append("")

    lines.append("---")
    lines.append(f"_Last updated: {generated_at}. Source: loop-status.json + GitHub issues._")

    return "\n".join(lines) + "\n"


def run(
    repo_root: str | None = None,
    state_dir: str | None = None,
    gh_override: str | None = None,
    out_file: str | None = None,
) -> int:
    """Main logic. Returns exit code (always 0)."""
    if repo_root is None:
        repo_root = _repo_root()

    if state_dir is None:
        state_dir = os.environ.get(
            "MAKATO_LOOP_STATE_DIR",
            os.path.join(repo_root, ".claude", "state"),
        )

    if gh_override is None:
        gh_override = os.environ.get("MAKATO_PROGRESS_GH_OVERRIDE") or None

    if out_file is None:
        out_file = os.environ.get(
            "MAKATO_PROGRESS_OUT",
            os.path.join(repo_root, "PROGRESS.md"),
        )

    status_file = os.path.join(state_dir, "loop-status.json")

    active_issue, queue, status_warnings = read_loop_status(status_file)
    epics, gh_warnings, _gh_failed = fetch_epics(gh_override)
    all_warnings = status_warnings + gh_warnings

    done, in_progress, not_started = classify_epics(epics, active_issue, queue)
    generated_at = _now()
    content = build_progress_md(done, in_progress, not_started, all_warnings, generated_at)

    with open(out_file, "w", encoding="utf-8") as fh:
        fh.write(content)

    _log(
        f"PROGRESS.md written to {out_file} "
        f"(done={len(done)}, in-progress={len(in_progress)}, not-started={len(not_started)})"
    )
    return 0


def main(argv: list[str] | None = None) -> int:
    """Entry point. Accepts no flags (all config via env hooks). Always exits 0."""
    import argparse

    parser = argparse.ArgumentParser(
        description="Generate PROGRESS.md from loop-status.json + GitHub epic issues.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    # No positional args; all config via env. Parse to support --help cleanly.
    parser.parse_args(argv if argv is not None else sys.argv[1:])
    return run()


if __name__ == "__main__":
    raise SystemExit(main())
