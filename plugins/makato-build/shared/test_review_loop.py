"""Behavioral tests for the durable build-review ledger and its consumer gates."""

from __future__ import annotations

import contextlib
import copy
import hashlib
import io
import itertools
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

_HERE = Path(__file__).resolve().parent
if str(_HERE) not in sys.path:
    sys.path.insert(0, str(_HERE))

import review_loop  # noqa: E402
import review_scope  # noqa: E402

_REVIEWER_SERIAL = itertools.count(1)


def _git(repo: Path, *args: str) -> str:
    return subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True, check=True).stdout.strip()


def _write(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")


def _finding(
    severity: str,
    file: str,
    line: int,
    *,
    finding_id: str,
    invariant: str,
    description: str | None = None,
    evidence: str | None = None,
    lens: str | None = None,
    extra_sites: tuple[tuple[str, int], ...] = (),
) -> dict:
    sites = [{"file": file, "line": line}, *({"file": name, "line": number} for name, number in extra_sites)]
    return {
        "id": finding_id,
        "severity": severity,
        "category": "security",
        "lens": lens,
        "invariant": invariant,
        "file": file,
        "line": line,
        "sites": sites,
        "evidence": evidence or f"evidence for {finding_id}",
        "description": description or f"{finding_id} violates {invariant}",
    }


def _r1(
    findings: list[dict],
    *,
    lens: str | None = None,
    status: str | None = None,
    ac: list | None = None,
    input_fingerprint: str | None = None,
    files_reviewed: int = 2,
    file_citations: list[dict] | None = None,
    reviewer_id: str | None = None,
    errors: list[str] | None = None,
) -> dict:
    critical = sum(finding["severity"] == "CRITICAL" for finding in findings)
    major = sum(finding["severity"] == "MAJOR" for finding in findings)
    blocking = critical + major
    actual_status = status or ("failure" if blocking else "success")
    actual_errors = list(errors or ([] if actual_status != "failure" else ["blocking findings require repair"]))
    if file_citations is None:
        file_citations = [{"file": name, "line": 1} for name in ("app.py", "shared.py")[:files_reviewed]]
    data = {
        "reviewer_id": reviewer_id or f"reviewer-instance-{next(_REVIEWER_SERIAL)}",
        "lens": lens,
        "critical_count": critical,
        "major_count": major,
        "suggestion_count": sum(finding["severity"] == "SUGGESTION" for finding in findings),
        "nitpick_count": sum(finding["severity"] == "NITPICK" for finding in findings),
        "files_reviewed": files_reviewed,
        "file_citations": file_citations,
        "findings": findings,
        "ac_verdicts": list(ac or []),
    }
    if input_fingerprint is not None:
        data["input_fingerprint"] = input_fingerprint
    return {
        "schema": "r1",
        "agent": "diff-reviewer",
        "status": actual_status,
        "summary": "Controlled reviewer result.",
        "files_changed": [],
        "tests_written": [],
        "errors": actual_errors,
        "tool_calls_used": 0,
        "data": data,
    }


def _ac(ac_id: str, file: str = "app.py", line: int = 1) -> dict:
    return {
        "ac_id": ac_id,
        "ac_text": f"Required behavior for {ac_id}.",
        "verified": True,
        "evidence": f"Verified {ac_id} against the current implementation and behavioral test.",
        "citations": [
            {"file": file, "line": line, "role": "implementation"},
            {"file": "test_app.py", "line": 1, "role": "test"},
        ],
    }


class LoopTestCase(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.dir = Path(self._tmp.name)
        self.build = self.dir / "install/makato-build"
        self.orch = self.dir / "independent/makato-orchestrate"
        for source, target in ((_HERE.parent, self.build), (_HERE.parents[1] / "makato-orchestrate", self.orch)):
            shutil.copytree(source, target, ignore=shutil.ignore_patterns("__pycache__", "*.pyc"))
        execution = patch.object(review_loop, "__file__", str(self.build / "shared/review_loop.py"))
        execution.start()
        self.addCleanup(execution.stop)
        exports = patch.dict(os.environ, dict.fromkeys(("MAKATO_BUILD_ROOT", "MAKATO_ORCHESTRATE_ROOT", "MAKATO_ORCHESTRATE_SHARED"), ""))
        exports.start()
        self.addCleanup(exports.stop)
        self.repo = self.dir / "worktree"
        self.repo.mkdir()
        _git(self.repo, "init", "-q", "-b", "main")
        _git(self.repo, "config", "user.email", "review@example.invalid")
        _git(self.repo, "config", "user.name", "Review test")
        _write(self.repo / "app.py", "VALUE = 1\n")
        _write(self.repo / "test_app.py", "def test_value():\n    assert __import__('app').VALUE >= 1\n")
        _write(self.build / "review-contract.md", "# Versioned review contract fixture\n")
        self.contract_paths = ["review-contract.md", *review_scope.REVIEW_CONTRACT_PATHS]
        for name in ("shared.py", "auth.py", "caller.py", "lease.py", "lease_variant_2.py", "lease_variant_3.py", "owner.py", "api.py", "module.py"):
            _write(self.repo / name, "".join(f"# evidence line {line}\n" for line in range(1, 80)))
        _git(self.repo, "add", "-A")
        _git(self.repo, "commit", "-qm", "review base")
        self.base = _git(self.repo, "rev-parse", "HEAD")
        self.state = str(self.dir / "ledger" / "GH-1.json")
        review_loop.init(self.state, "GH-1", self.base)
        self._files = 0

    def fingerprint(self, **kwargs: object) -> str:
        kwargs.setdefault("contract_paths", self.contract_paths)
        kwargs.setdefault("contract_root", str(self.build))
        kwargs.setdefault("orchestrate_root", str(self.orch))
        return str(review_scope.fingerprint(str(self.repo), self.base, **kwargs)["sha256"])

    def r1_file(self, r1: dict) -> str:
        self._files += 1
        path = self.dir / f"r1-{self._files}.json"
        path.write_text(json.dumps(r1), encoding="utf-8")
        return str(path)

    def merge(
        self,
        findings: list[dict] | None = None,
        *,
        pass_number: int = 1,
        scope: str = "full",
        after_round: int = 0,
        status: str | None = None,
        ac: list | None = None,
        expected_ac_ids: list[str] | None = None,
        files_reviewed: int = 2,
        file_citations: list[dict] | None = None,
        reviewer_id: str | None = None,
        input_fingerprint: str | None = None,
        lens: str | None = None,
        context_paths: list[str] | None = None,
        contract_paths: list[str] | None = None,
    ) -> dict:
        contract_paths = self.contract_paths if contract_paths is None else contract_paths
        fingerprint = input_fingerprint or self.fingerprint(
            context_paths=context_paths or [],
            contract_paths=contract_paths,
        )
        envelope = _r1(
            list(findings or []),
            lens=lens,
            status=status,
            ac=ac,
            input_fingerprint=fingerprint,
            files_reviewed=files_reviewed,
            file_citations=file_citations,
            reviewer_id=reviewer_id,
        )
        return review_loop.merge(
            self.state,
            pass_number,
            scope,
            after_round,
            None,
            [self.r1_file(envelope)],
            input_fingerprint=fingerprint,
            context_paths=context_paths,
            contract_paths=contract_paths,
            contract_root=str(self.build),
            orchestrate_root=str(self.orch),
            expected_ac_ids=expected_ac_ids,
        )

    def gate(self, event: str, evidence: dict | None = None, **kwargs: object) -> dict:
        kwargs.setdefault("contract_root", str(self.build))
        kwargs.setdefault("orchestrate_root", str(self.orch))
        if not self.stored()["contract_paths"]:
            kwargs.setdefault("contract_paths", self.contract_paths)
        evidence_path = None
        if evidence is not None:
            evidence_path = self.dir / f"evidence-{len(self.stored()['gate_history'])}.json"
            evidence_path.write_text(json.dumps(evidence), encoding="utf-8")
            evidence_path = str(evidence_path)
        return review_loop.gate(self.state, event, str(self.repo), self.base, evidence_path, **kwargs)

    def cli(self, *argv: str) -> tuple[int, str, str]:
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = review_loop._main(list(argv))
        return code, out.getvalue(), err.getvalue()

    def stored(self) -> dict:
        return json.loads(Path(self.state).read_text(encoding="utf-8"))

    def open_constituents(self, fingerprint: str | None = None) -> list[tuple[str, str, dict]]:
        current = fingerprint or self.fingerprint()
        result = []
        for finding_id, finding in self.stored()["findings"].items():
            if finding.get("severity") not in review_loop.BLOCKING:
                continue
            for constituent_id, constituent in finding["constituents"].items():
                closed = any(
                    entry.get("input_fingerprint") == current
                    and entry.get("disposition") in ("fixed", "false_positive")
                    and entry.get("pass", 0) >= max((item["pass"] for item in constituent.get("occurrences", [])), default=0)
                    for entry in constituent["closure_history"]
                )
                if not closed:
                    result.append((finding_id, constituent_id, constituent))
        return result

    def dispositions(self, disposition: str, fingerprint: str | None = None) -> list[dict]:
        result = []
        latest = next((entry for entry in reversed(self.stored()["passes"]) if entry["scope"] != "background-full"), {})
        for finding_id, constituent_id, constituent in self.open_constituents(fingerprint):
            if disposition == "confirmed" and (finding_id not in latest.get("blocking", []) or constituent_id not in latest.get("constituent_ids", [])):
                continue
            item = {
                "finding_id": finding_id,
                "constituent_id": constituent_id,
                "disposition": disposition,
                "evidence": f"Independent review disposition: {disposition}.",
                "citations": [{"file": constituent["sites"][0]["file"], "line": constituent["sites"][0]["line"]}],
            }
            if disposition == "confirmed":
                item["repair_scope"] = "local"
            result.append(item)
        return result

    def disposition_evidence(self, disposition: str, *, reviewer_id: str = "verifier-1", fingerprint: str | None = None) -> dict:
        return {
            "reviewer_id": reviewer_id,
            "independent": True,
            "input_fingerprint": fingerprint or self.fingerprint(),
            "dispositions": self.dispositions(disposition, fingerprint),
        }

    def confirm_open(self, fingerprint: str | None = None) -> dict:
        current = fingerprint or self.fingerprint()
        return self.gate("confirm", self.disposition_evidence("confirmed", fingerprint=current))

    def reserve_local(self, fingerprint: str | None = None, **kwargs: object) -> dict:
        current = fingerprint or self.fingerprint()
        return self.gate("repair-local", {"input_fingerprint": current}, **kwargs)


class MergeContractTests(LoopTestCase):
    def test_missing_mandatory_r1_fields_cannot_enter_the_ledger(self) -> None:
        valid = _r1([], input_fingerprint=self.fingerprint())
        before = Path(self.state).read_bytes()
        for field in ("schema", "agent", "status", "summary", "files_changed", "tests_written", "errors", "tool_calls_used", "data"):
            with self.subTest(field=field):
                Path(self.state).write_bytes(before)
                malformed = {key: value for key, value in valid.items() if key != field}
                with self.assertRaises(review_loop.LoopError):
                    review_loop.merge(self.state, 1, "final-full", 0, None, [self.r1_file(malformed)])
                self.assertEqual(Path(self.state).read_bytes(), before)

    def test_invalid_outer_r1_values_cannot_enter_the_ledger(self) -> None:
        before = Path(self.state).read_bytes()
        for field, value in (
            ("agent", None),
            ("agent", ""),
            ("agent", "coder"),
            ("summary", None),
            ("summary", ""),
            ("summary", "first line\nsecond line"),
            ("summary", "x" * 241),
            ("files_changed", None),
            ("files_changed", ["app.py"]),
            ("tests_written", None),
            ("tests_written", [1]),
            ("tests_written", ["test_app.py"]),
            ("errors", None),
            ("errors", ["x" * 241]),
            ("tool_calls_used", True),
            ("tool_calls_used", -1),
            ("tool_calls_used", 1.5),
            ("tool_calls_used", "0"),
        ):
            with self.subTest(field=field, value=value):
                Path(self.state).write_bytes(before)
                malformed = {**_r1([], input_fingerprint=self.fingerprint()), field: value}
                with self.assertRaises(review_loop.LoopError):
                    review_loop.merge(self.state, 1, "final-full", 0, None, [self.r1_file(malformed)])
                self.assertEqual(Path(self.state).read_bytes(), before)

    def test_merge_emits_complete_r1_and_preserves_reviewer_tool_counts(self) -> None:
        fingerprint = self.fingerprint()
        inputs = [{**_r1([], input_fingerprint=fingerprint), "tool_calls_used": count} for count in (2, 3)]
        merged = review_loop.merge(self.state, 1, "full", 0, None, [self.r1_file(envelope) for envelope in inputs])
        self.assertEqual(merged["tool_calls_used"], 5)
        self.assertEqual(merged["agent"], "diff-reviewer")
        self.assertTrue(merged["summary"])
        self.assertEqual(merged["files_changed"], [])
        self.assertEqual(merged["tests_written"], [])
        self.assertEqual(merged["errors"], [])

    def test_merged_error_summaries_remain_valid_without_truncating_finding_evidence(self) -> None:
        finding = _finding("MAJOR", "app.py", 1, finding_id="verbose", invariant="bounded input", description="details " * 100)
        merged = self.merge([finding])
        self.assertTrue(all(len(error) <= 240 for error in merged["errors"]))
        self.assertEqual(merged["data"]["findings"][0]["description"], finding["description"])
        self.assertEqual(self.stored()["raw_envelopes"][0]["envelope"]["data"]["findings"], [finding])

    def test_sixteen_nearby_and_transitive_raw_blockers_keep_invariants_and_constituent_evidence(self) -> None:
        raw = []
        for index in range(16):
            raw_id = "lens-collision" if index in (0, 1) else f"raw-{index:02d}"
            lens = ("security-privacy", "error-handling")[index % 2]
            line = 10 if index < 2 else 10 + 2 * min(index - 1, 2)
            raw.append(
                _finding(
                    "MAJOR",
                    "shared.py",
                    line,
                    finding_id=raw_id,
                    invariant=f"independent rule {index}",
                    description=f"Description {index}",
                    evidence=f"Evidence {index}",
                    lens=lens,
                )
            )

        merged = self.merge(raw, lens="security-privacy")
        records = self.stored()

        self.assertEqual(merged["data"]["major_count"], 16)
        self.assertEqual(len(merged["data"]["findings"]), 16)
        self.assertEqual(len(records["raw_envelopes"]), 1)
        self.assertEqual(records["raw_envelopes"][0]["envelope"]["data"]["findings"], raw)
        self.assertEqual(len({finding["invariant_id"] for finding in merged["data"]["findings"]}), 16)
        for finding in merged["data"]["findings"]:
            index = int(finding["invariant"].rsplit(" ", 1)[1])
            constituent = finding["constituents"][0]
            self.assertEqual(constituent["description"], f"Description {index}")
            self.assertEqual(constituent["evidence"], f"Evidence {index}")
            self.assertEqual(constituent["raw_ids"], [raw[index]["id"]])
            self.assertEqual(constituent["sites"], raw[index]["sites"])
        self.assertEqual(merged["data"]["findings"][0]["sites"], [{"file": "shared.py", "line": 10}])

    def test_same_invariant_across_new_raw_ids_and_sites_keeps_each_constituent(self) -> None:
        invariant = " Every request must be authorized "
        first = _finding("MAJOR", "auth.py", 12, finding_id="legacy-11", invariant=invariant, lens="security-privacy")
        second = _finding("MAJOR", "caller.py", 30, finding_id="fresh-92", invariant="every request must be authorized", lens="error-handling")
        self.merge([first], lens="security-privacy")
        merged = self.merge([second], pass_number=2, scope="delta", after_round=1, lens="error-handling")

        self.assertEqual(len(merged["data"]["findings"]), 1)
        record = self.stored()["findings"]["F-001"]
        self.assertEqual(merged["data"]["findings"][0]["constituent_ids"], sorted(record["constituents"]))
        self.assertEqual(len(record["constituents"]), 2)
        sites = {(site["file"], site["line"]) for site in merged["data"]["findings"][0]["sites"]}
        self.assertEqual(sites, {("auth.py", 12), ("caller.py", 30)})
        observed_raw_ids = {occurrence["raw_finding"]["id"] for constituent in record["constituents"].values() for occurrence in constituent["occurrences"]}
        self.assertEqual(observed_raw_ids, {"legacy-11", "fresh-92"})
        self.assertEqual(len(record["raised_in"]), 2)

    def test_r1_requires_a_real_reviewer_instance_id(self) -> None:
        malformed = _r1([], input_fingerprint=self.fingerprint())
        del malformed["data"]["reviewer_id"]
        before = Path(self.state).read_bytes()

        with self.assertRaisesRegex(review_loop.LoopError, "reviewer_id"):
            review_loop.merge(self.state, 1, "full", 0, None, [self.r1_file(malformed)])

        self.assertEqual(Path(self.state).read_bytes(), before)

    def test_invalid_r1_file_citations_are_rejected_before_state_mutation(self) -> None:
        fingerprint = self.fingerprint()
        malformed = _r1(
            [],
            input_fingerprint=fingerprint,
            file_citations=[{"file": "app.py", "line": 0}],
        )
        before = Path(self.state).read_bytes()

        with self.assertRaisesRegex(review_loop.LoopError, "positive integer line"):
            review_loop.merge(self.state, 1, "full", 0, None, [self.r1_file(malformed)])

        self.assertEqual(Path(self.state).read_bytes(), before)

    def test_r1_without_its_own_or_explicit_fingerprint_cannot_inherit_current_state(self) -> None:
        self.merge([])
        before = Path(self.state).read_bytes()

        with self.assertRaisesRegex(review_loop.LoopError, "explicit input fingerprint"):
            review_loop.merge(self.state, 2, "delta", 0, None, [self.r1_file(_r1([]))])

        self.assertEqual(Path(self.state).read_bytes(), before)

    def test_partial_and_malformed_r1_never_replace_a_successful_consumer_result(self) -> None:
        prior = self.merge([])
        before = self.stored()
        partial = self.merge([], pass_number=2, scope="delta", status="partial")
        self.assertEqual(partial["status"], "partial")
        self.assertEqual(partial["data"]["next_action"], "review")

        malformed = _r1([_finding("MAJOR", "app.py", 1, finding_id="bad", invariant="broken")])
        malformed["data"]["major_count"] = 0
        before_invalid = Path(self.state).read_bytes()
        with self.assertRaisesRegex(review_loop.LoopError, "major_count"):
            review_loop.merge(self.state, 3, "delta", 0, None, [self.r1_file(malformed)])
        self.assertEqual(Path(self.state).read_bytes(), before_invalid)

        failed_without_findings = self.r1_file(_r1([], status="failure", errors=["reviewer failed before reporting findings"]))
        with self.assertRaisesRegex(review_loop.LoopError, "failure requires blocking findings"):
            review_loop.merge(self.state, 3, "delta", 0, None, [failed_without_findings])
        self.assertEqual(Path(self.state).read_bytes(), before_invalid)
        self.assertEqual(len(self.stored()["passes"]), len(before["passes"]) + 1)
        self.assertNotEqual(prior["data"]["pass_id"], partial["data"]["pass_id"])

    def test_invalid_blocker_input_is_rejected_without_mutating_the_ledger(self) -> None:
        before = Path(self.state).read_bytes()
        invalid = _finding("MAJOR", "app.py", 1, finding_id="bad", invariant=" ")
        code, out, err = self.cli("merge", "--state", self.state, "--pass", "1", "--scope", "full", "--after-round", "0", self.r1_file(_r1([invalid])))
        self.assertEqual((code, out), (2, ""))
        self.assertIn("needs an invariant", err)
        self.assertEqual(Path(self.state).read_bytes(), before)

    def test_contract_lens_owns_ac_verdicts_and_transcript_uses_its_last_r1_object(self) -> None:
        security_verdict = {"ac_id": "AC-1", "verified": False, "evidence": "Security lens does not own AC certification.", "citations": []}
        contract_verdict = _ac("AC-1")
        contract = _r1([], lens="contract-ac", ac=[contract_verdict])
        security = _r1([], lens="security-privacy", ac=[security_verdict])
        merged = review_loop.merge(
            self.state,
            1,
            "full",
            0,
            None,
            [self.r1_file(security), self.r1_file(contract)],
            input_fingerprint=self.fingerprint(),
            contract_paths=self.contract_paths,
            contract_root=str(self.build),
            orchestrate_root=str(self.orch),
        )
        self.assertEqual(merged["data"]["ac_verdicts"], [contract_verdict])

        transcript = self.dir / "reviewer-transcript.txt"
        blocker = _finding("MAJOR", "app.py", 1, finding_id="from-last-object", invariant="the final object is authoritative")
        transcript.write_text(
            "analysis {not-json}\n" + json.dumps(_r1([])) + "\n" + json.dumps(_r1([blocker])),
            encoding="utf-8",
        )
        result = review_loop.merge(
            self.state,
            2,
            "delta",
            0,
            None,
            [str(transcript)],
            input_fingerprint=self.fingerprint(),
            contract_paths=self.contract_paths,
            contract_root=str(self.build),
            orchestrate_root=str(self.orch),
        )
        self.assertEqual(result["data"]["major_count"], 1)
        self.assertEqual(result["data"]["findings"][0]["constituents"][0]["raw_ids"], ["from-last-object"])

    def test_removed_drop_ids_cli_is_rejected_instead_of_suppressing_a_constituent(self) -> None:
        before = Path(self.state).read_bytes()
        arguments = [
            "merge",
            "--state",
            self.state,
            "--pass",
            "1",
            "--scope",
            "full",
            "--after-round",
            "0",
            "--drop-ids",
            "F-001",
            self.r1_file(_r1([])),
        ]
        error = io.StringIO()
        with contextlib.redirect_stderr(error), self.assertRaises(SystemExit) as raised:
            review_loop._main(arguments)
        self.assertEqual(raised.exception.code, 2)
        self.assertIn("--drop-ids", error.getvalue())
        self.assertEqual(Path(self.state).read_bytes(), before)


class GateAndRecoveryTests(LoopTestCase):
    def test_distinct_dismissed_invariant_is_history_not_repair_authority(self) -> None:
        self.merge(
            [
                _finding("MAJOR", "app.py", 1, finding_id="false-positive", invariant="dismissed invariant"),
                _finding("MAJOR", "app.py", 1, finding_id="real-blocker", invariant="real invariant"),
            ]
        )
        evidence = self.disposition_evidence("confirmed")
        dismissed = evidence["dispositions"][0]
        dismissed["disposition"] = "false_positive"
        dismissed.pop("repair_scope")
        self.assertEqual(self.gate("confirm", evidence)["next_action"], "repair-local")
        history = copy.deepcopy(self.stored()["findings"]["F-001"])

        def source_cli(*args: str) -> dict:
            result = subprocess.run([sys.executable, str(self.build / "shared/review_loop.py"), *args], capture_output=True, text=True, check=True)
            return json.loads(result.stdout)

        reserved = source_cli("gate", "--state", self.state, "--event", "repair-local", "--worktree", str(self.repo), "--review-base", self.base)
        self.assertEqual(reserved["repair_attempt"]["ids"], ["F-002"])
        self.assertEqual(self.reserve_local()["repair_attempt"], reserved["repair_attempt"])
        claimed = source_cli("repaired", "--state", self.state, "--round", "1", "--ids", ",".join(reserved["repair_attempt"]["ids"]), "--coder-id", "repair-coder")
        self.assertEqual(claimed["next_action"], "review")
        state = self.stored()
        self.assertEqual(state["repair_attempts"][0]["status"], "claimed")
        self.assertEqual(state["max_repair_round"], 1)
        self.assertEqual(state["findings"]["F-001"], history)
        self.assertEqual(len(state["raw_envelopes"]), 1)
        self.assertEqual(self.reserve_local()["next_action"], "blocked")

    def test_delta_confirms_only_new_blockers_and_preserves_repaired_history_for_certification(self) -> None:
        self.merge([_finding("MAJOR", "app.py", 1, finding_id="raw-first", invariant="input is bounded")])
        self.assertEqual(self.confirm_open()["next_action"], "repair-local")
        self.assertEqual(self.reserve_local()["next_action"], "repair-local")
        review_loop.repaired(self.state, 1, ["F-001"], "coder-1")
        historical = self.stored()["findings"]["F-001"]
        first_envelope = self.stored()["raw_envelopes"][0]

        _write(self.repo / "app.py", "VALUE = 2  # first finding repaired\n")
        self.gate("review")
        delta = self.merge(
            [_finding("MAJOR", "caller.py", 30, finding_id="raw-second", invariant="caller owns the request")],
            pass_number=2,
            scope="delta",
            after_round=1,
        )
        self.assertEqual(delta["data"]["next_action"], "confirm")
        evidence = self.disposition_evidence("confirmed")
        self.assertEqual([item["finding_id"] for item in evidence["dispositions"]], ["F-002"])
        self.assertEqual(self.gate("confirm", evidence)["next_action"], "repair-local")
        self.assertEqual(self.stored()["findings"]["F-001"], historical)
        self.assertEqual(self.stored()["raw_envelopes"][0], first_envelope)
        reserved = self.reserve_local()
        self.assertEqual(reserved["next_action"], "repair-local")
        self.assertEqual(reserved["repair_attempt"]["ids"], ["F-002"])
        self.assertEqual(review_loop.repaired(self.state, 2, ["F-002"], "coder-1")["next_action"], "review")

        _write(self.repo / "app.py", "VALUE = 3  # both findings repaired\n")
        self.gate("review")
        final = self.merge([], pass_number=3, scope="final-full", after_round=2, expected_ac_ids=["AC-1"], ac=[_ac("AC-1")])
        self.assertEqual(final["data"]["next_action"], "certify")
        closures = self.disposition_evidence("fixed")
        self.assertEqual({item["finding_id"] for item in closures["dispositions"]}, {"F-001", "F-002"})
        missing_history = {**closures, "dispositions": [item for item in closures["dispositions"] if item["finding_id"] == "F-002"]}
        blocked = self.gate("certify", missing_history)
        self.assertEqual(blocked["next_action"], "blocked")
        self.assertIn("F-001/", blocked["reason"])
        self.assertEqual(self.stored()["findings"]["F-001"], historical)
        self.assertEqual(self.gate("complete")["next_action"], "certify")
        self.assertEqual(self.gate("certify", closures)["next_action"], "certify")
        for constituent_id, constituent in historical["constituents"].items():
            closed = self.stored()["findings"]["F-001"]["constituents"][constituent_id]
            self.assertEqual(closed["confirmation_history"], constituent["confirmation_history"])
            self.assertEqual(closed["occurrences"], constituent["occurrences"])
            self.assertEqual([item["disposition"] for item in closed["closure_history"]], ["fixed"])
        fingerprint = self.fingerprint()
        completion = {
            "input_fingerprint": fingerprint,
            "mechanical": {
                "before_fingerprint": fingerprint,
                "after_fingerprint": fingerprint,
                "no_change": True,
                "evidence": "The final mechanical checks made no worktree changes.",
            },
        }
        self.assertEqual(self.gate("complete", completion)["next_action"], "complete")

    def test_missing_current_confirmation_blocks_even_when_other_current_constituents_are_dismissed(self) -> None:
        self.merge([_finding("MAJOR", "owner.py", 4, finding_id=f"raw-{number}", invariant="every write has a current owner", description=f"copy {number}") for number in range(3)])
        evidence = self.disposition_evidence("confirmed")
        for disposition in evidence["dispositions"][:2]:
            disposition["disposition"] = "false_positive"
            disposition.pop("repair_scope")
        minority = evidence["dispositions"][-1]["constituent_id"]
        missing_current = {**evidence, "dispositions": evidence["dispositions"][:2]}
        blocked = self.gate("confirm", missing_current)
        self.assertEqual(blocked["next_action"], "blocked")
        self.assertIn(minority, blocked["reason"])
        self.assertTrue(all(not constituent["confirmation_history"] and not constituent["closure_history"] for _, _, constituent in self.open_constituents()))
        self.assertEqual(self.reserve_local()["next_action"], "confirm")
        self.assertEqual(self.stored()["repair_attempts"], [])

        self.assertEqual(self.gate("confirm", evidence)["next_action"], "repair-local")
        self.assertEqual({constituent_id for _, constituent_id, _ in self.open_constituents()}, {minority})
        self.assertEqual(self.gate("complete")["next_action"], "repair-local")
        self.assertEqual(self.reserve_local()["next_action"], "repair-local")
        self.assertEqual(review_loop.repaired(self.state, 1, ["F-001"], "coder-1")["next_action"], "review")

    def test_background_pass_does_not_replace_current_raw_confirmation_scope(self) -> None:
        current = _finding("MAJOR", "auth.py", 5, finding_id="raw-current", invariant="authorization is checked")
        self.merge([current])
        self.merge(
            [current, _finding("MAJOR", "caller.py", 30, finding_id="raw-background", invariant="caller owns the request")],
            pass_number=2,
            scope="background-full",
        )
        evidence = self.disposition_evidence("confirmed")
        self.assertEqual([item["finding_id"] for item in evidence["dispositions"]], ["F-001"])
        self.assertEqual(self.gate("confirm", evidence)["next_action"], "repair-local")
        reserved = self.reserve_local()
        self.assertEqual(reserved["next_action"], "repair-local")
        self.assertEqual(reserved["repair_attempt"]["pass_id"], "P-1")
        self.assertEqual(reserved["repair_attempt"]["ids"], ["F-001"])
        self.assertEqual(review_loop.repaired(self.state, 1, ["F-001"], "coder-1")["next_action"], "review")
        self.assertEqual({finding_id for finding_id, _, _ in self.open_constituents()}, {"F-001", "F-002"})

        self.merge([], pass_number=3, scope="final-full", after_round=1, expected_ac_ids=["AC-1"], ac=[_ac("AC-1")])
        closures = self.disposition_evidence("fixed")
        missing_background = {**closures, "dispositions": [item for item in closures["dispositions"] if item["finding_id"] == "F-001"]}
        blocked = self.gate("certify", missing_background)
        self.assertEqual(blocked["next_action"], "blocked")
        self.assertIn("F-002/", blocked["reason"])
        self.assertEqual(len(self.stored()["raw_envelopes"]), 3)

    def test_historical_confirmer_cannot_claim_a_new_site_of_the_same_invariant(self) -> None:
        invariant = "one owner per active lease"
        self.merge([_finding("CRITICAL", "lease.py", 10, finding_id="raw-first", invariant=invariant)])
        self.confirm_open()
        self.reserve_local()
        review_loop.repaired(self.state, 1, ["F-001"], "coder-1")
        self.merge(
            [_finding("CRITICAL", "lease_variant_2.py", 12, finding_id="raw-second", invariant=invariant)],
            pass_number=2,
            scope="delta",
            after_round=1,
        )
        confirmed = self.gate("confirm", self.disposition_evidence("confirmed", reviewer_id="verifier-2"))
        self.assertEqual(confirmed["next_action"], "repair-local")
        self.assertEqual(self.reserve_local()["next_action"], "repair-local")
        with self.assertRaisesRegex(review_loop.LoopError, "confirming verifier"):
            review_loop.repaired(self.state, 2, ["F-001"], "verifier-1")
        self.assertEqual(review_loop.repaired(self.state, 2, ["F-001"], "coder-1")["next_action"], "review")

    def test_stable_prior_id_preserves_recurrence_when_invariant_is_paraphrased(self) -> None:
        self.merge([_finding("CRITICAL", "lease.py", 10, finding_id="raw-a", invariant="one owner per active lease")])
        identity = self.stored()["findings"]["F-001"]["invariant_id"]
        for pass_number, wording in ((2, "Active lease ownership must stay exclusive"), (3, "Never allow concurrent holders of a live lease")):
            self.confirm_open()
            self.assertEqual(self.reserve_local()["next_action"], "repair-local")
            review_loop.repaired(self.state, pass_number - 1, ["F-001"], "coder-1")
            _write(self.repo / "app.py", f"VALUE = {pass_number}\n")
            self.gate("review")
            result = self.merge(
                [_finding("CRITICAL", f"lease_variant_{pass_number}.py", 10 + pass_number, finding_id="F-001", invariant=wording)],
                pass_number=pass_number,
                scope="delta",
                after_round=pass_number - 1,
            )
            self.assertEqual([finding["id"] for finding in result["data"]["findings"]], ["F-001"])
            record = self.stored()["findings"]["F-001"]
            self.assertEqual(record["invariant_id"], identity)
            self.assertEqual(review_loop.recurrences(record), pass_number - 1)
            self.assertEqual(len(record["constituents"]), pass_number)
        self.assertEqual(self.confirm_open()["next_action"], "redesign")
        self.assertNotEqual(self.reserve_local()["next_action"], "repair-local")

    def test_invariant_recurrence_survives_new_raw_ids_and_sites_and_routes_to_redesign(self) -> None:
        invariant = "one owner per active lease"
        self.merge([_finding("CRITICAL", "lease.py", 10, finding_id="raw-a", invariant=invariant)])
        self.confirm_open()
        first = self.reserve_local()
        self.assertEqual(first["next_action"], "repair-local")
        review_loop.repaired(self.state, 1, ["F-001"], "coder-1")

        for pass_number, repair_round in ((2, 1), (3, 2)):
            historical = self.stored()["findings"]["F-001"]["constituents"]
            changed = _finding(
                "CRITICAL",
                f"lease_variant_{pass_number}.py",
                10 + pass_number,
                finding_id=f"new-raw-{pass_number}",
                invariant="ONE OWNER PER ACTIVE LEASE",
            )
            _write(self.repo / "app.py", f"VALUE = {pass_number}  # repaired previous lease site\n")
            self.gate("review")
            merged = self.merge([changed], pass_number=pass_number, scope="delta", after_round=repair_round)
            self.assertEqual([item["id"] for item in merged["data"]["findings"]], ["F-001"])
            evidence = self.disposition_evidence("confirmed")
            current_ids = set(self.stored()["passes"][-1]["constituent_ids"])
            self.assertEqual(len(evidence["dispositions"]), 1)
            self.assertEqual({item["constituent_id"] for item in evidence["dispositions"]}, current_ids)
            self.assertEqual(len(merged["data"]["findings"][0]["constituent_ids"]), pass_number)
            confirmed = self.gate("confirm", evidence)
            self.assertEqual(confirmed["next_action"], "repair-local" if repair_round == 1 else "redesign")
            for constituent_id, constituent in historical.items():
                self.assertEqual(self.stored()["findings"]["F-001"]["constituents"][constituent_id], constituent)
            if repair_round == 1:
                second = self.reserve_local()
                self.assertEqual(second["next_action"], "repair-local")
                review_loop.repaired(self.state, 2, ["F-001"], "coder-1")

        record = self.stored()["findings"]["F-001"]
        self.assertEqual(review_loop.recurrences(record), 2)
        self.assertEqual(len(record["constituents"]), 3)
        attempts_before = len(self.stored()["repair_attempts"])
        bypass = self.reserve_local()
        self.assertNotEqual(bypass["next_action"], "repair-local")
        self.assertEqual(len(self.stored()["repair_attempts"]), attempts_before)
        redesign = self.gate("redesign", {"input_fingerprint": self.fingerprint()})
        self.assertEqual(redesign["next_action"], "redesign")
        self.assertEqual(self.stored()["repair_attempts"][-1]["mode"], "redesign")
        self.assertEqual(review_loop.repaired(self.state, 3, ["F-001"], "coder-1")["next_action"], "review")

        _write(self.repo / "app.py", "VALUE = 4  # redesigned lease invariant\n")
        self.gate("review")
        final = self.merge([], pass_number=4, scope="final-full", after_round=3, expected_ac_ids=["AC-1"], ac=[_ac("AC-1")])
        self.assertEqual(final["data"]["next_action"], "certify")
        closures = self.disposition_evidence("fixed")
        self.assertEqual(len(closures["dispositions"]), 3)
        missing_history = {**closures, "dispositions": [item for item in closures["dispositions"] if item["constituent_id"] in current_ids]}
        blocked = self.gate("certify", missing_history)
        self.assertEqual(blocked["next_action"], "blocked")
        self.assertIn("omits required constituents", blocked["reason"])
        self.assertEqual(len(self.open_constituents()), 3)
        self.assertEqual(self.gate("certify", closures)["next_action"], "certify")
        closed = self.stored()["findings"]["F-001"]
        self.assertEqual(review_loop.recurrences(closed), 2)
        self.assertEqual(
            {occurrence["raw_finding"]["id"] for constituent in closed["constituents"].values() for occurrence in constituent["occurrences"]},
            {"raw-a", "new-raw-2", "new-raw-3"},
        )
        self.assertTrue(all([entry["disposition"] for entry in constituent["closure_history"]] == ["fixed"] for constituent in closed["constituents"].values()))
        fingerprint = self.fingerprint()
        completion = {
            "input_fingerprint": fingerprint,
            "mechanical": {
                "before_fingerprint": fingerprint,
                "after_fingerprint": fingerprint,
                "no_change": True,
                "evidence": "The final mechanical checks made no worktree changes.",
            },
        }
        self.assertEqual(self.gate("complete", completion)["next_action"], "complete")

    def test_uncertain_and_false_positive_constituents_do_not_outvote_a_remaining_blocker(self) -> None:
        same_rule = "every write has a current owner"
        findings = [_finding("MAJOR", "owner.py", 4, finding_id=f"raw-{number}", invariant=same_rule, description=f"copy {number}") for number in range(3)]
        merged = self.merge(findings)
        constituents = merged["data"]["findings"][0]["constituents"]
        dispositions = []
        for number, constituent in enumerate(constituents):
            disposition = ("false_positive", "confirmed", "uncertain")[number]
            site = constituent["sites"][0]
            dispositions.append(
                {
                    "finding_id": "F-001",
                    "constituent_id": constituent["constituent_id"],
                    "disposition": disposition,
                    "evidence": f"Independent assessment: {disposition}.",
                    "citations": [{"file": site["file"], "line": site["line"]}],
                    **({"repair_scope": "local"} if disposition == "confirmed" else {}),
                }
            )
        result = self.gate(
            "confirm",
            {"reviewer_id": "second-reviewer", "independent": True, "input_fingerprint": self.fingerprint(), "dispositions": dispositions},
        )

        self.assertEqual(result["next_action"], "blocked")
        self.assertIn("uncertain", result["reason"])
        state_record = self.stored()["findings"]["F-001"]
        self.assertEqual(sum(bool(item["closure_history"]) for item in state_record["constituents"].values()), 1)
        open_ids = {constituent_id for _, constituent_id, _ in self.open_constituents()}
        self.assertEqual(len(open_ids), 2)
        self.assertEqual(state_record["severity"], "MAJOR")

    def test_each_constituent_must_close_after_repair_before_complete(self) -> None:
        expected = ["AC-1", "AC-2"]
        findings = [
            _finding("MAJOR", "app.py", 1, finding_id="raw-1", invariant="validated input is bounded"),
            _finding("CRITICAL", "app.py", 1, finding_id="raw-2", invariant="writes require authorization"),
        ]
        initial = self.merge(findings, expected_ac_ids=expected)
        self.assertEqual(initial["data"]["next_action"], "confirm")
        self.confirm_open()
        self.assertEqual(self.reserve_local()["next_action"], "repair-local")
        review_loop.repaired(self.state, 1, ["F-001", "F-002"], "coder-1")

        _write(self.repo / "app.py", "VALUE = 2  # corrected\n")
        self.gate("review")
        fingerprint = self.fingerprint()
        clean = self.merge([], pass_number=2, scope="delta", after_round=1, expected_ac_ids=expected, input_fingerprint=fingerprint)
        self.assertEqual(clean["status"], "success")
        complete_dispositions = self.dispositions("fixed", fingerprint)
        self.assertEqual(len(complete_dispositions), 2)
        missing_one = {**self.disposition_evidence("fixed", fingerprint=fingerprint), "dispositions": complete_dispositions[:1]}
        blocked = self.gate("certify", missing_one)
        self.assertEqual(blocked["next_action"], "blocked")
        self.assertIn("omits required constituents", blocked["reason"])
        self.assertFalse(any(item["closure_history"] for _, _, item in self.open_constituents(fingerprint)))

        certified = self.gate(
            "certify",
            {**self.disposition_evidence("fixed", fingerprint=fingerprint), "dispositions": complete_dispositions},
        )
        self.assertEqual(certified["next_action"], "certify")
        final = self.merge(
            [],
            pass_number=3,
            scope="final-full",
            after_round=1,
            expected_ac_ids=expected,
            input_fingerprint=fingerprint,
            ac=[_ac("AC-1"), _ac("AC-2")],
        )
        self.assertEqual(final["data"]["next_action"], "certify")
        completion = {
            "event": "complete",
            "input_fingerprint": fingerprint,
            "mechanical": {
                "before_fingerprint": fingerprint,
                "after_fingerprint": fingerprint,
                "no_change": True,
                "evidence": "The final mechanical checks made no worktree changes.",
            },
        }
        result = self.gate("complete", completion)
        self.assertEqual(result["next_action"], "complete")
        history = self.stored()["gate_history"]
        self.assertEqual([entry["gate_id"] for entry in history], list(range(1, len(history) + 1)))
        self.assertTrue({"initial", "review", "confirm", "repair-local", "certify", "complete"}.issubset({entry["event"] for entry in history}))
        self.assertEqual(self.stored()["mechanical_evidence"]["pass_id"], final["data"]["pass_id"])

    def test_first_architectural_confirmation_routes_to_redesign_without_recurrence(self) -> None:
        self.merge([_finding("MAJOR", "api.py", 8, finding_id="raw-contract", invariant="public contract remains atomic")])
        disposition = self.dispositions("confirmed")[0]
        disposition["repair_scope"] = "cross-boundary"
        result = self.gate(
            "confirm",
            {
                "reviewer_id": "architecture-reviewer",
                "independent": True,
                "input_fingerprint": self.fingerprint(),
                "dispositions": [disposition],
            },
        )

        self.assertEqual(result["next_action"], "redesign")
        self.assertEqual(self.stored()["repair_attempts"], [])
        redesign = self.gate("redesign", {"input_fingerprint": self.fingerprint()})
        self.assertEqual(redesign["next_action"], "redesign")
        self.assertEqual(self.stored()["repair_attempts"][-1]["mode"], "redesign")

    def test_missing_confirmation_scope_fails_closed_to_redesign(self) -> None:
        self.merge([_finding("MAJOR", "module.py", 3, finding_id="raw-unknown", invariant="module boundaries remain explicit")])
        disposition = self.dispositions("confirmed")[0]
        disposition.pop("repair_scope")
        result = self.gate(
            "confirm",
            {
                "reviewer_id": "independent-reviewer",
                "independent": True,
                "input_fingerprint": self.fingerprint(),
                "dispositions": [disposition],
            },
        )

        self.assertEqual(result["next_action"], "redesign")
        stored = self.stored()["findings"]["F-001"]["constituents"][disposition["constituent_id"]]["confirmation_history"][-1]
        self.assertEqual(stored["repair_scope"], "unknown")

    def test_raiser_cannot_confirm_and_repair_or_closer_cannot_share_identity(self) -> None:
        finding = _finding("MAJOR", "auth.py", 5, finding_id="raw-auth", invariant="authorization is checked")
        fingerprint = self.fingerprint()
        self.merge([finding], input_fingerprint=fingerprint, reviewer_id="review-1")
        self_confirm = self.gate(
            "confirm",
            self.disposition_evidence("confirmed", reviewer_id="review-1", fingerprint=fingerprint),
        )
        self.assertEqual(self_confirm["next_action"], "blocked")
        self.assertIn("reporter", self_confirm["reason"])
        finding_record = self.stored()["findings"]["F-001"]
        constituent_id = next(iter(finding_record["constituents"]))
        self.assertEqual(finding_record["constituents"][constituent_id]["confirmation_history"], [])

        confirmed = self.confirm_open(fingerprint)
        self.assertEqual(confirmed["next_action"], "repair-local")
        self.reserve_local(fingerprint)
        before_bad_coder = Path(self.state).read_bytes()
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as missing_coder:
            review_loop._main(["repaired", "--state", self.state, "--round", "1", "--ids", "F-001"])
        self.assertEqual(missing_coder.exception.code, 2)
        self.assertEqual(Path(self.state).read_bytes(), before_bad_coder)
        with self.assertRaisesRegex(review_loop.LoopError, "verifier"):
            review_loop.repaired(self.state, 1, ["F-001"], "verifier-1")
        self.assertEqual(Path(self.state).read_bytes(), before_bad_coder)

        review_loop.repaired(self.state, 1, ["F-001"], "coder-1")
        self.assertEqual(self.stored()["repair_attempts"][0]["coder_ids"], ["coder-1"])
        _write(
            self.repo / "auth.py",
            "".join("# repaired authorization check\n" if line == 5 else f"# evidence line {line}\n" for line in range(1, 80)),
        )
        self.gate("review")
        repaired_fingerprint = self.fingerprint()
        self.merge(
            [],
            pass_number=2,
            scope="delta",
            after_round=1,
            input_fingerprint=repaired_fingerprint,
            file_citations=[{"file": "auth.py", "line": 5}, {"file": "shared.py", "line": 1}],
        )

        coder_closure = self.gate(
            "certify",
            self.disposition_evidence("fixed", reviewer_id="coder-1", fingerprint=repaired_fingerprint),
        )
        self.assertEqual(coder_closure["next_action"], "blocked")
        self.assertIn("repair coder", coder_closure["reason"])
        self.assertEqual(
            self.stored()["findings"]["F-001"]["constituents"][constituent_id]["closure_history"],
            [],
        )

        verifier_closure = self.gate(
            "certify",
            self.disposition_evidence("fixed", reviewer_id="verifier-1", fingerprint=repaired_fingerprint),
        )
        self.assertEqual(verifier_closure["next_action"], "certify")
        closure = self.stored()["findings"]["F-001"]["constituents"][constituent_id]["closure_history"][-1]
        self.assertEqual(closure["reviewer_id"], "verifier-1")

    def test_a_reraised_constituent_cannot_reuse_an_older_false_positive_closure(self) -> None:
        finding = _finding("MAJOR", "auth.py", 5, finding_id="raw-auth", invariant="authorization is checked")
        fingerprint = self.fingerprint()
        self.merge([finding], input_fingerprint=fingerprint)
        constituent_id = next(iter(self.stored()["findings"]["F-001"]["constituents"]))
        false_positive = {
            "finding_id": "F-001",
            "constituent_id": constituent_id,
            "disposition": "false_positive",
            "evidence": "Independent reproduction shows the cited call is not reachable.",
            "citations": [{"file": "auth.py", "line": 5}],
        }
        self.gate(
            "confirm",
            {
                "reviewer_id": "independent-reviewer",
                "independent": True,
                "input_fingerprint": fingerprint,
                "dispositions": [false_positive],
            },
        )
        self.merge([finding], pass_number=2, scope="delta", input_fingerprint=fingerprint)
        current = self.gate(
            "confirm",
            {
                "reviewer_id": "independent-reviewer",
                "independent": True,
                "input_fingerprint": fingerprint,
                "dispositions": [
                    {
                        **false_positive,
                        "disposition": "confirmed",
                        "repair_scope": "local",
                        "evidence": "The current independent review reproduced the blocker.",
                    }
                ],
            },
        )

        self.assertEqual(current["next_action"], "repair-local")
        history = self.stored()["findings"]["F-001"]["constituents"][constituent_id]["confirmation_history"]
        self.assertEqual(history[-1]["pass"], 2)

    def test_final_ac_requires_text_and_explicit_implementation_and_test_citations(self) -> None:
        fingerprint = self.fingerprint()
        valid = _ac("AC-1")
        mechanical = {
            "input_fingerprint": fingerprint,
            "mechanical": {"before_fingerprint": fingerprint, "after_fingerprint": fingerprint, "no_change": True, "evidence": "No mutation."},
        }
        variants = [
            {key: value for key, value in valid.items() if key != "ac_text"},
            {**valid, "ac_text": ""},
            {**valid, "ac_text": "   "},
            {**valid, "ac_text": 1},
            {**valid, "citations": valid["citations"][:1]},
            {**valid, "citations": valid["citations"][1:]},
            {**valid, "citations": [{"file": "app.py", "line": 1}, {"file": "test_app.py", "line": 1}]},
            {**valid, "citations": [{**citation, "role": "source"} for citation in valid["citations"]]},
            {**valid, "citations": [{**citation, "role": ["implementation", "test"]} for citation in valid["citations"]]},
        ]
        for pass_number, verdict in enumerate(variants, start=1):
            with self.subTest(verdict=verdict):
                self.merge([], pass_number=pass_number, scope="final-full", expected_ac_ids=["AC-1"], ac=[verdict])
                result = self.gate("complete", mechanical)
                self.assertEqual(result["next_action"], "certify")
                self.assertIn("AC", result["reason"])
        self.merge([], pass_number=len(variants) + 1, scope="final-full", expected_ac_ids=["AC-1"], ac=[valid])
        self.assertEqual(self.stored()["passes"][-1]["ac_verdicts"], [valid])
        self.assertEqual(self.gate("complete", mechanical)["next_action"], "complete")

    def test_tracked_post_completion_audit_appends_invalidate_certification(self) -> None:
        relative = "specs/GH-1/build.jsonl"
        audit = self.repo / relative
        _write(audit, "{}\n")
        _git(self.repo, "add", relative)
        _git(self.repo, "commit", "-qm", "track review audit")
        fingerprint = self.fingerprint()
        verdicts = [_ac("AC-1")]
        self.merge(
            [],
            scope="final-full",
            expected_ac_ids=["AC-1"],
            ac=verdicts,
            files_reviewed=1,
            file_citations=[{"file": relative, "line": 1}],
        )
        mechanical = {
            "input_fingerprint": fingerprint,
            "mechanical": {"before_fingerprint": fingerprint, "after_fingerprint": fingerprint, "no_change": True, "evidence": "No mutation."},
        }
        self.assertEqual(self.gate("complete", mechanical)["next_action"], "complete")
        for step in ("ac-verification", "session"):
            subprocess.run(
                [
                    "bash",
                    str(self.build / "shared/build-log.sh"),
                    "GH-1",
                    json.dumps(
                        {
                            "skill": "build-review",
                            "story": "GH-1",
                            "step": step,
                            "status": "ok",
                            "data": {"ac_verdicts": verdicts} if step == "ac-verification" else {},
                        }
                    ),
                ],
                cwd=self.repo,
                env={**os.environ, "MAKATO_TARGET_REPO_ROOT": str(self.repo), "MAKATO_SPECS_DIR": str(self.repo / "specs")},
                check=True,
                capture_output=True,
                text=True,
            )
            current = self.gate("review")
            self.assertNotEqual(current["input_fingerprint"], fingerprint)
            self.assertEqual(current["next_action"], "review")
            self.assertIn("changed since latest review", current["reason"])
        self.assertEqual([json.loads(line).get("step") for line in audit.read_text().splitlines()], [None, "ac-verification", "session"])

    def test_successful_delta_or_stale_ac_verdicts_cannot_complete(self) -> None:
        expected = ["AC-1"]
        fingerprint = self.fingerprint()
        self.merge([], expected_ac_ids=expected, input_fingerprint=fingerprint)
        mechanical = {
            "input_fingerprint": fingerprint,
            "mechanical": {"before_fingerprint": fingerprint, "after_fingerprint": fingerprint, "no_change": True, "evidence": "No mutation."},
        }
        self.assertNotEqual(self.gate("complete", mechanical)["next_action"], "complete")

        self.merge([], pass_number=2, scope="delta", expected_ac_ids=expected, input_fingerprint=fingerprint, ac=[_ac("AC-1")])
        self.assertNotEqual(self.gate("complete", mechanical)["next_action"], "complete")

        incomplete_ac = {"ac_id": "AC-1", "verified": True, "evidence": "AC-1 was reviewed.", "citations": []}
        self.merge([], pass_number=3, scope="final-full", expected_ac_ids=expected, input_fingerprint=fingerprint, ac=[incomplete_ac])
        mismatch = self.gate("complete", mechanical)
        self.assertEqual(mismatch["next_action"], "certify")
        self.assertIn("AC", mismatch["reason"])

        self.merge([], pass_number=4, scope="final-full", expected_ac_ids=expected, input_fingerprint=fingerprint, ac=[_ac("AC-1")])
        self.assertEqual(self.gate("complete")["next_action"], "certify")
        _write(self.repo / "app.py", "VALUE = 3  # changed after final review\n")
        changed = self.gate("complete", mechanical)
        self.assertNotEqual(changed["next_action"], "complete")

    def test_final_full_requires_current_file_citations_and_reviewed_file_count(self) -> None:
        for name in ("app.py", "auth.py", "caller.py"):
            _write(self.repo / name, f"# changed {name}\n")
        fingerprint = self.fingerprint()
        expected = ["AC-1"]
        mechanical = {
            "input_fingerprint": fingerprint,
            "mechanical": {
                "before_fingerprint": fingerprint,
                "after_fingerprint": fingerprint,
                "no_change": True,
                "evidence": "The final mechanical checks made no worktree changes.",
            },
        }

        self.merge(
            [],
            scope="final-full",
            expected_ac_ids=expected,
            input_fingerprint=fingerprint,
            files_reviewed=3,
            file_citations=[{"file": "app.py", "line": 1}, {"file": "auth.py", "line": 1}],
            ac=[_ac("AC-1")],
        )
        missing_citation = self.gate("complete", mechanical)
        self.assertEqual(missing_citation["next_action"], "certify")
        self.assertIn("citation", missing_citation["reason"])

        self.merge(
            [],
            pass_number=2,
            scope="final-full",
            expected_ac_ids=expected,
            input_fingerprint=fingerprint,
            files_reviewed=2,
            file_citations=[
                {"file": "app.py", "line": 1},
                {"file": "auth.py", "line": 1},
                {"file": "caller.py", "line": 1},
            ],
            ac=[_ac("AC-1")],
        )
        undercounted = self.gate("complete", mechanical)
        self.assertEqual(undercounted["next_action"], "certify")
        self.assertIn("coverage", undercounted["reason"])

    def test_final_full_requires_each_reviewer_to_cover_the_complete_changed_scope(self) -> None:
        files = ["app.py", "auth.py", "caller.py"]
        for name in files:
            _write(self.repo / name, f"# changed {name}\n")
        fingerprint = self.fingerprint()
        mechanical = {
            "input_fingerprint": fingerprint,
            "mechanical": {"before_fingerprint": fingerprint, "after_fingerprint": fingerprint, "no_change": True, "evidence": "Unchanged full-review inputs."},
        }
        cases = [
            ("zero", 0, []),
            ("count", 2, files),
            ("citations", 100, files[:-1]),
            ("complete", 3, files),
            ("extra-sample", 0, []),
        ]
        for number, (case, count, cited) in enumerate(cases, 1):
            with self.subTest(case=case):
                artifacts = []
                for lens in review_loop.LENSES:
                    incomplete = lens == "security-privacy" and case not in ("complete", "extra-sample")
                    artifacts.append(
                        self.r1_file(
                            _r1(
                                [],
                                lens=lens,
                                input_fingerprint=fingerprint,
                                files_reviewed=count if incomplete else len(files),
                                file_citations=[{"file": path, "line": 1} for path in (cited if incomplete else files)],
                                ac=[_ac("AC-1")] if lens == "contract-ac" else [],
                            )
                        )
                    )
                if case == "extra-sample":
                    artifacts.append(self.r1_file(_r1([], lens="security-privacy", input_fingerprint=fingerprint, files_reviewed=0, file_citations=[])))
                review_loop.merge(
                    self.state,
                    number,
                    "final-full",
                    0,
                    None,
                    artifacts,
                    input_fingerprint=fingerprint,
                    contract_paths=self.contract_paths,
                    contract_root=str(self.build),
                    orchestrate_root=str(self.orch),
                    expected_ac_ids=["AC-1"],
                )
                result = self.gate("complete", mechanical)
                self.assertEqual(result["next_action"], "complete" if case == "complete" else "certify", result)
                if case != "complete":
                    self.assertIn("coverage", result["reason"])
                self.assertEqual(self.stored()["max_repair_round"], 0)
                self.assertEqual(self.stored()["passes"][-1]["ac_verdicts"], [_ac("AC-1")])

    def test_final_full_with_only_one_scoped_lens_cannot_complete(self) -> None:
        fingerprint = self.fingerprint()
        self.merge(
            [],
            scope="final-full",
            expected_ac_ids=["AC-1"],
            input_fingerprint=fingerprint,
            lens="security-privacy",
            ac=[_ac("AC-1")],
        )
        mechanical = {
            "input_fingerprint": fingerprint,
            "mechanical": {
                "before_fingerprint": fingerprint,
                "after_fingerprint": fingerprint,
                "no_change": True,
                "evidence": "The final mechanical checks made no worktree changes.",
            },
        }

        result = self.gate("complete", mechanical)

        self.assertEqual(result["next_action"], "certify")

    def test_partial_versioned_contract_inventory_is_rejected_before_first_bind(self) -> None:
        before = Path(self.state).read_bytes()
        with self.assertRaisesRegex(review_loop.LoopError, "complete versioned"):
            self.merge(
                [],
                scope="final-full",
                expected_ac_ids=["AC-1"],
                contract_paths=["review-contract.md"],
                ac=[_ac("AC-1")],
            )
        self.assertEqual(Path(self.state).read_bytes(), before)
        self.assertEqual(self.stored()["passes"], [])

    def test_stale_expected_ac_ids_and_partial_pass_remain_nonterminal(self) -> None:
        fingerprint = self.fingerprint()
        empty_before = Path(self.state).read_bytes()
        with self.assertRaises(review_loop.LoopError):
            self.merge([], expected_ac_ids=[], input_fingerprint=fingerprint)
        self.assertEqual(Path(self.state).read_bytes(), empty_before)
        self.merge([], expected_ac_ids=["AC-1"], input_fingerprint=fingerprint)
        self.merge([], pass_number=2, scope="final-full", expected_ac_ids=["AC-1"], input_fingerprint=fingerprint, ac=[_ac("AC-1")])
        mechanical = {
            "input_fingerprint": fingerprint,
            "mechanical": {"before_fingerprint": fingerprint, "after_fingerprint": fingerprint, "no_change": True, "evidence": "No mutation."},
        }
        before = Path(self.state).read_bytes()
        with self.assertRaises(review_loop.LoopError):
            self.gate("complete", mechanical, expected_ac_ids=["AC-2"])
        self.assertEqual(Path(self.state).read_bytes(), before)

        self.merge([], pass_number=3, scope="final-full", status="partial", expected_ac_ids=["AC-1"], input_fingerprint=fingerprint, ac=[_ac("AC-1")])
        partial = self.gate("complete", mechanical)
        self.assertNotEqual(partial["next_action"], "complete")

    def test_missing_expected_ac_manifest_cannot_complete_a_clean_final_full_pass(self) -> None:
        fingerprint = self.fingerprint()
        self.merge([], scope="final-full", input_fingerprint=fingerprint, ac=[_ac("AC-1")])
        mechanical = {
            "input_fingerprint": fingerprint,
            "mechanical": {"before_fingerprint": fingerprint, "after_fingerprint": fingerprint, "no_change": True, "evidence": "No mutation."},
        }

        result = self.gate("complete", mechanical)

        self.assertEqual(result["next_action"], "certify")
        self.assertIn("AC", result["reason"])

    def test_gate_evidence_errors_are_persisted_as_blocked_not_clean(self) -> None:
        self.merge([], expected_ac_ids=["AC-1"], ac=[_ac("AC-1")], scope="final-full")
        bad_path = self.dir / "bad-evidence.json"
        bad_path.write_text("{", encoding="utf-8")
        code, out, err = self.cli("gate", "--state", self.state, "--event", "complete", "--worktree", str(self.repo), "--review-base", self.base, "--evidence", str(bad_path))
        self.assertEqual(code, 0)
        result = json.loads(out)
        self.assertEqual(result["next_action"], "blocked")
        self.assertEqual(self.stored()["gate_history"][-1]["next_action"], "blocked")
        self.assertIn("cannot read gate evidence", self.stored()["gate_history"][-1]["reason"])

    def test_corrupt_schema_one_and_base_mismatch_refuse_without_rewriting_state(self) -> None:
        valid_bytes = Path(self.state).read_bytes()
        with self.assertRaises(review_loop.LoopError):
            review_loop.init(self.state, "GH-1", "different-base")
        self.assertEqual(Path(self.state).read_bytes(), valid_bytes)

        legacy = {"version": 1, "story": "GH-1", "review_base": self.base}
        Path(self.state).write_text(json.dumps(legacy), encoding="utf-8")
        legacy_bytes = Path(self.state).read_bytes()
        with self.assertRaisesRegex(review_loop.LoopError, "explicit migration"):
            review_loop.init(self.state, "GH-1", self.base)
        self.assertEqual(Path(self.state).read_bytes(), legacy_bytes)

        Path(self.state).write_text("not valid json", encoding="utf-8")
        corrupt_bytes = Path(self.state).read_bytes()
        with self.assertRaises(review_loop.LoopError):
            review_loop.init(self.state, "GH-1", self.base)
        self.assertEqual(Path(self.state).read_bytes(), corrupt_bytes)

    def test_claim_uses_reserved_confirmation_after_a_fresh_gate_observes_the_actual_repair(self) -> None:
        self.merge([_finding("MAJOR", "app.py", 1, finding_id="raw-1", invariant="bounded writes")])
        self.confirm_open()
        self.assertEqual(self.reserve_local()["next_action"], "repair-local")
        before = self.fingerprint()
        _write(self.repo / "app.py", "VALUE = 3  # repaired\n")
        observed = self.gate("review")["input_fingerprint"]
        self.assertNotEqual(observed, before)
        claimed = review_loop.repaired(self.state, 1, ["F-001"], "coder-1")
        self.assertEqual(claimed["next_action"], "review")
        self.assertEqual(self.stored()["current_fingerprint"], observed)
        self.assertEqual(self.stored()["repair_attempts"][0]["input_fingerprint"], before)

    def test_repair_reservation_is_idempotent_and_restart_cannot_reset_durable_cap(self) -> None:
        self.merge([_finding("MAJOR", "app.py", 1, finding_id="raw-1", invariant="bounded writes")])
        self.confirm_open()
        first = self.reserve_local(soft_cap="1", hard_cap="1")
        resumed = review_loop.init(self.state, "GH-1", self.base)
        second = self.reserve_local(soft_cap="1", hard_cap="1")
        self.assertEqual(first["repair_attempt"], second["repair_attempt"])
        self.assertTrue(resumed["resumed"])
        self.assertEqual(self.stored()["max_repair_round"], 1)
        self.assertEqual(len(self.stored()["repair_attempts"]), 1)

        review_loop.repaired(self.state, 1, ["F-001"], "coder-1")
        duplicate = self.reserve_local(soft_cap="9", hard_cap="20")
        self.assertEqual(duplicate["next_action"], "blocked")
        self.assertEqual(len(self.stored()["repair_attempts"]), 1)
        self.assertEqual(self.stored()["max_repair_round"], 1)
        self.assertIn("hard repair cap", duplicate["reason"])

    def test_manual_repair_local_cannot_bypass_soft_cap_nonconvergence(self) -> None:
        first = _finding("MAJOR", "app.py", 1, finding_id="raw-a", invariant="persisted invariant A")
        self.merge([first])
        self.confirm_open()
        self.reserve_local(soft_cap="1", hard_cap="8")
        review_loop.repaired(self.state, 1, ["F-001"], "coder-1")
        new = _finding("MAJOR", "app.py", 1, finding_id="raw-b", invariant="persisted invariant B")
        self.merge([first, new], pass_number=2, scope="delta", after_round=1)
        self.confirm_open()

        attempts = len(self.stored()["repair_attempts"])
        forced = self.reserve_local(soft_cap="1", hard_cap="8")
        self.assertNotEqual(forced["next_action"], "repair-local")
        self.assertEqual(len(self.stored()["repair_attempts"]), attempts)

    def test_gate_is_mandatory_at_every_transition_and_checkpoint_is_not_final(self) -> None:
        _write(self.repo / "specs/GH-1/build.jsonl", "{}\n")
        _write(self.repo / "specs/GH-1/plan-1.md", "Reviewed task checkpoint plan\n")
        fingerprint = self.fingerprint()
        paths = review_scope.changed_files(str(self.repo), self.base)
        paths += [name if name.startswith("orchestrate:") else "contract:" + name for name in self.contract_paths]
        self.merge([], pass_number=1, scope="delta", input_fingerprint=fingerprint, files_reviewed=len(paths), file_citations=[{"file": path, "line": 1} for path in paths])
        checkpoint_path = self.dir / "checkpoint.json"
        checkpoint_path.write_text(
            json.dumps(
                {
                    "task_ids": ["T-1", "T-2"],
                    "input_fingerprint": fingerprint,
                    "pass_id": "P-1",
                    "scope": "delta",
                    "checkpoint_verified": True,
                    "final_review": False,
                    "reviewer_id": "checkpoint-reviewer",
                    "independent": True,
                    "dispositions": [],
                    "evidence": "Completed tasks were reviewed against the current delta.",
                    "citations": [{"file": "app.py", "line": 1}],
                }
            ),
            encoding="utf-8",
        )
        code, out, err = self.cli(
            "gate",
            "--state",
            self.state,
            "--event",
            "checkpoint",
            "--worktree",
            str(self.repo),
            "--review-base",
            self.base,
            "--evidence",
            str(checkpoint_path),
        )
        self.assertEqual((code, err), (0, ""))
        checkpoint = json.loads(out)
        self.assertEqual(checkpoint["next_action"], "review")
        self.assertFalse(checkpoint["checkpoint_receipt"]["final_review"])
        review_loop.publish_audit(self.state, str(self.repo), self.base)

        code, out, err = self.cli(
            "checkpoint-receipt",
            "--state",
            self.state,
            "--task-ids",
            "T-1,T-2",
            "--fingerprint",
            fingerprint,
            "--pass-id",
            "P-1",
            "--worktree",
            str(self.repo),
            "--review-base",
            self.base,
        )
        self.assertEqual((code, err), (0, ""))
        receipt = json.loads(out)
        self.assertEqual(receipt["task_ids"], ["T-1", "T-2"])
        self.assertFalse(receipt["final_review"])
        self.assertEqual(receipt["checkpoint_verified"], True)

        _write(self.repo / "new-untracked.py", "VALUE = 2\n")
        stale_code, stale_out, stale_err = self.cli(
            "checkpoint-receipt",
            "--state",
            self.state,
            "--task-ids",
            "T-1,T-2",
            "--fingerprint",
            fingerprint,
            "--pass-id",
            "P-1",
            "--worktree",
            str(self.repo),
            "--review-base",
            self.base,
        )
        self.assertEqual((stale_code, stale_out), (2, ""))
        self.assertIn("stale", stale_err)


class ActiveBindingTests(LoopTestCase):
    def test_first_binding_is_explicit_atomic_and_requires_full_closure_even_with_exports(self) -> None:
        original = Path(self.state).read_bytes()
        env = {"MAKATO_BUILD_ROOT": str(self.build), "MAKATO_ORCHESTRATE_ROOT": str(self.orch)}
        for omitted in ("contract_root", "orchestrate_root"):
            roots = {"contract_root": str(self.build), "orchestrate_root": str(self.orch)}
            roots.pop(omitted)
            with self.subTest(omitted=omitted), patch.dict(os.environ, env):
                with self.assertRaisesRegex(review_loop.LoopError, "explicit"):
                    review_loop.gate(self.state, "initial", str(self.repo), self.base, contract_paths=self.contract_paths, **roots)
                with self.assertRaisesRegex(review_loop.LoopError, "explicit"):
                    review_loop.merge(self.state, 1, "full", 0, None, [self.r1_file(_r1([], input_fingerprint=self.fingerprint()))], contract_paths=self.contract_paths, **roots)
                self.assertEqual(Path(self.state).read_bytes(), original)
        self.gate("initial")
        stored = self.stored()
        self.assertEqual(stored["root_bindings"], review_scope.root_bindings(self.build, self.orch))
        self.assertEqual(stored["contract_root"], str(self.build))
        self.assertEqual(stored["orchestrate_root"], str(self.orch))

    def test_all_state_commands_reject_the_wrong_executing_install_before_mutation(self) -> None:
        self.gate("initial")
        original = Path(self.state).read_bytes()
        wrong = self.dir / "wrong-executing-build"
        shutil.copytree(self.build, wrong)
        commands = [
            lambda: review_loop.init(self.state, "GH-1", self.base),
            lambda: review_loop.gate(self.state, "initial", str(self.repo), self.base),
            lambda: review_loop.merge(self.state, 1, "full", 0, None, []),
            lambda: review_loop.repaired(self.state, 1, ["F-001"], "coder"),
            lambda: review_loop.background(self.state, 1, "delta"),
            lambda: review_loop.publish_audit(self.state, str(self.repo), self.base),
            lambda: review_loop.operational_log(self.state, str(self.repo), {"step": "r1"}),
            lambda: review_loop.checkpoint_receipt(self.state, ["1"], "a" * 64, "P-1", str(self.repo), self.base),
            lambda: review_loop.verify_binding(self.state, str(self.repo), str(self.build), str(self.orch)),
        ]
        with patch.object(review_loop, "__file__", str(wrong / "shared/review_loop.py")):
            for command in commands:
                with self.subTest(command=command), self.assertRaises(review_loop.LoopError):
                    command()
                self.assertEqual(Path(self.state).read_bytes(), original)
        self.assertFalse((self.repo / ".git/makato-review-loop").exists())

    def test_identical_roots_cannot_be_switched_or_replaced(self) -> None:
        self.gate("initial")
        original = Path(self.state).read_bytes()
        for name, selected in (("contract_root", self.build), ("orchestrate_root", self.orch)):
            replacement = self.dir / (selected.name + "-copy")
            shutil.copytree(selected, replacement)
            with self.subTest(root=name), self.assertRaises(review_loop.LoopError):
                self.gate("review", **{name: str(replacement)})
            retired = selected.with_name(selected.name + "-retired")
            selected.rename(retired)
            shutil.copytree(retired, selected)
            try:
                with self.assertRaisesRegex(review_loop.LoopError, "bindings"):
                    review_loop.background(self.state, 1, "delta")
                self.assertEqual(Path(self.state).read_bytes(), original)
            finally:
                shutil.rmtree(selected)
                retired.rename(selected)

    def test_ledger_rejects_old_schema_missing_or_malformed_root_triples(self) -> None:
        self.gate("initial")
        valid = self.stored()
        invalid = []
        old = copy.deepcopy(valid)
        old["version"] = 2
        invalid.append(old)
        for field in ("orchestrate_root", "root_bindings"):
            missing = copy.deepcopy(valid)
            missing.pop(field)
            invalid.append(missing)
        for change in (
            {"root_bindings": None},
            {"orchestrate_root": None},
            {"root_bindings": {"build": valid["root_bindings"]["build"]}},
            {"root_bindings": {**valid["root_bindings"], "extra": {}}},
            {"root_bindings": {**valid["root_bindings"], "build": {**valid["root_bindings"]["build"], "dev": True}}},
            {"root_bindings": {**valid["root_bindings"], "orchestrate": {**valid["root_bindings"]["orchestrate"], "path": str(self.build)}}},
        ):
            invalid.append({**valid, **change})
        for index, state in enumerate(invalid):
            Path(self.state).write_text(json.dumps(state))
            before = Path(self.state).read_bytes()
            with self.subTest(index=index), self.assertRaises(review_loop.LoopError):
                review_loop.init(self.state, "GH-1", self.base)
            self.assertEqual(Path(self.state).read_bytes(), before)

    def test_verify_binding_and_contract_paths_cli_are_read_only_and_fail_closed(self) -> None:
        self.gate("initial")
        before = Path(self.state).read_bytes()
        code, out, err = self.cli("contract-paths")
        self.assertEqual((code, err), (0, ""))
        self.assertEqual(json.loads(out), list(review_scope.REVIEW_CONTRACT_PATHS))
        args = ("verify-binding", "--state", self.state, "--worktree", str(self.repo), "--build-root", str(self.build), "--orchestrate-root", str(self.orch))
        code, out, err = self.cli(*args)
        self.assertEqual((code, err), (0, ""))
        self.assertEqual(json.loads(out)["root_bindings"], self.stored()["root_bindings"])
        with patch.dict(os.environ, {"MAKATO_ORCHESTRATE_SHARED": str(self.build / "shared")}):
            self.assertEqual(self.cli(*args)[0], 2)
        self.assertEqual(self.cli(*args[:-1], str(self.build))[0], 2)
        self.assertEqual(Path(self.state).read_bytes(), before)
        self.assertFalse((self.repo / ".git/makato-review-loop").exists())

    def test_sampling_is_off_without_bound_state_and_with_mismatched_explicit_roots(self) -> None:
        arguments = {"profile": "deep", "qualification": "q.json", "config_fingerprint": "a" * 64, "model": "pinned", "settings": {}}
        for state in (None, self.state, str(self.dir / "missing.json")):
            with self.subTest(state=state), patch.object(review_loop.review_eval, "verify_qualification") as verify:
                result = review_loop.lenses(str(self.repo), self.base, "on", state=state, **arguments)
                self.assertFalse(result["sampling_enabled"])
                self.assertIn("sampling_warning", result)
                self.assertEqual(result["sample_counts"], dict.fromkeys(review_loop.LENSES, 1))
                verify.assert_not_called()
        self.gate("initial")
        with patch.object(review_loop.review_eval, "verify_qualification") as verify:
            result = review_loop.lenses(str(self.repo), self.base, "on", state=self.state, orchestrate_root=str(self.build), **arguments)
            self.assertFalse(result["sampling_enabled"])
            self.assertIn("sampling_warning", result)
            verify.assert_not_called()


class LensQualificationTests(LoopTestCase):
    def qualified_sampling(self) -> tuple[dict, Path]:
        from test_review_eval import MODEL, SETTINGS, _make_corpus, _save_report

        self.gate("initial")
        corpus = _make_corpus(self.dir / "policy", source_root=self.build, orchestrate_root=self.orch)
        report = _save_report(corpus)
        return {
            "qualification": str(report),
            "config_fingerprint": corpus["config"]["fingerprint"],
            "model": MODEL,
            "settings": SETTINGS,
            "state": self.state,
            "profile": "deep",
        }, report

    def test_deep_sampling_qualification_is_verified_and_limited_to_eligible_passes(self) -> None:
        arguments, _ = self.qualified_sampling()
        for pass_kind in ("initial", "first-rereview"):
            with self.subTest(pass_kind=pass_kind):
                qualified = review_loop.lenses(str(self.repo), self.base, "on", pass_kind=pass_kind, **arguments)
                self.assertTrue(qualified["sampling_enabled"], qualified.get("sampling_warning"))
                self.assertEqual(qualified["sample_counts"]["error-handling"], 2)
                self.assertEqual(qualified["sample_counts"]["state-concurrency"], 2)
        off = review_loop.lenses(str(self.repo), self.base, "off", **arguments)
        self.assertFalse(off["split"])
        self.assertEqual(off["lenses"], [])
        self.assertFalse(off["sampling_enabled"])
        self.assertEqual(off["sample_counts"], dict.fromkeys(review_loop.LENSES, 1))
        later = review_loop.lenses(str(self.repo), self.base, "on", pass_kind="later", **arguments)
        self.assertFalse(later["sampling_enabled"])
        self.assertEqual(later["sample_counts"], dict.fromkeys(review_loop.LENSES, 1))

    def test_bound_sampling_rejects_stale_report_and_active_helpers_but_ignores_decoy(self) -> None:
        arguments, report = self.qualified_sampling()
        decoy = self.dir / "inactive/makato-orchestrate"
        shutil.copytree(self.orch, decoy)
        _write(decoy / "shared/progress-comment.sh", "inactive helper change\n")
        self.assertTrue(review_loop.lenses(str(self.repo), self.base, "on", **arguments)["sampling_enabled"])
        for argument in ("shared/build-log.sh", "shared/review_scope.py", "orchestrate:shared/progress-comment.sh"):
            _, relative, selected = review_scope.contract_input(argument, self.build, self.orch)
            target = selected / relative
            before = target.read_bytes()
            target.write_bytes(before + b"\n# stale active helper\n")
            with self.subTest(argument=argument):
                rejected = review_loop.lenses(str(self.repo), self.base, "on", **arguments)
                self.assertFalse(rejected["sampling_enabled"])
                self.assertIn("sampling_warning", rejected)
                self.assertEqual(rejected["sample_counts"], dict.fromkeys(review_loop.LENSES, 1))
            target.write_bytes(before)
        original_report = report.read_bytes()
        forged = json.loads(original_report)
        forged["quality_pass"] = False
        report.write_text(json.dumps(forged))
        rejected = review_loop.lenses(str(self.repo), self.base, "on", **arguments)
        self.assertFalse(rejected["sampling_enabled"])
        self.assertIn("recomputed raw evidence", rejected["sampling_warning"])
        report.write_bytes(original_report)
        mode_target = self.orch / "shared/progress-comment.sh"
        before_mode = mode_target.stat().st_mode
        mode_target.chmod(before_mode ^ 0o100)
        self.assertFalse(review_loop.lenses(str(self.repo), self.base, "on", **arguments)["sampling_enabled"])
        mode_target.chmod(before_mode)
        saved = self.orch.with_name("original-orchestrate")
        self.orch.rename(saved)
        shutil.copytree(saved, self.orch)
        rejected = review_loop.lenses(str(self.repo), self.base, "on", **arguments)
        self.assertFalse(rejected["sampling_enabled"])
        self.assertIn("sampling_warning", rejected)
        self.assertEqual(rejected["sample_counts"], dict.fromkeys(review_loop.LENSES, 1))

    def test_standard_profile_and_unqualified_deep_profile_do_not_sample_twice(self) -> None:
        standard = review_loop.lenses(str(self.repo), self.base, "on", profile="standard")
        deep = review_loop.lenses(str(self.repo), self.base, "on", profile="deep", pass_kind="first-rereview")
        self.assertFalse(standard["sampling_enabled"])
        self.assertFalse(deep["sampling_enabled"])
        self.assertEqual(deep["sample_counts"]["state-concurrency"], 1)


class BackgroundReviewTests(LoopTestCase):
    def test_background_full_review_repeats_only_when_it_adds_new_blockers(self) -> None:
        self.assertFalse(review_loop.background(self.state, 1, "delta")["run"])
        self.assertFalse(review_loop.background(self.state, 3, "full")["run"])
        self.assertTrue(review_loop.background(self.state, 2, "delta")["run"])

        blocker = _finding("MAJOR", "app.py", 1, finding_id="raw-a", invariant="one writer per record")
        self.merge([blocker], pass_number=1, scope="background-full", after_round=1)
        self.assertTrue(review_loop.background(self.state, 2, "delta")["run"])
        self.merge([blocker], pass_number=2, scope="background-full", after_round=2)
        self.assertFalse(review_loop.background(self.state, 3, "delta")["run"])


class AuditPublicationTests(LoopTestCase):
    def setUp(self) -> None:
        super().setUp()
        self.audit = self.repo / "specs/GH-1/build.jsonl"
        _write(self.audit, "{}\n")
        _write(self.repo / "specs/GH-1/plan.md", "Reviewed plan\n")
        _write(self.repo / "specs/GH-1/plan-1.md", "Issue 1 plan\n")
        _git(self.repo, "add", "specs")
        _git(self.repo, "commit", "-qm", "track audit and plan")
        _write(self.repo / "app.py", "VALUE = 2\n")

    def certify(self, *, final: bool = True, **bindings: object) -> dict:
        contexts = sorted(set(self.stored()["context_paths"]) | {"specs/GH-1/plan.md"})
        current = self.gate("review", context_paths=contexts, contract_paths=self.contract_paths, contract_root=str(self.build), orchestrate_root=str(self.orch), **bindings)["input_fingerprint"]
        paths = review_scope.changed_files(str(self.repo), self.base)
        if not final:
            paths.append("test_app.py")
            paths += ["context:" + path for path in contexts]
            paths += [name if name.startswith("orchestrate:") else "contract:" + name for name in self.contract_paths]
        number = len(self.stored()["passes"]) + 1
        self.merge(
            [],
            pass_number=number,
            scope="final-full" if final else "delta",
            input_fingerprint=current,
            expected_ac_ids=["AC-1"],
            ac=[_ac("AC-1")] if final else [],
            files_reviewed=len(paths),
            file_citations=[{"file": name, "line": 1} for name in paths],
        )
        if final:
            evidence = {"input_fingerprint": current, "mechanical": {"before_fingerprint": current, "after_fingerprint": current, "no_change": True, "evidence": "Unchanged reviewed inputs."}}
            result = self.gate("complete", evidence)
            self.assertEqual(result["next_action"], "complete")
        else:
            result = self.gate(
                "checkpoint",
                {
                    "input_fingerprint": current,
                    "pass_id": f"P-{number}",
                    "scope": "delta",
                    "task_ids": ["1"],
                    "checkpoint_verified": True,
                    "final_review": False,
                    "reviewer_id": "checkpoint-verifier",
                    "independent": True,
                    "dispositions": [],
                    "evidence": "Independent task review.",
                    "citations": [{"file": "app.py", "line": 1}],
                },
            )
            self.assertIn("checkpoint_receipt", result)
        return result

    def publish(self) -> dict:
        return review_loop.publish_audit(self.state, str(self.repo), self.base)

    def test_unbound_generic_checkpoint_publication_keeps_no_durable_root_authority(self) -> None:
        current = review_loop.gate(self.state, "initial", str(self.repo), self.base)["current_fingerprint"]
        paths = review_scope.changed_files(str(self.repo), self.base)
        paths.append("test_app.py")
        envelope = _r1([], input_fingerprint=current, files_reviewed=len(paths), file_citations=[{"file": path, "line": 1} for path in paths])
        review_loop.merge(self.state, 1, "delta", 0, None, [self.r1_file(envelope)], input_fingerprint=current)
        evidence = {
            "input_fingerprint": current,
            "pass_id": "P-1",
            "scope": "delta",
            "task_ids": ["1"],
            "checkpoint_verified": True,
            "final_review": False,
            "reviewer_id": "generic-verifier",
            "independent": True,
            "dispositions": [],
            "evidence": "Independent generic checkpoint.",
            "citations": [{"file": "app.py", "line": 1}],
        }
        evidence_path = self.dir / "generic-checkpoint.json"
        evidence_path.write_text(json.dumps(evidence))
        result = review_loop.gate(self.state, "checkpoint", str(self.repo), self.base, str(evidence_path))
        self.assertIn("checkpoint_receipt", result)
        delivered = self.publish()
        receipt = review_loop.checkpoint_receipt(self.state, ["1"], current, "P-1", str(self.repo), self.base)
        self.assertEqual(receipt, delivered["checkpoint_receipt"])
        review_loop.operational_log(self.state, str(self.repo), {"step": "generic"})
        review_loop.background(self.state, 1, "delta")
        review_loop.init(self.state, "GH-1", self.base)
        self.assertNotEqual(review_loop.gate(self.state, "complete", str(self.repo), self.base)["next_action"], "complete")
        state = self.stored()
        self.assertTrue(all(state[field] is None for field in ("contract_root", "orchestrate_root", "root_bindings")))
        with self.assertRaises(review_loop.LoopError):
            review_loop.verify_binding(self.state, str(self.repo), str(self.build), str(self.orch))

    def test_orchestrate_audit_alias_is_never_authorized_for_publication(self) -> None:
        alias = self.orch / "audit-alias.jsonl"
        os.link(self.audit, alias)
        self.contract_paths.append("orchestrate:" + alias.name)
        self.certify()
        before = self.audit.read_bytes()
        with self.assertRaisesRegex(review_loop.LoopError, "aliases"):
            self.publish()
        self.assertEqual(alias.read_bytes(), before)
        self.assertEqual(self.audit.read_bytes(), before)

    def test_orchestrate_operational_alias_and_unknown_manifest_source_fail_as_audit_errors(self) -> None:
        operational = self.operation_path()
        _write(operational, "{}\n")
        alias = self.orch / "operational-alias.jsonl"
        os.link(operational, alias)
        self.contract_paths.append("orchestrate:" + alias.name)
        self.gate("initial")
        with self.assertRaisesRegex(review_loop.LoopError, "protected"):
            review_loop.operational_log(self.state, str(self.repo), {"step": "r1"})
        self.assertEqual(operational.read_bytes(), b"{}\n")
        unknown = {"manifest": {"files": [{"path": "unknown:input", "contract": False}]}}
        with patch.object(review_loop.review_audit, "fingerprint", return_value=unknown):
            with self.assertRaisesRegex(review_loop.LoopError, "unknown"):
                review_loop.operational_log(self.state, str(self.repo), {"step": "r1"})

    def test_unpublished_checkpoint_receipt_is_not_deliverable(self) -> None:
        receipt = self.certify(final=False)["checkpoint_receipt"]
        with self.assertRaisesRegex(review_loop.LoopError, "published"):
            review_loop.checkpoint_receipt(self.state, ["1"], receipt["input_fingerprint"], receipt["pass_id"], str(self.repo), self.base)

    def operation_path(self) -> Path:
        return self.repo / ".git/makato-review-loop" / self.stored()["run_id"] / "operations.jsonl"

    def log_operation(self, entry: dict) -> subprocess.CompletedProcess:
        return subprocess.run(
            ["bash", str(self.build / "shared/build-log.sh"), "GH-1", json.dumps(entry)],
            cwd=self.repo,
            env={**os.environ, "MAKATO_REVIEW_LEDGER_STATE": self.state, "WORKTREE_PATH": str(self.repo)},
            capture_output=True,
            text=True,
            check=False,
        )

    def test_result_operational_logging_does_not_append_to_published_canonical_audit(self) -> None:
        self.certify()
        published = self.publish()
        canonical = self.audit.read_bytes()
        entry = {"skill": "build-review", "step": "r1", "status": "success", "data": {"result": published}}
        logged = self.log_operation(entry)
        self.assertEqual(logged.returncode, 0, logged.stderr)
        self.assertEqual(self.audit.read_bytes(), canonical)
        self.assertEqual(json.loads(self.operation_path().read_text()), entry)
        self.assertEqual(self.gate("review")["audit_transition"], published["audit_transition"])

    def test_operational_log_explicit_context_and_contract_aliases_are_not_exempt(self) -> None:
        operational = self.operation_path()
        _write(operational, "{}\n")
        alias = self.build / "operational-contract.jsonl"
        os.link(operational, alias)
        relative = operational.relative_to(self.repo).as_posix()
        self.gate("review", context_paths=[relative], contract_paths=[*self.contract_paths, alias.name])
        canonical = self.audit.read_bytes()
        rejected = self.log_operation({"step": "r1"})
        self.assertNotEqual(rejected.returncode, 0)
        self.assertIn("protected", rejected.stderr)
        self.assertEqual(operational.read_text(), "{}\n")
        self.assertEqual(self.audit.read_bytes(), canonical)

    def test_operational_log_cannot_follow_a_symlink_into_protected_source(self) -> None:
        operational = self.operation_path()
        operational.parent.mkdir(parents=True)
        operational.symlink_to(self.repo / "app.py")
        source = (self.repo / "app.py").read_bytes()
        rejected = self.log_operation({"step": "r1"})
        self.assertNotEqual(rejected.returncode, 0)
        self.assertEqual((self.repo / "app.py").read_bytes(), source)

    def test_final_publication_preserves_source_certificate_and_verbatim_verdicts(self) -> None:
        original = self.certify()
        before = self.stored()
        prefix = self.audit.read_bytes()
        delivered = self.publish()
        self.assertNotEqual(delivered["input_fingerprint"], delivered["delivery_fingerprint"])
        self.assertEqual(delivered["input_fingerprint"], original["input_fingerprint"])
        self.assertEqual(delivered["delivery_fingerprint"], self.gate("review")["current_fingerprint"])
        self.assertEqual(self.gate("review")["next_action"], "complete")
        for field in ("passes", "mechanical_evidence", "checkpoint_receipts", "findings"):
            self.assertEqual(self.stored()[field], before[field])
        rows = [json.loads(line) for line in self.audit.read_bytes()[len(prefix) :].splitlines()]
        self.assertEqual([row["step"] for row in rows], ["ac-verification", "session"])
        self.assertEqual(rows[0]["data"]["ac_verdicts"], before["passes"][-1]["ac_verdicts"])
        for row in rows:
            self.assertEqual(row["data"]["run_id"], before["run_id"])
            self.assertEqual(row["data"]["pass_id"], "P-1")
            self.assertEqual(row["story"], "GH-1")
        audit_bytes = self.audit.read_bytes()
        self.assertEqual(self.publish(), delivered)
        code, output, errors = self.cli("publish-audit", "--state", self.state, "--worktree", str(self.repo), "--review-base", self.base)
        self.assertEqual((code, errors), (0, ""))
        self.assertEqual(json.loads(output), delivered)
        self.assertEqual(self.audit.read_bytes(), audit_bytes)

    def test_final_publication_and_reuse_recheck_each_raw_reviewer_not_merged_coverage(self) -> None:
        self.certify()
        complete = self.stored()
        for phase in ("publication", "reuse"):
            with self.subTest(phase=phase):
                if phase == "reuse":
                    review_loop._save_state(self.state, complete)
                    self.publish()
                valid = self.stored()
                damaged = copy.deepcopy(valid)
                envelope = damaged["raw_envelopes"][-1]["envelope"]["data"]
                envelope.update(files_reviewed=0, file_citations=[])
                review_loop._save_state(self.state, damaged)
                prefix = self.audit.read_bytes()
                try:
                    with self.assertRaisesRegex(review_loop.LoopError, "final-full"):
                        self.publish()
                    self.assertEqual(self.audit.read_bytes(), prefix)
                    self.assertNotEqual(self.gate("review")["next_action"], "complete")
                finally:
                    self.audit.write_bytes(prefix)
                    review_loop._save_state(self.state, valid)

    def test_retained_r1_contract_and_derived_summary_revalidate_every_certificate_boundary(self) -> None:
        mutations = [
            (("raw_envelopes", 0, "envelope", "data", "file_citations", 0, "line"), 0),
            (("raw_envelopes", 0, "envelope", "schema"), "not-r1"),
            (("raw_envelopes", 0, "envelope", "summary"), ""),
            (("raw_envelopes", 0, "envelope", "files_changed"), ["app.py"]),
            (("raw_envelopes", 0, "envelope", "data", "major_count"), 1),
            (("raw_envelopes", 0, "envelope", "data", "reviewer_id"), ""),
            (("raw_envelopes", 0, "envelope", "status"), "partial"),
            (("raw_envelopes", 0, "envelope", "data", "input_fingerprint"), "f" * 64),
            (("raw_envelopes", 0, "run_id"), "other-run"),
            (("raw_envelopes", 0, "pass_id"), "P-99"),
            (("raw_envelopes", 0, "repair_round"), 99),
            (("raw_envelopes", 0, "input_fingerprint"), "f" * 64),
            (("raw_envelopes", 0, "lens"), "security"),
            (("passes", 0, "files_reviewed"), 999),
            (("passes", 0, "ac_verdicts"), [_ac("AC-1", line=2)]),
        ]
        initial = self.stored()
        prefix = self.audit.read_bytes()

        def rejected(call) -> None:
            try:
                result = call()
            except review_loop.LoopError:
                return
            self.assertNotEqual(result.get("next_action"), "complete", result)
            self.assertNotIn("checkpoint_receipt", result)
            self.assertNotIn("audit_transition", result)

        for final in (True, False):
            review_loop._save_state(self.state, initial)
            self.audit.write_bytes(prefix)
            source = self.certify(final=final)
            certified = self.stored()
            for published in (False, True):
                review_loop._save_state(self.state, certified)
                self.audit.write_bytes(prefix)
                if published:
                    self.publish()
                valid = self.stored()
                audit_bytes = self.audit.read_bytes()
                for path, value in mutations:
                    with self.subTest(final=final, published=published, mutation=path):
                        damaged = copy.deepcopy(valid)
                        target = damaged
                        for key in path[:-1]:
                            target = target[key]
                        target[path[-1]] = value
                        review_loop._save_state(self.state, damaged)
                        rejected(lambda: self.gate("review"))
                        with self.assertRaises(review_loop.LoopError):
                            self.publish()
                        if not final and published:
                            receipt = source["checkpoint_receipt"]
                            with self.assertRaises(review_loop.LoopError):
                                review_loop.checkpoint_receipt(self.state, ["1"], receipt["input_fingerprint"], receipt["pass_id"], str(self.repo), self.base)
                        self.assertEqual(self.audit.read_bytes(), audit_bytes)

    def test_previously_unchanged_audit_membership_is_the_only_new_coverage_entry(self) -> None:
        self.base = _git(self.repo, "rev-parse", "HEAD")
        self.state = str(self.dir / "clean-audit-ledger.json")
        review_loop.init(self.state, "GH-1", self.base)
        self.certify()
        self.assertNotIn("specs/GH-1/build.jsonl", self.stored()["current_changed_files"])
        self.publish()
        self.assertEqual(self.gate("review")["next_action"], "complete")
        self.assertIn("specs/GH-1/build.jsonl", review_scope.changed_files(str(self.repo), self.base))

    def test_checkpoint_delivery_retains_source_snapshot_and_later_review_uses_current_anchor(self) -> None:
        source = self.certify(final=False)["checkpoint_receipt"]
        delivered = self.publish()
        receipt = delivered["checkpoint_receipt"]
        for key, value in source.items():
            self.assertEqual(receipt[key], value)
        self.assertNotEqual(receipt["input_fingerprint"], receipt["delivery_fingerprint"])
        self.assertEqual(review_loop.checkpoint_receipt(self.state, ["1"], source["input_fingerprint"], source["pass_id"], str(self.repo), self.base), receipt)
        self.assertEqual([json.loads(line).get("step") for line in self.audit.read_text().splitlines()], [None, "session"])
        live = self.gate("review")
        self.assertEqual(live["input_fingerprint"], delivered["delivery_fingerprint"])
        final = self.certify()
        self.assertEqual(final["input_fingerprint"], delivered["delivery_fingerprint"])
        final_delivery = self.publish()
        self.assertTrue(final_delivery["final_review"])
        with self.assertRaises(review_loop.LoopError):
            review_loop.checkpoint_receipt(self.state, ["1"], source["input_fingerprint"], source["pass_id"], str(self.repo), self.base)

    def test_mixed_source_untracked_context_and_contract_changes_reject_publication_and_reuse(self) -> None:
        self.certify()
        targets = [
            self.repo / "app.py",
            self.repo / "new.py",
            self.repo / "specs/GH-1/plan.md",
            self.build / "review-contract.md",
            self.build / "shared/build-log.sh",
            self.build / "shared/review_scope.py",
            self.orch / "shared/progress-comment.sh",
            self.orch / "scripts/task_schedule.py",
        ]
        for phase in ("before", "after"):
            if phase == "after":
                self.publish()
            for target in targets:
                with self.subTest(phase=phase, path=target.name):
                    prior = target.read_bytes() if target.exists() else None
                    target.write_bytes((prior or b"") + b"# mutation\n")
                    with self.assertRaises(review_loop.LoopError):
                        self.publish()
                    self.assertNotEqual(self.gate("review")["next_action"], "complete")
                    if prior is None:
                        target.unlink()
                    else:
                        target.write_bytes(prior)

    def test_prefix_truncation_rewrites_and_malformed_unrelated_excess_tails_fail_closed(self) -> None:
        self.certify()
        self.publish()
        valid = self.audit.read_bytes()
        for damaged in (b"", b"[]\n" + valid[3:], valid + b"not-json\n", valid + b"{}\n", valid[:-1]):
            with self.subTest(damaged=damaged[-20:]):
                self.audit.write_bytes(damaged)
                with self.assertRaises(review_loop.LoopError):
                    self.publish()
                self.assertNotEqual(self.gate("review")["next_action"], "complete")
                self.audit.write_bytes(valid)

    def test_path_inode_mode_and_symlink_substitutions_are_rejected(self) -> None:
        self.certify()
        self.publish()
        saved = self.audit.with_name("saved")
        self.audit.rename(saved)
        for symlink in (False, True):
            with self.subTest(symlink=symlink):
                if symlink:
                    self.audit.symlink_to(saved)
                else:
                    self.audit.write_bytes(saved.read_bytes())
                with self.assertRaises(review_loop.LoopError):
                    self.publish()
                self.assertNotEqual(self.gate("review")["next_action"], "complete")
                self.audit.unlink()
        saved.rename(self.audit)
        mode = self.audit.stat().st_mode & 0o777
        self.audit.chmod(mode ^ 0o100)
        with self.assertRaises(review_loop.LoopError):
            self.publish()
        self.audit.chmod(mode)
        folder = self.audit.parent
        relocated = folder.with_name("relocated")
        folder.rename(relocated)
        folder.symlink_to(relocated, target_is_directory=True)
        with self.assertRaises(review_loop.LoopError):
            self.publish()
        folder.unlink()
        relocated.rename(folder)

    def test_hardlinked_canonical_audit_rejects_before_any_collateral_append(self) -> None:
        alias = self.repo / "protected-data.json"
        os.link(self.audit, alias)
        self.certify()
        before = self.audit.read_bytes()
        with self.assertRaises(review_loop.LoopError):
            self.publish()
        self.assertEqual(self.audit.read_bytes(), before)
        self.assertEqual(alias.read_bytes(), before)

    def test_hardlink_added_after_source_capture_rejects_before_any_append(self) -> None:
        self.certify()
        alias = self.dir / "protected-data.json"
        os.link(self.audit, alias)
        before = self.audit.read_bytes()
        with self.assertRaises(review_loop.LoopError):
            self.publish()
        self.assertEqual(self.audit.read_bytes(), before)
        self.assertEqual(alias.read_bytes(), before)

    def test_hardlink_added_while_persisting_intent_rejects_before_any_append(self) -> None:
        self.certify()
        alias = self.repo / "protected-data.json"
        before = self.audit.read_bytes()
        save = review_loop._save_state

        def link_after_intent(path: str, state: dict) -> None:
            save(path, state)
            if any("intent" in cert for cert in state.get("audit_certificates", [])):
                os.link(self.audit, alias)

        with patch.object(review_loop, "_save_state", side_effect=link_after_intent):
            with self.assertRaises(review_loop.LoopError):
                self.publish()
        self.assertEqual(self.audit.read_bytes(), before)
        self.assertEqual(alias.read_bytes(), before)

    def test_either_root_replaced_while_persisting_intent_blocks_before_append(self) -> None:
        self.certify()
        prefix = self.audit.read_bytes()
        save = review_loop._save_state
        for selected in (self.build, self.orch):
            retired = selected.with_name(selected.name + "-retired")
            replaced = False

            def replace_after_intent(path: str, state: dict) -> None:
                nonlocal replaced
                save(path, state)
                if not replaced and any("intent" in cert for cert in state.get("audit_certificates", [])):
                    selected.rename(retired)
                    shutil.copytree(retired, selected)
                    replaced = True

            try:
                with self.subTest(root=selected), patch.object(review_loop, "_save_state", side_effect=replace_after_intent):
                    with self.assertRaisesRegex(review_loop.LoopError, "bindings"):
                        self.publish()
                self.assertEqual(self.audit.read_bytes(), prefix)
            finally:
                if replaced:
                    shutil.rmtree(selected)
                    retired.rename(selected)
                # Re-exercise the pre-append intent boundary independently for the other root.
                state = self.stored()
                state["audit_certificates"][-1].pop("intent", None)
                save(self.state, state)

    def test_explicit_audit_context_or_cross_root_contract_alias_never_gets_exemption(self) -> None:
        alias_root = self.build
        os.link(self.audit, alias_root / "alias.txt")
        self.gate("review", context_paths=["specs/GH-1/build.jsonl"], contract_paths=self.contract_paths)
        self.certify()
        with self.assertRaisesRegex(review_loop.LoopError, "aliases"):
            self.publish()
        # A fresh ledger binds an explicit contract alias in a different root.
        self.state = str(self.dir / "aliased-ledger.json")
        review_loop.init(self.state, "GH-1", self.base)
        self.contract_paths = [*review_scope.REVIEW_CONTRACT_PATHS, "alias.txt"]
        current = self.gate("review", contract_paths=self.contract_paths, contract_root=str(alias_root))["input_fingerprint"]
        paths = review_scope.changed_files(str(self.repo), self.base)
        review_loop.merge(
            self.state,
            1,
            "final-full",
            0,
            None,
            [self.r1_file(_r1([], ac=[_ac("AC-1")], input_fingerprint=current, files_reviewed=len(paths), file_citations=[{"file": name, "line": 1} for name in paths]))],
            input_fingerprint=current,
            expected_ac_ids=["AC-1"],
        )
        self.gate("complete", {"input_fingerprint": current, "mechanical": {"before_fingerprint": current, "after_fingerprint": current, "no_change": True, "evidence": "unchanged"}})
        with self.assertRaisesRegex(review_loop.LoopError, "aliases"):
            self.publish()

    def test_external_evidence_root_is_verified_even_when_delivery_fingerprint_is_identical(self) -> None:
        external = self.dir / "target"
        _write(external / "specs/GH-1/build.jsonl", "{}\n")
        _write(external / "specs/GH-1/plan.md", "Reviewed plan\n")
        _write(external / "specs/GH-1/plan-1.md", "Issue 1 plan\n")
        self.certify(evidence_root=str(external))
        worktree_copy = self.audit.read_bytes()
        delivered = self.publish()
        self.assertEqual(delivered["input_fingerprint"], delivered["delivery_fingerprint"])
        self.assertEqual(self.audit.read_bytes(), worktree_copy)
        self.assertEqual(self.gate("review")["next_action"], "complete")
        (external / "specs/GH-1/build.jsonl").write_text("{}\n")
        self.assertEqual(self.gate("review")["next_action"], "blocked")
        with self.assertRaises(review_loop.LoopError):
            self.publish()

    def test_unresolvable_or_ambiguous_canonical_audit_fails_explicitly(self) -> None:
        self.audit.unlink()
        self.certify()
        with self.assertRaisesRegex(review_loop.LoopError, "unavailable"):
            self.publish()
        _write(self.audit, "{}\n")
        _write(self.repo / "specs/GH-1-another/build.jsonl", "{}\n")
        _write(self.repo / "specs/GH-1-extra/build.jsonl", "{}\n")
        _write(self.repo / "specs/GH-1-another/plan-1.md", "Ambiguous issue 1 plan\n")
        self.certify()
        with self.assertRaisesRegex(review_loop.LoopError, "multiple"):
            self.publish()

    def test_intent_retry_recovers_before_append_and_after_append_without_duplicate_rows(self) -> None:
        for crash_save in (1, 2):
            with self.subTest(crash_save=crash_save):
                _write(self.repo / "app.py", f"VALUE = {crash_save + 2}\n")
                self.certify()
                prefix = self.audit.read_bytes()
                save = review_loop._save_state
                calls = 0

                def crash(path: str, state: dict) -> None:
                    nonlocal calls
                    calls += 1
                    if calls == crash_save:
                        if crash_save == 1:
                            save(path, state)
                        raise RuntimeError("simulated crash")
                    save(path, state)

                with patch.object(review_loop, "_save_state", side_effect=crash):
                    with self.assertRaisesRegex(RuntimeError, "simulated"):
                        self.publish()
                intent = self.stored()["audit_certificates"][-1]["intent"]["append"].encode()
                self.assertEqual(self.audit.read_bytes(), prefix if crash_save == 1 else prefix + intent)
                delivered = self.publish()
                self.assertEqual(self.audit.read_bytes(), prefix + intent)
                self.assertEqual(self.publish(), delivered)

    def test_partial_intended_append_is_completed_but_foreign_partial_bytes_are_never_truncated(self) -> None:
        import review_audit

        self.certify()
        prefix = self.audit.read_bytes()
        native_write = os.write
        calls = 0

        def partial(fd: int, data: bytes) -> int:
            nonlocal calls
            calls += 1
            if calls == 1:
                return native_write(fd, data[:17])
            raise OSError("interrupted partial append")

        with patch.object(review_audit.os, "write", side_effect=partial):
            with self.assertRaisesRegex(review_loop.LoopError, "partial"):
                self.publish()
        intent = self.stored()["audit_certificates"][-1]["intent"]["append"].encode()
        self.assertEqual(self.audit.read_bytes(), prefix + intent[:17])
        self.publish()
        self.assertEqual(self.audit.read_bytes(), prefix + intent)
        stored = self.stored()
        del stored["audit_certificates"][-1]["audit_transition"]
        review_loop._save_state(self.state, stored)
        foreign = prefix + intent[:17] + b"foreign"
        self.audit.write_bytes(foreign)
        with self.assertRaisesRegex(review_loop.LoopError, "tail"):
            self.publish()
        self.assertEqual(self.audit.read_bytes(), foreign)

    def test_forged_transition_or_row_digest_cannot_authorize_a_different_tail(self) -> None:
        self.certify()
        self.publish()
        stored = self.stored()
        valid_bytes = self.audit.read_bytes()
        for field, value in (("input_fingerprint", "f" * 64), ("pass_id", "P-99"), ("append_length", 1), ("prefix_sha256", "0" * 64)):
            altered = copy.deepcopy(stored)
            altered["audit_certificates"][-1]["audit_transition"][field] = value
            review_loop._save_state(self.state, altered)
            with self.assertRaises(review_loop.LoopError):
                self.publish()
            self.assertNotEqual(self.gate("review")["next_action"], "complete")
        altered = copy.deepcopy(stored)
        cert = altered["audit_certificates"][-1]
        rows = [json.loads(line) for line in cert["intent"]["append"].splitlines()]
        rows[0]["data"]["ac_verdicts"][0]["verified"] = False
        forged = "".join(json.dumps(row, sort_keys=True, ensure_ascii=False, separators=(",", ":")) + "\n" for row in rows).encode()
        cert["intent"]["append"] = forged.decode()
        cert["audit_transition"]["append_sha256"] = hashlib.sha256(forged).hexdigest()
        cert["audit_transition"]["append_length"] = len(forged)
        self.audit.write_bytes(valid_bytes[: cert["audit"]["prefix_length"]] + forged)
        cert["audit_transition"]["delivery_fingerprint"] = self.fingerprint(context_paths=["specs/GH-1/plan.md"])
        review_loop._save_state(self.state, altered)
        with self.assertRaisesRegex(review_loop.LoopError, "ledger-derived"):
            self.publish()
        self.assertNotEqual(self.gate("review")["next_action"], "complete")

    def test_nested_evidence_root_normalizes_only_its_canonical_worktree_entry(self) -> None:
        nested = self.repo / "target"
        canonical = nested / "specs/GH-1/build.jsonl"
        _write(canonical, "{}\n")
        _write(nested / "specs/GH-1/plan.md", "Reviewed plan\n")
        _write(nested / "specs/GH-1/plan-1.md", "Issue 1 plan\n")
        self.certify(evidence_root=str(nested))
        other_copy = self.audit.read_bytes()
        delivered = self.publish()
        self.assertNotEqual(delivered["input_fingerprint"], delivered["delivery_fingerprint"])
        self.assertEqual(self.audit.read_bytes(), other_copy)
        self.assertEqual(self.gate("review")["next_action"], "complete")

    def test_resolver_cannot_authorize_an_audit_outside_selected_specs(self) -> None:
        self.state = str(self.dir / "escape-ledger.json")
        review_loop.init(self.state, "../outside", self.base)
        outside = self.repo / "outside/build.jsonl"
        _write(outside, "{}\n")
        self.certify()
        before = outside.read_bytes()
        with self.assertRaisesRegex(review_loop.LoopError, "escapes"):
            self.publish()
        self.assertEqual(outside.read_bytes(), before)

    def test_parallel_cli_publication_serializes_one_exact_append(self) -> None:
        self.certify()
        prefix = self.audit.read_bytes()
        command = [sys.executable, str(self.build / "shared/review_loop.py"), "publish-audit", "--state", self.state, "--worktree", str(self.repo), "--review-base", self.base]
        first = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        second = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        output1, error1 = first.communicate(timeout=10)
        output2, error2 = second.communicate(timeout=10)
        self.assertEqual((first.returncode, second.returncode), (0, 0), error1 + error2)
        self.assertEqual(json.loads(output1), json.loads(output2))
        intent = self.stored()["audit_certificates"][-1]["intent"]["append"].encode()
        self.assertEqual(self.audit.read_bytes(), prefix + intent)

    def test_publication_independently_revalidates_the_successful_source_certificate(self) -> None:
        self.certify()
        stored = self.stored()
        stored["mechanical_evidence"]["no_change"] = False
        review_loop._save_state(self.state, stored)
        before = self.audit.read_bytes()
        with self.assertRaisesRegex(review_loop.LoopError, "source final-full"):
            self.publish()
        self.assertEqual(self.audit.read_bytes(), before)


class LensRoutingTests(LoopTestCase):
    def test_auto_lens_split_threshold_and_explicit_modes(self) -> None:
        _write(self.repo / "app.py", "".join(f"x{number} = {number}\n" for number in range(199)))
        _write(self.repo / "new.py", "".join(f"y{number} = {number}\n" for number in range(200)))
        at_threshold = review_loop.lenses(str(self.repo), self.base, "auto")
        self.assertEqual((at_threshold["changed_lines"], at_threshold["split"]), (400, False))

        _write(self.repo / "new.py", "".join(f"y{number} = {number}\n" for number in range(201)))
        above = review_loop.lenses(str(self.repo), self.base, "auto")
        self.assertEqual((above["changed_lines"], above["changed_files"], above["split"]), (401, 2, True))
        self.assertEqual(above["lenses"], list(review_loop.LENSES))
        self.assertTrue(review_loop.lenses(str(self.repo), self.base, "on")["split"])
        self.assertFalse(review_loop.lenses(str(self.repo), self.base, "off")["split"])
        fallback = review_loop.lenses(str(self.repo), self.base, "sometimes")
        self.assertEqual((fallback["mode"], fallback["split"]), ("auto", True))
        self.assertIn("warning", fallback)


class PartitionTests(LoopTestCase):
    def test_repair_groups_keep_shared_site_files_together(self) -> None:
        findings = [
            _finding("MAJOR", "a.py", 1, finding_id="F-001", invariant="rule A", extra_sites=(("shared.py", 1),)),
            _finding("MAJOR", "b.py", 1, finding_id="F-002", invariant="rule B"),
            _finding("MAJOR", "shared.py", 90, finding_id="F-003", invariant="rule C"),
            _finding("MAJOR", "c.py", 1, finding_id="F-004", invariant="rule D", extra_sites=(("d.py", 4),)),
        ]
        groups = review_loop.partition(self.r1_file(_r1(findings)), ["F-001", "F-002", "F-003", "F-004"], 4)["groups"]
        self.assertEqual([group["ids"] for group in groups], [["F-001", "F-003"], ["F-002"], ["F-004"]])
        self.assertEqual(groups[0]["files"], ["a.py", "shared.py"])

    def test_unknown_repair_group_ids_are_rejected(self) -> None:
        finding = _finding("MAJOR", "app.py", 1, finding_id="F-001", invariant="rule")
        with self.assertRaises(review_loop.LoopError):
            review_loop.partition(self.r1_file(_r1([finding])), ["F-404"], 4)


if __name__ == "__main__":
    unittest.main()
