"""Make gate-scout's pytest commands parallel (pytest-xdist) and, in repair loops, incremental (pytest-testmon).

gate-scout is read-only, so it reports the plain command. build-verify passes that
command through ``rewrite`` before running it:

    detect    which accelerators the target project can use, and how they are provisioned
    install   provision them when the project does not declare them (explicit opt-in)
    rewrite   one gate command in, one accelerated command out, with the reason when unchanged
    reset     forget the testmon database and the detect cache (start of a verify session)

Acceleration is an optimisation and must never become a new failure mode: every
refusal returns the original command plus a reason, and ``serial_command`` is always
the command to fall back to. The rules below rest on behaviour verified against
pytest 9, pytest-xdist 3, pytest-testmon 2.2 and pytest-cov 7:

* ``coverage run -m pytest -n N`` measures nothing — the xdist workers are separate
  processes — so a Coverage.py runner is translated instead: ``python -m pytest --cov
  -n N`` with pytest-cov, which merges the worker data into the same ``.coverage`` file,
  leaving a later ``coverage report`` unchanged (identical figures and missing lines
  were checked across a fresh unit run plus an appended integration run, with
  ``--source``/``--branch`` and with config-file sources). ``python -m`` is kept
  because ``coverage run -m`` and ``python -m`` put the working directory on
  ``sys.path`` and the ``pytest`` executable does not. ``--cov-fail-under=0`` is added
  because ``coverage run`` never fails on a threshold (``coverage report`` does) while
  pytest-cov would exit 1 on the project's ``fail_under`` and read as a test failure.
  Options pytest-cov has no counterpart for, and ``parallel``/``concurrency`` in the
  project's coverage config, keep the command as it is.
* ``--testmon`` needs pytest's cacheprovider (``-p no:cacheprovider`` crashes it), is
  switched off by ``-m``/``-k`` unless ``--testmon-forceselect`` is used, deselects
  tests (so it must never feed a coverage figure), and does not see changes to
  non-Python files the tests read.
* ``--testmon-noselect`` records dependency data while deselecting nothing, so it may
  ride on an authoritative full run; ``--testmon`` then selects only tests whose
  executed code changed (new, failed and unrecorded tests are always selected). It
  follows executed function bodies; state only visible through import-time attribute
  reads is not tracked, so a selection is a triage signal, never a pass for a gate.
* testmon is switched off while coverage is measured, so a coverage run can never
  seed the baseline: the first ``affected`` triage of a session records it, which
  means it runs every test once (``testmon_bootstrap`` in the result).
* testmon's data file defaults to ``./.testmondata`` — an untracked file in the
  worktree that review and push would pick up — so it is redirected into the git dir.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shlex
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any

PLUGINS = {
    "xdist": {"module": "xdist", "dist": "pytest-xdist"},
    "testmon": {"module": "testmon", "dist": "pytest-testmon"},
    "pytest-cov": {"module": "pytest_cov", "dist": "pytest-cov"},
}
LANES = ("unit", "integration")
PURPOSES = ("full", "record", "affected")
SHELL_PUNCTUATION = frozenset("();<>|&")
LAST_RUN_OPTIONS = frozenset({"--lf", "--ff", "--last-failed", "--failed-first", "--sw", "--stepwise"})
RUNNER_VALUE_OPTIONS = frozenset({"--with", "--with-editable", "--with-requirements", "--group", "--only-group", "--no-group", "--extra", "--package", "--python", "--project", "--directory"})
PROBE_TIMEOUT_SECONDS = 180
TRUTHY = ("1", "true", "yes", "on")
COVERAGE_CONFIG_FILES = (".coveragerc", "setup.cfg", "tox.ini", "pyproject.toml")
COVERAGE_UNSUPPORTED_CONFIG = re.compile(r"^\s*(?:parallel\s*=\s*(?:true|yes|on|1)\b|concurrency\s*=\s*[\w\[\"'])", re.IGNORECASE | re.MULTILINE)


def _testmon_datafile(repo_root: str) -> Path:
    return state_dir(repo_root) / "testmondata"


def _has_shell_control(command: str) -> bool:
    """True when the command chains, pipes, redirects, substitutes or spans lines — anything beyond one pytest invocation."""
    if "\n" in command or "`" in command or "$(" in command:
        return True
    lexer = shlex.shlex(command, posix=True, punctuation_chars=True)
    lexer.whitespace_split = False
    return any(token and set(token) <= SHELL_PUNCTUATION for token in lexer)


def state_dir(repo_root: str) -> Path:
    """A per-worktree private directory outside the tracked tree (inside the git dir when there is one)."""
    result = subprocess.run(["git", "-C", repo_root, "rev-parse", "--absolute-git-dir"], capture_output=True, text=True, check=False)
    git_dir = result.stdout.strip()
    base = Path(git_dir) if result.returncode == 0 and git_dir else Path(tempfile.gettempdir()) / f"makato-accel-{hashlib.sha256(repo_root.encode()).hexdigest()[:12]}"
    path = base / "makato" / "pytest-accel"
    path.mkdir(parents=True, exist_ok=True)
    return path


def resolve_workers(raw: str | None) -> tuple[str | None, str | None]:
    """MAKATO_PYTEST_WORKERS → (value for ``-n``, or None when parallelism is off; warning)."""
    if raw is None or raw.strip() == "" or raw.strip().lower() == "auto":
        return "auto", None
    value = raw.strip()
    if value.isdigit():
        return (None, None) if int(value) <= 1 else (value, None)
    return "auto", f"invalid MAKATO_PYTEST_WORKERS {raw!r}; using auto"


def _is_uv(prefix: list[str]) -> bool:
    return len(prefix) >= 2 and Path(prefix[0]).name == "uv" and prefix[1] == "run"


def _probe(repo_root: str, prefix: list[str], module: str, with_dist: str | None) -> tuple[bool, str]:
    command = list(prefix)
    if with_dist is not None:
        command += ["--with", with_dist]
    command += ["python" if prefix else "python3", "-c", f"import {module}"]
    try:
        result = subprocess.run(command, cwd=repo_root, capture_output=True, text=True, timeout=PROBE_TIMEOUT_SECONDS, check=False)
    except (OSError, subprocess.TimeoutExpired) as exc:
        return False, f"{type(exc).__name__}: {exc}"
    if result.returncode == 0:
        return True, ""
    lines = result.stderr.strip().splitlines()
    return False, lines[-1] if lines else f"exit {result.returncode}"


def detect_plugin(repo_root: str, prefix: list[str], name: str) -> dict[str, Any]:
    info = PLUGINS[name]
    ok, reason = _probe(repo_root, prefix, info["module"], None)
    if ok:
        return {"importable": True, "via": "environment", "reason": ""}
    if _is_uv(prefix):
        ok, overlay_reason = _probe(repo_root, prefix, info["module"], info["dist"])
        if ok:
            return {"importable": True, "via": "uv-with", "reason": ""}
        reason = overlay_reason or reason
    return {"importable": False, "via": "none", "reason": reason}


def _detect_cache(repo_root: str) -> Path:
    return state_dir(repo_root) / "detect.json"


def detect(repo_root: str, runner_prefix: str) -> dict[str, Any]:
    prefix = shlex.split(runner_prefix)
    report: dict[str, Any] = {"repo_root": repo_root, "runner_prefix": runner_prefix}
    for name in PLUGINS:
        report[name] = detect_plugin(repo_root, prefix, name)
    _detect_cache(repo_root).write_text(json.dumps(report), encoding="utf-8")
    return report


def _cached_detect(repo_root: str, runner_prefix: str) -> dict[str, Any]:
    cache = _detect_cache(repo_root)
    if cache.is_file():
        try:
            cached = json.loads(cache.read_text(encoding="utf-8"))
            if cached.get("runner_prefix") == runner_prefix:
                return cached
        except (OSError, json.JSONDecodeError):  # fmt: skip
            pass
    return detect(repo_root, runner_prefix)


def install(repo_root: str, runner_prefix: str, names: list[str]) -> dict[str, Any]:
    """Provision plugins without touching the project's manifests or lockfile.

    uv projects need nothing installed: ``rewrite`` adds ``--with <dist>`` (an ephemeral,
    cached overlay). Other runners get a ``pip install`` into the project environment,
    which the caller opts into explicitly; the dependency declaration stays the project's.
    """
    prefix = shlex.split(runner_prefix)
    outcome: dict[str, Any] = {}
    for name in names:
        current = detect_plugin(repo_root, prefix, name)
        if current["importable"] or _is_uv(prefix):
            outcome[name] = current
            continue
        pip = [*prefix, "python", "-m", "pip"] if prefix else [sys.executable, "-m", "pip"]
        result = subprocess.run([*pip, "install", "--quiet", PLUGINS[name]["dist"]], cwd=repo_root, capture_output=True, text=True, check=False)
        if result.returncode == 0:
            outcome[name] = detect_plugin(repo_root, prefix, name)
        else:
            outcome[name] = {"importable": False, "via": "none", "reason": (result.stderr.strip().splitlines() or ["pip install failed"])[-1]}
    _detect_cache(repo_root).unlink(missing_ok=True)
    return outcome


def _already_parallel(options: list[str]) -> bool:
    for index, token in enumerate(options):
        if token in ("-n", "--numprocesses", "--dist", "--tx") or token.startswith(("--numprocesses=", "--dist=", "--tx=")):
            return True
        if token.startswith("-n") and (token[2:].isdigit() or token[2:] in ("auto", "logical")):
            return True
        if token == "-p" and index + 1 < len(options) and options[index + 1] == "xdist":
            return True
    return False


def _plugin_disabled(options: list[str], plugin: str) -> bool:
    return f"-pno:{plugin}" in options or any(token == "-p" and index + 1 < len(options) and options[index + 1] == f"no:{plugin}" for index, token in enumerate(options))


def _has_coverage_option(options: list[str]) -> bool:
    return any(token == "--cov" or token.startswith(("--cov=", "--cov-")) for token in options)


def _has_selector(options: list[str]) -> bool:
    return any(token[:2] in ("-m", "-k") and not token.startswith("--") for token in options)


def _with_dist(tokens: list[str], dist: str) -> list[str]:
    """Insert ``--with <dist>`` right after ``uv run``."""
    for index in range(len(tokens) - 1):
        if Path(tokens[index]).name == "uv" and tokens[index + 1] == "run":
            return [*tokens[: index + 2], "--with", dist, *tokens[index + 2 :]]
    return tokens


def _tool_index(tokens: list[str], names: tuple[str, ...]) -> int | None:
    """Index of the first executable/module token called one of ``names``, skipping values of runner options such as ``--with pytest``."""
    for index, token in enumerate(tokens):
        if Path(token).name in names and (index == 0 or tokens[index - 1] not in RUNNER_VALUE_OPTIONS):
            return index
    return None


def _coverage_parallel_configured(repo_root: str, rcfile: str | None) -> bool:
    """True when the Coverage.py config uses parallel mode or a concurrency setting (a crude text check: a false positive only keeps the run as it is)."""
    for name in (rcfile,) if rcfile else COVERAGE_CONFIG_FILES:
        try:
            if COVERAGE_UNSUPPORTED_CONFIG.search((Path(repo_root) / name).read_text(encoding="utf-8")):
                return True
        except (OSError, UnicodeDecodeError):  # fmt: skip
            continue
    return False


def _translate_coverage_run(tokens: list[str], cov_at: int, pytest_at: int, repo_root: str) -> tuple[list[str], list[str]] | str:
    """Map ``<runner> coverage run <flags> -m pytest`` onto (interpreter tokens, pytest-cov flags); a string is the reason it cannot be mapped.

    ``python -m pytest`` rather than the ``pytest`` executable: ``coverage run -m`` and ``python -m`` both put the working directory on ``sys.path``.
    """
    if tokens[cov_at + 1 : cov_at + 2] != ["run"] or tokens[pytest_at - 1] != "-m":
        return "Coverage.py invocation is not of the form `coverage run ... -m pytest`"
    given = tokens[cov_at + 2 : pytest_at - 1]
    flags: list[str] = []
    sources: list[str] = []
    rcfile: str | None = None
    index = 0
    while index < len(given):
        token = given[index]
        name, has_value, value = token.partition("=")
        if token in ("--append", "-a"):
            flags.append("--cov-append")
        elif token == "--branch":
            flags.append("--cov-branch")
        elif name in ("--source", "--rcfile"):
            if not has_value:
                index += 1
                if index >= len(given):
                    return f"coverage run option {token} is missing its value"
                value = given[index]
            if name == "--source":
                sources += [item for item in value.split(",") if item]
            else:
                rcfile = value
        else:
            return f"coverage run option {token} has no pytest-cov counterpart"
        index += 1
    if _coverage_parallel_configured(repo_root, rcfile):
        return "Coverage.py config sets parallel or concurrency, which pytest-cov does not reproduce"
    cov_flags = [f"--cov={item}" for item in sources] or ["--cov"]
    if rcfile:
        cov_flags.append(f"--cov-config={rcfile}")
    cov_flags += flags
    if cov_at and tokens[cov_at - 1] == "-m":
        interpreter = tokens[: cov_at - 1]
    else:
        runner = any("=" not in token for token in tokens[:cov_at])
        interpreter = [*tokens[:cov_at], "python" if runner else "python3"]
    return interpreter, cov_flags


def rewrite(repo_root: str, command: str, lane: str, purpose: str, runner_prefix: str, env: dict[str, str] | None = None) -> dict[str, Any]:
    """Return {command, serial_command, accelerated, plugins, reason, warnings, testmon_baseline, testmon_bootstrap} for one gate command."""
    env = dict(os.environ) if env is None else env
    plugins: list[str] = []
    warnings: list[str] = []
    notes: list[str] = []
    bootstrap = False

    def outcome(rendered: str, accelerated: bool, reason: str) -> dict[str, Any]:
        return {
            "command": rendered,
            "serial_command": command,
            "accelerated": accelerated,
            "plugins": plugins if accelerated else [],
            "lane": lane,
            "purpose": purpose,
            "testmon_baseline": _testmon_datafile(repo_root).exists(),
            "testmon_bootstrap": bootstrap and accelerated,
            "reason": reason,
            "warnings": warnings,
        }

    if env.get("MAKATO_PYTEST_ACCEL", "auto").strip().lower() in ("off", "0", "false", "no"):
        return outcome(command, False, "disabled by MAKATO_PYTEST_ACCEL=off")
    try:
        tokens = shlex.split(command)
    except ValueError as exc:
        return outcome(command, False, f"unparseable command: {exc}")
    if _has_shell_control(command):
        return outcome(command, False, "compound shell command; only a single pytest invocation is rewritten")
    pytest_at = _tool_index(tokens, ("pytest", "py.test"))
    if pytest_at is None:
        return outcome(command, False, "not a pytest command")
    options = tokens[pytest_at + 1 :]
    if any(token in ("--pdb", "--trace") for token in options):
        return outcome(command, False, "interactive debugger option")

    cov_at = _tool_index(tokens[:pytest_at], ("coverage",))
    cov_head: list[str] = []
    cov_flags: list[str] = []
    if cov_at is not None:
        if purpose == "affected":
            return outcome(command, False, "triage runs the plain unit command, never a Coverage.py command")
        if _has_coverage_option(options):
            return outcome(command, False, "pytest-cov options on a Coverage.py run: measured twice")
        translated = _translate_coverage_run(tokens, cov_at, pytest_at, repo_root)
        if isinstance(translated, str):
            return outcome(command, False, translated)
        cov_head, cov_flags = translated

    workers, warning = resolve_workers(env.get("MAKATO_PYTEST_WORKERS"))
    if warning:
        warnings.append(warning)
    report = _cached_detect(repo_root, runner_prefix)
    flags: list[str] = []
    overlays: list[str] = []

    if workers is None:
        notes.append("xdist off: MAKATO_PYTEST_WORKERS<=1")
    elif _already_parallel(options):
        notes.append("xdist skipped: the command already selects workers or a distribution mode")
    elif _plugin_disabled(options, "xdist"):
        notes.append("xdist skipped: disabled with -p no:xdist")
    elif lane == "integration" and env.get("MAKATO_PYTEST_XDIST_INTEGRATION", "").strip().lower() not in TRUTHY:
        notes.append("xdist skipped: integration tests share real services; opt in with MAKATO_PYTEST_XDIST_INTEGRATION=1")
    elif report["xdist"]["importable"]:
        flags += ["-n", workers]
        plugins.append("xdist")
        if report["xdist"]["via"] == "uv-with":
            overlays.append(PLUGINS["xdist"]["dist"])
    else:
        notes.append(f"xdist not installed ({report['xdist']['reason'] or 'not importable'}); run pytest_accel.py install --plugins xdist")

    if cov_at is not None:
        if "xdist" not in plugins:
            return outcome(command, False, "; ".join(notes) or "no workers: the Coverage.py run stays as it is")
        if not report["pytest-cov"]["importable"]:
            return outcome(command, False, f"pytest-cov not installed ({report['pytest-cov']['reason'] or 'not importable'}); run pytest_accel.py install --plugins pytest-cov")
        plugins.append("pytest-cov")
        if report["pytest-cov"]["via"] == "uv-with":
            overlays.append(PLUGINS["pytest-cov"]["dist"])
        notes.append("Coverage.py run translated to python -m pytest --cov: pytest-cov measures the workers and writes the same data file")

    if purpose in ("record", "affected"):
        if cov_at is not None:
            notes.append("testmon skipped: it cannot record while coverage is measured; the first affected triage records the baseline")
        elif lane != "unit":
            notes.append("testmon skipped: only the unit lane is tracked incrementally")
        elif _has_coverage_option(options):
            notes.append("testmon skipped: a coverage run must execute every test")
        elif _plugin_disabled(options, "cacheprovider"):
            notes.append("testmon skipped: it needs pytest's cacheprovider")
        elif purpose == "affected" and LAST_RUN_OPTIONS.intersection(options):
            notes.append("testmon skipped: the command already selects by last-run state")
        elif report["testmon"]["importable"]:
            if purpose == "record":
                flags.append("--testmon-noselect")
            else:
                flags.append("--testmon-forceselect" if _has_selector(options) else "--testmon")
                if not _testmon_datafile(repo_root).exists():
                    bootstrap = True
                    notes.append("testmon baseline bootstrap: none recorded yet, so this triage runs and records every test once")
            plugins.append("testmon")
            if report["testmon"]["via"] == "uv-with":
                overlays.append(PLUGINS["testmon"]["dist"])
        else:
            notes.append(f"testmon not installed ({report['testmon']['reason'] or 'not importable'}); run pytest_accel.py install --plugins testmon")

    if not flags:
        return outcome(command, False, "; ".join(notes) or "nothing to accelerate")

    if cov_at is not None:
        rewritten = [*cov_head, "-m", "pytest", *flags, *cov_flags, "--cov-fail-under=0", "--cov-report=", *options]
    else:
        rewritten = [*tokens[: pytest_at + 1], *flags, *options]
    for dist in overlays:
        rewritten = _with_dist(rewritten, dist)
    rendered = shlex.join(rewritten)
    if "testmon" in plugins:
        rendered = f"TESTMON_DATAFILE={shlex.quote(str(_testmon_datafile(repo_root)))} {rendered}"
    return outcome(rendered, True, "; ".join(notes))


def reset(repo_root: str) -> dict[str, Any]:
    removed = []
    for entry in sorted(state_dir(repo_root).iterdir()):
        if entry.name.startswith(("testmondata", "detect.json")):
            entry.unlink()
            removed.append(entry.name)
    return {"removed": removed}


def _main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    for name in ("detect", "install", "rewrite", "reset"):
        command = sub.add_parser(name)
        command.add_argument("--repo-root", required=True)
        if name != "reset":
            command.add_argument("--runner-prefix", default="", help='gate-scout python_runner_prefix, e.g. "uv run"; empty or "none" when there is none')
        if name == "install":
            command.add_argument("--plugins", default="xdist,testmon", help="comma-separated: xdist, testmon, pytest-cov")
        if name == "rewrite":
            command.add_argument("--command", required=True, dest="gate_command")
            command.add_argument("--lane", required=True, choices=LANES)
            command.add_argument("--purpose", default="full", choices=PURPOSES)

    args = parser.parse_args(argv)
    prefix = getattr(args, "runner_prefix", "")
    runner_prefix = "" if prefix == "none" else prefix
    if args.command == "detect":
        print(json.dumps(detect(args.repo_root, runner_prefix)))
    elif args.command == "install":
        names = [item.strip() for item in args.plugins.split(",") if item.strip()]
        unknown = [item for item in names if item not in PLUGINS]
        if unknown:
            print(f"pytest-accel: unknown plugin(s): {', '.join(unknown)}", file=sys.stderr)
            return 2
        print(json.dumps(install(args.repo_root, runner_prefix, names)))
    elif args.command == "rewrite":
        print(json.dumps(rewrite(args.repo_root, args.gate_command, args.lane, args.purpose, runner_prefix)))
    else:
        print(json.dumps(reset(args.repo_root)))
    return 0


if __name__ == "__main__":
    raise SystemExit(_main(sys.argv[1:]))
