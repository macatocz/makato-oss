"""Deterministic qualification-policy tests; fixtures are not production LLM evidence."""

from __future__ import annotations

import copy
import hashlib
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent))
import review_eval  # noqa: E402
import review_scope  # noqa: E402

MODEL = "test-model@1"
SETTINGS = {"profile": "deep", "risk_lenses": ["error-handling", "state-concurrency"]}
OLD_RELEASE_PATHS = (
    "agents/RETURN-CONTRACT.md",
    "agents/coder.md",
    "agents/diff-reviewer.md",
    "config/default-workflow-schema.yml",
    "config/verification-ownership.md",
    "skills/build-review/SKILL.md",
    "skills/build-review/references/mechanical-fixes.md",
    "skills/build-review/references/review-criteria.md",
    "skills/build-review/references/review-loop.md",
    "shared/spec_folder.py",
    "shared/review_loop.py",
    "shared/skill_execution.py",
    "shared/review_scope.py",
    "scripts/run-skill.py",
    "AUTONOMOUS-MODE.md",
)


def _write_configuration_sources(root: Path, orchestrate_root: Path) -> Path:
    for argument in review_scope.REVIEW_CONTRACT_PATHS:
        _, relative, selected = review_scope.contract_input(argument, root, orchestrate_root)
        path = selected / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        if relative == ".claude-plugin/plugin.json":
            name = "makato-orchestrate" if selected == orchestrate_root.resolve() else "makato-build"
            path.write_text(json.dumps({"name": name}), encoding="utf-8")
        else:
            path.write_text(f"fixture source: {argument}\n", encoding="utf-8")
        path.chmod(0o644)
    return root


def _write_baseline_sources(root: Path) -> Path:
    for relative in OLD_RELEASE_PATHS:
        path = root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(f"fixture source: {relative}\n", encoding="utf-8")
        path.chmod(0o644)
    return root


def _workflow(finding_ids: list[str]) -> tuple[list[dict], dict, dict, list[dict]]:
    history = [{"stage": "initial-review", "finding_ids": finding_ids, "invariant_ids": finding_ids}]
    if finding_ids:
        history.extend(
            [
                {"stage": "repair", "repair_round": 1},
                {"stage": "re-review", "repair_round": 1, "finding_ids": [], "invariant_ids": [], "recurrences_after_repair": [], "repair_regressions": []},
            ]
        )
        stats = {"rounds_to_pass": 1, "recurrences_after_repair": 0, "repair_regressions": 0}
        repair_output = [{"round": 1, "result": "fixture policy evidence"}]
    else:
        stats = {"rounds_to_pass": 0, "recurrences_after_repair": 0, "repair_regressions": 0}
        repair_output = []
    history.append(
        {"stage": "final-full", "outcome": "passed", "finding_ids": [], "invariant_ids": [], "repair_round": stats["rounds_to_pass"], "recurrences_after_repair": [], "repair_regressions": []}
    )
    return history, stats, {"finding_history": history}, repair_output


@pytest.fixture
def corpus(tmp_path):
    return _make_corpus(tmp_path)


def _make_corpus(tmp_path: Path, *, source_root: Path | None = None, orchestrate_root: Path | None = None) -> dict:
    source = tmp_path / "snapshot"
    source.mkdir(parents=True)
    (source / "operation.py").write_text("def operation():\n    return False\n", encoding="utf-8")
    snapshot = {"path": "snapshot", "files": {"operation.py": hashlib.sha256((source / "operation.py").read_bytes()).hexdigest()}}
    cases = []
    for name, split, findings in (
        ("dev", "development", [{"id": "dev-atomicity", "severity": "MAJOR", "oracle": "one operation is atomic"}]),
        ("clean", "holdout", []),
        (
            "blocker",
            "holdout",
            [
                {"id": "private-data", "severity": "CRITICAL", "oracle": "no unauthorized disclosure"},
                {"id": "atomicity", "severity": "MAJOR", "oracle": "the complete operation is atomic"},
            ],
        ),
    ):
        cases.append(
            {
                "id": name,
                "split": split,
                "snapshot": copy.deepcopy(snapshot),
                "findings": findings,
                "known_clean": not findings,
                "adjudicated_by": "test-expert",
                "provenance": "deterministic policy fixture",
                "review_input": "Review operation.py",
            }
        )
    manifest = {"schema": review_eval.SCHEMA, "cases": cases}
    if source_root is None:
        orchestrate_root = tmp_path / "separate-orchestrate"
        source_root = _write_configuration_sources(tmp_path / "release", orchestrate_root)
    config_root = source_root
    config = review_eval.configuration(MODEL, SETTINGS, config_root, orchestrate_root=orchestrate_root)
    baseline_root = _write_baseline_sources(tmp_path / "baseline")
    (baseline_root / "skills/build-review/SKILL.md").write_text("fixture pre-change review policy\n", encoding="utf-8")
    (baseline_root / "legacy-policy.py").write_text("PRE_CHANGE = True\n", encoding="utf-8")
    baseline_source = review_eval._baseline_source(baseline_root)
    commands = {}
    for name in ("baseline", "candidate", "assessor"):
        adapter = tmp_path / f"{name}-adapter"
        adapter.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        adapter.chmod(0o700)
        commands[name] = [str(adapter)]
    command_provenance = review_eval._experiment_commands(commands)
    records = []
    for case in cases:
        oracle_ids = [finding["id"] for finding in case["findings"]]
        baseline_detected = oracle_ids
        if case["id"] == "blocker":
            baseline_detected = ["atomicity"]
        for repetition in range(3):
            for variant in ("baseline", "candidate"):
                detected = baseline_detected if variant == "baseline" else oracle_ids
                history, stats, review, repair_output = _workflow(detected)
                assessment = {
                    "adjudicator": "independent-test-assessor",
                    "evidence": "policy fixture",
                    "detected_ids": detected,
                    "harmful_false_positives": 0,
                    "unresolved": False,
                    "constituents_complete": True,
                    "ac_transport_complete": True,
                    "citations_complete": True,
                    "infrastructure_safe": True,
                    "workflow_evidence_verified": True,
                    "tokens": 2,
                }
                records.append(
                    {
                        "case_id": case["id"],
                        "variant": variant,
                        "repetition": repetition,
                        "model": MODEL,
                        "configuration_fingerprint": config["fingerprint"],
                        "workflow_source_fingerprint": baseline_source["fingerprint"] if variant == "baseline" else config["fingerprint"],
                        "seconds": 20 if variant == "baseline" else 10,
                        "tokens": 200 if variant == "baseline" else 100,
                        "assessment_seconds": 0.2,
                        "assessment_tokens": 2,
                        "workflow_complete": True,
                        "workflow_history": history,
                        "workflow_stats": stats,
                        "repair_output": repair_output,
                        "review": review,
                        "assessment": copy.deepcopy(assessment),
                    }
                )
    runs = {
        "schema": review_eval.SCHEMA,
        "configuration": config,
        "configuration_fingerprint": config["fingerprint"],
        "baseline_source": baseline_source,
        "command_provenance": command_provenance,
        "model": MODEL,
        "settings": SETTINGS,
        "corpus_sha256": "pending",
        "commands": commands,
        "runs": records,
    }
    recoveries = {"configuration_fingerprint": config["fingerprint"], "incidents": [{"seconds": 0.5, "single_writer": True, "durable_result": True, "evidence": "controlled disposable process"}]}
    return {
        "root": tmp_path,
        "manifest": manifest,
        "runs": runs,
        "recoveries": recoveries,
        "source_root": config_root,
        "orchestrate_root": orchestrate_root,
        "config": config,
        "baseline_root": baseline_root,
        "commands": commands,
    }


