"""Synthesise Current Requirements into docs/specs/<capability>.md at archival time.

When a `to-issues`-born spec folder (multiple issues sharing one
``stories.json`` / ``created-issues.json``) is archived post-merge and has NO
``spec-delta.md``, the feature's requirements would otherwise never land in the
living spec — ``sync_living_specs.py`` only runs on a ``spec-delta.md``, which
``to-issues`` never produces. A later ``makato-change`` on the same feature
would then start from an empty living baseline (#33).

This module is the archival-time complement to ``sync_living_specs.py``: it
reads ``plan.md`` acceptance criteria and/or ``stories.json`` success scenarios
and appends ``### <requirement>`` sections (with ``**SHALL**:`` bullet lines) to
``<docs-dir>/<capability>.md``, where ``capability`` is the spec folder's
basename — matching the living-spec section format ``sync_living_specs.py``
writes. ``archive-spec.sh`` invokes it only when ``spec-delta.md`` is absent, so
the two paths never both fire for one folder.

Stdlib only.

Exit codes:
    0  success (including a clean no-op when no requirement content is found)
    1  usage error or spec folder not found
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys

# ── Regex constants ───────────────────────────────────────────────────────────

_H1_RE = re.compile(r"^#\s+(.+?)\s*$")
_TITLE_RE = re.compile(r"^\*\*Title:\*\*\s*(.+?)\s*$")
# The AC heading, but NOT the `## Acceptance Criteria Coverage` table heading —
# the trailing `$` after the optional whitespace excludes any suffix word.
_AC_HEADING_RE = re.compile(r"^##\s+Acceptance [Cc]riteria\s*$")
_H2_RE = re.compile(r"^##\s+")
_BULLET_RE = re.compile(r"^[-*]\s+(.+?)\s*$")
_IMPL_PLAN_PREFIX_RE = re.compile(r"^Implementation Plan:\s*", re.IGNORECASE)


# ── Pure parsers ────────────────────────────────────────────────────────────


def parse_plan(text: str) -> tuple[str, list[str]]:
    """Extract the feature title and acceptance-criteria bullet texts from plan.md.

    Args:
        text: Full text content of a ``plan.md`` file.

    Returns:
        ``(title, acceptance_criteria)``.  ``title`` is taken from the first
        ``**Title:**`` field when present, else the first ``# `` H1 heading
        (with any ``Implementation Plan:`` prefix stripped), else ``""``.
        ``acceptance_criteria`` is the list of bullet texts under the
        ``## Acceptance criteria`` heading — bounded by the next ``##`` heading,
        so the sibling ``## Acceptance Criteria Coverage`` table never leaks in.
    """
    title = ""
    h1 = ""
    acs: list[str] = []
    in_ac = False

    for line in text.splitlines():
        if not title:
            m = _TITLE_RE.match(line)
            if m:
                title = m.group(1)
        if not h1:
            m = _H1_RE.match(line)
            if m:
                h1 = _IMPL_PLAN_PREFIX_RE.sub("", m.group(1)).strip()

        if _AC_HEADING_RE.match(line):
            in_ac = True
            continue
        if in_ac and _H2_RE.match(line):
            in_ac = False
            continue
        if in_ac:
            bm = _BULLET_RE.match(line)
            if bm:
                acs.append(bm.group(1))

    return (title or h1, acs)


def parse_stories_json(text: str) -> list[tuple[str, list[str]]]:
    """Extract ``(story_title, scenarios)`` pairs from stories.json content.

    Args:
        text: Full text content of a ``stories.json`` file.

    Returns:
        One ``(title, scenarios)`` tuple per story.  ``scenarios`` is taken from
        the ``successScenarios`` list of strings when present, else from the
        ``scenario`` field of each ``acceptanceTestCases`` entry, else ``[]``.
        Returns ``[]`` on invalid JSON or when no ``stories`` list is found.
        Accepts either a top-level object with a ``stories`` key or a bare list
        of story objects.
    """
    # Split clauses (not `except (ValueError, TypeError)`) to stay stable across
    # the toolchain: ruff (py3.14 target) rewrites the tuple to PEP 758 parenless
    # form, which pyright (<3.14 target) then rejects. Separate clauses satisfy both.
    try:
        data = json.loads(text)
    except ValueError:
        return []
    except TypeError:
        return []

    if isinstance(data, dict):
        stories = data.get("stories", [])
    elif isinstance(data, list):
        stories = data
    else:
        return []

    if not isinstance(stories, list):
        return []

    pairs: list[tuple[str, list[str]]] = []
    for story in stories:
        if not isinstance(story, dict):
            continue
        title = str(story.get("title") or story.get("id") or "")
        scenarios: list[str] = []
        success = story.get("successScenarios")
        if isinstance(success, list):
            scenarios = [str(s) for s in success if str(s).strip()]
        else:
            for case in story.get("acceptanceTestCases", []) or []:
                if isinstance(case, dict):
                    scenario = str(case.get("scenario") or "").strip()
                    if scenario:
                        scenarios.append(scenario)
        pairs.append((title, scenarios))
    return pairs


# ── Synthesis ─────────────────────────────────────────────────────────────


def _render_section(name: str, bullets: list[str]) -> list[str]:
    """Render one ``### <name>`` section with ``**SHALL**:`` bullet lines."""
    lines = [f"### {name}", ""]
    lines.extend(f"**SHALL**: {b}" for b in bullets)
    return lines


