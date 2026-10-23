"""Behavioral tests for repair-delta review scoping against real throwaway git repositories."""

from __future__ import annotations

import itertools
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

_HERE = Path(__file__).resolve().parent
if str(_HERE) not in sys.path:
    sys.path.insert(0, str(_HERE))

import review_scope  # noqa: E402


def _run(repo: Path, *args: str) -> str:
    return subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True, check=True).stdout


def _write(repo: Path, relative: str, content: str) -> None:
    target = repo / relative
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(content, encoding="utf-8")


class RepairDeltaTests(unittest.TestCase):
    """A branch with an uncommitted implementation, then a coder repair on top of it."""

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.repo = Path(self._tmp.name)
        _run(self.repo, "init", "-q", "-b", "main")
        _run(self.repo, "config", "user.email", "t@example.invalid")
        _run(self.repo, "config", "user.name", "t")
        _write(self.repo, "src/pkg/evidence.py", "def f():\n    return 1\n")
        _write(self.repo, "README.md", "base\n")
        _run(self.repo, "add", "-A")
        _run(self.repo, "commit", "-qm", "base")
        self.base = _run(self.repo, "rev-parse", "HEAD").strip()

        _write(self.repo, "src/pkg/evidence.py", "def f():\n    return 11\n")
        _write(self.repo, "src/pkg/freeze.py", "from pkg.evidence import f\n\n\ndef h():\n    return f()\n")
        _write(self.repo, "src/pkg/unrelated.py", "VALUE = 1\n")
        _write(self.repo, "tests/test_evidence.py", "from pkg.evidence import f\n\n\ndef test_f():\n    assert f() == 11\n")
        _write(self.repo, "tests/test_freeze.py", "from pkg.freeze import h\n\n\ndef test_h():\n    assert h() == 11\n")

    def delta(self, pre: str) -> dict:
        return review_scope.build_delta(str(self.repo), self.base, pre)

    def test_delta_is_the_repair_not_the_implementation(self) -> None:
        pre = review_scope.snapshot(str(self.repo))
        _write(self.repo, "src/pkg/evidence.py", "def f():\n    return 11  # guarded\n")

        delta = self.delta(pre)

        self.assertEqual([item["path"] for item in delta["files"]], ["src/pkg/evidence.py"])
        self.assertFalse(delta["empty"])
        self.assertEqual(delta["changed_files_total"], 5)

    def test_neighbours_that_import_or_test_the_repaired_file_join_the_scope(self) -> None:
        pre = review_scope.snapshot(str(self.repo))
        _write(self.repo, "src/pkg/evidence.py", "def f():\n    return 11  # guarded\n")

        delta = self.delta(pre)
        reasons = {item["path"]: item["reason"] for item in delta["related"]}

        self.assertEqual(reasons["tests/test_evidence.py"], "test of src/pkg/evidence.py")
        self.assertEqual(reasons["src/pkg/freeze.py"], "references src/pkg/evidence.py")
        self.assertNotIn("src/pkg/unrelated.py", delta["scope_files"])
        self.assertNotIn("tests/test_freeze.py", delta["scope_files"])
        self.assertEqual(delta["scope_files"], ["src/pkg/evidence.py", "src/pkg/freeze.py", "tests/test_evidence.py"])

    def test_snapshotting_leaves_index_and_worktree_untouched(self) -> None:
        _run(self.repo, "add", "src/pkg/freeze.py")
        before = _run(self.repo, "status", "--porcelain=v1")

        review_scope.snapshot(str(self.repo))

        self.assertEqual(_run(self.repo, "status", "--porcelain=v1"), before)

    def test_repair_that_adds_or_deletes_files_is_in_the_delta(self) -> None:
        pre = review_scope.snapshot(str(self.repo))
        _write(self.repo, "src/pkg/guard.py", "def check():\n    return True\n")
        (self.repo / "src/pkg/unrelated.py").unlink()

        delta = self.delta(pre)

        self.assertEqual({(item["status"], item["path"]) for item in delta["files"]}, {("A", "src/pkg/guard.py"), ("D", "src/pkg/unrelated.py")})

    def test_untouched_tree_gives_an_empty_delta(self) -> None:
        pre = review_scope.snapshot(str(self.repo))

        delta = self.delta(pre)

        self.assertTrue(delta["empty"])
        self.assertEqual(delta["scope_files"], [])

    def test_a_commit_between_snapshots_does_not_masquerade_as_a_repair(self) -> None:
        pre = review_scope.snapshot(str(self.repo))
        _run(self.repo, "add", "-A")
        _run(self.repo, "commit", "-qm", "commit the implementation")

        self.assertTrue(self.delta(pre)["empty"])

    def test_documents_that_mention_a_repaired_script_are_neighbours(self) -> None:
        _write(self.repo, "scripts/claims-freeze-smoke.sh", "echo ok\n")
        _write(self.repo, "docs/inner-loop.md", "Run `scripts/claims-freeze-smoke.sh` before pushing.\n")
        _write(self.repo, "docs/other.md", "No script here.\n")
        pre = review_scope.snapshot(str(self.repo))
        _write(self.repo, "scripts/claims-freeze-smoke.sh", "echo repaired\n")

        delta = self.delta(pre)

        self.assertIn("docs/inner-loop.md", delta["scope_files"])
        self.assertNotIn("docs/other.md", delta["scope_files"])

    def test_scope_ratio_is_the_share_of_the_whole_change(self) -> None:
        pre = review_scope.snapshot(str(self.repo))
        _write(self.repo, "src/pkg/unrelated.py", "VALUE = 2\n")

        self.assertEqual(self.delta(pre)["scope_ratio"], round(1 / 5, 3))

    def test_related_list_is_capped_and_reports_truncation(self) -> None:
        for number in range(4):
            _write(self.repo, f"src/pkg/user{number}.py", "from pkg.evidence import f\n")
        _write(self.repo, "src/pkg/evidence.py", "def f():\n    return 12\n")
        _write(self.repo, "src/pkg/evidence.py", "def f():\n    return 12\n")

        related, truncated = review_scope.related_files(str(self.repo), ["src/pkg/evidence.py"], review_scope.changed_files(str(self.repo), self.base), max_related=3)

        self.assertEqual(len(related), 3)
        self.assertTrue(truncated)
        self.assertEqual(related[0]["path"], "tests/test_evidence.py", "test pairs outrank plain references")
        self.assertEqual(len(related), 3)


