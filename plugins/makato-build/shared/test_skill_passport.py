"""Unit tests for skill_passport — hierarchical passport writer (F3 / #147).

Run from repo root:
    python3 -m pytest plugins/makato-build/shared/test_skill_passport.py -v

Covers:
  - PassportNode dataclass
  - skills_invoked_transitively rollup (1-level, 3-level, 5-level)
  - write_passport creates file when absent
  - write_passport appends session node when file already exists
  - concurrent-write guard (LOCK_EX held → graceful skip, no corruption)
  - read_passport returns None when file absent
  - compute_rollup injects transitively-invoked skills into nodes
  - latency benchmark: compute_rollup on 5-level tree < 20 ms
  - integration: opt-out agents (skill_routing: disabled) do NOT write passport
"""

from __future__ import annotations

import copy
import fcntl
import json
import sys
import tempfile
import time
import unittest
from pathlib import Path

_HERE = Path(__file__).parent.resolve()
if str(_HERE) not in sys.path:
    sys.path.insert(0, str(_HERE))

from skill_passport import (  # noqa: E402
    PassportNode,
    compute_rollup,
    read_passport,
    skills_invoked_transitively,
    write_passport,
)
from skill_routing import should_emit_f4_log  # noqa: E402

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _make_node(agent: str, task: str, skills: list[str], children: list) -> PassportNode:
    return PassportNode(
        agent_name=agent,
        task_id=task,
        skills_invoked=skills,
        children=children,
    )


def _node_dict(agent: str, task: str, skills: list[str], children: list) -> dict:
    """Return a raw dict matching the JSON schema for a passport node."""
    return {
        "agent_name": agent,
        "task_id": task,
        "skills_invoked": skills,
        "children": children,
    }


# ---------------------------------------------------------------------------
# PassportNode dataclass
# ---------------------------------------------------------------------------


class TestPassportNode(unittest.TestCase):
    def test_node_fields(self):
        node = _make_node("coder", "task-1", ["makato-build:build-verify"], [])
        self.assertEqual(node.agent_name, "coder")
        self.assertEqual(node.task_id, "task-1")
        self.assertEqual(node.skills_invoked, ["makato-build:build-verify"])
        self.assertEqual(node.children, [])

    def test_ts_field_is_optional_defaults_empty(self):
        """PassportNode.ts defaults to empty string when not supplied."""
        node = PassportNode(agent_name="scout", task_id="", skills_invoked=[], children=[])
        self.assertIsInstance(node.ts, str)


# ---------------------------------------------------------------------------
# skills_invoked_transitively — rollup function
# ---------------------------------------------------------------------------


class TestSkillsInvokedTransitively(unittest.TestCase):
    def test_single_node_no_children(self):
        node = _make_node("coder", "t1", ["makato-build:build-refine"], [])
        result = skills_invoked_transitively(node)
        self.assertEqual(result, ["makato-build:build-refine"])

    def test_single_node_deduplicates(self):
        node = _make_node("coder", "t1", ["skill-a", "skill-a", "skill-b"], [])
        result = skills_invoked_transitively(node)
        self.assertEqual(sorted(result), ["skill-a", "skill-b"])

    def test_single_node_sorted(self):
        node = _make_node("coder", "t1", ["z-skill", "a-skill"], [])
        result = skills_invoked_transitively(node)
        self.assertEqual(result, ["a-skill", "z-skill"])

    def test_three_level_tree(self):
        leaf1 = _make_node("scout", "t3", ["skill-leaf1"], [])
        leaf2 = _make_node("scout", "t4", ["skill-leaf2"], [])
        mid = _make_node("coder", "t2", ["skill-mid"], [leaf1, leaf2])
        root = _make_node("po-agent", "t1", ["skill-root"], [mid])

        result = skills_invoked_transitively(root)
        self.assertEqual(
            sorted(result),
            sorted(["skill-root", "skill-mid", "skill-leaf1", "skill-leaf2"]),
        )

    def test_five_level_tree(self):
        """5-level deep tree — rollup unifies all direct skills."""
        nodes = [_make_node(f"agent-{i}", f"t{i}", [f"skill-{i}"], []) for i in range(5)]
        # build 5 levels: 4 wraps 3 wraps 2 wraps 1 wraps 0
        tree = nodes[0]
        for n in nodes[1:]:
            n.children = [tree]
            tree = n  # top is nodes[4]
        result = skills_invoked_transitively(tree)
        expected = sorted([f"skill-{i}" for i in range(5)])
        self.assertEqual(sorted(result), expected)

    def test_overlapping_skills_deduplicated(self):
        """Skills that appear in multiple nodes appear once in the rollup."""
        child = _make_node("coder", "t2", ["shared-skill", "child-only"], [])
        root = _make_node("po-agent", "t1", ["shared-skill", "root-only"], [child])
        result = skills_invoked_transitively(root)
        self.assertEqual(sorted(result), sorted(["shared-skill", "child-only", "root-only"]))


