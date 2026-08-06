"""audit-skill-adoption.py — F4 log analyzer and skill-adoption dashboard writer.

Reads the F4 JSONL skill-invocations log, validates D31 required fields,
generates docs/skill-adoption.md (or stdout with --dry-run), and optionally
writes docs/skill-audit-notes.md when D15 anomaly thresholds are met.

Usage:
    python3 scripts/audit-skill-adoption.py [--log-path PATH] [--output-path PATH] [--dry-run]

D31 required fields per log line:
    ts, session_id, agent_id, agent_name, parent_agent_id,
    task_id, skill, plugin, event

D15 anomaly: rolling 7-day rate < 50% AND >= 5 sessions → write anomaly notes.

Exit 0 always (malformed lines do not cause non-zero exit).
"""

from __future__ import annotations

import argparse
import json
import sys
from collections import Counter
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import IO, Optional

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

_REQUIRED_FIELDS = (
    "ts",
    "session_id",
    "agent_id",
    "agent_name",
    "parent_agent_id",
    "task_id",
    "skill",
    "plugin",
    "event",
)

_DEFAULT_LOG_PATH = ".claude/skill-invocations.log"
_DEFAULT_OUTPUT_PATH = "docs/skill-adoption.md"
_ANOMALY_OUTPUT_PATH = "docs/skill-audit-notes.md"

# D15: rolling 7-day rate threshold
_D15_RATE_THRESHOLD = 0.50
_D15_MIN_SESSIONS = 5

# ---------------------------------------------------------------------------
# Parsing
# ---------------------------------------------------------------------------


def _parse_log(
    log_path: Path,
    stderr: IO[str] = sys.stderr,
) -> tuple[list[dict], int]:
    """Parse JSONL log; return (valid_entries, malformed_count).

    A line is malformed when:
    - it is not valid JSON, or
    - any of the D31 required fields is missing (including 'skill').
    """
    valid: list[dict] = []
    malformed_count = 0

    if not log_path.exists():
        return valid, malformed_count

    with log_path.open(encoding="utf-8") as fh:
        for lineno, raw in enumerate(fh, start=1):
            raw = raw.strip()
            if not raw:
                continue
            try:
                entry = json.loads(raw)
            except json.JSONDecodeError as exc:
                malformed_count += 1
                print(
                    f"[audit-skill-adoption] malformed line {lineno}: {exc}",
                    file=stderr,
                )
                continue

            missing = [f for f in _REQUIRED_FIELDS if f not in entry]
            if missing:
                malformed_count += 1
                print(
                    f"[audit-skill-adoption] malformed line {lineno}: "
                    f"missing required fields {missing}",
                    file=stderr,
                )
                continue

            valid.append(entry)

    return valid, malformed_count


# ---------------------------------------------------------------------------
# Dashboard generation
# ---------------------------------------------------------------------------


def _build_markdown(
    valid: list[dict],
    malformed_count: int,
    generated_at: str,
) -> str:
    """Return the full dashboard markdown string."""
    lines: list[str] = []
    lines.append("# Skill Adoption Dashboard")
    lines.append("")
    lines.append(f"_Generated: {generated_at}_")
    lines.append("")

    if not valid:
        lines.append("## No Invocation Data Available")
        lines.append("")
        lines.append(
            "> No invocation data available. "
            "The F4 log is empty or has not been written yet."
        )
        lines.append("")
        if malformed_count:
            lines.append(f"**Malformed lines skipped:** {malformed_count}")
            lines.append("")
        return "\n".join(lines)

    # Per-skill counts
    skill_counts: Counter = Counter(e["skill"] for e in valid)
    lines.append("## Per-Skill Invocation Counts")
    lines.append("")
    lines.append("| Skill | Count |")
    lines.append("|---|---|")
    for skill, count in skill_counts.most_common():
        lines.append(f"| {skill} | {count} |")
    lines.append("")

    # Per-agent counts
    agent_counts: Counter = Counter(e["agent_name"] for e in valid)
    lines.append("## Per-Agent Invocation Counts")
    lines.append("")
    lines.append("| Agent | Count |")
    lines.append("|---|---|")
    for agent, count in agent_counts.most_common():
        lines.append(f"| {agent} | {count} |")
    lines.append("")

    # Summary
    lines.append("## Summary")
    lines.append("")
    lines.append(f"- **Total valid invocations:** {len(valid)}")
    lines.append(f"- **Malformed lines skipped:** {malformed_count}")
    lines.append("")

    return "\n".join(lines)


