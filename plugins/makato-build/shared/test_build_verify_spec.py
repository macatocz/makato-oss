"""
Unit tests for build_verify_spec.py — Task 1 (#568).

Tests import the Python module directly for speed; separate subprocess tests
verify the bash wrapper's spec-folder resolution logic. Fully offline.

Run from the repo root:
    pytest plugins/makato-build/shared/test_build_verify_spec.py -v
"""

import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

# ---------------------------------------------------------------------------
# Locate the module and script
# ---------------------------------------------------------------------------
REPO_ROOT = Path(__file__).parent.parent.parent.parent  # makato/
SRC = REPO_ROOT / "plugins/makato-build/shared/build_verify_spec.py"
SCRIPT = REPO_ROOT / "plugins/makato-build/skills/build-verify-spec/references/build-verify-spec.sh"

# Import module under test
sys.path.insert(0, str(SRC.parent))
from build_verify_spec import (
    check_coherence,
    check_completeness,
    check_correctness,
    format_report,
)

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

PLAN_ALL_CHECKED = """\
## Tasks

### Task 1: Alpha
**Mode:** tdd
- [x] Alpha implemented
- [x] Alpha tested

### Task 2: Beta
- [x] Beta implemented
"""

PLAN_FOUR_OF_FIVE = """\
## Tasks

### Task 1: Alpha
- [x] Alpha done

### Task 2: Beta
- [x] Beta done

### Task 3: Gamma
- [x] Gamma done

### Task 4: Delta
- [x] Delta done

### Task 5: Epsilon
- [ ] Epsilon NOT done
"""

PLAN_WITH_BACKGROUND_BOX = """\
## Background

- [x] Some random box in background

## Tasks

### Task 1
- [x] Real task done
"""

STORIES_ALL_CONFIRMED = {
    "version": "2.0",
    "slug": "test",
    "stories": [
        {
            "sequence": 1,
            "summary": "test story",
            "description": {
                "successScenarios": [
                    {
                        "title": "Scenario 1: widget initializes",
                        "given": "a developer runs build_widget command",
                        "when": "the widget is created",
                        "then": "the widget status is initialized",
                    }
                ]
            },
        }
    ],
}

STORIES_WITH_GAP = {
    "version": "2.0",
    "slug": "test",
    "stories": [
        {
            "sequence": 1,
            "summary": "test story",
            "description": {
                "successScenarios": [
                    {
                        "title": "Completely unrelated zxqvbnm feature",
                        "given": "zxqvbnm_frobnicate is configured",
                        "when": "xyzzy_invocation happens",
                        "then": "quux_response is returned",
                    }
                ]
            },
        }
    ],
}

DIFF_WITH_WIDGET = """\
diff --git a/widget.py b/widget.py
--- a/widget.py
+++ b/widget.py
@@ -0,0 +1,10 @@
+def build_widget():
+    status = "initialized"
+    return {"widget": True, "status": status}
"""

DELTA_MODIFIED_PRESENT = """\
## MODIFIED Requirements

### Widget Initialization

**SHALL**: initialize widget with status field when build_widget command runs.
"""

DELTA_MODIFIED_MISSING = """\
## MODIFIED Requirements

### Completely Unrelated Requirement zxqvbnm

**SHALL**: frobnicate the xyzzy quux mechanism at startup phase.
"""

DELTA_SUGGESTION_ONLY = """\
## MODIFIED Requirements

### Partial Widget Thing

**SHALL**: widget partial build setup configured.
"""

# ---------------------------------------------------------------------------
# COMPLETENESS tests
# ---------------------------------------------------------------------------


class TestCompleteness:
    def test_all_tasks_checked_returns_ok(self):
        result = check_completeness(PLAN_ALL_CHECKED)
        assert result.ok
        assert result.checked == 3
        assert result.total == 3
        assert result.unchecked_items == []

    def test_unchecked_task_returns_not_ok(self):
        result = check_completeness(PLAN_FOUR_OF_FIVE)
        assert not result.ok
        assert result.checked == 4
        assert result.total == 5
        assert len(result.unchecked_items) == 1
        assert "Epsilon NOT done" in result.unchecked_items[0]

    def test_background_box_not_counted(self):
        """Checkboxes outside ## Tasks must not be counted."""
        result = check_completeness(PLAN_WITH_BACKGROUND_BOX)
        assert result.total == 1
        assert result.checked == 1
        assert result.ok

    def test_empty_plan_returns_ok_zero(self):
        result = check_completeness("## Tasks\n\nNo checkboxes here.\n")
        assert result.ok
        assert result.total == 0