class ReferencePatternTests(unittest.TestCase):
    def matches(self, path: str, text: str) -> bool:
        return review_scope._reference_pattern(path).search(text) is not None

    def test_typescript_import_and_mock_specifiers(self) -> None:
        self.assertTrue(self.matches("frontend/src/api/claimsApi.ts", "import { load } from './claimsApi';\n"))
        self.assertTrue(self.matches("frontend/src/api/claimsApi.ts", "vi.mock('../api/claimsApi')\n"))
        self.assertTrue(self.matches("frontend/src/api/claimsApi.ts", 'const m = await import("@/api/claimsApi.ts");\n'))

    def test_typescript_names_do_not_match_longer_identifiers(self) -> None:
        self.assertFalse(self.matches("frontend/src/api/claimsApi.ts", "import { x } from './claimsApiClient';\n"))

    def test_index_file_is_matched_through_its_directory(self) -> None:
        self.assertTrue(self.matches("frontend/src/claims/index.ts", "import { x } from '../claims';\n"))

    def test_python_import_forms(self) -> None:
        self.assertTrue(self.matches("src/pkg/evidence.py", "from pkg.evidence import f\n"))
        self.assertTrue(self.matches("src/pkg/evidence.py", "from pkg import evidence\n"))
        self.assertTrue(self.matches("src/pkg/evidence.py", "import pkg.evidence as ev\n"))

    def test_python_name_does_not_match_a_longer_module_or_a_comment(self) -> None:
        self.assertFalse(self.matches("src/pkg/evidence.py", "from pkg.evidence_store import f\n"))
        self.assertFalse(self.matches("src/pkg/evidence.py", "# see evidence for details\nx = 1\n"))

    def test_generic_python_module_names_need_their_package(self) -> None:
        self.assertTrue(self.matches("src/claims/utils.py", "from claims.utils import clean\n"))
        self.assertFalse(self.matches("src/claims/utils.py", "from other.utils import clean\n"))


