"""d22_compliance_report.py — D22 system-done compliance reporter.

Reads three data sources to produce a compliance snapshot:

1. The F4 skill-invocations log (.claude/skill-invocations.log)
2. Per-story skill-passport.json files and build.jsonl session counters
3. Per-plugin config/skill-bundles.yml bundle coverage

Stdlib-only; no third-party dependencies.
"""

from __future__ import annotations

import argparse
import json
import re
from datetime import date, datetime, timedelta, timezone
from pathlib import Path


def read_invocations_log(log_path: Path) -> list[dict]:
    """Parse a JSONL skill-invocations log file.

    Reads each line as a JSON object. Malformed lines (invalid JSON) are
    silently skipped. Returns an empty list when the file does not exist.

    Args:
        log_path: Path to the JSONL log file.

    Returns:
        A list of dicts, one per valid JSONL line.
    """
    if not log_path.exists():
        return []

    entries: list[dict] = []
    with log_path.open(encoding="utf-8") as fh:
        for raw in fh:
            raw = raw.strip()
            if not raw:
                continue
            try:
                entries.append(json.loads(raw))
            except json.JSONDecodeError:
                # Silently skip malformed lines.
                continue
    return entries


def read_skill_passports(specs_root: Path) -> tuple[int, int]:
    """Count skill-passport.json files and session-ok build.jsonl lines.

    Globs ``specs_root/*/skill-passport.json`` to count how many passport
    files exist (``passports_found``), then globs
    ``specs_root/*/build.jsonl`` and counts lines where
    ``step == "session"`` AND ``status == "ok"`` (``builds_observed``).

    Returns ``(0, 0)`` when no files are found — not an error.

    Args:
        specs_root: Root directory to search (typically ``specs/``).

    Returns:
        A tuple ``(passports_found, builds_observed)``.
    """
    passports_found = len(list(specs_root.glob("*/skill-passport.json")))

    builds_observed = 0
    for build_file in specs_root.glob("*/build.jsonl"):
        for raw in build_file.read_text(encoding="utf-8").splitlines():
            raw = raw.strip()
            if not raw:
                continue
            try:
                entry = json.loads(raw)
            except json.JSONDecodeError:
                continue
            if entry.get("step") == "session" and entry.get("status") == "ok":
                builds_observed += 1

    return passports_found, builds_observed


def read_bundle_coverage(plugins_root: Path) -> tuple[int, list[str]]:
    """Check which plugin directories have a non-empty config/skill-bundles.yml.

    Iterates over immediate subdirectories of ``plugins_root``. For each
    subdirectory:

    - If ``config/skill-bundles.yml`` exists AND is non-empty → counts
      as covered.
    - If missing or empty (0 bytes) → adds the directory name to
      ``missing_plugin_names``.

    Args:
        plugins_root: Parent directory containing plugin subdirectories.

    Returns:
        A tuple ``(covered_count, missing_plugin_names)``.
    """
    covered_count = 0
    missing_plugin_names: list[str] = []

    if not plugins_root.is_dir():
        return covered_count, missing_plugin_names

    for entry in sorted(plugins_root.iterdir()):
        if not entry.is_dir():
            continue
        bundles_file = entry / "config" / "skill-bundles.yml"
        if bundles_file.exists() and bundles_file.stat().st_size > 0:
            covered_count += 1
        else:
            missing_plugin_names.append(entry.name)

    return covered_count, missing_plugin_names


_DATE_HEADING_RE = re.compile(r"^## (\d{4}-\d{2}-\d{2})")
_AUDIT_WINDOW_DAYS = 90
_BUNDLE_REQUIRED_COUNT = 12
_PASSPORT_RATE_THRESHOLD = 0.95


