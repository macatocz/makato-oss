"""Crash-recoverable, fenced process runtime for build-review dispatches.

The runtime owns only its private checkpoint and child process group. It never
interprets a process exit as a successful review: a valid R1 result and the
review ledger's gate are both required by the caller.
"""

from __future__ import annotations

import argparse
import contextlib
import fcntl
import hashlib
import json
import os
import re
import signal
import subprocess
import sys
import tempfile
import threading
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterator, Mapping, Sequence

VERSION = 1
SCHEMA = "review-runtime.v1"
DEFAULT_POLL_SECONDS = 0.1
MAX_WAIT_SECONDS = 3600
_STARTUP_TIMEOUT_SECONDS = 30.0
_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$")
_FINGERPRINT = re.compile(r"^[0-9a-f]{64}$")
_ACTIONS = frozenset({"review", "confirm", "repair-local", "redesign", "certify"})
_GATE_EVENTS = frozenset({"initial", "review", "confirm", "repair-local", "redesign", "certify"})
_ATTEMPT_STATES = frozenset({"preparing", "running", "completed", "blocked", "canceled"})
_R1_REQUIRED = ("schema", "agent", "status", "summary", "files_changed", "tests_written", "errors", "tool_calls_used", "data")
_R1_STATUS = frozenset({"success", "partial", "failure"})
_R1_BLOCK = re.compile(r"```json\s*\n(.*?)\n```", re.DOTALL)


class RuntimeErrorState(RuntimeError):
    """The checkpoint or process state is unsafe to continue."""


def _now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def _assert_not_halted(environ: Mapping[str, str] | None = None) -> None:
    values = os.environ if environ is None else environ
    halt_file = Path(values.get("MAKATO_HALT_FILE", str(Path.home() / ".claude" / "HALT"))).expanduser()
    if halt_file.exists():
        raise RuntimeErrorState(f"HALT file present at {halt_file}; refusing a new review launch")


def _private_dir(path: Path) -> None:
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    if path.is_symlink() or not path.is_dir():
        raise RuntimeErrorState(f"runtime directory is not a real directory: {path}")
    os.chmod(path, 0o700)


