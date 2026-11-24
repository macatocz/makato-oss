"""Workflow state and audit must agree on an issue's spec folder."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[4]
BUILD = ROOT / "plugins/makato-build"
STATE = ROOT / "plugins/makato-orchestrate/shared/workflow-state.sh"


class SpecStateResolutionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.repo = Path(self.temp.name)
        self.specs = self.repo / "other-specs"
        self.folder = self.specs / "1487-feature"
        self.folder.mkdir(parents=True)
        (self.folder / "plan-1516.md").write_text("# Story\n")
        self.env = os.environ | {
            "MAKATO_BUILD_ROOT": str(BUILD),
            "SPECS_DIR": str(self.specs),
            "MAKATO_SPECS_DIR": str(self.specs),
        }

    def run_helper(self, *args):
        return subprocess.run(args, cwd=self.repo, env=self.env, text=True, capture_output=True)

    def test_numeric_issue_state_and_audit_use_same_spec(self):
        init = self.run_helper(str(STATE), "init", "1516", "org/repo", "feat/story", "1516")
        self.assertEqual(init.returncode, 0, init.stderr)
        state = self.folder / "workflow-state-1516.json"
        self.assertEqual(json.loads(state.read_text())["issue_number"], 1516)
        self.assertFalse((self.specs / "1516").exists())
        result = self.run_helper(str(STATE), "read", "1516", "1516")
        self.assertEqual(json.loads(result.stdout)["branch"], "feat/story")
        entry = '{"skill":"build-start","story":"1516","status":"ok"}'
        result = self.run_helper(str(BUILD / "shared/build-log.sh"), "1516", entry)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads((self.folder / "build.jsonl").read_text())["story"], "1516")

    def test_ambiguous_issue_does_not_create_or_modify_state(self):
        other = self.specs / "other-feature"
        other.mkdir()
        (other / "plan-1516.md").write_text("# Other\n")
        result = self.run_helper(str(STATE), "init", "1516", "org/repo", "feat/story", "1516")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.specs / "1516").exists())
        self.assertFalse((self.folder / "workflow-state-1516.json").exists())
        self.assertFalse((other / "workflow-state-1516.json").exists())

    def test_unrelated_named_key_does_not_use_another_issues_spec(self):
        result = self.run_helper(str(STATE), "read", "unrelated", "1516")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), {})

    def test_numeric_key_cannot_select_a_different_issue(self):
        result = self.run_helper(str(STATE), "init", "1487", "org/repo", "feat/story", "1516")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.folder / "workflow-state-1516.json").exists())


if __name__ == "__main__":
    unittest.main()