# ---------------------------------------------------------------------------
# read_passport
# ---------------------------------------------------------------------------


class TestReadPassport(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())

    def test_returns_none_when_file_absent(self):
        result = read_passport(self.tmp)
        self.assertIsNone(result)

    def test_returns_parsed_json_when_file_present(self):
        passport = {"sessions": [], "schema_version": "1"}
        (self.tmp / "skill-passport.json").write_text(json.dumps(passport))
        result = read_passport(self.tmp)
        self.assertEqual(result, passport)


# ---------------------------------------------------------------------------
# write_passport
# ---------------------------------------------------------------------------


class TestWritePassport(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())

    def test_creates_file_when_absent(self):
        node = _node_dict("coder", "t1", ["s1"], [])
        write_passport(self.tmp, node)
        passport_path = self.tmp / "skill-passport.json"
        self.assertTrue(passport_path.exists())

    def test_written_file_is_valid_json(self):
        node = _node_dict("coder", "t1", ["s1"], [])
        write_passport(self.tmp, node)
        data = json.loads((self.tmp / "skill-passport.json").read_text())
        self.assertIn("sessions", data)

    def test_appends_session_when_file_exists(self):
        """Calling write_passport twice produces two session entries."""
        node1 = _node_dict("coder", "t1", ["s1"], [])
        node2 = _node_dict("scout", "t2", ["s2"], [])
        write_passport(self.tmp, node1)
        write_passport(self.tmp, node2)
        data = json.loads((self.tmp / "skill-passport.json").read_text())
        self.assertEqual(len(data["sessions"]), 2)

    def test_session_node_contains_expected_fields(self):
        node = _node_dict("coder", "t1", ["build-refine"], [])
        write_passport(self.tmp, node)
        data = json.loads((self.tmp / "skill-passport.json").read_text())
        session = data["sessions"][0]
        self.assertEqual(session["agent_name"], "coder")
        self.assertEqual(session["task_id"], "t1")
        self.assertIn("skills_invoked", session)
        self.assertIn("ts", session)

    def test_concurrent_write_guard_graceful_skip(self):
        """When passport file is LOCK_EX-held by another process, write_passport
        skips without exception and does not corrupt the existing content."""
        # Pre-populate the file
        node_initial = _node_dict("coder", "t0", ["s0"], [])
        write_passport(self.tmp, node_initial)
        original_content = (self.tmp / "skill-passport.json").read_bytes()

        # Hold an exclusive lock as a competing process would
        passport_path = self.tmp / "skill-passport.json"
        with open(passport_path, "rb+") as lock_fd:
            fcntl.flock(lock_fd, fcntl.LOCK_EX)
            try:
                # Now attempt a concurrent write — should skip gracefully
                node_concurrent = _node_dict("interloper", "t99", ["evil-skill"], [])
                # Must NOT raise, must NOT corrupt
                write_passport(self.tmp, node_concurrent)
                # File content is unchanged
                self.assertEqual(
                    (self.tmp / "skill-passport.json").read_bytes(),
                    original_content,
                    "Concurrent write guard must not corrupt existing passport",
                )
            finally:
                fcntl.flock(lock_fd, fcntl.LOCK_UN)


# ---------------------------------------------------------------------------
# compute_rollup
# ---------------------------------------------------------------------------


