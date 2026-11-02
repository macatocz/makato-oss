"""Behavioral tests for the durable build-review ledger and its consumer gates."""

from __future__ import annotations

import contextlib
import io
import itertools
import json
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
    return {"schema": "r1", "agent": "diff-reviewer", "status": actual_status, "errors": actual_errors, "data": data}


def _ac(ac_id: str, file: str = "app.py", line: int = 1) -> dict:
    return {
        "ac_id": ac_id,
        "verified": True,
        "evidence": f"Verified {ac_id} against the current implementation.",
        "citations": [{"file": file, "line": line}],
    }


class LoopTestCase(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.dir = Path(self._tmp.name)
        self.repo = self.dir / "worktree"
        self.repo.mkdir()
        _git(self.repo, "init", "-q", "-b", "main")
        _git(self.repo, "config", "user.email", "review@example.invalid")
        _git(self.repo, "config", "user.name", "Review test")
        _write(self.repo / "app.py", "VALUE = 1\n")
        _write(self.repo / "review-contract.md", "# Versioned review contract fixture\n")
        self.contract_paths = ["review-contract.md", *review_scope.REVIEW_CONTRACT_PATHS]
        for relative in review_scope.REVIEW_CONTRACT_PATHS:
            _write(self.repo / relative, f"Versioned contract fixture: {relative}\n")
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
        kwargs.setdefault("contract_root", str(self.repo))
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
            contract_root=str(self.repo),
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
            contract_root=str(self.repo),
            expected_ac_ids=expected_ac_ids,
        )

    def gate(self, event: str, evidence: dict | None = None, **kwargs: object) -> dict:
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
            contract_root=str(self.repo),
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
            contract_root=str(self.repo),
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

    def test_final_full_with_a_partial_versioned_contract_inventory_cannot_complete(self) -> None:
        fingerprint = self.fingerprint(contract_paths=["review-contract.md"], contract_root=str(self.repo))
        self.merge(
            [],
            scope="final-full",
            expected_ac_ids=["AC-1"],
            input_fingerprint=fingerprint,
            contract_paths=["review-contract.md"],
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
        fingerprint = self.fingerprint()
        self.merge([], pass_number=1, scope="delta", input_fingerprint=fingerprint)
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


class LensQualificationTests(LoopTestCase):
    def test_deep_sampling_qualification_is_verified_and_limited_to_eligible_passes(self) -> None:
        config = "a" * 64
        model = "pinned-test-model"
        settings = {"temperature": 0, "top_p": 1}
        qualification = "qualified-artifact.json"
        source_root = Path(review_loop.__file__).resolve().parent.parent

        with patch.object(review_loop.review_eval, "verify_qualification", return_value=None) as verify:
            qualified = review_loop.lenses(
                str(self.repo),
                self.base,
                "on",
                profile="deep",
                pass_kind="initial",
                qualification=qualification,
                config_fingerprint=config,
                model=model,
                settings=settings,
            )
            first_rereview = review_loop.lenses(
                str(self.repo),
                self.base,
                "on",
                profile="deep",
                pass_kind="first-rereview",
                qualification=qualification,
                config_fingerprint=config,
                model=model,
                settings=settings,
            )

        expected_call = {
            "source_root": source_root,
            "settings": settings,
        }
        self.assertEqual(verify.call_count, 2)
        verify.assert_called_with(qualification, config, model, **expected_call)
        self.assertTrue(qualified["sampling_enabled"])
        self.assertEqual(qualified["sample_counts"]["error-handling"], 2)
        self.assertEqual(qualified["sample_counts"]["state-concurrency"], 2)
        self.assertTrue(first_rereview["sampling_enabled"])
        self.assertEqual(first_rereview["sample_counts"]["error-handling"], 2)

        with patch.object(
            review_loop.review_eval,
            "verify_qualification",
            side_effect=review_loop.review_eval.EvalError("qualification rejected"),
        ) as verify:
            rejected = review_loop.lenses(
                str(self.repo),
                self.base,
                "on",
                profile="deep",
                pass_kind="initial",
                qualification=qualification,
                config_fingerprint=config,
                model=model,
                settings=settings,
            )
            verify.assert_called_once_with(qualification, config, model, **expected_call)
        self.assertFalse(rejected["sampling_enabled"])
        self.assertEqual(rejected["sample_counts"], dict.fromkeys(review_loop.LENSES, 1))

        with patch.object(review_loop.review_eval, "verify_qualification") as verify:
            off = review_loop.lenses(
                str(self.repo),
                self.base,
                "off",
                profile="deep",
                pass_kind="initial",
                qualification=qualification,
                config_fingerprint=config,
                model=model,
                settings=settings,
            )
            verify.assert_not_called()
        self.assertFalse(off["split"])
        self.assertEqual(off["lenses"], [])
        self.assertFalse(off["sampling_enabled"])
        self.assertEqual(off["sample_counts"], dict.fromkeys(review_loop.LENSES, 1))

        with patch.object(review_loop.review_eval, "verify_qualification") as verify:
            later = review_loop.lenses(
                str(self.repo),
                self.base,
                "on",
                profile="deep",
                pass_kind="later",
                qualification=qualification,
                config_fingerprint=config,
                model=model,
                settings=settings,
            )
            verify.assert_not_called()
        self.assertFalse(later["sampling_enabled"])
        self.assertEqual(later["sample_counts"], dict.fromkeys(review_loop.LENSES, 1))

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
