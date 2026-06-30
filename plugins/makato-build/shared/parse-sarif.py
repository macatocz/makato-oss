#!/usr/bin/env python3
"""Normalise diagnostic output from various linters/checkers into a unified Finding stream.

Per PLAN §9.4. Pure stdlib (Python 3.14); optional sarif-om import is tolerated but
not required.

Supported inputs:
- SARIF 2.1.0 (any tool that emits it: ruff, biome, semgrep, codeql, ...)
- pyright --outputjson
- sqlfluff lint --format json
- markdownlint-cli2 --json (or markdownlint --json)
- pre-commit textual output (line-oriented fallback)

CLI:
    cat report.sarif | parse-sarif.py --tool sarif > findings.json
    pyright --outputjson | parse-sarif.py --tool pyright > findings.json
    sqlfluff lint --format json . | parse-sarif.py --tool sqlfluff > findings.json
    markdownlint-cli2 --json . | parse-sarif.py --tool markdownlint > findings.json
    pre-commit run --all-files | parse-sarif.py --tool pre-commit > findings.json

Self-test:
    parse-sarif.py --selftest
"""

from __future__ import annotations

import json
import re
import sys
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any, Iterable

# Optional: prefer vendored sarif-om when available, but never required.
try:  # pragma: no cover - exercised only when user has the lib installed
    import sarif_om  # type: ignore  # noqa: F401

    _HAS_SARIF_OM = True
except ImportError:
    _HAS_SARIF_OM = False


# Rule patterns whose findings are auto-fixable by the issuing tool.
# Keys are tool names (lower-case); values are iterables of regex patterns
# (case-insensitive) matched against the rule id.
AUTOFIXABLE_RULES: dict[str, tuple[str, ...]] = {
    "ruff": (
        r"^F401$",  # unused-import
        r"^I001$",  # unsorted-imports
        r"^I002$",  # missing-required-import
        r"^W291$",  # trailing-whitespace
        r"^W292$",  # missing-newline-at-end-of-file
        r"^W293$",  # blank-line-with-whitespace
        r"^E501$",  # line-too-long (when --fix-only enabled)
        r"^UP\d+$",  # pyupgrade rules
        r"^Q\d+$",  # flake8-quotes
        r"^COM\d+$",  # flake8-commas
        r"^ISC\d+$",  # implicit-str-concat
    ),
    "biome": (
        r"^lint/style/.*$",
        r"^lint/correctness/noUnusedImports$",
        r"^lint/correctness/noUnusedVariables$",
        r"^lint/suspicious/noDoubleEquals$",
        r"^assist/.*$",  # organize-imports etc.
        r"^format$",
    ),
    "eslint": (
        r"^prettier/.*$",
        r"^import/order$",
    ),
}

_SEVERITY_VALUES = {"error", "warning", "note"}


@dataclass
class Finding:
    """A single normalised diagnostic across all supported tools."""

    tool: str
    rule: str
    path: str
    line: int
    column: int
    message: str
    severity: str  # 'error' | 'warning' | 'note'
    autofix_available: bool = False
    raw: dict = field(default_factory=dict)

    def __post_init__(self) -> None:
        if self.severity not in _SEVERITY_VALUES:
            self.severity = "note"

    def to_dict(self) -> dict:
        return asdict(self)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _load(file_or_dict: Any) -> Any:
    """Accept a path, file-like object, raw JSON string, or already-parsed dict/list."""
    if isinstance(file_or_dict, (dict, list)):
        return file_or_dict
    if hasattr(file_or_dict, "read"):
        data = file_or_dict.read()
        return json.loads(data) if isinstance(data, (str, bytes)) else data
    if isinstance(file_or_dict, (str, Path)):
        s = str(file_or_dict)
        # Heuristic: a JSON document starts with '{' or '['; otherwise treat
        # as a filesystem path. Avoids OSError on overlong "filenames".
        stripped = s.lstrip()
        if stripped.startswith(("{", "[")):
            return json.loads(s)
        try:
            p = Path(s)
            if p.exists():
                return json.loads(p.read_text(encoding="utf-8"))
        except OSError:
            pass
        return json.loads(s)
    raise TypeError(f"Cannot load JSON input from {type(file_or_dict).__name__}")


def _is_autofixable(tool: str, rule: str) -> bool:
    patterns = AUTOFIXABLE_RULES.get(tool.lower())
    if not patterns or not rule:
        return False
    return any(re.match(pat, rule, re.IGNORECASE) for pat in patterns)


def _norm_sarif_severity(level: str | None, kind: str | None = None) -> str:
    if kind and kind not in ("fail", None):
        return "note"
    if not level:
        return "note"
    lvl = level.lower()
    if lvl == "error":
        return "error"
    if lvl == "warning":
        return "warning"
    return "note"


def _norm_pyright_severity(sev: str | None) -> str:
    if not sev:
        return "note"
    s = sev.lower()
    if s == "error":
        return "error"
    if s == "warning":
        return "warning"
    return "note"  # 'information', 'hint', anything else


# ---------------------------------------------------------------------------
# SARIF 2.1.0
# ---------------------------------------------------------------------------

