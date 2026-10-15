"""Resolve makato spec folders across supported naming conventions.

The plan producer may use a feature slug as the folder name while the build
caller may receive only the GitHub issue number. This module keeps that
translation deterministic and shared by the build helpers.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path


class SpecFolderError(RuntimeError):
    """Base class for resolution failures."""


class SpecFolderNotFound(SpecFolderError):
    """No spec folder matches the requested key."""


class SpecFolderAmbiguous(SpecFolderError):
    """More than one spec folder matches the requested key."""


_ISSUE_KEY = re.compile(r"^(?:#|gh-)?([1-9][0-9]*)$")


def _normalise_key(key: str) -> str:
    value = key.strip()
    if value.startswith("#"):
        value = value[1:]
    if value.lower().startswith("gh-"):
        value = value[3:]
    return value


def _directories(specs_root: Path) -> list[Path]:
    if not specs_root.is_dir():
        return []
    return sorted(path for path in specs_root.iterdir() if path.is_dir())


def _unique(candidates: set[Path], key: str) -> Path | None:
    ordered = sorted(candidates)
    if len(ordered) > 1:
        names = ", ".join(str(path) for path in ordered)
        raise SpecFolderAmbiguous(f"multiple spec folders found for {key!r}: {names}")
    return ordered[0] if ordered else None


def _manifest_matches(folder: Path, issue_number: str) -> bool:
    manifest = folder / "seed-manifest.json"
    if not manifest.is_file():
        return False
    try:
        data = json.loads(manifest.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):  # fmt: skip
        return False
    if not isinstance(data, dict):
        return False
    return str(data.get("issue_number", "")) == issue_number


def _created_issues_matches(folder: Path, issue_number: str) -> bool:
    artifact = folder / "created-issues.json"
    if not artifact.is_file():
        return False
    try:
        data = json.loads(artifact.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):  # fmt: skip
        return False
    if not isinstance(data, dict):
        return False
    issues = data.get("issues", [])
    if not isinstance(issues, list):
        return False
    return any(str(item.get("issue_number", "")) == issue_number for item in issues if isinstance(item, dict))


def _stories_matches(folder: Path, issue_number: str) -> bool:
    """Match issue-backed stories produced by makato-plan."""
    artifact = folder / "stories.json"
    if not artifact.is_file():
        return False
    try:
        data = json.loads(artifact.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):  # fmt: skip
        return False

    def contains_issue(value: object) -> bool:
        if isinstance(value, dict):
            for key in ("githubIssue", "issue_number", "issueNumber"):
                if str(value.get(key, "")) == issue_number:
                    return True
            return any(contains_issue(child) for child in value.values())
        if isinstance(value, list):
            return any(contains_issue(child) for child in value)
        return False

    return contains_issue(data)


def _issue_matches(folder: Path, issue_number: str) -> bool:
    return (
        (folder / f"plan-{issue_number}.md").is_file()
        or _manifest_matches(folder, issue_number)
        or _created_issues_matches(folder, issue_number)
        or _stories_matches(folder, issue_number)
        or (folder / f"workflow-state-{issue_number}.json").is_file()
    )


def resolve_spec_folder(repo_root: Path, key: str, issue_number: str | None = None) -> Path:
    """Return the unique spec folder for *key*.

    Direct key matches remain the first choice for non-numeric keys. Numeric
    issue keys prefer artifact-backed issue matches so a stale ``specs/995``
    logging placeholder cannot shadow ``specs/<slug>/plan-995.md``.
    """

    root = Path(repo_root).resolve()
    specs_root = root / "specs"
    normalised = _normalise_key(key)
    issue_match = _ISSUE_KEY.match(normalised)
    issue = issue_number or (issue_match.group(1) if issue_match else None)
    folders = _directories(specs_root)

    if issue is not None:
        issue_matches = {folder for folder in folders if _issue_matches(folder, issue)}
        resolved_issue = _unique(issue_matches, key)
        if resolved_issue is not None:
            return resolved_issue

    prefix_matches = {folder for folder in folders if folder.name.startswith(f"{normalised}-")}
    resolved_prefix = _unique(prefix_matches, key)
    if resolved_prefix is not None:
        return resolved_prefix

    exact = specs_root / normalised
    if exact.is_dir():
        return exact

    raise SpecFolderNotFound(f"no spec folder found for {key!r} under {specs_root}")


def _main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("repo_root", type=Path)
    parser.add_argument("key")
    parser.add_argument("--issue-number")
    args = parser.parse_args(argv)

    try:
        print(resolve_spec_folder(args.repo_root, args.key, args.issue_number))
    except SpecFolderAmbiguous as exc:
        print(f"spec-folder: {exc}", file=sys.stderr)
        return 3
    except SpecFolderNotFound as exc:
        print(f"spec-folder: {exc}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(_main(sys.argv[1:]))