class DecideTests(unittest.TestCase):
    def decide(self, event: str, last_scope: str = "none", full_since_repair: bool = False, repair_rounds: int = 0, scope_ratio: float | None = None, mode: str = "delta") -> dict:
        return review_scope.decide(event, mode, last_scope, full_since_repair, repair_rounds, scope_ratio)

    def run_loop(self, reviews: list[bool], scope_ratio: float = 0.2, mode: str = "delta") -> tuple[list[str], bool]:
        """Run the caller loop: ``reviews[i]`` is whether review i comes back clean. Returns (scopes reviewed, accepted)."""
        scopes: list[str] = []
        state = self.decide("start", mode=mode)
        repair_rounds = 0
        for clean in reviews:
            scopes.append(str(state["next"]))
            full_since_repair = bool(state["full_since_repair"])
            if clean:
                state = self.decide("clean", last_scope=scopes[-1], full_since_repair=full_since_repair, repair_rounds=repair_rounds, mode=mode)
                if state["next"] == "done":
                    return scopes, True
            else:
                repair_rounds += 1
                state = self.decide("repaired", last_scope=scopes[-1], full_since_repair=full_since_repair, repair_rounds=repair_rounds, scope_ratio=scope_ratio, mode=mode)
        return scopes, False

    def drive(self, reviews: list[bool], scope_ratio: float = 0.2, mode: str = "delta") -> list[str]:
        return self.run_loop(reviews, scope_ratio, mode)[0]

    def test_first_pass_is_always_full(self) -> None:
        self.assertEqual(self.decide("start")["next"], "full")

    def test_a_clean_first_pass_needs_nothing_more(self) -> None:
        self.assertEqual(self.drive([True]), ["full"])

    def test_repairs_are_delta_reviewed_then_certified_by_one_full_pass(self) -> None:
        self.assertEqual(self.drive([False, False, True, True]), ["full", "delta", "delta", "final-full"])

    def test_clean_delta_directly_after_the_first_repair_still_requires_the_full_pass(self) -> None:
        self.assertEqual(self.drive([False, True, True]), ["full", "delta", "final-full"])

    def test_findings_from_the_certifying_pass_are_repaired_and_delta_reviewed_only(self) -> None:
        self.assertEqual(self.drive([False, True, False, True]), ["full", "delta", "final-full", "delta"])

    def test_wide_repairs_fall_back_to_a_full_pass_which_then_certifies(self) -> None:
        self.assertEqual(self.drive([False, True], scope_ratio=0.75), ["full", "full"])

    def test_legacy_full_mode_reviews_everything_every_time(self) -> None:
        self.assertEqual(self.drive([False, False, True], mode="full"), ["full", "full", "full"])

    def test_a_repaired_tree_is_never_accepted_without_a_full_pass_after_the_first_repair(self) -> None:
        for length in range(1, 9):
            for outcomes in itertools.product([True, False], repeat=length):
                scopes, accepted = self.run_loop(list(outcomes))
                if accepted and len(scopes) > 1:
                    self.assertTrue(any(scope in ("full", "final-full") for scope in scopes[1:]), f"accepted {scopes} for outcomes {outcomes}")

    def test_mechanical_changes_get_a_delta_review(self) -> None:
        self.assertEqual(self.decide("mechanical", last_scope="full", full_since_repair=True, repair_rounds=2)["next"], "delta")

    def test_mechanical_change_after_a_clean_first_pass_needs_no_final_full_pass(self) -> None:
        self.assertEqual(self.decide("clean", last_scope="delta", full_since_repair=False, repair_rounds=0)["next"], "done")

    def test_impossible_event_for_the_state_is_an_error(self) -> None:
        with self.assertRaises(review_scope.ScopeError):
            self.decide("clean", last_scope="none")


class ModeResolutionTests(unittest.TestCase):
    def test_default_is_delta(self) -> None:
        self.assertEqual(review_scope.resolve_mode(None), ("delta", None))
        self.assertEqual(review_scope.resolve_mode("  "), ("delta", None))

    def test_full_is_honoured_case_insensitively(self) -> None:
        self.assertEqual(review_scope.resolve_mode("FULL"), ("full", None))

    def test_invalid_value_falls_back_to_delta_with_a_warning(self) -> None:
        mode, warning = review_scope.resolve_mode("everything")
        self.assertEqual(mode, "delta")
        self.assertIn("MAKATO_REVIEW_SCOPE", warning or "")


if __name__ == "__main__":
    unittest.main()