_SEMGREP_SECURITY_TAGS = {"security", "cwe", "owasp", "injection", "xss", "sqli"}
_SEMGREP_SECURITY_SEGMENTS = {"security", "secrets", "audit", "injection"}


def _semgrep_category(rule_id: str, result: dict, rule_def: dict) -> str:
    """Return 'security' or 'style' for a semgrep rule.

    Resolution order:
    1. result.properties.category (semgrep sets this in SARIF output)
    2. rule_def.properties.tags (any tag matching security keywords)
    3. rule_id segment heuristic (segment containing 'security' or related words)
    """
    cat = (result.get("properties") or {}).get("category") or ""
    if not cat:
        cat = (rule_def.get("properties") or {}).get("category") or ""
    if cat:
        return "security" if "security" in cat.lower() else "style"

    tags = (rule_def.get("properties") or {}).get("tags") or []
    if any(_SEMGREP_SECURITY_TAGS & {str(t).lower() for t in tags}):
        return "security"

    segments = {s.lower() for s in rule_id.split(".")}
    if segments & _SEMGREP_SECURITY_SEGMENTS:
        return "security"

    return "style"


def parse_sarif(file_or_dict: Any) -> list[Finding]:
    """Parse a SARIF 2.1.0 log into normalised findings.

    Spec: https://docs.oasis-open.org/sarif/sarif/v2.1.0/sarif-v2.1.0.html
    """
    sarif = _load(file_or_dict)
    if not isinstance(sarif, dict):
        return []

    findings: list[Finding] = []
    for run in sarif.get("runs", []) or []:
        tool_block = (run.get("tool") or {}).get("driver") or {}
        tool_name = (tool_block.get("name") or "sarif").strip()

        # Index rule definitions for default level + autofix lookup
        rule_index: dict[str, dict] = {}
        for rule in tool_block.get("rules", []) or []:
            rid = rule.get("id")
            if rid:
                rule_index[rid] = rule

        is_semgrep = tool_name.lower().startswith("semgrep")

        for result in run.get("results", []) or []:
            rule_id = result.get("ruleId") or result.get("rule", {}).get("id") or ""
            rule_def = rule_index.get(rule_id, {})

            level = result.get("level") or rule_def.get("defaultConfiguration", {}).get(
                "level"
            )
            severity = _norm_sarif_severity(level, result.get("kind"))

            msg_obj = result.get("message") or {}
            message = msg_obj.get("text") or msg_obj.get("markdown") or ""

            # First location wins; SARIF allows many.
            path, line, column = "", 0, 0
            locs = result.get("locations") or []
            if locs:
                phys = locs[0].get("physicalLocation") or {}
                art = phys.get("artifactLocation") or {}
                path = art.get("uri") or ""
                region = phys.get("region") or {}
                line = int(region.get("startLine") or 0)
                column = int(region.get("startColumn") or 0)

            # SARIF result has explicit fixes[] array → autofixable.
            autofix = bool(result.get("fixes")) or _is_autofixable(tool_name, rule_id)

            # Semgrep: prefix rule_id with category so finding-routes.json can
            # distinguish "semgrep:security.*" from "semgrep:style.*".
            # Resolution order: result.properties.category → rule tags → rule_id heuristic.
            routed_rule = rule_id
            if is_semgrep and rule_id:
                routed_rule = (
                    _semgrep_category(rule_id, result, rule_def) + "." + rule_id
                )

            findings.append(
                Finding(
                    tool=tool_name,
                    rule=routed_rule,
                    path=path,
                    line=line,
                    column=column,
                    message=message,
                    severity=severity,
                    autofix_available=autofix,
                    raw=result,
                )
            )
    return findings


# ---------------------------------------------------------------------------
# pyright --outputjson
# ---------------------------------------------------------------------------


def parse_pyright_json(stdin_or_path: Any) -> list[Finding]:
    """Parse `pyright --outputjson` output."""
    data = _load(stdin_or_path)
    if not isinstance(data, dict):
        return []

    findings: list[Finding] = []
    for diag in data.get("generalDiagnostics", []) or []:
        rng = diag.get("range") or {}
        start = rng.get("start") or {}
        # pyright uses 0-based; normalise to 1-based for human display.
        line = int(start.get("line", 0)) + 1 if start else 0
        col = int(start.get("character", 0)) + 1 if start else 0

        findings.append(
            Finding(
                tool="pyright",
                rule=diag.get("rule") or "",
                path=diag.get("file") or diag.get("uri") or "",
                line=line,
                column=col,
                message=diag.get("message") or "",
                severity=_norm_pyright_severity(diag.get("severity")),
                autofix_available=False,  # pyright never autofixes
                raw=diag,
            )
        )
    return findings


# ---------------------------------------------------------------------------
# sqlfluff --format json
# ---------------------------------------------------------------------------


