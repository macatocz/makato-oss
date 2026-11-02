"""Integration coverage for run-skill's durable build-review launch path."""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

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
        self.build = _BUILD_ROOT
        self.orchestrate = _REPO_ROOT / "plugins/makato-orchestrate"
        self.env = {
            key: value
            for key, value in os.environ.items()
            if not key.startswith("MAKATO_REVIEW_")
            and key
            not in {
                "MAKATO_BUILD_ROOT",
                "MAKATO_ORCHESTRATE_ROOT",
                "MAKATO_ORCHESTRATE_SHARED",
                "WORKTREE_PATH",
                "KEY",
                "ISSUE_NUMBER",
                "REPO",
                "MAKATO_PC_GH_STUB",
                "MAKATO_PC_GH_FAIL",
                "MAKATO_PROGRESS_COMMENT_DISABLE",
            }
        }
        self.env.update(MAKATO_BUILD_ROOT=str(self.build), MAKATO_ORCHESTRATE_ROOT=str(self.orchestrate), MAKATO_ORCHESTRATE_SHARED=str(self.orchestrate / "shared"))
        environment = mock.patch.dict(os.environ, self.env, clear=True)
        environment.start()
        self.addCleanup(environment.stop)
        self.repo = self.root / "worktree"
        self.repo.mkdir()
        self.git(self.repo, "init", "-q")
        self.git(self.repo, "config", "user.email", "runtime-test@example.invalid")
        self.git(self.repo, "config", "user.name", "Runtime Test")
        (self.repo / "src.py").write_text("value = 1\n")
        (self.repo / "test_src.py").write_text("import runpy\nfrom pathlib import Path\n\ndef test_value():\n    assert runpy.run_path(str(Path(__file__).with_name('src.py')))['value'] == 3\n")
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
            env=self.env,
        )
        fingerprint = review_scope.fingerprint(
            str(self.repo),
            "HEAD",
            context_paths=["specs/SMOKE/plan.md"],
            contract_paths=list(review_scope.REVIEW_CONTRACT_PATHS),
            evidence_root=str(self.repo),
            contract_root=str(self.build),
            orchestrate_root=str(self.orchestrate),
        )["sha256"]
        invocation = self.root / "caller-context.txt"
        invocation.write_text("Authorized controlled process smoke; not LLM quality evaluation.\n")
        self.count_file = self.root / "harness-count.txt"
        self.args_file = self.root / "harness-args.json"
        self.env.update(MAKATO_HALT_FILE=str(self.root / "absent-halt"), HARNESS_COUNT=str(self.count_file), HARNESS_ARGS=str(self.args_file))
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
        self.enable_publication()

    def invoke(self, *, check: bool = True) -> subprocess.CompletedProcess:
        return subprocess.run(self.args, env=self.env, cwd=self.repo, capture_output=True, text=True, check=check, timeout=20)

    def enable_publication(self) -> None:
        audit = self.repo / "specs/SMOKE/build.jsonl"
        audit.write_text("{}\n")
        self.git(self.repo, "add", "specs/SMOKE/build.jsonl")
        self.git(self.repo, "commit", "-qm", "tracked review audit")
        self.refresh_launch_fingerprint()
        self.env["HARNESS_PUBLISH_AUDIT"] = "1"

    def refresh_launch_fingerprint(self) -> str:
        current = review_scope.fingerprint(
            str(self.repo),
            "HEAD",
            context_paths=[self.args[index + 1] for index, value in enumerate(self.args) if value == "--review-context-path"],
            contract_paths=list(review_scope.REVIEW_CONTRACT_PATHS),
            evidence_root=str(self.repo),
            contract_root=str(self.build),
            orchestrate_root=str(self.orchestrate),
        )["sha256"]
        self.args[self.args.index("--input-fingerprint") + 1] = current
        return current

    def install_sources(self) -> Path:
        self.build = self.root / "independent-build" / "build-v9"
        self.orchestrate = self.root / "independent-control-plane" / "orchestrate-v9"
        shutil.copytree(_BUILD_ROOT, self.build, ignore=shutil.ignore_patterns("__pycache__"))
        shutil.copytree(_REPO_ROOT / "plugins/makato-orchestrate", self.orchestrate, ignore=shutil.ignore_patterns("__pycache__"))
        decoy = self.repo / "plugins/makato-orchestrate"
        shutil.copytree(self.orchestrate, decoy)
        # The decoy is not a worktree input; it cannot certify the active install.
        with (self.repo / ".git/info/exclude").open("a") as stream:
            stream.write("plugins/\n")
        self.env.update(MAKATO_BUILD_ROOT=str(self.build), MAKATO_ORCHESTRATE_ROOT=str(self.orchestrate), MAKATO_ORCHESTRATE_SHARED=str(self.orchestrate / "shared"))
        self.args[1] = str(self.build / "scripts/run-skill.py")
        self.args[self.args.index("--harness") + 1] = str(self.build / "scripts/tests/review_runtime_child.py")
        self.refresh_launch_fingerprint()
        return decoy

    def runtime_cli(self, *arguments: str) -> subprocess.CompletedProcess:
        return subprocess.run([sys.executable, str(self.build / "shared/review_runtime.py"), *arguments], env=self.env, cwd=self.repo, capture_output=True, text=True, timeout=20)

    def test_installed_launcher_binds_both_roots_and_ignores_inactive_decoy(self) -> None:
        decoy = self.install_sources()
        first = json.loads(self.invoke().stdout)
        snapshot = self.runtime_cli("status", "--state", str(self.runtime_state), "--attempt-id", "launcher-smoke")
        self.assertEqual(snapshot.returncode, 0, snapshot.stderr)
        attempt = json.loads(snapshot.stdout)["attempt"]
        self.assertEqual(attempt["contract_root"], str(self.build))
        self.assertEqual(attempt["orchestrate_root"], str(self.orchestrate))
        self.assertEqual(attempt["root_bindings"], review_scope.root_bindings(self.build, self.orchestrate))
        (decoy / "shared/progress-comment.sh").write_text("# inactive mutation\n")
        self.assertEqual(json.loads(self.invoke().stdout), first)
        self.assertEqual(self.count_file.read_text(), "1")
        for active in (self.build / "shared/build-log.sh", self.build / "shared/review_scope.py", self.orchestrate / "shared/progress-comment.sh"):
            with self.subTest(active=active):
                before = active.read_bytes()
                active.write_bytes(before + b"\n# active contract mutation\n")
                rejected = self.invoke(check=False)
                self.assertNotEqual(rejected.returncode, 0, rejected.stdout)
                self.assertEqual(self.count_file.read_text(), "1")
                active.write_bytes(before)
        self.assertEqual(json.loads(self.invoke().stdout), first)

    def test_durable_dry_run_exposes_roots_without_creating_ledger_binding(self) -> None:
        self.install_sources()
        args = self.args[:2] + ["--dry-run", "--review-orchestrate-root", str(self.orchestrate)] + self.args[2:]
        dry = subprocess.run(args, env=self.env, cwd=self.repo, capture_output=True, text=True, timeout=20)
        self.assertEqual(dry.returncode, 0, dry.stderr)
        data = json.loads(dry.stdout)
        self.assertEqual(
            {key: data["env"][key] for key in ("MAKATO_BUILD_ROOT", "MAKATO_ORCHESTRATE_ROOT", "MAKATO_ORCHESTRATE_SHARED")},
            {key: self.env[key] for key in ("MAKATO_BUILD_ROOT", "MAKATO_ORCHESTRATE_ROOT", "MAKATO_ORCHESTRATE_SHARED")},
        )
        metadata = json.JSONDecoder().raw_decode(data["argv"][-1].split("Resolved dispatch metadata (JSON):\n", 1)[1])[0]
        self.assertEqual(metadata["plugin_roots"]["makato-orchestrate"], str(self.orchestrate))
        self.assertIsNone(json.loads(self.ledger.read_text())["root_bindings"])
        self.assertFalse(self.runtime_state.exists())
        self.assertFalse(self.count_file.exists())

    def test_installed_launcher_rejects_missing_conflicting_and_shared_roots_before_child(self) -> None:
        self.install_sources()
        decoy_build = self.root / "decoy-build"
        shutil.copytree(self.build, decoy_build)
        for overrides in (
            {"MAKATO_ORCHESTRATE_ROOT": "", "MAKATO_ORCHESTRATE_SHARED": ""},
            {"MAKATO_BUILD_ROOT": str(decoy_build)},
            {"MAKATO_ORCHESTRATE_SHARED": str(self.build / "shared")},
        ):
            with self.subTest(overrides=overrides):
                original = self.env.copy()
                self.env.update(overrides)
                rejected = self.invoke(check=False)
                self.env = original
                self.assertEqual(rejected.returncode, 2, rejected.stdout)
                self.assertFalse(self.count_file.exists())
        conflicting = self.args[:2] + ["--review-orchestrate-root", str(self.repo / "plugins/makato-orchestrate")] + self.args[2:]
        rejected = subprocess.run(conflicting, env=self.env, cwd=self.repo, capture_output=True, text=True, timeout=20)
        self.assertEqual(rejected.returncode, 2, rejected.stdout)
        self.assertIn("disagree", rejected.stderr)
        self.assertFalse(self.count_file.exists())

    def test_launcher_rejects_incomplete_closure_before_runtime_checkpoint_or_child(self) -> None:
        self.install_sources()
        original = self.args
        for missing in review_scope.REVIEW_CONTRACT_PATHS:
            with self.subTest(missing=missing):
                self.args = list(original)
                index = next(index for index, value in enumerate(self.args) if value == "--review-contract-path" and self.args[index + 1] == missing)
                del self.args[index : index + 2]
                rejected = self.invoke(check=False)
                self.assertEqual(rejected.returncode, 2, rejected.stdout)
                self.assertIn("complete versioned review contract", rejected.stderr)
                self.assertFalse(self.runtime_state.exists())
                self.assertFalse(self.count_file.exists())
        self.args = original

    def test_runtime_child_cannot_override_orchestrate_root_even_in_dry_run(self) -> None:
        self.install_sources()
        result = subprocess.run(
            [*self.args[:2], "--runtime-child", "--dry-run", "--repo-root", str(self.repo), "--review-orchestrate-root", str(self.orchestrate), "makato-build:build-review"],
            env=self.env,
            capture_output=True,
            text=True,
            timeout=20,
        )
        self.assertEqual(result.returncode, 2, result.stdout)
        self.assertIn("cannot override durable", result.stderr)
        self.assertFalse(self.count_file.exists())

    def test_installed_runtime_cli_rejects_missing_binding_old_state_and_physical_switch(self) -> None:
        self.install_sources()
        self.invoke()
        original = json.loads(self.runtime_state.read_text())
        for field in ("contract_root", "orchestrate_root", "root_bindings"):
            broken = json.loads(json.dumps(original))
            del broken["attempts"]["launcher-smoke"][field]
            self.runtime_state.write_text(json.dumps(broken))
            self.assertEqual(self.invoke(check=False).returncode, 2)
            self.assertEqual(self.runtime_cli("status", "--state", str(self.runtime_state)).returncode, 2)
        self.runtime_state.write_text(json.dumps({**original, "version": 1}))
        self.assertEqual(self.invoke(check=False).returncode, 2)
        self.runtime_state.write_text(json.dumps(original))
        relocated = self.root / "relocated-orchestrate"
        shutil.copytree(self.orchestrate, relocated)
        original_env = self.env.copy()
        self.env.update(MAKATO_ORCHESTRATE_ROOT=str(relocated), MAKATO_ORCHESTRATE_SHARED=str(relocated / "shared"))
        self.assertEqual(self.invoke(check=False).returncode, 2)
        self.env = original_env
        old = self.orchestrate.with_name("previous-orchestrate")
        self.orchestrate.rename(old)
        shutil.copytree(old, self.orchestrate)
        self.assertEqual(self.invoke(check=False).returncode, 2)
        self.assertEqual(self.count_file.read_text(), "1")

    def test_wrong_executing_runtime_recovery_blocks_without_loading_bound_code(self) -> None:
        self.install_sources()
        self.env.update(HARNESS_RESULT="certified", HARNESS_PUBLISH_AUDIT="0")
        self.assertNotEqual(self.invoke(check=False).returncode, 0)
        runtime_cli = self.build / "shared/review_runtime.py"
        before = runtime_cli.read_bytes()
        # The wrong source runtime must never import or execute the frozen copy.
        runtime_cli.write_text("raise AssertionError('loaded frozen runtime code')\n")
        environment = self.env | {"MAKATO_BUILD_ROOT": str(_BUILD_ROOT)}
        recovery = subprocess.run(
            [sys.executable, str(_SHARED / "review_runtime.py"), "recover-worktree", "--worktree", str(self.repo)], env=environment, cwd=self.repo, capture_output=True, text=True, timeout=20
        )
        runtime_cli.write_bytes(before)
        self.assertEqual(recovery.returncode, 4, recovery.stderr + recovery.stdout)
        self.assertEqual(json.loads(recovery.stdout)["decision"], "blocked")
        self.assertNotIn("loaded frozen runtime code", recovery.stderr)
        self.assertEqual(self.count_file.read_text(), "1")

    def test_tracked_final_audit_accepts_and_reuses_without_another_child(self) -> None:
        first = json.loads(self.invoke().stdout)
        self.assertNotEqual(first["data"]["input_fingerprint"], first["data"]["delivery_fingerprint"])
        self.assertEqual(first["data"]["delivery_fingerprint"], self.refresh_launch_fingerprint())
        # Reuse retains original invocation identity, including its pre-review FP.
        self.args[self.args.index("--input-fingerprint") + 1] = review_runtime.status(self.runtime_state, "launcher-smoke")["attempt"]["fingerprint"]
        self.assertEqual(json.loads(self.invoke().stdout), first)
        self.assertEqual(self.count_file.read_text(), "1")
        audit = self.repo / "specs/SMOKE/build.jsonl"
        self.assertEqual([json.loads(line).get("step") for line in audit.read_text().splitlines()], [None, "ac-verification", "session"])
        with audit.open("a") as stream:
            stream.write("{}\n")
        self.assertNotEqual(self.invoke(check=False).returncode, 0)
        self.assertEqual(self.count_file.read_text(), "1")

    def test_runtime_acceptance_and_reuse_reject_undercovered_retained_reviewer(self) -> None:
        self.invoke()
        ledger = json.loads(self.ledger.read_text())
        reviewer = ledger["raw_envelopes"][-1]["envelope"]["data"]
        reviewer.update(files_reviewed=0, file_citations=[])
        self.ledger.write_text(json.dumps(ledger))
        audit = self.repo / "specs/SMOKE/build.jsonl"
        prefix = audit.read_bytes()
        runtime_state = self.runtime_state.read_bytes()
        for accepted in (False, True):
            with self.subTest(accepted=accepted):
                state = json.loads(runtime_state)
                attempt = state["attempts"]["launcher-smoke"]
                if not accepted:
                    attempt["accepted_at"] = None
                self.runtime_state.write_text(json.dumps(state))
                result = self.runtime_cli(
                    "accept",
                    "--state",
                    str(self.runtime_state),
                    "--attempt-id",
                    "launcher-smoke",
                    "--expected-epoch",
                    str(state["epoch"]),
                )
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertEqual(audit.read_bytes(), prefix)
        self.runtime_state.write_bytes(runtime_state)
        self.assertNotEqual(self.invoke(check=False).returncode, 0)
        self.assertEqual(self.count_file.read_text(), "1")

    def test_runtime_acceptance_and_reuse_revalidate_retained_r1_and_ac_summary(self) -> None:
        self.invoke()
        valid = self.ledger.read_bytes()
        runtime_state = self.runtime_state.read_bytes()
        audit = self.repo / "specs/SMOKE/build.jsonl"
        prefix = audit.read_bytes()
        for corruption in ("raw-line", "raw-status", "raw-binding", "cached-ac"):
            ledger = json.loads(valid)
            raw = ledger["raw_envelopes"][-1]
            if corruption == "raw-line":
                raw["envelope"]["data"]["file_citations"][0]["line"] = 0
            elif corruption == "raw-status":
                raw["envelope"]["status"] = "partial"
            elif corruption == "raw-binding":
                raw["pass_id"] = "P-999"
            else:
                ledger["passes"][-1]["ac_verdicts"][0]["evidence"] = "Substituted evidence."
            self.ledger.write_text(json.dumps(ledger))
            for accepted in (False, True):
                with self.subTest(corruption=corruption, accepted=accepted):
                    state = json.loads(runtime_state)
                    if not accepted:
                        state["attempts"]["launcher-smoke"]["accepted_at"] = None
                    self.runtime_state.write_text(json.dumps(state))
                    result = self.runtime_cli("accept", "--state", str(self.runtime_state), "--attempt-id", "launcher-smoke", "--expected-epoch", str(state["epoch"]))
                    self.assertNotEqual(result.returncode, 0, result.stdout)
                    self.assertEqual(audit.read_bytes(), prefix)
            self.runtime_state.write_bytes(runtime_state)
            self.assertNotEqual(self.invoke(check=False).returncode, 0)
            self.assertEqual(self.count_file.read_text(), "1")

    def test_published_checkpoint_reuses_then_final_review_binds_the_live_audit_anchor(self) -> None:
        self.env["HARNESS_RESULT"] = "checkpoint"
        checkpoint = json.loads(self.invoke().stdout)
        receipt = checkpoint["data"]["checkpoint_receipt"]
        self.assertNotEqual(receipt["input_fingerprint"], receipt["delivery_fingerprint"])
        self.assertEqual(json.loads(self.invoke().stdout), checkpoint)
        self.assertEqual(self.count_file.read_text(), "1")
        self.args[self.args.index("--attempt-id") + 1] = "final-published-checkpoint"
        live = self.refresh_launch_fingerprint()
        self.assertEqual(live, receipt["delivery_fingerprint"])
        self.env["HARNESS_RESULT"] = "certified"
        final = json.loads(self.invoke().stdout)
        self.assertTrue(final["data"]["final_review"])
        self.assertEqual(json.loads(self.invoke().stdout), final)
        self.assertEqual(self.count_file.read_text(), "2")

    def test_decision_append_requires_a_recomputed_launch_fingerprint(self) -> None:
        with (self.repo / "specs/SMOKE/build.jsonl").open("a") as stream:
            stream.write('{"step":"checkpoint-decision"}\n')
        stale = self.invoke(check=False)
        self.assertNotEqual(stale.returncode, 0)
        self.assertFalse(self.count_file.exists())
        self.refresh_launch_fingerprint()
        self.assertTrue(json.loads(self.invoke().stdout)["data"]["final_review"])
        self.assertEqual(self.count_file.read_text(), "1")

    def test_progress_enabled_source_launcher_preserves_published_delivery_offline(self) -> None:
        orchestrate = self.orchestrate
        github = self.root / "offline-github"
        github.mkdir()
        self.env.update(
            KEY="SMOKE",
            ISSUE_NUMBER="186",
            REPO="offline/review",
            MAKATO_ORCHESTRATE_ROOT=str(orchestrate),
            MAKATO_ORCHESTRATE_SHARED=str(orchestrate / "shared"),
            MAKATO_TARGET_REPO_ROOT=str(self.repo),
            MAKATO_PC_GH_STUB=str(github),
        )
        self.env.pop("MAKATO_PROGRESS_COMMENT_DISABLE", None)
        initialized = subprocess.run(
            ["bash", str(orchestrate / "shared/workflow-state.sh"), "init", "SMOKE", "offline/review", "feat/review", "186"],
            cwd=self.repo,
            env=self.env,
            capture_output=True,
            text=True,
            check=True,
        )
        self.assertEqual(initialized.returncode, 0)
        # Workflow state is operational but explicitly bound, even though ignored.
        workflow = self.repo / "specs/SMOKE/workflow-state-186.json"
        (self.repo / ".git/info/exclude").write_text("specs/SMOKE/workflow-state-186.json\n")
        self.args[self.args.index("makato-build:build-review") : self.args.index("makato-build:build-review")] = [
            "--review-context-path",
            "specs/SMOKE/workflow-state-186.json",
        ]
        self.refresh_launch_fingerprint()
        before = workflow.read_bytes()
        first = json.loads(self.invoke().stdout)
        self.assertEqual(workflow.read_bytes(), before)
        self.assertEqual(json.loads(self.invoke().stdout), first)
        self.assertEqual(self.count_file.read_text(), "1")
        comments = list(github.glob("comment-*.md"))
        self.assertEqual(len(comments), 1)
        body = comments[0].read_text()
        self.assertIn("START", body)
        self.assertIn("DONE", body)
        operations = list((self.repo / ".git/makato-review-loop").glob("*/operations.jsonl"))
        self.assertEqual(len(operations), 1)
        rows = [json.loads(line) for line in operations[0].read_text().splitlines()]
        self.assertTrue(any(row["skill"] == "progress-comment" and row["status"] == "ok" for row in rows))
        audit = self.repo / "specs/SMOKE/build.jsonl"
        self.assertEqual([json.loads(line).get("step") for line in audit.read_text().splitlines()], [None, "ac-verification", "session"])

    def enable_offline_progress(self, orchestrate: Path) -> Path:
        github = self.root / "offline-github"
        github.mkdir()
        self.env.update(
            KEY="SMOKE",
            ISSUE_NUMBER="186",
            REPO="offline/review",
            MAKATO_ORCHESTRATE_ROOT=str(orchestrate),
            MAKATO_ORCHESTRATE_SHARED=str(orchestrate / "shared"),
            MAKATO_TARGET_REPO_ROOT=str(self.repo),
            MAKATO_PC_GH_STUB=str(github),
        )
        self.env.pop("MAKATO_PROGRESS_COMMENT_DISABLE", None)
        return github

    def bind_legacy_workflow(self) -> Path:
        legacy = self.repo / "specs/SMOKE/workflow-state.json"
        legacy.write_text('{"issue_number":186,"progress_comment_id":null}\n')
        (self.repo / ".git/info/exclude").write_text("specs/SMOKE/workflow-state*.json\n")
        index = self.args.index("makato-build:build-review")
        self.args[index:index] = ["--review-context-path", "specs/SMOKE/workflow-state.json"]
        self.refresh_launch_fingerprint()
        return legacy

    def test_source_launcher_preserves_protected_legacy_path_and_one_live_comment(self) -> None:
        github = self.enable_offline_progress(self.orchestrate)
        legacy = self.bind_legacy_workflow()
        before, identity = legacy.read_bytes(), legacy.stat()
        first = self.invoke(check=False)
        self.assertTrue(legacy.exists(), first.stderr)
        self.assertEqual(legacy.read_bytes(), before)
        self.assertEqual((legacy.stat().st_ino, legacy.stat().st_mode), (identity.st_ino, identity.st_mode))
        self.assertFalse(legacy.with_name("workflow-state-186.json").exists())
        self.assertFalse(legacy.with_name("workflow-state.json.superseded-by-186").exists())
        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertEqual(json.loads(self.invoke().stdout), json.loads(first.stdout))
        self.assertEqual(self.count_file.read_text(), "1")
        comments = list(github.glob("comment-*.md"))
        self.assertEqual(len(comments), 1)
        self.assertIn("START", comments[0].read_text())
        self.assertIn("DONE", comments[0].read_text())

    def test_failed_private_cache_read_never_migrates_protected_legacy_state(self) -> None:
        orchestrate = self.orchestrate
        github = self.enable_offline_progress(orchestrate)
        legacy = self.bind_legacy_workflow()
        before, identity = legacy.read_bytes(), legacy.stat()
        modern = legacy.with_name("workflow-state-186.json")
        modern.write_text('{"issue_number":186,"progress_comment_id":null}\n')
        modern_before = modern.read_bytes()
        result = subprocess.run(
            ["bash", str(orchestrate / "shared/progress-comment.sh"), "note", "SMOKE", "186", "offline/review", "--text", "Cache unavailable"],
            cwd=self.repo,
            env={**self.env, "WORKTREE_PATH": str(self.repo), "MAKATO_REVIEW_LEDGER_STATE": str(self.root / "missing-ledger.json")},
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(legacy.exists(), result.stderr)
        self.assertEqual(legacy.read_bytes(), before)
        self.assertEqual((legacy.stat().st_ino, legacy.stat().st_mode), (identity.st_ino, identity.st_mode))
        self.assertEqual(modern.read_bytes(), modern_before)
        self.assertFalse(legacy.with_name("workflow-state.json.superseded-by-186").exists())
        self.assertIn("WARN", result.stderr)
        self.assertEqual(result.stdout, "")
        self.assertEqual(list(github.iterdir()), [])
        self.assertEqual(list(self.ledger.parent.glob("*/operations.jsonl")), [])

    def test_separate_installed_orchestrate_root_uses_active_build_private_cache_and_log(self) -> None:
        self.install_sources()
        self.assertFalse((self.orchestrate.parent / "makato-build").exists())
        github = self.enable_offline_progress(self.orchestrate)
        first = json.loads(self.invoke().stdout)
        self.assertEqual(json.loads(self.invoke().stdout), first)
        self.assertEqual(self.count_file.read_text(), "1")
        comments = list(github.glob("comment-*.md"))
        self.assertEqual(len(comments), 1)
        self.assertEqual(comments[0].read_text().count("START: build-review"), 1)
        self.assertEqual(comments[0].read_text().count("DONE: build-review"), 1)
        operations = list((self.repo / ".git/makato-review-loop").glob("*/operations.jsonl"))
        self.assertEqual(len(operations), 1)
        rows = [json.loads(line) for line in operations[0].read_text().splitlines()]
        self.assertEqual([row["step"] for row in rows], ["progress-comment-id", "progress-comment", "progress-comment"])
        self.assertEqual([row["data"].get("event") for row in rows[1:]], ["create", "append"])
        audit = self.repo / "specs/SMOKE/build.jsonl"
        self.assertEqual([json.loads(line).get("step") for line in audit.read_text().splitlines()], [None, "ac-verification", "session"])

    def test_direct_wrong_progress_bindings_warn_without_transport_or_private_writes(self) -> None:
        decoy = self.install_sources()
        github = self.enable_offline_progress(self.orchestrate)
        legacy = self.bind_legacy_workflow()
        self.invoke()
        protected = [self.ledger, self.runtime_state, legacy, self.repo / "specs/SMOKE/build.jsonl"]
        protected.extend(self.ledger.parent.glob("*/operations.jsonl"))
        before = {path: (path.read_bytes(), path.stat().st_ino, path.stat().st_mode) for path in protected}
        comments = {path: path.read_bytes() for path in github.iterdir()}
        transport = self.root / "transport-bin"
        transport.mkdir()
        calls = transport / "calls"
        gh = transport / "gh"
        gh.write_text('#!/bin/sh\nprintf "called\\n" >> "$TRANSPORT_CALLS"\nexit 1\n')
        gh.chmod(0o755)
        environment = self.env | {
            "WORKTREE_PATH": str(self.repo),
            "MAKATO_REVIEW_LEDGER_STATE": str(self.ledger),
            "PATH": f"{transport}:{self.env['PATH']}",
            "TRANSPORT_CALLS": str(calls),
        }
        environment.pop("MAKATO_PC_GH_STUB")
        wrong_build = self.root / "inactive-build"
        shutil.copytree(self.build, wrong_build)
        helper = self.orchestrate / "shared/progress-comment.sh"
        for executable, overrides in (
            (decoy / "shared/progress-comment.sh", {}),
            (helper, {"MAKATO_ORCHESTRATE_SHARED": str(decoy / "shared")}),
            (helper, {"MAKATO_ORCHESTRATE_ROOT": str(decoy)}),
            (helper, {"MAKATO_BUILD_ROOT": str(wrong_build)}),
            (helper, {"MAKATO_BUILD_ROOT": ""}),
            (helper, {"MAKATO_BUILD_ROOT": None}),
        ):
            with self.subTest(executable=executable, overrides=overrides):
                calls.unlink(missing_ok=True)
                child_env = environment | overrides
                child_env = {key: value for key, value in child_env.items() if value is not None}
                result = subprocess.run(
                    ["bash", str(executable), "note", "SMOKE", "186", "offline/review", "--text", "must not publish"],
                    cwd=self.repo,
                    env=child_env,
                    capture_output=True,
                    text=True,
                    timeout=20,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, "")
                self.assertIn("WARN", result.stderr)
                self.assertFalse(calls.exists(), "binding failure reached GitHub transport")
                self.assertEqual({path: path.read_bytes() for path in github.iterdir()}, comments)
                for path, (content, inode, mode) in before.items():
                    self.assertEqual((path.read_bytes(), path.stat().st_ino, path.stat().st_mode), (content, inode, mode))
                self.assertFalse(legacy.with_name("workflow-state-186.json").exists())
                self.assertFalse(legacy.with_name("workflow-state.json.superseded-by-186").exists())
        self.assertEqual(self.count_file.read_text(), "1")

    def test_wrong_install_build_logger_cannot_mutate_ledger_or_canonical_audit(self) -> None:
        self.install_sources()
        self.invoke()
        wrong_build = self.root / "inactive-build"
        shutil.copytree(self.build, wrong_build)
        protected = [self.ledger, self.runtime_state, self.repo / "specs/SMOKE/build.jsonl"]
        before = {path: path.read_bytes() for path in protected}
        environment = self.env | {"WORKTREE_PATH": str(self.repo), "MAKATO_REVIEW_LEDGER_STATE": str(self.ledger)}
        entry = json.dumps({"skill": "boundary-regression", "step": "session", "status": "start", "model": "controlled-smoke"})
        for arguments, stdin in (([entry], None), (["--batch"], entry + "\n")):
            with self.subTest(arguments=arguments):
                result = subprocess.run(
                    ["bash", str(wrong_build / "shared/build-log.sh"), "SMOKE", *arguments],
                    cwd=self.repo,
                    env=environment,
                    input=stdin,
                    capture_output=True,
                    text=True,
                    timeout=20,
                )
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertIn("executing installation", result.stderr)
                for path, content in before.items():
                    self.assertEqual(path.read_bytes(), content)
                self.assertEqual(list(self.ledger.parent.glob("*/operations.jsonl")), [])
        self.assertEqual(self.count_file.read_text(), "1")

    def test_source_launcher_rejects_hardlinked_audit_without_corrupting_reviewed_data(self) -> None:
        audit = self.repo / "specs/SMOKE/build.jsonl"
        collateral = self.repo / "protected-data.json"
        os.link(audit, collateral)
        self.refresh_launch_fingerprint()
        before = audit.read_bytes()
        rejected = self.invoke(check=False)
        self.assertNotEqual(rejected.returncode, 0)
        self.assertEqual(audit.read_bytes(), before)
        self.assertEqual(collateral.read_bytes(), before)
        self.assertIsNone(review_runtime.status(self.runtime_state, "launcher-smoke")["attempt"]["accepted_at"])
        self.assertNotEqual(self.invoke(check=False).returncode, 0)
        self.assertEqual(self.count_file.read_text(), "1")

    def test_progress_github_error_is_logged_without_invalidating_publication(self) -> None:
        github = self.root / "offline-github"
        github.mkdir()
        self.env.update(
            KEY="SMOKE",
            ISSUE_NUMBER="186",
            REPO="offline/review",
            MAKATO_ORCHESTRATE_SHARED=str(_REPO_ROOT / "plugins/makato-orchestrate/shared"),
            MAKATO_TARGET_REPO_ROOT=str(self.repo),
            MAKATO_PC_GH_STUB=str(github),
            MAKATO_PC_GH_FAIL="1",
        )
        self.env.pop("MAKATO_PROGRESS_COMMENT_DISABLE", None)
        first = json.loads(self.invoke().stdout)
        self.assertEqual(json.loads(self.invoke().stdout), first)
        self.assertEqual(self.count_file.read_text(), "1")
        operations = list((self.repo / ".git/makato-review-loop").glob("*/operations.jsonl"))
        rows = [json.loads(line) for line in operations[0].read_text().splitlines()]
        self.assertEqual([row["status"] for row in rows], ["warn", "warn"])
        self.assertTrue(all(row["skill"] == "progress-comment" for row in rows))

    def assert_unpublished_rejected(self, mode: str) -> None:
        self.env.update(HARNESS_RESULT=mode, HARNESS_PUBLISH_AUDIT="0")
        for _ in range(2):
            result = self.invoke(check=False)
            self.assertEqual(result.returncode, 2, result.stdout)
            self.assertIn("audit", result.stderr)
            self.assertIsNone(review_runtime.status(self.runtime_state, "launcher-smoke")["attempt"]["accepted_at"])
        self.assertEqual(self.count_file.read_text(), "1")

    def test_final_source_certificate_without_publication_cannot_be_accepted_or_reused(self) -> None:
        self.assert_unpublished_rejected("certified")

    def test_checkpoint_source_certificate_without_publication_cannot_be_accepted_or_reused(self) -> None:
        self.assert_unpublished_rejected("checkpoint")

    def test_real_checkpoint_receipt_cli_uses_source_identity_and_checks_live_delivery(self) -> None:
        self.env["HARNESS_RESULT"] = "checkpoint"
        result = json.loads(self.invoke().stdout)["data"]
        receipt = result["checkpoint_receipt"]
        command = [
            sys.executable,
            str(_SHARED / "review_loop.py"),
            "checkpoint-receipt",
            "--state",
            str(self.ledger),
            "--task-ids",
            "1",
            "--pass-id",
            receipt["pass_id"],
            "--worktree",
            str(self.repo),
            "--review-base",
            "HEAD",
            "--fingerprint",
            result["input_fingerprint"],
        ]
        checked = subprocess.run(command, capture_output=True, text=True, check=False)
        self.assertEqual(checked.returncode, 0, checked.stderr)
        self.assertEqual(json.loads(checked.stdout), receipt)
        self.assertEqual(receipt["delivery_fingerprint"], self.refresh_launch_fingerprint())
        self.assertNotEqual(receipt["input_fingerprint"], receipt["delivery_fingerprint"])
        command[-1] = receipt["delivery_fingerprint"]
        wrong_identity = subprocess.run(command, capture_output=True, text=True, check=False)
        self.assertEqual(wrong_identity.returncode, 2)
        command[-1] = receipt["input_fingerprint"]
        (self.repo / "src.py").write_text("value = 4\n")
        stale = subprocess.run(command, capture_output=True, text=True, check=False)
        self.assertEqual(stale.returncode, 2)

    def test_task_checkpoint_is_nonfinal_then_full_review_starts_from_the_live_published_anchor(self) -> None:
        self.env["HARNESS_RESULT"] = "checkpoint"
        checkpoint = json.loads(self.invoke().stdout)["data"]
        self.assertFalse(checkpoint["final_review"])
        self.assertEqual(checkpoint["checkpoint_receipt"]["task_ids"], ["1"])
        self.assertEqual(json.loads(self.ledger.read_text())["expected_ac_ids"], ["AC-1"])
        self.args[self.args.index("--attempt-id") + 1] = "final-after-checkpoint"
        self.env["HARNESS_RESULT"] = "certified"
        live = self.refresh_launch_fingerprint()
        self.assertEqual(live, checkpoint["delivery_fingerprint"])
        self.assertNotEqual(live, checkpoint["input_fingerprint"])
        final = json.loads(self.invoke().stdout)["data"]
        self.assertTrue(final["final_review"])
        # Publication changed the live inputs; a new attempt needs fresh review,
        # not the source-only checkpoint's pre-publication certify action.
        self.assertEqual(review_runtime.status(self.runtime_state, "final-after-checkpoint")["attempt"]["next_action"], "review")
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