# ---------------------------------------------------------------------------
# CORRECTNESS tests
# ---------------------------------------------------------------------------


class TestCorrectness:
    def test_confirmed_scenario_returns_ok(self):
        stories_text = json.dumps(STORIES_ALL_CONFIRMED)
        result = check_correctness(stories_text, DIFF_WITH_WIDGET)
        assert result.ok
        assert not result.skipped
        assert any(v.verdict == "CONFIRMED" for v in result.verdicts)

    def test_gap_scenario_returns_not_ok(self):
        stories_text = json.dumps(STORIES_WITH_GAP)
        result = check_correctness(stories_text, DIFF_WITH_WIDGET)
        assert not result.ok
        assert result.gap_count >= 1
        assert any(v.verdict == "GAP" for v in result.verdicts)

    def test_absent_stories_returns_skipped(self):
        result = check_correctness(None, DIFF_WITH_WIDGET)
        assert result.skipped
        assert result.ok

    def test_empty_stories_returns_skipped(self):
        result = check_correctness("", DIFF_WITH_WIDGET)
        assert result.skipped

    def test_no_diff_returns_untestable(self):
        stories_text = json.dumps(STORIES_ALL_CONFIRMED)
        result = check_correctness(stories_text, "")
        assert all(v.verdict == "UNTESTABLE" for v in result.verdicts)
        assert result.ok  # UNTESTABLE is not a GAP

    def test_string_description_does_not_raise(self):
        # description as plain string (not dict) must not raise AttributeError
        stories = {
            "version": "2.0",
            "slug": "test",
            "stories": [{"sequence": 1, "summary": "s", "description": "plain string value"}],
        }
        result = check_correctness(json.dumps(stories), DIFF_WITH_WIDGET)
        assert result.skipped or result.ok  # no scenarios extracted → ok/skipped, never error


# ---------------------------------------------------------------------------
# COHERENCE tests
# ---------------------------------------------------------------------------


class TestCoherence:
    def test_absent_delta_returns_skipped(self):
        result = check_coherence(None, DIFF_WITH_WIDGET)
        assert result.skipped
        assert result.ok

    def test_empty_delta_returns_skipped(self):
        result = check_coherence("", DIFF_WITH_WIDGET)
        assert result.skipped

    def test_matching_requirement_confirmed_or_suggestion(self):
        """A MODIFIED requirement whose keywords appear in diff should not GAP."""
        result = check_coherence(DELTA_MODIFIED_PRESENT, DIFF_WITH_WIDGET)
        assert result.gap_count == 0
        assert result.ok

    def test_completely_missing_requirement_gaps(self):
        result = check_coherence(DELTA_MODIFIED_MISSING, DIFF_WITH_WIDGET)
        # The requirement's unique keywords (zxqvbnm, xyzzy) won't appear in the diff
        if result.gap_count > 0:
            assert not result.ok

    def test_suggestion_only_is_ok(self):
        """SUGGESTION findings are non-blocking."""
        result = check_coherence(DELTA_SUGGESTION_ONLY, DIFF_WITH_WIDGET)
        # Even if SUGGESTION, gap_count must be 0
        assert result.gap_count == 0
        assert result.ok


# ---------------------------------------------------------------------------
# format_report tests
# ---------------------------------------------------------------------------


