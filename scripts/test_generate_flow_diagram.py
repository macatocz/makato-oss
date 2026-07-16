"""Unit tests for generate-flow-diagram.py (#428).

Run from repo root:
    python3 -m pytest scripts/test_generate_flow_diagram.py -v
    python3 -m unittest scripts.test_generate_flow_diagram -v

The module filename contains hyphens, so it is loaded via importlib rather than a plain
import (mirrors no existing precedent — the other scripts have underscore names).

Each test builds a throwaway repo tree under a tempdir: a fake plugins/ inventory, a
data.json, an inventory.json sidecar, and a minimal makato-flow.html with a graph-data
tag — then drives detect_drift / splice_html / run directly.
"""

from __future__ import annotations

import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

_HERE = Path(__file__).parent.resolve()
_MODULE_PATH = _HERE / "generate-flow-diagram.py"

_spec = importlib.util.spec_from_file_location("generate_flow_diagram", _MODULE_PATH)
assert _spec and _spec.loader
_mod = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_mod)


def _write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def _make_skill(repo: Path, plugin: str, name: str) -> None:
    _write(
        repo / "plugins" / plugin / "skills" / name / "SKILL.md",
        f'---\nname: {name}\ndescription: test\nversion: "1.0.0"\n---\n\n# {name}\n',
    )


def _make_agent(repo: Path, plugin: str, name: str) -> None:
    _write(
        repo / "plugins" / plugin / "agents" / f"{name}.md",
        f"---\nname: {name}\nmodel: sonnet\ndescription: test\n---\n\n# {name}\n",
    )


def _html_with_blob(data: dict) -> str:
    blob = json.dumps(data, separators=(",", ":"), ensure_ascii=False)
    return (
        "<html><body>\n"
        f"{_mod.OPEN_TAG}\n{blob}\n{_mod.CLOSE_TAG}\n"
        "<script>const DATA = JSON.parse(...);</script>\n"
        "</body></html>\n"
    )