def _write_inputs(corpus, refresh_digest: bool = True) -> dict[str, Path]:
    root = corpus["root"]
    manifest_path = root / "manifest.json"
    runs_path = root / "runs.json"
    recoveries_path = root / "recoveries.json"
    manifest_path.write_text(json.dumps(corpus["manifest"], sort_keys=True), encoding="utf-8")
    manifest_digest = hashlib.sha256(manifest_path.read_bytes()).hexdigest()
    if refresh_digest:
        corpus["runs"]["corpus_sha256"] = manifest_digest
    runs_path.write_text(json.dumps(corpus["runs"], sort_keys=True), encoding="utf-8")
    recoveries_path.write_text(json.dumps(corpus["recoveries"], sort_keys=True), encoding="utf-8")
    return {"manifest": manifest_path, "runs": runs_path, "recoveries": recoveries_path}


def check(corpus, refresh_digest: bool = True):
    paths = _write_inputs(corpus, refresh_digest)
    return review_eval.qualify(
        corpus["manifest"],
        corpus["runs"],
        corpus["recoveries"],
        corpus["root"],
        hashlib.sha256(paths["manifest"].read_bytes()).hexdigest(),
        model=MODEL,
        settings=SETTINGS,
        source_root=corpus["source_root"],
        orchestrate_root=corpus["orchestrate_root"],
        artifact_paths=paths,
    )


def _save_report(corpus, report=None) -> Path:
    if report is None:
        report = check(corpus)
    path = corpus["root"] / "qualification.json"
    path.write_text(json.dumps(report, sort_keys=True), encoding="utf-8")
    return path


def _record(corpus, case_id: str, variant: str, repetition: int = 0) -> dict:
    return next(record for record in corpus["runs"]["runs"] if record["case_id"] == case_id and record["variant"] == variant and record["repetition"] == repetition)


def test_configuration_fingerprint_uses_exact_model_settings_and_release_source_inventory(corpus):
    config = review_eval.configuration(MODEL, SETTINGS, corpus["source_root"], orchestrate_root=corpus["orchestrate_root"])
    assert review_eval.configuration_fingerprint(MODEL, {**SETTINGS, "sample_count": 3}, corpus["source_root"], orchestrate_root=corpus["orchestrate_root"]) != config["fingerprint"]
    assert review_eval.configuration_fingerprint("another-model@1", SETTINGS, corpus["source_root"], orchestrate_root=corpus["orchestrate_root"]) != config["fingerprint"]


def test_audit_helper_and_resolver_are_release_inputs_but_new_helper_is_not_required_of_baseline(tmp_path):
    orchestrate = tmp_path / "orchestrate"
    root = _write_configuration_sources(tmp_path / "release", orchestrate)
    paths = {"shared/review_audit.py", "shared/spec_folder.py"}
    assert paths.issubset(review_scope.REVIEW_CONTRACT_PATHS)
    original = review_eval.configuration_fingerprint(MODEL, SETTINGS, root, orchestrate_root=orchestrate)
    for relative in sorted(paths):
        target = root / relative
        before = target.read_bytes()
        target.write_bytes(before + b"# changed\n")
        assert review_eval.configuration_fingerprint(MODEL, SETTINGS, root, orchestrate_root=orchestrate) != original
        target.write_bytes(before)
    (root / "shared/review_audit.py").unlink()
    assert review_eval._baseline_source(root)["fingerprint"]


@pytest.mark.parametrize("relative", ["skills/build-review/SKILL.md", "legacy-policy.py"])
def test_changed_baseline_prompt_or_implementation_invalidates_qualification(corpus, relative):
    report_path = _save_report(corpus)
    (corpus["baseline_root"] / relative).write_text("baseline changed after measurement\n", encoding="utf-8")
    with pytest.raises(review_eval.EvalError, match="baseline"):
        review_eval.verify_qualification(report_path, corpus["config"]["fingerprint"], MODEL, source_root=corpus["source_root"], orchestrate_root=corpus["orchestrate_root"], settings=SETTINGS)


@pytest.mark.parametrize("target", ["shared", "skills/build-review/SKILL.md"])
def test_internal_baseline_alias_is_usable_but_retargeting_invalidates_qualification(corpus, target):
    alias = corpus["baseline_root"] / "review-alias"
    alias.symlink_to(target)
    baseline = review_eval._baseline_source(corpus["baseline_root"])
    corpus["runs"]["baseline_source"] = baseline
    for record in corpus["runs"]["runs"]:
        if record["variant"] == "baseline":
            record["workflow_source_fingerprint"] = baseline["fingerprint"]
    report = check(corpus)
    assert report["rollout_eligible"] is True
    report_path = _save_report(corpus, report)
    review_eval.verify_qualification(report_path, corpus["config"]["fingerprint"], MODEL, source_root=corpus["source_root"], orchestrate_root=corpus["orchestrate_root"], settings=SETTINGS)
    alias.unlink()
    alias.symlink_to("agents")
    with pytest.raises(review_eval.EvalError, match="baseline"):
        review_eval.verify_qualification(report_path, corpus["config"]["fingerprint"], MODEL, source_root=corpus["source_root"], orchestrate_root=corpus["orchestrate_root"], settings=SETTINGS)