def parse_sqlfluff_json(stdin_or_path: Any) -> list[Finding]:
    """Parse `sqlfluff lint --format json` output (top-level list of file objects)."""
    data = _load(stdin_or_path)
    if not isinstance(data, list):
        return []

    findings: list[Finding] = []
    for file_block in data:
        path = file_block.get("filepath") or file_block.get("file") or ""
        for v in file_block.get("violations", []) or []:
            code = v.get("code") or v.get("rule") or ""
            # sqlfluff 3.x exposes `severity` as 'warning'/'error'; older as 'fatal'/...
            sev_raw = (v.get("severity") or "warning").lower()
            severity = "error" if sev_raw in ("error", "fatal") else "warning"
            findings.append(
                Finding(
                    tool="sqlfluff",
                    rule=code,
                    path=path,
                    line=int(v.get("line_no") or v.get("start_line_no") or 0),
                    column=int(v.get("line_pos") or v.get("start_line_pos") or 0),
                    message=v.get("description") or "",
                    severity=severity,
                    # sqlfluff fix has no per-rule machine-readable flag; the
                    # `fixes` key may exist when --format json is paired with fix.
                    autofix_available=bool(v.get("fixes")),
                    raw=v,
                )
            )
    return findings


# ---------------------------------------------------------------------------
# markdownlint(-cli2) --json
# ---------------------------------------------------------------------------


def parse_markdownlint_json(stdin_or_path: Any) -> list[Finding]:
    """Parse markdownlint / markdownlint-cli2 JSON output (list of issues)."""
    data = _load(stdin_or_path)
    if not isinstance(data, list):
        return []

    findings: list[Finding] = []
    for v in data:
        # rule names: ruleNames=['MD013','line-length']; primary id is index 0.
        rule_names = v.get("ruleNames") or []
        rule = rule_names[0] if rule_names else (v.get("ruleName") or "")
        message = v.get("ruleDescription") or v.get("errorDetail") or ""
        if v.get("errorDetail"):
            message = f"{message}: {v['errorDetail']}".strip(": ")
        findings.append(
            Finding(
                tool="markdownlint",
                rule=rule,
                path=v.get("fileName") or "",
                line=int(v.get("lineNumber") or 0),
                column=int((v.get("errorRange") or [0])[0] or 0),
                message=message,
                severity="warning",  # markdownlint has no severity dimension
                autofix_available=bool(v.get("fixInfo")),
                raw=v,
            )
        )
    return findings


# ---------------------------------------------------------------------------
# pre-commit textual fallback
# ---------------------------------------------------------------------------

# Match common forms emitted by tools running under pre-commit, e.g.:
#   path/to/file.py:42:5: F401 'os' imported but unused
#   path/to/file.py:10: warning: something happened
_PRECOMMIT_LINE_RE = re.compile(
    r"""^
    (?P<path>[^\s:][^:]*?):
    (?P<line>\d+)
    (?::(?P<col>\d+))?
    :\s*
    (?:(?P<sev>error|warning|note|info)\s*:\s*)?
    (?:(?P<rule>[A-Z]{1,4}\d{2,4}|[A-Za-z0-9_-]+/[A-Za-z0-9_-]+)\s+)?
    (?P<msg>.+)
    $""",
    re.VERBOSE,
)

# Markdownlint-style line: `path:LINE[:COL] RULE/name message` (NO trailing colon
# before message). Used only when the active hook is "markdownlint".
#   docs/foo.md:4:151 MD013/line-length Line length [Expected: 150; Actual: 703]
#   docs/foo.md:3 MD036/no-emphasis-as-heading Emphasis used instead of a heading
_PRECOMMIT_MDLINT_LINE_RE = re.compile(
    r"^(?P<path>[^\s:][^:\n]*):(?P<line>\d+)(?::(?P<col>\d+))?\s+"
    r"(?P<rule>[A-Z]+\d+)/[\w-]+\s+(?P<message>.+)$"
)

# Pyright textual output: `<path>:<line>:<col> - <severity>: <message> (<rule>)`
# Pyright's actual output indents diagnostic lines by 2 spaces and splits the
# message across continuation lines, with the rule appearing in parens on a
# follow-up line. Examples (ANSI codes stripped first):
#   "  /abs/path/foo.py:7:19 - error: Argument of type ..."
#   "    \"Literal[...]\" is not assignable to \"int\" (reportArgumentType)"
# So the path-line regex tolerates leading whitespace and the rule may be
# absent (we then sniff it from the next non-empty line).
_PRECOMMIT_PYRIGHT_LINE_RE = re.compile(
    r"^\s*(?P<path>[^\s:][^:\n]*?):(?P<line>\d+):(?P<col>\d+)\s*-\s*"
    r"(?P<sev>error|warning|information|note|hint)\s*:\s*"
    r"(?P<message>.+?)"
    r"(?:\s*\((?P<rule>[A-Za-z][A-Za-z0-9_]*)\))?\s*$"
)
# Standalone rule continuation: "    ... (reportArgumentType)"
_PRECOMMIT_PYRIGHT_RULE_RE = re.compile(r"\((?P<rule>report[A-Z][A-Za-z]+)\)\s*$")

# ANSI escape sequence stripper for tools that color their text output (pyright,
# semgrep, ruff). Applied before regex matching when active_hook is in a known
# colorizing tool set.
_ANSI_RE = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")

