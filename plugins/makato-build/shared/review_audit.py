"""Certificate-bound append-only audit delivery, without changing review fingerprints."""

from __future__ import annotations

import copy
import fcntl
import hashlib
import json
import os
import stat
import uuid
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path

import review_scope
from spec_folder import SpecFolderError, resolve_spec_folder


class AuditError(RuntimeError):
    """Publication or its independently checked delivery is unsafe."""


def _sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _encoded(value: object) -> bytes:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")


def _check_roots(state: dict) -> None:
    bound = state.get("root_bindings")
    if bound is not None:
        try:
            if review_scope.root_bindings(state["contract_root"], state["orchestrate_root"]) != bound:
                raise AuditError("live roots differ from frozen audit bindings")
        except review_scope.ScopeError as exc:
            raise AuditError(str(exc)) from exc


def fingerprint(state: dict, worktree: str, review_base: str) -> dict:
    _check_roots(state)
    current = review_scope.fingerprint(
        worktree,
        review_base,
        context_paths=state["context_paths"],
        contract_paths=state["contract_paths"],
        evidence_root=state.get("evidence_root") or worktree,
        contract_root=state.get("contract_root"),
        orchestrate_root=state.get("orchestrate_root"),
    )
    _check_roots(state)
    return current


def _resolve(state: dict, worktree: str) -> tuple[Path, str, list[dict]]:
    _check_roots(state)
    root = Path(state.get("evidence_root") or worktree).absolute()
    try:
        path = resolve_spec_folder(root, state["story"]) / "build.jsonl"
        relative = path.relative_to(root).as_posix()
        path.relative_to(root / "specs")
        if ".." in Path(relative).parts or not path.resolve().is_relative_to((root / "specs").resolve()):
            raise AuditError("canonical audit escapes the selected specs root")
    except (SpecFolderError, ValueError) as exc:
        raise AuditError(f"cannot resolve canonical audit: {exc}") from exc
    identities = []
    # Include ancestors, so replacing a directory with a symlink or another inode fails.
    for component in [root, *(root / Path(*Path(relative).parts[:i]) for i in range(1, len(Path(relative).parts) + 1))]:
        info = component.lstat()
        if stat.S_ISLNK(info.st_mode):
            raise AuditError("canonical audit has a symlink component")
        identities.append({"device": info.st_dev, "inode": info.st_ino, "mode": info.st_mode})
    if not stat.S_ISREG(identities[-1]["mode"]):
        raise AuditError("canonical audit is not a regular file")
    evidence_root = state.get("evidence_root") or worktree
    explicit_inputs = [(evidence_root, relative) for relative in state["context_paths"]]
    try:
        explicit_inputs.extend(
            (root, relative)
            for _, relative, root in (review_scope.contract_input(argument, state.get("contract_root") or evidence_root, state.get("orchestrate_root")) for argument in state["contract_paths"])
        )
    except review_scope.ScopeError as exc:
        raise AuditError(str(exc)) from exc
    for root_path, explicit_relative in explicit_inputs:
        if os.path.samefile(path, Path(root_path) / explicit_relative):
            raise AuditError("canonical audit aliases an explicit context or contract input")
    if info.st_nlink != 1:
        raise AuditError("canonical audit has hardlink aliases")
    return path, relative, identities


@contextmanager
def _audit_file(state: dict, worktree: str, *, writable: bool = False):
    try:
        path, relative, identities = _resolve(state, worktree)
        flags = (os.O_RDWR | os.O_APPEND) if writable else os.O_RDONLY
        fd = os.open(path, flags | os.O_NOFOLLOW)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX if writable else fcntl.LOCK_SH)
            info = os.fstat(fd)
            if identities[-1] != {"device": info.st_dev, "inode": info.st_ino, "mode": info.st_mode}:
                raise AuditError("canonical audit identity changed while opening")
            if info.st_nlink != 1:
                raise AuditError("canonical audit has hardlink aliases")
            with os.fdopen(os.dup(fd), "rb") as handle:
                data = handle.read()
            yield fd, data, relative, identities
            if _resolve(state, worktree)[1:] != (relative, identities):
                raise AuditError("canonical audit path identity changed")
        finally:
            os.close(fd)
    except OSError as exc:
        raise AuditError(f"canonical audit unavailable: {exc}") from exc