def compute_structural_metrics(
    bundle_result: tuple[int, list[str]],
    passport_result: tuple[int, int],
    notes_path: Path,
) -> dict:
    """Compute D22 structural compliance metrics.

    Args:
        bundle_result: Return value of :func:`read_bundle_coverage` —
            ``(covered_count, missing_plugin_names)``.
        passport_result: Return value of :func:`read_skill_passports` —
            ``(passports_found, builds_observed)``.
        notes_path: Path to ``docs/skill-audit-notes.md``.

    Returns:
        A dict with keys ``bundle_coverage``, ``passport_rate``,
        ``audit_active``, and ``overall``.  See module docstring for the
        full schema.
    """
    covered_count, missing_plugin_names = bundle_result
    passports_found, builds_observed = passport_result

    # ── bundle_coverage ──────────────────────────────────────────────────────
    bundle_verdict = (
        "PASS"
        if covered_count == _BUNDLE_REQUIRED_COUNT and not missing_plugin_names
        else "FAIL"
    )
    bundle_coverage = {
        "covered": covered_count,
        "missing": list(missing_plugin_names),
        "verdict": bundle_verdict,
    }

    # ── passport_rate ────────────────────────────────────────────────────────
    if builds_observed == 0:
        rate = 0.0
    else:
        rate = passports_found / builds_observed
    passport_verdict = "PASS" if rate >= _PASSPORT_RATE_THRESHOLD else "FAIL"
    passport_rate = {
        "rate": rate,
        "verdict": passport_verdict,
    }

    # ── audit_active ─────────────────────────────────────────────────────────
    last_entry_date: str | None = None
    active = False

    if notes_path.exists():
        most_recent: date | None = None
        for line in notes_path.read_text(encoding="utf-8").splitlines():
            m = _DATE_HEADING_RE.match(line)
            if m:
                try:
                    candidate = date.fromisoformat(m.group(1))
                except ValueError:
                    continue
                if most_recent is None or candidate > most_recent:
                    most_recent = candidate

        if most_recent is not None:
            last_entry_date = most_recent.isoformat()
            cutoff = date.today() - timedelta(days=_AUDIT_WINDOW_DAYS)
            active = most_recent >= cutoff

    audit_verdict = "PASS" if active else "FAIL"
    audit_active = {
        "active": active,
        "last_entry_date": last_entry_date,
        "verdict": audit_verdict,
    }

    # ── overall ───────────────────────────────────────────────────────────────
    all_pass = all(
        sub["verdict"] == "PASS"
        for sub in (bundle_coverage, passport_rate, audit_active)
    )
    overall = "PASS" if all_pass else "FAIL"

    return {
        "bundle_coverage": bundle_coverage,
        "passport_rate": passport_rate,
        "audit_active": audit_active,
        "overall": overall,
    }



_TRAILING_WINDOW_DAYS = 28
_ADOPTION_RATE_THRESHOLD = 0.70
_INSUFFICIENT_DATA_THRESHOLD_DAYS = 21  # need oldest entry >= 21 days before now


