"""Behavioral tests for gate-command acceleration: what may be parallelised or selected incrementally, and what must stay serial."""

from __future__ import annotations

import json
import shlex
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

_HERE = Path(__file__).resolve().parent
if str(_HERE) not in sys.path:
    sys.path.insert(0, str(_HERE))

import pytest_accel  # noqa: E402

PLAIN_ENV = {"PATH": "/usr/bin"}
# `coverage run` never fails on a threshold (`coverage report` does); pytest-cov would exit 1 on the project's fail_under, which reads as a test failure.
NO_THRESHOLD = "--cov-fail-under=0"


def _plugin(importable: bool, via: str = "environment", reason: str = "") -> dict:
    return {"importable": importable, "via": via if importable else "none", "reason": "" if importable else (reason or "No module named")}


class AccelTestCase(unittest.TestCase):
    runner_prefix = ""

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.repo = self._tmp.name
        subprocess.run(["git", "init", "-q", self.repo], check=True)

    def seed(self, xdist: dict | None = None, testmon: dict | None = None, runner_prefix: str | None = None, baseline: bool = True) -> None:
        """Pre-populate the detect cache (and a recorded testmon baseline) in their documented formats, so rewrite rules are tested without probing interpreters."""
        report = {
            "repo_root": self.repo,
            "runner_prefix": self.runner_prefix if runner_prefix is None else runner_prefix,
            "xdist": xdist or _plugin(True),
            "testmon": testmon or _plugin(True),
            "pytest-cov": _plugin(True),
        }
        directory = pytest_accel.state_dir(self.repo)
        (directory / "detect.json").write_text(json.dumps(report), encoding="utf-8")
        if baseline:
            (directory / "testmondata").write_text("recorded", encoding="utf-8")

    def rewrite(self, command: str, lane: str = "unit", purpose: str = "full", env: dict[str, str] | None = None, runner_prefix: str | None = None) -> dict:
        return pytest_accel.rewrite(self.repo, command, lane, purpose, self.runner_prefix if runner_prefix is None else runner_prefix, env=PLAIN_ENV if env is None else env)