@pytest.mark.parametrize("target", ["../snapshot", "../absent", "review-alias"])
def test_external_broken_or_cyclic_baseline_alias_cannot_qualify(corpus, target):
    (corpus["baseline_root"] / "review-alias").symlink_to(target)
    with pytest.raises(review_eval.EvalError, match="symlink"):
        check(corpus)


@pytest.mark.parametrize("variant", ["baseline", "candidate", "assessor"])
def test_changed_executable_adapter_invalidates_qualification(corpus, variant):
    report_path = _save_report(corpus)
    Path(corpus["commands"][variant][0]).write_text("#!/bin/sh\nexit 17\n", encoding="utf-8")
    with pytest.raises(review_eval.EvalError, match="provenance"):
        review_eval.verify_qualification(report_path, corpus["config"]["fingerprint"], MODEL, source_root=corpus["source_root"], orchestrate_root=corpus["orchestrate_root"], settings=SETTINGS)


def test_identical_baseline_candidate_commands_cannot_qualify(corpus):
    corpus["runs"]["commands"]["candidate"] = corpus["commands"]["baseline"]
    with pytest.raises(review_eval.EvalError, match="distinct"):
        check(corpus)


def test_same_review_implementation_in_another_directory_is_not_a_baseline(corpus):
    target = corpus["baseline_root"] / "skills/build-review/SKILL.md"
    target.write_bytes((corpus["source_root"] / "skills/build-review/SKILL.md").read_bytes())
    with pytest.raises(review_eval.EvalError, match="identical"):
        check(corpus)


def test_baseline_record_cannot_echo_the_candidate_implementation_fingerprint(corpus):
    _record(corpus, "dev", "baseline")["workflow_source_fingerprint"] = corpus["config"]["fingerprint"]
    with pytest.raises(review_eval.EvalError, match="implementation fingerprint"):
        check(corpus)


def test_workflow_recurrence_and_regression_metrics_use_invariant_ids_after_finding_id_changes():
    history = [
        {"stage": "initial-review", "finding_ids": ["finding-old"], "invariant_ids": ["atomicity"]},
        {"stage": "repair", "repair_round": 1},
        {
            "stage": "re-review",
            "repair_round": 1,
            "finding_ids": ["finding-new-site", "finding-regression"],
            "invariant_ids": ["atomicity", "new-invariant"],
            "recurrences_after_repair": ["atomicity"],
            "repair_regressions": ["new-invariant"],
        },
        {"stage": "repair", "repair_round": 2},
        {"stage": "re-review", "repair_round": 2, "finding_ids": [], "invariant_ids": [], "recurrences_after_repair": [], "repair_regressions": []},
        {"stage": "final-full", "outcome": "passed", "finding_ids": [], "invariant_ids": [], "repair_round": 2, "recurrences_after_repair": [], "repair_regressions": []},
    ]
    evidence = {
        "workflow_complete": True,
        "review": {},
        "repair_output": [{"round": 1}],
        "workflow_history": history,
        "workflow_stats": {"rounds_to_pass": 2, "recurrences_after_repair": 1, "repair_regressions": 1},
    }
    assert review_eval._workflow_evidence(evidence) == evidence["workflow_stats"]


def test_late_final_full_blocker_requires_repair_and_recertification_and_counts_the_invariant():
    history = [
        {"stage": "initial-review", "finding_ids": ["first"], "invariant_ids": ["atomicity"]},
        {"stage": "repair", "repair_round": 1},
        {"stage": "re-review", "repair_round": 1, "finding_ids": [], "invariant_ids": [], "recurrences_after_repair": [], "repair_regressions": []},
        {
            "stage": "final-full",
            "outcome": "failed",
            "repair_round": 1,
            "finding_ids": ["renamed-first", "late"],
            "invariant_ids": ["atomicity", "late-invariant"],
            "recurrences_after_repair": ["atomicity"],
            "repair_regressions": ["late-invariant"],
        },
        {"stage": "repair", "repair_round": 2},
        {"stage": "re-review", "repair_round": 2, "finding_ids": [], "invariant_ids": [], "recurrences_after_repair": [], "repair_regressions": []},
        {"stage": "final-full", "outcome": "passed", "repair_round": 2, "finding_ids": [], "invariant_ids": [], "recurrences_after_repair": [], "repair_regressions": []},
    ]
    stats = {"rounds_to_pass": 2, "recurrences_after_repair": 1, "repair_regressions": 1}
    measured = {
        "workflow_complete": True,
        "review": {"finding_history": history},
        "repair_output": [{"round": 1}, {"round": 2}],
        "workflow_history": history,
        "workflow_stats": stats,
    }
    assert review_eval._workflow_evidence(measured) == stats
    history[-1]["outcome"] = "failed"
    with pytest.raises(review_eval.EvalError, match="final-full"):
        review_eval._workflow_evidence(measured)


@pytest.mark.parametrize("failed_stage", ["initial-review", "re-review", "final-full"])
def test_nonpassing_review_requires_repair_before_another_clean_attempt(failed_stage):
    history, stats, review, output = _workflow(["atomicity"])
    if failed_stage == "initial-review":
        history = [history[0], {**history[-1], "repair_round": 0}]
        stats["rounds_to_pass"] = 0
        output = []
    elif failed_stage == "re-review":
        history[2].update(finding_ids=["renamed"], invariant_ids=["atomicity"], recurrences_after_repair=["atomicity"])
        stats["recurrences_after_repair"] = 1
    else:
        history.insert(-1, {**history[-1], "outcome": "failed"})
    evidence = {"workflow_complete": True, "review": review, "repair_output": output, "workflow_history": history, "workflow_stats": stats}
    with pytest.raises(review_eval.EvalError, match="followed by a repair"):
        review_eval._workflow_evidence(evidence)


