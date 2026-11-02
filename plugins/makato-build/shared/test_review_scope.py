"""Behavioral tests for review-delta and fingerprint behavior in disposable git repositories."""

from __future__ import annotations

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
    return subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True, check=True).stdout.strip()


def _write(repo: Path, relative: str, content: str) -> None:
    target = repo / relative
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(content, encoding="utf-8")


class RepairDeltaTests(unittest.TestCase):
    """A branch with an uncommitted implementation, then a coder repair on top of it."""

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.repo = Path(self._tmp.name) / "repo"
        self.repo.mkdir()
        _run(self.repo, "init", "-q", "-b", "main")
        _run(self.repo, "config", "user.email", "t@example.invalid")
        _run(self.repo, "config", "user.name", "t")
        _write(self.repo, "src/pkg/evidence.py", "def f():\n    return 1\n")
        _write(self.repo, "README.md", "base\n")
        _run(self.repo, "add", "-A")
        _run(self.repo, "commit", "-qm", "base")
        self.base = _run(self.repo, "rev-parse", "HEAD")

        _write(self.repo, "src/pkg/evidence.py", "def f():\n    return 11\n")
        _write(self.repo, "src/pkg/freeze.py", "from pkg.evidence import f\n\n\ndef h():\n    return f()\n")
        _write(self.repo, "src/pkg/unrelated.py", "VALUE = 1\n")
        _write(self.repo, "tests/test_evidence.py", "from pkg.evidence import f\n\n\ndef test_f():\n    assert f() == 11\n")
        _write(self.repo, "tests/test_freeze.py", "from pkg.freeze import h\n\n\ndef test_h():\n    assert h() == 11\n")

    def delta(self, pre: str) -> dict:
        return review_scope.build_delta(str(self.repo), self.base, pre)

    def test_delta_is_the_coder_repair_not_the_preexisting_implementation(self) -> None:
        pre = review_scope.snapshot(str(self.repo))
        _write(self.repo, "src/pkg/evidence.py", "def f():\n    return 11  # guarded\n")

        delta = self.delta(pre)

        self.assertEqual([item["path"] for item in delta["files"]], ["src/pkg/evidence.py"])
        self.assertFalse(delta["empty"])
        self.assertEqual(delta["changed_files_total"], 5)

    def test_neighbouring_callers_and_tests_join_the_repair_scope(self) -> None:
        pre = review_scope.snapshot(str(self.repo))
        _write(self.repo, "src/pkg/evidence.py", "def f():\n    return 11  # guarded\n")

        delta = self.delta(pre)
        reasons = {item["path"]: item["reason"] for item in delta["related"]}

        self.assertEqual(reasons["tests/test_evidence.py"], "test of src/pkg/evidence.py")
        self.assertEqual(reasons["src/pkg/freeze.py"], "references src/pkg/evidence.py")
        self.assertNotIn("src/pkg/unrelated.py", delta["scope_files"])
        self.assertNotIn("tests/test_freeze.py", delta["scope_files"])
        self.assertEqual(delta["scope_files"], ["src/pkg/evidence.py", "src/pkg/freeze.py", "tests/test_evidence.py"])

    def test_snapshot_preserves_the_real_index_and_worktree(self) -> None:
        _run(self.repo, "add", "src/pkg/freeze.py")
        before_status = _run(self.repo, "status", "--porcelain=v1")
        before_index = _run(self.repo, "write-tree")

        review_scope.snapshot(str(self.repo))

        self.assertEqual(_run(self.repo, "status", "--porcelain=v1"), before_status)
        self.assertEqual(_run(self.repo, "write-tree"), before_index)

    def test_materialized_snapshot_holds_untracked_files_and_leaves_live_tree_untouched(self) -> None:
        _run(self.repo, "add", "src/pkg/freeze.py")
        before = _run(self.repo, "status", "--porcelain=v1")
        pre = review_scope.snapshot(str(self.repo))
        target = Path(self._tmp.name + "-bg")
        self.addCleanup(lambda: review_scope.release(str(self.repo), str(target)) if target.exists() else None)

        made = review_scope.materialize(str(self.repo), pre, str(target))
        _write(self.repo, "src/pkg/unrelated.py", "VALUE = 2\n")

        self.assertEqual(made["path"], str(target))
        self.assertIn("src/pkg/unrelated.py", _run(target, "diff", "--name-only", self.base).split())
        self.assertEqual((target / "src/pkg/unrelated.py").read_text(encoding="utf-8"), "VALUE = 1\n")
        self.assertEqual(_run(target, "status", "--porcelain=v1"), "")
        _write(self.repo, "src/pkg/unrelated.py", "VALUE = 1\n")
        self.assertEqual(_run(self.repo, "status", "--porcelain=v1"), before)

    def test_release_removes_materialized_checkout_and_tolerates_a_second_call(self) -> None:
        target = Path(self._tmp.name + "-bg")
        review_scope.materialize(str(self.repo), review_scope.snapshot(str(self.repo)), str(target))

        review_scope.release(str(self.repo), str(target))
        review_scope.release(str(self.repo), str(target))

        self.assertFalse(target.exists())
        self.assertNotIn(str(target), _run(self.repo, "worktree", "list"))

    def test_materialize_refuses_an_existing_target(self) -> None:
        with self.assertRaises(review_scope.ScopeError):
            review_scope.materialize(str(self.repo), review_scope.snapshot(str(self.repo)), str(self._tmp.name))

    def test_added_and_deleted_repair_files_appear_in_snapshot_delta(self) -> None:
        pre = review_scope.snapshot(str(self.repo))
        _write(self.repo, "src/pkg/guard.py", "def check():\n    return True\n")
        (self.repo / "src/pkg/unrelated.py").unlink()

        delta = self.delta(pre)

        self.assertEqual({(item["status"], item["path"]) for item in delta["files"]}, {("A", "src/pkg/guard.py"), ("D", "src/pkg/unrelated.py")})

    def test_untouched_tree_has_an_empty_delta(self) -> None:
        pre = review_scope.snapshot(str(self.repo))

        delta = self.delta(pre)

        self.assertTrue(delta["empty"])
        self.assertEqual(delta["scope_files"], [])

    def test_a_commit_between_snapshots_does_not_masquerade_as_a_repair(self) -> None:
        pre = review_scope.snapshot(str(self.repo))
        _run(self.repo, "add", "-A")
        _run(self.repo, "commit", "-qm", "commit the implementation")

        self.assertTrue(self.delta(pre)["empty"])

    def test_changed_reference_documents_join_scope_but_unrelated_docs_do_not(self) -> None:
        _write(self.repo, "scripts/claims-freeze-smoke.sh", "echo ok\n")
        _write(self.repo, "docs/inner-loop.md", "Run `scripts/claims-freeze-smoke.sh` before pushing.\n")
        _write(self.repo, "docs/other.md", "No script here.\n")
        pre = review_scope.snapshot(str(self.repo))
        _write(self.repo, "scripts/claims-freeze-smoke.sh", "echo repaired\n")

        delta = self.delta(pre)

        self.assertIn("docs/inner-loop.md", delta["scope_files"])
        self.assertNotIn("docs/other.md", delta["scope_files"])

    def test_scope_ratio_uses_the_whole_branch_change_as_denominator(self) -> None:
        pre = review_scope.snapshot(str(self.repo))
        _write(self.repo, "src/pkg/unrelated.py", "VALUE = 2\n")

        self.assertEqual(self.delta(pre)["scope_ratio"], round(1 / 5, 3))

    def test_related_file_limit_reports_truncation_and_prioritizes_test_pairs(self) -> None:
        for number in range(4):
            _write(self.repo, f"src/pkg/user{number}.py", "from pkg.evidence import f\n")
        _write(self.repo, "src/pkg/evidence.py", "def f():\n    return 12\n")

        related, truncated = review_scope.related_files(
            str(self.repo),
            ["src/pkg/evidence.py"],
            review_scope.changed_files(str(self.repo), self.base),
            max_related=3,
        )

        self.assertEqual(len(related), 3)
        self.assertTrue(truncated)
        self.assertEqual(related[0]["path"], "tests/test_evidence.py")


class FingerprintTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.repo = Path(self._tmp.name) / "repo"
        self.repo.mkdir()
        _run(self.repo, "init", "-q", "-b", "main")
        _run(self.repo, "config", "user.email", "t@example.invalid")
        _run(self.repo, "config", "user.name", "t")
        _write(self.repo, "src/pkg/evidence.py", "def f():\n    return 1\n")
        _write(self.repo, "README.md", "base\n")
        _write(self.repo, ".gitignore", "generated/\n.venv/\n")
        _run(self.repo, "add", "-A")
        _run(self.repo, "commit", "-qm", "base")
        self.base = _run(self.repo, "rev-parse", "HEAD")
        _write(self.repo, "src/pkg/evidence.py", "def f():\n    return 11\n")
        _write(self.repo, "src/pkg/freeze.py", "from pkg.evidence import f\n\n\ndef h():\n    return f()\n")

    def test_source_caller_untracked_context_and_contract_bytes_change_review_fingerprint(self) -> None:
        evidence_root = Path(self._tmp.name) / "evidence"
        _write(evidence_root, "specs/review-input.md", "The review must cover current callers.\n")
        _write(evidence_root, "contracts/return-contract.md", "R1 findings preserve each constituent.\n")
        context = ["specs/review-input.md"]
        contracts = ["contracts/return-contract.md"]

        def fingerprint() -> str:
            return str(
                review_scope.fingerprint(
                    str(self.repo),
                    self.base,
                    context_paths=context,
                    contract_paths=contracts,
                    evidence_root=str(evidence_root),
                )["sha256"]
            )

        original = fingerprint()
        source_before = (self.repo / "src/pkg/evidence.py").read_text(encoding="utf-8")
        _write(self.repo, "src/pkg/evidence.py", source_before + "# source mutation\n")
        self.assertNotEqual(fingerprint(), original)
        _write(self.repo, "src/pkg/evidence.py", source_before)
        self.assertEqual(fingerprint(), original)

        caller_before = (self.repo / "src/pkg/freeze.py").read_text(encoding="utf-8")
        _write(self.repo, "src/pkg/freeze.py", caller_before + "# caller mutation\n")
        self.assertNotEqual(fingerprint(), original)
        _write(self.repo, "src/pkg/freeze.py", caller_before)
        self.assertEqual(fingerprint(), original)

        _write(self.repo, "untracked/late-caller.py", "from pkg.evidence import f\n")
        untracked_fingerprint = fingerprint()
        self.assertNotEqual(untracked_fingerprint, original)
        self.assertIn(
            "worktree:untracked/late-caller.py",
            review_scope.fingerprint(
                str(self.repo),
                self.base,
                context_paths=context,
                contract_paths=contracts,
                evidence_root=str(evidence_root),
            )["files"],
        )
        (self.repo / "untracked/late-caller.py").unlink()
        self.assertEqual(fingerprint(), original)

        _write(evidence_root, "specs/review-input.md", "The review must cover callers and dependencies.\n")
        self.assertNotEqual(fingerprint(), original)
        _write(evidence_root, "specs/review-input.md", "The review must cover current callers.\n")
        self.assertEqual(fingerprint(), original)

        _write(evidence_root, "contracts/return-contract.md", "R1 findings preserve raw evidence and every constituent.\n")
        self.assertNotEqual(fingerprint(), original)

    def test_ignored_generated_data_does_not_pollute_fingerprint_but_explicit_plan_does(self) -> None:
        generated = self.repo / "generated"
        _write(generated, "build.jsonl", '{"event":"review"}\n')
        _write(self.repo, ".venv/cache.pyc", "generated cache\n")
        unscoped_before = review_scope.fingerprint(str(self.repo), self.base)["sha256"]
        _write(generated, "build.jsonl", '{"event":"another review"}\n')
        _write(self.repo, ".venv/cache.pyc", "new cache bytes\n")
        self.assertEqual(review_scope.fingerprint(str(self.repo), self.base)["sha256"], unscoped_before)

        _write(generated, "plan.md", "expected behavior A\n")
        explicit_before = review_scope.fingerprint(str(self.repo), self.base, context_paths=["generated/plan.md"], evidence_root=str(self.repo))["sha256"]
        _write(generated, "plan.md", "expected behavior B\n")
        explicit_after = review_scope.fingerprint(str(self.repo), self.base, context_paths=["generated/plan.md"], evidence_root=str(self.repo))["sha256"]
        self.assertNotEqual(explicit_after, explicit_before)

        _write(self.repo, "src/pkg/meaningful-untracked.py", "def caller():\n    return 1\n")
        with_untracked = review_scope.fingerprint(str(self.repo), self.base, context_paths=["generated/plan.md"], evidence_root=str(self.repo))["sha256"]
        self.assertNotEqual(with_untracked, explicit_after)

    def test_symlinked_context_and_contract_bind_target_bytes_and_reject_a_missing_target(self) -> None:
        evidence = Path(self._tmp.name) / "evidence"
        evidence.mkdir()
        link = evidence / "input.md"
        link.symlink_to("target.md")
        for source in ("context", "contract"):
            with self.subTest(source=source):
                _write(evidence, "target.md", "required invariant A\n")
                kwargs = {
                    "context_paths": ["input.md"] if source == "context" else [],
                    "contract_paths": ["input.md"] if source == "contract" else [],
                    "evidence_root": str(evidence),
                    "contract_root": str(evidence),
                }
                before = review_scope.fingerprint(str(self.repo), self.base, **kwargs)["sha256"]
                _write(evidence, "target.md", "required invariant B\n")
                self.assertNotEqual(review_scope.fingerprint(str(self.repo), self.base, **kwargs)["sha256"], before)
                (evidence / "target.md").unlink()
                with self.assertRaises(review_scope.ScopeError):
                    review_scope.fingerprint(str(self.repo), self.base, **kwargs)


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

    def test_python_name_does_not_match_a_longer_module_or_comment(self) -> None:
        self.assertFalse(self.matches("src/pkg/evidence.py", "from pkg.evidence_store import f\n"))
        self.assertFalse(self.matches("src/pkg/evidence.py", "# see evidence for details\nx = 1\n"))

    def test_generic_python_module_names_need_their_package(self) -> None:
        self.assertTrue(self.matches("src/claims/utils.py", "from claims.utils import clean\n"))
        self.assertFalse(self.matches("src/claims/utils.py", "from other.utils import clean\n"))


if __name__ == "__main__":
    unittest.main()