# ISO-8601 timestamp prefix used by tools like trivy:
#   2026-06-18T23:42+02:00\tINFO\t[vuln] ...
#   2026-06-18T23:42:15Z\tWARN\t[secret] ...
_PRECOMMIT_ISO_TS_RE = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}")

# Tab-separated log-level marker followed by [category]:
#   "...\tINFO\t[vuln] Vulnerability scanning is enabled"
_PRECOMMIT_LOG_LEVEL_RE = re.compile(r"\t(?:INFO|WARN|DEBUG|ERROR|TRACE|FATAL)\t\[")

# Hook header lines from pre-commit, used to attribute follow-up diagnostics:
#   ruff.....................................................................Failed
_PRECOMMIT_HOOK_RE = re.compile(r"^([a-z][a-z0-9_-]+)\.{3,}.*(Failed|Passed)\s*$")

# Hook header text → canonical tool name. Used when the dotted-prefix hook line
# uses a human-readable label instead of the hook id (e.g. "Detect hardcoded
# secrets" for gitleaks).
_PRECOMMIT_HOOK_LABEL_RE = re.compile(
    r"^(?P<label>[A-Za-z][A-Za-z0-9 _-]*?)\.{3,}.*(Failed|Passed)\s*$"
)
_PRECOMMIT_HOOK_LABEL_TO_TOOL = {
    "detect hardcoded secrets": "gitleaks",
}

# gitleaks block parser. Each finding is a multi-line block starting with
# "Finding:" and exposing File:/Line:/RuleID:/Secret: rows. Blocks are
# separated by blank lines.
_GITLEAKS_FIELD_RE = re.compile(r"^\s*(?P<key>[A-Za-z]+)\s*:\s*(?P<val>.*?)\s*$")


def _parse_gitleaks_block(block_text: str) -> Finding | None:
    """Parse a single gitleaks finding block into a Finding, or None if invalid."""
    fields: dict[str, str] = {}
    for raw in block_text.splitlines():
        m = _GITLEAKS_FIELD_RE.match(raw)
        if not m:
            continue
        key = m.group("key").lower()
        if key in (
            "finding",
            "secret",
            "ruleid",
            "entropy",
            "file",
            "line",
            "fingerprint",
        ):
            fields[key] = m.group("val")

    # A valid block must at minimum carry File + Line + RuleID.
    if "file" not in fields or "line" not in fields or "ruleid" not in fields:
        return None

    try:
        line_no = int(fields["line"])
    except ValueError:
        return None

    rule = fields["ruleid"]
    # Redacted message — never include the actual secret value.
    message = f"Secret of type {rule} at line {line_no}"
    return Finding(
        tool="gitleaks",
        rule=rule,
        path=fields["file"],
        line=line_no,
        column=0,
        message=message,
        severity="error",
        autofix_available=False,
        raw={"block": block_text},
    )


def _parse_gitleaks_section(section_lines: list[str]) -> list[Finding]:
    """Split the gitleaks section into Finding-blocks and parse each."""
    # Re-join, then split on blank lines OR on lines beginning with "Finding:".
    joined = "\n".join(section_lines)
    # Split on blank lines first.
    rough_blocks = re.split(r"\n\s*\n", joined)

    findings: list[Finding] = []
    for rb in rough_blocks:
        if not rb.strip():
            continue
        # A rough block may contain multiple "Finding:" markers; split further.
        # Each sub-block must start with a "Finding:" line to be considered.
        sub_blocks: list[list[str]] = []
        current: list[str] = []
        for line in rb.splitlines():
            if re.match(r"^\s*Finding\s*:", line):
                if current:
                    sub_blocks.append(current)
                current = [line]
            else:
                if current:
                    current.append(line)
        if current:
            sub_blocks.append(current)

        for sb in sub_blocks:
            f = _parse_gitleaks_block("\n".join(sb))
            if f is not None:
                findings.append(f)
    return findings


