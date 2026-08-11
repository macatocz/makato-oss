"""Apply spec-delta.md operations to docs/specs/<capability>.md.

Given a spec-delta.md file (ADDED / MODIFIED / REMOVED requirement sections)
and a target docs/specs/ directory, update the living capability spec in-place.

Capability is derived from the parent directory of spec-delta.md:
    specs/foo-bar/spec-delta.md  →  capability "foo-bar"
    target: <docs-dir>/foo-bar.md

Operation semantics:
    ADDED     — appended to docs/specs/<capability>.md; file created if absent.
    MODIFIED  — replace the matching ### <name> section in the target file.
                A dangling ref (no matching heading) emits a WARN to stderr
                and is skipped — exit 0.
    REMOVED   — replace the ### <name> section with ``<!-- REMOVED: <name> -->``.
    Empty     — spec-delta with no populated requirement sections is a no-op.

Stdlib only.

Exit codes:
    0  success (including no-op and dangling MODIFIED WARN)
    1  usage error or spec-delta.md not found
"""

from __future__ import annotations

import argparse
import os
import re
import sys
from typing import IO

# ── Regex constants ───────────────────────────────────────────────────────────

_SECTION_RE = re.compile(r"^##\s+(ADDED Requirements|MODIFIED Requirements|REMOVED Requirements)\s*$")
_REQ_RE = re.compile(r"^###\s+(.+?)\s*$")
_H2_RE = re.compile(r"^##\s+")
_H3_RE = re.compile(r"^###\s+(.+?)\s*$")


# ── Pure functions ────────────────────────────────────────────────────────────


def parse_delta(text: str) -> dict[str, list[tuple[str, list[str]]]]:
    """Parse spec-delta.md into ADDED / MODIFIED / REMOVED requirement lists.

    Args:
        text: Full text content of a spec-delta.md file.

    Returns:
        Dict with keys ``"ADDED"``, ``"MODIFIED"``, ``"REMOVED"``.  Each value
        is a list of ``(requirement_name, body_lines)`` tuples.  Only
        requirements whose body contains at least one non-comment, non-blank
        line are included (template ``<!-- ... -->`` blocks are treated as empty
        and silently skipped).
    """
    result: dict[str, list[tuple[str, list[str]]]] = {
        "ADDED": [],
        "MODIFIED": [],
        "REMOVED": [],
    }
    current_section: str | None = None
    current_req: str | None = None
    current_body: list[str] = []

    def flush_req() -> None:
        if current_section and current_req is not None:
            stripped = [line for line in current_body if line.strip() and not line.strip().startswith("<!--")]
            if stripped:
                result[current_section].append((current_req, current_body[:]))

    for line in text.splitlines():
        sec_m = _SECTION_RE.match(line)
        if sec_m:
            flush_req()
            current_req = None
            current_body = []
            label = sec_m.group(1)
            if label.startswith("ADDED"):
                current_section = "ADDED"
            elif label.startswith("MODIFIED"):
                current_section = "MODIFIED"
            elif label.startswith("REMOVED"):
                current_section = "REMOVED"
            continue

        if _H2_RE.match(line) and not _SECTION_RE.match(line):
            flush_req()
            current_req = None
            current_body = []
            current_section = None
            continue

        req_m = _REQ_RE.match(line)
        if req_m and current_section:
            flush_req()
            current_req = req_m.group(1)
            current_body = []
            continue

        if current_req is not None:
            current_body.append(line)

    flush_req()
    return result


def split_sections(
    lines: list[str],
) -> list[tuple[str | None, list[str]]]:
    """Split markdown lines into ``(heading_line_or_None, body_lines)`` chunks.

    Args:
        lines: Lines of a markdown file (without trailing newlines).

    Returns:
        List of ``(heading, body)`` tuples.  The first chunk has
        ``heading=None`` for any content before the first ``###`` heading.
        Only ``###`` headings are split points; ``##`` headings are preserved
        as body content within their enclosing chunk.
    """
    chunks: list[tuple[str | None, list[str]]] = []
    current_heading: str | None = None
    current_body: list[str] = []

    for line in lines:
        if _H3_RE.match(line):
            chunks.append((current_heading, current_body))
            current_heading = line
            current_body = []
        else:
            current_body.append(line)

    chunks.append((current_heading, current_body))
    return chunks


def join_chunks(chunks: list[tuple[str | None, list[str]]]) -> list[str]:
    """Reassemble ``(heading, body)`` chunks back into a flat list of lines.

    Args:
        chunks: Output of :func:`split_sections`.

    Returns:
        Flat list of lines ready for ``"\\n".join(...)``.
    """
    out: list[str] = []
    for heading, body in chunks:
        if heading is not None:
            out.append(heading)
        out.extend(body)
    return out


