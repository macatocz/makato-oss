"""Flip verified AC checkboxes in a GitHub issue body.

Given a machine-readable per-AC verdict set and a GitHub issue body, produce
the new issue body with verified ACs flipped ``- [ ]`` → ``- [x]``, applying
the granular-first / all-or-nothing-fallback policy.

This is the executable reference implementation of documentation-agent.md
§ "Step 4a — Mark verified AC checkboxes".

Policy:
    Granular: for each verdict with ``verified==true`` whose normalised
    ``ac_text`` matches a ``- [ ]`` checkbox line (exact or substring on the
    normalised label), flip that line to ``- [x]``.  ``verified==false`` or
    unmatched → untouched.  Never flips ``[x]`` → ``[ ]``.

    All-or-nothing fallback: when ZERO verdicts matched any checkbox line,
    fall back to a coarse gate — iff every verdict is ``verified==true``,
    check ALL ``- [ ]`` lines (``mode: "fallback-all"``); if any verdict is
    ``verified==false``, check none (``mode: "fallback-none"``).

    Empty verdict array → no change, ``mode: "skipped"``.

Output:
    Modified body written to stdout.
    JSON summary written to stderr::

        {"mode":"granular|fallback-all|fallback-none|skipped",
         "boxes_checked":N,"verdicts_total":N,"verified":N}

Stdlib only.

Exit codes:
    0  success (body on stdout, summary on stderr) — including no-op
    1  usage / unreadable input / malformed verdict JSON / verdict JSON not an array
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from typing import IO

# ── Regex ─────────────────────────────────────────────────────────────────────

# Unchecked-checkbox line: capture indent, spacing after marker, and label.
_BOX_RE = re.compile(r"^(\s*[-*]\s+)\[ \](\s+)(.*)$")


# ── Pure functions ────────────────────────────────────────────────────────────


def normalize(text: str) -> str:
    """Normalise AC text for fuzzy matching.

    Lowercase, strip a leading ``AC-N`` / ``Scenario N:`` label, collapse
    whitespace, and drop trailing punctuation — so plan-AC wording pairs with
    issue-body wording even when labels differ.

    Args:
        text: Raw AC text or checkbox label.

    Returns:
        Normalised string suitable for equality / substring comparison.
    """
    t = text.strip().lower()
    t = re.sub(r"^(ac[-\s]?\d+|scenario\s+\d+)\s*[:.\-]?\s*", "", t)
    t = re.sub(r"\s+", " ", t)
    t = t.strip(" .:;,-")
    return t


def load_verdicts(path: str) -> list[dict]:
    """Load and validate the verdicts JSON array from *path*.

    Args:
        path: Filesystem path to a JSON file that must be an array of
              ``{ac_id, ac_text, verified, ...}`` objects.

    Returns:
        The parsed list of verdict dicts.

    Raises:
        SystemExit(1): on ``JSONDecodeError`` or when the top-level value is
                       not a list.
    """
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
    except (json.JSONDecodeError, ValueError) as exc:
        print(f"mark-ac-checkboxes: malformed verdict JSON: {exc}", file=sys.stderr)
        raise SystemExit(1)

    if not isinstance(data, list):
        print("mark-ac-checkboxes: verdict JSON must be an array", file=sys.stderr)
        raise SystemExit(1)

    return data  # type: ignore[return-value]


def mark_checkboxes(
    verdicts: list[dict],
    body: str,
) -> tuple[str, dict]:
    """Apply the granular / fallback checkbox-marking policy.

    Args:
        verdicts: List of verdict dicts.  Each must have at minimum
                  ``ac_text`` (str) and ``verified`` (bool-ish) fields.
        body:     Raw issue body text (markdown).

    Returns:
        A ``(new_body, summary)`` tuple where *summary* is the JSON-serialisable
        dict ``{"mode": ..., "boxes_checked": ..., "verdicts_total": ...,
        "verified": ...}``.
    """
    lines = body.split("\n")

    # Index unchecked checkbox lines with their normalised labels.
    box_lines: list[tuple[int, str]] = []  # (line_index, normalized_label)
    for i, line in enumerate(lines):
        m = _BOX_RE.match(line)
        if m:
            box_lines.append((i, normalize(m.group(3))))

    total = len(verdicts)
    verified_verdicts = [v for v in verdicts if v.get("verified") is True]
    verified_count = len(verified_verdicts)

    def check_line(idx: int) -> None:
        m = _BOX_RE.match(lines[idx])
        assert m is not None  # guaranteed — idx came from box_lines
        lines[idx] = f"{m.group(1)}[x]{m.group(2)}{m.group(3)}"

    matched_indices: set[int] = set()

    # ── Granular pass ─────────────────────────────────────────────────────────
    for v in verified_verdicts:
        ac_norm = normalize(str(v.get("ac_text", "")))
        if not ac_norm:
            continue
        for i, label in box_lines:
            if i in matched_indices:
                continue
            if ac_norm == label or ac_norm in label or label in ac_norm:
                matched_indices.add(i)
                check_line(i)
                break  # one AC → at most one box

    if total == 0:
        mode = "skipped"
    elif matched_indices:
        mode = "granular"
    else:
        # ── All-or-nothing fallback ───────────────────────────────────────────
        all_verified = total > 0 and verified_count == total
        if all_verified:
            for i, _ in box_lines:
                check_line(i)
                matched_indices.add(i)
            mode = "fallback-all"
        else:
            mode = "fallback-none"

    new_body = "\n".join(lines)
    summary = {
        "mode": mode,
        "boxes_checked": len(matched_indices),
        "verdicts_total": total,
        "verified": verified_count,
    }
    return new_body, summary


def process_files(
    verdicts_path: str,
    body_path: str,
    *,
    stdout: IO[str] | None = None,
    stderr: IO[str] | None = None,
) -> int:
    """Load inputs, apply checkbox policy, emit outputs.

    Args:
        verdicts_path: Path to the verdicts JSON file.
        body_path:     Path to the issue body markdown file.
        stdout:        Destination for the modified body (default: ``sys.stdout``).
        stderr:        Destination for the JSON summary (default: ``sys.stderr``).

    Returns:
        Exit code: 0 on success, 1 on error.
    """
    out: IO[str] = sys.stdout if stdout is None else stdout
    err: IO[str] = sys.stderr if stderr is None else stderr

    verdicts = load_verdicts(verdicts_path)  # exits 1 on malformed input

    with open(body_path, encoding="utf-8") as fh:
        body = fh.read()

    new_body, summary = mark_checkboxes(verdicts, body)
    out.write(new_body)
    print(json.dumps(summary), file=err)
    return 0


# ── CLI ───────────────────────────────────────────────────────────────────────


class _Parser(argparse.ArgumentParser):
    """ArgumentParser that exits with code 1 on usage errors (matches bash behaviour)."""

    def error(self, message: str) -> None:  # type: ignore[override]
        self.print_usage(sys.stderr)
        self.exit(1, f"{self.prog}: error: {message}\n")


def main(argv: list[str] | None = None) -> int:
    """Entry point for mark_ac_checkboxes.py.

    Args:
        argv: Argument list (default: ``sys.argv[1:]``).

    Returns:
        Exit code: 0 on success, 1 on error.
    """
    parser = _Parser(
        prog="mark_ac_checkboxes.py",
        description="Flip verified AC checkboxes in a GitHub issue body.",
    )
    parser.add_argument(
        "verdicts_path",
        help="Path to a JSON array of {ac_id, ac_text, verified, ...} verdicts",
    )
    parser.add_argument(
        "body_path",
        help="Path to the raw issue body (markdown)",
    )
    args = parser.parse_args(argv)

    if not os.path.isfile(args.verdicts_path):
        print(
            f"mark-ac-checkboxes: verdicts file not found: {args.verdicts_path}",
            file=sys.stderr,
        )
        return 1

    if not os.path.isfile(args.body_path):
        print(
            f"mark-ac-checkboxes: issue-body file not found: {args.body_path}",
            file=sys.stderr,
        )
        return 1

    return process_files(args.verdicts_path, args.body_path)


if __name__ == "__main__":
    raise SystemExit(main())
