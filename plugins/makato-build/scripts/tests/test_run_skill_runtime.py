"""Integration coverage for run-skill's durable build-review launch path."""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

_BUILD_ROOT = Path(__file__).resolve().parents[2]
_REPO_ROOT = _BUILD_ROOT.parents[1]
_SHARED = _BUILD_ROOT / "shared"
if str(_SHARED) not in sys.path:
    sys.path.insert(0, str(_SHARED))

import review_runtime  # noqa: E402
import review_scope  # noqa: E402


class DurableLauncherTests(unittest.TestCase):
    def setUp(self) -> None:
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.repo = self.root / "worktree"
        self.repo.mkdir()
        self.git(self.repo, "init", "-q")
        self.git(self.repo, "config", "user.email", "runtime-test@example.invalid")
        self.git(self.repo, "config", "user.name", "Runtime Test")
        (self.repo / "src.py").write_text("value = 1\n")
        context = self.repo / "specs" / "SMOKE"
        context.mkdir(parents=True)
        (context / "plan.md").write_text("AC-1: src.py returns value 3.\n")
        self.git(self.repo, "add", ".")
        self.git(self.repo, "commit", "-q", "-m", "base")
        (self.repo / "src.py").write_text("value = 2\n")
        git_dir = Path(self.git(self.repo, "rev-parse", "--absolute-git-dir"))
        self.ledger = git_dir / "makato-review-loop" / "SMOKE.json"
        subprocess.run(
            [sys.executable, str(_SHARED / "review_loop.py"), "init", "--state", str(self.ledger), "--story", "SMOKE", "--review-base", "HEAD"],
            capture_output=True,
            text=True,
            check=True,
        )
        fingerprint = review_scope.fingerprint(
            str(self.repo),
            "HEAD",
            context_paths=["specs/SMOKE/plan.md"],
            contract_paths=list(review_scope.REVIEW_CONTRACT_PATHS),
            evidence_root=str(self.repo),
            contract_root=str(_BUILD_ROOT),
        )["sha256"]
        invocation = self.root / "caller-context.txt"
        invocation.write_text("Authorized controlled process smoke; not LLM quality evaluation.\n")
        self.count_file = self.root / "harness-count.txt"
        self.args_file = self.root / "harness-args.json"
        self.env = {**os.environ, "MAKATO_BUILD_ROOT": str(_BUILD_ROOT), "MAKATO_HALT_FILE": str(self.root / "absent-halt"), "HARNESS_COUNT": str(self.count_file), "HARNESS_ARGS": str(self.args_file)}
        self.args = [
            sys.executable,
            str(_BUILD_ROOT / "scripts" / "run-skill.py"),
            "--repo-root",
            str(self.repo),
            "--cwd",
            str(self.repo),
            "--context-file",
            str(invocation),
            "--harness",
            str(Path(__file__).with_name("review_runtime_child.py").resolve()),
            "--review-ledger-state",
            str(self.ledger),
            "--attempt-id",
            "launcher-smoke",
            "--input-fingerprint",
            fingerprint,
            "--gate-event",
            "initial",
            "--review-worktree",
            str(self.repo),
            "--review-base",
            "HEAD",
            "--review-context-path",
            "specs/SMOKE/plan.md",
            *[arg for path in review_scope.REVIEW_CONTRACT_PATHS for arg in ("--review-contract-path", path)],
            "--review-evidence-root",
            str(self.repo),
            "--review-expected-ac-ids",
            "AC-1",
            "makato-build:build-review",
            "--",
            "SMOKE",
            "--autonomous",
        ]
        self.runtime_state = self.ledger.parent / self.ledger.stem / "runtime.json"

    def invoke(self, *, check: bool = True) -> subprocess.CompletedProcess:
        return subprocess.run(self.args, env=self.env, cwd=self.repo, capture_output=True, text=True, check=check, timeout=20)

    def test_task_checkpoint_is_nonfinal_then_full_review_starts_from_the_persisted_certify_action(self) -> None:
        self.env["HARNESS_RESULT"] = "checkpoint"
        checkpoint = json.loads(self.invoke().stdout)["data"]
        self.assertFalse(checkpoint["final_review"])
        self.assertEqual(checkpoint["checkpoint_receipt"]["task_ids"], ["1"])
        self.assertEqual(json.loads(self.ledger.read_text())["expected_ac_ids"], ["AC-1"])
        self.args[self.args.index("--attempt-id") + 1] = "final-after-checkpoint"
        self.env["HARNESS_RESULT"] = "certified"
        final = json.loads(self.invoke().stdout)["data"]
        self.assertTrue(final["final_review"])
        self.assertEqual(review_runtime.status(self.runtime_state, "final-after-checkpoint")["attempt"]["next_action"], "certify")
        self.assertEqual(self.count_file.read_text(), "2")
        self.assertEqual(json.loads(self.ledger.read_text())["passes"][-1]["scope"], "final-full")

    def test_legitimate_review_edits_are_certified_and_reaccepted_without_second_child(self) -> None:
        first = self.invoke()
        self.assertTrue(json.loads(first.stdout)["data"]["final_review"])
        second = self.invoke()
        self.assertEqual(json.loads(second.stdout), json.loads(first.stdout))
        self.assertEqual(self.count_file.read_text(), "1")
        self.assertEqual((self.repo / "src.py").read_text(), "value = 3\n")
        receipt = review_runtime.status(self.runtime_state, "launcher-smoke")["attempt"]
        self.assertIsNotNone(receipt["accepted_at"])

    def test_syntactic_success_without_final_gate_and_empty_return_never_pass(self) -> None:
        for mode in ("uncertified", "empty", "malformed"):
            with self.subTest(mode=mode):
                self.env["HARNESS_RESULT"] = mode
                self.args[self.args.index("--attempt-id") + 1] = mode
                result = self.invoke(check=False)
                self.assertNotEqual(result.returncode, 0)
                snapshot = review_runtime.status(self.runtime_state, mode)
                receipt = snapshot["attempt"]
                self.assertIsNone(receipt["accepted_at"])
                if mode != "uncertified":
                    self.assertEqual(receipt["state"], "blocked")
                    review_runtime.cancel(state_path=self.runtime_state, attempt_id=mode, expected_epoch=snapshot["epoch"], grace_seconds=0)

    def test_source_edit_after_acceptance_invalidates_cached_success_without_replaying_writer(self) -> None:
        self.invoke()
        (self.repo / "src.py").write_text("value = 4\n")
        stale = self.invoke(check=False)
        self.assertNotEqual(stale.returncode, 0)
        self.assertEqual(self.count_file.read_text(), "1")
        self.assertEqual((self.repo / "src.py").read_text(), "value = 4\n")

    def test_killed_launcher_recovers_same_child_and_rejects_competing_coordinator(self) -> None:
        self.env["HARNESS_DELAY"] = "0.8"
        parent = subprocess.Popen(self.args, env=self.env, cwd=self.repo, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            deadline = time.monotonic() + 10
            while not self.count_file.exists() and time.monotonic() < deadline:
                if parent.poll() is not None:
                    self.fail(f"launcher exited before its detached child: {parent.communicate()}")
                time.sleep(0.01)
            self.assertTrue(self.count_file.exists(), "controlled executable did not start")
            parent.kill()
            parent.communicate(timeout=5)
            competing = list(self.args)
            competing[competing.index("--attempt-id") + 1] = "competing"
            denied = subprocess.run(competing, env=self.env, cwd=self.repo, capture_output=True, text=True, timeout=20)
            self.assertNotEqual(denied.returncode, 0)
            recovered = self.invoke()
            self.assertTrue(json.loads(recovered.stdout)["data"]["final_review"])
            self.assertEqual(self.count_file.read_text(), "1")
        finally:
            if parent.poll() is None:
                parent.kill()
                parent.communicate(timeout=5)

    @staticmethod
    def git(repo: Path, *args: str) -> str:
        result = subprocess.run(
            ["git", "-C", str(repo), *args],
            capture_output=True,
            text=True,
            check=True,
        )
        return result.stdout.strip()


if __name__ == "__main__":
    unittest.main()