class TestGenerateFlowDiagram(unittest.TestCase):
    def setUp(self):
        self.repo = Path(tempfile.mkdtemp())
        # Baseline clean inventory: one skill + one agent on disk, each with a node.
        _make_skill(self.repo, "makato-core", "alpha")
        _make_agent(self.repo, "makato-core", "beta")
        self.data = {
            "lanes": [{"id": "l1", "label": "Lane", "color": "#000"}],
            "edgeKinds": {"flow": {"label": "F", "color": "#111"}},
            "nodes": [
                {"id": "alpha", "label": "alpha", "kind": "skill", "lane": "l1"},
                {"id": "beta", "label": "beta", "kind": "agent", "lane": "l1"},
            ],
            "edges": [{"from": "alpha", "to": "beta", "kind": "flow"}],
            "flows": {"main": {"label": "Main", "seq": ["alpha", "beta"]}},
            "statusText": {"alpha": "a", "beta": "b"},
        }
        self.inventory = {
            "nodeSources": {},
            "unmappedSkills": {},
            "unmappedAgents": {},
            "conceptualNodes": {},
        }

    def _paths(self):
        data_path = self.repo / _mod.DEFAULT_DATA
        inv_path = self.repo / _mod.DEFAULT_INVENTORY
        html_path = self.repo / _mod.DEFAULT_HTML
        _write(data_path, json.dumps(self.data, indent=2, ensure_ascii=False) + "\n")
        _write(inv_path, json.dumps(self.inventory) + "\n")
        _write(html_path, _html_with_blob(self.data))
        return html_path, data_path, inv_path

    def test_clean_check_passes(self):
        """Clean inventory + up-to-date HTML → --check exits 0."""
        html_path, data_path, inv_path = self._paths()
        rc = _mod.run(self.repo, html_path, data_path, inv_path, check=True)
        self.assertEqual(rc, 0)

    def test_missing_skill_detected(self):
        """A skill dir with no node → [missing] reported, --check exits 1."""
        _make_skill(self.repo, "makato-core", "gamma")  # on disk, no node
        html_path, data_path, inv_path = self._paths()
        findings = _mod.detect_drift(self.data, self.inventory, self.repo)
        self.assertTrue(any("[missing]" in f and "gamma" in f for f in findings))
        self.assertEqual(
            _mod.run(self.repo, html_path, data_path, inv_path, check=True), 1
        )

    def test_orphan_skill_detected(self):
        """A skill node referencing a deleted skill → [orphan] reported, exit 1."""
        self.data["nodes"].append(
            {"id": "ghost", "label": "ghost", "kind": "skill", "lane": "l1"}
        )
        html_path, data_path, inv_path = self._paths()
        findings = _mod.detect_drift(self.data, self.inventory, self.repo)
        self.assertTrue(any("[orphan]" in f and "ghost" in f for f in findings))
        self.assertEqual(
            _mod.run(self.repo, html_path, data_path, inv_path, check=True), 1
        )

    def test_stale_edge_detected(self):
        """An edge with an unknown `to` id → [stale-edge] reported, exit 1."""
        self.data["edges"].append({"from": "alpha", "to": "nowhere", "kind": "flow"})
        html_path, data_path, inv_path = self._paths()
        findings = _mod.detect_drift(self.data, self.inventory, self.repo)
        self.assertTrue(any("[stale-edge]" in f and "nowhere" in f for f in findings))
        self.assertEqual(
            _mod.run(self.repo, html_path, data_path, inv_path, check=True), 1
        )

    def test_stale_flow_seq_detected(self):
        """A flow seq id absent from nodes → [stale-edge] reported."""
        self.data["flows"]["main"]["seq"].append("ghostnode")
        findings = _mod.detect_drift(self.data, self.inventory, self.repo)
        self.assertTrue(any("[stale-edge]" in f and "ghostnode" in f for f in findings))

    def test_cluster_endpoint_accepted(self):
        """An edge from a valid `cluster:<name>` anchor is not flagged stale."""
        self.data["nodes"][0]["cluster"] = "makato-core"
        self.data["edges"].append(
            {"from": "cluster:makato-core", "to": "beta", "kind": "flow"}
        )
        findings = _mod.detect_drift(self.data, self.inventory, self.repo)
        self.assertEqual(
            [f for f in findings if "[stale-edge]" in f],
            [],
            f"cluster endpoint should be valid, got {findings}",
        )

    def test_unknown_cluster_endpoint_detected(self):
        """A `cluster:<name>` whose name no node carries → [stale-edge] with hint."""
        self.data["edges"].append(
            {"from": "cluster:nonexistent", "to": "beta", "kind": "flow"}
        )
        findings = _mod.detect_drift(self.data, self.inventory, self.repo)
        self.assertTrue(
            any(
                "[stale-edge]" in f and "cluster:nonexistent" in f and "no node" in f
                for f in findings
            ),
            f"expected stale-edge for unknown cluster, got {findings}",
        )

    def test_idempotent_splice(self):
        """Regenerating from an unchanged data file yields byte-identical HTML."""
        html_path, data_path, inv_path = self._paths()
        original = html_path.read_text(encoding="utf-8")
        rc = _mod.run(self.repo, html_path, data_path, inv_path, check=False)
        self.assertEqual(rc, 0)
        self.assertEqual(html_path.read_text(encoding="utf-8"), original)

    def test_splice_repairs_stale_html(self):
        """A stale HTML blob is repaired by default mode and then passes --check."""
        html_path, data_path, inv_path = self._paths()
        # Corrupt the committed blob.
        html_path.write_text(_html_with_blob({"stale": True}), encoding="utf-8")
        self.assertEqual(
            _mod.run(self.repo, html_path, data_path, inv_path, check=True), 1
        )
        _mod.run(self.repo, html_path, data_path, inv_path, check=False)
        self.assertEqual(
            _mod.run(self.repo, html_path, data_path, inv_path, check=True), 0
        )

    def test_composite_node_covers_multiple_skills(self):
        """A nodeSources composite node covers several disk skills without drift."""
        _make_skill(self.repo, "makato-build", "impl-tdd")
        _make_skill(self.repo, "makato-build", "impl-goal")
        self.data["nodes"].append(
            {"id": "impl", "label": "impl-tdd / goal", "kind": "skill", "lane": "l1"}
        )
        self.inventory["nodeSources"] = {"impl-tdd / goal": ["impl-tdd", "impl-goal"]}
        findings = _mod.detect_drift(self.data, self.inventory, self.repo)
        self.assertEqual(findings, [], f"expected no drift, got {findings}")

    def test_unmapped_skill_suppresses_missing(self):
        """A skill listed in unmappedSkills is not reported as missing."""
        _make_skill(self.repo, "makato-core", "hidden")
        self.inventory["unmappedSkills"] = {"hidden": "intentionally not drawn"}
        findings = _mod.detect_drift(self.data, self.inventory, self.repo)
        self.assertFalse(any("hidden" in f for f in findings))

    def test_conceptual_node_suppresses_orphan(self):
        """A skill node declared conceptual is not reported as orphan."""
        self.data["nodes"].append(
            {"id": "cn", "label": "auto-seed", "kind": "skill", "lane": "l1"}
        )
        self.inventory["conceptualNodes"] = {"auto-seed": "loop pass, not a skill dir"}
        findings = _mod.detect_drift(self.data, self.inventory, self.repo)
        self.assertFalse(any("auto-seed" in f for f in findings))


if __name__ == "__main__":
    unittest.main()
