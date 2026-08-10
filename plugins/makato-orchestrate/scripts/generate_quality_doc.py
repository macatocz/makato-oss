"""Per-domain quality scorecard from build.jsonl + halt_audit (#598).

Reads all per-issue build.jsonl files whose plan.md / spec.md frontmatter
carries `domain: <name>` (or is absent when `--domain general`) and writes a
Quality Scorecard table to `specs/master/<domain>-quality.md`.

Usage:
  python3 generate_quality_doc.py --domain <name> [--specs-dir <path>]

Arguments:
  --domain <name>    Required. The domain to aggregate (e.g. "orchestrate",
                     "build", "general").
  --specs-dir <path> Optional. Override the specs/ root. Defaults to
                     $REPO_ROOT/specs (or $MAKATO_QUALITY_SPECS_DIR for tests).

Output:
  Writes/overwrites `<specs-dir>/master/<domain>-quality.md`. If the master
  file already exists, only the `## Quality Scorecard` section and the
  `_Last updated_` footer line are replaced; all other content is preserved.

Per-issue metrics:
  tests_passing       — last numeric data.tests_passing from a status:ok/green entry
  sensor_clean        — Yes/No/- from the last gate-sensors entry
  halts               — count of halt_audit[] entries
  last_halt           — halt_audit[-1].code
  structural_failures — count of build-verify entries where status==error or
                        data.all_gates_passed==false

Never fatal: always exits 0; unreadable files produce `-` for their cells and
a warning to stderr.

Exit codes:
  0  success
  1  SPECS_DIR not found
  64 usage error (missing --domain, unknown flag, missing flag value)

Environment:
  MAKATO_QUALITY_SPECS_DIR  Override specs/ root (tests).
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
from datetime import datetime, timezone


def _now() -> str:
    """Return an ISO-8601 UTC timestamp with millisecond precision."""
    n = datetime.now(timezone.utc)
    return n.strftime("%Y-%m-%dT%H:%M:%S.") + f"{n.microsecond // 1000:03d}Z"


def _log(msg: str) -> None:
    """Write a prefixed message to stderr."""
    print(f"quality-doc: {msg}", file=sys.stderr)


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


def detect_domain(folder: str) -> str:
    """Read domain: frontmatter from plan.md or spec.md in folder.

    Mirrors archive-spec.sh:detect_domain exactly. Defaults to "general".
    """
    for fname in ("plan.md", "spec.md"):
        path = os.path.join(folder, fname)
        if not os.path.isfile(path):
            continue
        try:
            with open(path, encoding="utf-8") as fh:
                for line in fh:
                    m = re.match(r"^domain:\s*([A-Za-z0-9_-]+)", line)
                    if m:
                        return m.group(1)
        except OSError:
            pass
    return "general"


def _issue_number_from_folder(base: str) -> str:
    """Extract leading numeric segment from folder basename.

    e.g. "598-makato-orchestrate-feat-quality-doc" -> "598"
    Returns empty string if none found.
    """
    m = re.match(r"^([0-9]+)", base)
    return m.group(1) if m else ""


def _slug_title(base: str) -> str:
    """Strip leading digits+dash from folder basename.

    e.g. "598-makato-orchestrate-feat-quality-doc" ->
         "makato-orchestrate-feat-quality-doc"
    """
    return re.sub(r"^[0-9]+-", "", base)


def aggregate_build_jsonl(build_file: str) -> tuple[str, str, int]:
    """Parse build.jsonl and return (tests_passing, sensor_clean, structural_failures).

    Returns ("-", "-", 0) placeholders when file is absent/unreadable.
    sensor_clean: "Yes" / "No" / "-"
    structural_failures: int count
    """
    if not os.path.isfile(build_file):
        return "-", "-", 0

    entries: list[dict] = []
    try:
        with open(build_file, encoding="utf-8", errors="replace") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    entries.append(json.loads(line))
                except json.JSONDecodeError:
                    pass
    except OSError:
        return "-", "-", 0

    # tests_passing: last numeric data.tests_passing from a status ok/green entry
    tests_passing = "-"
    for e in reversed(entries):
        if e.get("status") in ("ok", "green"):
            d = e.get("data") or {}
            tp = d.get("tests_passing")
            if tp is not None and isinstance(tp, (int, float)):
                tests_passing = str(int(tp))
                break

    # sensor_clean: last gate-sensors entry
    sensor_clean = "-"
    for e in reversed(entries):
        if e.get("step") == "gate-sensors":
            d = e.get("data") or {}
            findings = d.get("findings")
            if findings is None:
                findings = d.get("sensor_findings")
            if findings is not None:
                try:
                    sensor_clean = "Yes" if int(findings) == 0 else "No"
                except (ValueError, TypeError):
                    sensor_clean = "-"
            break

    # structural_failures: build-verify entries where status==error or
    # data.all_gates_passed==false
    structural_failures = 0
    for e in entries:
        if e.get("skill") == "build-verify" or e.get("step") == "build-verify":
            d = e.get("data") or {}
            if e.get("status") == "error" or d.get("all_gates_passed") is False:
                structural_failures += 1

    return tests_passing, sensor_clean, structural_failures


def aggregate_halt(folder: str, issue: str) -> tuple[int, str]:
    """Read workflow-state-<issue>.json and return (halt_count, last_halt_code).

    Returns (0, "-") if the file is absent or unreadable.
    """
    state_file = None
    try:
        for fname in os.listdir(folder):
            if fname == f"workflow-state-{issue}.json":
                state_file = os.path.join(folder, fname)
                break
    except OSError:
        return 0, "-"

    if not state_file:
        return 0, "-"

    try:
        with open(state_file, encoding="utf-8") as fh:
            data = json.load(fh)
    except Exception:
        return 0, "-"

    halt_audit = data.get("halt_audit") or []
    count = len(halt_audit)
    if count > 0:
        last = halt_audit[-1].get("code", "-") if isinstance(halt_audit[-1], dict) else "-"
    else:
        last = "-"
    return count, last


def build_scorecard_block(domain: str, rows: list[str], timestamp: str) -> str:
    """Build the ## Quality Scorecard markdown block."""
    header = "## Quality Scorecard"
    table = (
        "| Issue | Story | Tests Passing | Sensor Clean | HALTs | Last HALT | Structural Failures |\n"
        "|-------|-------|---------------|--------------|-------|-----------|---------------------|"
    )
    if rows:
        table += "\n" + "\n".join(rows)
    footer = f"_Last updated: {timestamp}. Source: build.jsonl + workflow-state._"
    return f"{header}\n\n{table}\n\n{footer}"


