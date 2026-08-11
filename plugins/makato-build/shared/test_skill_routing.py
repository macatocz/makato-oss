"""Unit tests for the skill_routing frontmatter parser.

Run from repo root:
    python3 -m pytest plugins/makato-build/shared/test_skill_routing.py -v

Mirrors the test_inject_context.py precedent — same layout, same discovery
path (pyproject.toml scopes pytest to plugins/makato-build/shared/).
"""

from __future__ import annotations

import sys
import textwrap
import unittest
from pathlib import Path

_HERE = Path(__file__).parent.resolve()
if str(_HERE) not in sys.path:
    sys.path.insert(0, str(_HERE))

from skill_routing import (  # noqa: E402
    SkillRoutingState,
    is_skill_routing_disabled,
    parse_skill_routing,
    should_emit_f4_log,
    should_inject_recommendations,
)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _write_agent(tmp_path: Path, content: str) -> Path:
    p = tmp_path / "agent.md"
    p.write_text(textwrap.dedent(content))
    return p


# ---------------------------------------------------------------------------
# parse_skill_routing — state detection
# ---------------------------------------------------------------------------


class TestParseDisabled(unittest.TestCase):
    def setUp(self):
        import tempfile

        self.tmp = Path(tempfile.mkdtemp())

    def test_parse_disabled_returns_disabled(self):
        path = _write_agent(
            self.tmp,
            """\
            ---
            name: some-agent
            skill_routing: disabled
            ---
            body
        """,
        )
        self.assertEqual(parse_skill_routing(path), SkillRoutingState.DISABLED)

    def test_parse_enabled_returns_enabled(self):
        path = _write_agent(
            self.tmp,
            """\
            ---
            name: some-agent
            skill_routing: enabled
            ---
            body
        """,
        )
        self.assertEqual(parse_skill_routing(path), SkillRoutingState.ENABLED)

    def test_parse_absent_field_returns_absent(self):
        path = _write_agent(
            self.tmp,
            """\
            ---
            name: some-agent
            model: sonnet
            ---
            body
        """,
        )
        self.assertEqual(parse_skill_routing(path), SkillRoutingState.ABSENT)

    def test_parse_no_frontmatter_returns_absent(self):
        """Files predating the feature have no --- delimiters → ABSENT (backwards-compat)."""
        path = _write_agent(
            self.tmp,
            """\
            # Agent without frontmatter
            body text
        """,
        )
        self.assertEqual(parse_skill_routing(path), SkillRoutingState.ABSENT)

    def test_parse_empty_frontmatter_returns_absent(self):
        """Empty frontmatter block → field absent → ABSENT."""
        path = _write_agent(
            self.tmp,
            """\
            ---
            ---
            body
        """,
        )
        self.assertEqual(parse_skill_routing(path), SkillRoutingState.ABSENT)

    def test_parse_null_value_returns_absent(self):
        """`skill_routing: null` → ABSENT (treats null identically to a missing field)."""
        path = _write_agent(
            self.tmp,
            """\
            ---
            name: some-agent
            skill_routing: null
            ---
            body
        """,
        )
        self.assertEqual(parse_skill_routing(path), SkillRoutingState.ABSENT)

    def test_parse_unclosed_frontmatter_returns_absent(self):
        """Opening `---` without a closing delimiter → treated as no frontmatter → ABSENT.

        The D21 default-on stance means a malformed opener must not accidentally
        opt an agent out; the safer default is to include (skill-routed).
        """
        path = _write_agent(
            self.tmp,
            """\
            ---
            name: partial
            skill_routing: disabled
            body without closing delimiter
        """,
        )
        self.assertEqual(parse_skill_routing(path), SkillRoutingState.ABSENT)

    def test_malformed_frontmatter_raises_valueerror(self):
        """Syntactically broken YAML → ValueError with path in message."""
        path = _write_agent(
            self.tmp,
            """\
            ---
            name: [unclosed
            ---
            body
        """,
        )
        with self.assertRaises(ValueError) as ctx:
            parse_skill_routing(path)
        self.assertIn(str(path), str(ctx.exception))

    def test_invalid_value_raises_valueerror(self):
        """Only 'disabled' and 'enabled' are valid values."""
        path = _write_agent(
            self.tmp,
            """\
            ---
            skill_routing: maybe
            ---
            body
        """,
        )
        with self.assertRaises(ValueError):
            parse_skill_routing(path)

    def test_case_sensitivity_uppercase_rejected(self):
        """'DISABLED' is not a valid value — lowercase only, matching design-doc examples."""
        path = _write_agent(
            self.tmp,
            """\
            ---
            skill_routing: DISABLED
            ---
            body
        """,
        )
        with self.assertRaises(ValueError):
            parse_skill_routing(path)

    def test_case_sensitivity_mixed_rejected(self):
        path = _write_agent(
            self.tmp,
            """\
            ---
            skill_routing: Disabled
            ---
            body
        """,
        )
        with self.assertRaises(ValueError):
            parse_skill_routing(path)