class XdistRewriteTests(AccelTestCase):
    def test_plain_pytest_gets_workers(self) -> None:
        self.seed()

        result = self.rewrite("pytest tests/unit -q")

        self.assertTrue(result["accelerated"])
        self.assertEqual(shlex.split(result["command"]), ["pytest", "-n", "auto", "tests/unit", "-q"])
        self.assertEqual(result["serial_command"], "pytest tests/unit -q")
        self.assertEqual(result["plugins"], ["xdist"])

    def test_pytest_cov_is_parallelised_because_it_merges_worker_data(self) -> None:
        self.seed()

        result = self.rewrite("pytest --cov=pkg --cov-report=term-missing")

        self.assertEqual(shlex.split(result["command"]), ["pytest", "-n", "auto", "--cov=pkg", "--cov-report=term-missing"])

    def test_coverage_py_runner_becomes_pytest_cov_so_workers_are_measured(self) -> None:
        self.seed()

        for command, expected in (
            ("coverage run -m pytest", ["python3", "-m", "pytest", "-n", "auto", "--cov", NO_THRESHOLD, "--cov-report="]),
            ("coverage run -m pytest tests/unit -q", ["python3", "-m", "pytest", "-n", "auto", "--cov", NO_THRESHOLD, "--cov-report=", "tests/unit", "-q"]),
            ("coverage run --append -m pytest tests/unit", ["python3", "-m", "pytest", "-n", "auto", "--cov", "--cov-append", NO_THRESHOLD, "--cov-report=", "tests/unit"]),
            ("coverage run --source=src,lib --branch -m pytest", ["python3", "-m", "pytest", "-n", "auto", "--cov=src", "--cov=lib", "--cov-branch", NO_THRESHOLD, "--cov-report="]),
            ("coverage run --source src --rcfile cov.ini -m pytest", ["python3", "-m", "pytest", "-n", "auto", "--cov=src", "--cov-config=cov.ini", NO_THRESHOLD, "--cov-report="]),
            ("python -m coverage run -m pytest", ["python", "-m", "pytest", "-n", "auto", "--cov", NO_THRESHOLD, "--cov-report="]),
            ("COVERAGE_FILE=.cov coverage run -m pytest", ["COVERAGE_FILE=.cov", "python3", "-m", "pytest", "-n", "auto", "--cov", NO_THRESHOLD, "--cov-report="]),
        ):
            result = self.rewrite(command)
            self.assertTrue(result["accelerated"], command)
            self.assertEqual(shlex.split(result["command"]), expected, command)
            self.assertEqual(result["serial_command"], command)
            self.assertEqual(result["plugins"], ["xdist", "pytest-cov"], command)

    def test_translation_keeps_the_runner_prefix_and_the_module_form_that_puts_the_cwd_on_sys_path(self) -> None:
        self.seed(xdist=_plugin(True, via="uv-with"), runner_prefix="uv run")

        parts = shlex.split(self.rewrite("uv run coverage run -m pytest tests/unit", runner_prefix="uv run")["command"])

        self.assertEqual(parts[:2], ["uv", "run"])
        self.assertEqual(parts[parts.index("python") :], ["python", "-m", "pytest", "-n", "auto", "--cov", NO_THRESHOLD, "--cov-report=", "tests/unit"])
        self.assertEqual({parts[index + 1] for index, part in enumerate(parts) if part == "--with"}, {"pytest-xdist"})

    def test_coverage_translation_needs_pytest_cov_and_workers_otherwise_the_run_is_untouched(self) -> None:
        command = "coverage run -m pytest tests/unit"
        self.seed()
        for env, expected in (({**PLAIN_ENV, "MAKATO_PYTEST_WORKERS": "1"}, "xdist off"), ({**PLAIN_ENV, "MAKATO_PYTEST_ACCEL": "off"}, "MAKATO_PYTEST_ACCEL=off")):
            result = self.rewrite(command, env=env)
            self.assertFalse(result["accelerated"])
            self.assertEqual(result["command"], command)
            self.assertIn(expected, result["reason"])

        (pytest_accel.state_dir(self.repo) / "detect.json").write_text(
            json.dumps({"repo_root": self.repo, "runner_prefix": "", "xdist": _plugin(True), "testmon": _plugin(True), "pytest-cov": _plugin(False)}), encoding="utf-8"
        )
        result = self.rewrite(command)
        self.assertFalse(result["accelerated"])
        self.assertEqual(result["command"], command)
        self.assertEqual(result["plugins"], [])
        self.assertIn("install --plugins pytest-cov", result["reason"])

    def test_coverage_options_without_a_pytest_cov_counterpart_keep_the_run_as_it_is(self) -> None:
        self.seed()

        for command in (
            "coverage run --include=src/* -m pytest",
            "coverage run --omit=tests/* -m pytest",
            "coverage run --parallel-mode -m pytest",
            "coverage run --concurrency=multiprocessing -m pytest",
            "coverage run --data-file=.cov -m pytest",
            "coverage run --source -m pytest",
            "coverage run script.py",
            "coverage run -m pytest --cov=src",
            "coverage report -m",
        ):
            result = self.rewrite(command)
            self.assertFalse(result["accelerated"], command)
            self.assertEqual(result["command"], command)

    def test_a_project_coverage_config_with_parallel_or_concurrency_keeps_the_run_as_it_is(self) -> None:
        self.seed()
        command = "coverage run -m pytest"
        config = Path(self.repo) / "pyproject.toml"

        for body, refused in (
            ("[tool.coverage.run]\nparallel = true\n", True),
            ('[tool.coverage.run]\nconcurrency = ["multiprocessing"]\n', True),
            ("[tool.coverage.run]\nparallel = false\nsource = ['pkg']\n", False),
            ("[tool.coverage.run]\nbranch = true\n", False),
        ):
            config.write_text(body, encoding="utf-8")
            self.assertEqual(not self.rewrite(command)["accelerated"], refused, body)

        rc = Path(self.repo) / "ci.cfg"
        rc.write_text("[run]\nparallel = True\n", encoding="utf-8")
        config.write_text("[tool.coverage.run]\nbranch = true\n", encoding="utf-8")
        self.assertFalse(self.rewrite("coverage run --rcfile=ci.cfg -m pytest")["accelerated"], "an explicit --rcfile replaces the discovered config")
        self.assertTrue(self.rewrite(command)["accelerated"])

    def test_a_coverage_run_is_never_asked_to_triage(self) -> None:
        self.seed()

        result = self.rewrite("coverage run -m pytest", purpose="affected")

        self.assertFalse(result["accelerated"])
        self.assertIn("never a Coverage.py command", result["reason"])

    def test_recording_through_a_coverage_run_cannot_seed_testmon(self) -> None:
        self.seed(baseline=False)

        result = self.rewrite("coverage run -m pytest tests/unit", purpose="record")

        self.assertEqual(result["plugins"], ["xdist", "pytest-cov"])
        self.assertNotIn("testmon", result["command"])
        self.assertIn("first affected triage records the baseline", result["reason"])

    def test_compound_shell_commands_are_left_alone(self) -> None:
        self.seed()

        for command in ("coverage run -m pytest && coverage report", "pytest tests/unit | tee out.txt", "pytest tests/unit; echo done", "pytest $(ls tests)"):
            self.assertFalse(self.rewrite(command)["accelerated"], command)

    def test_non_pytest_commands_are_left_alone(self) -> None:
        self.seed()

        self.assertEqual(self.rewrite("npm test")["reason"], "not a pytest command")

    def test_commands_that_choose_their_own_parallelism_are_respected(self) -> None:
        self.seed()

        for command in ("pytest -n 4", "pytest -n4", "pytest -nauto", "pytest --numprocesses=2", "pytest --dist loadscope", "pytest -p xdist -q"):
            result = self.rewrite(command)
            self.assertFalse(result["accelerated"], command)
            self.assertEqual(result["command"], command)

    def test_explicitly_disabled_xdist_is_respected(self) -> None:
        self.seed()

        self.assertFalse(self.rewrite("pytest -p no:xdist")["accelerated"])
        self.assertFalse(self.rewrite("pytest -pno:xdist")["accelerated"])

    def test_debugger_runs_are_never_parallel(self) -> None:
        self.seed()

        self.assertFalse(self.rewrite("pytest --pdb tests/unit")["accelerated"])

    def test_integration_lane_needs_an_explicit_opt_in(self) -> None:
        self.seed()

        off = self.rewrite("pytest tests/integration", lane="integration")
        on = self.rewrite("pytest tests/integration", lane="integration", env={**PLAIN_ENV, "MAKATO_PYTEST_XDIST_INTEGRATION": "1"})

        self.assertFalse(off["accelerated"])
        self.assertIn("MAKATO_PYTEST_XDIST_INTEGRATION", off["reason"])
        self.assertTrue(on["accelerated"])

    def test_missing_plugin_keeps_the_serial_command_and_says_how_to_fix_it(self) -> None:
        self.seed(xdist=_plugin(False, reason="No module named 'xdist'"))

        result = self.rewrite("pytest tests/unit")

        self.assertFalse(result["accelerated"])
        self.assertEqual(result["command"], "pytest tests/unit")
        self.assertIn("pytest_accel.py install --plugins xdist", result["reason"])

    def test_worker_count_override_and_off_switches(self) -> None:
        self.seed()

        four = self.rewrite("pytest", env={**PLAIN_ENV, "MAKATO_PYTEST_WORKERS": "4"})
        one = self.rewrite("pytest", env={**PLAIN_ENV, "MAKATO_PYTEST_WORKERS": "1"})
        off = self.rewrite("pytest", env={**PLAIN_ENV, "MAKATO_PYTEST_ACCEL": "off"})

        self.assertEqual(shlex.split(four["command"]), ["pytest", "-n", "4"])
        self.assertFalse(one["accelerated"])
        self.assertFalse(off["accelerated"])
        self.assertEqual(off["reason"], "disabled by MAKATO_PYTEST_ACCEL=off")

    def test_garbage_worker_count_falls_back_to_auto_and_warns(self) -> None:
        self.seed()

        result = self.rewrite("pytest", env={**PLAIN_ENV, "MAKATO_PYTEST_WORKERS": "lots"})

        self.assertEqual(shlex.split(result["command"]), ["pytest", "-n", "auto"])
        self.assertTrue(any("MAKATO_PYTEST_WORKERS" in warning for warning in result["warnings"]))