def capture(state: dict, worktree: str, current: dict, gate: dict) -> None:
    """Capture once at the successful source gate; unresolved audit grants no exemption."""
    pass_id = next(entry["pass_id"] for entry in reversed(state["passes"]) if entry["scope"] != "background-full")
    certificates = state.setdefault("audit_certificates", [])
    if any(item["pass_id"] == pass_id for item in certificates):
        return
    certificate = {
        "pass_id": pass_id,
        "input_fingerprint": current["sha256"],
        "manifest": current["manifest"],
        "final_review": gate["next_action"] == "complete",
        "source_gate_id": gate["gate_id"],
        "timestamp": datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z"),
    }
    if not certificate["final_review"]:
        certificate["checkpoint_receipt"] = copy.deepcopy(gate["checkpoint_receipt"])
    try:
        with _audit_file(state, worktree) as (_, data, relative, identities):
            if data and not data.endswith(b"\n"):
                raise AuditError("canonical audit prefix must end in a newline")
            certificate["audit"] = {"path": relative, "identity": identities, "prefix_length": len(data), "prefix_sha256": _sha(data)}
    except AuditError as exc:
        certificate["audit_error"] = str(exc)
    certificates.append(certificate)


def certificate(state: dict) -> dict | None:
    latest = next((entry for entry in reversed(state["passes"]) if entry["scope"] != "background-full"), {})
    return next((entry for entry in reversed(state.get("audit_certificates", [])) if entry["pass_id"] == latest.get("pass_id")), None)


def _source(state: dict, cert: dict, worktree: str) -> dict:
    # The ledger, not a caller receipt, remains the source of all publication rows.
    import review_loop

    if _sha(_encoded(cert["manifest"])) != cert["input_fingerprint"]:
        raise AuditError("source manifest hash does not match reviewed input")
    latest = review_loop._latest_pass(state)
    if latest.get("pass_id") != cert["pass_id"] or latest.get("run_id") != state["run_id"] or latest.get("input_fingerprint") != cert["input_fingerprint"] or latest.get("status") != "success":
        raise AuditError("successful source certificate is stale")
    source_gate = next((gate for gate in state["gate_history"] if gate["gate_id"] == cert["source_gate_id"]), {})
    anchor = cert["input_fingerprint"]
    if source_gate.get("input_fingerprint") != anchor:
        raise AuditError("source gate is not bound to the reviewed anchor")
    if cert["final_review"]:
        checked = copy.deepcopy(state)
        checked["current_changed_files"] = cert["manifest"]["changed_files"]
        if source_gate.get("next_action") != "complete" or review_loop._gate_decision(checked, "review", None, anchor)["next_action"] != "complete":
            raise AuditError("source final-full certificate no longer verifies")
    else:
        receipt = cert.get("checkpoint_receipt")
        if (
            latest.get("scope") != "delta"
            or latest.get("blocking")
            or not isinstance(receipt, dict)
            or review_loop._unclosed_constituents(state, anchor)
            or receipt not in state["checkpoint_receipts"]
            or source_gate.get("checkpoint_receipt") != receipt
            or receipt.get("input_fingerprint") != anchor
            or receipt.get("pass_id") != latest["pass_id"]
        ):
            raise AuditError("source checkpoint certificate no longer verifies")
        try:
            scope = review_loop._checkpoint_scope(state, worktree, cert["manifest"], receipt["snapshot"], latest)
            if receipt.get("checkpoint_scope") != scope:
                raise AuditError("source checkpoint scope coverage differs from authoritative inputs")
            review_loop._checkpoint_coverage(state, latest, scope)
        except (review_loop.LoopError, review_scope.ScopeError) as exc:
            raise AuditError(str(exc)) from exc
    return latest


def _append(state: dict, cert: dict, worktree: str) -> bytes:
    latest = _source(state, cert, worktree)
    base = {"ts": cert["timestamp"], "skill": "build-review", "story": state["story"], "status": "ok"}
    binding = {"run_id": state["run_id"], "pass_id": latest["pass_id"], "input_fingerprint": cert["input_fingerprint"]}
    rows = []
    if cert["final_review"]:
        rows.append({**base, "step": "ac-verification", "data": {**binding, "ac_verdicts": latest["ac_verdicts"]}})
    rows.append(
        {
            **base,
            "step": "session",
            "data": {**binding, "final_review": cert["final_review"], "passes": latest["pass"], "repair_rounds": latest["after_round"], "files_reviewed": latest["files_reviewed"]},
        }
    )
    return b"".join(_encoded(row) + b"\n" for row in rows)