def parse_pre_commit_output(text: str) -> list[Finding]:
    """Best-effort parse of pre-commit textual output."""
    if not text:
        return []

    findings: list[Finding] = []
    current_tool = "pre-commit"
    # Buffer gitleaks lines so we can run the block parser when the section ends
    # (next hook header reached, or end-of-input).
    gitleaks_buffer: list[str] = []

    def _flush_gitleaks() -> None:
        if gitleaks_buffer:
            findings.extend(_parse_gitleaks_section(gitleaks_buffer))
            gitleaks_buffer.clear()

    for raw_line in text.splitlines():
        line = raw_line.rstrip()

        # Detect a new hook header. Try the strict (lower-case hook-id) shape
        # first; fall back to the human-label shape for hooks like
        # "Detect hardcoded secrets" → gitleaks.
        hook_match = _PRECOMMIT_HOOK_RE.match(line)
        new_tool: str | None = None
        if hook_match:
            new_tool = hook_match.group(1)
        else:
            label_match = _PRECOMMIT_HOOK_LABEL_RE.match(line)
            if label_match:
                label = label_match.group("label").strip().lower()
                mapped = _PRECOMMIT_HOOK_LABEL_TO_TOOL.get(label)
                if mapped:
                    new_tool = mapped

        if new_tool is not None:
            _flush_gitleaks()
            current_tool = new_tool
            continue

        # While inside a gitleaks section, buffer raw lines and skip the
        # line-oriented parser entirely.
        if current_tool == "gitleaks":
            # Skip "- hook id: ..." / "- exit code: ..." pre-commit boilerplate
            # and gitleaks' own timestamped log line ("3:42PM INF ...").
            stripped = line.lstrip()
            if stripped.startswith("- hook id:") or stripped.startswith("- exit code:"):
                continue
            if re.match(r"^\d{1,2}:\d{2}(?:AM|PM)\s+\w+\s", stripped):
                continue
            gitleaks_buffer.append(line)
            continue

        if not line:
            continue

        # Skip scanner log-noise (trivy, etc.):
        #   2026-06-18T23:42+02:00\tINFO\t[vuln] ...
        if _PRECOMMIT_ISO_TS_RE.match(line):
            continue
        # Skip tab-delimited log-level markers like "\tINFO\t[..." / "\tWARN\t[..."
        if _PRECOMMIT_LOG_LEVEL_RE.search(line):
            continue
        # Skip pure progress indicators (e.g. "==> downloading db")
        if line.lstrip().startswith("==>"):
            continue

        # When the active hook is markdownlint, prefer the markdownlint-shape
        # regex: `path:LINE[:COL] RULE/name message` (no trailing colon).
        if current_tool == "markdownlint":
            md = _PRECOMMIT_MDLINT_LINE_RE.match(line)
            if md:
                rule = md.group("rule") or ""
                findings.append(
                    Finding(
                        tool="markdownlint",
                        rule=rule,
                        path=md.group("path"),
                        line=int(md.group("line")),
                        column=int(md.group("col") or 0),
                        message=(md.group("message") or "").strip(),
                        severity="warning",
                        autofix_available=_is_autofixable("markdownlint", rule),
                        raw={"line": raw_line},
                    )
                )
                continue

        # When the active hook is pyright, parse the text format:
        #   <path>:<line>:<col> - <severity>: <message> (<rule>)
        # Strip ANSI color codes first (pyright colorizes by default). Pyright
        # may also emit the rule on the NEXT line as "  ... (reportFoo)" so we
        # patch the most-recent pyright finding's rule when we see one.
        if current_tool == "pyright":
            stripped_line = _ANSI_RE.sub("", line)
            py = _PRECOMMIT_PYRIGHT_LINE_RE.match(stripped_line)
            if py:
                sev_raw = (py.group("sev") or "").lower()
                if sev_raw == "error":
                    severity = "error"
                elif sev_raw == "warning":
                    severity = "warning"
                else:
                    severity = "note"
                rule = (py.group("rule") or "").strip()
                findings.append(
                    Finding(
                        tool="pyright",
                        rule=rule,
                        path=py.group("path"),
                        line=int(py.group("line")),
                        column=int(py.group("col") or 0),
                        message=(py.group("message") or "").strip(),
                        severity=severity,
                        autofix_available=False,
                        raw={"line": raw_line},
                    )
                )
                continue
            # Continuation rule line: backfill the most recent pyright finding
            # if we haven't picked up a rule yet.
            rule_m = _PRECOMMIT_PYRIGHT_RULE_RE.search(stripped_line)
            if (
                rule_m
                and findings
                and findings[-1].tool == "pyright"
                and not findings[-1].rule
            ):
                findings[-1].rule = rule_m.group("rule")
                continue

        m = _PRECOMMIT_LINE_RE.match(line)
        if not m:
            continue

        sev_raw = (m.group("sev") or "").lower()
        if sev_raw == "error":
            severity = "error"
        elif sev_raw == "warning":
            severity = "warning"
        elif sev_raw in ("note", "info"):
            severity = "note"
        else:
            severity = "warning"

        rule = m.group("rule") or ""
        findings.append(
            Finding(
                tool=current_tool,
                rule=rule,
                path=m.group("path"),
                line=int(m.group("line")),
                column=int(m.group("col") or 0),
                message=(m.group("msg") or "").strip(),
                severity=severity,
                autofix_available=_is_autofixable(current_tool, rule),
                raw={"line": raw_line},
            )
        )
    # End-of-input: flush any pending gitleaks buffer.
    _flush_gitleaks()
    return findings


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


_PARSERS = {
    "sarif": parse_sarif,
    "pyright": parse_pyright_json,
    "sqlfluff": parse_sqlfluff_json,
    "markdownlint": parse_markdownlint_json,
    "pre-commit": parse_pre_commit_output,
}


def _serialise(findings: Iterable[Finding]) -> str:
    return json.dumps([f.to_dict() for f in findings], indent=2, ensure_ascii=False)