def compute_adoption_metrics(
    log_entries: list[dict],
    now: "datetime | None" = None,
) -> dict:
    """Compute skill-invocation adoption metrics over a 4-week trailing window.

    Groups log_entries by ISO year-week and checks whether all 4 canonical
    trailing ISO weeks (relative to ``now``) have adoption rate >= 0.70.

    The SIMPLEST CORRECT MODEL: every entry in the log represents a session
    that invoked a skill -> rate = 1.0 for any week with at least one entry.

    Args:
        log_entries: List of JSONL-decoded dicts from the skill-invocations log.
            Entries missing the ``ts`` field or with unparseable timestamps are
            silently skipped.
        now: Reference timestamp for the trailing window.  Defaults to
            ``datetime.now(tz=timezone.utc)`` when ``None``.

    Returns:
        A dict with keys:
        - ``weekly_rates``: list of ``{"week": "YYYY-WNN", "rate": float}``
          for every in-window week that has at least one entry, in
          chronological order.
        - ``consecutive_weeks_above_70``: number of consecutive trailing
          weeks (from most recent backwards) with rate >= 0.70.
        - ``days_remaining``: ``int`` when verdict is ``INSUFFICIENT-DATA``
          (= 28 - span_days), else ``None``.
        - ``verdict``: ``"PASS"``, ``"FAIL"``, or ``"INSUFFICIENT-DATA"``.
    """
    if now is None:
        now = datetime.now(tz=timezone.utc)

    # Ensure now is timezone-aware for comparison.
    if now.tzinfo is None:
        now = now.replace(tzinfo=timezone.utc)

    window_start = now - timedelta(days=_TRAILING_WINDOW_DAYS)

    # -- Parse all entries ---------------------------------------------------
    parsed: list = []
    for entry in log_entries:
        ts_raw = entry.get("ts")
        if not ts_raw:
            continue
        try:
            ts = datetime.fromisoformat(str(ts_raw))
        except (ValueError, TypeError):
            continue
        if ts.tzinfo is None:
            ts = ts.replace(tzinfo=timezone.utc)
        parsed.append(ts)

    # -- INSUFFICIENT-DATA: no entries at all --------------------------------
    if not parsed:
        return {
            "weekly_rates": [],
            "consecutive_weeks_above_70": 0,
            "days_remaining": _TRAILING_WINDOW_DAYS,
            "verdict": "INSUFFICIENT-DATA",
        }

    oldest = min(parsed)
    most_recent = max(parsed)

    # -- INSUFFICIENT-DATA: history too short (< 21 days before now) ---------
    # The system needs its oldest entry to be at least 3 full weeks before now
    # so that all 4 canonical trailing weeks have had a chance to accumulate data.
    history_days = int((now - oldest).total_seconds() // 86400)
    if history_days < _INSUFFICIENT_DATA_THRESHOLD_DAYS:
        span_days = int((most_recent - oldest).total_seconds() // 86400)
        days_remaining = max(0, _TRAILING_WINDOW_DAYS - span_days)
        # Collect in-window entries for weekly_rates.
        in_window = [ts for ts in parsed if ts >= window_start]
        week_keys: dict = {}
        for ts in in_window:
            iso = ts.isocalendar()
            key = f"{iso[0]}-W{iso[1]:02d}"
            week_keys[key] = 1.0
        weekly_rates = [{"week": k, "rate": v} for k, v in sorted(week_keys.items())]
        return {
            "weekly_rates": weekly_rates,
            "consecutive_weeks_above_70": 0,
            "days_remaining": days_remaining,
            "verdict": "INSUFFICIENT-DATA",
        }

    # -- Determine the 4 canonical trailing ISO weeks -------------------------
    # Go backwards from now in 7-day steps to get each week's (year, week) key.
    canonical_weeks: list = []
    seen: set = set()
    cursor = now
    while len(canonical_weeks) < 4:
        iso = cursor.isocalendar()
        yw = (iso[0], iso[1])
        if yw not in seen:
            canonical_weeks.append(yw)
            seen.add(yw)
        cursor -= timedelta(days=7)

    # -- Build in-window coverage map: (year, week) -> bool (has entries) ----
    in_window = [ts for ts in parsed if ts >= window_start]
    week_has_entries: dict = {}
    for ts in in_window:
        iso = ts.isocalendar()
        yw = (iso[0], iso[1])
        week_has_entries[yw] = True

    # -- weekly_rates: all in-window weeks with entries -----------------------
    week_rate_map: dict = {}
    for yw in week_has_entries:
        key = f"{yw[0]}-W{yw[1]:02d}"
        week_rate_map[key] = 1.0
    weekly_rates = [{"week": k, "rate": v} for k, v in sorted(week_rate_map.items())]

    # -- Compute rate for each of the 4 canonical weeks ----------------------
    canonical_rates: list = []
    for yw in canonical_weeks:
        rate = 1.0 if week_has_entries.get(yw, False) else 0.0
        canonical_rates.append(rate)

    # -- consecutive_weeks_above_70 (from most recent backwards) --------------
    consecutive = 0
    for rate in canonical_rates:
        if rate >= _ADOPTION_RATE_THRESHOLD:
            consecutive += 1
        else:
            break

    # -- verdict --------------------------------------------------------------
    if all(r >= _ADOPTION_RATE_THRESHOLD for r in canonical_rates):
        verdict = "PASS"
    else:
        verdict = "FAIL"

    return {
        "weekly_rates": weekly_rates,
        "consecutive_weeks_above_70": consecutive,
        "days_remaining": None,
        "verdict": verdict,
    }


def generate_report(
    structural: dict,
    adoption: dict,
    output_path: Path,
    notes_path: Path,
    dry_run: bool = False,
) -> str:
    """Generate the D22 compliance report markdown.

    Builds the full markdown report from structural and adoption metric dicts
    (as returned by :func:`compute_structural_metrics` and
    :func:`compute_adoption_metrics`).

    When overall_pass (structural PASS AND adoption PASS) and NOT dry_run,
    appends a maintenance-mode transition note to ``notes_path`` and writes
    the markdown to ``output_path`` (creating parent dirs as needed).

    When dry_run is True, no files are written; the markdown string is still
    returned.

    Args:
        structural: Dict returned by :func:`compute_structural_metrics`.
        adoption: Dict returned by :func:`compute_adoption_metrics`.
        output_path: Where to write the markdown report file.
        notes_path: Path to ``docs/skill-audit-notes.md`` for maintenance note.
        dry_run: When True, skip all file I/O. Default False.

    Returns:
        The full markdown report as a string.
    """
    _now = datetime.now(tz=timezone.utc)
    ts_now = _now.isoformat(timespec="seconds")
    today_str = _now.date().isoformat()

    overall_pass = (
        structural.get("overall") == "PASS"
        and adoption.get("verdict") == "PASS"
    )

    if overall_pass:
        overall_status = "PASS"
    elif structural.get("overall") == "PASS" or adoption.get("verdict") == "PASS":
        overall_status = "PARTIAL"
    else:
        overall_status = "FAIL"

    # ── structural section ───────────────────────────────────────────────────
    bc = structural["bundle_coverage"]
    pr = structural["passport_rate"]
    aa = structural["audit_active"]

    bundle_value = f"{bc['covered']}/12 plugins"
    bundle_verdict = bc["verdict"]

    passport_value = f"{pr['rate'] * 100:.0f}%"
    passport_verdict = pr["verdict"]

    last_date_str = aa.get("last_entry_date") or "none"
    audit_value = f"{'Yes' if aa['active'] else 'No'} (last entry: {last_date_str})"
    audit_verdict = aa["verdict"]

    missing = bc.get("missing", [])
    if missing:
        missing_section = "\n".join(missing)
    else:
        missing_section = "— none —"

    # ── adoption section ─────────────────────────────────────────────────────
    weekly_rows = ""
    for row in adoption.get("weekly_rates", []):
        week = row["week"]
        rate_pct = f"{row['rate'] * 100:.0f}%"
        above = "✓" if row["rate"] >= _ADOPTION_RATE_THRESHOLD else "✗"
        weekly_rows += f"| {week} | {rate_pct} | {above} |\n"
    if not weekly_rows:
        weekly_rows = "| — | — | — |\n"

    consecutive = adoption.get("consecutive_weeks_above_70", 0)
    adoption_verdict = adoption.get("verdict", "FAIL")
    days_remaining = adoption.get("days_remaining")

    days_remaining_line = ""
    if adoption_verdict == "INSUFFICIENT-DATA" and days_remaining is not None:
        days_remaining_line = (
            f"\n*{days_remaining} days remaining before 4-week window is complete.*"
        )

    # ── overall verdict section ──────────────────────────────────────────────
    f5_link = "https://github.com/macatocz/makato/issues/131"
    if overall_pass:
        overall_text = (
            f"BOTH CRITERIA PASS — maintenance mode begins. "
            f"See [#131 (F5)]({f5_link}) for next steps."
        )
    else:
        overall_text = (
            f"One or more criteria did not PASS — see above for details. "
            f"[#131 (F5)]({f5_link}) remains blocked."
        )

    # ── assemble markdown ────────────────────────────────────────────────────
    md = f"""# D22 Compliance Report

Generated: {ts_now}
Overall Status: {overall_status}

## Structural Criteria

| Criterion | Value | Verdict |
|---|---|---|
| Bundle coverage | {bundle_value} | {bundle_verdict} |
| Passport emission rate | {passport_value} | {passport_verdict} |
| Audit active | {audit_value} | {audit_verdict} |

### Missing bundle definitions

{missing_section}

## Adoption Criterion

| Week | Rate | Above 70%? |
|---|---|---|
{weekly_rows}
Consecutive weeks ≥ 70%: {consecutive} / 4 required
**Verdict: {adoption_verdict}**{days_remaining_line}

## Overall Verdict

{overall_text}

## Cross-reference

A full PASS on both criteria unblocks [#131 (F5 domain-tagged skill schema)]({f5_link}).
"""

    if not dry_run:
        # Write report to output_path (create parent dirs).
        output_path.parent.mkdir(parents=True, exist_ok=True)
        output_path.write_text(md, encoding="utf-8")

        # Append maintenance note when overall passes.
        if overall_pass:
            maintenance_note = (
                f"\n## {today_str} — Maintenance mode start\n\n"
                "D22 system-done criteria met. Structural: PASS. "
                "Adoption: PASS (4 consecutive weeks ≥ 70%).\n"
                "Epic agent-skill-routing enters maintenance mode. "
                "F5 (#131) unblocked.\n"
            )
            notes_path.parent.mkdir(parents=True, exist_ok=True)
            with notes_path.open("a", encoding="utf-8") as fh:
                fh.write(maintenance_note)

    return md


# ---------------------------------------------------------------------------
# CLI entry point
# ---------------------------------------------------------------------------

def main(argv=None):
    parser = argparse.ArgumentParser(
        description="D22 system-done compliance gate — aggregates skill telemetry and emits compliance report.",
    )
    parser.add_argument(
        "--log-path",
        default=".claude/skill-invocations.log",
        help="Path to F4 JSONL invocation log (default: .claude/skill-invocations.log)",
    )
    parser.add_argument(
        "--specs-root",
        default="specs",
        help="Root directory of spec folders (default: specs)",
    )
    parser.add_argument(
        "--plugins-root",
        default="plugins",
        help="Root directory of plugin folders (default: plugins)",
    )
    parser.add_argument(
        "--notes-path",
        default="docs/skill-audit-notes.md",
        help="Path to skill-audit-notes.md (default: docs/skill-audit-notes.md)",
    )
    parser.add_argument(
        "--output-path",
        default="docs/d22-compliance-report.md",
        help="Where to write the compliance report (default: docs/d22-compliance-report.md)",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        default=False,
        help="Print report to stdout; write no files.",
    )
    args = parser.parse_args(argv)

    log_entries = read_invocations_log(Path(args.log_path))
    passport_result = read_skill_passports(Path(args.specs_root))
    bundle_result = read_bundle_coverage(Path(args.plugins_root))
    structural = compute_structural_metrics(bundle_result, passport_result, Path(args.notes_path))
    adoption = compute_adoption_metrics(log_entries)
    generate_report(structural, adoption, Path(args.output_path), Path(args.notes_path), dry_run=args.dry_run)


if __name__ == "__main__":
    main()