def test_passed_final_full_cannot_retain_blocking_findings():
    history, stats, review, output = _workflow(["atomicity"])
    history[-1].update(finding_ids=["renamed"], invariant_ids=["atomicity"], recurrences_after_repair=["atomicity"])
    stats["recurrences_after_repair"] = 1
    evidence = {"workflow_complete": True, "review": review, "repair_output": output, "workflow_history": history, "workflow_stats": stats}
    with pytest.raises(review_eval.EvalError, match="cannot retain"):
        review_eval._workflow_evidence(evidence)


def test_omitted_recurrence_cannot_understate_workflow_statistics():
    history, stats, review, output = _workflow(["atomicity"])
    history[2].update(finding_ids=["new-site-id"], invariant_ids=["atomicity"])
    history.insert(3, {"stage": "repair", "repair_round": 2})
    history.insert(4, {"stage": "re-review", "repair_round": 2, "finding_ids": [], "invariant_ids": [], "recurrences_after_repair": [], "repair_regressions": []})
    history[-1]["repair_round"] = 2
    stats["rounds_to_pass"] = 2
    output.append({"round": 2})
    evidence = {"workflow_complete": True, "review": review, "repair_output": output, "workflow_history": history, "workflow_stats": stats}
    with pytest.raises(review_eval.EvalError, match="exactly match"):
        review_eval._workflow_evidence(evidence)


def test_complete_paired_evidence_reports_full_workflow_metrics_and_recall_benefit(corpus):
    result = check(corpus)
    assert result["rollout_eligible"] is True
    assert result["quality_pass"] is True
    assert result["performance_pass"] is True
    assert result["recall_benefit"] is True
    assert result["metrics"] == {"baseline": {"median_seconds": 20, "median_tokens": 200}, "candidate": {"median_seconds": 10, "median_tokens": 100}}
    assert result["repetitions"] == 3
    assert result["marginal_detected_ids"] == ["private-data"]
    assert result["recall"] == {"baseline": 2 / 3, "candidate": 1.0}
    assert result["sample_cost"] == {
        "median_incremental_seconds_candidate_minus_baseline": -10,
        "median_incremental_tokens_candidate_minus_baseline": -100,
        "candidate_median_full_workflow_seconds": 10,
        "candidate_median_full_workflow_tokens": 100,
    }
    assert result["workflow_stats"]["candidate"] == {"rounds_to_pass": 1, "recurrences_after_repair": 0, "repair_regressions": 0}
    assert result["post_merge_observations"] == {"status": "not_observed", "reverts": None, "incidents": None}


@pytest.mark.parametrize("case_id", ["dev", "blocker"])
def test_candidate_miss_of_any_major_or_critical_oracle_blocks(corpus, case_id):
    _record(corpus, case_id, "candidate")["assessment"]["detected_ids"] = []
    result = check(corpus)
    assert result["rollout_eligible"] is False
    assert any("missed blocker" in reason for reason in result["quality_failures"])


@pytest.mark.parametrize("severity", ["CRITICAL", "MAJOR"])
def test_missing_critical_or_major_holdout_coverage_is_rejected(corpus, severity):
    blocker = next(case for case in corpus["manifest"]["cases"] if case["id"] == "blocker")
    blocker["findings"] = [finding for finding in blocker["findings"] if finding["severity"] != severity]
    with pytest.raises(review_eval.EvalError, match="blocker holdout is missing severity coverage"):
        check(corpus)


@pytest.mark.parametrize(
    "case_id, error",
    [
        ("dev", "development cases are required"),
        ("clean", "clean holdout cases are required"),
        ("blocker", "blocker holdout cases are required"),
    ],
)
def test_development_clean_and_blocker_splits_are_all_required(corpus, case_id, error):
    corpus["manifest"]["cases"] = [case for case in corpus["manifest"]["cases"] if case["id"] != case_id]
    with pytest.raises(review_eval.EvalError, match=error):
        check(corpus)


def test_one_false_clean_infrastructure_assessment_cannot_be_outvoted(corpus):
    _record(corpus, "blocker", "candidate")["assessment"]["infrastructure_safe"] = False
    assert check(corpus)["quality_pass"] is False


def test_clean_holdout_harmful_false_positive_increase_rejects_quality(corpus):
    _record(corpus, "clean", "candidate")["assessment"]["harmful_false_positives"] = 1
    assert check(corpus)["quality_pass"] is False


def test_no_paired_marginal_recall_benefit_keeps_sampling_ineligible(corpus):
    for case in corpus["manifest"]["cases"]:
        ids = [finding["id"] for finding in case["findings"]]
        for repetition in range(3):
            baseline = _record(corpus, case["id"], "baseline", repetition)
            baseline["assessment"]["detected_ids"] = ids
            candidate = _record(corpus, case["id"], "candidate", repetition)
            for key in ("workflow_history", "workflow_stats", "repair_output", "review"):
                baseline[key] = copy.deepcopy(candidate[key])
    result = check(corpus)
    assert result["quality_pass"] is True
    assert result["performance_pass"] is True
    assert result["recall_benefit"] is False
    assert result["marginal_detected_ids"] == []
    assert result["rollout_eligible"] is False


def test_lower_time_without_lower_full_workflow_tokens_cannot_qualify(corpus):
    for record in corpus["runs"]["runs"]:
        if record["variant"] == "candidate":
            record["tokens"] = 201
    result = check(corpus)
    assert result["quality_pass"] is True
    assert result["performance_pass"] is False
    assert result["rollout_eligible"] is False


@pytest.mark.parametrize("problem", ["duplicate", "unpaired", "model", "corpus", "nan"])
def test_invalid_paired_measurements_fail_closed(corpus, problem):
    records = corpus["runs"]["runs"]
    if problem == "duplicate":
        records.append(copy.deepcopy(records[0]))
    elif problem == "unpaired":
        del records[1]
    elif problem == "model":
        records[1]["model"] = "another-model"
    elif problem == "corpus":
        corpus["runs"]["corpus_sha256"] = "changed"
    else:
        records[0]["seconds"] = float("nan")
    with pytest.raises(review_eval.EvalError):
        check(corpus, refresh_digest=problem != "corpus")


def test_snapshot_byte_drift_invalidates_old_measurements(corpus):
    (corpus["root"] / "snapshot" / "operation.py").write_text("changed after review", encoding="utf-8")
    with pytest.raises(review_eval.EvalError, match="snapshot bytes changed"):
        check(corpus)


