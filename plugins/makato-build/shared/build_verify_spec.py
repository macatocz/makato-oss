"""
build_verify_spec.py — spec-level verification logic for makato-build (#568).

Three-dimensional verification:
  COMPLETENESS — plan-<N>.md checkbox audit (all - [x] checked?)
  CORRECTNESS  — stories.json successScenarios satisfied by the diff?
  COHERENCE    — spec-delta.md MODIFIED requirements evidenced by the diff?

Importable module; consumed by build-verify-spec.sh (thin bash wrapper) and
tested directly by test_build_verify_spec.py.

All logic is stdlib only (json, re, sys, pathlib).
"""

from __future__ import annotations

import json
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path

# ---------------------------------------------------------------------------
# Data structures
# ---------------------------------------------------------------------------


@dataclass
class CompletenessResult:
    checked: int = 0
    total: int = 0
    unchecked_items: list[str] = field(default_factory=list)

    @property
    def ok(self) -> bool:
        return self.total == 0 or self.unchecked_items == []


@dataclass
class ScenarioVerdict:
    title: str
    verdict: str  # CONFIRMED | GAP | UNTESTABLE


@dataclass
class CorrectnessResult:
    verdicts: list[ScenarioVerdict] = field(default_factory=list)
    gap_count: int = 0
    skipped: bool = False

    @property
    def ok(self) -> bool:
        return self.gap_count == 0


@dataclass
class RequirementVerdict:
    name: str
    verdict: str  # CONFIRMED | GAP | SUGGESTION | UNTESTABLE
    shall: str = ""


@dataclass
class CoherenceResult:
    verdicts: list[RequirementVerdict] = field(default_factory=list)
    gap_count: int = 0
    suggestion_count: int = 0
    skipped: bool = False

    @property
    def ok(self) -> bool:
        return self.gap_count == 0


# ---------------------------------------------------------------------------
# Keyword-matching helpers
# ---------------------------------------------------------------------------

_STOP = frozenset(
    {
        "the",
        "and",
        "for",
        "that",
        "this",
        "with",
        "from",
        "are",
        "not",
        "was",
        "its",
        "into",
        "when",
        "then",
        "given",
        "shall",
        "must",
        "each",
        "will",
        "plan",
        "spec",
        "task",
        "diff",
        "file",
        "code",
        "test",
        "should",
        "have",
        "been",
        "also",
        "both",
        "only",
        "skip",
        "none",
        "any",
        "all",
        "new",
    }
)


def _keywords(text: str) -> list[str]:
    words = re.findall(r"[a-z_][a-z0-9_]{2,}", text.lower())
    return [w for w in words if w not in _STOP]


def _text_in_diff(needle: str, diff_text: str, threshold: float = 0.4) -> bool:
    """Return True when enough key words from needle appear in diff_text."""
    if not needle.strip() or not diff_text.strip():
        return False
    diff_lower = diff_text.lower()
    words = _keywords(needle)
    if not words:
        return False
    hits = sum(1 for w in words if w in diff_lower)
    return hits / len(words) >= threshold


# ---------------------------------------------------------------------------
# COMPLETENESS
# ---------------------------------------------------------------------------


def check_completeness(plan_text: str) -> CompletenessResult:
    """
    Scan the ## Tasks section of plan_text and count checked/unchecked boxes.

    Only checkboxes inside the ## Tasks section are counted; checkboxes in
    other sections (e.g. ## Definition of Done, ## Background) are ignored.
    """
    result = CompletenessResult()
    in_tasks = False

    for line in plan_text.splitlines():
        # Detect ## Tasks heading (any number of leading #)
        if re.match(r"^#+\s+Tasks\s*$", line, re.IGNORECASE):
            in_tasks = True
            continue

        # A new top-level (##) heading that is NOT ## Tasks ends the section
        if in_tasks and re.match(r"^##\s+\S", line) and not re.match(r"^###", line):
            in_tasks = False
            continue

        if not in_tasks:
            continue

        # Checked: - [x] or * [x]  (case-insensitive x)
        if re.match(r"^\s*[-*]\s+\[[xX]\]", line):
            result.checked += 1
            continue

        # Unchecked: - [ ]
        if re.match(r"^\s*[-*]\s+\[ \]", line):
            result.total += 1  # will be subtracted below; use raw count
            m = re.match(r"^\s*[-*]\s+\[ \]\s+(.*)", line)
            label = m.group(1).strip() if m else line.strip()
            result.unchecked_items.append(label)

    result.total = result.checked + len(result.unchecked_items)
    return result