def synthesize(spec_folder: str, docs_dir: str) -> None:
    """Append synthesised requirement sections to ``<docs_dir>/<capability>.md``.

    ``capability`` is ``os.path.basename(spec_folder)``. Reads ``plan.md`` and
    (optionally) ``stories.json`` from ``spec_folder``, builds one or more
    ``### <requirement>`` sections with ``**SHALL**:`` bullets, and appends them
    to the living spec — creating ``docs_dir`` and the target file when absent.

    A clean no-op (no file created, no write) when neither source yields any
    requirement content.

    Args:
        spec_folder: Path to the ``specs/<key>-<slug>/`` folder being archived.
        docs_dir:    Path to the ``docs/specs/`` directory.
    """
    capability = os.path.basename(os.path.normpath(spec_folder))

    sections: list[tuple[str, list[str]]] = []

    plan_path = os.path.join(spec_folder, "plan.md")
    if os.path.isfile(plan_path):
        with open(plan_path, encoding="utf-8") as fh:
            title, acs = parse_plan(fh.read())
        if acs:
            sections.append((title or capability, acs))

    stories_path = os.path.join(spec_folder, "stories.json")
    if os.path.isfile(stories_path):
        with open(stories_path, encoding="utf-8") as fh:
            for story_title, scenarios in parse_stories_json(fh.read()):
                if scenarios:
                    sections.append((story_title or capability, scenarios))

    # No-op when nothing to synthesise — never touch the filesystem.
    if not sections:
        return

    os.makedirs(docs_dir, exist_ok=True)
    target_path = os.path.join(docs_dir, capability + ".md")

    if os.path.exists(target_path):
        with open(target_path, encoding="utf-8") as fh:
            lines = fh.read().splitlines()
    else:
        lines = []

    for name, bullets in sections:
        while lines and not lines[-1].strip():
            lines.pop()
        if lines:
            lines.append("")
        lines.extend(_render_section(name, bullets))

    output = "\n".join(lines)
    if output and not output.endswith("\n"):
        output += "\n"

    with open(target_path, "w", encoding="utf-8") as fh:
        fh.write(output)


# ── CLI ───────────────────────────────────────────────────────────────────


class _Parser(argparse.ArgumentParser):
    """ArgumentParser that exits with code 1 on usage errors (matches bash behaviour)."""

    def error(self, message: str) -> None:  # type: ignore[override]
        self.print_usage(sys.stderr)
        self.exit(1, f"{self.prog}: error: {message}\n")


def main(argv: list[str] | None = None) -> int:
    """Entry point for synthesize_living_spec.py.

    Args:
        argv: Argument list (default: ``sys.argv[1:]``).

    Returns:
        Exit code: 0 on success (including no-op), 1 on error.
    """
    parser = _Parser(
        prog="synthesize_living_spec.py",
        description="Synthesise Current Requirements into docs/specs/<capability>.md from plan.md / stories.json.",
    )
    parser.add_argument(
        "spec_folder",
        help="Path to the specs/<KEY>-<slug>/ folder being archived",
    )
    parser.add_argument(
        "docs_dir",
        help="Path to the docs/specs/ directory (will be created if absent)",
    )
    args = parser.parse_args(argv)

    if not os.path.isdir(args.spec_folder):
        print(
            f"synthesize-living-spec: spec folder not found: {args.spec_folder}",
            file=sys.stderr,
        )
        return 1

    synthesize(args.spec_folder, args.docs_dir)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
