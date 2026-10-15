"""Fail-closed contract for the intentional-security-fixture gate."""

import importlib.util
import json
import subprocess
from pathlib import Path
from unittest.mock import patch

import pytest

spec = importlib.util.spec_from_file_location("security_fixture_gate", Path(__file__).resolve().parents[1] / "scripts/check-security-fixtures.py")
assert spec is not None and spec.loader is not None
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)


def valid_report():
    return {
        "errors": [],
        "results": [{"check_id": rule, "path": str(gate.FIXTURE), "start": {"line": line, "col": 1}, "end": {"line": line, "col": 20}} for rule, line in gate.EXPECTED],
    }


def run_gate(report, code=1):
    output = report if isinstance(report, str) else json.dumps(report)
    with patch.object(gate.subprocess, "run", return_value=subprocess.CompletedProcess([], code, output, "")):
        return gate.main()


def test_exact_expected_findings_are_accepted():
    assert run_gate(valid_report()) == 0


@pytest.mark.parametrize("case", ["missing", "duplicate", "rule", "path", "missing-start", "line", "boolean-line", "end-line", "column", "errors", "results", "json", "non-object"])
def test_incomplete_or_unexpected_findings_are_rejected(case):
    report = valid_report()
    first = report["results"][0]
    if case == "missing":
        report["results"].pop()
    elif case == "duplicate":
        report["results"].append(first)
    elif case == "rule":
        first["check_id"] = "unexpected.rule"
    elif case == "path":
        first["path"] = "production.py"
    elif case == "missing-start":
        del first["start"]
    elif case == "line":
        first["start"]["line"] = first["end"]["line"] = 1
    elif case == "boolean-line":
        first["start"]["line"] = True
    elif case == "end-line":
        first["end"]["line"] += 1
    elif case == "column":
        first["end"]["col"] = 0
    elif case == "errors":
        report["errors"] = [{"message": "incomplete scan"}]
    elif case == "results":
        del report["results"]
    elif case == "json":
        report = "{"
    elif case == "non-object":
        report = []
    assert run_gate(report) == 1


@pytest.mark.parametrize("code", [0, 2, 127])
def test_wrong_scanner_exit_status_is_rejected(code):
    assert run_gate(valid_report(), code) == 1


def test_unavailable_scanner_is_rejected():
    with patch.object(gate.subprocess, "run", side_effect=FileNotFoundError("semgrep")):
        assert gate.main() == 1