def req_name_from_heading(heading_line: str | None) -> str | None:
    """Extract the requirement name from a ``### <name>`` heading line.

    Args:
        heading_line: A markdown ``###`` heading line, or ``None``.

    Returns:
        The stripped requirement name, or ``None`` when the line does not match.
    """
    m = re.match(r"^###\s+(.+?)\s*$", heading_line or "")
    return m.group(1) if m else None


def apply_delta(
    delta_path: str,
    docs_dir: str,
    *,
    stderr: IO[str] | None = None,
) -> None:
    """Apply ADDED / MODIFIED / REMOVED operations from delta_path to the target spec.

    Args:
        delta_path: Path to the spec-delta.md file.
        docs_dir:   Path to the docs/specs/ directory (created if absent).
        stderr:     File object for WARN messages (default: ``sys.stderr``).

    Reads:
        ``delta_path`` (spec-delta.md).
        ``docs_dir/<capability>.md`` (target living spec, when it exists).

    Writes:
        ``docs_dir/<capability>.md`` with operations applied.

    Returns:
        ``None`` on success (including no-op and dangling-MODIFIED WARNs).
    """
    if stderr is None:
        stderr = sys.stderr

    delta_text = open(delta_path, encoding="utf-8").read()
    delta = parse_delta(delta_text)

    # Derive capability from the spec-delta.md parent directory basename.
    parent_dir = os.path.basename(os.path.dirname(os.path.abspath(delta_path)))
    capability = parent_dir

    os.makedirs(docs_dir, exist_ok=True)
    target_path = os.path.join(docs_dir, capability + ".md")

    # No-op when no section contains real requirements.
    if not any(delta[k] for k in ("ADDED", "MODIFIED", "REMOVED")):
        return

    # Load existing target or start empty.
    if os.path.exists(target_path):
        with open(target_path, encoding="utf-8") as fh:
            target_lines = fh.read().splitlines()
    else:
        target_lines = []

    # ── Apply ADDED ───────────────────────────────────────────────────────────
    for req_name, body_lines in delta["ADDED"]:
        while target_lines and not target_lines[-1].strip():
            target_lines.pop()
        if target_lines:
            target_lines.append("")
        target_lines.append(f"### {req_name}")
        target_lines.extend(body_lines)

    # ── Apply MODIFIED ────────────────────────────────────────────────────────
    for req_name, body_lines in delta["MODIFIED"]:
        chunks = split_sections(target_lines)
        matched = False
        new_chunks: list[tuple[str | None, list[str]]] = []
        for heading, body in chunks:
            existing_name = req_name_from_heading(heading)
            if existing_name and existing_name.lower() == req_name.lower():
                new_chunks.append((heading, body_lines))
                matched = True
            else:
                new_chunks.append((heading, body))
        if matched:
            target_lines = join_chunks(new_chunks)
        else:
            print(
                f'WARN: sync-living-specs: dangling MODIFIED ref "{req_name}" in {capability}.md — no matching heading found; skipping',
                file=stderr,
            )

    # ── Apply REMOVED ─────────────────────────────────────────────────────────
    for req_name, _body_lines in delta["REMOVED"]:
        chunks = split_sections(target_lines)
        new_chunks = []
        for heading, body in chunks:
            existing_name = req_name_from_heading(heading)
            if existing_name and existing_name.lower() == req_name.lower():
                new_chunks.append((None, [f"<!-- REMOVED: {req_name} -->"]))
            else:
                new_chunks.append((heading, body))
        target_lines = join_chunks(new_chunks)

    # ── Write result ──────────────────────────────────────────────────────────
    output = "\n".join(target_lines)
    if output and not output.endswith("\n"):
        output += "\n"

    with open(target_path, "w", encoding="utf-8") as fh:
        fh.write(output)


# ── CLI ───────────────────────────────────────────────────────────────────────


class _Parser(argparse.ArgumentParser):
    """ArgumentParser that exits with code 1 on usage errors (matches bash behaviour)."""

    def error(self, message: str) -> None:  # type: ignore[override]
        self.print_usage(sys.stderr)
        self.exit(1, f"{self.prog}: error: {message}\n")


def main(argv: list[str] | None = None) -> int:
    """Entry point for sync_living_specs.py.

    Args:
        argv: Argument list (default: ``sys.argv[1:]``).

    Returns:
        Exit code: 0 on success, 1 on error.
    """
    parser = _Parser(
        prog="sync_living_specs.py",
        description="Apply spec-delta.md operations to docs/specs/<capability>.md.",
    )
    parser.add_argument(
        "delta_path",
        help="Path to the spec-delta.md file (e.g. specs/<KEY>-<slug>/spec-delta.md)",
    )
    parser.add_argument(
        "docs_dir",
        help="Path to the docs/specs/ directory (will be created if absent)",
    )
    args = parser.parse_args(argv)

    if not os.path.isfile(args.delta_path):
        print(
            f"sync-living-specs: spec-delta file not found: {args.delta_path}",
            file=sys.stderr,
        )
        return 1

    apply_delta(args.delta_path, args.docs_dir)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