class TestComputeRollup(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())

    def _passport_with_sessions(self, sessions: list) -> dict:
        return {"schema_version": "1", "sessions": sessions}

    def test_injects_transitively_at_root(self):
        child = _node_dict("scout", "t2", ["skill-child"], [])
        root = _node_dict("coder", "t1", ["skill-root"], [child])
        passport = self._passport_with_sessions([root])
        result = compute_rollup(copy.deepcopy(passport))
        enriched_root = result["sessions"][0]
        self.assertIn("skills_invoked_transitively", enriched_root)
        sit = enriched_root["skills_invoked_transitively"]
        self.assertIn("skill-root", sit)
        self.assertIn("skill-child", sit)

    def test_rollup_not_stored_in_file(self):
        """compute_rollup operates on an in-memory copy; the on-disk file is NOT modified."""
        node = _node_dict("coder", "t1", ["s1"], [])
        write_passport(self.tmp, node)
        passport = read_passport(self.tmp)
        assert passport is not None
        original_on_disk = (self.tmp / "skill-passport.json").read_bytes()
        compute_rollup(copy.deepcopy(passport))  # read-only transform
        self.assertEqual(
            (self.tmp / "skill-passport.json").read_bytes(),
            original_on_disk,
        )

    def test_leaf_node_rollup_equals_direct(self):
        leaf = _node_dict("scout", "t1", ["leaf-skill"], [])
        passport = self._passport_with_sessions([leaf])
        result = compute_rollup(copy.deepcopy(passport))
        sit = result["sessions"][0]["skills_invoked_transitively"]
        self.assertEqual(sorted(sit), ["leaf-skill"])


# ---------------------------------------------------------------------------
# Latency benchmark — compute_rollup on 5-level nested tree < 20 ms
# ---------------------------------------------------------------------------


class TestRollupLatency(unittest.TestCase):
    def test_five_level_rollup_under_20ms(self):
        """Rollup on a 5-level nested passport tree must complete in < 20 ms (NFR-R2)."""

        # Build a 5-level nested node dict (each node has one child)
        def _build_level(depth: int) -> dict:
            if depth == 0:
                return _node_dict(f"agent-{depth}", f"t{depth}", [f"skill-{depth}"], [])
            child = _build_level(depth - 1)
            return _node_dict(f"agent-{depth}", f"t{depth}", [f"skill-{depth}"], [child])

        tree = _build_level(4)  # depth 0..4 = 5 levels
        passport = {"schema_version": "1", "sessions": [tree]}

        start = time.perf_counter()
        compute_rollup(copy.deepcopy(passport))
        elapsed_ms = (time.perf_counter() - start) * 1000

        self.assertLess(
            elapsed_ms,
            20.0,
            f"compute_rollup took {elapsed_ms:.2f} ms — must be < 20 ms for advisory-only cost (NFR-R2)",
        )


# ---------------------------------------------------------------------------
# Integration: opt-out agents do NOT trigger passport writes (D21 / #147)
# ---------------------------------------------------------------------------


class TestSkillRoutingOptOutIntegration(unittest.TestCase):
    """
    The contract is: callers check `should_emit_f4_log(agent_path)` before
    calling `write_passport`. Opt-out agents (skill_routing: disabled) return
    False from that check — so write_passport is never called for them.

    This test verifies that the two real opted-out agents (documentation-agent
    and context-summariser) correctly gate a simulated passport write.
    """

    _REPO_ROOT = Path(__file__).parent.parent.parent.parent.resolve()

    def _opt_out_agents(self) -> list[Path]:
        return [
            self._REPO_ROOT / "plugins/makato-orchestrate/agents/documentation-agent.md",
            self._REPO_ROOT / "plugins/makato-orchestrate/agents/context-summariser.md",
        ]

    def test_opted_out_agents_gate_passport_write(self):
        """For each opted-out agent, should_emit_f4_log is False → passport write is skipped."""
        tmp = Path(tempfile.mkdtemp())
        for agent_path in self._opt_out_agents():
            self.assertTrue(
                agent_path.exists(),
                f"Agent file not found: {agent_path}",
            )
            emit = should_emit_f4_log(agent_path)
            self.assertFalse(
                emit,
                f"{agent_path.name} should have skill_routing: disabled",
            )
            # Simulate the caller guard: only write when should_emit_f4_log is True
            if emit:
                node = _node_dict(agent_path.stem, "task-0", ["some-skill"], [])
                write_passport(tmp, node)

        # Passport must NOT have been written (no opted-in agents in the loop)
        self.assertIsNone(
            read_passport(tmp),
            "Passport file must not exist — opt-out agents must not trigger writes",
        )


if __name__ == "__main__":
    unittest.main()
