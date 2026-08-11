"""Unit tests for stale-artifact-check hook output parsing in parse-sarif.py.

Task 3: Extend parse-sarif.py to recognise stale-artifact-check hook output.
Satisfies: AC-1, AC-4

parse-sarif.py has a hyphenated filename so cannot be imported directly.
We load it via importlib and register it in sys.modules so @dataclass resolves.

Hook output format emitted by stale-artifact-check.sh:
    stale-artifact check (debug leftovers).....Failed
    src/index.js:3: [stale-artifact/console-log] console.log( found in addition

The bracket-wrapped [tool/rule] form is extracted into Finding.rule as the bare
rule name (console-log), not the full bracket string or the prefixed form.
AUTOFIXABLE_RULES for stale-artifact uses bare rule patterns (^console-log$, etc.)
to match the extracted rule.
"""

import importlib.util
import os
import sys
import unittest

# parse-sarif.py has a hyphenated filename — use importlib to load it directly.
# Register in sys.modules before exec_module so @dataclass can resolve __module__.
_SHARED_DIR = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location(
    "parse_sarif",
    os.path.join(_SHARED_DIR, "parse-sarif.py"),
)
assert _spec is not None
assert _spec.loader is not None
_mod = importlib.util.module_from_spec(_spec)
sys.modules["parse_sarif"] = _mod
_spec.loader.exec_module(_mod)

parse_pre_commit = _mod.parse_pre_commit_output
_is_autofixable = _mod._is_autofixable


class TestStaleArtifactLabelMapping(unittest.TestCase):
    """Test that the stale-artifact-check hook header maps to tool 'stale-artifact'."""

    def test_label_maps_to_stale_artifact(self):
        """parse_pre_commit maps 'stale-artifact check (debug leftovers)' hook header
        to tool='stale-artifact' and extracts the bare rule name from [tool/rule] brackets.

        Scenario 1 (maps to AC-1): stale-artifact sensor flags console.log in staged diff.
        """
        pre_commit_output = "stale-artifact check (debug leftovers).....Failed\nsrc/index.js:3: [stale-artifact/console-log] console.log( found in addition\n"
        findings = parse_pre_commit(pre_commit_output)
        self.assertEqual(len(findings), 1, f"Expected 1 finding, got {len(findings)}: {findings}")
        f = findings[0]
        self.assertEqual(f.tool, "stale-artifact")
        self.assertEqual(f.rule, "console-log")
        self.assertEqual(f.path, "src/index.js")
        self.assertEqual(f.line, 3)

    def test_clean_output_produces_no_findings(self):
        """A pre-commit run where stale-artifact-check passes produces an empty findings list.

        Scenario 4 (maps to AC-4): clean diffs produce no findings.
        """
        pre_commit_output = "stale-artifact check (debug leftovers).....Passed\n"
        findings = parse_pre_commit(pre_commit_output)
        self.assertEqual(findings, [])

    def test_autofix_available_true_for_console_log(self):
        """_is_autofixable returns True for ('stale-artifact', 'console-log').

        AUTOFIXABLE_RULES for stale-artifact must use bare rule patterns so the
        extracted rule 'console-log' matches.
        """
        self.assertTrue(
            _is_autofixable("stale-artifact", "console-log"),
            "Expected _is_autofixable('stale-artifact', 'console-log') to be True",
        )


if __name__ == "__main__":
    unittest.main()