def test_missing_expert_adjudication_is_not_a_release_corpus(corpus):
    corpus["manifest"]["cases"][0]["adjudicated_by"] = ""
    with pytest.raises(review_eval.EvalError, match="expert adjudication"):
        check(corpus)


def test_recovery_without_single_writer_proof_rejects_release(corpus):
    corpus["recoveries"]["incidents"][0]["single_writer"] = False
    result = check(corpus)
    assert result["quality_pass"] is True
    assert result["recovery_pass"] is False
    assert result["rollout_eligible"] is False


@pytest.mark.parametrize("git_entry", ["directory", "file", "nested-file", "nested-directory"])
def test_any_git_directory_or_file_in_snapshot_is_rejected(corpus, git_entry):
    source = corpus["root"] / "snapshot"
    if git_entry == "directory":
        (source / ".git").mkdir()
    elif git_entry == "file":
        (source / ".git").write_text("gitdir: elsewhere", encoding="utf-8")
    elif git_entry == "nested-file":
        (source / "nested").mkdir()
        (source / "nested" / ".git").write_text("gitdir: elsewhere", encoding="utf-8")
    else:
        (source / "nested").mkdir()
        (source / "nested" / ".git").mkdir()
    with pytest.raises(review_eval.EvalError, match=r"\.git"):
        review_eval.validate_manifest(corpus["manifest"], corpus["root"])


def test_run_pairs_rejects_git_history_before_scanner_invocation(corpus, monkeypatch):
    manifest_path = _write_inputs(corpus)["manifest"]
    (corpus["root"] / "snapshot" / ".git").mkdir()
    calls = []

    def fail_if_called(*args):
        calls.append(args)
        raise AssertionError("scanner must not receive git metadata")

    monkeypatch.setattr(review_eval, "_invoke", fail_if_called)
    with pytest.raises(review_eval.EvalError, match=r"\.git"):
        review_eval.run_pairs(
            str(manifest_path),
            corpus["commands"]["baseline"],
            corpus["commands"]["candidate"],
            corpus["commands"]["assessor"],
            MODEL,
            SETTINGS,
            3,
            30,
            corpus["source_root"],
            baseline_source_root=corpus["baseline_root"],
            orchestrate_root=corpus["orchestrate_root"],
        )
    assert calls == []


def test_snapshot_symlink_escape_is_rejected(corpus, tmp_path):
    outside = tmp_path / "outside.py"
    outside.write_text("private data", encoding="utf-8")
    link = corpus["root"] / "snapshot" / "outside.py"
    link.symlink_to(outside)
    corpus["manifest"]["cases"][0]["snapshot"]["files"]["outside.py"] = hashlib.sha256(outside.read_bytes()).hexdigest()
    with pytest.raises(review_eval.EvalError, match="symlink escapes"):
        review_eval.validate_manifest(corpus["manifest"], corpus["root"])


def test_changed_raw_artifact_bytes_invalidate_bound_report(corpus):
    result = check(corpus)
    report_path = _save_report(corpus, result)
    for name in ("manifest", "runs", "recoveries"):
        artifact_path = Path(result["artifacts"][name]["path"])
        original = artifact_path.read_bytes()
        artifact_path.write_bytes(original + b" ")
        with pytest.raises(review_eval.EvalError, match=f"{name} artifact content changed"):
            review_eval.verify_qualification(report_path, corpus["config"]["fingerprint"], MODEL, source_root=corpus["source_root"], orchestrate_root=corpus["orchestrate_root"], settings=SETTINGS)
        artifact_path.write_bytes(original)


def test_forged_report_booleans_are_recomputed_from_raw_evidence(corpus):
    for case in corpus["manifest"]["cases"]:
        ids = [finding["id"] for finding in case["findings"]]
        for repetition in range(3):
            baseline = _record(corpus, case["id"], "baseline", repetition)
            baseline["assessment"]["detected_ids"] = ids
            candidate = _record(corpus, case["id"], "candidate", repetition)
            for key in ("workflow_history", "workflow_stats", "repair_output", "review"):
                baseline[key] = copy.deepcopy(candidate[key])
    result = check(corpus)
    assert result["rollout_eligible"] is False
    report_path = _save_report(corpus, result)
    forged = json.loads(report_path.read_text(encoding="utf-8"))
    forged["rollout_eligible"] = True
    forged["recall_benefit"] = True
    report_path.write_text(json.dumps(forged, sort_keys=True), encoding="utf-8")
    with pytest.raises(review_eval.EvalError, match="recomputed raw evidence"):
        review_eval.verify_qualification(report_path, corpus["config"]["fingerprint"], MODEL, source_root=corpus["source_root"], orchestrate_root=corpus["orchestrate_root"], settings=SETTINGS)


def test_stale_or_arbitrarily_claimed_configuration_fingerprint_is_rejected(corpus):
    result = check(corpus)
    report_path = _save_report(corpus, result)
    source = corpus["source_root"] / "agents" / "diff-reviewer.md"
    source.write_text("changed current release contract", encoding="utf-8")
    with pytest.raises(review_eval.EvalError, match="does not match current release"):
        review_eval.verify_qualification(report_path, corpus["config"]["fingerprint"], MODEL, source_root=corpus["source_root"], orchestrate_root=corpus["orchestrate_root"], settings=SETTINGS)
    with pytest.raises(review_eval.EvalError, match="does not match current release"):
        review_eval.verify_qualification(report_path, "a" * 64, MODEL, source_root=corpus["source_root"], orchestrate_root=corpus["orchestrate_root"], settings=SETTINGS)


def test_qualification_verification_returns_only_recomputed_bound_report(corpus):
    result = check(corpus)
    report_path = _save_report(corpus, result)
    verified = review_eval.verify_qualification(report_path, corpus["config"]["fingerprint"], MODEL, source_root=corpus["source_root"], orchestrate_root=corpus["orchestrate_root"], settings=SETTINGS)
    assert verified["rollout_eligible"] is True