class UvRunnerTests(AccelTestCase):
    runner_prefix = "uv run"

    def test_overlay_plugins_are_added_with_uv_with_right_after_uv_run(self) -> None:
        self.seed(xdist=_plugin(True, via="uv-with"))

        result = self.rewrite("uv run pytest tests/unit")

        self.assertEqual(shlex.split(result["command"]), ["uv", "run", "--with", "pytest-xdist", "pytest", "-n", "auto", "tests/unit"])

    def test_plugins_already_in_the_environment_need_no_overlay(self) -> None:
        self.seed(xdist=_plugin(True, via="environment"))

        result = self.rewrite("uv run pytest tests/unit")

        self.assertEqual(shlex.split(result["command"]), ["uv", "run", "pytest", "-n", "auto", "tests/unit"])

    def test_a_with_pytest_option_value_is_not_mistaken_for_the_pytest_command(self) -> None:
        self.seed()

        result = self.rewrite("uv run --with pytest python -m pytest tests/unit")

        self.assertEqual(shlex.split(result["command"]), ["uv", "run", "--with", "pytest", "python", "-m", "pytest", "-n", "auto", "tests/unit"])

    def test_a_with_coverage_option_value_is_not_mistaken_for_the_coverage_command(self) -> None:
        self.seed(xdist=_plugin(True, via="uv-with"))

        translated = shlex.split(self.rewrite("uv run --with pytest --with coverage coverage run -m pytest tests/unit")["command"])
        self.assertEqual(translated[translated.index("python") :], ["python", "-m", "pytest", "-n", "auto", "--cov", NO_THRESHOLD, "--cov-report=", "tests/unit"])
        self.assertIn("coverage", translated[: translated.index("python")], "the --with coverage overlay must be kept")

        plain = self.rewrite("uv run --with coverage pytest tests/unit", purpose="affected")
        self.assertEqual(plain["plugins"], ["xdist", "testmon"], "a plain pytest command carrying --with coverage is not a Coverage.py command")