def main(argv: list[str] | None = None) -> int:
    args = list(sys.argv[1:] if argv is None else argv)
    tool: str | None = None
    input_path: str | None = None

    i = 0
    while i < len(args):
        a = args[i]
        if a in ("--tool", "-t"):
            i += 1
            if i >= len(args):
                print("error: --tool requires a value", file=sys.stderr)
                return 2
            tool = args[i].lower()
        elif a in ("--input", "-i"):
            i += 1
            if i >= len(args):
                print("error: --input requires a value", file=sys.stderr)
                return 2
            input_path = args[i]
        elif a in ("-h", "--help"):
            print(__doc__)
            return 0
        else:
            print(f"error: unknown arg {a!r}", file=sys.stderr)
            return 2
        i += 1

    if tool is None:
        print(
            f"error: --tool is required (one of: {', '.join(_PARSERS)})",
            file=sys.stderr,
        )
        return 2
    if tool not in _PARSERS:
        print(
            f"error: unknown tool {tool!r}; expected one of {list(_PARSERS)}",
            file=sys.stderr,
        )
        return 2

    parser = _PARSERS[tool]
    if input_path:
        payload: Any = Path(input_path).read_text(encoding="utf-8")
    else:
        payload = sys.stdin.read()

    # All parsers accept either raw text (pre-commit) or a JSON string (_load handles both).
    findings = parser(payload)

    sys.stdout.write(_serialise(findings))
    sys.stdout.write("\n")
    return 0


# ---------------------------------------------------------------------------
# Self-test (inline fixtures)
# ---------------------------------------------------------------------------