def test_run_pairs_isolates_mutable_scanner_tree_from_assessor_snapshot(corpus, monkeypatch):
    paths = _write_inputs(corpus)
    manifest_path = paths["manifest"]
    scanner_trees = {}
    scanner_calls = []
    original = "def operation():\n    return False\n"

    def invoke(command, payload, cwd, timeout):
        if command == corpus["commands"]["assessor"]:
            scanner_path = scanner_trees[(payload["case_id"], payload["variant"], payload["repetition"])]
            assert cwd != scanner_path
            assert payload["initial_snapshot"]["path"] == str(cwd)
            assert (cwd / "operation.py").read_text(encoding="utf-8") == original
            assert payload["repair_output"] == []
            assert "repair_output" not in payload["review"]
            assert "oracle" in payload and "known_clean" in payload
            return {"tokens": 2, "workflow_evidence_verified": True}, 0.2
        scanner_calls.append(payload)
        assert "findings" not in payload and "oracle" not in payload and "known_clean" not in payload
        assert (cwd / "operation.py").read_text(encoding="utf-8") == original
        scanner_trees[(payload["case_id"], payload["variant"], payload["repetition"])] = cwd
        (cwd / "operation.py").write_text("repair mutates only this isolated variant", encoding="utf-8")
        history, stats, review, repair_output = _workflow([])
        return {
            "tokens": 10,
            "workflow_complete": True,
            "model": MODEL,
            "configuration_fingerprint": corpus["config"]["fingerprint"],
            "workflow_source_fingerprint": payload["workflow_source_fingerprint"],
            "review": review,
            "workflow_history": history,
            "workflow_stats": stats,
            "repair_output": repair_output,
        }, 0.5

    monkeypatch.setattr(review_eval, "_invoke", invoke)
    review_eval.run_pairs(
        str(manifest_path),
        corpus["commands"]["baseline"],
        corpus["commands"]["candidate"],
        corpus["commands"]["assessor"],
        MODEL,
        SETTINGS,
        3,
        30,
        corpus["source_root"],
        baseline_source_root=corpus["baseline_root"],
        orchestrate_root=corpus["orchestrate_root"],
    )
    assert (corpus["root"] / "snapshot" / "operation.py").read_text(encoding="utf-8") == original
    assert {(payload["case_id"], payload["variant"], payload["repetition"]) for payload in scanner_calls} == {
        (case["id"], variant, repetition) for case in corpus["manifest"]["cases"] for variant in ("baseline", "candidate") for repetition in range(3)
    }


def test_scanner_only_measurement_and_missing_full_workflow_history_fail(corpus):
    _record(corpus, "dev", "candidate")["workflow_complete"] = False
    with pytest.raises(review_eval.EvalError, match="complete review"):
        check(corpus)
    _record(corpus, "dev", "candidate")["workflow_complete"] = True
    _record(corpus, "dev", "candidate")["workflow_history"] = []
    with pytest.raises(review_eval.EvalError, match="workflow history"):
        check(corpus)


def test_new_untracked_snapshot_file_invalidates_old_measurements(corpus):
    (corpus["root"] / "snapshot" / "new_dependency.py").write_text("unreviewed context", encoding="utf-8")
    with pytest.raises(review_eval.EvalError, match="file inventory changed"):
        check(corpus)


def _refresh_configuration(corpus):
    config = review_eval.configuration(MODEL, SETTINGS, corpus["source_root"], orchestrate_root=corpus["orchestrate_root"])
    corpus["config"] = config
    corpus["runs"]["configuration"] = config
    corpus["runs"]["configuration_fingerprint"] = config["fingerprint"]
    corpus["recoveries"]["configuration_fingerprint"] = config["fingerprint"]
    for record in corpus["runs"]["runs"]:
        record["configuration_fingerprint"] = config["fingerprint"]
        if record["variant"] == "candidate":
            record["workflow_source_fingerprint"] = config["fingerprint"]


@pytest.mark.parametrize(
    "argument",
    [
        "shared/build-log.sh",
        "shared/review_scope.py",
        "shared/default-branch.sh",
        "orchestrate:shared/progress-comment.sh",
        "orchestrate:scripts/task_schedule.py",
    ],
)
@pytest.mark.parametrize("mutation", ["bytes", "mode", "directory", "symlink"])
def test_active_installed_source_changes_invalidate_configuration_and_qualification(corpus, argument, mutation):
    build = Path(review_eval.__file__).resolve().parents[1]
    orchestrate = build.parent / "makato-orchestrate"
    _, relative, original_root = review_scope.contract_input(argument, build, orchestrate)
    _, _, selected = review_scope.contract_input(argument, corpus["source_root"], corpus["orchestrate_root"])
    target = selected / relative
    shutil.copy2(original_root / relative, target)
    _refresh_configuration(corpus)
    report = _save_report(corpus)
    before = corpus["config"]["fingerprint"]
    if mutation == "bytes":
        target.write_bytes(target.read_bytes() + b"\n# active installed source changed\n")
    elif mutation == "mode":
        target.chmod(target.stat().st_mode ^ 0o100)
    else:
        contents = target.read_bytes()
        target.unlink()
        if mutation == "directory":
            target.mkdir()
        else:
            outside = corpus["root"] / "outside-source"
            outside.write_bytes(contents)
            target.symlink_to(outside)
    if mutation in ("bytes", "mode"):
        changed = review_eval.configuration_fingerprint(MODEL, SETTINGS, corpus["source_root"], orchestrate_root=corpus["orchestrate_root"])
        assert changed != before
    else:
        with pytest.raises(review_eval.EvalError, match="canonical|regular|symlink"):
            review_eval.configuration(MODEL, SETTINGS, corpus["source_root"], orchestrate_root=corpus["orchestrate_root"])
    with pytest.raises(review_eval.EvalError, match="configuration|canonical"):
        review_eval.verify_qualification(report, before, MODEL, source_root=corpus["source_root"], orchestrate_root=corpus["orchestrate_root"], settings=SETTINGS)


def test_configuration_records_kind_mode_and_hash_without_physical_root_identity(corpus):
    inventory = corpus["config"]["source_inventory"]
    assert len(inventory) == len(review_scope.REVIEW_CONTRACT_PATHS)
    for argument, record in zip(review_scope.REVIEW_CONTRACT_PATHS, inventory, strict=True):
        label, relative, selected = review_scope.contract_input(argument, corpus["source_root"], corpus["orchestrate_root"])
        target = selected / relative
        assert record == {"path": f"{label}:{relative}", "kind": "file", "mode": 0o644, "sha256": hashlib.sha256(target.read_bytes()).hexdigest()}
    assert set(corpus["config"]) == {"schema", "model", "settings", "source_inventory", "fingerprint"}
    assert str(corpus["root"]) not in json.dumps(corpus["config"])


