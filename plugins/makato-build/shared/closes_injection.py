"""Choose artifact-derived ``Closes #N`` lines for build-create-pr.

to-issues writes one ``created-issues.json`` per spec folder, and a module
folder can list dozens of story issues without any story key. GitHub closes
every issue a merged PR body references, so a story PR may close only its own
issue: the explicit ``--issue N`` (the PO-agent's ``ISSUE_NUMBER``) or a
GitHub-style work-item key. When neither names the issue, the artifact's entry
is used only if the folder belongs to that one issue.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import asdict, dataclass
from pathlib import Path

_GITHUB_ISSUE = re.compile(r"(?:gh[#-]|#)?([1-9][0-9]*)", re.IGNORECASE)
_FOLDER_ISSUE_FILE = re.compile(r"plan-([1-9][0-9]*)\.md|workflow-state-([1-9][0-9]*)\.json")


@dataclass(frozen=True)
class ClosesPlan:
    issue: int | None
    closes: tuple[int, ...]
    closes_injected: int
    artifact_status: str
    artifact_issues: int
    artifact_warning: str | None
    scope_warning: str | None


def github_issue(reference: str) -> int | None:
    """Return the issue number for ``N``, ``#N``, ``GH#N`` or ``GH-N``; ``None`` otherwise.

    Jira keys such as ``DCP-1234`` deliberately return ``None``: their number
    is not a GitHub issue.
    """

    match = _GITHUB_ISSUE.fullmatch(reference.strip())
    return int(match.group(1)) if match else None


def _issue_numbers(artifact: object) -> tuple[int, ...] | None:
    if not isinstance(artifact, dict):
        return None
    issues = artifact.get("issues")
    if not isinstance(issues, list):
        return None
    numbers: list[int] = []
    for entry in issues:
        number = entry.get("issue_number") if isinstance(entry, dict) else None
        if not isinstance(number, int) or isinstance(number, bool) or number < 1:
            return None
        numbers.append(number)
    return tuple(numbers)


def _schema_findings(artifact: object, schema_path: Path | None) -> tuple[str | None, str | None]:
    """Return ``(advisory, violation)``; an unusable schema is advisory, never a violation."""

    if schema_path is None:
        return "artifact-schema-unavailable", None
    try:
        import jsonschema
    except ImportError:
        return "artifact-schema-unavailable (jsonschema is not installed)", None
    try:
        schema = json.loads(schema_path.read_text(encoding="utf-8"))
        jsonschema.validate(artifact, schema)
    except jsonschema.ValidationError as error:
        return None, f"created-issues.json failed schema validation ({error.message})"
    except (OSError, UnicodeDecodeError, json.JSONDecodeError, jsonschema.SchemaError) as error:  # fmt: skip
        return f"artifact-schema-unavailable ({error})", None
    return None, None


def _load_artifact(artifact_path: Path, schema_path: Path | None) -> tuple[str, tuple[int, ...], str | None]:
    """Return ``(artifact_status, issue_numbers, warning)``."""

    if not artifact_path.is_file():
        return "missing", (), None
    try:
        artifact = json.loads(artifact_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:  # fmt: skip
        return "malformed", (), f"created-issues.json is unreadable ({error})"
    advisory, violation = _schema_findings(artifact, schema_path)
    if violation is not None:
        return "malformed", (), violation
    numbers = _issue_numbers(artifact)
    if numbers is None:
        return "malformed", (), "created-issues.json is malformed (issues[] needs a positive integer issue_number per entry)"
    return "valid", numbers, advisory


def _folder_issues(folder: Path) -> set[int]:
    """Issue numbers the folder's per-issue plans and workflow states name."""

    found: set[int] = set()
    for path in folder.iterdir():
        match = _FOLDER_ISSUE_FILE.fullmatch(path.name)
        if match:
            found.add(int(match.group(1) or match.group(2)))
    return found


def plan_closes(artifact_path: Path, *, key: str = "", issue: int | None = None, schema_path: Path | None = None) -> ClosesPlan:
    """Select artifact entries; explicit GitHub links remain Case 2's responsibility.

    ``closes_injected`` counts the closes the artifact supplies; when the
    artifact lists the current issue, its entry is the canonical source (D20).
    """

    current = issue if issue is not None else github_issue(key)
    status, listed, artifact_warning = _load_artifact(artifact_path, schema_path)

    if current is not None:
        listed_current = current in listed
        scope_warning = None
        if status == "valid" and not listed_current:
            scope_warning = f"issue #{current} is not listed in created-issues.json — no artifact Closes injected"
        return ClosesPlan(current, (current,) if listed_current else (), int(listed_current), status, len(listed), artifact_warning, scope_warning)

    if not listed:
        return ClosesPlan(None, (), 0, status, 0, artifact_warning, None)
    try:
        folder_issues = set(listed) | _folder_issues(artifact_path.parent)
    except OSError as error:
        return ClosesPlan(None, (), 0, status, len(listed), artifact_warning, f"cannot determine whether spec folder is shared ({error}) — no Closes injected")
    if len(folder_issues) == 1:
        return ClosesPlan(None, (listed[0],), 1, status, len(listed), artifact_warning, None)
    scope_warning = f"shared spec folder names {len(folder_issues)} issues and the current issue is unknown; pass --issue N — no Closes injected"
    return ClosesPlan(None, (), 0, status, len(listed), artifact_warning, scope_warning)


def _issue_argument(value: str) -> int | None:
    if not value.strip():
        return None
    if not re.fullmatch(r"[1-9][0-9]*", value):
        raise argparse.ArgumentTypeError(f"expected a GitHub issue number, got {value!r}")
    return int(value)


def _main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("artifact", type=Path, help="the spec folder's created-issues.json (need not exist)")
    parser.add_argument("--key", default="", help="work-item key; GH#N, #N and N name a GitHub issue")
    parser.add_argument("--issue", type=_issue_argument, default=None, help="current GitHub issue (ISSUE_NUMBER); empty means unknown")
    parser.add_argument("--schema", default="", help="created-issues.schema.json; empty skips schema validation")
    args = parser.parse_args(argv)

    plan = plan_closes(args.artifact, key=args.key, issue=args.issue, schema_path=Path(args.schema) if args.schema else None)
    if plan.artifact_warning:
        action = "without schema validation" if plan.artifact_status == "valid" else "without artifact Closes injection"
        print(f"[build-create-pr] WARNING: {plan.artifact_warning} — continuing {action}", file=sys.stderr)
    if plan.scope_warning:
        print(f"[build-create-pr] WARNING: {plan.scope_warning}", file=sys.stderr)
    print(json.dumps(asdict(plan)))
    return 0


if __name__ == "__main__":
    raise SystemExit(_main(sys.argv[1:]))
