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
from datetime import datetime, timezone, timedelta
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
            lines.append(
                f"**Malformed lines skipped:** {malformed_count}"
            )
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
# Public API (used by tests)
# ---------------------------------------------------------------------------


def generate_dashboard(
    log_path: Path,
    output_path: Path,
    dry_run: bool,
    stdout: IO[str] = sys.stdout,
    stderr: IO[str] = sys.stderr,
    anomaly_path: Optional[Path] = None,
) -> dict:
    """Parse log, build dashboard, write or print.

    Returns a dict with keys:
        valid_count      — number of D31-valid log lines processed
        malformed_count  — number of malformed lines skipped
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

    return {
        "valid_count": len(valid),
        "malformed_count": malformed_count,
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
    args = parser.parse_args(argv)

    generate_dashboard(
        log_path=Path(args.log_path),
        output_path=Path(args.output_path),
        dry_run=args.dry_run,
    )


if __name__ == "__main__":
    main()