def test_inactive_decoy_mutation_is_irrelevant_and_relocated_content_is_reproducible(corpus, monkeypatch):
    report = _save_report(corpus)
    relocated_build = corpus["root"] / "relocated-build"
    relocated_orchestrate = corpus["root"] / "relocated-orchestrate"
    shutil.copytree(corpus["source_root"], relocated_build)
    shutil.copytree(corpus["orchestrate_root"], relocated_orchestrate)
    monkeypatch.setenv("MAKATO_BUILD_ROOT", str(relocated_build))
    monkeypatch.setenv("MAKATO_ORCHESTRATE_ROOT", str(relocated_orchestrate))
    monkeypatch.setenv("MAKATO_ORCHESTRATE_SHARED", str(relocated_orchestrate / "shared"))
    decoy = relocated_orchestrate / "shared/progress-comment.sh"
    before = decoy.read_bytes()
    decoy.write_bytes(before + b"inactive\n")
    active = review_eval.configuration(MODEL, SETTINGS, corpus["source_root"], orchestrate_root=corpus["orchestrate_root"])
    assert active == corpus["config"]
    assert review_eval.verify_qualification(report, active["fingerprint"], MODEL, source_root=corpus["source_root"], orchestrate_root=corpus["orchestrate_root"], settings=SETTINGS)["rollout_eligible"]
    decoy.write_bytes(before)
    assert review_scope.root_bindings(relocated_build, relocated_orchestrate) != review_scope.root_bindings(corpus["source_root"], corpus["orchestrate_root"])
    assert review_eval.configuration(MODEL, SETTINGS, relocated_build, orchestrate_root=relocated_orchestrate) == active
    assert review_eval.verify_qualification(report, active["fingerprint"], MODEL, source_root=relocated_build, orchestrate_root=relocated_orchestrate, settings=SETTINGS)["rollout_eligible"]


@pytest.mark.parametrize("name", ["source_root", "orchestrate_root"])
@pytest.mark.parametrize("problem", ["missing", "empty", "absent", "file", "wrong-manifest"])
def test_configuration_requires_both_explicit_valid_roots_despite_valid_exports(corpus, monkeypatch, name, problem):
    monkeypatch.setenv("MAKATO_BUILD_ROOT", str(corpus["source_root"]))
    monkeypatch.setenv("MAKATO_ORCHESTRATE_ROOT", str(corpus["orchestrate_root"]))
    roots = {key: corpus[key] for key in ("source_root", "orchestrate_root")}
    if problem == "missing":
        roots[name] = None
    elif problem == "empty":
        roots[name] = ""
    elif problem == "absent":
        roots[name] = corpus["root"] / "absent"
    elif problem == "file":
        roots[name] = corpus["root"] / "not-a-directory"
        roots[name].write_text("not a root")
    else:
        (roots[name] / ".claude-plugin/plugin.json").write_text('{"name":"inactive-decoy"}')
    with pytest.raises(review_eval.EvalError, match="root|manifest"):
        review_eval.configuration(MODEL, SETTINGS, **roots)


@pytest.mark.parametrize("argument", ["../escape", "orchestrate:../escape", "/escape", "orchestrate:shared//escape", "unknown:shared/escape"])
def test_configuration_rejects_contract_traversal_in_shared_dispatcher(corpus, monkeypatch, argument):
    monkeypatch.setattr(review_scope, "REVIEW_CONTRACT_PATHS", (*review_scope.REVIEW_CONTRACT_PATHS, argument))
    with pytest.raises(review_eval.EvalError, match="invalid contract path"):
        review_eval.configuration(MODEL, SETTINGS, corpus["source_root"], orchestrate_root=corpus["orchestrate_root"])


@pytest.mark.parametrize("relative", OLD_RELEASE_PATHS)
def test_unavailable_old_baseline_input_is_still_rejected(corpus, relative):
    (corpus["baseline_root"] / relative).unlink()
    with pytest.raises(review_eval.EvalError, match="pre-change review contracts"):
        check(corpus)


def test_frozen_old_export_needs_no_new_candidate_or_namespaced_inputs(corpus):
    baseline = review_eval._baseline_source(corpus["baseline_root"])
    assert {record["path"] for record in baseline["source_inventory"]} == {*OLD_RELEASE_PATHS, "legacy-policy.py"}
    assert check(corpus)["rollout_eligible"] is True
    target = corpus["baseline_root"] / "skills/build-review/SKILL.md"
    target.write_bytes((corpus["source_root"] / "skills/build-review/SKILL.md").read_bytes())
    with pytest.raises(review_eval.EvalError, match="identical"):
        review_eval._experiment_baseline(corpus["config"], corpus["baseline_root"])


