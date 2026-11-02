"""Deterministic qualification-policy tests; fixtures are not production LLM evidence."""

from __future__ import annotations

import copy
import hashlib
import json
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent))
import review_eval  # noqa: E402
import review_scope  # noqa: E402

MODEL = "test-model@1"
SETTINGS = {"profile": "deep", "risk_lenses": ["error-handling", "state-concurrency"]}


def _write_configuration_sources(root: Path) -> Path:
    for relative in review_scope.REVIEW_CONTRACT_PATHS:
        path = root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(f"fixture source: {relative}\n", encoding="utf-8")
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
    source = tmp_path / "snapshot"
    source.mkdir()
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
    config_root = _write_configuration_sources(tmp_path / "release")
    config = review_eval.configuration(MODEL, SETTINGS, config_root)
    baseline_root = _write_configuration_sources(tmp_path / "baseline")
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
    config = review_eval.configuration(MODEL, SETTINGS, corpus["source_root"])
    assert review_eval.configuration_fingerprint(MODEL, {**SETTINGS, "sample_count": 3}, corpus["source_root"]) != config["fingerprint"]
    assert review_eval.configuration_fingerprint("another-model@1", SETTINGS, corpus["source_root"]) != config["fingerprint"]


@pytest.mark.parametrize("relative", ["skills/build-review/SKILL.md", "legacy-policy.py"])
def test_changed_baseline_prompt_or_implementation_invalidates_qualification(corpus, relative):
    report_path = _save_report(corpus)
    (corpus["baseline_root"] / relative).write_text("baseline changed after measurement\n", encoding="utf-8")
    with pytest.raises(review_eval.EvalError, match="baseline"):
        review_eval.verify_qualification(report_path, corpus["config"]["fingerprint"], MODEL, source_root=corpus["source_root"], settings=SETTINGS)


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
    review_eval.verify_qualification(report_path, corpus["config"]["fingerprint"], MODEL, source_root=corpus["source_root"], settings=SETTINGS)
    alias.unlink()
    alias.symlink_to("agents")
    with pytest.raises(review_eval.EvalError, match="baseline"):
        review_eval.verify_qualification(report_path, corpus["config"]["fingerprint"], MODEL, source_root=corpus["source_root"], settings=SETTINGS)


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
        review_eval.verify_qualification(report_path, corpus["config"]["fingerprint"], MODEL, source_root=corpus["source_root"], settings=SETTINGS)


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
            review_eval.verify_qualification(report_path, corpus["config"]["fingerprint"], MODEL, source_root=corpus["source_root"], settings=SETTINGS)
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
        review_eval.verify_qualification(report_path, corpus["config"]["fingerprint"], MODEL, source_root=corpus["source_root"], settings=SETTINGS)


def test_stale_or_arbitrarily_claimed_configuration_fingerprint_is_rejected(corpus):
    result = check(corpus)
    report_path = _save_report(corpus, result)
    source = corpus["source_root"] / "agents" / "diff-reviewer.md"
    source.write_text("changed current release contract", encoding="utf-8")
    with pytest.raises(review_eval.EvalError, match="does not match current release"):
        review_eval.verify_qualification(report_path, corpus["config"]["fingerprint"], MODEL, source_root=corpus["source_root"], settings=SETTINGS)
    with pytest.raises(review_eval.EvalError, match="does not match current release"):
        review_eval.verify_qualification(report_path, "a" * 64, MODEL, source_root=corpus["source_root"], settings=SETTINGS)


def test_qualification_verification_returns_only_recomputed_bound_report(corpus):
    result = check(corpus)
    report_path = _save_report(corpus, result)
    verified = review_eval.verify_qualification(report_path, corpus["config"]["fingerprint"], MODEL, source_root=corpus["source_root"], settings=SETTINGS)
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
