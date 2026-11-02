"""Finding history, lens merging, convergence and repair partitioning for the build-review repair loop.

``review_scope.py`` decides *what* the next review covers; this helper remembers
*what was found* across passes, so the loop can merge parallel lens reviews,
recognise a finding that keeps coming back, stop when repairs no longer converge
and split a round's repairs into file-disjoint groups:

    init       create (or resume) the per-story loop state file
    lenses     should this full pass be split into parallel lens reviews?
    merge      merge one or more diff-reviewer R1 results into one R1 and record the pass
    repaired   record that a repair round claimed to fix finding ids
    next       convergence decision: may another repair round start?
    partition  group a round's findings into file-disjoint repair groups
    background should a background full pass of the pre-repair tree run this round?

Input problems exit 2 with ``review-loop: <message>`` on stderr.
"""

from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
import re
import sys
import tempfile
import uuid
from collections.abc import Iterable
from functools import wraps
from pathlib import Path

import review_eval
import review_scope

LENSES = ("security-privacy", "state-concurrency", "error-handling", "resources-performance", "contract-ac")
LENS_MODES = ("auto", "on", "off")
SPLIT_MIN_CHANGED_LINES = 400
SPLIT_MIN_CHANGED_FILES = 15
DEFAULT_SOFT_CAP = 3
DEFAULT_HARD_CAP = 8
DEFAULT_MAX_GROUPS = 4
SEVERITY_RANK = {"CRITICAL": 4, "MAJOR": 3, "SUGGESTION": 2, "NITPICK": 1}
BLOCKING = ("CRITICAL", "MAJOR")
REDESIGN_RECURRENCES = 2
STOP_RECURRENCES = 3
STATE_VERSION = 2
_ID_PATTERN = re.compile(r"^F-(\d+)$")
_INVARIANT_PREFIX = "I-"
_CONSTITUENT_PREFIX = "C-"


class LoopError(RuntimeError):
    """An input problem that makes the loop state unreliable."""


# ---------------------------------------------------------------- state


def _locked_state(func):
    """Serialize each state read/modify/write sequence across processes."""

    @wraps(func)
    def wrapped(state_path: str, *args, **kwargs):
        lock_path = os.path.abspath(state_path) + ".lock"
        os.makedirs(os.path.dirname(lock_path), mode=0o700, exist_ok=True)
        descriptor = os.open(lock_path, os.O_CREAT | os.O_RDWR, 0o600)
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX)
            return func(state_path, *args, **kwargs)
        finally:
            fcntl.flock(descriptor, fcntl.LOCK_UN)
            os.close(descriptor)

    return wrapped


def _load_state(path: str) -> dict:
    try:
        with open(path, encoding="utf-8") as handle:
            state = json.load(handle)
    except FileNotFoundError:
        raise LoopError(f"no loop state at {path}; run init first") from None
    except (OSError, json.JSONDecodeError) as exc:
        raise LoopError(f"unreadable loop state {path}: {exc}") from None
    if not isinstance(state, dict):
        raise LoopError(f"corrupt loop state in {path}: expected an object")
    if state.get("version") != STATE_VERSION:
        raise LoopError(f"incompatible loop state version {state.get('version')!r} in {path}; explicit migration to version {STATE_VERSION} is required")
    required = {
        "story": str,
        "review_base": str,
        "run_id": str,
        "next_id": int,
        "passes": list,
        "findings": dict,
        "raw_envelopes": list,
        "gate_history": list,
        "max_repair_round": int,
        "repair_attempts": list,
        "checkpoint_receipts": list,
        "current_fingerprint": (str, type(None)),
        "context_paths": list,
        "contract_paths": list,
        "evidence_root": (str, type(None)),
        "expected_ac_ids": (list, type(None)),
        "caps": dict,
        "contract_root": (str, type(None)),
    }
    for field, expected in required.items():
        if field not in state or isinstance(state[field], bool) or not isinstance(state[field], expected):
            raise LoopError(f"corrupt loop state in {path}: invalid {field}")
    if state["next_id"] < 1 or state["max_repair_round"] < 0 or not state["story"] or not state["review_base"] or not state["run_id"]:
        raise LoopError(f"corrupt loop state in {path}: invalid durable identity or counters")
    caps = state["caps"]
    if set(caps) != {"soft", "hard"} or any(type(value) is not int or value < 1 for value in caps.values()) or caps["soft"] > caps["hard"]:
        raise LoopError(f"corrupt loop state in {path}: invalid durable caps")
    if state["current_fingerprint"] is not None and not re.fullmatch(r"[0-9a-f]{64}", state["current_fingerprint"]):
        raise LoopError(f"corrupt loop state in {path}: invalid current fingerprint")
    if state["expected_ac_ids"] is not None and (
        not state["expected_ac_ids"]
        or any(not isinstance(ac_id, str) or not ac_id.strip() for ac_id in state["expected_ac_ids"])
        or len(set(state["expected_ac_ids"])) != len(state["expected_ac_ids"])
    ):
        raise LoopError(f"corrupt loop state in {path}: invalid expected AC ids")
    if any(not isinstance(path_value, str) or not path_value for path_value in state["context_paths"] + state["contract_paths"]):
        raise LoopError(f"corrupt loop state in {path}: invalid context or contract paths")
    previous_pass = 0
    for entry in state["passes"]:
        if not isinstance(entry, dict) or isinstance(entry.get("pass"), bool) or not isinstance(entry.get("pass"), int) or entry["pass"] <= previous_pass:
            raise LoopError(f"corrupt loop state in {path}: invalid pass sequence")
        if entry.get("scope") not in ("full", "delta", "final-full", "background-full") or entry.get("status") not in ("success", "failure", "partial"):
            raise LoopError(f"corrupt loop state in {path}: invalid pass status or scope")
        if isinstance(entry.get("after_round"), bool) or not isinstance(entry.get("after_round"), int) or entry["after_round"] < 0:
            raise LoopError(f"corrupt loop state in {path}: invalid pass repair round")
        if not isinstance(entry.get("blocking"), list) or not isinstance(entry.get("constituent_ids"), list):
            raise LoopError(f"corrupt loop state in {path}: invalid pass findings")
        previous_pass = entry["pass"]
    previous_gate = 0
    for entry in state["gate_history"]:
        if (
            not isinstance(entry, dict)
            or entry.get("gate_id") != previous_gate + 1
            or entry.get("next_action") not in ("review", "confirm", "repair-local", "redesign", "certify", "complete", "blocked")
            or not isinstance(entry.get("reason"), str)
        ):
            raise LoopError(f"corrupt loop state in {path}: invalid gate history")
        previous_gate = entry["gate_id"]
    max_finding_id = 0
    for finding_id, record in state["findings"].items():
        match = _ID_PATTERN.fullmatch(finding_id) if isinstance(finding_id, str) else None
        if not match or not isinstance(record, dict):
            raise LoopError(f"corrupt loop state in {path}: invalid finding record")
        max_finding_id = max(max_finding_id, int(match.group(1)))
        if not isinstance(record.get("invariant_id"), str) or not record["invariant_id"] or record.get("severity") not in SEVERITY_RANK:
            raise LoopError(f"corrupt loop state in {path}: invalid finding identity for {finding_id}")
        if not isinstance(record.get("raised_in"), list) or not isinstance(record.get("repair_claims"), list) or not isinstance(record.get("constituents"), dict):
            raise LoopError(f"corrupt loop state in {path}: invalid finding history for {finding_id}")
        if any(isinstance(round_number, bool) or not isinstance(round_number, int) or round_number < 1 for round_number in record["repair_claims"]):
            raise LoopError(f"corrupt loop state in {path}: invalid repair claims for {finding_id}")
        for raised in record["raised_in"]:
            if not isinstance(raised, dict) or any(isinstance(raised.get(field), bool) or not isinstance(raised.get(field), int) or raised[field] < 0 for field in ("pass", "after_round")):
                raise LoopError(f"corrupt loop state in {path}: invalid raise history for {finding_id}")
        for constituent_id, constituent in record["constituents"].items():
            if not isinstance(constituent_id, str) or not isinstance(constituent, dict) or constituent.get("constituent_id") != constituent_id:
                raise LoopError(f"corrupt loop state in {path}: invalid constituent for {finding_id}")
            if any(not isinstance(constituent.get(field), list) for field in ("sites", "occurrences", "confirmation_history", "closure_history")):
                raise LoopError(f"corrupt loop state in {path}: invalid constituent history for {finding_id}")
    if state["next_id"] <= max_finding_id:
        raise LoopError(f"corrupt loop state in {path}: next id would reuse an existing finding id")
    if state["max_repair_round"] < max((entry["after_round"] for entry in state["passes"]), default=0):
        raise LoopError(f"corrupt loop state in {path}: repair counter is behind recorded passes")
    if any(not isinstance(entry, dict) or not isinstance(entry.get("envelope"), dict) for entry in state["raw_envelopes"]):
        raise LoopError(f"corrupt loop state in {path}: invalid raw R1 envelope")
    for attempt in state["repair_attempts"]:
        if (
            not isinstance(attempt, dict)
            or isinstance(attempt.get("round"), bool)
            or not isinstance(attempt.get("round"), int)
            or attempt["round"] < 1
            or attempt.get("mode") not in ("local", "redesign")
            or attempt.get("status") not in ("started", "claimed")
            or not isinstance(attempt.get("ids"), list)
            or not isinstance(attempt.get("claimed_ids"), list)
            or not isinstance(attempt.get("pass_id"), str)
            or not isinstance(attempt.get("input_fingerprint"), str)
        ):
            raise LoopError(f"corrupt loop state in {path}: invalid repair attempt")
        if any(finding_id not in state["findings"] for finding_id in attempt["ids"] + attempt["claimed_ids"]):
            raise LoopError(f"corrupt loop state in {path}: repair attempt references an unknown finding")
    if state["max_repair_round"] < max((attempt["round"] for attempt in state["repair_attempts"]), default=0):
        raise LoopError(f"corrupt loop state in {path}: repair attempt exceeds durable counter")
    if any(not isinstance(entry, dict) or not isinstance(entry.get("task_ids"), list) for entry in state["checkpoint_receipts"]):
        raise LoopError(f"corrupt loop state in {path}: invalid checkpoint receipt")
    return state