def _write_eval_adapters(corpus, *, mutate: str | None = None) -> dict:
    records = {(record["case_id"], record["variant"], record["repetition"]): record for record in corpus["runs"]["runs"]}
    adapter = corpus["root"] / "policy-adapter.py"
    adapter.write_text(
        "import json, sys, time\n"
        "from pathlib import Path\n"
        f"sys.path.insert(0, {str(Path(review_eval.__file__).resolve().parent)!r})\n"
        "import review_eval\n"
        f"records = {records!r}\n"
        f"mutate = {mutate!r}\n"
        "payload = json.load(sys.stdin)\n"
        "variant = sys.argv[1]\n"
        "record = records[(payload['case_id'], payload['variant'], payload['repetition'])]\n"
        "if variant == 'assessor':\n"
        "    assert 'oracle' in payload and 'configuration' not in payload\n"
        "    result = record['assessment']\n"
        "else:\n"
        "    assert 'oracle' not in payload and 'findings' not in payload\n"
        "    if variant == 'candidate':\n"
        "        config = review_eval.configuration(payload['model'], payload['configuration']['settings'], payload['workflow_source_root'], orchestrate_root=payload['orchestrate_root'])\n"
        "        assert config == payload['configuration']\n"
        "        fingerprint = config['fingerprint']\n"
        "        if mutate and payload['case_id'] == 'blocker' and payload['repetition'] == 2:\n"
        "            target = Path(payload['orchestrate_root']) / 'shared/progress-comment.sh'\n"
        "            if mutate == 'bytes':\n"
        "                target.write_bytes(target.read_bytes() + b'\\n# changed during run\\n')\n"
        "            else:\n"
        "                target.chmod(target.stat().st_mode ^ 0o100)\n"
        "    else:\n"
        "        assert 'orchestrate_root' not in payload\n"
        "        fingerprint = review_eval._baseline_source(payload['workflow_source_root'])['fingerprint']\n"
        "        time.sleep(0.03)\n"
        "    assert fingerprint == payload['workflow_source_fingerprint']\n"
        "    result = {key: record[key] for key in ("
        "'model', 'configuration_fingerprint', 'workflow_source_fingerprint', 'tokens', "
        "'workflow_complete', 'workflow_history', 'workflow_stats', 'repair_output', 'review')}\n"
        "print(json.dumps(result))\n",
        encoding="utf-8",
    )
    return {name: [sys.executable, str(adapter), name] for name in ("baseline", "candidate", "assessor")}


def _eval_cli(corpus, *arguments: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        [sys.executable, str(Path(review_eval.__file__).resolve()), *arguments],
        cwd=corpus["root"],
        capture_output=True,
        text=True,
        check=False,
        env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1"},
    )


def _configuration_flags(corpus) -> list[str]:
    return ["--model", MODEL, "--settings", json.dumps(SETTINGS), "--source-root", str(corpus["source_root"]), "--orchestrate-root", str(corpus["orchestrate_root"])]


def test_real_cli_run_qualify_verify_propagates_both_selected_roots(corpus):
    paths = _write_inputs(corpus)
    commands = _write_eval_adapters(corpus)
    flags = _configuration_flags(corpus)
    configured = _eval_cli(corpus, "configuration", *flags)
    assert configured.returncode == 0, configured.stderr
    assert json.loads(configured.stdout) == corpus["config"]
    measured = _eval_cli(
        corpus,
        "run",
        "--manifest",
        str(paths["manifest"]),
        "--baseline-source-root",
        str(corpus["baseline_root"]),
        *flags,
        *[argument for name, command in commands.items() for argument in (f"--{name}", json.dumps(command))],
    )
    assert measured.returncode == 0, measured.stderr
    runs = json.loads(measured.stdout)
    assert runs["configuration"] == corpus["config"]
    assert len(runs["runs"]) == 18
    paths["runs"].write_text(measured.stdout)
    qualified = _eval_cli(corpus, "qualify", "--manifest", str(paths["manifest"]), "--runs", str(paths["runs"]), "--recoveries", str(paths["recoveries"]), *flags)
    assert qualified.returncode == 0, qualified.stderr
    report = json.loads(qualified.stdout)
    assert report["rollout_eligible"] is True
    report_path = _save_report(corpus, report)
    verified = _eval_cli(corpus, "verify", "--qualification", str(report_path), "--configuration-fingerprint", corpus["config"]["fingerprint"], *flags)
    assert verified.returncode == 0, verified.stderr
    assert json.loads(verified.stdout) == report
    (corpus["orchestrate_root"] / "shared/progress-comment.sh").write_text("changed after qualification\n")
    stale = _eval_cli(corpus, "verify", "--qualification", str(report_path), "--configuration-fingerprint", corpus["config"]["fingerprint"], *flags)
    assert stale.returncode == 2
    assert "current release" in stale.stderr


@pytest.mark.parametrize("mutation", ["bytes", "mode"])
def test_run_pairs_rechecks_active_orchestrate_root_after_actual_adapter_execution(corpus, mutation):
    paths = _write_inputs(corpus)
    commands = _write_eval_adapters(corpus, mutate=mutation)
    with pytest.raises(review_eval.EvalError, match="configuration sources changed during paired runs"):
        review_eval.run_pairs(
            paths["manifest"],
            commands["baseline"],
            commands["candidate"],
            commands["assessor"],
            MODEL,
            SETTINGS,
            3,
            30,
            corpus["source_root"],
            baseline_source_root=corpus["baseline_root"],
            orchestrate_root=corpus["orchestrate_root"],
        )


@pytest.mark.parametrize("command", ["configuration", "run", "qualify", "verify"])
@pytest.mark.parametrize("missing", ["--source-root", "--orchestrate-root"])
def test_all_configuration_cli_commands_require_explicit_root_flags(corpus, command, missing):
    paths = _write_inputs(corpus)
    flags = _configuration_flags(corpus)
    index = flags.index(missing)
    del flags[index : index + 2]
    required = {
        "configuration": [],
        "run": [
            "--manifest",
            str(paths["manifest"]),
            "--baseline-source-root",
            str(corpus["baseline_root"]),
            "--baseline",
            json.dumps(corpus["commands"]["baseline"]),
            "--candidate",
            json.dumps(corpus["commands"]["candidate"]),
            "--assessor",
            json.dumps(corpus["commands"]["assessor"]),
        ],
        "qualify": ["--manifest", str(paths["manifest"]), "--runs", str(paths["runs"]), "--recoveries", str(paths["recoveries"])],
        "verify": ["--qualification", "report.json", "--configuration-fingerprint", corpus["config"]["fingerprint"]],
    }
    result = _eval_cli(corpus, command, *required[command], *flags)
    assert result.returncode == 2
    assert missing in result.stderr and "required" in result.stderr


def test_immutable_old_export_is_accepted_without_candidate_files(tmp_path):
    baseline_root = _write_baseline_sources(tmp_path / "immutable-old-release")
    legacy = baseline_root / "legacy-policy.py"
    legacy.write_text("PRE_CHANGE = True\n", encoding="utf-8")
    baseline = review_eval._baseline_source(baseline_root)
    assert {item["path"] for item in baseline["source_inventory"]} == {*OLD_RELEASE_PATHS, "legacy-policy.py"}
    assert next(item["sha256"] for item in baseline["source_inventory"] if item["path"] == "legacy-policy.py") == hashlib.sha256(legacy.read_bytes()).hexdigest()