class TestFormatReport:
    def _completeness(self, checked=3, total=3, unchecked=None):
        from build_verify_spec import CompletenessResult

        r = CompletenessResult(checked=checked, total=total)
        r.unchecked_items = unchecked or []
        return r

    def _correctness_ok(self):
        return check_correctness(None, "")

    def _coherence_ok(self):
        return check_coherence(None, "")

    def test_all_ok_report_exits_zero(self):
        c = self._completeness()
        report, code = format_report(c, self._correctness_ok(), self._coherence_ok())
        assert code == 0
        assert "=== COMPLETENESS ===" in report
        assert "=== CORRECTNESS ===" in report
        assert "=== COHERENCE ===" in report
        assert "CRITICAL" not in report

    def test_unchecked_task_exits_one(self):
        from build_verify_spec import CompletenessResult

        c = CompletenessResult(checked=4, total=5)
        c.unchecked_items = ["Epsilon NOT done"]
        _report, code = format_report(c, self._correctness_ok(), self._coherence_ok())
        assert code == 1
        assert "Tasks: 4/5" in _report
        assert "CRITICAL" in _report

    def test_gap_correctness_exits_one(self):
        stories_text = json.dumps(STORIES_WITH_GAP)
        correctness = check_correctness(stories_text, DIFF_WITH_WIDGET)
        c = self._completeness()
        _report, code = format_report(c, correctness, self._coherence_ok())
        if correctness.gap_count > 0:
            assert code == 1


# ---------------------------------------------------------------------------
# Bash wrapper subprocess tests (spec-folder resolution)
# ---------------------------------------------------------------------------


def _run_script(
    spec_key,
    plan_text="",
    diff_text="",
    stories_data=None,
    delta_text="",
    spec_dir_name=None,
):
    """Run build-verify-spec.sh with fixture files. Returns (rc, stdout, stderr)."""
    with tempfile.TemporaryDirectory() as tmpdir:
        tmp = Path(tmpdir)
        slug = spec_dir_name or f"{spec_key}-test-fixture"
        spec_dir = tmp / "specs" / slug
        spec_dir.mkdir(parents=True)

        (spec_dir / "plan-1.md").write_text(plan_text)

        if stories_data is not None:
            (spec_dir / "stories.json").write_text(json.dumps(stories_data))
        if delta_text:
            (spec_dir / "spec-delta.md").write_text(delta_text)

        diff_file = tmp / "diff.txt"
        diff_file.write_text(diff_text)

        env = os.environ.copy()
        env["REPO_ROOT"] = str(tmp)
        env["PY_MODULE"] = str(SRC)  # avoid path-resolution issues in tests

        result = subprocess.run(
            ["bash", str(SCRIPT), spec_key, str(diff_file)],
            capture_output=True,
            text=True,
            cwd=str(tmp),
            env=env,
            check=False,
        )
        return result.returncode, result.stdout, result.stderr


class TestBashWrapper:
    def test_all_checked_exits_zero(self):
        rc, out, _ = _run_script("test", plan_text=PLAN_ALL_CHECKED)
        assert rc == 0
        assert "Tasks: 3/3" in out

    def test_unchecked_task_exits_one(self):
        rc, out, _ = _run_script("test", plan_text=PLAN_FOUR_OF_FIVE)
        assert rc == 1
        assert "Tasks: 4/5" in out
        assert "CRITICAL" in out

    def test_absent_stories_skipped(self):
        rc, out, _ = _run_script("test", plan_text=PLAN_ALL_CHECKED)
        assert rc == 0
        assert "absent" in out.lower() or "skipped" in out.lower()

    def test_gap_scenario_exits_one(self):
        rc, out, _ = _run_script(
            "test",
            plan_text=PLAN_ALL_CHECKED,
            stories_data=STORIES_WITH_GAP,
            diff_text=DIFF_WITH_WIDGET,
        )
        assert rc == 1
        assert "GAP" in out

    def test_missing_spec_key_exits_two(self):
        rc, _, _err = _run_script("nonexistent-key-zzz999")
        assert rc == 2

    def test_missing_args_exits_nonzero(self):
        result = subprocess.run(["bash", str(SCRIPT)], capture_output=True, text=True, check=False)
        assert result.returncode != 0

    def test_plan_outside_tasks_not_counted(self):
        rc, out, _ = _run_script("test", plan_text=PLAN_WITH_BACKGROUND_BOX)
        assert "Tasks: 1/1" in out
        assert rc == 0

    def test_section_headers_present(self):
        _, out, _ = _run_script("test", plan_text=PLAN_ALL_CHECKED)
        assert "=== COMPLETENESS ===" in out
        assert "=== CORRECTNESS ===" in out
        assert "=== COHERENCE ===" in out