# ---------------------------------------------------------------------------
# CORRECTNESS
# ---------------------------------------------------------------------------


def check_correctness(stories_text: str | None, diff_text: str) -> CorrectnessResult:
    """
    Verify each stories.json successScenarios entry against diff_text.
    Returns skipped=True when stories_text is absent/empty.
    """
    if not stories_text:
        return CorrectnessResult(skipped=True)

    try:
        stories_data = json.loads(stories_text)
    except json.JSONDecodeError, ValueError:
        # Treat as gap — malformed stories.json
        v = ScenarioVerdict(title="(malformed stories.json)", verdict="GAP")
        return CorrectnessResult(verdicts=[v], gap_count=1)

    if not isinstance(stories_data, dict):
        return CorrectnessResult(skipped=True)

    all_scenarios = [
        scenario
        for story in stories_data.get("stories", [])
        for scenario in (story.get("description") or {}).get("successScenarios", [])
    ]

    result = CorrectnessResult()
    for scenario in all_scenarios:
        title = scenario.get("title", "")
        given = scenario.get("given", "")
        when_ = scenario.get("when", "")
        then_ = scenario.get("then", "")
        descriptor = " ".join(filter(None, [title, given, when_, then_]))

        if not diff_text.strip():
            verdict = "UNTESTABLE"
        elif _text_in_diff(descriptor, diff_text):
            verdict = "CONFIRMED"
        else:
            verdict = "GAP"
            result.gap_count += 1

        result.verdicts.append(
            ScenarioVerdict(title=title or descriptor[:60], verdict=verdict)
        )

    return result


# ---------------------------------------------------------------------------
# COHERENCE
# ---------------------------------------------------------------------------


def _parse_modified_requirements(delta_text: str) -> list[tuple[str, str]]:
    """
    Extract (name, shall_statement) pairs from the ## MODIFIED Requirements
    section of a spec-delta.md file.
    """
    requirements: list[tuple[str, str]] = []
    in_modified = False
    current_name: str | None = None
    current_shall: list[str] = []

    for line in delta_text.splitlines():
        if re.match(r"^#+\s+MODIFIED\s+Requirements", line, re.IGNORECASE):
            in_modified = True
            current_name = None
            current_shall = []
            continue

        if in_modified and re.match(r"^##\s+\S", line) and not re.match(r"^###", line):
            if current_name and current_shall:
                requirements.append((current_name, " ".join(current_shall)))
            in_modified = False
            current_name = None
            current_shall = []
            continue

        if not in_modified:
            continue

        heading = re.match(r"^###\s+(.*)", line)
        if heading:
            if current_name and current_shall:
                requirements.append((current_name, " ".join(current_shall)))
            current_name = heading.group(1).strip()
            current_shall = []
            continue

        shall_m = re.match(r"^\*{0,2}SHALL\*{0,2}\s*:\s*(.*)", line, re.IGNORECASE)
        if shall_m and current_name is not None:
            current_shall.append(shall_m.group(1).strip())

    if in_modified and current_name and current_shall:
        requirements.append((current_name, " ".join(current_shall)))

    return requirements


def check_coherence(delta_text: str | None, diff_text: str) -> CoherenceResult:
    """
    Verify MODIFIED requirements from spec-delta.md against diff_text.
    Returns skipped=True when delta_text is absent/empty.
    """
    if not delta_text:
        return CoherenceResult(skipped=True)

    requirements = _parse_modified_requirements(delta_text)
    result = CoherenceResult()

    for name, shall_stmt in requirements:
        if not diff_text.strip():
            verdict = "UNTESTABLE"
        elif _text_in_diff(shall_stmt, diff_text, threshold=0.35):
            verdict = "CONFIRMED"
        else:
            words = _keywords(shall_stmt)
            hits = sum(1 for w in words if w in diff_text.lower()) if words else 0
            ratio = hits / len(words) if words else 0
            if ratio < 0.2:
                verdict = "GAP"
                result.gap_count += 1
            else:
                verdict = "SUGGESTION"
                result.suggestion_count += 1

        result.verdicts.append(
            RequirementVerdict(name=name, verdict=verdict, shall=shall_stmt)
        )

    return result


# ---------------------------------------------------------------------------
# Report formatter
# ---------------------------------------------------------------------------