def _write_atomic(path: Path, payload: bytes) -> None:
    _private_dir(path.parent)
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temp_path = Path(temporary)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "wb", closefd=True) as stream:
            stream.write(payload)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temp_path, path)
        os.chmod(path, 0o600)
        directory_fd = os.open(path.parent, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    except BaseException:
        with contextlib.suppress(FileNotFoundError):
            temp_path.unlink()
        raise


def _write_json(path: Path, value: Mapping[str, Any]) -> None:
    _write_atomic(path, (json.dumps(value, ensure_ascii=False, sort_keys=True) + "\n").encode("utf-8"))


def _initial_state() -> dict[str, Any]:
    return {"version": VERSION, "epoch": 0, "next_action": "review", "attempts": {}, "updated_at": _now()}


def _read_state(path: Path, *, absent_ok: bool = False) -> dict[str, Any]:
    try:
        raw = path.read_bytes()
    except FileNotFoundError:
        if absent_ok:
            return _initial_state()
        raise RuntimeErrorState(f"runtime checkpoint is missing: {path}") from None
    try:
        state = json.loads(raw)
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise RuntimeErrorState(f"runtime checkpoint is malformed: {exc}") from exc
    if not isinstance(state, dict) or state.get("version") != VERSION:
        version = state.get("version") if isinstance(state, dict) else "unknown"
        raise RuntimeErrorState(f"incompatible runtime checkpoint version {version!r}; explicit migration is required")
    if not isinstance(state.get("epoch"), int) or isinstance(state.get("epoch"), bool) or not isinstance(state.get("attempts"), dict):
        raise RuntimeErrorState("runtime checkpoint has an invalid epoch or attempts map")
    if state.get("next_action") not in _ACTIONS | {"complete", "blocked"}:
        raise RuntimeErrorState("runtime checkpoint has an unknown next_action")
    for attempt_id, attempt in state["attempts"].items():
        if not isinstance(attempt_id, str) or not _ID.fullmatch(attempt_id) or not isinstance(attempt, dict):
            raise RuntimeErrorState("runtime checkpoint contains a malformed attempt")
        if attempt.get("attempt_id") != attempt_id or attempt.get("state") not in _ATTEMPT_STATES:
            raise RuntimeErrorState(f"runtime checkpoint attempt {attempt_id!r} has an unknown identity or state")
    return state


@contextlib.contextmanager
def _locked(path: Path, *, create: bool = True) -> Iterator[dict[str, Any]]:
    path = path.expanduser().absolute()
    if create:
        _private_dir(path.parent)
    elif not path.parent.exists() or not path.exists():
        yield _initial_state()
        return
    lock_path = path.with_name(path.name + ".lock")
    flags = os.O_CREAT | os.O_RDWR | getattr(os, "O_NOFOLLOW", 0)
    fd = os.open(lock_path, flags, 0o600)
    try:
        os.fchmod(fd, 0o600)
        fcntl.flock(fd, fcntl.LOCK_EX)
        yield _read_state(path, absent_ok=create)
    finally:
        fcntl.flock(fd, fcntl.LOCK_UN)
        os.close(fd)


def _save(path: Path, state: dict[str, Any]) -> None:
    state["epoch"] += 1
    state["updated_at"] = _now()
    _write_json(path, state)


def _attempt_dir(state_path: Path, attempt_id: str) -> Path:
    if not _ID.fullmatch(attempt_id) or attempt_id in {".", ".."}:
        raise RuntimeErrorState("attempt id must be 1–128 safe ASCII characters")
    return state_path.parent / "attempts" / attempt_id


def _proc_start_token(pid: int) -> str | None:
    if sys.platform == "darwin":
        result = subprocess.run(["ps", "-p", str(pid), "-o", "lstart="], capture_output=True, text=True, timeout=2, check=False, env={**os.environ, "LC_ALL": "C"})
        return result.stdout.strip() if result.returncode == 0 and result.stdout.strip() else None
    try:
        stat = Path(f"/proc/{pid}/stat").read_text(encoding="ascii")
    except (FileNotFoundError, PermissionError, ProcessLookupError):
        return None
    end = stat.rfind(")")
    if end < 0:
        return None
    fields = stat[end + 2 :].split()
    if len(fields) <= 19:
        return None
    return fields[19]


def _run_identity_present(pid: int, run_identity: str) -> bool:
    if sys.platform == "darwin":
        result = subprocess.run(["ps", "eww", "-p", str(pid), "-o", "command="], capture_output=True, text=True, timeout=2, check=False)
        return result.returncode == 0 and re.search(rf"(?:^|[ \t])MAKATO_REVIEW_RUN_ID={re.escape(run_identity)}(?:[ \t]|$)", result.stdout) is not None
    try:
        environ = Path(f"/proc/{pid}/environ").read_bytes().split(b"\0")
    except (FileNotFoundError, PermissionError, ProcessLookupError):
        return False
    expected = f"MAKATO_REVIEW_RUN_ID={run_identity}".encode("ascii")
    return expected in environ


def _identity(pid: int, run_identity: str) -> dict[str, Any] | None:
    token = _proc_start_token(pid)
    if token is None:
        return None
    try:
        pgid = os.getpgid(pid)
    except ProcessLookupError:
        return None
    if pgid != pid or not _run_identity_present(pid, run_identity):
        return None
    return {"pid": pid, "pgid": pgid, "start_token": token, "run_identity": run_identity}


def _group_members(pgid: int, run_identity: str) -> tuple[list[int], bool]:
    """Return owned members and whether every member of this PGID is ours."""
    members: list[int] = []
    all_owned = True
    if sys.platform == "darwin":
        result = subprocess.run(["ps", "-axo", "pid=,pgid=,stat="], capture_output=True, text=True, timeout=2, check=False)
        if result.returncode:
            return [], False
        for line in result.stdout.splitlines():
            values = line.split()
            if len(values) != 3 or not values[0].isdigit() or not values[1].isdigit():
                all_owned = False
                continue
            if int(values[1]) != pgid or values[2].startswith(("Z", "X")):
                continue
            members.append(int(values[0]))
            all_owned = all_owned and _run_identity_present(int(values[0]), run_identity)
        return members, all_owned
    try:
        proc_entries = tuple(Path("/proc").iterdir())
    except OSError:
        return [], False
    for entry in proc_entries:
        if not entry.name.isdigit():
            continue
        pid = int(entry.name)
        try:
            stat = (entry / "stat").read_text(encoding="ascii")
            end = stat.rfind(")")
            fields = stat[end + 2 :].split() if end >= 0 else []
            if len(fields) <= 2:
                all_owned = False
                continue
            if int(fields[2]) != pgid or fields[0] in {"Z", "X"}:
                continue
        except (FileNotFoundError, ProcessLookupError):
            continue
        except (PermissionError, ValueError):
            all_owned = False
            continue
        members.append(pid)
        if not _run_identity_present(pid, run_identity):
            all_owned = False
    return members, all_owned


def _matches_identity(attempt: Mapping[str, Any]) -> bool:
    pid = attempt.get("pid")
    pgid = attempt.get("pgid")
    token = attempt.get("start_token")
    run_identity = attempt.get("run_identity")
    if not isinstance(pid, int) or isinstance(pid, bool) or not isinstance(pgid, int) or isinstance(pgid, bool):
        return False
    if not isinstance(token, str) or not isinstance(run_identity, str):
        return False
    if _proc_start_token(pid) != token or not _run_identity_present(pid, run_identity):
        return False
    try:
        return os.getpgid(pid) == pgid == pid
    except ProcessLookupError:
        return False


def authorize_child(
    *,
    state_path: str | Path,
    attempt_id: str,
    run_identity: str,
    invocation_sha256: str,
    context_path: str | Path | None,
    expected_epoch: int,
) -> dict[str, Any]:
    """Recheck a runtime child against the fenced attempt before invoking OMP."""
    path = Path(state_path).expanduser().absolute()
    context_file = Path(context_path).expanduser().resolve() if context_path is not None else None
    try:
        context_sha = hashlib.sha256(context_file.read_bytes()).hexdigest() if context_file is not None else None
    except OSError as exc:
        raise RuntimeErrorState(f"authorized context is unavailable: {exc}") from exc
    _assert_not_halted()
    with _locked(path, create=False) as state:
        _require_epoch(state, expected_epoch)
        attempt = state["attempts"].get(attempt_id)
        if not isinstance(attempt, dict) or attempt.get("state") != "running" or attempt.get("ownership_epoch") != expected_epoch:
            raise RuntimeErrorState("runtime child has no active fenced durable attempt")
        pid = attempt.get("pid")
        if (
            attempt.get("run_identity") != run_identity
            or not _matches_identity(attempt)
            or not isinstance(pid, int)
            or os.getpgid(0) != attempt.get("pgid")
            or not _run_identity_present(os.getpid(), run_identity)
        ):
            raise RuntimeErrorState("runtime child process-group identity does not match the durable attempt")
        if attempt.get("invocation_sha256") != invocation_sha256:
            raise RuntimeErrorState("runtime child invocation differs from the authorized attempt")
        if attempt.get("context_path") != (str(context_file) if context_file is not None else None) or attempt.get("context_sha256") != context_sha:
            raise RuntimeErrorState("runtime child context changed after authorization")
        gate = _gate(
            ledger_state=Path(attempt["ledger_state"]),
            event=attempt["gate_event"],
            worktree=Path(attempt["worktree"]),
            review_base=attempt["review_base"],
            fingerprint=attempt["fingerprint"],
            soft_cap=attempt.get("soft_cap"),
            hard_cap=attempt.get("hard_cap"),
            context_paths=attempt.get("context_paths"),
            contract_paths=attempt.get("contract_paths"),
            evidence_root=attempt.get("evidence_root"),
            contract_root=attempt.get("contract_root"),
            expected_ac_ids=attempt.get("expected_ac_ids"),
        )
        if gate.get("next_action") != attempt.get("next_action") or gate.get("next_action") == "blocked":
            raise RuntimeErrorState(f"runtime child dispatch is no longer authorized by the review gate: {gate.get('reason', gate.get('next_action'))}")
        return gate


def _owned_group_alive(attempt: Mapping[str, Any]) -> bool:
    """Treat an unobservable group as live; only proven absence permits reuse."""
    pgid = attempt.get("pgid")
    run_identity = attempt.get("run_identity")
    if pgid is None and attempt.get("pid") is None and attempt.get("start_token") is None:
        return False
    if not isinstance(pgid, int) or isinstance(pgid, bool) or pgid <= 1 or not isinstance(run_identity, str):
        return True
    members, all_owned = _group_members(pgid, run_identity)
    return bool(members) or not all_owned


def _validate_r1(data: bytes) -> tuple[dict[str, Any] | None, str | None]:
    if not data.strip():
        return None, "empty_return"
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError:
        return None, "invalid_utf8_return"
    blocks = _R1_BLOCK.findall(text)
    if not blocks:
        return None, "missing_fenced_r1"
    try:
        envelope = json.loads(blocks[-1])
    except json.JSONDecodeError:
        return None, "malformed_r1_json"
    if not isinstance(envelope, dict):
        return None, "malformed_r1_object"
    missing = [field for field in _R1_REQUIRED if field not in envelope]
    if missing:
        return None, "malformed_r1_missing:" + ",".join(missing)
    if envelope.get("schema") != "r1" or envelope.get("status") not in _R1_STATUS:
        return None, "malformed_r1_schema_or_status"
    if not isinstance(envelope.get("agent"), str) or not envelope["agent"].strip() or not isinstance(envelope.get("summary"), str):
        return None, "malformed_r1_identity_or_summary"
    for field in ("files_changed", "tests_written", "errors"):
        if not isinstance(envelope.get(field), list) or any(not isinstance(item, str) for item in envelope[field]):
            return None, f"malformed_r1_{field}"
    if not isinstance(envelope.get("tool_calls_used"), int) or isinstance(envelope["tool_calls_used"], bool) or envelope["tool_calls_used"] < 0:
        return None, "malformed_r1_tool_calls_used"
    if not isinstance(envelope.get("data"), dict):
        return None, "malformed_r1_data"
    return envelope, None


def _gate(
    *,
    ledger_state: Path,
    event: str,
    worktree: Path,
    review_base: str,
    fingerprint: str | None,
    soft_cap: int | None = None,
    hard_cap: int | None = None,
    context_paths: Sequence[str] | None = None,
    contract_paths: Sequence[str] | None = None,
    evidence_root: str | Path | None = None,
    contract_root: str | Path | None = None,
    expected_ac_ids: Sequence[str] | None = None,
) -> dict[str, Any]:
    if event not in _GATE_EVENTS:
        raise RuntimeErrorState(f"invalid review gate event: {event}")
    if fingerprint is not None and not _FINGERPRINT.fullmatch(fingerprint):
        raise RuntimeErrorState("input fingerprint must be a lowercase SHA-256")
    loop_cli = Path(__file__).with_name("review_loop.py")
    command = [sys.executable, str(loop_cli), "gate", "--state", str(ledger_state), "--event", event, "--worktree", str(worktree), "--review-base", review_base]
    if fingerprint is not None:
        command.extend(["--fingerprint", fingerprint])
    if soft_cap is not None:
        command.extend(["--soft-cap", str(soft_cap)])
    if hard_cap is not None:
        command.extend(["--hard-cap", str(hard_cap)])
    if evidence_root is not None:
        command.extend(["--evidence-root", str(Path(evidence_root).expanduser().resolve())])
    if contract_root is not None:
        command.extend(["--contract-root", str(Path(contract_root).expanduser().resolve())])
    if expected_ac_ids:
        normalized_ac_ids = sorted(set(expected_ac_ids))
        if len(normalized_ac_ids) != len(expected_ac_ids) or any(not item.strip() for item in normalized_ac_ids):
            raise RuntimeErrorState("expected AC ids must be distinct non-empty strings")
        command.extend(["--expected-ac-ids", ",".join(normalized_ac_ids)])
    for item in context_paths or ():
        command.extend(["--context-path", item])
    for item in contract_paths or ():
        command.extend(["--contract-path", item])
    try:
        completed = subprocess.run(command, capture_output=True, text=True, check=False, timeout=30)
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise RuntimeErrorState(f"review gate could not be evaluated: {exc}") from exc
    if completed.returncode != 0:
        detail = completed.stderr.strip() or completed.stdout.strip() or f"exit {completed.returncode}"
        raise RuntimeErrorState(f"review gate blocked runtime operation: {detail}")
    try:
        result = json.loads(completed.stdout)
    except json.JSONDecodeError as exc:
        raise RuntimeErrorState(f"review gate returned malformed JSON: {exc}") from exc
    if not isinstance(result, dict) or not isinstance(result.get("next_action"), str):
        raise RuntimeErrorState("review gate omitted next_action")
    if fingerprint is not None and result.get("input_fingerprint") != fingerprint:
        raise RuntimeErrorState("review gate fingerprint differs from the requested input")
    return result


def _allowed(role: str, action: str) -> bool:
    role = role.lower()
    if role in {"coder", "makato-build:coder"}:
        return action in {"repair-local", "redesign"}
    if role in {"diff-reviewer", "reviewer", "makato-build:diff-reviewer"}:
        return action in {"review", "confirm", "certify"}
    if role in {"review-coordinator", "build-review", "makato-build:build-review"}:
        return action in _ACTIONS
    return False


def _mutating_role(role: str) -> bool:
    return role.lower().removeprefix("makato-build:") in {"coder", "build-review", "review-coordinator"}


def _read_writer_owner(path: Path) -> dict[str, Any] | None:
    try:
        owner = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return None
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise RuntimeErrorState("worktree writer ownership record is unreadable") from exc
    if (
        not isinstance(owner, dict)
        or owner.get("schema") != SCHEMA
        or not isinstance(owner.get("attempt_id"), str)
        or not _ID.fullmatch(owner["attempt_id"])
        or not isinstance(owner.get("pid"), int)
        or isinstance(owner["pid"], bool)
        or owner["pid"] <= 1
        or owner.get("pgid") != owner["pid"]
        or isinstance(owner.get("pgid"), bool)
        or not isinstance(owner.get("start_token"), str)
        or not owner["start_token"]
        or not isinstance(owner.get("run_identity"), str)
        or not _ID.fullmatch(owner["run_identity"])
    ):
        raise RuntimeErrorState("worktree writer ownership record is malformed")
    return owner


def _claim_writer_owner(path: Path, identity: Mapping[str, Any], attempt_id: str) -> dict[str, Any]:
    """Called under the worktree flock, before any writer child can spawn."""
    previous = _read_writer_owner(path)
    if previous is not None and _owned_group_alive(previous):
        raise RuntimeErrorState("a prior writer process group still owns this worktree")
    owner = {"schema": SCHEMA, "attempt_id": attempt_id, **identity}
    _write_json(path, owner)
    return owner


def _clear_writer_owner(path: Path, owner: Mapping[str, Any]) -> None:
    """Retire only this worker's fence, under its still-held worktree flock."""
    if _read_writer_owner(path) != owner or not _matches_identity(owner):
        return
    members, all_owned = _group_members(owner["pgid"], owner["run_identity"])
    if not all_owned or any(pid != os.getpid() for pid in members):
        return
    path.unlink()
    directory_fd = os.open(path.parent, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
    try:
        os.fsync(directory_fd)
    finally:
        os.close(directory_fd)


def _run_worker(descriptor_path: Path) -> int:
    """Private child supervisor; its session survives its launching coordinator."""
    try:
        descriptor = json.loads(descriptor_path.read_text(encoding="utf-8"))
        descriptor_path.unlink()
    except Exception:
        return 125
    run_identity = os.environ.get("MAKATO_REVIEW_RUN_ID", "")
    attempt_id = descriptor.get("attempt_id")
    attempt_dir = Path(descriptor["attempt_dir"])
    identity = _identity(os.getpid(), run_identity)
    if identity is None:
        return 125
    writer_fd = None
    writer_owner = None
    owner_path = None
    try:
        if descriptor.get("writer_lock"):
            writer_fd = os.open(descriptor["writer_lock"], os.O_CREAT | os.O_RDWR | getattr(os, "O_NOFOLLOW", 0), 0o600)
            try:
                fcntl.flock(writer_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except OSError as exc:
                raise RuntimeErrorState("another writer owns this worktree") from exc
            owner_path = Path(descriptor["writer_lock"]).with_suffix(".owner.json")
            writer_owner = _claim_writer_owner(owner_path, identity, attempt_id)
        _write_json(attempt_dir / "ready.json", {"schema": SCHEMA, "attempt_id": attempt_id, **identity, "ready_at": _now()})
        start_marker = attempt_dir / "start"
        abort_marker = attempt_dir / "abort"
        started = time.monotonic()
        while not start_marker.exists():
            if abort_marker.exists() or time.monotonic() - started > _STARTUP_TIMEOUT_SECONDS:
                return 125
            time.sleep(0.025)
        if abort_marker.exists():
            return 125
        try:
            start_payload = json.loads(start_marker.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            return 125
        runtime_env = start_payload.get("runtime_env")
        if not isinstance(runtime_env, dict) or any(not isinstance(key, str) or not isinstance(value, str) for key, value in runtime_env.items()):
            return 125
        child_env = os.environ.copy()
        child_env.update(runtime_env)
        command = descriptor.get("command")
        cwd = descriptor.get("cwd")
        if not isinstance(command, list) or not command or any(not isinstance(item, str) for item in command) or not isinstance(cwd, str):
            return 125
        output_path = Path(descriptor["stdout_path"])
        fd = os.open(output_path, os.O_CREAT | os.O_WRONLY | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "wb") as output:
            process = subprocess.Popen(command, cwd=cwd, env=child_env, stdin=subprocess.DEVNULL, stdout=output, stderr=subprocess.STDOUT, close_fds=True)
            exit_code = process.wait()
            # The durable group fence survives this worker even if its flock does not.
            while True:
                members, all_owned = _group_members(identity["pgid"], run_identity)
                if all_owned and not any(pid != os.getpid() for pid in members):
                    break
                time.sleep(DEFAULT_POLL_SECONDS)
            output.flush()
            os.fsync(output.fileno())
        raw = output_path.read_bytes()
        stdout_sha = hashlib.sha256(raw).hexdigest()
        envelope, protocol_error = _validate_r1(raw)
        result_path = Path(descriptor["result_path"])
        result_sha = None
        result_status = None
        if envelope is not None:
            result_bytes = (json.dumps(envelope, ensure_ascii=False, sort_keys=True) + "\n").encode("utf-8")
            _write_atomic(result_path, result_bytes)
            result_sha = hashlib.sha256(result_bytes).hexdigest()
            result_status = envelope["status"]
        receipt = {
            "schema": SCHEMA,
            "attempt_id": attempt_id,
            "run_identity": run_identity,
            "worker_identity": identity,
            "child_pid": process.pid,
            "exit_code": exit_code,
            "stdout_path": str(output_path),
            "stdout_sha256": stdout_sha,
            "result_path": str(result_path),
            "result_sha256": result_sha,
            "result_status": result_status,
            "protocol_error": protocol_error,
            "finished_at": _now(),
        }
        _write_json(Path(descriptor["exit_receipt_path"]), receipt)
        return 0
    except BaseException as exc:
        # The parent's reconciliation sees a missing receipt and blocks; this
        # marker is useful evidence but never converts the run to success.
        with contextlib.suppress(Exception):
            _write_json(Path(descriptor["worker_error_path"]), {"attempt_id": attempt_id, "error_type": type(exc).__name__, "error": str(exc)[:500], "at": _now()})
        return 125
    finally:
        if writer_fd is not None:
            if writer_owner is not None and owner_path is not None:
                with contextlib.suppress(Exception):
                    _clear_writer_owner(owner_path, writer_owner)
            os.close(writer_fd)


def _record_from_ready(attempt: dict[str, Any], attempt_dir: Path) -> bool:
    try:
        ready = json.loads((attempt_dir / "ready.json").read_text(encoding="utf-8"))
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        return False
    if ready.get("schema") != SCHEMA or ready.get("attempt_id") != attempt.get("attempt_id"):
        return False
    run_identity = attempt.get("run_identity")
    if ready.get("run_identity") != run_identity:
        return False
    pid = ready.get("pid")
    identity_fields = ("pid", "pgid", "start_token", "run_identity")
    identity = _identity(pid, run_identity) if isinstance(pid, int) and not isinstance(pid, bool) else None
    if identity is None or identity != {key: ready.get(key) for key in identity_fields}:
        return False
    attempt.update(identity)
    return True


def _reconcile_locked(state_path: Path, state: dict[str, Any], attempt: dict[str, Any]) -> bool:
    attempt_dir = _attempt_dir(state_path, attempt["attempt_id"])
    receipt_path = Path(attempt["exit_receipt_path"])
    try:
        receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        receipt = None
    except (json.JSONDecodeError, OSError):
        attempt["state"] = "blocked"
        attempt["protocol_error"] = "malformed_exit_receipt"
        return True
    identity_fields = ("pid", "pgid", "start_token", "run_identity")
    changed = False
    if attempt.get("pid") is None and receipt is not None:
        worker_identity = receipt.get("worker_identity")
        if isinstance(worker_identity, dict) and worker_identity.get("run_identity") == attempt.get("run_identity"):
            attempt.update({key: worker_identity.get(key) for key in identity_fields})
            changed = True
    if attempt.get("pid") is None and _record_from_ready(attempt, attempt_dir):
        changed = True
    if receipt is not None:
        if receipt.get("schema") != SCHEMA or receipt.get("attempt_id") != attempt.get("attempt_id") or receipt.get("run_identity") != attempt.get("run_identity"):
            attempt["state"] = "blocked"
            attempt["protocol_error"] = "exit_receipt_identity_mismatch"
            return True
        if receipt.get("worker_identity") != {key: attempt.get(key) for key in identity_fields}:
            attempt["state"] = "blocked"
            attempt["protocol_error"] = "exit_receipt_process_mismatch"
            return True
        try:
            stdout = Path(attempt["stdout_path"]).read_bytes()
        except OSError:
            stdout = b""
        stdout_sha = hashlib.sha256(stdout).hexdigest()
        result_path = Path(attempt["result_path"])
        result_sha = None
        result_status = None
        envelope, protocol_error = _validate_r1(stdout)
        if envelope is not None:
            try:
                result_bytes = result_path.read_bytes()
            except OSError:
                result_bytes = b""
            result_sha = hashlib.sha256(result_bytes).hexdigest() if result_bytes else None
            try:
                result_envelope = json.loads(result_bytes)
            except (UnicodeDecodeError, json.JSONDecodeError):
                result_envelope = None
            if not isinstance(result_envelope, dict) or result_envelope != envelope:
                protocol_error = "durable_result_invalid"
            else:
                result_status = envelope["status"]
        if stdout_sha != receipt.get("stdout_sha256") or result_sha != receipt.get("result_sha256") or result_status != receipt.get("result_status") or protocol_error != receipt.get("protocol_error"):
            protocol_error = protocol_error or "result_receipt_digest_mismatch"
        attempt["exit_code"] = receipt.get("exit_code")
        attempt["stdout_sha256"] = stdout_sha
        attempt["result_sha256"] = result_sha
        attempt["result_status"] = result_status
        attempt["protocol_error"] = protocol_error
        attempt["finished_at"] = receipt.get("finished_at")
        attempt["state"] = (
            "completed" if isinstance(receipt.get("exit_code"), int) and not isinstance(receipt.get("exit_code"), bool) and receipt.get("exit_code") == 0 and not protocol_error else "blocked"
        )
        if receipt.get("exit_code") != 0 and not attempt.get("protocol_error"):
            attempt["protocol_error"] = "child_exit_nonzero"
        return True
    state_name = attempt.get("state")
    if state_name in {"preparing", "running"} and not _matches_identity(attempt):
        attempt["state"] = "blocked"
        attempt["protocol_error"] = "child_identity_lost_without_exit_receipt"
        return True
    if state_name == "preparing":
        if attempt.get("pid") is None:
            attempt["state"] = "blocked"
            attempt["protocol_error"] = "launch_state_ambiguous_no_identity"
            return True
        attempt["state"] = "running"
        changed = True
    return changed


def _runtime_env(state_path: Path, ledger_state: Path, state: Mapping[str, Any], attempt: Mapping[str, Any], gate: Mapping[str, Any]) -> dict[str, str]:
    return {
        "MAKATO_REVIEW_RUNTIME_STATE": str(state_path),
        "MAKATO_REVIEW_LEDGER_STATE": str(ledger_state),
        "MAKATO_REVIEW_ATTEMPT_ID": str(attempt["attempt_id"]),
        "MAKATO_REVIEW_RUNTIME_EPOCH": str(state["epoch"]),
        "MAKATO_REVIEW_RUN_ID": str(attempt["run_identity"]),
        "MAKATO_REVIEW_NEXT_ACTION": str(gate["next_action"]),
        "MAKATO_REVIEW_GATE_ID": str(gate.get("gate_id") or ""),
        "MAKATO_REVIEW_INPUT_FINGERPRINT": str(gate["input_fingerprint"]),
        "MAKATO_REVIEW_GATE_JSON": json.dumps(gate, ensure_ascii=False, sort_keys=True),
        "MAKATO_REVIEW_INVOCATION_SHA256": str(attempt["invocation_sha256"]),
        "MAKATO_REVIEW_CONTEXT_SHA256": str(attempt.get("context_sha256") or ""),
        "MAKATO_REVIEW_EXPECTED_AC_IDS": ",".join(attempt.get("expected_ac_ids") or []),
    }


def _activate_waiting_worker(state_path: Path, state: dict[str, Any], attempt: dict[str, Any], gate: Mapping[str, Any]) -> None:
    attempt["gate_id"] = gate.get("gate_id")
    attempt["gate_reason"] = gate.get("reason")
    attempt["gate_fingerprint"] = gate.get("input_fingerprint")
    attempt["gate_event"] = attempt.get("gate_event")
    state["next_action"] = gate["next_action"]
    attempt["ownership_epoch"] = state["epoch"] + 1
    _save(state_path, state)
    _write_json(
        _attempt_dir(state_path, attempt["attempt_id"]) / "start",
        {
            "runtime_env": _runtime_env(state_path, Path(attempt["ledger_state"]), state, attempt, gate),
        },
    )


def _public(
    path: Path, state: Mapping[str, Any], attempt: Mapping[str, Any] | None, *, decision: str | None = None, gate: Mapping[str, Any] | None = None, timed_out: bool | None = None
) -> dict[str, Any]:
    output = {
        "schema": SCHEMA,
        "checkpoint": str(path.expanduser().absolute()),
        "epoch": state.get("epoch", 0),
        "next_action": (gate or {}).get("next_action", state.get("next_action", "review")),
        "reason": (gate or {}).get("reason"),
        "gate_id": (gate or {}).get("gate_id"),
        "input_fingerprint": (gate or {}).get("input_fingerprint"),
        "attempt": None,
        "decision": decision or "status",
    }
    if attempt is not None:
        fields = (
            "attempt_id",
            "role",
            "fingerprint",
            "next_action",
            "state",
            "ownership_epoch",
            "pid",
            "pgid",
            "start_token",
            "run_identity",
            "stdout_path",
            "result_path",
            "exit_receipt_path",
            "result_sha256",
            "stdout_sha256",
            "result_status",
            "protocol_error",
            "exit_code",
            "accepted_at",
            "created_at",
            "finished_at",
            "invocation_sha256",
            "context_path",
            "context_sha256",
            "contract_root",
            "expected_ac_ids",
        )
        output["attempt"] = {key: attempt.get(key) for key in fields}
    if timed_out is not None:
        output["timed_out"] = timed_out
    return output


def status(state_path: str | Path, attempt_id: str | None = None) -> dict[str, Any]:
    path = Path(state_path).expanduser().absolute()
    with _locked(path, create=False) as state:
        attempt = state["attempts"].get(attempt_id) if attempt_id else None
        if attempt_id and attempt is None:
            return _public(path, state, None, decision="not_found")
        return _public(path, state, attempt)


def _require_epoch(state: Mapping[str, Any], expected_epoch: int) -> None:
    if expected_epoch != state["epoch"]:
        raise RuntimeErrorState(f"stale runtime epoch {expected_epoch}; current epoch is {state['epoch']}")


def launch(
    *,
    state_path: str | Path,
    ledger_state: str | Path,
    attempt_id: str,
    role: str,
    fingerprint: str,
    expected_epoch: int,
    next_action: str | None,
    gate_event: str,
    worktree: str | Path,
    review_base: str,
    command: Sequence[str],
    cwd: str | Path,
    env: Mapping[str, str] | None = None,
    soft_cap: int | None = None,
    hard_cap: int | None = None,
    context_path: str | Path | None = None,
    invocation_sha256: str | None = None,
    context_paths: Sequence[str] = (),
    contract_paths: Sequence[str] = (),
    evidence_root: str | Path | None = None,
    expected_ac_ids: Sequence[str] = (),
) -> dict[str, Any]:
    """Persist a launch receipt, then start exactly one detached supervised child."""
    path = Path(state_path).expanduser().absolute()
    ledger = Path(ledger_state).expanduser().absolute()
    worktree_path = Path(worktree).expanduser().resolve()
    if not command or any(not isinstance(item, str) for item in command):
        raise RuntimeErrorState("launch command must be a non-empty argv list")
    if not any(_allowed(role, action) for action in _ACTIONS) or (next_action is not None and (next_action not in _ACTIONS or not _allowed(role, next_action))):
        raise RuntimeErrorState(f"role {role!r} is not authorized for next_action {next_action!r}")
    if not _FINGERPRINT.fullmatch(fingerprint):
        raise RuntimeErrorState("input fingerprint must be a lowercase SHA-256")
    if not Path(cwd).expanduser().resolve().is_dir():
        raise RuntimeErrorState(f"child working directory does not exist: {cwd}")
    git_dir = subprocess.run(
        ["git", "-C", str(worktree_path), "rev-parse", "--absolute-git-dir"],
        capture_output=True,
        text=True,
        check=False,
        timeout=10,
    )
    if git_dir.returncode:
        raise RuntimeErrorState("a durable review writer requires a real Git worktree")
    writer_directory = Path(git_dir.stdout.strip()) / "makato-review-loop"
    _private_dir(writer_directory)
    environment = os.environ if env is None else env
    build_root = environment.get("MAKATO_BUILD_ROOT") or str(Path(__file__).resolve().parents[1])
    contract_root_path = Path(build_root).expanduser().resolve()
    supplied_ac_ids = tuple(expected_ac_ids)
    if any(not isinstance(item, str) or not item.strip() for item in supplied_ac_ids):
        raise RuntimeErrorState("expected AC ids must be non-empty strings")
    if len(set(supplied_ac_ids)) != len(supplied_ac_ids):
        raise RuntimeErrorState("expected AC ids must be distinct")
    normalized_ac_ids = tuple(sorted(supplied_ac_ids))
    attempt_id = str(attempt_id)
    attempt_dir = _attempt_dir(path, attempt_id)
    with _locked(path) as state:
        _require_epoch(state, expected_epoch)
        existing = state["attempts"].get(attempt_id)
        if existing is not None and not isinstance(existing, dict):
            raise RuntimeErrorState(f"attempt {attempt_id!r} is malformed; refusing to launch")
        if next_action is None and existing is not None:
            next_action = existing.get("next_action")
        if existing is not None and (
            existing.get("role") != role
            or existing.get("fingerprint") != fingerprint
            or existing.get("next_action") != next_action
            or existing.get("gate_event") != gate_event
            or existing.get("ledger_state") != str(ledger)
            or existing.get("worktree") != str(worktree_path)
            or existing.get("review_base") != review_base
            or existing.get("soft_cap") != soft_cap
            or existing.get("hard_cap") != hard_cap
            or existing.get("context_paths") != sorted(set(context_paths))
            or existing.get("contract_paths") != sorted(set(contract_paths))
            or existing.get("evidence_root") != (str(Path(evidence_root).expanduser().resolve()) if evidence_root is not None else None)
            or existing.get("contract_root") != str(contract_root_path)
            or existing.get("expected_ac_ids") != list(normalized_ac_ids)
            or existing.get("context_path") != (str(Path(context_path).expanduser().resolve()) if context_path is not None else None)
            or existing.get("invocation_sha256") != (invocation_sha256 or hashlib.sha256(json.dumps(list(command), ensure_ascii=False).encode("utf-8")).hexdigest())
        ):
            raise RuntimeErrorState("attempt id already belongs to a different role, invocation, or fingerprint evidence")
        if existing is None:
            _assert_not_halted(env)
        current_gate = _gate(
            ledger_state=ledger,
            event=gate_event,
            worktree=worktree_path,
            review_base=review_base,
            fingerprint=None if existing is not None and _mutating_role(role) else fingerprint,
            soft_cap=soft_cap,
            hard_cap=hard_cap,
            context_paths=context_paths,
            contract_paths=contract_paths,
            evidence_root=evidence_root,
            contract_root=contract_root_path,
            expected_ac_ids=normalized_ac_ids,
        )
        if next_action is None:
            next_action = current_gate["next_action"]
        if next_action not in _ACTIONS or not _allowed(role, next_action):
            raise RuntimeErrorState(f"current review gate does not authorize a new {role} dispatch: {next_action}")
        if existing is not None:
            changed = _reconcile_locked(path, state, existing)
            if state.get("next_action") != current_gate["next_action"]:
                state["next_action"] = current_gate["next_action"]
                changed = True
            if existing.get("state") in {"preparing", "running"} and not (_attempt_dir(path, attempt_id) / "start").exists():
                if current_gate.get("next_action") == existing.get("next_action"):
                    try:
                        _assert_not_halted(env)
                    except RuntimeErrorState as exc:
                        _write_atomic(_attempt_dir(path, attempt_id) / "abort", b"abort\n")
                        existing["state"] = "blocked"
                        existing["protocol_error"] = "halt_file_present_before_activation"
                        existing["worker_error"] = str(exc)[:500]
                        _save(path, state)
                        _signal_owned(existing, signal.SIGTERM)
                        return _public(path, state, existing, decision="blocked", gate=current_gate)
                    _activate_waiting_worker(path, state, existing, current_gate)
                    return _public(path, state, existing, decision="running", gate=current_gate)
                _write_atomic(_attempt_dir(path, attempt_id) / "abort", b"abort\n")
                existing["state"] = "blocked"
                existing["protocol_error"] = f"gate_changed_before_activation:{current_gate.get('next_action')}"
                changed = True
            if changed:
                _save(path, state)
            decision = "blocked" if current_gate.get("next_action") == "blocked" or existing.get("state") == "blocked" else existing.get("state", "running")
            return _public(path, state, existing, decision=decision, gate=current_gate)
        if current_gate["next_action"] != next_action:
            raise RuntimeErrorState(f"gate authorizes {current_gate['next_action']!r}, not requested {next_action!r}: {current_gate.get('reason', '')}")
        if current_gate["next_action"] == "blocked":
            raise RuntimeErrorState(f"review gate blocked dispatch: {current_gate.get('reason', 'no reason provided')}")
        if _mutating_role(role):
            for previous in state["attempts"].values():
                previous_role = previous.get("role") if isinstance(previous, dict) else None
                if isinstance(previous_role, str) and _mutating_role(previous_role) and previous.get("state") in {"preparing", "running", "blocked"}:
                    raise RuntimeErrorState(f"writer attempt {previous.get('attempt_id')} is {previous.get('state')}; reconcile it before another writer")
        run_identity = uuid.uuid4().hex
        stdout_path = attempt_dir / "stdout.log"
        result_path = attempt_dir / "result.json"
        receipt_path = attempt_dir / "exit-receipt.json"
        descriptor_path = attempt_dir / "launch.json"
        attempt = {
            "attempt_id": attempt_id,
            "role": role,
            "fingerprint": fingerprint,
            "next_action": next_action,
            "gate_event": gate_event,
            "ledger_state": str(ledger),
            "worktree": str(worktree_path),
            "review_base": review_base,
            "context_paths": sorted(set(context_paths)),
            "contract_paths": sorted(set(contract_paths)),
            "evidence_root": str(Path(evidence_root).expanduser().resolve()) if evidence_root is not None else None,
            "contract_root": str(contract_root_path),
            "expected_ac_ids": list(normalized_ac_ids),
            "soft_cap": soft_cap,
            "hard_cap": hard_cap,
            "state": "preparing",
            "ownership_epoch": state["epoch"] + 1,
            "run_identity": run_identity,
            "pid": None,
            "pgid": None,
            "start_token": None,
            "stdout_path": str(stdout_path),
            "result_path": str(result_path),
            "exit_receipt_path": str(receipt_path),
            "context_path": str(Path(context_path).resolve()) if context_path is not None else None,
            "context_sha256": hashlib.sha256(Path(context_path).read_bytes()).hexdigest() if context_path is not None else None,
            "invocation_sha256": invocation_sha256 or hashlib.sha256(json.dumps(list(command), ensure_ascii=False).encode("utf-8")).hexdigest(),
            "created_at": _now(),
            "accepted_at": None,
            "protocol_error": None,
        }
        state["attempts"][attempt_id] = attempt
        state["next_action"] = current_gate["next_action"]
        # This receipt is durable before the worker process can start.
        _save(path, state)
        child_env = dict(os.environ if env is None else env)
        child_env["MAKATO_REVIEW_RUN_ID"] = run_identity
        descriptor = {
            "attempt_id": attempt_id,
            "attempt_dir": str(attempt_dir),
            "command": list(command),
            "cwd": str(Path(cwd).expanduser().resolve()),
            "stdout_path": str(stdout_path),
            "result_path": str(result_path),
            "exit_receipt_path": str(receipt_path),
            "worker_error_path": str(attempt_dir / "worker-error.json"),
            "writer_lock": str(writer_directory / "worktree-writer.lock") if _mutating_role(role) else None,
        }
        _write_json(descriptor_path, descriptor)
        worker = [sys.executable, str(Path(__file__).resolve()), "_worker", str(descriptor_path)]
        try:
            process = subprocess.Popen(
                worker, cwd=str(Path(cwd).expanduser().resolve()), env=child_env, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True, close_fds=True
            )
        except OSError as exc:
            attempt["state"] = "blocked"
            attempt["protocol_error"] = f"worker_spawn_failed:{type(exc).__name__}"
            attempt["worker_error"] = str(exc)[:500]
            _save(path, state)
            raise RuntimeErrorState(f"durable worker could not start: {exc}") from exc
        # Reap while this launcher survives; process ownership itself remains durable
        # when the launcher exits or is killed.
        threading.Thread(target=process.wait, name=f"review-worker-{attempt_id}", daemon=True).start()
        deadline = time.monotonic() + _STARTUP_TIMEOUT_SECONDS
        identity = None
        while time.monotonic() < deadline:
            identity = _identity(process.pid, run_identity)
            if identity is not None:
                break
            if process.poll() is not None:
                break
            time.sleep(0.01)
        if identity is None:
            # The ready receipt can recover the narrow Popen/parent-death race.
            if not _record_from_ready(attempt, attempt_dir):
                attempt["state"] = "blocked"
                attempt["protocol_error"] = "worker_start_identity_unavailable"
                _save(path, state)
                return _public(path, state, attempt, decision="blocked", gate=current_gate)
        else:
            attempt.update(identity)
        attempt["state"] = "running"
        _save(path, state)
        # Activation occurs only after process identity is durably fenced.
        latest_gate = _gate(
            ledger_state=ledger,
            event=gate_event,
            worktree=worktree_path,
            review_base=review_base,
            fingerprint=fingerprint,
            soft_cap=soft_cap,
            hard_cap=hard_cap,
            context_paths=context_paths,
            contract_paths=contract_paths,
            evidence_root=evidence_root,
            contract_root=contract_root_path,
            expected_ac_ids=normalized_ac_ids,
        )
        if latest_gate.get("next_action") != next_action:
            _write_atomic(attempt_dir / "abort", b"abort\n")
            attempt["state"] = "blocked"
            attempt["protocol_error"] = f"gate_changed_before_activation:{latest_gate.get('next_action')}"
            _save(path, state)
            _signal_owned(attempt, signal.SIGTERM)
            return _public(path, state, attempt, decision="blocked", gate=latest_gate)
        try:
            _assert_not_halted(env)
        except RuntimeErrorState as exc:
            _write_atomic(attempt_dir / "abort", b"abort\n")
            attempt["state"] = "blocked"
            attempt["protocol_error"] = "halt_file_present_before_activation"
            attempt["worker_error"] = str(exc)[:500]
            _save(path, state)
            _signal_owned(attempt, signal.SIGTERM)
            return _public(path, state, attempt, decision="blocked", gate=latest_gate)
        _activate_waiting_worker(path, state, attempt, latest_gate)
        return _public(path, state, attempt, decision="launched", gate=latest_gate)


def _signal_owned(attempt: Mapping[str, Any], signum: int) -> bool:
    pgid = attempt.get("pgid")
    run_identity = attempt.get("run_identity")
    if not isinstance(pgid, int) or isinstance(pgid, bool) or not isinstance(run_identity, str):
        return False
    members, all_owned = _group_members(pgid, run_identity)
    if not members or not all_owned:
        return False
    if _proc_start_token(pgid) is not None and not _matches_identity(attempt):
        return False
    try:
        os.killpg(pgid, signum)
        return True
    except ProcessLookupError:
        return False


def reconcile(
    *,
    state_path: str | Path,
    attempt_id: str,
    expected_epoch: int,
    gate_event: str | None = None,
    worktree: str | Path | None = None,
    review_base: str | None = None,
    fingerprint: str | None = None,
    soft_cap: int | None = None,
    hard_cap: int | None = None,
    invocation_sha256: str | None = None,
    context_paths: Sequence[str] | None = None,
    contract_paths: Sequence[str] | None = None,
    evidence_root: str | Path | None = None,
    expected_ac_ids: Sequence[str] | None = None,
) -> dict[str, Any]:
    """Observe/adopt one durable attempt; never relaunch or activate it."""
    path = Path(state_path).expanduser().absolute()
    with _locked(path, create=False) as state:
        _require_epoch(state, expected_epoch)
        attempt = state["attempts"].get(attempt_id)
        if attempt is None:
            raise RuntimeErrorState(f"unknown attempt {attempt_id!r}; reconcile never launches")
        current_fingerprint = None if _mutating_role(attempt["role"]) else (fingerprint or attempt.get("fingerprint"))
        event = gate_event or attempt.get("gate_event")
        gate = _gate(
            ledger_state=Path(attempt["ledger_state"]),
            event=event,
            worktree=Path(worktree or attempt["worktree"]),
            review_base=review_base or attempt["review_base"],
            fingerprint=current_fingerprint,
            soft_cap=soft_cap,
            hard_cap=hard_cap,
            context_paths=context_paths if context_paths is not None else attempt.get("context_paths"),
            contract_paths=contract_paths if contract_paths is not None else attempt.get("contract_paths"),
            evidence_root=evidence_root if evidence_root is not None else attempt.get("evidence_root"),
            contract_root=attempt.get("contract_root"),
            expected_ac_ids=expected_ac_ids if expected_ac_ids is not None else attempt.get("expected_ac_ids"),
        )
        invocation_matches = invocation_sha256 is None or invocation_sha256 == attempt.get("invocation_sha256")
        gate_matches = gate.get("next_action") == attempt.get("next_action")
        changed = _reconcile_locked(path, state, attempt)
        reason = None
        if invocation_sha256 is not None and not invocation_matches:
            reason = "current invocation/context digest differs from the authorized attempt"
        elif gate.get("next_action") == "blocked":
            reason = gate.get("reason") or "current review gate is blocked"
        elif not gate_matches and not _mutating_role(attempt["role"]) and attempt.get("state") not in {"completed", "canceled"}:
            reason = f"current gate action {gate.get('next_action')} differs from attempt action {attempt.get('next_action')}"
        if reason is not None:
            if attempt.get("continuation_blocked_reason") != reason:
                attempt["continuation_blocked_reason"] = reason
                changed = True
            attempt_dir = _attempt_dir(path, attempt_id)
            if not (attempt_dir / "start").exists() and attempt.get("state") == "running":
                _write_atomic(attempt_dir / "abort", b"abort\n")
                if _signal_owned(attempt, signal.SIGTERM):
                    attempt["state"] = "blocked"
                    attempt["protocol_error"] = "activation_gate_or_context_changed"
                changed = True
        elif invocation_sha256 is not None and attempt.pop("continuation_blocked_reason", None) is not None:
            changed = True
        gate_updates = {
            "gate_id": gate.get("gate_id"),
            "gate_reason": gate.get("reason"),
            "gate_fingerprint": gate.get("input_fingerprint"),
        }
        for key, value in gate_updates.items():
            if attempt.get(key) != value:
                attempt[key] = value
                changed = True
        if state.get("next_action") != gate.get("next_action", "blocked"):
            state["next_action"] = gate.get("next_action", "blocked")
            changed = True
        if changed:
            _save(path, state)
        decision = "blocked" if reason is not None or attempt.get("state") == "blocked" else attempt.get("state", "running")
        return _public(path, state, attempt, decision=decision, gate=gate)


def accept(
    *,
    state_path: str | Path,
    attempt_id: str,
    expected_epoch: int,
    invocation_sha256: str | None = None,
) -> dict[str, Any]:
    path = Path(state_path).expanduser().absolute()
    with _locked(path, create=False) as state:
        _require_epoch(state, expected_epoch)
        attempt = state["attempts"].get(attempt_id)
        if attempt is None:
            raise RuntimeErrorState(f"unknown attempt {attempt_id!r}")
        if attempt.get("state") != "completed" or attempt.get("protocol_error"):
            raise RuntimeErrorState("result is not a validated completed R1; it cannot be accepted")
        if invocation_sha256 is not None and invocation_sha256 != attempt.get("invocation_sha256"):
            raise RuntimeErrorState("current invocation/context digest does not match this result")
        result_path = Path(attempt["result_path"])
        try:
            raw = result_path.read_bytes()
            stdout = Path(attempt["stdout_path"]).read_bytes()
        except OSError as exc:
            raise RuntimeErrorState(f"durable result is unavailable: {exc}") from exc
        digest = hashlib.sha256(raw).hexdigest()
        if digest != attempt.get("result_sha256") or hashlib.sha256(stdout).hexdigest() != attempt.get("stdout_sha256"):
            raise RuntimeErrorState("durable result/stdout digest mismatch")
        envelope, error = _validate_r1(stdout)
        try:
            result = json.loads(raw)
        except (UnicodeDecodeError, json.JSONDecodeError):
            result = None
        if error or envelope is None or result != envelope:
            raise RuntimeErrorState(f"durable result failed R1 validation: {error or 'result mismatch'}")
        current_gate = _gate(
            ledger_state=Path(attempt["ledger_state"]),
            event="review",
            worktree=Path(attempt["worktree"]),
            review_base=attempt["review_base"],
            fingerprint=None if _mutating_role(attempt["role"]) else attempt["fingerprint"],
            context_paths=attempt.get("context_paths"),
            contract_paths=attempt.get("contract_paths"),
            evidence_root=attempt.get("evidence_root"),
            contract_root=attempt.get("contract_root"),
            expected_ac_ids=attempt.get("expected_ac_ids"),
        )
        if result["status"] == "success" and attempt["role"].lower().removeprefix("makato-build:") in {"build-review", "review-coordinator"}:
            data = result["data"]
            if data.get("input_fingerprint") != current_gate.get("input_fingerprint"):
                raise RuntimeErrorState("successful review result is stale for the current worktree")
            if data.get("final_review") is True:
                if current_gate["next_action"] != "complete":
                    raise RuntimeErrorState("successful review has not passed the current final-full gate")
            elif data.get("final_review") is False and isinstance(data.get("checkpoint_receipt"), dict):
                receipt = data["checkpoint_receipt"]
                tasks = receipt.get("task_ids")
                if not isinstance(tasks, list) or not tasks or any(not isinstance(task, str) or not task for task in tasks):
                    raise RuntimeErrorState("checkpoint receipt requires non-empty string task IDs")
                if not isinstance(receipt.get("pass_id"), str) or not receipt["pass_id"]:
                    raise RuntimeErrorState("checkpoint receipt requires a review pass ID")
                command = [
                    sys.executable,
                    str(Path(__file__).with_name("review_loop.py")),
                    "checkpoint-receipt",
                    "--state",
                    attempt["ledger_state"],
                    "--worktree",
                    attempt["worktree"],
                    "--review-base",
                    attempt["review_base"],
                    "--fingerprint",
                    data["input_fingerprint"],
                    "--task-ids",
                    ",".join(tasks),
                    "--pass-id",
                    receipt["pass_id"],
                ]
                try:
                    checked = subprocess.run(command, capture_output=True, text=True, timeout=30, check=False)
                    actual_receipt = json.loads(checked.stdout) if not checked.returncode else None
                except (OSError, subprocess.TimeoutExpired, ValueError) as exc:
                    raise RuntimeErrorState(f"checkpoint receipt could not be verified: {exc}") from exc
                if checked.returncode or actual_receipt != receipt:
                    raise RuntimeErrorState("successful checkpoint lacks a current durable review receipt")
            else:
                raise RuntimeErrorState("successful review must provide final-full or checkpoint certification")
        if attempt.get("accepted_at") is None:
            attempt["accepted_at"] = _now()
            attempt["accepted_sha256"] = digest
            attempt["accepted_invocation_sha256"] = attempt.get("invocation_sha256")
            _save(path, state)
        elif attempt.get("accepted_sha256") != digest or attempt.get("accepted_invocation_sha256") != attempt.get("invocation_sha256"):
            raise RuntimeErrorState("accepted result changed after acceptance")
        output = _public(path, state, attempt, decision="accepted")
        output["result"] = result
        return output


def cancel(*, state_path: str | Path, attempt_id: str, expected_epoch: int, grace_seconds: float = 2.0) -> dict[str, Any]:
    path = Path(state_path).expanduser().absolute()
    if grace_seconds < 0 or grace_seconds > 30:
        raise RuntimeErrorState("cancel grace must be between 0 and 30 seconds")
    with _locked(path, create=False) as state:
        _require_epoch(state, expected_epoch)
        attempt = state["attempts"].get(attempt_id)
        if attempt is None:
            raise RuntimeErrorState(f"unknown attempt {attempt_id!r}")
        changed = _reconcile_locked(path, state, attempt)
        if attempt.get("state") in {"completed", "canceled"}:
            if changed:
                _save(path, state)
            return _public(path, state, attempt, decision=attempt["state"])
        attempt_dir = _attempt_dir(path, attempt_id)
        if not (attempt_dir / "start").exists():
            _write_atomic(attempt_dir / "abort", b"abort\n")
            if attempt.get("pid") is None:
                _record_from_ready(attempt, attempt_dir)
        if _owned_group_alive(attempt) and not _signal_owned(attempt, signal.SIGTERM) and _owned_group_alive(attempt):
            attempt["state"] = "blocked"
            attempt["protocol_error"] = "cancel_refused_process_identity_mismatch"
            _save(path, state)
            raise RuntimeErrorState("cancel refused: process group PID/PGID/start-token/run-identity did not match")
        deadline = time.monotonic() + grace_seconds
        while time.monotonic() < deadline and _owned_group_alive(attempt):
            time.sleep(0.025)
        if _owned_group_alive(attempt):
            if not _signal_owned(attempt, signal.SIGKILL) and _owned_group_alive(attempt):
                attempt["state"] = "blocked"
                attempt["protocol_error"] = "cancel_identity_changed_during_termination"
                _save(path, state)
                raise RuntimeErrorState("cancel stopped: process group identity changed before forced termination")
            end = time.monotonic() + 2.0
            while time.monotonic() < end and _owned_group_alive(attempt):
                time.sleep(0.025)
        if _owned_group_alive(attempt):
            attempt["state"] = "blocked"
            attempt["protocol_error"] = "owned_process_group_did_not_terminate"
            _save(path, state)
            raise RuntimeErrorState("owned process group did not terminate")
        attempt["state"] = "canceled"
        attempt["canceled_at"] = _now()
        _save(path, state)
        return _public(path, state, attempt, decision="canceled")


def wait_for_result(state_path: str | Path, attempt_id: str, timeout: float) -> dict[str, Any]:
    if timeout < 0 or timeout > MAX_WAIT_SECONDS:
        raise RuntimeErrorState(f"wait timeout must be between 0 and {MAX_WAIT_SECONDS:g} seconds")
    path = Path(state_path).expanduser().absolute()
    started = time.monotonic()
    while True:
        with _locked(path, create=False) as state:
            attempt = state["attempts"].get(attempt_id)
            if attempt is None:
                return _public(path, state, None, decision="not_found", timed_out=False)
            changed = _reconcile_locked(path, state, attempt)
            if changed:
                _save(path, state)
            if attempt.get("state") not in {"running", "preparing"}:
                return _public(path, state, attempt, decision=attempt.get("state"), timed_out=False)
            remaining = timeout - (time.monotonic() - started)
            if remaining <= 0:
                return _public(path, state, attempt, decision="running", timed_out=True)
        time.sleep(min(DEFAULT_POLL_SECONDS, remaining))


def recover_worktree(worktree: str | Path) -> dict[str, Any]:
    """Discover and reconcile the one outstanding build-review attempt for a worktree."""
    root = Path(worktree).expanduser().resolve()
    if not root.is_dir():
        raise RuntimeErrorState(f"review worktree is unavailable: {root}")
    git = subprocess.run(
        ["git", "-C", str(root), "rev-parse", "--absolute-git-dir"],
        capture_output=True,
        text=True,
        check=False,
        timeout=10,
    )
    if git.returncode:
        raise RuntimeErrorState(f"cannot resolve review worktree git directory: {git.stderr.strip()}")
    runtime_root = Path(git.stdout.strip()).resolve() / "makato-review-loop"
    if not runtime_root.is_dir():
        return {"schema": SCHEMA, "decision": "not_found", "reason": "no review runtime checkpoint"}
    outstanding: list[tuple[str, Path, int, str, dict[str, Any]]] = []
    for checkpoint in sorted(runtime_root.glob("*/runtime.json")):
        if checkpoint.is_symlink():
            raise RuntimeErrorState(f"review runtime checkpoint is a symlink: {checkpoint}")
        with _locked(checkpoint, create=False) as state:
            for attempt_id, attempt in state["attempts"].items():
                if not isinstance(attempt, dict):
                    raise RuntimeErrorState(f"malformed attempt in review checkpoint: {checkpoint}")
                role = attempt.get("role")
                if not isinstance(role, str):
                    raise RuntimeErrorState(f"malformed role in review checkpoint: {checkpoint}")
                if role.lower() not in {"build-review", "makato-build:build-review"}:
                    continue
                attempt_worktree = attempt.get("worktree")
                if not isinstance(attempt_worktree, str) or Path(attempt_worktree).expanduser().resolve() != root:
                    continue
                if attempt.get("state") in {"accepted", "canceled"} or attempt.get("accepted_at") is not None:
                    continue
                outstanding.append((str(attempt.get("created_at", "")), checkpoint, state["epoch"], str(attempt_id), attempt))
    if not outstanding:
        return {"schema": SCHEMA, "decision": "not_found", "reason": "no outstanding build-review attempt"}
    if len(outstanding) != 1:
        raise RuntimeErrorState(f"ambiguous outstanding build-review attempts for {root}: {len(outstanding)}")
    _, checkpoint, epoch, attempt_id, attempt = outstanding[0]
    if attempt.get("state") not in {"preparing", "running", "completed", "blocked"}:
        raise RuntimeErrorState(f"unknown build-review attempt state {attempt.get('state')!r}; refusing to resume")
    return reconcile(
        state_path=checkpoint,
        attempt_id=attempt_id,
        expected_epoch=epoch,
        gate_event=attempt.get("gate_event"),
        worktree=root,
        review_base=attempt.get("review_base"),
        fingerprint=attempt.get("fingerprint"),
        soft_cap=attempt.get("soft_cap"),
        hard_cap=attempt.get("hard_cap"),
    )


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    cmd = sub.add_parser("launch", help="durably launch one gated role-scoped child")
    cmd.add_argument("--state", required=True)
    cmd.add_argument("--ledger-state", required=True)
    cmd.add_argument("--attempt-id", required=True)
    cmd.add_argument("--role", required=True)
    cmd.add_argument("--fingerprint", required=True)
    cmd.add_argument("--expected-epoch", type=int, required=True)
    cmd.add_argument("--next-action", choices=sorted(_ACTIONS), help="assert a gate action; omitted selects the current durable action")
    cmd.add_argument("--gate-event", choices=sorted(_GATE_EVENTS), required=True)
    cmd.add_argument("--worktree", required=True)
    cmd.add_argument("--review-base", required=True)
    cmd.add_argument("--soft-cap", type=int)
    cmd.add_argument("--hard-cap", type=int)
    cmd.add_argument("--context-path")
    cmd.add_argument("--fingerprint-context-path", action="append", default=[])
    cmd.add_argument("--fingerprint-contract-path", action="append", default=[])
    cmd.add_argument("--evidence-root")
    cmd.add_argument("--expected-ac-ids")
    cmd.add_argument("--invocation-sha256")
    cmd.add_argument("--cwd", default=os.getcwd())
    cmd.add_argument("argv", nargs=argparse.REMAINDER)
    cmd = sub.add_parser("recover-worktree", help="reconcile the outstanding build-review attempt for a worktree")
    cmd.add_argument("--worktree", required=True)

    cmd = sub.add_parser("status", help="read current durable process/result state without launching")
    cmd.add_argument("--state", required=True)
    cmd.add_argument("--attempt-id")

    for name in ("reconcile", "resume"):
        cmd = sub.add_parser(name, help="reconcile a known attempt; never launches or replays")
        cmd.add_argument("--state", required=True)
        cmd.add_argument("--attempt-id", required=True)
        cmd.add_argument("--expected-epoch", type=int, required=True)
        cmd.add_argument("--gate-event")
        cmd.add_argument("--worktree")
        cmd.add_argument("--review-base")
        cmd.add_argument("--fingerprint")
        cmd.add_argument("--soft-cap", type=int)
        cmd.add_argument("--hard-cap", type=int)
        cmd.add_argument("--invocation-sha256")
        cmd.add_argument("--expected-ac-ids")

    cmd = sub.add_parser("accept", help="idempotently accept a validated durable R1 result")
    cmd.add_argument("--state", required=True)
    cmd.add_argument("--attempt-id", required=True)
    cmd.add_argument("--expected-epoch", type=int, required=True)
    cmd.add_argument("--invocation-sha256")

    cmd = sub.add_parser("cancel", help="cancel only the identity-checked owned process group")
    cmd.add_argument("--state", required=True)
    cmd.add_argument("--attempt-id", required=True)
    cmd.add_argument("--expected-epoch", type=int, required=True)
    cmd.add_argument("--grace-seconds", type=float, default=2.0)

    cmd = sub.add_parser("wait", help="wait for a result; timeout does not cancel")
    cmd.add_argument("--state", required=True)
    cmd.add_argument("--attempt-id", required=True)
    cmd.add_argument("--timeout", type=float, required=True)

    worker = sub.add_parser("_worker", help=argparse.SUPPRESS)
    worker.add_argument("descriptor")
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = _parser()
    args = parser.parse_args(argv)
    try:
        if args.command == "_worker":
            return _run_worker(Path(args.descriptor))
        if args.command == "status":
            result = status(args.state, args.attempt_id)
        elif args.command == "recover-worktree":
            result = recover_worktree(args.worktree)
        elif args.command in {"reconcile", "resume"}:
            result = reconcile(
                state_path=args.state,
                attempt_id=args.attempt_id,
                expected_epoch=args.expected_epoch,
                gate_event=args.gate_event,
                worktree=args.worktree,
                review_base=args.review_base,
                fingerprint=args.fingerprint,
                soft_cap=args.soft_cap,
                hard_cap=args.hard_cap,
                invocation_sha256=args.invocation_sha256,
                expected_ac_ids=None if args.expected_ac_ids is None else tuple(item.strip() for item in args.expected_ac_ids.split(",") if item.strip()),
            )
        elif args.command == "accept":
            result = accept(state_path=args.state, attempt_id=args.attempt_id, expected_epoch=args.expected_epoch, invocation_sha256=args.invocation_sha256)
        elif args.command == "cancel":
            result = cancel(state_path=args.state, attempt_id=args.attempt_id, expected_epoch=args.expected_epoch, grace_seconds=args.grace_seconds)
        elif args.command == "wait":
            result = wait_for_result(args.state, args.attempt_id, args.timeout)
        else:
            command = list(args.argv)
            if command and command[0] == "--":
                command.pop(0)
            result = launch(
                state_path=args.state,
                ledger_state=args.ledger_state,
                attempt_id=args.attempt_id,
                role=args.role,
                fingerprint=args.fingerprint,
                expected_epoch=args.expected_epoch,
                next_action=args.next_action,
                gate_event=args.gate_event,
                worktree=args.worktree,
                review_base=args.review_base,
                command=command,
                cwd=args.cwd,
                soft_cap=args.soft_cap,
                hard_cap=args.hard_cap,
                context_path=args.context_path,
                invocation_sha256=args.invocation_sha256,
                context_paths=args.fingerprint_context_path,
                contract_paths=args.fingerprint_contract_path,
                evidence_root=args.evidence_root,
                expected_ac_ids=tuple(item.strip() for item in args.expected_ac_ids.split(",") if item.strip()) if args.expected_ac_ids else (),
            )
    except (RuntimeErrorState, OSError, ValueError) as exc:
        print(f"review-runtime: {exc}", file=sys.stderr)
        return 2
    print(json.dumps(result, ensure_ascii=False, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
