"""Behavioral tests for durable review process ownership and recovery."""

from __future__ import annotations

import concurrent.futures
import hashlib
import json
import os
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

import review_runtime as runtime  # noqa: E402

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
        self.env = os.environ.copy()
        self.env["MAKATO_HALT_FILE"] = str(self.halt_file)

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

    def test_caller_process_can_exit_and_new_coordinator_adopts_same_durable_result(self) -> None:
        output = "```json\n" + json.dumps(_R1) + "\n```\n"
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
    env=os.environ, invocation_sha256="b" * 64)
print(json.dumps(receipt), flush=True)
os._exit(0)
"""
        env = self.env | {
            "PYTHONPATH": str(_HERE),
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
        self.assertEqual(accepted["result"], _R1)
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