# ---------------------------------------------------------------------------
# D15 anomaly detection
# ---------------------------------------------------------------------------


def _check_d15_anomaly(
    valid: list[dict],
    now: Optional[datetime] = None,
) -> dict[str, float]:
    """Return a mapping of skill → 7-day rate for skills triggering D15 anomaly."""
    if now is None:
        now = datetime.now(tz=timezone.utc)
    cutoff = now - timedelta(days=7)

    # Count total sessions and 7-day sessions per skill
    skill_total: Counter = Counter()
    skill_7d: Counter = Counter()

    for entry in valid:
        skill = entry["skill"]
        skill_total[skill] += 1
        try:
            ts = datetime.fromisoformat(entry["ts"].replace("Z", "+00:00"))
            if ts >= cutoff:
                skill_7d[skill] += 1
        except (ValueError, AttributeError):
            pass

    anomalies: dict[str, float] = {}
    for skill, total in skill_total.items():
        if total < _D15_MIN_SESSIONS:
            continue
        rate_7d = skill_7d[skill] / total
        if rate_7d < _D15_RATE_THRESHOLD:
            anomalies[skill] = rate_7d

    return anomalies


def _write_anomaly_notes(
    anomalies: dict[str, float],
    anomaly_path: Path,
    generated_at: str,
) -> None:
    """Write D15 anomaly notes to the given path."""
    lines: list[str] = []
    lines.append("# Skill Audit Notes (D15 Anomalies)")
    lines.append("")
    lines.append(f"_Generated: {generated_at}_")
    lines.append("")
    lines.append(
        f"Skills with rolling 7-day rate < {int(_D15_RATE_THRESHOLD * 100)}% "
        f"AND >= {_D15_MIN_SESSIONS} total sessions:"
    )
    lines.append("")
    lines.append("| Skill | 7-day Rate |")
    lines.append("|---|---|")
    for skill, rate in sorted(anomalies.items()):
        lines.append(f"| {skill} | {rate:.1%} |")
    lines.append("")

    anomaly_path.parent.mkdir(parents=True, exist_ok=True)
    anomaly_path.write_text("\n".join(lines), encoding="utf-8")


# ---------------------------------------------------------------------------
# D16 adaptive state (audit-state.json sidecar) + D14 escalation
# ---------------------------------------------------------------------------

_STATE_PATH = ".claude/state/audit-state.json"

# D16 adaptive sample sizing
_SAMPLE_INIT = 10
_SAMPLE_STEP = 5
_SAMPLE_CAP = 30

# D14 escalation / relaxation thresholds (consecutive windows)
_ESCALATE_AFTER_DIRTY = 3
_RELAX_AFTER_CLEAN = 3

# Refinement issue metadata (D14)
_REFINEMENT_LABEL = "type:audit-refinement"