def _save_state(path: str, state: dict) -> None:
    directory = os.path.dirname(os.path.abspath(path))
    os.makedirs(directory, mode=0o700, exist_ok=True)
    handle, tmp = tempfile.mkstemp(prefix=".review-loop-", suffix=".json", dir=directory)
    try:
        os.fchmod(handle, 0o600)
        with os.fdopen(handle, "w", encoding="utf-8") as out:
            json.dump(state, out, indent=1, sort_keys=True)
            out.write("\n")
            out.flush()
            os.fsync(out.fileno())
        os.replace(tmp, path)
        directory_fd = os.open(directory, os.O_RDONLY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise


def _initial_state(story: str, review_base: str) -> dict:
    state = {
        "version": STATE_VERSION,
        "story": story,
        "review_base": review_base,
        "run_id": str(uuid.uuid4()),
        "next_id": 1,
        "max_repair_round": 0,
        "repair_attempts": [],
        "passes": [],
        "findings": {},
        "raw_envelopes": [],
        "gate_history": [],
        "confirmations": {},
        "mechanical_evidence": None,
        "checkpoint_receipts": [],
        "current_fingerprint": None,
        "context_paths": [],
        "contract_paths": [],
        "evidence_root": None,
        "contract_root": None,
        "expected_ac_ids": None,
    }
    _limits(state)
    return state


@_locked_state
def init(path: str, story: str, review_base: str) -> dict[str, object]:
    """Resume only the identical ledger; never silently reset incompatible history."""
    if os.path.exists(path):
        state = _load_state(path)
        if state.get("story") != story or state.get("review_base") != review_base:
            raise LoopError("ledger story or review base changed; explicit migration is required")
        gate = _gate_decision(state, "initial", None, state.get("current_fingerprint"))
        _save_state(path, state)
        return {"state": path, "resumed": True, "next_id": state["next_id"], "run_id": state["run_id"], "gate": gate}
    state = _initial_state(story, review_base)
    gate = _gate_decision(state, "initial", None, None)
    _save_state(path, state)
    return {"state": path, "resumed": False, "next_id": 1, "run_id": state["run_id"], "gate": gate}


def _id_key(finding_id: str) -> tuple[int, str]:
    match = _ID_PATTERN.match(finding_id)
    return (int(match.group(1)), finding_id) if match else (sys.maxsize, finding_id)


def _ids(raw: str | None) -> list[str]:
    return [item.strip() for item in (raw or "").split(",") if item.strip()]


def _digest(prefix: str, value: object) -> str:
    encoded = json.dumps(value, sort_keys=True, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    return prefix + hashlib.sha256(encoded).hexdigest()[:24]


def _canonical_invariant(finding: dict) -> str | None:
    invariant = finding.get("invariant")
    if not isinstance(invariant, str) or not invariant.strip():
        return None
    return " ".join(invariant.split()).casefold()


def _invariant_id(finding: dict, raw_id: object) -> str:
    canonical = _canonical_invariant(finding)
    if canonical:
        return _digest(_INVARIANT_PREFIX, canonical)
    return _digest(_INVARIANT_PREFIX, {"raw_id": raw_id, "finding": finding})


def _constituent_id(invariant_id: str, finding: dict) -> str:
    identity = {
        "raw_id": finding.get("id"),
        "lens": finding.get("lens"),
        **{key: finding.get(key) for key in ("category", "description", "evidence", "sites") if finding.get(key) is not None},
    }
    return _digest(_CONSTITUENT_PREFIX, [invariant_id, identity])


def _record_gate(state: dict, event: str, next_action: str, reason: str, fingerprint: str | None) -> dict:
    entry = {
        "gate_id": len(state["gate_history"]) + 1,
        "event": event,
        "next_action": next_action,
        "reason": reason,
        "input_fingerprint": fingerprint,
        "repair_round": state["max_repair_round"],
    }
    state["gate_history"].append(entry)
    return entry


# ---------------------------------------------------------------- lenses


def lenses(
    worktree: str,
    review_base: str,
    mode: str | None,
    profile: str = "standard",
    pass_kind: str = "initial",
    qualification: str | None = None,
    config_fingerprint: str | None = None,
    model: str | None = None,
    settings: dict | None = None,
) -> dict[str, object]:
    """Split a full pass and optionally qualify risk-lens duplicate sampling."""
    raw = mode if mode is not None else os.environ.get("MAKATO_REVIEW_LENSES")
    warning = None
    value = (raw or "auto").strip().lower() or "auto"
    if value not in LENS_MODES:
        warning = f"invalid MAKATO_REVIEW_LENSES {raw!r}; using auto"
        value = "auto"
    if profile not in ("standard", "deep") or pass_kind not in ("initial", "first-rereview", "later"):
        raise LoopError("profile must be standard|deep and pass-kind initial|first-rereview|later")
    changed_lines = 0
    tracked: set[str] = set()
    fields = review_scope._nul_split(review_scope._git(worktree, "diff", "--numstat", "--no-renames", "-z", review_base))
    for entry in fields:
        added, deleted, path = entry.split("\t", 2)
        tracked.add(path)
        changed_lines += (int(added) if added.isdigit() else 0) + (int(deleted) if deleted.isdigit() else 0)
    untracked = review_scope._nul_split(review_scope._git(worktree, "ls-files", "--others", "--exclude-standard", "-z"))
    for path in untracked:
        text = review_scope._read_text(worktree, path)
        if text is not None:
            changed_lines += len(text.splitlines())
    changed_files = len(tracked | set(untracked))
    split = value == "on" or (value == "auto" and (changed_lines > SPLIT_MIN_CHANGED_LINES or changed_files > SPLIT_MIN_CHANGED_FILES))
    sample_counts = {lens: 1 for lens in LENSES}
    sampling_enabled = False
    qualification_error = None
    if value != "off" and profile == "deep" and pass_kind in ("initial", "first-rereview"):
        try:
            if not qualification or not config_fingerprint or not model or not isinstance(settings, dict):
                raise LoopError("qualified Deep sampling requires bound evidence, pinned model and exact settings")
            review_eval.verify_qualification(
                qualification,
                config_fingerprint,
                model,
                source_root=Path(__file__).resolve().parent.parent,
                settings=settings,
            )
            for lens in ("error-handling", "state-concurrency"):
                sample_counts[lens] = 2
            sampling_enabled = True
        except (OSError, ValueError, LoopError) as exc:
            qualification_error = str(exc)
    elif profile == "deep":
        qualification_error = "Deep duplicate sampling is disabled in off mode and after the first re-review"
    split = split or sampling_enabled
    result: dict[str, object] = {
        "split": split,
        "lenses": list(LENSES) if split else [],
        "changed_lines": changed_lines,
        "changed_files": changed_files,
        "mode": value,
        "profile": profile,
        "pass_kind": pass_kind,
        "sample_counts": sample_counts,
        "sampling_enabled": sampling_enabled,
        "configuration_fingerprint": config_fingerprint,
    }
    if warning:
        result["warning"] = warning
    if qualification_error:
        result["sampling_warning"] = qualification_error
    return result


# ---------------------------------------------------------------- merge


def _parse_r1(path: str) -> dict:
    """The R1 object of a reviewer result: a plain JSON file, or the last JSON object in a transcript."""
    try:
        text = Path(path).read_text(encoding="utf-8")
    except OSError as exc:
        raise LoopError(f"cannot read {path}: {exc}") from None
    try:
        value = json.loads(text)
    except json.JSONDecodeError:
        value = None
        decoder = json.JSONDecoder()
        index = 0
        while (start := text.find("{", index)) != -1:
            try:
                candidate, end = decoder.raw_decode(text, start)
            except json.JSONDecodeError:
                index = start + 1
                continue
            if isinstance(candidate, dict):
                value = candidate
            index = end
    if not isinstance(value, dict):
        raise LoopError(f"{path}: no R1 JSON object")
    return value


def _site(raw: object, where: str) -> dict:
    if not isinstance(raw, dict) or not isinstance(raw.get("file"), str) or not raw["file"] or isinstance(raw.get("line"), bool) or not isinstance(raw.get("line"), int) or raw["line"] < 1:
        raise LoopError(f"{where}: every site needs a file and a positive integer line")
    site = {"file": raw["file"], "line": raw["line"]}
    if raw.get("note"):
        site["note"] = raw["note"]
    return site


def _validated_findings(path: str, r1: dict) -> list[dict]:
    if r1.get("schema") != "r1":
        raise LoopError(f"{path}: schema must be 'r1'")
    status = r1.get("status")
    if status not in ("success", "failure", "partial"):
        raise LoopError(f"{path}: status must be success, failure, or partial")
    errors = r1.get("errors", [])
    if not isinstance(errors, list) or any(not isinstance(error, str) or not error.strip() for error in errors):
        raise LoopError(f"{path}: errors must be a list of non-empty strings")
    data = r1.get("data")
    if not isinstance(data, dict) or not isinstance(data.get("findings"), list):
        raise LoopError(f"{path}: data.findings must be a list")
    if "files_reviewed" not in data or isinstance(data["files_reviewed"], bool) or not isinstance(data["files_reviewed"], int) or data["files_reviewed"] < 0:
        raise LoopError(f"{path}: data.files_reviewed must be a non-negative integer")
    if not isinstance(data.get("reviewer_id"), str) or not data["reviewer_id"].strip():
        raise LoopError(f"{path}: data.reviewer_id must identify the actual reviewer instance")
    if not isinstance(data.get("file_citations"), list):
        raise LoopError(f"{path}: data.file_citations must be a list")
    if data["file_citations"]:
        _valid_citations(data["file_citations"], f"{path}: file coverage")
    elif data["files_reviewed"] > 0:
        raise LoopError(f"{path}: reviewed files need file_citations")
    if "ac_verdicts" in data and not isinstance(data["ac_verdicts"], list):
        raise LoopError(f"{path}: data.ac_verdicts must be a list")
    if data.get("lens") is not None and data["lens"] not in LENSES:
        raise LoopError(f"{path}: data.lens is not a recognized review lens")
    findings: list[dict] = []
    counts: dict[str, int] = dict.fromkeys(BLOCKING, 0)
    for number, raw in enumerate(data["findings"], start=1):
        where = f"{path}: finding {number}"
        if not isinstance(raw, dict) or raw.get("severity") not in SEVERITY_RANK:
            raise LoopError(f"{where}: severity must be one of {', '.join(SEVERITY_RANK)}")
        finding = dict(raw)
        finding["lens"] = raw.get("lens") or data.get("lens")
        if finding["severity"] in BLOCKING:
            counts[finding["severity"]] += 1
            if not isinstance(raw.get("invariant"), str) or not raw["invariant"].strip():
                raise LoopError(f"{where}: a blocking finding needs an invariant")
            if not isinstance(raw.get("sites"), list) or not raw["sites"]:
                raise LoopError(f"{where}: a blocking finding needs at least one site")
            finding["sites"] = [_site(site, where) for site in raw["sites"]]
        elif isinstance(raw.get("sites"), list) and raw["sites"]:
            finding["sites"] = [_site(site, where) for site in raw["sites"]]
        elif isinstance(raw.get("file"), str) and isinstance(raw.get("line"), int) and not isinstance(raw.get("line"), bool):
            finding["sites"] = [{"file": raw["file"], "line": raw["line"]}]
        else:
            finding["sites"] = []
        findings.append(finding)
    for severity, field in (("CRITICAL", "critical_count"), ("MAJOR", "major_count")):
        count = data.get(field)
        if isinstance(count, bool) or not isinstance(count, int) or count != counts[severity]:
            raise LoopError(f"{path}: data.{field}={count!r} but {counts[severity]} {severity} finding(s) listed")
    for severity, field in (("SUGGESTION", "suggestion_count"), ("NITPICK", "nitpick_count")):
        if field in data:
            count = data[field]
            actual = sum(1 for finding in findings if finding["severity"] == severity)
            if isinstance(count, bool) or not isinstance(count, int) or count != actual:
                raise LoopError(f"{path}: data.{field}={count!r} but {actual} {severity} finding(s) listed")
    blocking_count = counts["CRITICAL"] + counts["MAJOR"]
    if status == "failure" and (blocking_count == 0 or not errors):
        raise LoopError(f"{path}: failure requires blocking findings and non-empty errors")
    if status == "success" and (blocking_count or errors):
        raise LoopError(f"{path}: success cannot contain blocking findings or errors")
    return findings


def _components(count: int, linked: Iterable[tuple[int, int]]) -> list[list[int]]:
    parent = list(range(count))

    def find(item: int) -> int:
        while parent[item] != item:
            parent[item] = parent[parent[item]]
            item = parent[item]
        return item

    for left, right in linked:
        root_left, root_right = find(left), find(right)
        if root_left != root_right:
            parent[max(root_left, root_right)] = min(root_left, root_right)
    groups: dict[int, list[int]] = {}
    for item in range(count):
        groups.setdefault(find(item), []).append(item)
    return sorted(groups.values(), key=lambda members: members[0])


def _known_id(finding: dict, state: dict) -> str | None:
    value = finding.get("id")
    return value if isinstance(value, str) and value in state["findings"] else None


@_locked_state
def merge(
    state_path: str,
    pass_number: int,
    scope: str,
    after_round: int,
    snapshot: str | None,
    r1_files: list[str],
    input_fingerprint: str | None = None,
    context_paths: list[str] | None = None,
    contract_paths: list[str] | None = None,
    evidence_root: str | None = None,
    expected_ac_ids: list[str] | None = None,
    contract_root: str | None = None,
) -> dict:
    """Merge validated R1 envelopes losslessly; only invariant identity groups findings."""
    state = _load_state(state_path)
    if not isinstance(pass_number, int) or isinstance(pass_number, bool) or pass_number < 1:
        raise LoopError("pass number must be a positive integer")
    if state["passes"] and pass_number <= state["passes"][-1]["pass"]:
        raise LoopError("pass number must increase monotonically")
    if not isinstance(after_round, int) or isinstance(after_round, bool) or after_round < 0 or (after_round < state["max_repair_round"] and scope != "background-full"):
        raise LoopError(f"after-round cannot move behind durable repair round {state['max_repair_round']}")
    if scope not in ("full", "delta", "final-full", "background-full"):
        raise LoopError(f"invalid review scope {scope!r}")
    inputs = [(path, _parse_r1(path)) for path in r1_files]
    if not inputs:
        raise LoopError("merge needs at least one R1 file")
    validated = [(path, r1, _validated_findings(path, r1)) for path, r1 in inputs]
    fingerprints = {value for _, r1, _ in validated if isinstance((value := r1.get("data", {}).get("input_fingerprint")), str) and value}
    if input_fingerprint:
        fingerprints.add(input_fingerprint)
    if len(fingerprints) > 1:
        raise LoopError("R1 inputs have conflicting input fingerprints")
    if not fingerprints:
        raise LoopError("review result needs an explicit input fingerprint; never infer it from mutable state")
    fingerprint = next(iter(fingerprints))
    if not re.fullmatch(r"[0-9a-f]{64}", fingerprint):
        raise LoopError("review input fingerprint must be a lowercase SHA-256")
    if state["current_fingerprint"] not in (None, fingerprint) and scope != "background-full":
        raise LoopError("review result is stale for the current input fingerprint")
    _bind_inputs(state, context_paths, contract_paths, evidence_root, contract_root, expected_ac_ids)
    if scope != "background-full" or state["current_fingerprint"] is None:
        state["current_fingerprint"] = fingerprint
    state["max_repair_round"] = max(state["max_repair_round"], after_round)

    entries: list[dict] = []
    envelope_refs: list[int] = []
    for path, r1, findings in validated:
        envelope_id = len(state["raw_envelopes"]) + 1
        state["raw_envelopes"].append(
            {
                "envelope_id": envelope_id,
                "run_id": state["run_id"],
                "pass_id": f"P-{pass_number}",
                "repair_round": after_round,
                "input_fingerprint": fingerprint,
                "lens": r1["data"].get("lens"),
                "envelope": r1,
            }
        )
        envelope_refs.append(envelope_id)
        for finding in findings:
            invariant_id = _invariant_id(finding, finding.get("id"))
            constituent_id = _constituent_id(invariant_id, finding)
            entries.append(
                {
                    "finding": finding,
                    "invariant_id": invariant_id,
                    "constituent_id": constituent_id,
                    "envelope_id": envelope_id,
                }
            )

    groups: dict[str, list[dict]] = {}
    for entry in entries:
        groups.setdefault(entry["invariant_id"], []).append(entry)

    merged: list[dict] = []
    new_blocking: list[str] = []
    for invariant_id, group_entries in groups.items():
        group = [entry["finding"] for entry in group_entries]
        lead = max(group, key=lambda finding: SEVERITY_RANK[finding["severity"]])
        matching_ids = sorted(
            (finding_id for finding_id, record in state["findings"].items() if record.get("invariant_id") == invariant_id),
            key=_id_key,
        )
        if matching_ids:
            finding_id = matching_ids[0]
        else:
            finding_id = f"F-{state['next_id']:03d}"
            state["next_id"] += 1
        sites: dict[tuple[str, int], dict] = {}
        constituents: dict[str, dict] = {}
        for entry in group_entries:
            finding = entry["finding"]
            for site in finding["sites"]:
                sites.setdefault((site["file"], site["line"]), site)
            cid = entry["constituent_id"]
            constituent = constituents.setdefault(
                cid,
                {
                    "constituent_id": cid,
                    "invariant_id": invariant_id,
                    "invariant": finding.get("invariant"),
                    "category": finding.get("category"),
                    "description": finding.get("description"),
                    "evidence": finding.get("evidence"),
                    "sites": [],
                    "raw_ids": [],
                    "raw_findings": [],
                    "envelope_ids": [],
                },
            )
            constituent["sites"] = sorted(
                {(site["file"], site["line"]): site for site in constituent["sites"] + finding["sites"]}.values(),
                key=lambda site: (site["file"], site["line"]),
            )
            raw_id = finding.get("id")
            if raw_id not in constituent["raw_ids"]:
                constituent["raw_ids"].append(raw_id)
            constituent["raw_findings"].append(finding)
            if entry["envelope_id"] not in constituent["envelope_ids"]:
                constituent["envelope_ids"].append(entry["envelope_id"])

        result = {key: lead.get(key) for key in ("severity", "category", "invariant", "file", "line", "evidence", "description")}
        result.update(
            {
                "id": finding_id,
                "invariant_id": invariant_id,
                "sites": [sites[key] for key in sorted(sites)],
                "lenses": sorted({finding["lens"] for finding in group if finding.get("lens")}),
                "constituent_ids": sorted(constituents),
                "constituents": [constituents[cid] for cid in sorted(constituents)],
                "raw_finding_ids": [finding.get("id") for finding in group],
            }
        )
        merged.append(result)

        record = state["findings"].setdefault(
            finding_id,
            {
                "invariant_id": invariant_id,
                "invariant": result.get("invariant"),
                "raised_in": [],
                "repair_claims": [],
                "constituents": {},
            },
        )
        previous_severity = record.get("severity")
        severity = result["severity"]
        if previous_severity in SEVERITY_RANK and SEVERITY_RANK[previous_severity] > SEVERITY_RANK[severity]:
            severity = previous_severity
        record.update(
            {
                "invariant_id": invariant_id,
                "invariant": result.get("invariant"),
                "severity": severity,
                "file": result.get("file"),
                "sites": result["sites"],
            }
        )
        if result["severity"] in BLOCKING:
            if not record["raised_in"]:
                new_blocking.append(finding_id)
            if not record["raised_in"] or record["raised_in"][-1]["pass"] != pass_number:
                record["raised_in"].append({"pass": pass_number, "after_round": after_round, "input_fingerprint": fingerprint})
        for cid, constituent in constituents.items():
            stored = record["constituents"].setdefault(
                cid,
                {
                    "constituent_id": cid,
                    "invariant_id": invariant_id,
                    "invariant": constituent.get("invariant"),
                    "category": constituent.get("category"),
                    "description": constituent.get("description"),
                    "evidence": constituent.get("evidence"),
                    "sites": [],
                    "occurrences": [],
                    "confirmation_history": [],
                    "closure_history": [],
                },
            )
            stored["sites"] = sorted(
                {(site["file"], site["line"]): site for site in stored["sites"] + constituent["sites"]}.values(),
                key=lambda site: (site["file"], site["line"]),
            )
            for raw_finding in constituent["raw_findings"]:
                stored["occurrences"].append(
                    {
                        "pass": pass_number,
                        "repair_round": after_round,
                        "input_fingerprint": fingerprint,
                        "envelope_ids": constituent["envelope_ids"],
                        "raw_finding": raw_finding,
                    }
                )
        # Carry the whole invariant surface forward, without repeating its raw history in every dispatch.
        result["constituent_ids"] = sorted(record["constituents"])
        result["constituents"] = [
            {key: record["constituents"][cid].get(key) for key in ("constituent_id", "invariant_id", "invariant", "category", "description", "evidence", "sites")}
            | {
                "raw_ids": [item["raw_finding"].get("id") for item in record["constituents"][cid]["occurrences"]],
                "envelope_ids": sorted({value for item in record["constituents"][cid]["occurrences"] for value in item["envelope_ids"]}),
            }
            for cid in result["constituent_ids"]
        ]
        result["sites"] = sorted(
            {(site["file"], site["line"]): site for constituent in record["constituents"].values() for site in constituent["sites"]}.values(),
            key=lambda site: (site["file"], site["line"]),
        )
        record["sites"] = result["sites"]

    merged.sort(key=lambda finding: (-SEVERITY_RANK[finding["severity"]], _id_key(finding["id"])))
    blocking = [finding for finding in merged if finding["severity"] in BLOCKING]
    counts = {severity: sum(1 for finding in merged if finding["severity"] == severity) for severity in SEVERITY_RANK}
    statuses = [r1["status"] for _, r1, _ in validated]
    status = "partial" if "partial" in statuses else ("failure" if "failure" in statuses or counts["CRITICAL"] + counts["MAJOR"] else "success")
    contract = [r1 for _, r1, _ in validated if r1["data"].get("lens") == "contract-ac"]
    if contract:
        verdicts = [verdict for r1 in contract for verdict in (r1["data"].get("ac_verdicts") or [])]
    elif len(inputs) == 1:
        verdicts = inputs[0][1]["data"].get("ac_verdicts") or []
    else:
        verdicts = []
    reviewed = [r1["data"].get("files_reviewed") for _, r1, _ in validated]
    errors = [error for _, r1, _ in validated for error in r1.get("errors", [])]
    errors.extend(
        f"{finding.get('file', finding['sites'][0]['file'] if finding['sites'] else '?')}:"
        f"{finding.get('line', finding['sites'][0]['line'] if finding['sites'] else '?')} — "
        f"[{finding['severity']}][{finding.get('category', 'unknown')}] {finding.get('description', '')}"
        for finding in blocking
    )
    pass_record = {
        "pass": pass_number,
        "pass_id": f"P-{pass_number}",
        "run_id": state["run_id"],
        "scope": scope,
        "after_round": after_round,
        "snapshot": snapshot,
        "input_fingerprint": fingerprint,
        "status": status,
        "blocking": [finding["id"] for finding in blocking],
        "constituent_ids": sorted({entry["constituent_id"] for entry in entries if entry["finding"]["severity"] in BLOCKING}),
        "new_blocking": new_blocking,
        "raw_envelope_ids": envelope_refs,
        "ac_verdicts": verdicts,
        "files_reviewed": max((value for value in reviewed if isinstance(value, int) and not isinstance(value, bool)), default=0),
        "file_citations": [citation for _, r1, _ in validated for citation in r1["data"]["file_citations"]],
        "review_lenses": sorted({r1["data"]["lens"] for _, r1, _ in validated if r1["data"].get("lens")}),
        "unscoped_full": len(validated) == 1 and validated[0][1]["data"].get("lens") is None,
    }
    state["passes"].append(pass_record)
    gate = _gate_decision(state, "review", None, state["current_fingerprint"])
    pass_record["gate"] = gate
    _save_state(state_path, state)
    return {
        "schema": "r1",
        "agent": "diff-reviewer",
        "status": status,
        "summary": f"merged {len(inputs)} reviewer result(s)",
        "files_changed": [],
        "tests_written": [],
        "errors": errors,
        "data": {
            "run_id": state["run_id"],
            "pass_id": f"P-{pass_number}",
            "pass_number": pass_number,
            "repair_round": after_round,
            "input_fingerprint": fingerprint,
            "review_scope": scope,
            "lenses": sorted({lens for _, r1, _ in validated if (lens := r1["data"].get("lens"))}),
            "critical_count": counts["CRITICAL"],
            "major_count": counts["MAJOR"],
            "suggestion_count": counts["SUGGESTION"],
            "nitpick_count": counts["NITPICK"],
            "files_reviewed": max((value for value in reviewed if isinstance(value, int) and not isinstance(value, bool)), default=0),
            "findings": merged,
            "ac_verdicts": verdicts,
            "raw_envelope_ids": envelope_refs,
            "next_action": gate["next_action"],
            "gate": gate,
        },
    }


# ---------------------------------------------------------------- repairs and convergence


def _valid_citations(raw: object, where: str) -> list[dict]:
    if not isinstance(raw, list) or not raw:
        raise LoopError(f"{where}: citations must be a non-empty list")
    citations = []
    for citation in raw:
        if (
            not isinstance(citation, dict)
            or not isinstance(citation.get("file"), str)
            or not citation["file"]
            or isinstance(citation.get("line"), bool)
            or not isinstance(citation.get("line"), int)
            or citation["line"] < 1
        ):
            raise LoopError(f"{where}: every citation needs a file and positive integer line")
        citations.append({"file": citation["file"], "line": citation["line"]})
    return citations


def _unclosed_constituents(state: dict, fingerprint: str | None) -> list[tuple[str, str, dict]]:
    result = []
    for finding_id, record in state["findings"].items():
        if record.get("severity") not in BLOCKING:
            continue
        for constituent_id, constituent in record.get("constituents", {}).items():
            latest_raise = max((item["pass"] for item in constituent.get("occurrences", [])), default=0)
            closure = next(
                (entry for entry in reversed(constituent.get("closure_history", [])) if entry.get("input_fingerprint") == fingerprint),
                {},
            )
            closed = closure.get("disposition") in ("fixed", "false_positive") and closure.get("pass", 0) >= latest_raise
            if not closed:
                result.append((finding_id, constituent_id, constituent))
    return result


def _current_blocking_constituents(state: dict, latest: dict, fingerprint: str | None) -> list[tuple[str, str, dict]]:
    blocking = set(latest.get("blocking", []))
    current_ids = set(latest.get("constituent_ids", []))
    return [
        (finding_id, constituent_id, constituent) for finding_id, constituent_id, constituent in _unclosed_constituents(state, fingerprint) if finding_id in blocking and constituent_id in current_ids
    ]


def _has_confirmation(constituent: dict, fingerprint: str | None, pass_number: int) -> bool:
    entry = next(
        (item for item in reversed(constituent.get("confirmation_history", [])) if item.get("input_fingerprint") == fingerprint),
        {},
    )
    return entry.get("disposition") == "confirmed" and entry.get("pass", 0) >= pass_number


def _apply_dispositions(state: dict, event: str, evidence: dict, fingerprint: str | None) -> list[str]:
    reviewer = evidence.get("reviewer_id")
    if not isinstance(reviewer, str) or not reviewer.strip() or evidence.get("independent") is not True:
        raise LoopError(f"{event} evidence requires an independent reviewer_id")
    if evidence.get("input_fingerprint") != fingerprint or not fingerprint:
        raise LoopError(f"{event} evidence fingerprint does not match the current review input")
    if reviewer.strip().casefold() in ("coder", "diff-reviewer"):
        raise LoopError(f"{event} reviewer must be independent of coder and diff-reviewer")
    coder_ids = {value.casefold() for attempt in state["repair_attempts"] for value in attempt.get("coder_ids", [])}
    if reviewer.strip().casefold() in coder_ids:
        raise LoopError(f"{event} reviewer cannot be a repair coder")
    dispositions = evidence.get("dispositions")
    if not isinstance(dispositions, list):
        raise LoopError(f"{event} evidence requires a dispositions list")
    latest = _latest_pass(state)
    if latest.get("input_fingerprint") != fingerprint:
        raise LoopError(f"{event} evidence requires a fresh review of the current input fingerprint")
    # Omitted blockers remain historical closure obligations, not current repair targets.
    required = _current_blocking_constituents(state, latest, fingerprint) if event == "confirm" else _unclosed_constituents(state, fingerprint)
    required_keys = {(finding_id, constituent_id) for finding_id, constituent_id, _ in required}
    observed: set[tuple[str, str]] = set()
    uncertainty = []
    staged: list[tuple[dict, dict, str]] = []
    for number, item in enumerate(dispositions, start=1):
        where = f"{event} disposition {number}"
        if not isinstance(item, dict):
            raise LoopError(f"{where} must be an object")
        finding_id, constituent_id = item.get("finding_id"), item.get("constituent_id")
        key = (finding_id, constituent_id)
        if key not in required_keys or key in observed:
            raise LoopError(f"{where} is unknown or duplicated")
        constituent = state["findings"][finding_id]["constituents"][constituent_id]
        envelope_ids = {value for occurrence in constituent["occurrences"] for value in occurrence["envelope_ids"]}
        raisers = {raw["envelope"]["data"]["reviewer_id"].strip().casefold() for raw in state["raw_envelopes"] if raw["envelope_id"] in envelope_ids}
        if reviewer.strip().casefold() in raisers:
            raise LoopError(f"{where}: the finding reporter cannot independently confirm or close it")
        observed.add(key)
        disposition = item.get("disposition")
        allowed = ("confirmed", "false_positive", "uncertain") if event == "confirm" else ("fixed", "false_positive", "uncertain")
        if disposition not in allowed:
            raise LoopError(f"{where}: disposition must be one of {', '.join(allowed)}")
        explanation = item.get("evidence")
        if not isinstance(explanation, str) or not explanation.strip():
            raise LoopError(f"{where}: non-empty evidence is required")
        repair_scope = item.get("repair_scope", "unknown")
        if repair_scope not in ("local", "architectural", "cross-boundary", "unknown"):
            raise LoopError(f"{where}: invalid repair_scope")
        citations = _valid_citations(item.get("citations"), where)
        if event != "confirm" and disposition == "fixed" and constituent_id in latest.get("constituent_ids", []):
            raise LoopError(f"{where}: finding remains present in the latest review")
        record = state["findings"][finding_id]["constituents"][constituent_id]
        entry = {
            "reviewer_id": reviewer.strip(),
            "independent": True,
            "disposition": disposition,
            "evidence": explanation,
            "citations": citations,
            "input_fingerprint": fingerprint,
            "pass": latest["pass"],
            "repair_scope": repair_scope,
        }
        staged.append((record, entry, disposition))
        if disposition == "uncertain":
            uncertainty.append(f"{finding_id}/{constituent_id}")
    missing = required_keys - observed
    if missing:
        missing_ids = [f"{finding_id}/{constituent_id}" for finding_id, constituent_id in sorted(missing)]
        raise LoopError(f"{event} evidence omits required constituents: {', '.join(missing_ids)}")
    for record, entry, disposition in staged:
        if event == "confirm":
            record["confirmation_history"].append(entry)
            state["confirmations"].setdefault(f"{record['invariant_id']}/{record['constituent_id']}", []).append(entry)
            if disposition == "false_positive":
                record["closure_history"].append(entry)
        else:
            record["closure_history"].append(entry)
    return uncertainty


def _latest_pass(state: dict) -> dict:
    return next((entry for entry in reversed(state["passes"]) if entry["scope"] != "background-full"), {})


def _ac_complete(pass_record: dict, expected_ac_ids: list[str] | None) -> bool:
    if not expected_ac_ids:
        return False
    verdicts = pass_record.get("ac_verdicts")
    if not isinstance(verdicts, list) or len(verdicts) != len(expected_ac_ids):
        return False
    seen: set[str] = set()
    for verdict in verdicts:
        if not isinstance(verdict, dict) or verdict.get("verified") is not True:
            return False
        ac_id = verdict.get("ac_id")
        if not isinstance(ac_id, str) or not ac_id.strip() or ac_id in seen:
            return False
        seen.add(ac_id)
        if not isinstance(verdict.get("evidence"), str) or not verdict["evidence"].strip():
            return False
        try:
            _valid_citations(verdict.get("citations"), "AC verdict")
        except LoopError:
            return False
    return seen == set(expected_ac_ids)


def _new_blockers_by_round(state: dict) -> dict[int, int]:
    result: dict[int, int] = {}
    for record in state["findings"].values():
        if record.get("raised_in"):
            first = record["raised_in"][0]["after_round"]
            result[first] = result.get(first, 0) + 1
    return result


def _bind_inputs(
    state: dict,
    context_paths: list[str] | None,
    contract_paths: list[str] | None,
    evidence_root: str | None,
    contract_root: str | None,
    expected_ac_ids: list[str] | None,
) -> None:
    for key, values in (("context_paths", context_paths), ("contract_paths", contract_paths)):
        if values is not None:
            if any(not isinstance(value, str) or not value.strip() for value in values):
                raise LoopError(f"{key} must contain non-empty paths")
            if not set(state[key]).issubset(values):
                raise LoopError(f"{key} cannot shrink during a review; explicit migration is required")
            state[key] = sorted(set(values))
    for key, root in (("evidence_root", evidence_root), ("contract_root", contract_root)):
        if root is not None:
            resolved = str(Path(root).resolve())
            if state.get(key) is not None and str(Path(state[key]).resolve()) != resolved:
                raise LoopError(f"{key} changed; explicit migration is required")
            state[key] = resolved
    if expected_ac_ids is not None:
        if not expected_ac_ids or any(not isinstance(value, str) or not value.strip() for value in expected_ac_ids):
            raise LoopError("expected AC ids must be non-empty authoritative IDs")
        if len(set(expected_ac_ids)) != len(expected_ac_ids):
            raise LoopError("expected AC ids must be distinct")
        if state["expected_ac_ids"] is not None and set(state["expected_ac_ids"]) != set(expected_ac_ids):
            raise LoopError("expected AC ids changed; explicit migration is required")
        state["expected_ac_ids"] = sorted(expected_ac_ids)


def _repair_policy(
    state: dict,
    latest: dict,
    fingerprint: str | None,
    soft_cap: str | None,
    hard_cap: str | None,
) -> tuple[str, str]:
    """One policy for ordinary, manual and resumed repair dispatches."""
    if latest.get("status") == "partial" or latest.get("input_fingerprint") != fingerprint:
        return "review", "current input needs a complete independent review"
    targets = [(finding_id, constituent) for finding_id, _, constituent in _current_blocking_constituents(state, latest, fingerprint)]
    if not targets:
        return "certify", "clean re-review needs independent constituent closure"
    pending = next(
        (attempt for attempt in reversed(state["repair_attempts"]) if attempt["pass_id"] == latest.get("pass_id") and attempt["input_fingerprint"] == fingerprint and attempt["status"] == "started"),
        None,
    )
    # A reservation consumes its round once, but may be adopted without requesting another.
    rounds = state["max_repair_round"] - (1 if pending is not None else 0)
    soft, hard = _limits(state, soft_cap, hard_cap)
    if rounds >= hard:
        return "blocked", "hard repair cap reached"
    counts = [recurrences(state["findings"][finding_id]) for finding_id, _ in targets]
    if any(count >= STOP_RECURRENCES for count in counts):
        return "blocked", "recurring finding requires human decision"
    if any(not _has_confirmation(constituent, fingerprint, latest["pass"]) for _, constituent in targets):
        return "confirm", "blocker constituents need independent confirmation"
    if rounds >= soft:
        new = _new_blockers_by_round(state)
        if new.get(rounds, 0) > 0 and new.get(rounds, 0) >= new.get(rounds - 1, 0):
            return "blocked", "repair loop is not converging at the soft cap"
    needs_plan = any(next(item for item in reversed(constituent["confirmation_history"]) if item.get("input_fingerprint") == fingerprint)["repair_scope"] != "local" for _, constituent in targets)
    if needs_plan or any(count >= REDESIGN_RECURRENCES for count in counts):
        return "redesign", "architectural, uncertain-boundary or recurring invariant requires a reviewed plan"
    return "repair-local", "confirmed local blockers remain within the convergence policy"


def _reserve_repair_attempt(
    state: dict,
    latest: dict,
    fingerprint: str | None,
    mode: str,
    ids: list[str],
    soft_cap: str | None,
    hard_cap: str | None,
) -> tuple[dict | None, str | None]:
    pass_id = latest.get("pass_id")
    if not pass_id or not fingerprint:
        return None, "repair requires a current review pass and input fingerprint"
    existing = next(
        (attempt for attempt in reversed(state["repair_attempts"]) if attempt["pass_id"] == pass_id and attempt["input_fingerprint"] == fingerprint),
        None,
    )
    if existing is not None:
        if existing["mode"] == mode and existing["status"] == "started" and existing["ids"] == ids:
            return existing, None
        return None, "a repair attempt is already recorded for this pass"
    _, hard = _limits(state, soft_cap, hard_cap)
    if state["max_repair_round"] >= hard:
        return None, "hard repair cap reached"
    attempt = {
        "round": state["max_repair_round"] + 1,
        "pass_id": pass_id,
        "input_fingerprint": fingerprint,
        "mode": mode,
        "ids": ids,
        "claimed_ids": [],
        "status": "started",
    }
    state["repair_attempts"].append(attempt)
    state["max_repair_round"] = attempt["round"]
    return attempt, None


def _gate_decision(
    state: dict,
    event: str,
    evidence: dict | None,
    fingerprint: str | None,
    soft_cap: str | None = None,
    hard_cap: str | None = None,
    repair_recorded: bool = False,
) -> dict:
    allowed_events = ("initial", "review", "confirm", "repair-local", "redesign", "certify", "complete", "blocked", "checkpoint")
    if event not in allowed_events:
        raise LoopError(f"unknown gate event {event!r}")
    _limits(state, soft_cap, hard_cap)
    if fingerprint:
        state["current_fingerprint"] = fingerprint
    fingerprint = state.get("current_fingerprint")
    uncertainty: list[str] = []
    error: str | None = None
    latest = _latest_pass(state)
    try:
        if event in ("confirm", "certify") and evidence is not None:
            uncertainty = _apply_dispositions(state, event, evidence, fingerprint)
        if event == "checkpoint":
            if evidence is None:
                raise LoopError("checkpoint event requires evidence")
            if not isinstance(evidence.get("evidence"), str) or not evidence["evidence"].strip():
                raise LoopError("checkpoint evidence requires a non-empty review summary")
            _valid_citations(evidence.get("citations"), "checkpoint evidence")
            task_ids = evidence.get("task_ids")
            if not isinstance(task_ids, list) or not task_ids or any(not isinstance(task_id, str) or not task_id.strip() for task_id in task_ids) or len(set(task_ids)) != len(task_ids):
                raise LoopError("checkpoint evidence requires distinct non-empty string task_ids")
            if evidence.get("checkpoint_verified") is not True or evidence.get("final_review") is not False:
                raise LoopError("checkpoint receipt must set checkpoint_verified=true and final_review=false")
            if evidence.get("scope") != "delta" or latest.get("scope") != "delta":
                raise LoopError("checkpoint requires a delta review")
            if evidence.get("pass_id") != latest.get("pass_id") or latest.get("status") != "success":
                raise LoopError("checkpoint evidence must reference the latest successful delta pass")
            if evidence.get("input_fingerprint") != fingerprint or latest.get("input_fingerprint") != fingerprint:
                raise LoopError("checkpoint fingerprint is stale")
            if not isinstance(latest.get("files_reviewed"), int) or latest["files_reviewed"] < 1:
                raise LoopError("checkpoint requires mechanical review coverage of at least one file")
            if latest.get("blocking"):
                raise LoopError("checkpoint cannot pass with blocking findings")
            snapshot = evidence.get("snapshot")
            if not isinstance(snapshot, str) or not snapshot:
                raise LoopError("checkpoint evidence requires the current tree snapshot")
            uncertainty = _apply_dispositions(state, "certify", evidence, fingerprint)
            if uncertainty or _unclosed_constituents(state, fingerprint):
                raise LoopError("checkpoint cannot pass with uncertain or unresolved blocker constituents")
            receipt = {
                "task_ids": task_ids,
                "input_fingerprint": fingerprint,
                "pass_id": latest["pass_id"],
                "scope": "delta",
                "checkpoint_verified": True,
                "final_review": False,
                "snapshot": snapshot,
            }
            state.setdefault("checkpoint_receipts", []).append(receipt)
        if event == "complete" and evidence is not None:
            if evidence.get("event") not in (None, "complete"):
                raise LoopError("completion evidence event must be 'complete'")
            mechanical = evidence.get("mechanical")
            if (
                evidence.get("input_fingerprint") != fingerprint
                or not isinstance(mechanical, dict)
                or mechanical.get("before_fingerprint") != fingerprint
                or mechanical.get("after_fingerprint") != fingerprint
                or mechanical.get("no_change") is not True
                or not isinstance(mechanical.get("evidence"), str)
                or not mechanical["evidence"].strip()
            ):
                raise LoopError("completion evidence requires current fingerprint and mechanical no-change evidence")
            latest = _latest_pass(state)
            if latest.get("scope") != "final-full" or latest.get("status") != "success" or latest.get("input_fingerprint") != fingerprint:
                raise LoopError("mechanical no-change evidence must follow a successful current final-full pass")
            state["mechanical_evidence"] = {
                "input_fingerprint": fingerprint,
                "pass_id": latest.get("pass_id"),
                "no_change": True,
                "before_fingerprint": mechanical["before_fingerprint"],
                "after_fingerprint": mechanical["after_fingerprint"],
                "evidence": mechanical["evidence"],
            }
    except LoopError as exc:
        error = str(exc)

    latest = _latest_pass(state)
    open_constituents = _unclosed_constituents(state, fingerprint)
    attempt = None
    if uncertainty:
        action, reason = "blocked", "independent reviewer marked a constituent uncertain"
    elif error and event in ("confirm", "certify", "complete", "checkpoint", "repair-local", "redesign"):
        action, reason = "blocked", error
    elif event == "blocked":
        action, reason = "blocked", (evidence or {}).get("reason", "explicitly blocked")
    elif event in ("repair-local", "redesign"):
        if repair_recorded:
            action, reason = "review", "repair claim recorded; independent re-review required"
        else:
            action, reason = _repair_policy(state, latest, fingerprint, soft_cap, hard_cap)
            if action == event:
                mode = "local" if event == "repair-local" else "redesign"
                attempt, reserve_error = _reserve_repair_attempt(
                    state,
                    latest,
                    fingerprint,
                    mode,
                    sorted(latest.get("blocking", []), key=_id_key),
                    soft_cap,
                    hard_cap,
                )
                if reserve_error:
                    action, reason = "blocked", reserve_error
                else:
                    reason = "independent confirmations and durable repair reservation are recorded"
            elif event == "redesign" and action == "repair-local":
                action, reason = "blocked", "a bounded local repair does not require a planning cycle"
    elif event == "checkpoint":
        action, reason = "review", "task checkpoint verified; final review remains required"
    elif not state["passes"]:
        action, reason = "review", "no review pass recorded"
    elif latest.get("status") == "partial":
        action, reason = "review", "latest review was partial and cannot certify"
    elif latest.get("input_fingerprint") != fingerprint or not fingerprint:
        action, reason = "review", "worktree changed since latest review; run a fresh review"
    elif open_constituents:
        action, reason = _repair_policy(state, latest, fingerprint, soft_cap, hard_cap)
    elif latest.get("status") != "success":
        action, reason = "review", "latest review is not a complete successful pass"
    elif latest.get("scope") != "final-full":
        action, reason = "certify", "final full review is required"
    elif latest.get("input_fingerprint") != fingerprint or not fingerprint:
        action, reason = "certify", "final review fingerprint is missing or stale"
    elif not set(review_scope.REVIEW_CONTRACT_PATHS).issubset(state.get("contract_paths", [])):
        action, reason = "certify", "the complete versioned review contract must be included in the input manifest"
    elif (
        not isinstance(latest.get("files_reviewed"), int)
        or isinstance(latest.get("files_reviewed"), bool)
        or latest["files_reviewed"] < len(state.get("current_changed_files", []))
        or not set(state.get("current_changed_files", [])).issubset(citation["file"] for citation in latest.get("file_citations", []))
        or (not latest.get("unscoped_full") and set(latest.get("review_lenses", [])) != set(LENSES))
    ):
        action, reason = "certify", "final full pass has incomplete file, citation or review-lens coverage"
    elif not _ac_complete(latest, state.get("expected_ac_ids")):
        action, reason = "certify", "final per-AC verdicts and citations are incomplete or do not match expected AC ids"
    elif (
        not isinstance(state.get("mechanical_evidence"), dict)
        or state["mechanical_evidence"].get("input_fingerprint") != fingerprint
        or state["mechanical_evidence"].get("pass_id") != latest.get("pass_id")
        or state["mechanical_evidence"].get("no_change") is not True
        or state["mechanical_evidence"].get("before_fingerprint") != fingerprint
        or state["mechanical_evidence"].get("after_fingerprint") != fingerprint
    ):
        action, reason = "certify", "mechanical no-change evidence is missing or stale"
    else:
        action, reason = "complete", "final full review, constituent closures, AC citations, and mechanical evidence match"

    if event == "checkpoint" and not error and not uncertainty:
        action, reason = "review", "task checkpoint verified; final review remains required"
    gate = _record_gate(state, event, action, reason, fingerprint)
    if attempt is not None:
        gate["repair_attempt"] = attempt
    if event == "checkpoint" and not error and not uncertainty:
        gate["checkpoint_receipt"] = state["checkpoint_receipts"][-1]
    return gate


def _read_evidence(path: str | None) -> dict | None:
    if path is None:
        return None
    try:
        value = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise LoopError(f"cannot read gate evidence {path}: {exc}") from None
    if not isinstance(value, dict):
        raise LoopError("gate evidence must be a JSON object")
    return value


@_locked_state
def gate(
    state_path: str,
    event: str,
    worktree: str,
    review_base: str,
    evidence_path: str | None = None,
    expected_fingerprint: str | None = None,
    soft_cap: str | None = None,
    hard_cap: str | None = None,
    context_paths: list[str] | None = None,
    contract_paths: list[str] | None = None,
    evidence_root: str | None = None,
    expected_ac_ids: list[str] | None = None,
    contract_root: str | None = None,
) -> dict:
    state = _load_state(state_path)
    if review_base != state["review_base"]:
        result = _gate_decision(state, "blocked", {"reason": "review base changed; explicit migration is required"}, state.get("current_fingerprint"))
        _save_state(state_path, state)
        return result
    _bind_inputs(state, context_paths, contract_paths, evidence_root, contract_root, expected_ac_ids)
    root = state.get("evidence_root") or worktree
    try:
        current_input = review_scope.fingerprint(
            worktree,
            review_base,
            context_paths=state.get("context_paths", []),
            contract_paths=state.get("contract_paths", []),
            evidence_root=root,
            contract_root=state.get("contract_root"),
        )
        current = current_input["sha256"]
        state["current_changed_files"] = current_input["manifest"]["changed_files"]
    except review_scope.ScopeError as exc:
        result = _gate_decision(state, "blocked", {"reason": f"cannot compute current fingerprint: {exc}"}, state.get("current_fingerprint"))
        _save_state(state_path, state)
        return result
    if expected_fingerprint and expected_fingerprint != current:
        result = _gate_decision(state, "blocked", {"reason": "supplied fingerprint does not match current worktree fingerprint"}, current)
        _save_state(state_path, state)
        return result
    try:
        evidence = _read_evidence(evidence_path)
    except LoopError as exc:
        evidence = {"reason": str(exc)}
        event = "blocked"
    if event == "checkpoint" and evidence is not None:
        try:
            evidence["snapshot"] = review_scope.snapshot(worktree)
        except review_scope.ScopeError as exc:
            result = _gate_decision(state, "blocked", {"reason": f"cannot snapshot checkpoint tree: {exc}"}, current)
            _save_state(state_path, state)
            return result
    result = _gate_decision(state, event, evidence, current, soft_cap, hard_cap)
    _save_state(state_path, state)
    result["current_fingerprint"] = current
    return result


@_locked_state
def checkpoint_receipt(
    state_path: str,
    task_ids: list[str],
    input_fingerprint: str,
    pass_id: str,
    worktree: str,
    review_base: str,
) -> dict:
    state = _load_state(state_path)
    if review_base != state["review_base"]:
        raise LoopError("review base changed; checkpoint is stale")
    current = review_scope.fingerprint(
        worktree,
        review_base,
        context_paths=state.get("context_paths", []),
        contract_paths=state.get("contract_paths", []),
        evidence_root=state.get("evidence_root") or worktree,
        contract_root=state.get("contract_root"),
    )["sha256"]
    expected_ids = list(task_ids)
    matching_pass = next(
        (
            record
            for record in state["passes"]
            if record.get("pass_id") == pass_id and record.get("scope") == "delta" and record.get("status") == "success" and record.get("input_fingerprint") == current
        ),
        None,
    )
    if matching_pass is None or state.get("current_fingerprint") != current:
        raise LoopError("checkpoint pass is stale or not a successful delta pass")
    for receipt in reversed(state.get("checkpoint_receipts", [])):
        if (
            receipt.get("task_ids") == expected_ids
            and receipt.get("input_fingerprint") == input_fingerprint == current
            and receipt.get("pass_id") == pass_id
            and receipt.get("checkpoint_verified") is True
            and receipt.get("final_review") is False
        ):
            return receipt
    raise LoopError("no matching persisted checkpoint receipt for current worktree")


@_locked_state
def repaired(state_path: str, repair_round: int, ids: list[str], coder_id: str) -> dict[str, object]:
    state = _load_state(state_path)
    if not isinstance(coder_id, str) or not coder_id.strip():
        raise LoopError("repair claim requires the actual coder instance id")
    coder_id = coder_id.strip()
    unknown = [finding_id for finding_id in ids if finding_id not in state["findings"]]
    if unknown:
        raise LoopError(f"unknown finding id(s): {', '.join(unknown)}")
    if not ids:
        raise LoopError("a repair claim must include at least one finding id")
    current_fingerprint = state.get("current_fingerprint")
    attempt = next(
        (item for item in reversed(state["repair_attempts"]) if item["round"] == repair_round and item["status"] == "started"),
        None,
    )
    if attempt is None:
        raise LoopError("repair claim requires a persisted started repair attempt")
    latest = _latest_pass(state)
    if repair_round != state["max_repair_round"] or attempt["pass_id"] != latest.get("pass_id"):
        raise LoopError("repair attempt is stale or does not match the durable repair round")
    if not set(ids).issubset(set(attempt["ids"])):
        raise LoopError("repair claim includes findings outside the reserved attempt")
    fingerprint = attempt["input_fingerprint"]
    if not fingerprint:
        raise LoopError("cannot record a repair without a persisted input fingerprint")
    for finding_id in ids:
        record = state["findings"][finding_id]
        if record.get("severity") not in BLOCKING:
            raise LoopError(f"{finding_id} is not a blocking finding and cannot consume a repair round")
        constituents = [constituent for item_finding, _, constituent in _unclosed_constituents(state, fingerprint) if item_finding == finding_id]
        current_constituents = [constituent for item_finding, _, constituent in _current_blocking_constituents(state, latest, fingerprint) if item_finding == finding_id]
        if not current_constituents or any(not _has_confirmation(constituent, fingerprint, latest["pass"]) for constituent in current_constituents):
            raise LoopError(f"{finding_id} requires independent confirmation for every current blocking constituent before repair")
        if any(
            entry.get("reviewer_id", "").casefold() == coder_id.casefold()
            for constituent in constituents
            for entry in constituent["confirmation_history"]
            if entry.get("input_fingerprint") == fingerprint and entry.get("disposition") == "confirmed"
        ):
            raise LoopError("the confirming verifier cannot also be the repair coder")
        if attempt["mode"] == "local" and recurrences(record) >= REDESIGN_RECURRENCES:
            raise LoopError(f"{finding_id} requires redesign before another local repair")
    for finding_id in ids:
        claims = state["findings"][finding_id]["repair_claims"]
        if repair_round not in claims:
            claims.append(repair_round)
        if finding_id not in attempt["claimed_ids"]:
            attempt["claimed_ids"].append(finding_id)
    if coder_id not in attempt.setdefault("coder_ids", []):
        attempt["coder_ids"].append(coder_id)
    if set(attempt["claimed_ids"]) >= set(attempt["ids"]):
        attempt["status"] = "claimed"
    gate_result = _gate_decision(state, "repair-local", None, current_fingerprint, repair_recorded=True)
    _save_state(state_path, state)
    return {"round": repair_round, "ids": ids, "next_action": gate_result["next_action"], "gate": gate_result}


def recurrences(record: dict) -> int:
    """Count repair claims contradicted by a later raise of the same invariant."""
    raised_after = [raise_["after_round"] for raise_ in record["raised_in"]]
    return sum(1 for claim in set(record["repair_claims"]) if any(after >= claim for after in raised_after))


def _cap(raw: str | None, default: int, name: str, warnings: list[str]) -> int:
    if raw is None or raw.strip() == "":
        return default
    value = raw.strip()
    if value.isdigit() and int(value) > 0:
        return int(value)
    warnings.append(f"invalid {name} {raw!r}; using {default}")
    return default


def _limits(state: dict, soft_cap: str | None = None, hard_cap: str | None = None) -> tuple[int, int]:
    """Resume retains limits; later configuration can tighten, never raise them."""
    previous = state.get("caps", {"soft": DEFAULT_SOFT_CAP, "hard": DEFAULT_HARD_CAP})
    warnings: list[str] = []
    soft = _cap(soft_cap if soft_cap is not None else os.environ.get("MAKATO_MAX_REPAIR_ROUNDS"), previous["soft"], "MAKATO_MAX_REPAIR_ROUNDS", warnings)
    hard = _cap(hard_cap if hard_cap is not None else os.environ.get("MAKATO_MAX_REPAIR_ROUNDS_HARD"), previous["hard"], "MAKATO_MAX_REPAIR_ROUNDS_HARD", warnings)
    if "caps" in state:
        soft, hard = min(soft, previous["soft"]), min(hard, previous["hard"])
    soft = min(soft, hard)
    state["caps"] = {"soft": soft, "hard": hard}
    state["cap_warnings"] = sorted(set(state.get("cap_warnings", [])) | set(warnings))
    return soft, hard


def partition(findings_path: str, ids: list[str], max_groups: int) -> dict[str, list[dict]]:
    """File-disjoint repair groups: findings that share a site file stay with one coder."""
    if max_groups < 1:
        raise LoopError("--max-groups must be at least 1")
    r1 = _parse_r1(findings_path)
    raw_data = r1.get("data")
    data: dict = raw_data if isinstance(raw_data, dict) else {}
    by_id = {finding.get("id"): finding for finding in data.get("findings") or [] if isinstance(finding, dict)}
    unknown = [finding_id for finding_id in ids if finding_id not in by_id]
    if unknown:
        raise LoopError(f"{findings_path}: unknown finding id(s): {', '.join(unknown)}")
    chosen = sorted(set(ids), key=_id_key)
    files = [
        {site["file"] for site in by_id[finding_id].get("sites") or [] if isinstance(site, dict) and site.get("file")} | ({by_id[finding_id]["file"]} if by_id[finding_id].get("file") else set())
        for finding_id in chosen
    ]
    pairs = [(left, right) for left in range(len(chosen)) for right in range(left + 1, len(chosen)) if files[left] & files[right]]
    groups = [{"ids": [chosen[index] for index in members], "files": set().union(*(files[index] for index in members))} for members in _components(len(chosen), pairs)]
    while len(groups) > max_groups:
        order = sorted(range(len(groups)), key=lambda index: (len(groups[index]["files"]), index))
        keep, absorb = sorted(order[:2])
        groups[keep] = {"ids": sorted(groups[keep]["ids"] + groups[absorb]["ids"], key=_id_key), "files": groups[keep]["files"] | groups[absorb]["files"]}
        del groups[absorb]
        groups.sort(key=lambda group: _id_key(group["ids"][0]))
    return {"groups": [{"group": number, "ids": group["ids"], "files": sorted(group["files"])} for number, group in enumerate(groups, start=1)]}


def background(state_path: str, repair_round: int, mode: str | None) -> dict[str, object]:
    resolved, warning = review_scope.resolve_mode(mode if mode is not None else os.environ.get("MAKATO_REVIEW_SCOPE"))
    state = _load_state(state_path)
    previous = [entry for entry in state["passes"] if entry["scope"] == "background-full"]
    if resolved == "full":
        result: dict[str, object] = {"run": False, "reason": "legacy full mode reviews everything every pass"}
    elif repair_round < 2:
        result = {"run": False, "reason": "round 1 relies on the full first pass"}
    elif not previous:
        result = {"run": True, "reason": "first background full pass"}
    elif previous[-1]["new_blocking"]:
        result = {"run": True, "reason": "last background pass found new blockers"}
    else:
        result = {"run": False, "reason": "last background pass found nothing new"}
    if warning:
        result["warning"] = warning
    return result


# ---------------------------------------------------------------- CLI


def _main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)

    cmd = sub.add_parser("init", help="create or resume the loop state")
    cmd.add_argument("--state", required=True)
    cmd.add_argument("--story", required=True)
    cmd.add_argument("--review-base", required=True)

    cmd = sub.add_parser("fingerprint", help="hash current review bytes and explicit context/contract files")
    cmd.add_argument("--worktree", required=True)
    cmd.add_argument("--review-base", required=True)
    cmd.add_argument("--evidence-root", default=None)
    cmd.add_argument("--contract-root", default=None)
    cmd.add_argument("--context-path", action="append", default=[])
    cmd.add_argument("--contract-path", action="append", default=[])

    cmd = sub.add_parser("lenses", help="lens-split and qualified sampling decision for a full pass")
    cmd.add_argument("--worktree", required=True)
    cmd.add_argument("--review-base", required=True)
    cmd.add_argument("--mode", default=None, help="auto|on|off; defaults to $MAKATO_REVIEW_LENSES")
    cmd.add_argument("--profile", choices=("standard", "deep"), default="standard")
    cmd.add_argument("--pass-kind", choices=("initial", "first-rereview", "later"), default="initial")
    cmd.add_argument("--qualification", default=None)
    cmd.add_argument("--config-fingerprint", default=None)
    cmd.add_argument("--model", default=None)
    cmd.add_argument("--settings", default=None, help="exact evaluation configuration settings as JSON")

    cmd = sub.add_parser("merge", help="merge reviewer R1 files and record the pass")
    cmd.add_argument("--state", required=True)
    cmd.add_argument("--pass", dest="pass_number", type=int, required=True)
    cmd.add_argument("--scope", required=True, choices=("full", "delta", "final-full", "background-full"))
    cmd.add_argument("--after-round", type=int, required=True)
    cmd.add_argument("--snapshot", default=None)
    cmd.add_argument("--fingerprint", default=None)
    cmd.add_argument("--context-path", action="append", default=None)
    cmd.add_argument("--contract-path", action="append", default=None)
    cmd.add_argument("--evidence-root", default=None)
    cmd.add_argument("--contract-root", default=None)
    cmd.add_argument("--expected-ac-ids", default=None)
    cmd.add_argument("r1_files", nargs="+")

    cmd = sub.add_parser("repaired", help="record a repair round's claimed fixes")
    cmd.add_argument("--state", required=True)
    cmd.add_argument("--round", dest="repair_round", type=int, required=True)
    cmd.add_argument("--ids", required=True)
    cmd.add_argument("--coder-id", required=True)

    cmd = sub.add_parser("gate", help="persist a deterministic decision for the next review transition")
    cmd.add_argument("--state", required=True)
    cmd.add_argument("--event", required=True, choices=("initial", "review", "confirm", "repair-local", "redesign", "certify", "complete", "blocked", "checkpoint"))
    cmd.add_argument("--worktree", required=True)
    cmd.add_argument("--review-base", required=True)
    cmd.add_argument("--evidence", dest="evidence_path", default=None)
    cmd.add_argument("--fingerprint", dest="expected_fingerprint", default=None)
    cmd.add_argument("--soft-cap", default=None)
    cmd.add_argument("--hard-cap", default=None)
    cmd.add_argument("--context-path", action="append", default=None)
    cmd.add_argument("--contract-path", action="append", default=None)
    cmd.add_argument("--evidence-root", default=None)
    cmd.add_argument("--contract-root", default=None)
    cmd.add_argument("--expected-ac-ids", default=None)

    cmd = sub.add_parser("checkpoint-receipt", help="validate a persisted checkpoint receipt against current worktree")
    cmd.add_argument("--state", required=True)
    cmd.add_argument("--task-ids", required=True)
    cmd.add_argument("--fingerprint", required=True)
    cmd.add_argument("--pass-id", required=True)
    cmd.add_argument("--worktree", required=True)
    cmd.add_argument("--review-base", required=True)

    cmd = sub.add_parser("partition", help="file-disjoint repair groups")
    cmd.add_argument("--findings", required=True, help="merged R1 file")
    cmd.add_argument("--ids", required=True)
    cmd.add_argument("--max-groups", type=int, default=DEFAULT_MAX_GROUPS)

    cmd = sub.add_parser("background", help="should a background full pass of the pre-repair tree run?")
    cmd.add_argument("--state", required=True)
    cmd.add_argument("--repair-round", type=int, required=True)
    cmd.add_argument("--mode", default=None, help="delta|full; defaults to $MAKATO_REVIEW_SCOPE")

    args = parser.parse_args(argv)
    try:
        if args.command == "init":
            result: object = init(args.state, args.story, args.review_base)
        elif args.command == "fingerprint":
            result = review_scope.fingerprint(
                args.worktree,
                args.review_base,
                context_paths=args.context_path,
                contract_paths=args.contract_path,
                evidence_root=args.evidence_root,
                contract_root=args.contract_root,
            )
        elif args.command == "lenses":
            result = lenses(
                args.worktree,
                args.review_base,
                args.mode,
                args.profile,
                args.pass_kind,
                args.qualification,
                args.config_fingerprint,
                args.model,
                None if args.settings is None else json.loads(args.settings),
            )
        elif args.command == "merge":
            result = merge(
                args.state,
                args.pass_number,
                args.scope,
                args.after_round,
                args.snapshot,
                args.r1_files,
                input_fingerprint=args.fingerprint,
                context_paths=args.context_path,
                contract_paths=args.contract_path,
                evidence_root=args.evidence_root,
                expected_ac_ids=None if args.expected_ac_ids is None else _ids(args.expected_ac_ids),
                contract_root=args.contract_root,
            )
        elif args.command == "repaired":
            result = repaired(args.state, args.repair_round, _ids(args.ids), args.coder_id)
        elif args.command == "gate":
            result = gate(
                args.state,
                args.event,
                args.worktree,
                args.review_base,
                args.evidence_path,
                args.expected_fingerprint,
                args.soft_cap,
                args.hard_cap,
                args.context_path,
                args.contract_path,
                args.evidence_root,
                None if args.expected_ac_ids is None else _ids(args.expected_ac_ids),
                contract_root=args.contract_root,
            )
        elif args.command == "checkpoint-receipt":
            result = checkpoint_receipt(
                args.state,
                _ids(args.task_ids),
                args.fingerprint,
                args.pass_id,
                args.worktree,
                args.review_base,
            )
        elif args.command == "partition":
            result = partition(args.findings, _ids(args.ids), args.max_groups)
        else:
            result = background(args.state, args.repair_round, args.mode)
    except (LoopError, review_scope.ScopeError, ValueError) as exc:
        print(f"review-loop: {exc}", file=sys.stderr)
        return 2
    print(json.dumps(result))
    return 0


if __name__ == "__main__":
    raise SystemExit(_main(sys.argv[1:]))