# ---------------------------------------------------------------------------
# Boolean helpers — contract per D21 default-on
# ---------------------------------------------------------------------------


class TestBooleanHelpers(unittest.TestCase):
    def setUp(self):
        import tempfile

        self.tmp = Path(tempfile.mkdtemp())

    def _agent(self, field_line: str = "") -> Path:
        lines = ["---", "name: test-agent"]
        if field_line:
            lines.append(field_line)
        lines += ["---", "body"]
        # unique filename per call — avoids overwrite when multiple paths are
        # created in the same test (all share self.tmp)
        name = field_line.replace(": ", "_").replace(" ", "_") or "absent"
        p = self.tmp / f"agent_{name}.md"
        p.write_text("\n".join(lines))
        return p

    def test_is_disabled_true_only_for_explicit_disabled(self):
        self.assertTrue(is_skill_routing_disabled(self._agent("skill_routing: disabled")))
        self.assertFalse(is_skill_routing_disabled(self._agent("skill_routing: enabled")))
        self.assertFalse(is_skill_routing_disabled(self._agent()))  # absent → default-on

    def test_should_inject_recommendations_negates_is_disabled(self):
        disabled = self._agent("skill_routing: disabled")
        enabled = self._agent("skill_routing: enabled")
        absent = self._agent()
        self.assertFalse(should_inject_recommendations(disabled))
        self.assertTrue(should_inject_recommendations(enabled))
        self.assertTrue(should_inject_recommendations(absent))

    def test_should_emit_f4_log_negates_is_disabled(self):
        disabled = self._agent("skill_routing: disabled")
        enabled = self._agent("skill_routing: enabled")
        absent = self._agent()
        self.assertFalse(should_emit_f4_log(disabled))
        self.assertTrue(should_emit_f4_log(enabled))
        self.assertTrue(should_emit_f4_log(absent))

    def test_inject_and_emit_are_consistent(self):
        """inject_recommendations and emit_f4_log must always agree."""
        for field in ("skill_routing: disabled", "skill_routing: enabled", ""):
            path = self._agent(field)
            self.assertEqual(
                should_inject_recommendations(path),
                should_emit_f4_log(path),
            )


# ---------------------------------------------------------------------------
# Task 2 placeholder — documentation-agent opts out
# (runs RED until documentation-agent.md frontmatter is added in Task 2)
# ---------------------------------------------------------------------------


class TestRealAgentOptOut(unittest.TestCase):
    """Integration checks against real agent files in the repo."""

    _REPO_ROOT = Path(__file__).parent.parent.parent.parent.resolve()

    def test_documentation_agent_is_disabled(self):
        path = self._REPO_ROOT / "plugins/makato-orchestrate/agents/documentation-agent.md"
        self.assertTrue(
            path.exists(),
            f"Agent file not found: {path}",
        )
        self.assertTrue(
            is_skill_routing_disabled(path),
            "documentation-agent must have skill_routing: disabled (D21 opt-out)",
        )

    def test_context_summariser_is_disabled(self):
        path = self._REPO_ROOT / "plugins/makato-orchestrate/agents/context-summariser.md"
        self.assertTrue(
            path.exists(),
            f"Agent file not found: {path}",
        )
        self.assertTrue(
            is_skill_routing_disabled(path),
            "context-summariser must have skill_routing: disabled (D21 opt-out)",
        )


if __name__ == "__main__":
    unittest.main()