def update_or_create_scorecard(output_file: str, new_scorecard: str) -> None:
    """Write scorecard to output_file.

    If the file exists, replace only the ## Quality Scorecard section +
    _Last updated_ footer line. All other content is preserved.
    If the file does not exist, create it.
    """
    section_start = "## Quality Scorecard"
    footer_prefix = "_Last updated:"

    if not os.path.isfile(output_file):
        # New file — write directly.
        tmp = output_file + ".tmp"
        try:
            with open(tmp, "w", encoding="utf-8") as fh:
                fh.write(new_scorecard + "\n")
            os.replace(tmp, output_file)
        except OSError:
            try:
                os.unlink(tmp)
            except OSError:
                pass
            raise
        return

    # File exists — replace the section.
    with open(output_file, encoding="utf-8") as fh:
        content = fh.read()

    start = content.find(section_start)
    if start == -1:
        # Section not present — append.
        combined = content.rstrip("\n") + "\n\n" + new_scorecard + "\n"
        with open(output_file, "w", encoding="utf-8") as fh:
            fh.write(combined)
        return

    # Find the footer line end.
    footer_start = content.find(footer_prefix, start)
    if footer_start == -1:
        end = len(content)
    else:
        footer_end = content.find("\n", footer_start)
        end = footer_end + 1 if footer_end != -1 else len(content)

    before = content[:start]
    after_raw = content[end:]
    after = after_raw.lstrip("\n")

    combined = before + new_scorecard + ("\n\n" + after if after else "\n")
    with open(output_file, "w", encoding="utf-8") as fh:
        fh.write(combined)