def _selftest() -> int:
    failures: list[str] = []

    def _check(cond: bool, label: str) -> None:
        if not cond:
            failures.append(label)

    # --- Fixture 1: SARIF 2.1.0 from a synthetic ruff run ------------------
    sarif_fixture = {
        "version": "2.1.0",
        "runs": [
            {
                "tool": {
                    "driver": {
                        "name": "ruff",
                        "rules": [
                            {
                                "id": "F401",
                                "defaultConfiguration": {"level": "warning"},
                            },
                            {
                                "id": "E999",
                                "defaultConfiguration": {"level": "error"},
                            },
                        ],
                    }
                },
                "results": [
                    {
                        "ruleId": "F401",
                        "level": "warning",
                        "message": {"text": "`os` imported but unused"},
                        "locations": [
                            {
                                "physicalLocation": {
                                    "artifactLocation": {"uri": "src/app.py"},
                                    "region": {"startLine": 3, "startColumn": 1},
                                }
                            }
                        ],
                        "fixes": [{"description": {"text": "Remove unused import"}}],
                    },
                    {
                        "ruleId": "E999",
                        "level": "error",
                        "message": {"text": "SyntaxError: bad token"},
                        "locations": [
                            {
                                "physicalLocation": {
                                    "artifactLocation": {"uri": "src/broken.py"},
                                    "region": {"startLine": 12, "startColumn": 4},
                                }
                            }
                        ],
                    },
                ],
            }
        ],
    }
    sarif_findings = parse_sarif(sarif_fixture)
    _check(
        len(sarif_findings) == 2,
        f"SARIF: expected 2 findings, got {len(sarif_findings)}",
    )
    f0 = sarif_findings[0]
    _check(f0.tool == "ruff", f"SARIF[0].tool == 'ruff' (got {f0.tool!r})")
    _check(f0.rule == "F401", f"SARIF[0].rule == 'F401' (got {f0.rule!r})")
    _check(f0.path == "src/app.py", f"SARIF[0].path (got {f0.path!r})")
    _check(
        f0.line == 3 and f0.column == 1,
        f"SARIF[0] line/col (got {f0.line}/{f0.column})",
    )
    _check(f0.severity == "warning", f"SARIF[0].severity (got {f0.severity!r})")
    _check(
        f0.autofix_available is True, "SARIF[0] has fixes[] → autofix_available=True"
    )
    f1 = sarif_findings[1]
    _check(f1.severity == "error", f"SARIF[1].severity (got {f1.severity!r})")
    _check(
        f1.autofix_available is False,
        f"SARIF[1] no fixes and rule not autofixable (got {f1.autofix_available})",
    )

    # Round-trip through JSON string
    sarif_findings_str = parse_sarif(json.dumps(sarif_fixture))
    _check(
        len(sarif_findings_str) == 2,
        "SARIF parses identical from JSON string input",
    )

    # --- Fixture 2: pyright --outputjson -----------------------------------
    pyright_fixture = {
        "version": "1.1.350",
        "summary": {"errorCount": 1, "warningCount": 1, "informationCount": 1},
        "generalDiagnostics": [
            {
                "file": "src/types.py",
                "severity": "error",
                "message": "Type 'str' is not assignable to 'int'",
                "rule": "reportGeneralTypeIssues",
                "range": {
                    "start": {"line": 9, "character": 4},
                    "end": {"line": 9, "character": 14},
                },
            },
            {
                "file": "src/types.py",
                "severity": "warning",
                "message": "Variable shadows builtin",
                "range": {
                    "start": {"line": 41, "character": 0},
                    "end": {"line": 41, "character": 3},
                },
            },
            {
                "file": "src/types.py",
                "severity": "information",
                "message": "Inferred type is 'int'",
                "range": {
                    "start": {"line": 0, "character": 0},
                    "end": {"line": 0, "character": 0},
                },
            },
        ],
    }
    py = parse_pyright_json(pyright_fixture)
    _check(len(py) == 3, f"pyright: expected 3 findings, got {len(py)}")
    _check(py[0].tool == "pyright", "pyright[0].tool == 'pyright'")
    _check(py[0].severity == "error", f"pyright[0].severity (got {py[0].severity!r})")
    _check(
        py[0].line == 10 and py[0].column == 5,
        f"pyright 1-based line/col (got {py[0].line}/{py[0].column})",
    )
    _check(py[0].rule == "reportGeneralTypeIssues", "pyright rule preserved")
    _check(py[1].severity == "warning", f"pyright[1].severity (got {py[1].severity!r})")
    _check(
        py[2].severity == "note", f"pyright information→note (got {py[2].severity!r})"
    )
    _check(all(f.autofix_available is False for f in py), "pyright never autofixable")

    # --- Bonus: autofix allowlist sanity-check -----------------------------
    _check(_is_autofixable("ruff", "F401") is True, "ruff F401 autofixable")
    _check(_is_autofixable("ruff", "PLR0915") is False, "ruff PLR0915 not autofixable")
    _check(
        _is_autofixable("biome", "lint/style/useConst") is True,
        "biome lint/style/* autofixable",
    )
    _check(
        _is_autofixable("biome", "lint/correctness/noUndeclaredVariables") is False,
        "biome non-listed not autofixable",
    )

    # --- Fixture 3: pre-commit markdownlint output -------------------------
    md_fixture = (
        "markdownlint.............................................................Failed\n"
        "- hook id: markdownlint\n"
        "- exit code: 1\n"
        "\n"
        'docs/foo.md:1 MD036/no-emphasis-as-heading Emphasis used [Context: "Bold"]\n'
        "docs/bar.md:5:151 MD013/line-length Line length [Expected: 150; Actual: 200]\n"
    )
    md_findings = parse_pre_commit_output(md_fixture)
    _check(
        len(md_findings) == 2,
        f"markdownlint: expected 2 findings, got {len(md_findings)}: {md_findings}",
    )
    if len(md_findings) == 2:
        _check(
            md_findings[0].tool == "markdownlint" and md_findings[0].rule == "MD036",
            f"markdownlint[0] tool/rule (got {md_findings[0].tool!r}/{md_findings[0].rule!r})",
        )
        _check(
            md_findings[1].rule == "MD013",
            f"markdownlint[1].rule == 'MD013' (got {md_findings[1].rule!r})",
        )

    # --- Fixture 4: trivy log-line noise should NOT become findings --------
    trivy_fixture = (
        "trivy fs (CRITICAL/HIGH CVEs)............................................Failed\n"
        "- hook id: trivy-fs\n"
        "- exit code: 1\n"
        "\n"
        "2026-06-18T23:42+02:00\tINFO\t[vuln] Vulnerability scanning is enabled\n"
        "2026-06-18T23:42+02:00\tINFO\t[secret] Secret scanning is enabled\n"
        "2026-06-18T23:42+02:00\tWARN\t[vuln-db] Skipped: no-fix-found\n"
        "==> downloading db\n"
    )
    trivy_findings = parse_pre_commit_output(trivy_fixture)
    _check(
        len(trivy_findings) == 0,
        f"trivy log-noise: expected 0 findings, got {len(trivy_findings)}: {trivy_findings}",
    )

    # --- Fixture 5: gitleaks block-format secrets --------------------------
    gitleaks_fixture = """Detect hardcoded secrets.................................................Failed
- hook id: gitleaks
- exit code: 1

    Finding:     AWS_ACCESS_KEY_ID = "AKIAQ******************"
    Secret:      AKIAQYLPMN5HCNRTBVPK
    RuleID:      aws-access-token
    Entropy:     3.781
    File:        smoke/test.py
    Line:        4
    Fingerprint: smoke/test.py:aws-access-token:4

    Finding:     AWS_SECRET_ACCESS_KEY = "9P****"
    Secret:      9Pq6Z7wXrK2bN8tFcVhA1mLs5dRgYjUiXeBoCv3T
    RuleID:      generic-api-key
    Entropy:     5.123
    File:        smoke/test.py
    Line:        5
    Fingerprint: smoke/test.py:generic-api-key:5

3:42PM INF 2 leaks were found
"""
    gl_findings = parse_pre_commit_output(gitleaks_fixture)
    gitleaks = [f for f in gl_findings if f.tool == "gitleaks"]
    _check(
        len(gitleaks) == 2,
        f"gitleaks: expected 2 findings, got {len(gitleaks)}: {gitleaks}",
    )
    if len(gitleaks) == 2:
        _check(
            gitleaks[0].rule == "aws-access-token",
            f"gitleaks[0].rule (got {gitleaks[0].rule!r})",
        )
        _check(
            gitleaks[0].path == "smoke/test.py",
            f"gitleaks[0].path (got {gitleaks[0].path!r})",
        )
        _check(
            gitleaks[0].line == 4,
            f"gitleaks[0].line (got {gitleaks[0].line!r})",
        )
        _check(
            "AKIAQYLPMN5HCNRTBVPK" not in gitleaks[0].message,
            f"gitleaks[0] secret value redacted (got {gitleaks[0].message!r})",
        )
        _check(
            gitleaks[1].rule == "generic-api-key",
            f"gitleaks[1].rule (got {gitleaks[1].rule!r})",
        )
        _check(
            gitleaks[0].severity == "error",
            f"gitleaks[0].severity (got {gitleaks[0].severity!r})",
        )
        _check(
            gitleaks[0].autofix_available is False,
            f"gitleaks[0].autofix_available (got {gitleaks[0].autofix_available!r})",
        )

    # --- Fixture 6: pyright text output -----------------------------------
    pyright_fixture = """pyright..................................................................Failed
- hook id: pyright
- exit code: 1

/abs/path/foo.py:7:19 - error: Argument of type "Literal['x']" cannot be assigned to parameter "a" of type "int" in function "add" (reportArgumentType)
foo.py:42:3 - warning: Type partially unknown (reportUnknownMemberType)
1 error, 1 warning, 0 informations
"""
    py_findings = parse_pre_commit_output(pyright_fixture)
    pyright = [f for f in py_findings if f.tool == "pyright"]
    _check(
        len(pyright) == 2,
        f"pyright: expected 2 findings, got {len(pyright)}: {pyright}",
    )
    if len(pyright) == 2:
        _check(
            pyright[0].rule == "reportArgumentType",
            f"pyright[0].rule (got {pyright[0].rule!r})",
        )
        _check(
            pyright[0].path == "/abs/path/foo.py",
            f"pyright[0].path (got {pyright[0].path!r})",
        )
        _check(
            pyright[0].line == 7 and pyright[0].column == 19,
            f"pyright[0].line/column (got {pyright[0].line}:{pyright[0].column})",
        )
        _check(
            pyright[0].severity == "error",
            f"pyright[0].severity (got {pyright[0].severity!r})",
        )
        _check(
            pyright[1].rule == "reportUnknownMemberType",
            f"pyright[1].rule (got {pyright[1].rule!r})",
        )
        _check(
            pyright[1].severity == "warning",
            f"pyright[1].severity (got {pyright[1].severity!r})",
        )

    # --- Fixture 7: semgrep SARIF category routing --------------------------
    semgrep_fixture = {
        "version": "2.1.0",
        "runs": [
            {
                "tool": {
                    "driver": {
                        "name": "Semgrep OSS",
                        "rules": [
                            {
                                "id": "python.lang.security.deserialization.use-of-pickle",
                                "properties": {
                                    "category": "security",
                                    "tags": ["CWE-502"],
                                },
                            },
                            {
                                "id": "python.lang.correctness.useless-return",
                                "properties": {"category": "best-practice"},
                            },
                            {
                                "id": "python.flask.security.xss.audit.direct-use-of-jinja2",
                                "properties": {"tags": ["security"]},
                            },
                        ],
                    }
                },
                "results": [
                    {
                        "ruleId": "python.lang.security.deserialization.use-of-pickle",
                        "properties": {"category": "security"},
                        "message": {"text": "avoid pickle"},
                        "locations": [
                            {
                                "physicalLocation": {
                                    "artifactLocation": {"uri": "app/io.py"},
                                    "region": {"startLine": 5},
                                }
                            }
                        ],
                    },
                    {
                        "ruleId": "python.lang.correctness.useless-return",
                        "message": {"text": "useless return"},
                        "locations": [
                            {
                                "physicalLocation": {
                                    "artifactLocation": {"uri": "app/util.py"},
                                    "region": {"startLine": 12},
                                }
                            }
                        ],
                    },
                    {
                        "ruleId": "python.flask.security.xss.audit.direct-use-of-jinja2",
                        "message": {"text": "XSS risk"},
                        "locations": [
                            {
                                "physicalLocation": {
                                    "artifactLocation": {"uri": "app/views.py"},
                                    "region": {"startLine": 99},
                                }
                            }
                        ],
                    },
                ],
            }
        ],
    }
    sg_findings = parse_sarif(semgrep_fixture)
    _check(
        len(sg_findings) == 3,
        f"semgrep fixture: expected 3 findings, got {len(sg_findings)}",
    )
    if len(sg_findings) == 3:
        _check(
            sg_findings[0].rule
            == "security.python.lang.security.deserialization.use-of-pickle",
            f"semgrep[0].rule should have 'security.' prefix (got {sg_findings[0].rule!r})",
        )
        _check(
            sg_findings[1].rule == "style.python.lang.correctness.useless-return",
            f"semgrep[1].rule should have 'style.' prefix (got {sg_findings[1].rule!r})",
        )
        _check(
            sg_findings[2].rule.startswith("security."),
            f"semgrep[2] xss rule (tag-based) should be 'security.*' (got {sg_findings[2].rule!r})",
        )

    if failures:
        for f in failures:
            print(f"FAIL: {f}", file=sys.stderr)
        print(f"\n{len(failures)} self-test failure(s)", file=sys.stderr)
        return 1
    print("OK: all self-tests passed")
    return 0


if __name__ == "__main__" and len(sys.argv) > 1 and sys.argv[1] == "--selftest":
    sys.exit(_selftest())

if __name__ == "__main__":
    sys.exit(main())
