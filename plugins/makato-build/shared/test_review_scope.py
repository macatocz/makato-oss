"""Behavioral tests for review-delta and fingerprint behavior in disposable git repositories."""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

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

    def test_snapshot_preserves_file_directory_replacements_and_the_real_index(self) -> None:
        for direction in ("file-to-directory", "directory-to-file"):
            with self.subTest(direction=direction):
                repo = Path(self._tmp.name) / direction
                repo.mkdir()
                _run(repo, "init", "-q")
                _run(repo, "config", "user.email", "t@example.invalid")
                _run(repo, "config", "user.name", "t")
                old = "entry" if direction == "file-to-directory" else "entry/child.txt"
                new = "entry/child.txt" if direction == "file-to-directory" else "entry"
                _write(repo, old, "before\n")
                _run(repo, "add", ".")
                _run(repo, "commit", "-qm", "base")
                (repo / old).unlink()
                if direction == "directory-to-file":
                    (repo / "entry").rmdir()
                _write(repo, new, "after\n")
                index = (repo / ".git/index").read_bytes()

                tree = review_scope.snapshot(str(repo))

                self.assertEqual(_run(repo, "ls-tree", "-r", "--name-only", tree), new)
                self.assertEqual(_run(repo, "show", f"{tree}:{new}"), "after")
                self.assertEqual((repo / ".git/index").read_bytes(), index)
                self.assertEqual((repo / new).read_bytes(), b"after\n")

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

    def test_snapshots_preserve_raw_text_and_clean_filtered_blobs(self) -> None:
        _write(self.repo, ".gitattributes", "*.txt text\n*.eol text eol=crlf\n*.filtered filter=upper\n")
        _run(self.repo, "config", "filter.upper.clean", "tr '[:lower:]' '[:upper:]'")
        _run(self.repo, "config", "filter.upper.smudge", "cat")
        raw = {"notes.txt": b"first\r\nsecond\r\n", "notes.eol": b"first\r\nsecond\r\n", "notes.filtered": b"raw lower case\n"}
        for path, content in raw.items():
            (self.repo / path).write_bytes(content)
        index = _run(self.repo, "write-tree")
        tree = review_scope.snapshot(str(self.repo))
        for path, content in raw.items():
            with self.subTest(path=path):
                actual = subprocess.run(["git", "-C", str(self.repo), "show", f"{tree}:{path}"], capture_output=True, check=True).stdout
                self.assertEqual(actual, content)
                self.assertEqual((self.repo / path).read_bytes(), content)
        self.assertEqual(_run(self.repo, "write-tree"), index)
        scope = review_scope.checkpoint_scope(str(self.repo), review_scope.fingerprint(str(self.repo), self.base)["manifest"], tree)
        self.assertTrue(set(raw).issubset(scope["scope_files"]))

    def test_raw_mutation_with_the_same_clean_blob_rejects_a_stale_checkpoint_snapshot(self) -> None:
        _write(self.repo, ".gitattributes", "*.txt text\n")
        notes = self.repo / "notes.txt"
        notes.write_bytes(b"first\r\nsecond\r\n")
        manifest = review_scope.fingerprint(str(self.repo), self.base)["manifest"]
        notes.write_bytes(b"first\nsecond\n")
        tree = review_scope.snapshot(str(self.repo))
        with self.assertRaisesRegex(review_scope.ScopeError, "snapshot bytes"):
            review_scope.checkpoint_scope(str(self.repo), manifest, tree)

    def test_raw_snapshot_consumers_preserve_committed_and_dirty_transforms(self) -> None:
        _write(self.repo, ".gitattributes", "*.txt filter=prefix\n*.eol text eol=crlf\n*.enc working-tree-encoding=UTF-16LE\n")
        _run(self.repo, "config", "filter.prefix.clean", "sed 's/^P://' ")
        _run(self.repo, "config", "filter.prefix.smudge", "sed 's/^/P:/'")
        raw = {"committed.txt": b"P:committed\n", "committed.eol": b"committed\r\n", "committed.enc": "committed\n".encode("utf-16le")}
        for path, content in raw.items():
            (self.repo / path).write_bytes(content)
        _run(self.repo, "add", ".")
        _run(self.repo, "commit", "-qm", "normalized branch files")
        (self.repo / "dirty.txt").write_bytes(b"P:dirty\n")
        (self.repo / "executable").write_bytes(b"#!/bin/sh\nexit 0\n")
        (self.repo / "executable").chmod(0o755)
        (self.repo / "link").symlink_to("committed.txt")
        raw.update({"dirty.txt": b"P:dirty\n", "executable": b"#!/bin/sh\nexit 0\n"})
        index = (self.repo / ".git/index").read_bytes()
        tree = review_scope.snapshot(str(self.repo))
        cli = subprocess.run([sys.executable, str(_HERE / "review_scope.py"), "snapshot", "--worktree", str(self.repo)], capture_output=True, text=True, check=True)
        self.assertEqual(json.loads(cli.stdout)["snapshot"], tree)
        self.assertTrue(review_scope.build_delta(str(self.repo), self.base, tree)["empty"])
        target = Path(self._tmp.name) / "raw-consumer"
        self.addCleanup(lambda: review_scope.release(str(self.repo), str(target)) if target.exists() else None)
        review_scope.materialize(str(self.repo), tree, str(target))
        expected_paths = set(_run(self.repo, "ls-tree", "-r", "--name-only", tree).splitlines())
        actual_paths = {p.relative_to(target).as_posix() for p in target.rglob("*") if not p.is_dir() and p.name != ".git"}
        self.assertEqual(actual_paths, expected_paths)
        for path, content in raw.items():
            with self.subTest(path=path):
                blob = subprocess.run(["git", "-C", str(self.repo), "show", f"{tree}:{path}"], capture_output=True, check=True).stdout
                self.assertEqual(blob, content)
                self.assertEqual((target / path).read_bytes(), content)
        self.assertEqual(os.readlink(target / "link"), "committed.txt")
        self.assertEqual((target / "executable").stat().st_mode & 0o777, 0o755)
        self.assertEqual((self.repo / ".git/index").read_bytes(), index)
        # Later source edits cannot change the immutable review consumer.
        (self.repo / "committed.txt").write_bytes(b"P:new\n")
        self.assertEqual((target / "committed.txt").read_bytes(), raw["committed.txt"])

    def test_snapshot_rejects_tracked_paths_through_symlink_directories(self) -> None:
        outside = Path(self._tmp.name) / "outside"
        outside.mkdir()
        (outside / "evidence.py").write_text("foreign\n")
        shutil.rmtree(self.repo / "src/pkg")
        (self.repo / "src/pkg").symlink_to(outside, target_is_directory=True)
        with self.assertRaises(review_scope.ScopeError):
            review_scope.snapshot(str(self.repo))

    def test_raw_complete_tree_includes_staged_deletions_and_normalized_baseline(self) -> None:
        _write(self.repo, ".gitattributes", "*.eol text eol=crlf\n")
        (self.repo / "baseline.eol").write_bytes(b"baseline\r\n")
        _run(self.repo, "add", ".")
        _run(self.repo, "commit", "-qm", "normalized baseline")
        base = _run(self.repo, "rev-parse", "HEAD")
        _run(self.repo, "rm", "README.md")
        (self.repo / "new.py").write_text("VALUE = 2\n")
        index = (self.repo / ".git/index").read_bytes()
        tree = review_scope.snapshot(str(self.repo))
        paths = _run(self.repo, "ls-tree", "-r", "--name-only", tree).splitlines()
        self.assertNotIn("README.md", paths)
        scope = review_scope.checkpoint_scope(str(self.repo), review_scope.fingerprint(str(self.repo), base)["manifest"], tree)
        self.assertTrue({"README.md", "new.py", "baseline.eol"}.issubset(scope["scope_files"]))
        (self.repo / "baseline.eol").write_bytes(b"baseline\n")
        with self.assertRaises(review_scope.ScopeError):
            review_scope.checkpoint_scope(str(self.repo), review_scope.fingerprint(str(self.repo), base)["manifest"], tree)
        self.assertEqual((self.repo / ".git/index").read_bytes(), index)

    def test_checkpoint_scope_binds_external_constraints_and_invalidates_prior_source(self) -> None:
        contracts = self.repo.parent / "contracts"
        contracts.mkdir()
        (contracts / "policy.md").write_text("Initial policy\n")
        contexts = self.repo.parent / "contexts"
        contexts.mkdir()
        (contexts / "requirements.md").write_text("Initial requirements\n")

        def manifest() -> dict:
            return review_scope.fingerprint(
                str(self.repo),
                self.base,
                context_paths=["requirements.md"],
                contract_paths=["policy.md"],
                evidence_root=str(contexts),
                contract_root=str(contracts),
            )["manifest"]

        first_manifest = manifest()
        first_tree = review_scope.snapshot(str(self.repo))
        first = review_scope.checkpoint_scope(str(self.repo), first_manifest, first_tree)
        self.assertIn("context:requirements.md", first["scope_files"])
        self.assertIn("contract:policy.md", first["scope_files"])
        previous = {"manifest": first_manifest, "checkpoint_receipt": {"snapshot": first_tree}}
        (contracts / "policy.md").write_text("Changed policy\n")
        scoped = review_scope.checkpoint_scope(str(self.repo), manifest(), first_tree, previous=previous)
        self.assertTrue(set(first_manifest["changed_files"]).issubset(scoped["scope_files"]))
        self.assertEqual(scoped["pre_snapshot"], first_tree)

    def test_checkpoint_scope_preserves_deleted_caller_dependencies_and_invariant_sites(self) -> None:
        before = review_scope.snapshot(str(self.repo))
        previous = {
            "manifest": review_scope.fingerprint(str(self.repo), self.base)["manifest"],
            "checkpoint_receipt": {"snapshot": before},
        }
        (self.repo / "src/pkg/freeze.py").unlink()
        post = review_scope.snapshot(str(self.repo))
        manifest = review_scope.fingerprint(str(self.repo), self.base)["manifest"]
        scope = review_scope.checkpoint_scope(str(self.repo), manifest, post, previous=previous, invariant_paths=["README.md"])
        self.assertTrue({"src/pkg/freeze.py", "src/pkg/evidence.py", "tests/test_freeze.py", "README.md"}.issubset(scope["scope_files"]))

    def test_checkpoint_scope_rejects_partial_snapshot_wrong_bytes_and_wrong_kind(self) -> None:
        before = review_scope.snapshot(str(self.repo))
        _write(self.repo, "src/pkg/unrelated.py", "VALUE = 99\n")
        manifest = review_scope.fingerprint(str(self.repo), self.base)["manifest"]
        with self.assertRaisesRegex(review_scope.ScopeError, "snapshot bytes"):
            review_scope.checkpoint_scope(str(self.repo), manifest, before)
        (self.repo / "new.py").write_text("NEW = 1\n")
        manifest = review_scope.fingerprint(str(self.repo), self.base)["manifest"]
        with self.assertRaisesRegex(review_scope.ScopeError, "source manifest"):
            review_scope.checkpoint_scope(str(self.repo), manifest, before)
        tree = review_scope.snapshot(str(self.repo))
        (self.repo / "new.py").unlink()
        (self.repo / "new.py").symlink_to("src/pkg/evidence.py")
        manifest = review_scope.fingerprint(str(self.repo), self.base)["manifest"]
        with self.assertRaisesRegex(review_scope.ScopeError, "kind or mode"):
            review_scope.checkpoint_scope(str(self.repo), manifest, tree)


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

    def test_git_clean_baseline_mutations_change_fingerprint_and_review_scope(self) -> None:
        _write(self.repo, ".gitattributes", "README.md filter=uppercase\n")
        _run(self.repo, "config", "filter.uppercase.clean", "tr '[:lower:]' '[:upper:]'")
        _write(self.repo, "README.md", "BASE\n")
        _run(self.repo, "add", "-A")
        _run(self.repo, "commit", "-qm", "filtered baseline")
        base = _run(self.repo, "rev-parse", "HEAD")
        original = review_scope.fingerprint(str(self.repo), base)

        _write(self.repo, "README.md", "base\n")

        self.assertEqual(_run(self.repo, "diff", "--name-only", base), "")
        mutated = review_scope.fingerprint(str(self.repo), base)
        self.assertNotEqual(mutated["sha256"], original["sha256"])
        self.assertIn("README.md", mutated["manifest"]["changed_files"])
        self.assertIn("README.md", review_scope.changed_files(str(self.repo), base))
        _write(self.repo, "README.md", "BASE\n")
        self.assertEqual(review_scope.fingerprint(str(self.repo), base), original)

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


class ActiveRootTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.directory = Path(self.tmp.name)
        self.build = self.directory / "installed/build"
        self.orch = self.directory / "independent/orchestrate"
        for source, target in ((_HERE.parent, self.build), (_HERE.parents[1] / "makato-orchestrate", self.orch)):
            shutil.copytree(source, target, ignore=shutil.ignore_patterns("__pycache__", "*.pyc"))

    def inventory(self) -> list[dict]:
        return review_scope.contract_inventory(self.build, orchestrate_root=self.orch)

    def source_suite(self) -> Path:
        suite = self.directory / "suite"
        self.build = suite / "plugins/makato-build"
        self.orch = suite / "plugins/makato-orchestrate"
        shutil.copytree(_HERE.parent, self.build, ignore=shutil.ignore_patterns("__pycache__", "*.pyc"))
        shutil.copytree(_HERE.parents[1] / "makato-orchestrate", self.orch, ignore=shutil.ignore_patterns("__pycache__", "*.pyc"))
        _write(
            suite,
            ".claude-plugin/marketplace.json",
            json.dumps(
                {
                    "name": "makato-suite",
                    "plugins": [{"name": name, "source": f"./plugins/{name}"} for name in ("makato-build", "makato-orchestrate")],
                }
            ),
        )
        _run(suite, "init", "-q", "-b", "main")
        _run(suite, "config", "user.email", "scope@example.invalid")
        _run(suite, "config", "user.name", "scope")
        _run(suite, "add", "-A")
        _run(suite, "commit", "-qm", "suite proof")
        return suite

    def test_contract_grammar_rejects_traversal_unknown_namespaces_and_skill_alias(self) -> None:
        for value in (
            "",
            "/shared/x",
            "a//b",
            "a/",
            "./a",
            "a/../b",
            r"a\b",
            "build:x",
            "contract:x",
            "x:y",
            "orchestrate:",
            "orchestrate:/x",
            "orchestrate:a:b",
            "orchestrate:./x",
            "skills/build-review/shared/review_loop.py",
        ):
            with self.subTest(value=value), self.assertRaises(review_scope.ScopeError):
                review_scope.contract_input(value, self.build, self.orch)
        with self.assertRaises(review_scope.ScopeError):
            review_scope.contract_input("orchestrate:shared/progress-comment.sh", self.build)
        self.assertEqual(review_scope.contract_input("shared/review_loop.py", self.build), ("contract", "shared/review_loop.py", self.build))
        self.assertEqual(review_scope.contract_input("orchestrate:scripts/task_schedule.py", self.build, self.orch), ("orchestrate", "scripts/task_schedule.py", self.orch))

    def test_inventory_covers_actual_helpers_and_tracks_content_kind_and_permissions_not_location(self) -> None:
        before = self.inventory()
        self.assertEqual([row["path"] for row in before], [path if path.startswith("orchestrate:") else "contract:" + path for path in review_scope.REVIEW_CONTRACT_PATHS])
        for argument in ("shared/build-log.sh", "shared/default-branch.sh", "orchestrate:shared/progress-comment.sh", "orchestrate:scripts/task_schedule.py"):
            source, relative, selected = review_scope.contract_input(argument, self.build, self.orch)
            target = selected / relative
            saved = target.read_bytes()
            target.write_bytes(saved + b"\n# mutation\n")
            changed = self.inventory()
            label = f"{source}:{relative}"
            self.assertNotEqual(next(row for row in before if row["path"] == label)["sha256"], next(row for row in changed if row["path"] == label)["sha256"])
            target.write_bytes(saved)
        relocated = self.directory / "relocated"
        shutil.copytree(self.build, relocated / "build")
        shutil.copytree(self.orch, relocated / "orchestrate")
        self.assertEqual(before, review_scope.contract_inventory(relocated / "build", orchestrate_root=relocated / "orchestrate"))
        self.assertNotEqual(review_scope.root_bindings(self.build, self.orch), review_scope.root_bindings(relocated / "build", relocated / "orchestrate"))
        helper = self.orch / "shared/progress-comment.sh"
        helper.chmod(helper.stat().st_mode ^ 0o100)
        changed = self.inventory()
        self.assertNotEqual(changed, before)
        self.assertEqual([row["sha256"] for row in changed], [row["sha256"] for row in before])
        self.assertTrue(all(row["kind"] == "file" and isinstance(row["mode"], int) for row in before))

    def test_required_contracts_reject_symlinks_but_canonicalize_root_ancestors(self) -> None:
        alias = self.directory / "ancestor"
        alias.symlink_to(self.build.parent, target_is_directory=True)
        self.assertEqual(self.inventory(), review_scope.contract_inventory(alias / self.build.name, orchestrate_root=self.orch))
        for selected, relative in ((self.build, "shared/review_loop.py"), (self.orch, "shared/progress-comment.sh")):
            with self.subTest(root=selected):
                target = selected / relative
                saved = target.with_suffix(".saved")
                target.rename(saved)
                target.symlink_to(saved.name)
                with self.assertRaisesRegex(review_scope.ScopeError, "symlink"):
                    self.inventory()
                target.unlink()
                saved.rename(target)
        shared = self.orch / "shared"
        shared.rename(self.orch / "real-shared")
        shared.symlink_to("real-shared", target_is_directory=True)
        with self.assertRaisesRegex(review_scope.ScopeError, "symlink"):
            self.inventory()

    def test_inventory_rejects_each_root_replacement_during_reads(self) -> None:
        record = review_scope._contract_record
        for root in (self.build, self.orch):
            moved = root.with_name(root.name + "-retired")
            replaced = False

            def replace_after_read(*args, **kwargs):
                nonlocal replaced
                result = record(*args, **kwargs)
                if not replaced:
                    root.rename(moved)
                    shutil.copytree(moved, root)
                    replaced = True
                return result

            with self.subTest(root=root), patch.object(review_scope, "_contract_record", side_effect=replace_after_read):
                with self.assertRaisesRegex(review_scope.ScopeError, "root changed"):
                    self.inventory()

    def test_explicit_installs_need_no_checkout_and_reject_conflicting_exports_and_manifests(self) -> None:
        roots = review_scope.resolve_active_roots(self.build, {}, self.orch)
        self.assertEqual(roots["root_bindings"], review_scope.root_bindings(self.build, self.orch))
        self.assertEqual(roots["shared"], str(self.orch / "shared"))
        self.assertEqual(roots, review_scope.resolve_active_roots(self.build, {"MAKATO_BUILD_ROOT": "", "MAKATO_ORCHESTRATE_SHARED": ""}, self.orch))
        with self.assertRaises(review_scope.ScopeError):
            review_scope.resolve_active_roots(self.build, {})
        for env in ({"MAKATO_BUILD_ROOT": str(self.orch)}, {"MAKATO_ORCHESTRATE_ROOT": str(self.build)}, {"MAKATO_ORCHESTRATE_SHARED": str(self.build / "shared")}):
            with self.subTest(env=env), self.assertRaises(review_scope.ScopeError):
                review_scope.resolve_active_roots(self.build, env, self.orch)
        _write(self.orch, ".claude-plugin/plugin.json", '{"name":"inactive-decoy"}')
        with self.assertRaisesRegex(review_scope.ScopeError, "manifest"):
            review_scope.resolve_active_roots(self.build, {}, self.orch)

    def test_implicit_checkout_and_linked_worktree_proof_ignore_hostile_git_environment(self) -> None:
        suite = self.source_suite()
        hostile = dict(os.environ)
        for key in ("MAKATO_BUILD_ROOT", "MAKATO_ORCHESTRATE_ROOT", "MAKATO_ORCHESTRATE_SHARED"):
            hostile.pop(key, None)
        hostile.update(dict.fromkeys(("GIT_DIR", "GIT_WORK_TREE", "GIT_COMMON_DIR", "GIT_INDEX_FILE", "GIT_CEILING_DIRECTORIES"), "/nonexistent/hostile"))
        self.assertEqual(review_scope.resolve_active_roots(self.build, hostile)["orchestrate"], str(self.orch))
        linked = self.directory / "linked"
        _run(suite, "worktree", "add", "--detach", str(linked), "HEAD")
        self.assertTrue((linked / ".git").is_file())
        self.assertEqual(review_scope.resolve_active_roots(linked / "plugins/makato-build", hostile)["orchestrate"], str(linked / "plugins/makato-orchestrate"))

    def test_implicit_layout_rejects_untracked_wrong_marketplace_nested_checkout_and_symlink(self) -> None:
        suite = self.source_suite()
        marker = ".claude-plugin/marketplace.json"
        _run(suite, "rm", "--cached", marker)
        with self.assertRaises(review_scope.ScopeError):
            review_scope.resolve_active_roots(self.build, {})
        _run(suite, "add", marker)
        saved = (suite / marker).read_text()
        _write(suite, marker, saved.replace("./plugins/makato-orchestrate", "./inactive-decoy"))
        with self.assertRaisesRegex(review_scope.ScopeError, "marketplace"):
            review_scope.resolve_active_roots(self.build, {})
        _write(suite, marker, saved)
        actual = self.orch.with_name("actual-orchestrate")
        self.orch.rename(actual)
        self.orch.symlink_to(actual, target_is_directory=True)
        with self.assertRaisesRegex(review_scope.ScopeError, "symlink"):
            review_scope.resolve_active_roots(self.build, {})
        nested = suite / "vendor/suite"
        shutil.copytree(self.build, nested / "plugins/makato-build")
        with self.assertRaisesRegex(review_scope.ScopeError, "toplevel"):
            review_scope.resolve_active_roots(nested / "plugins/makato-build", {})

    def test_fingerprint_namespaces_active_mutation_and_relocation_are_content_only(self) -> None:
        repo = self.directory / "consumer"
        _write(repo, "app.py", "VALUE = 1\n")
        _run(repo, "init", "-q", "-b", "main")
        _run(repo, "config", "user.email", "scope@example.invalid")
        _run(repo, "config", "user.name", "scope")
        _run(repo, "add", "-A")
        _run(repo, "commit", "-qm", "base")
        base = _run(repo, "rev-parse", "HEAD")

        def fingerprint(build, orchestrate):
            return review_scope.fingerprint(str(repo), base, contract_paths=list(review_scope.REVIEW_CONTRACT_PATHS), contract_root=str(build), orchestrate_root=str(orchestrate))

        before = fingerprint(self.build, self.orch)
        self.assertIn("orchestrate:shared/progress-comment.sh", before["files"])
        self.assertIn("contract:shared/build-log.sh", before["files"])
        self.assertEqual(before["manifest"]["schema"], "review-input-fingerprint-v2")
        self.assertEqual(before["manifest"]["review_contract_version"], 3)
        copy = self.directory / "copy"
        shutil.copytree(self.orch, copy)
        self.assertEqual(before, fingerprint(self.build, copy))
        helper = self.orch / "shared/progress-comment.sh"
        helper.write_bytes(helper.read_bytes() + b"\n# active change\n")
        self.assertNotEqual(before["sha256"], fingerprint(self.build, self.orch)["sha256"])
        self.assertEqual(before, fingerprint(self.build, copy))


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
