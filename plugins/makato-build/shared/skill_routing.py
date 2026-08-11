"""Skill routing frontmatter parser.

Reads the `skill_routing` field from an agent .md file's YAML frontmatter and
returns a SkillRoutingState value that downstream components use to decide:

  - whether to prepend `recommended_skills[]` into the agent's system prompt
    (should_inject_recommendations)
  - whether to write a F4 JSONL line to .claude/skill-invocations.log
    (should_emit_f4_log)

Decision rule (D21 — default-on, opt-out):

  field value   → state    → inject? → emit?
  ───────────────────────────────────────────
  "disabled"    → DISABLED → False   → False
  "enabled"     → ENABLED  → True    → True
  absent        → ABSENT   → True    → True  (default-on)

Only the exact lowercase strings "disabled" and "enabled" are accepted.
Any other value raises ValueError.

Depends on PyYAML — a hard dependency of the makato pytest harness (see
plugins/makato-build/shared/test_inject_context.py). Mirrors that peer file's
assumption to keep the frontmatter/YAML parsing story consistent across the
shared/ helpers.
"""

from __future__ import annotations

import enum
from pathlib import Path


class SkillRoutingState(enum.Enum):
    DISABLED = "disabled"
    ENABLED = "enabled"
    ABSENT = "absent"


def parse_skill_routing(path: Path | str) -> SkillRoutingState:
    """Return the SkillRoutingState encoded in the agent file's YAML frontmatter.

    Raises:
        ValueError: if the frontmatter YAML is syntactically broken, or if the
            `skill_routing` field contains an unrecognised value (e.g. 'DISABLED',
            'maybe').  The file path is included in the message to aid diagnosis.
        FileNotFoundError: if *path* does not exist (stdlib default — not caught here).
    """
    path = Path(path)
    text = path.read_text(encoding="utf-8")
    raw = _extract_frontmatter(text, path)
    if raw is None:
        return SkillRoutingState.ABSENT
    parsed = _parse_yaml_simple(raw, path)
    value = parsed.get("skill_routing")
    if value is None:
        return SkillRoutingState.ABSENT
    if value == "disabled":
        return SkillRoutingState.DISABLED
    if value == "enabled":
        return SkillRoutingState.ENABLED
    raise ValueError(f"{path}: invalid skill_routing value {value!r}. Only 'disabled' and 'enabled' are accepted (lowercase).")


def is_skill_routing_disabled(path: Path | str) -> bool:
    """Return True iff the agent explicitly opts out of skill routing (D21)."""
    return parse_skill_routing(path) is SkillRoutingState.DISABLED


def should_inject_recommendations(path: Path | str) -> bool:
    """Return True iff recommended_skills[] should be prepended into the agent's prompt."""
    return not is_skill_routing_disabled(path)


def should_emit_f4_log(path: Path | str) -> bool:
    """Return True iff a F4 JSONL line should be written for this agent's Skill calls."""
    return not is_skill_routing_disabled(path)


# ---------------------------------------------------------------------------
# Internal helpers — stdlib YAML subset parser
# ---------------------------------------------------------------------------


def _extract_frontmatter(text: str, path: Path) -> str | None:
    """Return the raw frontmatter string (between the two --- delimiters), or None.

    A file with no leading `---` returns None (no frontmatter block).  A file with
    an opening `---` but no closing delimiter also returns None (treated as no
    frontmatter, consistent with the D21 default-on stance — a malformed opener
    should not accidentally opt an agent out).
    """
    lines = text.splitlines()
    if not lines or lines[0].strip() != "---":
        return None
    for i, line in enumerate(lines[1:], start=1):
        if line.strip() == "---":
            return "\n".join(lines[1:i])
    return None


def _parse_yaml_simple(raw: str, path: Path) -> dict:
    """Parse the YAML frontmatter block.

    PyYAML is a hard dependency of the makato pytest harness (see
    plugins/makato-build/shared/test_inject_context.py) — this parser mirrors
    the same assumption so we don't drift from the peer resolver.

    Raises ValueError on parse failure with the file path in the message.
    """
    import yaml  # type: ignore[import-untyped]

    try:
        result = yaml.safe_load(raw)
    except yaml.YAMLError as exc:
        raise ValueError(f"{path}: YAML parse error in frontmatter: {exc}") from exc
    if result is None:
        return {}
    if not isinstance(result, dict):
        raise ValueError(f"{path}: frontmatter did not parse as a mapping")
    return result