def _normalized(cert: dict, current: dict, worktree: str, audit_path: Path) -> None:
    manifest = copy.deepcopy(current["manifest"])
    # Only the canonical physical location in this worktree can be normalized.
    try:
        relative = audit_path.resolve().relative_to(Path(worktree).resolve()).as_posix()
    except ValueError:
        relative = None
    if relative is not None:
        key = "worktree:" + relative
        original = next((entry for entry in cert["manifest"]["files"] if entry["path"] == key), None)
        manifest["files"] = [entry for entry in manifest["files"] if entry["path"] != key]
        if original is not None:
            manifest["files"].append(original)
        # fingerprint orders changed entries first, then explicit context and contracts.
        order = {entry["path"]: i for i, entry in enumerate(cert["manifest"]["files"])}
        manifest["files"].sort(key=lambda entry: order.get(entry["path"], len(order)))
        manifest["changed_files"] = [name for name in manifest["changed_files"] if name != relative]
        if relative in cert["manifest"]["changed_files"]:
            manifest["changed_files"].append(relative)
            manifest["changed_files"].sort()
    if manifest != cert["manifest"] or current["sha256"] != _sha(_encoded(current["manifest"])):
        raise AuditError("delivery contains changes outside the canonical audit append")


def _transition(state: dict, cert: dict, append: bytes, current: dict) -> dict:
    return {
        "schema": "review-audit-transition-v1",
        "story": state["story"],
        "run_id": state["run_id"],
        "pass_id": cert["pass_id"],
        "input_fingerprint": cert["input_fingerprint"],
        "delivery_fingerprint": current["sha256"],
        **cert["audit"],
        "append_length": len(append),
        "append_sha256": _sha(append),
    }


def _check_bytes(cert: dict, data: bytes, append: bytes, relative: str, identities: list[dict], *, pending: bool = False) -> bytes:
    audit = cert.get("audit")
    if not isinstance(audit, dict) or relative != audit["path"] or identities != audit["identity"]:
        raise AuditError("canonical audit identity or path differs from source certificate")
    length = audit["prefix_length"]
    if len(data) < length or _sha(data[:length]) != audit["prefix_sha256"]:
        raise AuditError("canonical audit prefix was rewritten or truncated")
    tail = data[length:]
    if (not pending and tail != append) or (pending and not append.startswith(tail)):
        raise AuditError("canonical audit has unrelated, malformed or excess tail bytes")
    return tail


def verify(state: dict, cert: dict, worktree: str, current: dict) -> dict:
    append = _append(state, cert, worktree)
    if cert.get("intent") != {"append": append.decode("utf-8")}:
        raise AuditError("publication intent does not match ledger-derived rows")
    with _audit_file(state, worktree) as (_, data, relative, identities):
        _check_bytes(cert, data, append, relative, identities)
        path = Path(state.get("evidence_root") or worktree).absolute() / relative
        _normalized(cert, current, worktree, path)
        expected = _transition(state, cert, append, current)
        if cert.get("audit_transition") != expected:
            raise AuditError("audit transition does not match independently verified delivery")
    result = {"input_fingerprint": cert["input_fingerprint"], "delivery_fingerprint": current["sha256"], "audit_transition": expected, "final_review": cert["final_review"]}
    if not cert["final_review"]:
        result["checkpoint_receipt"] = {**copy.deepcopy(cert["checkpoint_receipt"]), "delivery_fingerprint": current["sha256"], "audit_transition": expected}
    return result