class TestmonRewriteTests(AccelTestCase):
    def test_full_purpose_never_uses_testmon(self) -> None:
        self.seed()

        self.assertNotIn("--testmon", self.rewrite("pytest tests/unit", purpose="full")["command"])

    def test_record_purpose_records_without_deselecting_anything(self) -> None:
        self.seed(baseline=False)

        for command, expected in (
            ("pytest tests/unit", ["pytest", "-n", "auto", "--testmon-noselect", "tests/unit"]),
            ('pytest -m "not integration"', ["pytest", "-n", "auto", "--testmon-noselect", "-m", "not integration"]),
        ):
            result = self.rewrite(command, purpose="record")
            self.assertEqual(shlex.split(result["command"])[1:], expected, command)
            self.assertEqual(result["plugins"], ["xdist", "testmon"])
            self.assertFalse(result["testmon_baseline"])

    def test_record_is_refused_for_coverage_runs_and_the_integration_lane(self) -> None:
        self.seed(baseline=False)

        self.assertNotIn("testmon", self.rewrite("pytest --cov=pkg", purpose="record")["plugins"])
        self.assertNotIn("testmon", self.rewrite("pytest tests/integration", lane="integration", purpose="record", env={**PLAIN_ENV, "MAKATO_PYTEST_XDIST_INTEGRATION": "1"})["plugins"])

    def test_affected_without_a_baseline_bootstraps_one_recording_run(self) -> None:
        self.seed(baseline=False)

        result = self.rewrite("pytest tests/unit", purpose="affected")

        self.assertEqual(result["plugins"], ["xdist", "testmon"])
        self.assertTrue(result["testmon_bootstrap"])
        self.assertFalse(result["testmon_baseline"])
        self.assertIn("runs and records every test once", result["reason"])

    def test_baseline_flag_reports_a_recorded_baseline(self) -> None:
        self.seed()

        result = self.rewrite("pytest tests/unit", purpose="affected")

        self.assertTrue(result["testmon_baseline"])
        self.assertFalse(result["testmon_bootstrap"])

    def test_affected_purpose_selects_incrementally_with_a_private_data_file(self) -> None:
        self.seed()

        result = self.rewrite("pytest tests/unit", purpose="affected")

        parts = shlex.split(result["command"])
        self.assertEqual(parts[1:], ["pytest", "-n", "auto", "--testmon", "tests/unit"])
        self.assertTrue(parts[0].startswith("TESTMON_DATAFILE="))
        data_file = Path(parts[0].removeprefix("TESTMON_DATAFILE=")).resolve()
        git_dir = Path(subprocess.run(["git", "-C", self.repo, "rev-parse", "--absolute-git-dir"], capture_output=True, text=True, check=True).stdout.strip()).resolve()
        self.assertTrue(data_file.is_relative_to(git_dir), "the data file must live in the git dir, not as an untracked worktree file")
        self.assertEqual(result["plugins"], ["xdist", "testmon"])

    def test_marker_selection_requires_forceselect_because_plain_testmon_switches_itself_off(self) -> None:
        self.seed()

        for command in ('pytest -m "not integration"', "pytest -k claims", "pytest -mslow"):
            parts = shlex.split(self.rewrite(command, purpose="affected")["command"])
            self.assertIn("--testmon-forceselect", parts, command)
            self.assertNotIn("--testmon", parts, command)

    def test_coverage_runs_are_never_incremental(self) -> None:
        self.seed()

        result = self.rewrite("pytest --cov=pkg", purpose="affected")

        self.assertEqual(result["plugins"], ["xdist"])
        self.assertIn("coverage run must execute every test", result["reason"])

    def test_disabled_cacheprovider_blocks_testmon_because_it_would_crash(self) -> None:
        self.seed()

        result = self.rewrite("pytest -p no:cacheprovider", purpose="affected")

        self.assertNotIn("testmon", result["plugins"])
        self.assertIn("cacheprovider", result["reason"])

    def test_last_run_selectors_are_not_combined_with_testmon(self) -> None:
        self.seed()

        for flag in ("--lf", "--ff", "--sw"):
            self.assertNotIn("testmon", self.rewrite(f"pytest {flag}", purpose="affected")["plugins"], flag)

    def test_only_the_unit_lane_is_incremental(self) -> None:
        self.seed()

        result = self.rewrite("pytest tests/integration", lane="integration", purpose="affected", env={**PLAIN_ENV, "MAKATO_PYTEST_XDIST_INTEGRATION": "1"})

        self.assertEqual(result["plugins"], ["xdist"])

    def test_missing_testmon_still_returns_a_parallel_command(self) -> None:
        self.seed(testmon=_plugin(False))

        result = self.rewrite("pytest tests/unit", purpose="affected")

        self.assertEqual(result["plugins"], ["xdist"])
        self.assertEqual(shlex.split(result["command"]), ["pytest", "-n", "auto", "tests/unit"])
        self.assertIn("pytest_accel.py install --plugins testmon", result["reason"])

    def test_nothing_available_returns_the_original_command_untouched(self) -> None:
        self.seed(xdist=_plugin(False), testmon=_plugin(False))

        result = self.rewrite("pytest tests/unit", purpose="affected")

        self.assertFalse(result["accelerated"])
        self.assertEqual(result["command"], "pytest tests/unit")