def format_report(
    completeness: CompletenessResult,
    correctness: CorrectnessResult,
    coherence: CoherenceResult,
) -> tuple[str, int]:
    """
    Return (report_text, exit_code).
    exit_code 0 = all OK; 1 = CRITICAL finding.
    """
    lines: list[str] = []
    exit_code = 0

    # COMPLETENESS
    lines.append("=== COMPLETENESS ===")
    lines.append(f"Tasks: {completeness.checked}/{completeness.total} checked")
    if completeness.unchecked_items:
        for item in completeness.unchecked_items:
            lines.append(f"  CRITICAL: unchecked — {item}")
        n = len(completeness.unchecked_items)
        lines.append(f"CRITICAL: {n} unchecked task(s)")
        exit_code = 1
    else:
        lines.append("OK")
    lines.append("")

    # CORRECTNESS
    lines.append("=== CORRECTNESS ===")
    if correctness.skipped:
        lines.append("stories.json: absent — skipped")
        lines.append("OK")
    else:
        lines.append(
            f"stories.json successScenarios: {len(correctness.verdicts)} scenario(s)"
        )
        for v in correctness.verdicts:
            lines.append(f"  {v.verdict}: {v.title}")
        if correctness.gap_count > 0:
            lines.append(f"CRITICAL: {correctness.gap_count} GAP finding(s)")
            exit_code = 1
        else:
            lines.append("OK")
    lines.append("")

    # COHERENCE
    lines.append("=== COHERENCE ===")
    if coherence.skipped:
        lines.append("spec-delta.md: absent — skipped")
        lines.append("OK")
    else:
        n_req = len(coherence.verdicts)
        lines.append(f"spec-delta.md: {n_req} MODIFIED requirement(s)")
        for v in coherence.verdicts:
            if v.verdict == "GAP":
                lines.append(f"  GAP: {v.name} — SHALL: {v.shall[:80]}")
            elif v.verdict == "SUGGESTION":
                lines.append(
                    f"  SUGGESTION: {v.name} — partial evidence, review recommended"
                )
            elif v.verdict == "CONFIRMED":
                lines.append(f"  CONFIRMED: {v.name}")
            else:
                lines.append(f"  UNTESTABLE: {v.name}")
        if coherence.gap_count > 0:
            lines.append(f"CRITICAL: {coherence.gap_count} COHERENCE GAP finding(s)")
            exit_code = 1
        elif coherence.suggestion_count > 0:
            lines.append(
                f"SUGGESTION: {coherence.suggestion_count} low-confidence match(es) — non-blocking"
            )
        else:
            lines.append("OK")

    return "\n".join(lines), exit_code


# ---------------------------------------------------------------------------
# CLI entry point
# ---------------------------------------------------------------------------


def main(argv: list[str] | None = None) -> int:
    """
    CLI: build_verify_spec.py <plan_file> <diff_file> [<stories_file>] [<delta_file>]

    Returns exit code (0 = pass, 1 = CRITICAL, 2 = usage error).
    """
    args = argv if argv is not None else sys.argv[1:]

    if len(args) < 2:
        print(
            "usage: build_verify_spec.py <plan_file> <diff_file>"
            " [<stories_file>] [<delta_file>]",
            file=sys.stderr,
        )
        return 2

    plan_path = args[0]
    diff_path = args[1]
    stories_path = args[2] if len(args) > 2 else ""
    delta_path = args[3] if len(args) > 3 else ""

    def _read(path: str) -> str:
        if not path:
            return ""
        try:
            return Path(path).read_text(encoding="utf-8")
        except OSError as exc:
            print(f"build-verify-spec: cannot read {path}: {exc}", file=sys.stderr)
            return ""

    plan_text = _read(plan_path)
    if not plan_text:
        print(
            f"build-verify-spec: empty or unreadable plan file: {plan_path}",
            file=sys.stderr,
        )
        return 2

    diff_text = _read(diff_path)
    stories_text = _read(stories_path) if stories_path else ""
    delta_text = _read(delta_path) if delta_path else ""

    completeness = check_completeness(plan_text)
    correctness = check_correctness(stories_text or None, diff_text)
    coherence = check_coherence(delta_text or None, diff_text)

    report, exit_code = format_report(completeness, correctness, coherence)
    print(report)
    return exit_code


if __name__ == "__main__":
    sys.exit(main())