def publish(state: dict, state_path: str, worktree: str, review_base: str, save) -> dict:
    cert = certificate(state)
    if cert is None:
        raise AuditError("publication requires a persisted successful source certificate")
    if "audit" not in cert:
        raise AuditError(cert.get("audit_error", "no authorized canonical audit"))
    append = _append(state, cert, worktree)
    current = fingerprint(state, worktree, review_base)
    if cert.get("audit_transition") is not None:
        return verify(state, cert, worktree, current)
    # Pending intent is reconciled before requiring pre-publication equality.
    with _audit_file(state, worktree, writable=True) as (fd, data, relative, identities):
        if "intent" in cert:
            if cert["intent"] != {"append": append.decode("utf-8")}:
                raise AuditError("pending publication intent is not ledger-derived")
            tail = _check_bytes(cert, data, append, relative, identities, pending=True)
            _normalized(cert, current, worktree, Path(state.get("evidence_root") or worktree).absolute() / relative)
        else:
            if current["sha256"] != cert["input_fingerprint"] or current["manifest"] != cert["manifest"]:
                raise AuditError("worktree changed before publication")
            tail = _check_bytes(cert, data, b"", relative, identities)
            cert["intent"] = {"append": append.decode("utf-8")}
            save(state_path, state)  # fsync intent before any append bytes.
        # Persisting intent can yield to other processes. Recheck physical aliases
        # before any append, not only when detecting collateral changes afterward.
        if _resolve(state, worktree)[1:] != (relative, identities):
            raise AuditError("canonical audit path identity changed before append")
        if os.fstat(fd).st_nlink != 1:
            raise AuditError("canonical audit has hardlink aliases")
        os.lseek(fd, 0, os.SEEK_END)
        remaining = memoryview(append)[len(tail) :]
        while remaining:
            written = os.write(fd, remaining)
            if written <= 0:
                raise AuditError("audit append made no progress")
            remaining = remaining[written:]
        os.fsync(fd)
        current = fingerprint(state, worktree, review_base)
        _normalized(cert, current, worktree, Path(state.get("evidence_root") or worktree).absolute() / relative)
        cert["audit_transition"] = _transition(state, cert, append, current)
        save(state_path, state)
    return verify(state, cert, worktree, current)


def operational_log(state: dict, worktree: str, entry: dict | None = None) -> dict:
    """Keep narration/R1 transport outside every protected review input."""
    git_dir = Path(review_scope._git(worktree, "rev-parse", "--absolute-git-dir").decode().strip()).resolve()
    run_id = str(uuid.UUID(state["run_id"]))
    path = git_dir / "makato-review-loop" / run_id / "operations.jsonl"
    current = fingerprint(state, worktree, state["review_base"])
    roots = {
        "worktree": worktree,
        "context": state.get("evidence_root") or worktree,
        "contract": state.get("contract_root") or state.get("evidence_root") or worktree,
        "orchestrate": state.get("orchestrate_root"),
    }
    for item in current["manifest"]["files"]:
        source, relative = item["path"].split(":", 1)
        if source not in roots or not roots[source]:
            raise AuditError(f"unknown or unresolved protected source: {source!r}")
        if item.get("contract"):
            argument = relative if source == "contract" else f"{source}:{relative}"
            try:
                _, relative, selected = review_scope.contract_input(argument, roots["contract"], state.get("orchestrate_root"))
            except review_scope.ScopeError as exc:
                raise AuditError(str(exc)) from exc
        else:
            selected = roots[source]
        protected = Path(selected) / relative
        if path.resolve() == protected.resolve() or (path.exists() and protected.exists() and os.path.samefile(path, protected)):
            raise AuditError("operational log aliases a protected review input")
    for component in (path.parent.parent, path.parent, path):
        if component.is_symlink():
            raise AuditError("operational log has a symlink component")
    if path.exists() and (not path.is_file() or path.stat().st_nlink != 1):
        raise AuditError("operational log is not a private regular file")
    _check_roots(state)
    if entry is not None:
        if not isinstance(entry, dict):
            raise AuditError("operational log entry must be an object")
        path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    comment_id = None
    if path.exists() or entry is not None:
        flags = os.O_RDWR | os.O_APPEND | os.O_CREAT if entry is not None else os.O_RDONLY
        fd = os.open(path, flags | os.O_NOFOLLOW, 0o600)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX if entry is not None else fcntl.LOCK_SH)
            info = os.fstat(fd)
            if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or not os.path.samefile(path, fd):
                raise AuditError("operational log identity changed")
            with os.fdopen(os.dup(fd), "rb") as stream:
                for line in stream:
                    row = json.loads(line)
                    if row.get("step") == "progress-comment-id":
                        comment_id = row["data"]["comment_id"]
            if entry is not None:
                # Preserve build-log's single-physical-line JSONL normalization.
                payload = (json.dumps(entry, ensure_ascii=True, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8")
                with os.fdopen(os.dup(fd), "ab") as stream:
                    stream.write(payload)
                    stream.flush()
                    os.fsync(stream.fileno())
        finally:
            os.close(fd)
    return {"path": str(path), "progress_comment_id": comment_id}
