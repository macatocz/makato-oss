"""Paired review evaluation. Oracles go only to an independent assessor.

Commands are JSON argv arrays, not shell strings. Qualification binds its report to the exact
manifest, paired-run, recovery, model, settings, and release-source bytes used to produce it.
Synthetic policy fixtures are not production recall or performance evidence.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import shutil
import statistics
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Any

import review_scope

SCHEMA = "review-eval-v2"
CONFIG_SCHEMA = "review-eval-configuration-v1"
DEFAULT_SOURCE_ROOT = Path(__file__).resolve().parents[1]
WORKFLOW_STAGES = ("initial-review", "repair", "re-review", "final-full")


class EvalError(ValueError):
    """Missing or unreliable evaluation evidence."""


def _read(path: str | Path) -> dict:
    value = json.loads(Path(path).read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise EvalError(f"{path}: expected an object")
    return value


def _canonical_json(value: object) -> bytes:
    try:
        return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False, allow_nan=False).encode("utf-8")
    except (TypeError, ValueError) as exc:
        raise EvalError("configuration/evidence must be canonical JSON") from exc


def _sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _number(value: object, name: str) -> float:
    if isinstance(value, bool) or not isinstance(value, (float, int)) or not math.isfinite(value) or value < 0:
        raise EvalError(f"{name}: expected a finite nonnegative number")
    return float(value)


def _nonnegative_int(value: object, name: str) -> int:
    if type(value) is not int or value < 0:
        raise EvalError(f"{name}: expected a nonnegative integer")
    return value


def configuration(model: str, settings: dict[str, Any], source_root: str | Path | None = None) -> dict[str, Any]:
    """Derive a stable release fingerprint from the exact model, settings, and canonical source files."""
    if not isinstance(model, str) or not model.strip() or model != model.strip():
        raise EvalError("an exact nonempty pinned model name is required")
    if not isinstance(settings, dict):
        raise EvalError("explicit configuration settings must be a JSON object")
    root = Path(source_root or DEFAULT_SOURCE_ROOT).resolve()
    if not root.is_dir():
        raise EvalError(f"configuration source root is unavailable: {root}")
    inventory = []
    for relative in review_scope.REVIEW_CONTRACT_PATHS:
        path = root / relative
        cursor = path
        while cursor != root:
            if cursor.is_symlink():
                raise EvalError(f"configuration source is unavailable or not canonical: {relative}")
            cursor = cursor.parent
        resolved = path.resolve()
        if not resolved.is_relative_to(root) or not resolved.is_file():
            raise EvalError(f"configuration source is unavailable or not canonical: {relative}")
        inventory.append({"path": relative, "sha256": _sha256(resolved.read_bytes())})
    payload = {"schema": CONFIG_SCHEMA, "model": model, "settings": settings, "source_inventory": inventory}
    return {**payload, "fingerprint": _sha256(_canonical_json(payload))}


def configuration_fingerprint(model: str, settings: dict[str, Any], source_root: str | Path | None = None) -> str:
    """Return a fingerprint derived from current release sources, never a caller-claimed digest."""
    return configuration(model, settings, source_root)["fingerprint"]


def _baseline_source(source_root: str | Path) -> dict:
    """Pin the full immutable baseline tree, including its pre-change prompts."""
    if not isinstance(source_root, (str, Path)) or not str(source_root):
        raise EvalError("an explicit immutable baseline source root is required")
    root = Path(source_root).resolve()
    # These two helpers were introduced after the pinned pre-change baseline.
    required = set(review_scope.REVIEW_CONTRACT_PATHS) - {"shared/review_eval.py", "shared/review_runtime.py"}
    if not root.is_dir() or any(not (root / relative).is_file() for relative in required):
        raise EvalError("baseline source root must contain the pre-change review contracts")
    inventory = []
    for base, directories, filenames in os.walk(root, followlinks=False):
        directories[:] = sorted(name for name in directories if name not in {".git", "__pycache__", ".pytest_cache", ".ruff_cache"})
        base_path = Path(base)
        for name in directories:
            path = base_path / name
            if path.is_symlink():
                inventory.append(_baseline_link(path, root))
        for name in sorted(filenames):
            if name == ".git":
                continue
            path = base_path / name
            if path.is_symlink():
                inventory.append(_baseline_link(path, root))
                continue
            if not path.is_file():
                raise EvalError("baseline source files must be regular immutable files")
            inventory.append({"path": path.relative_to(root).as_posix(), "sha256": _sha256(path.read_bytes())})
    payload = {"schema": "review-baseline-source-v1", "source_inventory": sorted(inventory, key=lambda item: item["path"])}
    return {**payload, "source_root": str(root), "fingerprint": _sha256(_canonical_json(payload))}


def _baseline_link(path: Path, root: Path) -> dict:
    """Pin internal aliases without traversing them or accepting external source bytes."""
    try:
        target = path.resolve(strict=True)
    except (OSError, RuntimeError) as exc:
        raise EvalError("baseline source symlink is broken or cyclic") from exc
    if not target.is_relative_to(root) or any(part in {".git", "__pycache__", ".pytest_cache", ".ruff_cache"} for part in target.relative_to(root).parts):
        raise EvalError("baseline source symlink escapes the immutable source inventory")
    record = {"path": path.relative_to(root).as_posix(), "symlink": os.readlink(path)}
    if target.is_file():
        record["sha256"] = _sha256(target.read_bytes())
    elif not target.is_dir():
        raise EvalError("baseline source symlink must target a regular file or directory")
    return record


def _experiment_baseline(config: dict, source_root: str | Path) -> dict:
    baseline = _baseline_source(source_root)
    baseline_files = {item["path"]: item["sha256"] for item in baseline["source_inventory"] if "sha256" in item}
    if all(baseline_files.get(item["path"]) == item["sha256"] for item in config["source_inventory"]):
        raise EvalError("baseline and candidate review implementations are identical")
    return baseline


def _command_provenance(command: list[str]) -> dict:
    """Resolve argv execution without losing virtualenv/shebang entrypoint identity."""
    if not isinstance(command, list) or not command or any(not isinstance(item, str) or not item for item in command):
        raise EvalError("command must be a nonempty JSON argv array")
    executable = shutil.which(command[0])
    if executable is None:
        raise EvalError(f"evaluation executable is unavailable: {command[0]}")
    argv = [str(Path(executable).absolute()), *command[1:]]
    name = Path(argv[0]).name
    interpreter = name.split(".")[0].rstrip("0123456789") in {"python", "pypy"} or name in {"node", "nodejs", "bun", "bash", "sh", "dash", "zsh", "ruby", "perl", "php"}
    if interpreter and (len(argv) < 2 or not Path(argv[1]).is_absolute() or not Path(argv[1]).is_file()):
        raise EvalError("interpreter adapters require an absolute script file as the first argument")
    files = []
    for index, argument in enumerate(argv):
        path = Path(argument)
        if index and path.is_file() and not path.is_absolute():
            raise EvalError("adapter and input file arguments must use absolute paths")
        if index and (not path.is_absolute() or not path.is_file()):
            continue
        resolved = path.resolve()
        files.append({"argument_index": index, "path": str(path), "resolved": str(resolved), "sha256": _sha256(resolved.read_bytes())})
    return {"argv": argv, "files": files}


def _experiment_commands(commands: dict) -> dict:
    if not isinstance(commands, dict) or set(commands) != {"baseline", "candidate", "assessor"}:
        raise EvalError("paired runs must preserve all three executable command arrays")
    provenance = {name: _command_provenance(commands[name]) for name in ("baseline", "candidate", "assessor")}
    if provenance["baseline"]["argv"] == provenance["candidate"]["argv"]:
        raise EvalError("baseline and candidate commands must be distinct")
    if provenance["assessor"]["argv"] in (provenance["baseline"]["argv"], provenance["candidate"]["argv"]):
        raise EvalError("assessment must use an independent command/context")
    return provenance


def _safe_relative(value: object, name: str) -> Path:
    if not isinstance(value, str) or not value:
        raise EvalError(f"{name}: expected a nonempty relative path")
    path = Path(value)
    if path.is_absolute() or not path.parts or path.as_posix() != value or any(part in (".", "..") for part in path.parts):
        raise EvalError(f"{name}: unsafe relative path")
    if ".git" in path.parts:
        raise EvalError(f"{name}: .git metadata is forbidden in review snapshots")
    return path


def _validate_snapshot(snapshot: dict, directory: Path, case_id: str) -> None:
    files = snapshot.get("files")
    if not isinstance(files, dict) or not files:
        raise EvalError(f"{case_id}: content-addressed snapshot manifest missing")
    directory = directory.resolve()
    if not directory.is_dir():
        raise EvalError(f"{case_id}: snapshot directory is unavailable")
    actual_files: set[str] = set()
    for base, directories, filenames in os.walk(directory, followlinks=False):
        if ".git" in directories or ".git" in filenames:
            raise EvalError(f"{case_id}: .git directory/file is forbidden in review snapshots")
        base_path = Path(base)
        for name in directories:
            item = base_path / name
            if item.is_symlink():
                raise EvalError(f"{case_id}: snapshot directory symlinks are not isolated")
        for filename in filenames:
            item = base_path / filename
            if item.is_symlink() and not item.resolve().is_relative_to(directory):
                raise EvalError(f"{case_id}: snapshot file symlink escapes its snapshot")
            actual_files.add(item.relative_to(directory).as_posix())
    expected_files = set()
    for relative, expected in files.items():
        relative_path = _safe_relative(relative, f"{case_id}: snapshot file")
        key = relative_path.as_posix()
        if key in expected_files:
            raise EvalError(f"{case_id}: duplicate snapshot file")
        expected_files.add(key)
        if not isinstance(expected, str) or len(expected) != 64 or any(c not in "0123456789abcdef" for c in expected):
            raise EvalError(f"{case_id}: invalid SHA-256 for {key}")
    if actual_files != expected_files:
        raise EvalError(f"{case_id}: snapshot file inventory changed")
    for relative, expected in files.items():
        path = (directory / _safe_relative(relative, f"{case_id}: snapshot file")).resolve()
        if not path.is_relative_to(directory) or not path.is_file():
            raise EvalError(f"{case_id}: unavailable snapshot file {relative}")
        if _sha256(path.read_bytes()) != expected:
            raise EvalError(f"{case_id}: snapshot bytes changed: {relative}")


def validate_manifest(manifest: dict, root: Path) -> list[dict]:
    if manifest.get("schema") != SCHEMA:
        raise EvalError("unsupported corpus version")
    cases = manifest.get("cases")
    if not isinstance(cases, list) or not cases:
        raise EvalError("no adjudicated cases; sampling must remain disabled")
    root = root.resolve()
    ids: set[str] = set()
    for case in cases:
        if not isinstance(case, dict) or not isinstance(case.get("id"), str) or not case["id"] or case["id"] in ids:
            raise EvalError("case IDs must be unique nonempty strings")
        ids.add(case["id"])
        if case.get("split") not in ("development", "holdout"):
            raise EvalError(f"{case['id']}: missing development/holdout split")
        if not isinstance(case.get("adjudicated_by"), str) or not case["adjudicated_by"].strip():
            raise EvalError(f"{case['id']}: expert adjudication missing")
        if not isinstance(case.get("provenance"), str) or not case["provenance"].strip():
            raise EvalError(f"{case['id']}: incident provenance missing")
        if not isinstance(case.get("review_input"), str) or not case["review_input"].strip():
            raise EvalError(f"{case['id']}: scanner input missing")
        snapshot = case.get("snapshot")
        if not isinstance(snapshot, dict) or not isinstance(snapshot.get("files"), dict) or not snapshot["files"]:
            raise EvalError(f"{case['id']}: content-addressed snapshot manifest missing")
        relative_snapshot = _safe_relative(snapshot.get("path"), f"{case['id']}: snapshot path")
        directory = (root / relative_snapshot).resolve()
        if not directory.is_relative_to(root):
            raise EvalError(f"{case['id']}: snapshot path escapes the corpus root")
        _validate_snapshot(snapshot, directory, case["id"])
        findings = case.get("findings")
        if not isinstance(findings, list) or not isinstance(case.get("known_clean"), bool):
            raise EvalError(f"{case['id']}: oracle missing")
        finding_ids: set[str] = set()
        for finding in findings:
            if (
                not isinstance(finding, dict)
                or not isinstance(finding.get("id"), str)
                or not finding["id"]
                or finding["id"] in finding_ids
                or finding.get("severity") not in ("CRITICAL", "MAJOR")
                or not isinstance(finding.get("oracle"), str)
                or not finding["oracle"].strip()
            ):
                raise EvalError(f"{case['id']}: invalid blocker oracle")
            finding_ids.add(finding["id"])
        if case["known_clean"] == bool(findings):
            raise EvalError(f"{case['id']}: clean/blocker oracle contradiction")
    if not any(case["split"] == "development" for case in cases):
        raise EvalError("development cases are required")
    if not any(case["split"] == "holdout" and case["known_clean"] for case in cases):
        raise EvalError("clean holdout cases are required")
    holdout_blockers = [case for case in cases if case["split"] == "holdout" and case["findings"]]
    if not holdout_blockers:
        raise EvalError("blocker holdout cases are required")
    holdout_severities = {finding["severity"] for case in holdout_blockers for finding in case["findings"]}
    missing_severities = {"CRITICAL", "MAJOR"} - holdout_severities
    if missing_severities:
        raise EvalError("blocker holdout is missing severity coverage: " + ", ".join(sorted(missing_severities)))
    return cases


def _invoke(command: list[str], payload: dict, cwd: Path, timeout: float) -> tuple[dict, float]:
    if not isinstance(command, list) or not command or any(not isinstance(item, str) or not item for item in command):
        raise EvalError("command must be a nonempty JSON argv array")
    timeout = _number(timeout, "timeout")
    if timeout <= 0:
        raise EvalError("timeout must be positive")
    started = time.monotonic()
    result = subprocess.run(command, input=json.dumps(payload, ensure_ascii=False), text=True, capture_output=True, cwd=cwd, timeout=timeout, check=False)
    elapsed = time.monotonic() - started
    if result.returncode:
        raise EvalError(f"evaluation command exited {result.returncode}; not clean")
    try:
        value = json.loads(result.stdout)
    except json.JSONDecodeError as exc:
        raise EvalError("evaluation command returned malformed evidence") from exc
    if not isinstance(value, dict):
        raise EvalError("evaluation command did not return an object")
    return value, elapsed


def _string_ids(value: object, name: str) -> list[str]:
    if not isinstance(value, list) or any(not isinstance(item, str) or not item for item in value):
        raise EvalError(f"{name}: expected an array of nonempty IDs")
    if len(value) != len(set(value)):
        raise EvalError(f"{name}: duplicate IDs")
    return value


def _workflow_evidence(value: dict) -> dict[str, int]:
    if value.get("workflow_complete") is not True:
        raise EvalError("scanner-only timing cannot qualify end-to-end review")
    if not isinstance(value.get("review"), dict):
        raise EvalError("scanner must return structured review/finding history")
    repair_output = value.get("repair_output")
    if not isinstance(repair_output, (dict, list)):
        raise EvalError("scanner must provide repair_output separately (an empty list means no repair)")
    history = value.get("workflow_history")
    if not isinstance(history, list) or len(history) < 2:
        raise EvalError("complete review/repair/re-review workflow history is required")
    if any(not isinstance(event, dict) or event.get("stage") not in WORKFLOW_STAGES for event in history):
        raise EvalError("workflow history contains an invalid stage")
    if history[0].get("stage") != "initial-review" or history[-1].get("stage") != "final-full":
        raise EvalError("workflow history must start at initial-review and end at final-full")
    if history[-1].get("outcome") != "passed":
        raise EvalError("workflow final-full must record a passed outcome")
    if sum(event["stage"] == "initial-review" for event in history) != 1:
        raise EvalError("workflow history must contain exactly one initial-review")
    prior_invariants: set[str] = set()
    recurrence_events: set[tuple[int, str]] = set()
    regression_events: set[tuple[int, str]] = set()
    repair_round = 0
    needs_repair = False
    needs_re_review = False
    for index, event in enumerate(history):
        stage = event["stage"]
        if needs_repair and stage != "repair":
            raise EvalError("a non-passing review must be followed by a repair, not a clean retry")
        if needs_re_review and stage != "re-review":
            raise EvalError("every repair must be followed by its matching re-review")
        if stage == "repair":
            if not needs_repair or _nonnegative_int(event.get("repair_round"), "workflow repair_round") != repair_round + 1:
                raise EvalError("workflow repair rounds must be motivated and contiguous")
            repair_round += 1
            needs_repair = False
            needs_re_review = True
            continue
        finding_ids = _string_ids(event.get("finding_ids"), f"workflow {stage} finding_ids")
        invariant_ids = set(_string_ids(event.get("invariant_ids"), f"workflow {stage} invariant_ids"))
        if bool(finding_ids) != bool(invariant_ids):
            raise EvalError("review finding IDs and invariant IDs must agree on whether findings remain")
        outcome = event.get("outcome")
        if outcome is not None and outcome not in ("passed", "failed"):
            raise EvalError("review outcome must be passed or failed")
        if outcome == "passed" and (finding_ids or invariant_ids):
            raise EvalError("a passed review cannot retain findings or invariants")
        if stage == "final-full" and (outcome is None or (outcome == "passed" and index != len(history) - 1)):
            raise EvalError("only the last final-full may be passed; earlier final-full passes must fail")
        if stage != "initial-review":
            if _nonnegative_int(event.get("repair_round"), f"workflow {stage} repair_round") != repair_round:
                raise EvalError("review must reference the current recorded repair round")
            recurrences = set(_string_ids(event.get("recurrences_after_repair"), "workflow recurrences_after_repair"))
            regressions = set(_string_ids(event.get("repair_regressions"), "workflow repair_regressions"))
            expected_recurrences = prior_invariants & invariant_ids if repair_round else set()
            if recurrences != expected_recurrences:
                raise EvalError("workflow recurrence invariants must exactly match repeated invariants after repair")
            if not regressions <= invariant_ids - prior_invariants:
                raise EvalError("workflow repair regressions must be newly detected invariants")
            if not repair_round and regressions:
                raise EvalError("a pre-repair review cannot claim a repair regression")
            recurrence_events.update((repair_round, invariant) for invariant in expected_recurrences)
            regression_events.update((repair_round, invariant) for invariant in regressions)
        if stage == "re-review":
            if not needs_re_review:
                raise EvalError("a re-review must correspond to the preceding repair")
            needs_re_review = False
        prior_invariants.update(invariant_ids)
        needs_repair = bool(finding_ids) or outcome == "failed"
    if needs_repair or needs_re_review:
        raise EvalError("workflow ended with an unresolved repair or re-review")
    if bool(repair_output) != bool(repair_round):
        raise EvalError("repair output must agree with the recorded repair rounds")
    stats = value.get("workflow_stats")
    if not isinstance(stats, dict):
        raise EvalError("workflow_stats are required")
    measured = {
        "rounds_to_pass": _nonnegative_int(stats.get("rounds_to_pass"), "rounds_to_pass"),
        "recurrences_after_repair": _nonnegative_int(stats.get("recurrences_after_repair"), "recurrences_after_repair"),
        "repair_regressions": _nonnegative_int(stats.get("repair_regressions"), "repair_regressions"),
    }
    if measured != {"rounds_to_pass": repair_round, "recurrences_after_repair": len(recurrence_events), "repair_regressions": len(regression_events)}:
        raise EvalError("workflow_stats do not match the recorded workflow history")
    return measured


def run_pairs(
    manifest_path: str | Path,
    baseline: list[str],
    candidate: list[str],
    assessor: list[str],
    model: str,
    settings: dict[str, Any],
    repetitions: int,
    timeout: float,
    source_root: str | Path | None = None,
    *,
    baseline_source_root: str | Path,
) -> dict:
    if type(repetitions) is not int or repetitions < 3:
        raise EvalError("need >=3 paired repetitions per case")
    config = configuration(model, settings, source_root)
    baseline_source = _experiment_baseline(config, baseline_source_root)
    command_provenance = _experiment_commands({"baseline": baseline, "candidate": candidate, "assessor": assessor})
    commands = {name: record["argv"] for name, record in command_provenance.items()}
    path = Path(manifest_path).resolve()
    manifest_bytes = path.read_bytes()
    manifest = _read(path)
    cases = validate_manifest(manifest, path.parent)
    runs = []
    for case in cases:
        source = (path.parent / _safe_relative(case["snapshot"]["path"], f"{case['id']}: snapshot path")).resolve()
        for repetition in range(repetitions):
            order = (("baseline", commands["baseline"]), ("candidate", commands["candidate"]))
            if repetition % 2:
                order = tuple(reversed(order))
            for variant, command in order:
                with (
                    tempfile.TemporaryDirectory(prefix="makato-review-eval-initial-") as initial_temp,
                    tempfile.TemporaryDirectory(prefix="makato-review-eval-worktree-") as worktree_temp,
                    tempfile.TemporaryDirectory(prefix="makato-review-eval-assessor-") as assessor_temp,
                ):
                    frozen = Path(initial_temp) / "snapshot"
                    shutil.copytree(source, frozen, symlinks=False)
                    _validate_snapshot(case["snapshot"], frozen, case["id"])
                    worktree = Path(worktree_temp) / "snapshot"
                    assessor_snapshot = Path(assessor_temp) / "snapshot"
                    shutil.copytree(frozen, worktree, symlinks=False)
                    _validate_snapshot(case["snapshot"], worktree, case["id"])
                    shutil.copytree(frozen, assessor_snapshot, symlinks=False)
                    _validate_snapshot(case["snapshot"], assessor_snapshot, case["id"])
                    scan, scan_seconds = _invoke(
                        command,
                        {
                            "case_id": case["id"],
                            "variant": variant,
                            "repetition": repetition,
                            "model": model,
                            "configuration": config,
                            "workflow_source_root": baseline_source["source_root"] if variant == "baseline" else str(Path(source_root or DEFAULT_SOURCE_ROOT).resolve()),
                            "workflow_source_fingerprint": baseline_source["fingerprint"] if variant == "baseline" else config["fingerprint"],
                            "configuration_fingerprint": config["fingerprint"],
                            "review_input": case["review_input"],
                            "snapshot": {**case["snapshot"], "path": str(worktree)},
                        },
                        worktree,
                        timeout,
                    )
                    if scan.get("model") != model or scan.get("configuration_fingerprint") != config["fingerprint"]:
                        raise EvalError("measured workflow model/configuration does not match derived experiment")
                    workflow_fingerprint = baseline_source["fingerprint"] if variant == "baseline" else config["fingerprint"]
                    if scan.get("workflow_source_fingerprint") != workflow_fingerprint:
                        raise EvalError("measured workflow did not attest its variant's actual source fingerprint")
                    workflow_stats = _workflow_evidence(scan)
                    assessment, assessment_seconds = _invoke(
                        commands["assessor"],
                        {
                            "case_id": case["id"],
                            "variant": variant,
                            "repetition": repetition,
                            "review_input": case["review_input"],
                            "review": scan["review"],
                            "workflow_history": scan["workflow_history"],
                            "workflow_stats": workflow_stats,
                            "repair_output": scan["repair_output"],
                            "initial_snapshot": {**case["snapshot"], "path": str(assessor_snapshot)},
                            "oracle": case["findings"],
                            "known_clean": case["known_clean"],
                        },
                        assessor_snapshot,
                        timeout,
                    )
                    if assessment.get("workflow_evidence_verified") is not True:
                        raise EvalError("independent assessor did not verify workflow history and repair output")
                    assessment_tokens = _number(assessment.get("tokens"), "assessment tokens")
                    scanner_tokens = _number(scan.get("tokens"), "scanner full-workflow tokens")
                    runs.append(
                        {
                            "case_id": case["id"],
                            "variant": variant,
                            "repetition": repetition,
                            "model": model,
                            "configuration_fingerprint": config["fingerprint"],
                            "workflow_source_fingerprint": workflow_fingerprint,
                            "seconds": scan_seconds,
                            "tokens": scanner_tokens,
                            "assessment_seconds": assessment_seconds,
                            "assessment_tokens": assessment_tokens,
                            "workflow_complete": True,
                            "workflow_history": scan["workflow_history"],
                            "workflow_stats": workflow_stats,
                            "repair_output": scan["repair_output"],
                            "review": scan["review"],
                            "assessment": assessment,
                        }
                    )
    if configuration(model, settings, source_root) != config:
        raise EvalError("review configuration sources changed during paired runs")
    if _experiment_baseline(config, baseline_source_root) != baseline_source or _experiment_commands(commands) != command_provenance:
        raise EvalError("baseline sources or executable adapters changed during paired runs")
    return {
        "schema": SCHEMA,
        "configuration": config,
        "configuration_fingerprint": config["fingerprint"],
        "model": model,
        "settings": settings,
        "corpus_sha256": _sha256(manifest_bytes),
        "baseline_source": baseline_source,
        "commands": commands,
        "command_provenance": command_provenance,
        "runs": runs,
    }


def _artifact_record(path: str | Path) -> dict[str, str]:
    resolved = Path(path).resolve()
    if not resolved.is_file():
        raise EvalError(f"qualification input file is unavailable: {resolved}")
    return {"path": str(resolved), "sha256": _sha256(resolved.read_bytes())}


def qualify(
    manifest: dict, runs: dict, recoveries: dict, root: Path, corpus_digest: str, *, model: str, settings: dict[str, Any], source_root: str | Path | None, artifact_paths: dict[str, str | Path]
) -> dict:
    cases = validate_manifest(manifest, root)
    config = configuration(model, settings, source_root)
    if runs.get("schema") != SCHEMA or runs.get("corpus_sha256") != corpus_digest:
        raise EvalError("run/corpus fingerprint mismatch")
    if runs.get("configuration_fingerprint") != config["fingerprint"] or runs.get("configuration") != config or runs.get("model") != model or runs.get("settings") != settings:
        raise EvalError("run configuration does not match current model/settings/source inventory")
    command_provenance = _experiment_commands(runs.get("commands"))
    if runs.get("commands") != {name: record["argv"] for name, record in command_provenance.items()} or runs.get("command_provenance") != command_provenance:
        raise EvalError("evaluation executable or adapter provenance changed")
    baseline_record = runs.get("baseline_source")
    if not isinstance(baseline_record, dict):
        raise EvalError("paired runs must bind the actual pre-change baseline source inventory")
    baseline_source = _experiment_baseline(config, baseline_record.get("source_root"))
    if baseline_record != baseline_source:
        raise EvalError("baseline implementation or prompt source bytes changed")
    if not isinstance(corpus_digest, str) or len(corpus_digest) != 64:
        raise EvalError("manifest SHA-256 missing")
    if not isinstance(artifact_paths, dict) or set(artifact_paths) != {"manifest", "runs", "recoveries"}:
        raise EvalError("manifest, runs, and recoveries paths are required to bind qualification")
    artifacts = {name: _artifact_record(artifact_paths[name]) for name in ("manifest", "runs", "recoveries")}
    if artifacts["manifest"]["sha256"] != corpus_digest:
        raise EvalError("manifest file hash differs from supplied corpus digest")
    expected_documents = {"manifest": manifest, "runs": runs, "recoveries": recoveries}
    if Path(artifacts["manifest"]["path"]).parent != root.resolve():
        raise EvalError("manifest snapshot root does not match the bound manifest path")
    for name, expected_document in expected_documents.items():
        if _read(artifacts[name]["path"]) != expected_document:
            raise EvalError(f"{name} artifact changed while qualification was being computed")
    if recoveries.get("configuration_fingerprint") != config["fingerprint"]:
        raise EvalError("measured recovery evidence is from another configuration")
    records = runs.get("runs")
    if not isinstance(records, list) or not records:
        raise EvalError("no paired measured runs")
    indexed: dict[tuple[str, str, int], dict] = {}
    for record in records:
        if not isinstance(record, dict):
            raise EvalError("invalid measured run")
        key = (record.get("case_id"), record.get("variant"), record.get("repetition"))
        if not isinstance(key[0], str) or key[1] not in ("baseline", "candidate") or type(key[2]) is not int or key[2] < 0 or key in indexed:
            raise EvalError("duplicate/invalid paired run")
        if record.get("model") != model or record.get("configuration_fingerprint") != config["fingerprint"]:
            raise EvalError("paired model/configuration versions differ")
        workflow_fingerprint = baseline_source["fingerprint"] if record["variant"] == "baseline" else config["fingerprint"]
        if record.get("workflow_source_fingerprint") != workflow_fingerprint:
            raise EvalError("paired workflow implementation fingerprint differs from its pinned variant")
        _number(record.get("seconds"), "full-workflow seconds")
        _number(record.get("tokens"), "full-workflow tokens")
        _number(record.get("assessment_seconds"), "independent assessment seconds")
        _number(record.get("assessment_tokens"), "independent assessment tokens")
        if record.get("workflow_complete") is not True:
            raise EvalError("run did not measure the complete review/repair/re-review workflow")
        derived_stats = _workflow_evidence(
            {
                "workflow_complete": True,
                "review": record.get("review"),
                "repair_output": record.get("repair_output"),
                "workflow_history": record.get("workflow_history"),
                "workflow_stats": record.get("workflow_stats"),
            }
        )
        if record.get("workflow_stats") != derived_stats:
            raise EvalError("recorded workflow statistics are invalid")
        indexed[key] = record
    quality_failures = []
    seconds: dict[str, list[float]] = {"baseline": [], "candidate": []}
    tokens: dict[str, list[float]] = {"baseline": [], "candidate": []}
    workflow_values: dict[str, dict[str, list[int]]] = {variant: {field: [] for field in ("rounds_to_pass", "recurrences_after_repair", "repair_regressions")} for variant in ("baseline", "candidate")}
    expected_keys = set()
    repetition_counts = []
    marginal_detections = []
    baseline_hits = 0
    candidate_hits = 0
    oracle_opportunities = 0
    incremental_seconds = []
    incremental_tokens = []
    for case in cases:
        baseline_repetitions = sorted(key[2] for key in indexed if key[0] == case["id"] and key[1] == "baseline")
        candidate_repetitions = sorted(key[2] for key in indexed if key[0] == case["id"] and key[1] == "candidate")
        repetitions = baseline_repetitions
        if len(repetitions) < 3 or repetitions != list(range(len(repetitions))) or candidate_repetitions != repetitions:
            raise EvalError(f"{case['id']}: need >=3 contiguous paired repetitions")
        repetition_counts.append(len(repetitions))
        oracle_ids = {finding["id"] for finding in case["findings"]}
        for repetition in repetitions:
            if case["findings"]:
                oracle_opportunities += len(oracle_ids)
            expected_keys.update(((case["id"], "baseline", repetition), (case["id"], "candidate", repetition)))
            baseline_record = indexed[(case["id"], "baseline", repetition)]
            candidate_record = indexed[(case["id"], "candidate", repetition)]
            assessments = {}
            detected_by_variant = {}
            for variant, record in (("baseline", baseline_record), ("candidate", candidate_record)):
                assessment = record.get("assessment")
                if (
                    not isinstance(assessment, dict)
                    or not isinstance(assessment.get("adjudicator"), str)
                    or not assessment["adjudicator"].strip()
                    or not isinstance(assessment.get("evidence"), str)
                    or not assessment["evidence"].strip()
                ):
                    raise EvalError("independent assessment evidence missing")
                if assessment.get("workflow_evidence_verified") is not True:
                    quality_failures.append(f"{case['id']}/{variant}/{repetition}: workflow evidence not independently verified")
                detected = _string_ids(assessment.get("detected_ids"), "oracle matching evidence")
                if not set(detected) <= oracle_ids:
                    raise EvalError("assessment claims unknown oracle")
                detected_by_variant[variant] = set(detected)
                assessments[variant] = assessment
                seconds[variant].append(record["seconds"])
                tokens[variant].append(record["tokens"])
                for field in workflow_values[variant]:
                    workflow_values[variant][field].append(record["workflow_stats"][field])
                if case["findings"]:
                    if variant == "baseline":
                        baseline_hits += len(set(detected) & oracle_ids)
                    else:
                        candidate_hits += len(set(detected) & oracle_ids)
                if variant == "candidate":
                    if set(detected) != oracle_ids:
                        quality_failures.append(f"{case['id']}/{repetition}: missed blocker")
                    for field in ("constituents_complete", "ac_transport_complete", "citations_complete", "infrastructure_safe"):
                        if assessment.get(field) is not True:
                            quality_failures.append(f"{case['id']}/{repetition}: {field}")
                    if assessment.get("unresolved") is not False:
                        quality_failures.append(f"{case['id']}/{repetition}: unresolved assessment")
            if case["known_clean"]:
                baseline_fp = _number(assessments["baseline"].get("harmful_false_positives"), "baseline harmful false positives")
                candidate_fp = _number(assessments["candidate"].get("harmful_false_positives"), "candidate harmful false positives")
                if candidate_fp > baseline_fp:
                    quality_failures.append(f"{case['id']}/{repetition}: increased harmful false positives")
            marginal = sorted(detected_by_variant["candidate"] - detected_by_variant["baseline"])
            marginal_detections.append({"case_id": case["id"], "repetition": repetition, "finding_ids": marginal})
            incremental_seconds.append(candidate_record["seconds"] - baseline_record["seconds"])
            incremental_tokens.append(candidate_record["tokens"] - baseline_record["tokens"])
    if set(indexed) != expected_keys:
        raise EvalError("extra case/repetition records would bias paired metrics")
    recovery_records = recoveries.get("incidents")
    if not isinstance(recovery_records, list) or not recovery_records:
        raise EvalError("measured recovery evidence missing")
    recovery_pass = True
    for incident in recovery_records:
        if not isinstance(incident, dict):
            raise EvalError("invalid recovery evidence")
        recovery_pass = recovery_pass and (
            _number(incident.get("seconds"), "recovery seconds") <= 300
            and incident.get("single_writer") is True
            and incident.get("durable_result") is True
            and isinstance(incident.get("evidence"), str)
            and bool(incident["evidence"].strip())
        )
    metrics = {variant: {"median_seconds": statistics.median(seconds[variant]), "median_tokens": statistics.median(tokens[variant])} for variant in ("baseline", "candidate")}
    performance = metrics["candidate"]["median_seconds"] < metrics["baseline"]["median_seconds"] and metrics["candidate"]["median_tokens"] < metrics["baseline"]["median_tokens"] and recovery_pass
    quality = not quality_failures
    recall = {"baseline": baseline_hits / oracle_opportunities, "candidate": candidate_hits / oracle_opportunities} if oracle_opportunities else {"baseline": 0.0, "candidate": 0.0}
    marginal_ids = sorted({item for pair in marginal_detections for item in pair["finding_ids"]})
    recall_benefit = bool(marginal_ids)
    sample_cost = {
        "median_incremental_seconds_candidate_minus_baseline": statistics.median(incremental_seconds),
        "median_incremental_tokens_candidate_minus_baseline": statistics.median(incremental_tokens),
        "candidate_median_full_workflow_seconds": metrics["candidate"]["median_seconds"],
        "candidate_median_full_workflow_tokens": metrics["candidate"]["median_tokens"],
    }
    workflow_stats = {variant: {field: statistics.median(values) for field, values in workflow_values[variant].items()} for variant in ("baseline", "candidate")}
    post_merge = runs.get("post_merge_observations")
    if post_merge is None:
        post_merge = {"status": "not_observed", "reverts": None, "incidents": None}
    else:
        if not isinstance(post_merge, dict) or not isinstance(post_merge.get("evidence"), str) or not post_merge["evidence"].strip():
            raise EvalError("post-merge observations require explicit evidence")
        post_merge = {
            "status": "observed",
            "reverts": _nonnegative_int(post_merge.get("reverts"), "post-merge reverts"),
            "incidents": _nonnegative_int(post_merge.get("incidents"), "post-merge incidents"),
            "evidence": post_merge["evidence"],
        }
    return {
        "schema": SCHEMA,
        "configuration_fingerprint": config["fingerprint"],
        "configuration": config,
        "baseline_source": baseline_source,
        "command_provenance": command_provenance,
        "artifacts": artifacts,
        "corpus_sha256": corpus_digest,
        "model": model,
        "case_count": len(cases),
        "run_count": len(records),
        "repetitions": min(repetition_counts),
        "quality_pass": quality,
        "quality_failures": quality_failures,
        "holdout_verified": True,
        "performance_pass": performance,
        "recovery_pass": recovery_pass,
        "metrics": metrics,
        "workflow_stats": workflow_stats,
        "recall": recall,
        "recall_benefit": recall_benefit,
        "marginal_detected_ids": marginal_ids,
        "marginal_detections": marginal_detections,
        "sample_cost": sample_cost,
        "post_merge_observations": post_merge,
        "rollout_eligible": quality and performance and recall_benefit,
        "caveat": "Three paired repetitions expose variability; they do not prove statistical non-inferiority. Pilot before default rollout.",
    }


def verify_qualification(path: str | Path, expected_configuration_fingerprint: str, expected_model: str, *, source_root: str | Path | None = None, settings: dict[str, Any]) -> dict:
    """Recompute current configuration, raw-artifact hashes, and policy instead of trusting report flags."""
    report = _read(path)
    if report.get("schema") != SCHEMA:
        raise EvalError("unsupported or unbound qualification report")
    config = configuration(expected_model, settings, source_root)
    if expected_configuration_fingerprint != config["fingerprint"]:
        raise EvalError("expected configuration fingerprint does not match current release sources/model/settings")
    if report.get("configuration_fingerprint") != config["fingerprint"] or report.get("configuration") != config:
        raise EvalError("qualification configuration is stale or changed")
    artifacts = report.get("artifacts")
    if not isinstance(artifacts, dict) or set(artifacts) != {"manifest", "runs", "recoveries"}:
        raise EvalError("qualification is missing bound manifest/run/recovery artifacts")
    artifact_paths: dict[str, Path] = {}
    for name, record in artifacts.items():
        if not isinstance(record, dict) or not isinstance(record.get("path"), str):
            raise EvalError(f"qualification {name} artifact path is missing")
        actual = _artifact_record(record["path"])
        if actual != record:
            raise EvalError(f"qualification {name} artifact content changed")
        artifact_paths[name] = Path(record["path"])
    manifest = _read(artifact_paths["manifest"])
    runs = _read(artifact_paths["runs"])
    recoveries = _read(artifact_paths["recoveries"])
    recomputed = qualify(
        manifest, runs, recoveries, artifact_paths["manifest"].parent, artifacts["manifest"]["sha256"], model=expected_model, settings=settings, source_root=source_root, artifact_paths=artifact_paths
    )
    if _canonical_json(report) != _canonical_json(recomputed):
        raise EvalError("qualification report differs from recomputed raw evidence")
    if recomputed["rollout_eligible"] is not True:
        raise EvalError("qualification does not meet sampling rollout gates")
    return recomputed


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    config_cmd = sub.add_parser("configuration", help="derive current model/settings/source fingerprint")
    config_cmd.add_argument("--model", required=True)
    config_cmd.add_argument("--settings", required=True, type=json.loads)
    config_cmd.add_argument("--source-root", type=Path, default=DEFAULT_SOURCE_ROOT)
    validate = sub.add_parser("validate")
    validate.add_argument("--manifest", required=True)
    run = sub.add_parser("run")
    run.add_argument("--manifest", required=True)
    for name in ("baseline", "candidate", "assessor"):
        run.add_argument(f"--{name}", required=True, type=json.loads, help="JSON argv array")
    run.add_argument("--model", required=True)
    run.add_argument("--settings", required=True, type=json.loads)
    run.add_argument("--source-root", type=Path, default=DEFAULT_SOURCE_ROOT)
    run.add_argument("--baseline-source-root", required=True, type=Path, help="immutable exported pre-change build-plugin sources")
    run.add_argument("--repetitions", type=int, default=3)
    run.add_argument("--timeout", type=float, default=1800)
    check = sub.add_parser("qualify")
    check.add_argument("--manifest", required=True)
    check.add_argument("--runs", required=True)
    check.add_argument("--recoveries", required=True)
    check.add_argument("--model", required=True)
    check.add_argument("--settings", required=True, type=json.loads)
    check.add_argument("--source-root", type=Path, default=DEFAULT_SOURCE_ROOT)
    verify = sub.add_parser("verify")
    verify.add_argument("--qualification", required=True)
    verify.add_argument("--configuration-fingerprint", required=True)
    verify.add_argument("--model", required=True)
    verify.add_argument("--settings", required=True, type=json.loads)
    verify.add_argument("--source-root", type=Path, default=DEFAULT_SOURCE_ROOT)
    args = parser.parse_args(argv)
    try:
        if args.command == "configuration":
            result = configuration(args.model, args.settings, args.source_root)
        elif args.command == "run":
            result = run_pairs(
                args.manifest,
                args.baseline,
                args.candidate,
                args.assessor,
                args.model,
                args.settings,
                args.repetitions,
                args.timeout,
                args.source_root,
                baseline_source_root=args.baseline_source_root,
            )
        elif args.command == "qualify":
            manifest_path = Path(args.manifest).resolve()
            runs_path = Path(args.runs).resolve()
            recoveries_path = Path(args.recoveries).resolve()
            result = qualify(
                _read(manifest_path),
                _read(runs_path),
                _read(recoveries_path),
                manifest_path.parent,
                _sha256(manifest_path.read_bytes()),
                model=args.model,
                settings=args.settings,
                source_root=args.source_root,
                artifact_paths={"manifest": manifest_path, "runs": runs_path, "recoveries": recoveries_path},
            )
        elif args.command == "verify":
            result = verify_qualification(args.qualification, args.configuration_fingerprint, args.model, source_root=args.source_root, settings=args.settings)
        else:
            path = Path(args.manifest).resolve()
            cases = validate_manifest(_read(path), path.parent)
            result = {"schema": SCHEMA, "case_count": len(cases), "validated": True}
    except (EvalError, OSError, json.JSONDecodeError, ValueError, subprocess.SubprocessError) as exc:
        print(f"review-eval: {exc}", file=sys.stderr)
        return 2
    print(json.dumps(result, sort_keys=True))
    return 0 if args.command not in ("qualify",) or result["rollout_eligible"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