class StateTests(AccelTestCase):
    def test_state_lives_in_the_git_dir_so_it_never_shows_up_as_an_untracked_file(self) -> None:
        self.seed()
        self.rewrite("pytest", purpose="affected")

        status = subprocess.run(["git", "-C", self.repo, "status", "--porcelain"], capture_output=True, text=True, check=True).stdout

        self.assertEqual(status, "")

    def test_reset_forgets_testmon_data_and_the_detect_cache(self) -> None:
        self.seed()
        (pytest_accel.state_dir(self.repo) / "testmondata").write_text("x", encoding="utf-8")
        (pytest_accel.state_dir(self.repo) / "testmondata-shm").write_text("x", encoding="utf-8")

        removed = pytest_accel.reset(self.repo)["removed"]

        self.assertEqual(removed, ["detect.json", "testmondata", "testmondata-shm"])

    def test_a_cache_from_another_runner_is_not_reused(self) -> None:
        self.seed(xdist=_plugin(False), runner_prefix="poetry run")

        report = pytest_accel._cached_detect(self.repo, "")

        self.assertEqual(report["runner_prefix"], "")

    def test_unknown_plugin_name_is_rejected_by_the_cli(self) -> None:
        self.assertEqual(pytest_accel._main(["install", "--repo-root", self.repo, "--plugins", "xdist,nope"]), 2)


if __name__ == "__main__":
    unittest.main()