def _load_state(state_path: Path) -> dict:
    """Load the D16 per-domain audit state sidecar.

    Returns an empty dict for a missing or unparseable file — never raises.
    Mirrors the log-parse tolerance so a corrupt sidecar degrades to a fresh
    start rather than crashing the audit run.
    """
    if not state_path.exists():
        return {}
    try:
        return json.loads(state_path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        return {}


def _save_state(state: dict, state_path: Path) -> None:
    """Write the D16 state sidecar atomically (tempfile + os.replace)."""
    import os
    import tempfile

    state_path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(
        dir=str(state_path.parent), prefix=".audit-state-", suffix=".tmp"
    )
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(state, fh, indent=2, sort_keys=True)
        os.replace(tmp_name, state_path)
    except BaseException:
        # Clean up the temp file on any failure so no partial artifact leaks.
        if os.path.exists(tmp_name):
            os.unlink(tmp_name)
        raise


def _evaluate_windows(
    valid: list[dict],
    prior_state: dict,
    now: Optional[datetime] = None,
) -> tuple[dict, dict]:
    """Classify each skill's current window and update D16 counters.

    A window is:
      - "insufficient" — fewer than _D15_MIN_SESSIONS sessions in the rolling
        7-day window; counters are preserved unchanged (no-op).
      - "dirty" — >= _D15_MIN_SESSIONS 7-day sessions AND total rate <
        _D15_RATE_THRESHOLD. Increments consecutive_dirty, resets
        consecutive_clean, grows current_sample_size by _SAMPLE_STEP (capped
        at _SAMPLE_CAP).
      - "clean" — >= _D15_MIN_SESSIONS 7-day sessions AND rate healthy.
        Increments consecutive_clean, resets consecutive_dirty.

    Returns (new_state, results) where results[skill] carries the
    classification plus the escalate / relaxed flags for the caller.
    """
    if now is None:
        now = datetime.now(tz=timezone.utc)
    cutoff = now - timedelta(days=7)

    skill_total: Counter = Counter()
    skill_7d: Counter = Counter()
    for entry in valid:
        skill = entry["skill"]
        skill_total[skill] += 1
        try:
            ts = datetime.fromisoformat(entry["ts"].replace("Z", "+00:00"))
            if ts >= cutoff:
                skill_7d[skill] += 1
        except (ValueError, AttributeError):
            pass

    new_state = dict(prior_state)
    results: dict = {}
    window_end = now.strftime("%Y-%m-%dT%H:%M:%SZ")

    for skill, total in skill_total.items():
        prev = dict(
            prior_state.get(
                skill,
                {
                    "consecutive_clean": 0,
                    "consecutive_dirty": 0,
                    "current_sample_size": _SAMPLE_INIT,
                    "last_window_end": "",
                },
            )
        )
        sessions_7d = skill_7d[skill]
        rate_7d = sessions_7d / total if total else 0.0

        if sessions_7d < _D15_MIN_SESSIONS:
            # Insufficient sample: preserve counters, no signal (AC-2).
            results[skill] = {
                "classification": "insufficient",
                "rate": rate_7d,
                "sessions_7d": sessions_7d,
                "escalate": False,
                "relaxed": False,
                "consecutive_dirty": prev["consecutive_dirty"],
            }
            new_state[skill] = prev
            continue

        if rate_7d < _D15_RATE_THRESHOLD:
            prev["consecutive_dirty"] = prev.get("consecutive_dirty", 0) + 1
            prev["consecutive_clean"] = 0
            prev["current_sample_size"] = min(
                prev.get("current_sample_size", _SAMPLE_INIT) + _SAMPLE_STEP,
                _SAMPLE_CAP,
            )
            classification = "dirty"
            escalate = prev["consecutive_dirty"] >= _ESCALATE_AFTER_DIRTY
            relaxed = False
        else:
            prev["consecutive_clean"] = prev.get("consecutive_clean", 0) + 1
            prev["consecutive_dirty"] = 0
            classification = "clean"
            escalate = False
            relaxed = prev["consecutive_clean"] >= _RELAX_AFTER_CLEAN

        prev["last_window_end"] = window_end
        new_state[skill] = prev
        results[skill] = {
            "classification": classification,
            "rate": rate_7d,
            "sessions_7d": sessions_7d,
            "escalate": escalate,
            "relaxed": relaxed,
            "consecutive_dirty": prev["consecutive_dirty"],
        }

    return new_state, results


def _open_refinement_issue(
    skill: str,
    rate: float,
    issue_runner=None,
) -> bool:
    """Open a `type:audit-refinement` GitHub Issue via an injectable runner.

    `issue_runner` defaults to `subprocess.run`; tests inject a stub so no real
    `gh` call is made. Returns True on success (returncode 0), False on any
    failure or exception (tracker unreachable) — never raises. The caller is
    responsible for still recording the audit note when this returns False
    (AC-4).
    """
    if issue_runner is None:
        import subprocess

        def issue_runner(cmd):  # noqa: E731
            return subprocess.run(cmd, capture_output=True, text=True, check=False)

    title = f"[audit-refinement] Low adoption for {skill}"
    body = (
        f"Automated D14 escalation: skill `{skill}` has recorded a rolling "
        f"7-day adoption rate of {rate:.1%}, below the D15 threshold, for "
        f"{_ESCALATE_AFTER_DIRTY} consecutive audit windows. R&D escalation per "
        f"the S9 runbook — triage and drive an F1 bundle refinement."
    )
    cmd = [
        "gh",
        "issue",
        "create",
        "--title",
        title,
        "--body",
        body,
        "--label",
        _REFINEMENT_LABEL,
    ]
    try:
        result = issue_runner(cmd)
    except Exception:  # noqa: BLE001 — tracker unreachable must not raise
        return False
    return getattr(result, "returncode", 1) == 0


def _append_adaptive_note(
    skill: str,
    result: dict,
    sample_size: int,
    anomaly_path: Path,
    generated_at: str,
    issue_opened: bool,
) -> None:
    """Append (not overwrite) a dated adaptive audit-note entry (D14/D16)."""
    anomaly_path.parent.mkdir(parents=True, exist_ok=True)
    header_needed = not anomaly_path.exists()
    lines: list[str] = []
    if header_needed:
        lines.append("# Skill Audit Notes (adaptive)")
        lines.append("")
    escalated = (
        " — **escalated** (issue opened)"
        if issue_opened
        else (
            " — **escalation attempted, tracker unreachable**"
            if result.get("escalate")
            else ""
        )
    )
    lines.append(
        f"- {generated_at} · `{skill}` · 7-day rate {result['rate']:.1%} · "
        f"{result['sessions_7d']} sessions · sample {sample_size} · "
        f"dirty×{result['consecutive_dirty']}{escalated}"
    )
    with anomaly_path.open("a", encoding="utf-8") as fh:
        fh.write("\n".join(lines) + "\n")


def run_adaptive_audit(
    valid: list[dict],
    state_path: Path,
    anomaly_path: Path,
    dry_run: bool,
    issue_runner=None,
    stdout: IO[str] = sys.stdout,
    stderr: IO[str] = sys.stderr,
    now: Optional[datetime] = None,
) -> dict:
    """Run the full D14/D15/D16 adaptive audit pass over parsed log entries.

    Loads prior state, classifies each skill's window, and for dirty windows:
    appends a dated audit note; on the 3rd consecutive dirty window opens a
    `type:audit-refinement` issue (recording the note even if the tracker is
    unreachable, AC-4). Under `dry_run` reports fired signals to stdout and
    performs NO state write, NO note write, and NO issue-runner call (AC-3).

    Returns a summary dict: {"dirty": [...], "escalated": [...],
    "issues_opened": <N>}.
    """
    if now is None:
        now = datetime.now(tz=timezone.utc)
    generated_at = now.strftime("%Y-%m-%dT%H:%M:%SZ")

    prior_state = _load_state(state_path)
    new_state, results = _evaluate_windows(valid, prior_state, now=now)

    dirty = [s for s, r in results.items() if r["classification"] == "dirty"]
    escalated = [s for s, r in results.items() if r.get("escalate")]

    if dry_run:
        for skill in sorted(dirty):
            r = results[skill]
            print(
                f"[audit] SIGNAL {skill}: 7-day rate {r['rate']:.1%} "
                f"({r['sessions_7d']} sessions, dirty×{r['consecutive_dirty']})"
                f"{' [would escalate]' if r.get('escalate') else ''}",
                file=stdout,
            )
        return {
            "dirty": dirty,
            "escalated": escalated,
            "issues_opened": 0,
            "dry_run": True,
        }

    issues_opened = 0
    for skill in sorted(dirty):
        r = results[skill]
        issue_opened = False
        if r.get("escalate"):
            issue_opened = _open_refinement_issue(
                skill, r["rate"], issue_runner=issue_runner
            )
            if issue_opened:
                issues_opened += 1
            else:
                print(
                    f"[audit] warn: could not open refinement issue for "
                    f"{skill} (tracker unreachable); note still recorded.",
                    file=stderr,
                )
        _append_adaptive_note(
            skill,
            r,
            new_state.get(skill, {}).get("current_sample_size", _SAMPLE_INIT),
            anomaly_path,
            generated_at,
            issue_opened,
        )

    _save_state(new_state, state_path)

    return {
        "dirty": dirty,
        "escalated": escalated,
        "issues_opened": issues_opened,
        "dry_run": False,
    }


# ---------------------------------------------------------------------------
# Public API (used by tests)
# ---------------------------------------------------------------------------


def generate_dashboard(
    log_path: Path,
    output_path: Path,
    dry_run: bool,
    stdout: IO[str] = sys.stdout,
    stderr: IO[str] = sys.stderr,
    anomaly_path: Optional[Path] = None,
    run_adaptive: bool = False,
    state_path: Optional[Path] = None,
    issue_runner=None,
) -> dict:
    """Parse log, build dashboard, write or print.

    When `run_adaptive` is True, the D14/D15/D16 adaptive audit pass runs after
    the dashboard (stateful sample sizing + 3-dirty escalation). It honours
    `dry_run` identically to the dashboard: under dry-run it reports fired
    signals to stdout and writes nothing / makes no gh calls (AC-3).

    Returns a dict with keys:
        valid_count      — number of D31-valid log lines processed
        malformed_count  — number of malformed lines skipped
        adaptive         — the run_adaptive_audit summary, or None when not run
    """
    valid, malformed_count = _parse_log(log_path, stderr=stderr)
    generated_at = datetime.now(tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    markdown = _build_markdown(valid, malformed_count, generated_at)

    if dry_run:
        print(markdown, file=stdout)
    else:
        output_path.parent.mkdir(parents=True, exist_ok=True)
        output_path.write_text(markdown, encoding="utf-8")

        # D15 anomaly check and write (not under --dry-run)
        if valid:
            anomalies = _check_d15_anomaly(valid)
            if anomalies:
                _apath = anomaly_path or Path(_ANOMALY_OUTPUT_PATH)
                _write_anomaly_notes(anomalies, _apath, generated_at)

    adaptive_summary = None
    if run_adaptive and valid:
        adaptive_summary = run_adaptive_audit(
            valid=valid,
            state_path=state_path or Path(_STATE_PATH),
            anomaly_path=anomaly_path or Path(_ANOMALY_OUTPUT_PATH),
            dry_run=dry_run,
            issue_runner=issue_runner,
            stdout=stdout,
            stderr=stderr,
        )

    return {
        "valid_count": len(valid),
        "malformed_count": malformed_count,
        "adaptive": adaptive_summary,
    }


# ---------------------------------------------------------------------------
# CLI entry point
# ---------------------------------------------------------------------------


def main(argv: Optional[list[str]] = None) -> None:
    parser = argparse.ArgumentParser(
        description="Analyze F4 skill-invocation log and produce skill-adoption dashboard.",
    )
    parser.add_argument(
        "--log-path",
        default=_DEFAULT_LOG_PATH,
        help=f"Path to JSONL log (default: {_DEFAULT_LOG_PATH})",
    )
    parser.add_argument(
        "--output-path",
        default=_DEFAULT_OUTPUT_PATH,
        help=f"Path to write dashboard markdown (default: {_DEFAULT_OUTPUT_PATH})",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        default=False,
        help="Print dashboard to stdout; do not write any files or make gh calls.",
    )
    parser.add_argument(
        "--adaptive",
        action="store_true",
        default=False,
        help=(
            "Run the D14/D15/D16 adaptive audit pass (stateful sample sizing, "
            "3-dirty escalation) after the dashboard. Under --dry-run, reports "
            "fired signals without writing state, notes, or opening issues."
        ),
    )
    parser.add_argument(
        "--state-path",
        default=_STATE_PATH,
        help=f"Path to the D16 audit-state sidecar (default: {_STATE_PATH})",
    )
    args = parser.parse_args(argv)

    generate_dashboard(
        log_path=Path(args.log_path),
        output_path=Path(args.output_path),
        dry_run=args.dry_run,
        run_adaptive=args.adaptive,
        state_path=Path(args.state_path),
    )


if __name__ == "__main__":
    main()
