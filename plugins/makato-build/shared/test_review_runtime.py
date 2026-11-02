"""Behavioral tests for durable review process ownership and recovery."""

from __future__ import annotations

import concurrent.futures
import hashlib
import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path
from unittest import mock

_HERE = Path(__file__).resolve().parent
if str(_HERE) not in sys.path:
    sys.path.insert(0, str(_HERE))

import review_loop  # noqa: E402
import review_runtime as runtime  # noqa: E402
import review_scope  # noqa: E402

_R1 = {
    "schema": "r1",
    "agent": "build-review",
    "status": "success",
    "summary": "controlled runtime fixture",
    "files_changed": [],
    "tests_written": [],
    "errors": [],
    "tool_calls_used": 0,
    "data": {"input_fingerprint": "a" * 64, "final_review": True},
}


class ReviewRuntimeTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        subprocess.run(["git", "init", "-q", str(self.root)], check=True, capture_output=True)
        self.state = self.root / "runtime.json"
        self.ledger = self.root / "ledger.json"
        self.fingerprint = "a" * 64
        self.halt_file = self.root / "HALT"
        self.build = self.root / "build-install"
        self.orchestrate = self.root / "orchestrate-install"
        shutil.copytree(_HERE.parent, self.build, ignore=shutil.ignore_patterns("__pycache__"))
        shutil.copytree(_HERE.parents[1] / "makato-orchestrate", self.orchestrate, ignore=shutil.ignore_patterns("__pycache__"))
        (self.root / ".git/info/exclude").write_text("build-install/\norchestrate-install/\n")
        self.contracts = list(review_scope.REVIEW_CONTRACT_PATHS)
        self.env = {
            key: value
            for key, value in os.environ.items()
            if not key.startswith("MAKATO_REVIEW_") and key not in {"MAKATO_BUILD_ROOT", "MAKATO_ORCHESTRATE_ROOT", "MAKATO_ORCHESTRATE_SHARED", "WORKTREE_PATH"}
        }
        self.env.update(
            MAKATO_HALT_FILE=str(self.halt_file), MAKATO_BUILD_ROOT=str(self.build), MAKATO_ORCHESTRATE_ROOT=str(self.orchestrate), MAKATO_ORCHESTRATE_SHARED=str(self.orchestrate / "shared")
        )
        for patch in (
            mock.patch.dict(os.environ, self.env, clear=True),
            mock.patch.object(runtime, "__file__", str(self.build / "shared/review_runtime.py")),
            mock.patch.object(review_loop, "__file__", str(self.build / "shared/review_loop.py")),
        ):
            patch.start()
            self.addCleanup(patch.stop)

    def test_root_switch_during_initial_gate_is_rejected_before_worker_spawn(self) -> None:
        def switch_root(**kwargs):
            previous = self.orchestrate.with_name("previous-orchestrate")
            if not previous.exists():
                self.orchestrate.rename(previous)
                shutil.copytree(previous, self.orchestrate)
            return self.gate(**kwargs)

        with mock.patch.object(runtime, "_gate", side_effect=switch_root):
            with self.assertRaisesRegex(runtime.RuntimeErrorState, "root bindings"):
                runtime.launch(
                    state_path=self.state,
                    ledger_state=self.ledger,
                    attempt_id="switch",
                    role="build-review",
                    fingerprint=self.fingerprint,
                    expected_epoch=0,
                    next_action="review",
                    gate_event="initial",
                    worktree=self.root,
                    review_base="HEAD",
                    command=self.child_command(),
                    cwd=self.root,
                    env=self.env,
                    contract_paths=self.contracts,
                )
        self.assertFalse(self.state.exists())
        self.assertFalse((self.state.parent / "attempts/switch").exists())

    def test_runtime_v2_freezes_both_roots_and_exports_them_to_the_child(self) -> None:
        command = [sys.executable, "-c", "import os; print('\\n'.join(os.environ[key] for key in ('MAKATO_BUILD_ROOT', 'MAKATO_ORCHESTRATE_ROOT', 'MAKATO_ORCHESTRATE_SHARED')))"]
        self.launch(command)
        finished = runtime.wait_for_result(self.state, "attempt", 5)
        attempt = finished["attempt"]
        self.assertEqual(runtime.VERSION, 2)
        self.assertEqual(finished["schema"], "review-runtime.v2")
        self.assertEqual(attempt["contract_root"], str(self.build))
        self.assertEqual(attempt["orchestrate_root"], str(self.orchestrate))
        self.assertEqual(attempt["root_bindings"], review_scope.root_bindings(self.build, self.orchestrate))
        self.assertEqual(Path(attempt["stdout_path"]).read_text().splitlines(), [str(self.build), str(self.orchestrate), str(self.orchestrate / "shared")])

    def test_incomplete_contract_closure_is_rejected_before_gate_or_spawn(self) -> None:
        for missing in self.contracts:
            with self.subTest(missing=missing):
                with mock.patch.object(self, "contracts", [item for item in self.contracts if item != missing]):
                    with mock.patch.object(self, "gate", side_effect=AssertionError("incomplete closure reached the gate")):
                        with self.assertRaisesRegex(runtime.RuntimeErrorState, "complete versioned review contract"):
                            self.launch(self.child_command())
                self.assertFalse(self.state.exists())

    def test_every_state_operation_rejects_missing_binding_and_old_attempt_schema(self) -> None:
        self.launch(self.child_command())
        finished = runtime.wait_for_result(self.state, "attempt", 5)
        original = json.loads(self.state.read_text())
        operations = (
            lambda: runtime.status(self.state, "attempt"),
            lambda: runtime.wait_for_result(self.state, "attempt", 0),
            lambda: runtime.reconcile(state_path=self.state, attempt_id="attempt", expected_epoch=finished["epoch"]),
            lambda: runtime.accept(state_path=self.state, attempt_id="attempt", expected_epoch=finished["epoch"]),
            lambda: runtime.cancel(state_path=self.state, attempt_id="attempt", expected_epoch=finished["epoch"]),
        )
        for field in ("contract_root", "orchestrate_root", "root_bindings"):
            broken = json.loads(json.dumps(original))
            del broken["attempts"]["attempt"][field]
            runtime._write_json(self.state, broken)
            for operation in operations:
                with self.subTest(field=field, operation=operation):
                    with self.assertRaisesRegex(runtime.RuntimeErrorState, "root binding"):
                        operation()
        runtime._write_json(self.state, {**original, "version": 1})
        with self.assertRaisesRegex(runtime.RuntimeErrorState, "incompatible runtime checkpoint version"):
            runtime.status(self.state)
        runtime._write_json(self.state, original)

    def test_executing_install_and_same_path_replacement_reject_all_state_operations(self) -> None:
        self.launch(self.child_command())
        finished = runtime.wait_for_result(self.state, "attempt", 5)
        operations = (
            lambda: runtime.status(self.state, "attempt"),
            lambda: runtime.wait_for_result(self.state, "attempt", 0),
            lambda: runtime.reconcile(state_path=self.state, attempt_id="attempt", expected_epoch=finished["epoch"]),
            lambda: runtime.accept(state_path=self.state, attempt_id="attempt", expected_epoch=finished["epoch"]),
            lambda: runtime.cancel(state_path=self.state, attempt_id="attempt", expected_epoch=finished["epoch"]),
        )
        with mock.patch.object(runtime, "__file__", str(_HERE / "review_runtime.py")):
            for operation in operations:
                with self.assertRaises(runtime.RuntimeErrorState):
                    operation()
        old = self.orchestrate.with_name("old-orchestrate")
        self.orchestrate.rename(old)
        shutil.copytree(old, self.orchestrate)
        for operation in operations:
            with self.assertRaisesRegex(runtime.RuntimeErrorState, "root bindings"):
                operation()

    def gate(self, **_kwargs: object) -> dict[str, object]:
        return {
            "next_action": "review",
            "reason": "eligible",
            "gate_id": 1,
            "input_fingerprint": self.fingerprint,
        }

    def launch(
        self,
        command: list[str],
        *,
        attempt_id: str = "attempt",
        expected_epoch: int | None = None,
        state_path: Path | None = None,
        ledger_state: Path | None = None,
    ) -> dict:
        state_path = self.state if state_path is None else state_path
        ledger_state = self.ledger if ledger_state is None else ledger_state
        if expected_epoch is None:
            expected_epoch = runtime.status(state_path)["epoch"]
        with mock.patch.object(runtime, "_gate", side_effect=self.gate):
            return runtime.launch(
                state_path=state_path,
                ledger_state=ledger_state,
                attempt_id=attempt_id,
                role="makato-build:build-review",
                fingerprint=self.fingerprint,
                expected_epoch=expected_epoch,
                next_action="review",
                gate_event="initial",
                worktree=self.root,
                review_base="HEAD",
                command=command,
                cwd=self.root,
                env=self.env,
                contract_paths=self.contracts,
                invocation_sha256=hashlib.sha256(attempt_id.encode()).hexdigest(),
            )

    def child_command(self, *, delay: float = 0, output: str | None = None) -> list[str]:
        body = "import time; time.sleep(%r); " % delay
        if output is None:
            output = "```json\n" + json.dumps(_R1) + "\n```\n"
        body += "print(%r, end='')" % output
        return [sys.executable, "-c", body]

    def wait_until(self, predicate) -> None:
        deadline = time.monotonic() + 5
        while not predicate() and time.monotonic() < deadline:
            time.sleep(0.01)
        self.assertTrue(predicate())

    def stop_owned_group(self, attempt: dict) -> None:
        deadline = time.monotonic() + 5
        while runtime._owned_group_alive(attempt) and time.monotonic() < deadline:
            runtime._signal_owned(attempt, signal.SIGKILL)
            time.sleep(0.01)

    def test_missing_publication_never_compares_equal_at_initial_or_repeated_acceptance(self) -> None:
        self.launch(self.child_command())
        finished = runtime.wait_for_result(self.state, "attempt", 5)
        gate = {"next_action": "complete", "gate_id": 2, "input_fingerprint": self.fingerprint}
        for _ in range(2):
            with mock.patch.object(runtime, "_gate", return_value=gate):
                with self.assertRaisesRegex(runtime.RuntimeErrorState, "audit"):
                    runtime.accept(state_path=self.state, attempt_id="attempt", expected_epoch=finished["epoch"])
            self.assertIsNone(runtime.status(self.state, "attempt")["attempt"]["accepted_at"])

    def test_completed_result_reuse_does_not_launch_and_checks_delivery_fields_again(self) -> None:
        forged = {**_R1, "data": {**_R1["data"], "delivery_fingerprint": "b" * 64, "audit_transition": {"pass_id": "forged"}}}
        command = self.child_command(output="```json\n" + json.dumps(forged) + "\n```\n")
        self.launch(command)
        finished = runtime.wait_for_result(self.state, "attempt", 5)
        self.assertEqual(finished["attempt"]["state"], "completed")
        gate = {"next_action": "complete", "gate_id": 2, "input_fingerprint": self.fingerprint}
        native_popen = subprocess.Popen

        def forbid_worker(argv, *args, **kwargs):
            if argv[0] == "git":
                return native_popen(argv, *args, **kwargs)
            raise AssertionError("reuse spawned a child")

        with mock.patch.object(runtime, "_gate", return_value=gate), mock.patch.object(runtime.subprocess, "Popen", side_effect=forbid_worker):
            reused = runtime.launch(
                state_path=self.state,
                ledger_state=self.ledger,
                attempt_id="attempt",
                role="makato-build:build-review",
                fingerprint=self.fingerprint,
                expected_epoch=finished["epoch"],
                next_action=None,
                gate_event="initial",
                worktree=self.root,
                review_base="HEAD",
                command=command,
                cwd=self.root,
                env=self.env,
                contract_paths=self.contracts,
                invocation_sha256=hashlib.sha256(b"attempt").hexdigest(),
            )
            self.assertEqual(reused["attempt"]["state"], "completed")
            with self.assertRaisesRegex(runtime.RuntimeErrorState, "audit transition"):
                runtime.accept(state_path=self.state, attempt_id="attempt", expected_epoch=reused["epoch"])
        self.assertIsNone(runtime.status(self.state, "attempt")["attempt"]["accepted_at"])

    def test_darwin_inventory_observer_does_not_hold_result_or_writer_fence(self) -> None:
        supervisor = r"""import os, subprocess, sys, time, types
from pathlib import Path
sys.path.insert(0, sys.argv[2])
import review_runtime as r
native_run = subprocess.run
# Emit real process identities, including the inspector before it exits.
inspector = (
    "import os; "
    "print(os.getppid(), os.getpgid(os.getppid()), 'S'); "
    "print(os.getpid(), os.getpgrp(), 'R')"
)
def inspect(command, **kwargs):
    if command == ["ps", "-axo", "pid=,pgid=,stat="]:
        return native_run([sys.executable, "-c", inspector], **kwargs)
    return native_run(command, **kwargs)
def pending(_seconds):
    raise RuntimeError("exited inventory observer held the worker group")
r.sys = types.SimpleNamespace(platform="darwin")
r.subprocess.run = inspect
# The child has exited and there are no descendants. Bound a broken wait
# deterministically instead of relying on a timeout to detect the regression.
r.time = types.SimpleNamespace(monotonic=time.monotonic, sleep=pending)
raise SystemExit(r._run_worker(Path(sys.argv[1])))
"""
        for attempt_id, output, result_status, protocol_error in (
            ("valid", "```json\n" + json.dumps(_R1) + "\n```", "success", None),
            ("empty", "", None, "empty_return"),
        ):
            with self.subTest(attempt_id=attempt_id):
                attempt_dir = self.root / attempt_id
                attempt_dir.mkdir()
                writer_lock = self.root / "worktree-writer.lock"
                receipt_path = attempt_dir / "exit-receipt.json"
                descriptor = attempt_dir / "launch.json"
                runtime._write_json(attempt_dir / "start", {"runtime_env": {}})
                runtime._write_json(
                    descriptor,
                    {
                        "attempt_id": attempt_id,
                        "attempt_dir": str(attempt_dir),
                        "writer_lock": str(writer_lock),
                        "command": self.child_command(output=output),
                        "cwd": str(self.root),
                        "stdout_path": str(attempt_dir / "stdout.log"),
                        "result_path": str(attempt_dir / "result.json"),
                        "exit_receipt_path": str(receipt_path),
                        "worker_error_path": str(attempt_dir / "worker-error.json"),
                    },
                )
                finished = subprocess.run(
                    [sys.executable, "-c", supervisor, str(descriptor), str(_HERE)],
                    env=self.env | {"MAKATO_REVIEW_RUN_ID": attempt_id},
                    start_new_session=True,
                    capture_output=True,
                    text=True,
                    timeout=5,
                    check=False,
                )
                error_path = attempt_dir / "worker-error.json"
                detail = error_path.read_text() if error_path.exists() else finished.stderr
                self.assertEqual(finished.returncode, 0, detail)
                receipt = json.loads(receipt_path.read_text())
                self.assertEqual(receipt["exit_code"], 0)
                self.assertEqual(receipt["result_status"], result_status)
                self.assertEqual(receipt["protocol_error"], protocol_error)
                self.assertEqual(receipt["stdout_sha256"], hashlib.sha256(output.encode()).hexdigest())
                if result_status is not None:
                    self.assertEqual(json.loads((attempt_dir / "result.json").read_text()), _R1)
                self.assertFalse(writer_lock.with_suffix(".owner.json").exists())

    def test_reconcile_before_child_authorization_preserves_the_active_attempt_fence(self) -> None:
        import review_loop
        import review_scope

        (self.root / "src.py").write_text("value = 1\n")
        subprocess.run(["git", "-C", str(self.root), "add", "src.py"], check=True, capture_output=True)
        subprocess.run(["git", "-C", str(self.root), "-c", "user.name=Runtime Test", "-c", "user.email=test@example.invalid", "commit", "-qm", "base"], check=True, capture_output=True)
        self.state = self.root / ".git" / "review" / "runtime.json"
        self.ledger = self.state.with_name("ledger.json")
        review_loop.init(str(self.ledger), "AUTH", "HEAD")
        ready = self.state.with_name("ready")
        release = self.state.with_name("release")
        context = self.state.with_name("context")
        context.parent.mkdir(parents=True, exist_ok=True)
        context.write_text("authorized context\n")
        command = r"""import json, os, sys, time
from pathlib import Path
sys.path.insert(0, sys.argv[1])
import review_runtime as runtime
ready, release, context = map(Path, sys.argv[2:5])
ready.touch()
deadline = time.monotonic() + 10
while not release.exists() and time.monotonic() < deadline:
    time.sleep(.01)
assert release.exists(), "coordinator never released authorization"
kwargs = dict(
    state_path=os.environ["MAKATO_REVIEW_RUNTIME_STATE"],
    attempt_id=os.environ["MAKATO_REVIEW_ATTEMPT_ID"],
    run_identity=os.environ["MAKATO_REVIEW_RUN_ID"],
    invocation_sha256=os.environ["MAKATO_REVIEW_INVOCATION_SHA256"],
    context_path=context,
    expected_epoch=int(os.environ["MAKATO_REVIEW_RUNTIME_EPOCH"]),
)
# Observation may advance the coordinator epoch, but cannot replace the owner token.
for replacement in (
    {"expected_epoch": kwargs["expected_epoch"] + 1},
    {"run_identity": "foreign-run"},
    {"invocation_sha256": "f" * 64},
    {"context_path": None},
):
    try:
        runtime.authorize_child(**(kwargs | replacement))
    except runtime.RuntimeErrorState:
        pass
    else:
        raise AssertionError(f"invalid authorization was accepted: {replacement}")
runtime.authorize_child(**kwargs)
print("```json\n" + sys.argv[5] + "\n```")
"""
        contracts = list(review_scope.REVIEW_CONTRACT_PATHS)
        fingerprint = review_scope.fingerprint(str(self.root), "HEAD", contract_paths=contracts, contract_root=str(self.build), orchestrate_root=str(self.orchestrate))["sha256"]
        launched = runtime.launch(
            state_path=self.state,
            ledger_state=self.ledger,
            attempt_id="preauthorize",
            role="build-review",
            fingerprint=fingerprint,
            expected_epoch=0,
            next_action="review",
            gate_event="initial",
            worktree=self.root,
            review_base="HEAD",
            command=[sys.executable, "-c", command, str(self.build / "shared"), str(ready), str(release), str(context), json.dumps(_R1)],
            cwd=self.root,
            env=self.env,
            context_path=context,
            invocation_sha256="b" * 64,
            contract_paths=contracts,
        )
        self.addCleanup(self.stop_owned_group, launched["attempt"])
        self.wait_until(ready.exists)
        start = json.loads((self.state.parent / "attempts" / "preauthorize" / "start").read_text())
        owner_epoch = int(start["runtime_env"]["MAKATO_REVIEW_RUNTIME_EPOCH"])
        reconciled = runtime.reconcile(state_path=self.state, attempt_id="preauthorize", expected_epoch=launched["epoch"])
        self.assertEqual(reconciled["decision"], "running")
        self.assertGreater(reconciled["epoch"], owner_epoch)
        self.assertEqual(reconciled["attempt"]["ownership_epoch"], owner_epoch)
        with self.assertRaisesRegex(runtime.RuntimeErrorState, "stale runtime epoch"):
            runtime.cancel(state_path=self.state, attempt_id="preauthorize", expected_epoch=owner_epoch)
        release.touch()
        finished = runtime.wait_for_result(self.state, "preauthorize", 5)
        output = Path(finished["attempt"]["stdout_path"]).read_text()
        self.assertEqual(finished["attempt"]["state"], "completed", output)
        self.assertEqual(finished["attempt"]["exit_code"], 0)

    def test_child_authorization_rejects_an_explicitly_revoked_continuation(self) -> None:
        state = runtime._initial_state()
        state["epoch"] = 3
        state["attempts"]["revoked"] = {
            "attempt_id": "revoked",
            "state": "running",
            "ownership_epoch": 3,
            "run_identity": "owned-run",
            "pid": os.getpid(),
            "continuation_blocked_reason": "current invocation/context digest differs from the authorized attempt",
            "contract_root": str(self.build),
            "orchestrate_root": str(self.orchestrate),
            "root_bindings": review_scope.root_bindings(self.build, self.orchestrate),
            "contract_paths": self.contracts,
        }
        runtime._write_json(self.state, state)
        with mock.patch.object(runtime, "_matches_identity", side_effect=AssertionError("revoked continuation reached process authorization")):
            with self.assertRaises(runtime.RuntimeErrorState):
                runtime.authorize_child(
                    state_path=self.state,
                    attempt_id="revoked",
                    run_identity="owned-run",
                    invocation_sha256="b" * 64,
                    context_path=None,
                    expected_epoch=3,
                )

    def test_caller_process_can_exit_and_new_coordinator_adopts_same_durable_result(self) -> None:
        published = {**_R1, "data": {**_R1["data"], "delivery_fingerprint": "b" * 64, "audit_transition": {"schema": "review-audit-transition-v1"}}}
        output = "```json\n" + json.dumps(published) + "\n```\n"
        child = self.child_command(delay=0.25, output=output)
        coordinator = r"""import json, os, sys
import review_runtime as r
fp = "a" * 64
r._gate = lambda **kw: {"next_action": "review", "reason": "eligible", "gate_id": 1, "input_fingerprint": fp}
receipt = r.launch(
    state_path=os.environ["RUNTIME_STATE"], ledger_state=os.environ["LEDGER_STATE"],
    attempt_id="parent-died", role="makato-build:build-review", fingerprint=fp,
    expected_epoch=0, next_action="review", gate_event="initial",
    worktree=os.environ["WORKTREE"], review_base="HEAD",
    command=json.loads(os.environ["CHILD_ARGV"]), cwd=os.environ["WORKTREE"],
    env=os.environ, invocation_sha256="b" * 64, contract_paths=__import__("review_scope").REVIEW_CONTRACT_PATHS)
print(json.dumps(receipt), flush=True)
os._exit(0)
"""
        env = self.env | {
            "PYTHONPATH": str(self.build / "shared"),
            "RUNTIME_STATE": str(self.state),
            "LEDGER_STATE": str(self.ledger),
            "WORKTREE": str(self.root),
            "CHILD_ARGV": json.dumps(child),
        }
        exited = subprocess.run(
            [sys.executable, "-c", coordinator],
            env=env,
            cwd=self.root,
            capture_output=True,
            text=True,
            check=True,
            timeout=5,
        )
        self.assertEqual(json.loads(exited.stdout)["decision"], "launched")

        completed = runtime.wait_for_result(self.state, "parent-died", 5)
        self.assertEqual(completed["attempt"]["state"], "completed")
        self.assertEqual(completed["attempt"]["result_status"], "success")
        invocation = "b" * 64
        with mock.patch.object(
            runtime,
            "_gate",
            return_value={
                "next_action": "certify",
                "reason": "fresh gate after completion",
                "gate_id": 2,
                "input_fingerprint": self.fingerprint,
            },
        ):
            reconciled = runtime.reconcile(
                state_path=self.state,
                attempt_id="parent-died",
                expected_epoch=completed["epoch"],
                invocation_sha256=invocation,
            )
        self.assertEqual((reconciled["decision"], reconciled["next_action"]), ("completed", "certify"))
        with mock.patch.object(
            runtime,
            "_gate",
            return_value={
                "next_action": "complete",
                "gate_id": 3,
                "input_fingerprint": self.fingerprint,
                "delivery_fingerprint": published["data"]["delivery_fingerprint"],
                "audit_transition": published["data"]["audit_transition"],
            },
        ):
            accepted = runtime.accept(
                state_path=self.state,
                attempt_id="parent-died",
                expected_epoch=reconciled["epoch"],
                invocation_sha256=invocation,
            )
            accepted_again = runtime.accept(
                state_path=self.state,
                attempt_id="parent-died",
                expected_epoch=accepted["epoch"],
                invocation_sha256=invocation,
            )
        self.assertEqual(accepted["result"], published)
        self.assertEqual(accepted_again["attempt"]["accepted_at"], accepted["attempt"]["accepted_at"])

    def test_competing_coordinators_are_epoch_fenced_to_one_child(self) -> None:
        count = self.root / "writers.txt"
        script = ("from pathlib import Path; import time; p=Path(%r); time.sleep(.2); p.write_text(str(int(p.read_text())+1) if p.exists() else '1')") % str(count)
        command = [sys.executable, "-c", script]
        barrier = threading.Barrier(2)

        def coordinator() -> str:
            barrier.wait()
            try:
                self.launch(command, expected_epoch=0)
                return "launched"
            except runtime.RuntimeErrorState:
                return "fenced"

        with mock.patch.object(runtime, "_gate", side_effect=self.gate):
            with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
                outcomes = [future.result(timeout=5) for future in [pool.submit(coordinator), pool.submit(coordinator)]]
        self.assertCountEqual(outcomes, ["launched", "fenced"])
        finished = runtime.wait_for_result(self.state, "attempt", 5)
        self.assertEqual(finished["attempt"]["state"], "blocked")
        self.assertEqual(count.read_text(), "1")

    def test_empty_and_malformed_returns_block_instead_of_succeeding(self) -> None:
        cases = (("empty", ""), ("malformed", "not an R1"))
        for attempt_id, transcript in cases:
            with self.subTest(attempt_id=attempt_id):
                self.launch(self.child_command(output=transcript), attempt_id=attempt_id)
                result = runtime.wait_for_result(self.state, attempt_id, 5)
                self.assertEqual(result["attempt"]["state"], "blocked")
                self.assertIn(result["attempt"]["protocol_error"], {"empty_return", "missing_fenced_r1"})
                with self.assertRaises(runtime.RuntimeErrorState):
                    runtime.accept(state_path=self.state, attempt_id=attempt_id, expected_epoch=result["epoch"])
                runtime.cancel(state_path=self.state, attempt_id=attempt_id, expected_epoch=result["epoch"], grace_seconds=0)

    def test_receipt_waits_for_orphan_writer_and_other_ledger_cannot_start_a_writer(self) -> None:
        marker = self.root / "descendant-finished"
        started = self.root / "descendant-started"
        orphan = f"from pathlib import Path; import time; Path({str(started)!r}).touch(); time.sleep(.7); Path({str(marker)!r}).write_text('done')"
        body = f"import subprocess, sys; subprocess.Popen([sys.executable, '-c', {orphan!r}]); print({'```json' + chr(10) + json.dumps(_R1) + chr(10) + '```'!r})"
        self.launch([sys.executable, "-c", body])
        deadline = time.monotonic() + 5
        while not started.exists() and time.monotonic() < deadline:
            time.sleep(0.01)
        self.assertTrue(started.exists())
        early = runtime.wait_for_result(self.state, "attempt", 0.02)
        self.assertEqual(early["attempt"]["state"], "running")
        forbidden = self.root / "duplicate-writer"
        alternate = self.root / "other" / "runtime.json"
        with mock.patch.object(runtime, "_gate", side_effect=self.gate):
            runtime.launch(
                state_path=alternate,
                ledger_state=self.root / "other-ledger.json",
                attempt_id="other-ledger",
                role="build-review",
                fingerprint=self.fingerprint,
                expected_epoch=0,
                next_action="review",
                gate_event="initial",
                worktree=self.root,
                review_base="HEAD",
                cwd=self.root,
                env=self.env,
                contract_paths=self.contracts,
                command=[sys.executable, "-c", f"from pathlib import Path; Path({str(forbidden)!r}).touch()"],
            )
        denied = runtime.wait_for_result(alternate, "other-ledger", 5)
        self.assertEqual(denied["attempt"]["state"], "blocked")
        self.assertFalse(forbidden.exists())
        finished = runtime.wait_for_result(self.state, "attempt", 5)
        self.assertEqual(finished["attempt"]["state"], "completed")
        self.assertEqual(marker.read_text(), "done")

    def test_killed_worker_keeps_cross_ledger_writer_fenced_until_orphan_group_exits(self) -> None:
        started = self.root / "orphan-started"
        parent_pid = self.root / "parent-pid"
        release = self.root / "release-orphan"
        edited = self.root / "writer-output"
        edited.write_text("original")
        orphan = f"""import os, time
from pathlib import Path
os.closerange(3, 256)
Path({str(started)!r}).write_text(str(os.getpid()))
deadline = time.monotonic() + 20
while not Path({str(release)!r}).exists() and time.monotonic() < deadline:
    time.sleep(.01)
if Path({str(release)!r}).exists():
    Path({str(edited)!r}).write_text("old writer")
"""
        transcript = "```json\n" + json.dumps(_R1) + "\n```"
        body = (
            "import os, subprocess, sys; from pathlib import Path; "
            f"Path({str(parent_pid)!r}).write_text(str(os.getpid())); "
            f"subprocess.Popen([sys.executable, '-c', {orphan!r}], close_fds=True); "
            f"print({transcript!r})"
        )
        launched = self.launch([sys.executable, "-c", body])
        owned = launched["attempt"]
        self.addCleanup(self.stop_owned_group, owned)
        self.wait_until(started.exists)
        self.wait_until(lambda: runtime._proc_start_token(int(parent_pid.read_text())) is None)
        owner_path = self.root / ".git" / "makato-review-loop" / "worktree-writer.owner.json"
        owner = json.loads(owner_path.read_text())
        self.assertEqual(owner["run_identity"], owned["run_identity"])
        self.assertEqual(owner["start_token"], owned["start_token"])
        self.assertTrue(runtime._matches_identity(owned))
        os.kill(owned["pid"], signal.SIGKILL)
        self.wait_until(lambda: runtime._proc_start_token(owned["pid"]) is None)
        self.assertTrue(runtime._owned_group_alive(owned))
        self.assertFalse(Path(owned["exit_receipt_path"]).exists())

        alternate = self.root / "other" / "runtime.json"
        other_ledger = self.root / "other-ledger.json"
        forbidden = self.root / "competing-writer-started"
        command = [
            sys.executable,
            "-c",
            f"from pathlib import Path; Path({str(forbidden)!r}).touch(); Path({str(edited)!r}).write_text('competing writer')",
        ]
        self.launch(command, attempt_id="denied", state_path=alternate, ledger_state=other_ledger)
        denied = runtime.wait_for_result(alternate, "denied", 5)
        self.assertEqual(denied["attempt"]["state"], "blocked")
        self.wait_until(lambda: not runtime._owned_group_alive(denied["attempt"]))
        self.assertFalse(forbidden.exists())
        self.assertEqual(edited.read_text(), "original")
        self.assertEqual(json.loads(owner_path.read_text()), owner)

        release.touch()
        self.wait_until(lambda: not runtime._owned_group_alive(owned))
        self.assertEqual(edited.read_text(), "old writer")
        dead = runtime.wait_for_result(self.state, "attempt", 5)
        self.assertEqual(dead["attempt"]["state"], "blocked")
        with mock.patch.object(runtime, "_signal_owned", side_effect=AssertionError("dead groups must not be signaled")):
            canceled_dead = runtime.cancel(state_path=self.state, attempt_id="attempt", expected_epoch=dead["epoch"])
            denied = runtime.status(alternate, "denied")
            canceled_denied = runtime.cancel(state_path=alternate, attempt_id="denied", expected_epoch=denied["epoch"])
        self.assertEqual(canceled_dead["decision"], "canceled")
        self.assertEqual(canceled_denied["decision"], "canceled")
        self.assertEqual(json.loads(owner_path.read_text()), owner)

        fresh_marker = self.root / "fresh-writer"
        fresh_command = [
            sys.executable,
            "-c",
            f"from pathlib import Path; Path({str(fresh_marker)!r}).touch(); print({transcript!r})",
        ]
        self.launch(fresh_command, attempt_id="fresh", state_path=alternate, ledger_state=other_ledger)
        fresh = runtime.wait_for_result(alternate, "fresh", 5)
        self.assertEqual(fresh["attempt"]["state"], "completed")
        self.assertTrue(fresh_marker.exists())
        self.assertFalse(forbidden.exists())
        self.wait_until(lambda: not owner_path.exists())

    def test_worker_spawn_failure_can_be_canceled_without_identity_or_signals(self) -> None:
        popen = subprocess.Popen

        def fail_worker(command, *args, **kwargs):
            if "_worker" in command:
                raise OSError("controlled worker spawn failure")
            return popen(command, *args, **kwargs)

        with mock.patch.object(runtime.subprocess, "Popen", side_effect=fail_worker):
            with self.assertRaisesRegex(runtime.RuntimeErrorState, "durable worker could not start"):
                self.launch(self.child_command())
        failed = runtime.status(self.state, "attempt")
        self.assertEqual(failed["attempt"]["state"], "blocked")
        self.assertIsNone(failed["attempt"]["pid"])
        self.assertFalse(Path(failed["attempt"]["exit_receipt_path"]).exists())
        with self.assertRaisesRegex(runtime.RuntimeErrorState, "stale runtime epoch"):
            runtime.cancel(state_path=self.state, attempt_id="attempt", expected_epoch=failed["epoch"] - 1)
        with mock.patch.object(runtime, "_signal_owned", side_effect=AssertionError("no identity must not be signaled")):
            canceled = runtime.cancel(state_path=self.state, attempt_id="attempt", expected_epoch=failed["epoch"])
        self.assertEqual(canceled["decision"], "canceled")
        self.assertTrue((self.state.parent / "attempts" / "attempt" / "abort").exists())
        self.launch(self.child_command(), attempt_id="fresh")
        self.assertEqual(runtime.wait_for_result(self.state, "fresh", 5)["attempt"]["state"], "completed")

    def test_child_spawn_failure_without_receipt_can_be_canceled_without_signals(self) -> None:
        launched = self.launch([str(self.root / "nonexistent-command")])
        self.addCleanup(self.stop_owned_group, launched["attempt"])
        failed = runtime.wait_for_result(self.state, "attempt", 5)
        self.assertEqual(failed["attempt"]["state"], "blocked")
        self.wait_until(lambda: not runtime._owned_group_alive(failed["attempt"]))
        self.assertFalse(Path(failed["attempt"]["exit_receipt_path"]).exists())
        with mock.patch.object(runtime, "_signal_owned", side_effect=AssertionError("dead worker must not be signaled")):
            canceled = runtime.cancel(state_path=self.state, attempt_id="attempt", expected_epoch=failed["epoch"])
        self.assertEqual(canceled["decision"], "canceled")
        self.launch(self.child_command(), attempt_id="fresh")
        self.assertEqual(runtime.wait_for_result(self.state, "fresh", 5)["attempt"]["state"], "completed")

    def test_preactivation_gate_and_halt_denials_allow_metadata_cancellation(self) -> None:
        for halt in (False, True):
            with self.subTest(halt=halt):
                eligible = self.gate()
                calls = 0

                def change_gate(**_kwargs):
                    nonlocal calls
                    calls += 1
                    if calls == 2:
                        if halt:
                            self.halt_file.touch()
                        else:
                            return {**eligible, "next_action": "blocked", "reason": "controlled gate change"}
                    return eligible

                attempt_id = f"preactivation-{halt}"
                forbidden = self.root / attempt_id
                with mock.patch.object(self, "gate", side_effect=change_gate):
                    blocked = self.launch(
                        [sys.executable, "-c", f"from pathlib import Path; Path({str(forbidden)!r}).touch()"],
                        attempt_id=attempt_id,
                    )
                self.addCleanup(self.stop_owned_group, blocked["attempt"])
                self.assertEqual(blocked["decision"], "blocked")
                self.wait_until(lambda: not runtime._owned_group_alive(blocked["attempt"]))
                self.assertFalse(forbidden.exists())
                self.assertFalse(Path(blocked["attempt"]["exit_receipt_path"]).exists())
                with mock.patch.object(runtime, "_signal_owned", side_effect=AssertionError("denied worker must not be signaled")):
                    canceled = runtime.cancel(state_path=self.state, attempt_id=attempt_id, expected_epoch=blocked["epoch"])
                self.assertEqual(canceled["decision"], "canceled")
                if halt:
                    self.halt_file.unlink()
        self.launch(self.child_command(), attempt_id="fresh")
        self.assertEqual(runtime.wait_for_result(self.state, "fresh", 5)["attempt"]["state"], "completed")

    def test_durable_writer_owner_blocks_live_reused_or_unobservable_groups(self) -> None:
        owner_path = self.root / "worktree-writer.owner.json"
        previous = {
            "schema": runtime.SCHEMA,
            "attempt_id": "old",
            "pid": 987654,
            "pgid": 987654,
            "start_token": "old-token",
            "run_identity": "old-run",
        }
        runtime._write_json(owner_path, previous)
        identity = {"pid": 987655, "pgid": 987655, "start_token": "new-token", "run_identity": "new-run"}
        for members, all_owned in (([987654], True), ([987654], False), ([], False)):
            with self.subTest(members=members, all_owned=all_owned):
                with mock.patch.object(runtime, "_group_members", return_value=(members, all_owned)):
                    with self.assertRaisesRegex(runtime.RuntimeErrorState, "prior writer process group"):
                        runtime._claim_writer_owner(owner_path, identity, "new")
                self.assertEqual(json.loads(owner_path.read_text()), previous)

    def test_writer_cleanup_cannot_clear_new_owner_or_live_descendants(self) -> None:
        owner_path = self.root / "worktree-writer.owner.json"
        owner = {
            "schema": runtime.SCHEMA,
            "attempt_id": "current",
            "pid": os.getpid(),
            "pgid": os.getpid(),
            "start_token": "current-token",
            "run_identity": "current-run",
        }
        runtime._write_json(owner_path, owner)
        runtime._clear_writer_owner(owner_path, {**owner, "run_identity": "stale-run"})
        self.assertEqual(json.loads(owner_path.read_text()), owner)
        with mock.patch.object(runtime, "_matches_identity", return_value=True):
            with mock.patch.object(runtime, "_group_members", return_value=([os.getpid(), os.getpid() + 1], True)):
                runtime._clear_writer_owner(owner_path, owner)
            self.assertEqual(json.loads(owner_path.read_text()), owner)
            with mock.patch.object(runtime, "_group_members", return_value=([os.getpid()], True)):
                runtime._clear_writer_owner(owner_path, owner)
        self.assertFalse(owner_path.exists())

    def test_wait_timeout_keeps_child_alive_and_cancel_is_identity_checked(self) -> None:
        self.launch([sys.executable, "-c", "import time; time.sleep(10)"])
        timed_out = runtime.wait_for_result(self.state, "attempt", 0.02)
        self.assertTrue(timed_out["timed_out"])
        self.assertEqual(timed_out["attempt"]["state"], "running")
        current = runtime.status(self.state, "attempt")
        canceled = runtime.cancel(
            state_path=self.state,
            attempt_id="attempt",
            expected_epoch=current["epoch"],
            grace_seconds=0.2,
        )
        self.assertEqual(canceled["decision"], "canceled")

    def test_halt_prevents_launch_without_creating_a_child(self) -> None:
        self.halt_file.touch()
        marker = self.root / "forbidden-child"
        with self.assertRaises(runtime.RuntimeErrorState):
            self.launch([sys.executable, "-c", f"from pathlib import Path; Path({str(marker)!r}).touch()"])
        self.assertFalse(marker.exists())
        self.assertFalse(self.state.exists())

    def test_cancel_refuses_a_live_unrelated_process_even_with_a_matching_start_token(self) -> None:
        self.launch([sys.executable, "-c", "import time; time.sleep(30)"])
        original = json.loads(self.state.read_text())
        unrelated = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)"], start_new_session=True)
        self.addCleanup(unrelated.wait)
        self.addCleanup(unrelated.terminate)
        try:
            forged = json.loads(self.state.read_text())
            forged["attempts"]["attempt"].update(
                {
                    "pid": unrelated.pid,
                    "pgid": unrelated.pid,
                    "start_token": runtime._proc_start_token(unrelated.pid),
                }
            )
            self.state.write_text(json.dumps(forged))
            with self.assertRaises(runtime.RuntimeErrorState):
                runtime.cancel(
                    state_path=self.state,
                    attempt_id="attempt",
                    expected_epoch=forged["epoch"],
                    grace_seconds=0,
                )
            self.assertIsNone(unrelated.poll())
        finally:
            current = json.loads(self.state.read_text())
            current["attempts"]["attempt"] = original["attempts"]["attempt"]
            self.state.write_text(json.dumps(current))
            runtime.cancel(state_path=self.state, attempt_id="attempt", expected_epoch=current["epoch"], grace_seconds=0.2)


if __name__ == "__main__":
    unittest.main()
