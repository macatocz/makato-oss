#!/usr/bin/env python3
"""Require the intentionally vulnerable fixture to retain its security findings."""

from __future__ import annotations

import json
import subprocess
import sys
from collections import Counter
from pathlib import Path

FIXTURE = Path("plugins/makato-build/skills/build-fix-security/test-fixtures/bandit-sample.py")
EXPECTED = Counter(
    {
        ("python.lang.security.deserialization.avoid-pyyaml-load.avoid-pyyaml-load", 40): 1,
        ("python.lang.security.audit.subprocess-shell-true.subprocess-shell-true", 63): 1,
        ("python.lang.security.deserialization.pickle.avoid-pickle", 93): 1,
        ("python.lang.security.audit.eval-detected.eval-detected", 101): 1,
    }
)


def main() -> int:
    root = Path(__file__).resolve().parents[1]
    try:
        run = subprocess.run(
            ["semgrep", "--config", "auto", "--json", "--error", str(FIXTURE)],
            cwd=root,
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            check=False,
        )
    except OSError as exc:
        print(f"Cannot run security fixture scan: {exc}", file=sys.stderr)
        return 1
    if run.returncode != 1:
        print(f"Expected security findings (exit 1), got exit {run.returncode}", file=sys.stderr)
        print(run.stderr, file=sys.stderr)
        return 1
    try:
        report = json.loads(run.stdout)
    except ValueError as exc:
        print(f"Invalid scanner JSON: {exc}", file=sys.stderr)
        return 1
    if not isinstance(report, dict) or report.get("errors"):
        print(f"Security fixture scan incomplete: {report}", file=sys.stderr)
        return 1
    results = report.get("results")
    if not isinstance(results, list):
        print("Security fixture scan omitted results", file=sys.stderr)
        return 1
    observed: Counter[tuple[str, int]] = Counter()
    for finding in results:
        if not isinstance(finding, dict) or not isinstance(finding.get("check_id"), str) or not isinstance(finding.get("path"), str):
            print("Malformed security fixture finding", file=sys.stderr)
            return 1
        if (root / finding["path"]).resolve() != (root / FIXTURE).resolve():
            print("Security fixture scan returned an unexpected file", file=sys.stderr)
            return 1
        start, end = finding.get("start"), finding.get("end")
        if not isinstance(start, dict) or not isinstance(end, dict):
            print("Missing finding location", file=sys.stderr)
            return 1
        if any(type(position.get(key)) is not int or position[key] < 1 for position in (start, end) for key in ("line", "col")):
            print("Malformed finding location", file=sys.stderr)
            return 1
        if start["line"] != end["line"] or end["col"] <= start["col"]:
            print("Unexpected finding span", file=sys.stderr)
            return 1
        observed[(finding["check_id"], start["line"])] += 1
    if observed != EXPECTED:
        print(f"Missing findings: {dict(EXPECTED - observed)}", file=sys.stderr)
        print(f"Unexpected findings: {dict(observed - EXPECTED)}", file=sys.stderr)
        return 1
    print("Security negative fixture: all four expected findings detected")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