def generate_quality_doc(domain: str, specs_dir: str) -> int:
    """Generate the quality scorecard for the given domain. Returns exit code."""
    if not os.path.isdir(specs_dir):
        _log(f"ERROR — SPECS_DIR not found: {specs_dir}")
        return 1

    rows: list[str] = []

    try:
        entries = sorted(os.listdir(specs_dir))
    except OSError:
        _log(f"ERROR — cannot list SPECS_DIR: {specs_dir}")
        return 1

    for base in entries:
        folder = os.path.join(specs_dir, base)
        if not os.path.isdir(folder):
            continue
        if base in ("master", "archive"):
            continue
        # Only process folders that look like issue folders (leading digits).
        if not re.match(r"^[0-9]", base):
            continue

        folder_domain = detect_domain(folder)
        if folder_domain != domain:
            continue

        issue = _issue_number_from_folder(base)
        if not issue:
            continue
        slug_title = _slug_title(base)

        tests_passing, sensor_clean, structural_failures = aggregate_build_jsonl(
            os.path.join(folder, "build.jsonl")
        )
        halts, last_halt = aggregate_halt(folder, issue)

        rows.append(
            f"| #{issue} | {slug_title} | {tests_passing} | "
            f"{sensor_clean} | {halts} | {last_halt} | {structural_failures} |"
        )

    timestamp = _now()
    scorecard = build_scorecard_block(domain, rows, timestamp)

    os.makedirs(os.path.join(specs_dir, "master"), exist_ok=True)
    output_file = os.path.join(specs_dir, "master", f"{domain}-quality.md")

    try:
        update_or_create_scorecard(output_file, scorecard)
    except OSError as exc:
        _log(f"ERROR — cannot write {output_file}: {exc}")
        return 1

    if os.path.isfile(output_file) and rows:
        _log(f"updated scorecard in {output_file} (domain: {domain}, issues: {len(rows)})")
    else:
        _log(f"created {output_file} (domain: {domain}, issues: {len(rows)})")
    return 0


def main(argv: list[str] | None = None) -> int:
    """Entry point with argparse. Exit 64 on usage error, 1 on I/O, 0 on success."""
    args_list = argv if argv is not None else sys.argv[1:]

    # Manual arg parsing to match the bash script's exact exit-64 semantics.
    domain = ""
    specs_dir_override = ""
    i = 0
    while i < len(args_list):
        arg = args_list[i]
        if arg == "--domain":
            i += 1
            if i >= len(args_list):
                _log("ERROR — --domain requires a value")
                return 64
            domain = args_list[i]
        elif arg == "--specs-dir":
            i += 1
            if i >= len(args_list):
                _log("ERROR — --specs-dir requires a value")
                return 64
            specs_dir_override = args_list[i]
        elif arg.startswith("--"):
            _log(f"ERROR — unknown flag: {arg}")
            return 64
        else:
            _log(f"ERROR — unexpected positional arg: {arg}")
            return 64
        i += 1

    if not domain:
        _log("ERROR — --domain is required")
        return 64

    if specs_dir_override:
        specs_dir = specs_dir_override
    else:
        repo_root = _repo_root()
        specs_dir = os.environ.get(
            "MAKATO_QUALITY_SPECS_DIR",
            os.environ.get("SPECS_DIR", os.path.join(repo_root, "specs")),
        )

    return generate_quality_doc(domain, specs_dir)


if __name__ == "__main__":
    raise SystemExit(main())
