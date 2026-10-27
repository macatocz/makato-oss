"""Tests for the build-review loop helper (``review_loop.py``)."""

from __future__ import annotations

import contextlib
import io
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

_HERE = Path(__file__).resolve().parent
if str(_HERE) not in sys.path:
    sys.path.insert(0, str(_HERE))

import review_loop  # noqa: E402


def _finding(
    severity: str, file: str, line: int, *, finding_id: str = "new", lens: str | None = None, invariant: str = "rule", category: str = "security", extra_sites: tuple[tuple[str, int], ...] = ()
) -> dict:
    sites = [{"file": file, "line": line}, *({"file": f, "line": n} for f, n in extra_sites)]
    return {
        "id": finding_id,
        "severity": severity,
        "category": category,
        "lens": lens,
        "invariant": invariant,
        "file": file,
        "line": line,
        "sites": sites,
        "evidence": "e",
        "description": f"{severity} at {file}:{line}",
    }


def _r1(findings: list[dict], *, lens: str | None = None, status: str | None = None, ac: list | None = None) -> dict:
    critical = sum(1 for f in findings if f["severity"] == "CRITICAL")
    major = sum(1 for f in findings if f["severity"] == "MAJOR")
    return {
        "schema": "r1",
        "agent": "diff-reviewer",
        "status": status or ("failure" if critical + major else "success"),
        "data": {"lens": lens, "critical_count": critical, "major_count": major, "files_reviewed": 3, "findings": findings, "ac_verdicts": ac or []},
    }


class LoopTestCase(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.dir = Path(self._tmp.name)
        self.state = str(self.dir / "loop" / "GH-1.json")
        review_loop.init(self.state, "GH-1", "base")
        self._files = 0

    def r1_file(self, r1: dict) -> str:
        self._files += 1
        path = self.dir / f"r1-{self._files}.json"
        path.write_text(json.dumps(r1), encoding="utf-8")
        return str(path)

    def merge(self, *r1s: dict, pass_number: int = 1, scope: str = "full", after_round: int = 0, drop: list[str] | None = None) -> dict:
        return review_loop.merge(self.state, pass_number, scope, after_round, None, drop or [], [self.r1_file(r1) for r1 in r1s])

    def cli(self, *argv: str) -> tuple[int, str, str]:
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = review_loop._main(list(argv))
        return code, out.getvalue(), err.getvalue()

    def stored(self) -> dict:
        return json.loads(Path(self.state).read_text(encoding="utf-8"))


class MergeTests(LoopTestCase):
    def test_lens_findings_on_nearby_lines_become_one_with_the_highest_severity(self) -> None:
        merged = self.merge(
            _r1([_finding("MAJOR", "a.py", 10, lens="error-handling")], lens="error-handling"), _r1([_finding("CRITICAL", "a.py", 12, lens="security-privacy")], lens="security-privacy")
        )

        findings = merged["data"]["findings"]
        self.assertEqual(len(findings), 1)
        self.assertEqual(findings[0]["severity"], "CRITICAL")
        self.assertEqual(findings[0]["lenses"], ["error-handling", "security-privacy"])
        self.assertEqual([(s["file"], s["line"]) for s in findings[0]["sites"]], [("a.py", 10), ("a.py", 12)])
        self.assertEqual((merged["data"]["critical_count"], merged["data"]["major_count"]), (1, 0))
        self.assertEqual(merged["status"], "failure")

    def test_findings_beyond_the_line_tolerance_stay_separate(self) -> None:
        merged = self.merge(_r1([_finding("MAJOR", "a.py", 10)]), _r1([_finding("MAJOR", "a.py", 20)]))

        self.assertEqual([f["id"] for f in merged["data"]["findings"]], ["F-001", "F-002"])

    def test_a_reraised_prior_id_is_kept_and_a_new_finding_gets_the_next_id(self) -> None:
        self.merge(_r1([_finding("MAJOR", "a.py", 10)]))

        merged = self.merge(_r1([_finding("MAJOR", "a.py", 40, finding_id="F-001"), _finding("CRITICAL", "b.py", 5)]), pass_number=2, scope="delta", after_round=1)

        self.assertEqual(sorted(f["id"] for f in merged["data"]["findings"]), ["F-001", "F-002"])
        passes = self.stored()["passes"]
        self.assertEqual(passes[-1]["new_blocking"], ["F-002"])
        self.assertEqual(self.stored()["findings"]["F-001"]["raised_in"], [{"pass": 1, "after_round": 0}, {"pass": 2, "after_round": 1}])

    def test_drop_ids_removes_findings_by_id_and_by_their_recorded_sites(self) -> None:
        self.merge(_r1([_finding("MAJOR", "a.py", 10)]))

        merged = self.merge(
            _r1([_finding("MAJOR", "a.py", 11), _finding("MAJOR", "c.py", 1, finding_id="F-001"), _finding("MAJOR", "d.py", 1)]), pass_number=2, scope="background-full", after_round=1, drop=["F-001"]
        )

        self.assertEqual([f["file"] for f in merged["data"]["findings"]], ["d.py"])

    def test_a_blocking_finding_without_an_invariant_is_rejected_and_the_state_is_untouched(self) -> None:
        before = self.stored()
        code, out, err = self.cli("merge", "--state", self.state, "--pass", "1", "--scope", "full", "--after-round", "0", self.r1_file(_r1([_finding("MAJOR", "a.py", 1, invariant=" ")])))

        self.assertEqual((code, out), (2, ""))
        self.assertIn("needs an invariant", err)
        self.assertEqual(self.stored(), before)

    def test_counts_that_disagree_with_the_findings_are_rejected(self) -> None:
        r1 = _r1([_finding("CRITICAL", "a.py", 1)])
        r1["data"]["critical_count"] = 0
        with self.assertRaisesRegex(review_loop.LoopError, "critical_count"):
            self.merge(r1)

    def test_a_partial_input_makes_the_merged_result_partial(self) -> None:
        merged = self.merge(_r1([], status="partial"), _r1([]))

        self.assertEqual(merged["status"], "partial")

    def test_ac_verdicts_come_from_the_contract_lens(self) -> None:
        verdicts = [{"ac": "AC-1", "verdict": "verified"}]
        merged = self.merge(_r1([], lens="security-privacy", ac=[{"ac": "AC-1", "verdict": "gap"}]), _r1([], lens="contract-ac", ac=verdicts))

        self.assertEqual(merged["data"]["ac_verdicts"], verdicts)
        self.assertEqual(merged["status"], "success")

    def test_r1_is_read_from_the_last_json_object_of_a_transcript(self) -> None:
        path = self.dir / "transcript.txt"
        path.write_text("thinking {not json}\n" + json.dumps(_r1([])) + "\ndone\n" + json.dumps(_r1([_finding("MAJOR", "z.py", 3)])), encoding="utf-8")

        merged = review_loop.merge(self.state, 1, "full", 0, None, [], [str(path)])

        self.assertEqual(merged["data"]["major_count"], 1)


class NextTests(LoopTestCase):
    def raise_and_repair(self, finding: dict, rounds: list[int]) -> None:
        """Raise ``finding`` after round 0, then re-raise it after each repair round in ``rounds``."""
        self.merge(_r1([finding]))
        for number, repair_round in enumerate(rounds, start=2):
            review_loop.repaired(self.state, repair_round, ["F-001"])
            self.merge(_r1([{**finding, "id": "F-001"}]), pass_number=number, scope="delta", after_round=repair_round)

    def next(self, repair_rounds: int, open_ids: list[str], soft: str | None = "3", hard: str | None = "8") -> dict:
        return review_loop.next_round(self.state, repair_rounds, open_ids, soft, hard)

    def test_rounds_below_the_soft_cap_continue(self) -> None:
        self.merge(_r1([_finding("MAJOR", "a.py", 1)]))

        self.assertEqual(self.next(1, ["F-001"])["reason"], "within_soft_cap")

    def test_past_the_soft_cap_fewer_new_blockers_than_the_round_before_continues(self) -> None:
        self.merge(_r1([_finding("MAJOR", "a.py", 1), _finding("MAJOR", "b.py", 1)]), pass_number=1, after_round=2)
        self.merge(_r1([_finding("MAJOR", "c.py", 1)]), pass_number=2, after_round=3)

        decision = self.next(3, ["F-003"])

        self.assertEqual((decision["continue"], decision["reason"]), (True, "converging"))
        self.assertEqual(decision["new_by_round"], {"2": 2, "3": 1})

    def test_past_the_soft_cap_no_new_blockers_continues(self) -> None:
        self.merge(_r1([_finding("MAJOR", "a.py", 1)]), after_round=2)

        self.assertEqual(self.next(3, ["F-001"])["reason"], "converging")

    def test_past_the_soft_cap_as_many_new_blockers_as_before_stops(self) -> None:
        self.merge(_r1([_finding("MAJOR", "a.py", 1)]), pass_number=1, after_round=2)
        self.merge(_r1([_finding("MAJOR", "c.py", 1)]), pass_number=2, after_round=3)

        decision = self.next(3, ["F-002"])

        self.assertEqual((decision["continue"], decision["reason"]), (False, "not_converging"))

    def test_the_hard_cap_stops_even_a_converging_loop(self) -> None:
        self.merge(_r1([_finding("MAJOR", "a.py", 1)]), after_round=1)

        self.assertEqual(self.next(8, ["F-001"])["reason"], "hard_cap")

    def test_a_finding_back_after_two_repairs_needs_redesign_and_after_three_stops_the_loop(self) -> None:
        self.raise_and_repair(_finding("CRITICAL", "a.py", 1), [1, 2])
        decision = self.next(2, ["F-001"])
        self.assertEqual((decision["continue"], decision["redesign_ids"], decision["recurring_ids"]), (True, ["F-001"], []))

        review_loop.repaired(self.state, 3, ["F-001"])
        self.merge(_r1([_finding("CRITICAL", "a.py", 1, finding_id="F-001")]), pass_number=4, scope="delta", after_round=3)
        decision = self.next(3, ["F-001"])
        self.assertEqual((decision["continue"], decision["reason"], decision["recurring_ids"]), (False, "recurring_finding", ["F-001"]))

    def test_a_repair_claim_that_held_is_not_a_recurrence(self) -> None:
        self.merge(_r1([_finding("MAJOR", "a.py", 1)]))
        review_loop.repaired(self.state, 1, ["F-001"])

        self.assertEqual(review_loop.recurrences(self.stored()["findings"]["F-001"]), 0)

    def test_invalid_caps_fall_back_to_defaults_with_warnings(self) -> None:
        self.merge(_r1([_finding("MAJOR", "a.py", 1)]))
        with mock.patch.dict(os.environ, {"MAKATO_MAX_REPAIR_ROUNDS": "zero", "MAKATO_MAX_REPAIR_ROUNDS_HARD": "-1"}):
            decision = self.next(1, ["F-001"], soft=None, hard=None)

        self.assertEqual((decision["soft_cap"], decision["hard_cap"]), (3, 8))
        self.assertEqual(len(decision["warnings"]), 2)

    def test_a_hard_cap_below_the_soft_cap_is_raised_to_it(self) -> None:
        self.merge(_r1([_finding("MAJOR", "a.py", 1)]))

        decision = self.next(4, ["F-001"], soft="5", hard="2")

        self.assertEqual((decision["hard_cap"], decision["reason"]), (5, "within_soft_cap"))
        self.assertTrue(decision["warnings"])

    def test_unknown_ids_are_rejected(self) -> None:
        with self.assertRaises(review_loop.LoopError):
            review_loop.repaired(self.state, 1, ["F-404"])
        with self.assertRaises(review_loop.LoopError):
            self.next(1, ["F-404"])


class PartitionTests(LoopTestCase):
    def partition(self, findings: list[dict], ids: list[str], max_groups: int = 4) -> list[dict]:
        return review_loop.partition(self.r1_file(_r1(findings)), ids, max_groups)["groups"]

    def test_findings_sharing_a_site_file_stay_together(self) -> None:
        findings = [
            _finding("MAJOR", "a.py", 1, finding_id="F-001", extra_sites=(("shared.py", 1),)),
            _finding("MAJOR", "b.py", 1, finding_id="F-002"),
            _finding("MAJOR", "shared.py", 90, finding_id="F-003"),
            _finding("MAJOR", "c.py", 1, finding_id="F-004", extra_sites=(("d.py", 4),)),
        ]

        groups = self.partition(findings, ["F-001", "F-002", "F-003", "F-004"])

        self.assertEqual([g["ids"] for g in groups], [["F-001", "F-003"], ["F-002"], ["F-004"]])
        self.assertEqual(groups[0]["files"], ["a.py", "shared.py"])

    def test_too_many_groups_merge_the_smallest_first(self) -> None:
        findings = [
            _finding("MAJOR", "a.py", 1, finding_id="F-001", extra_sites=(("a2.py", 1), ("a3.py", 1))),
            _finding("MAJOR", "b.py", 1, finding_id="F-002"),
            _finding("MAJOR", "c.py", 1, finding_id="F-003"),
        ]

        groups = self.partition(findings, ["F-001", "F-002", "F-003"], max_groups=2)

        self.assertEqual([(g["group"], g["ids"]) for g in groups], [(1, ["F-001"]), (2, ["F-002", "F-003"])])

    def test_ids_missing_from_the_findings_are_rejected(self) -> None:
        with self.assertRaises(review_loop.LoopError):
            self.partition([_finding("MAJOR", "a.py", 1, finding_id="F-001")], ["F-002"])


class BackgroundTests(LoopTestCase):
    def background(self, repair_round: int, mode: str = "delta") -> dict:
        return review_loop.background(self.state, repair_round, mode)

    def test_round_one_and_legacy_full_mode_skip_the_background_pass(self) -> None:
        self.assertFalse(self.background(1)["run"])
        self.assertFalse(self.background(3, mode="full")["run"])

    def test_the_first_background_pass_runs_from_round_two(self) -> None:
        self.assertEqual(self.background(2), {"run": True, "reason": "first background full pass"})

    def test_a_background_pass_repeats_only_while_it_finds_new_blockers(self) -> None:
        self.merge(_r1([_finding("MAJOR", "a.py", 1)]), pass_number=3, scope="background-full", after_round=1)
        self.assertTrue(self.background(3)["run"])

        self.merge(_r1([_finding("MAJOR", "a.py", 1, finding_id="F-001")]), pass_number=5, scope="background-full", after_round=2)
        self.assertEqual(self.background(4), {"run": False, "reason": "last background pass found nothing new"})


class InitTests(LoopTestCase):
    def test_same_story_and_base_resume_the_history(self) -> None:
        self.merge(_r1([_finding("MAJOR", "a.py", 1)]))

        self.assertEqual(review_loop.init(self.state, "GH-1", "base"), {"state": self.state, "resumed": True, "next_id": 2})

    def test_a_new_review_base_starts_a_fresh_history(self) -> None:
        self.merge(_r1([_finding("MAJOR", "a.py", 1)]))

        self.assertFalse(review_loop.init(self.state, "GH-1", "rebased")["resumed"])
        self.assertEqual(self.stored()["findings"], {})


class LensTests(unittest.TestCase):
    def setUp(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.repo = Path(tmp.name)
        for args in (("init", "-q", "-b", "main"), ("config", "user.email", "t@example.invalid"), ("config", "user.name", "t")):
            subprocess.run(["git", "-C", str(self.repo), *args], check=True)
        (self.repo / "a.py").write_text("x = 1\n", encoding="utf-8")
        subprocess.run(["git", "-C", str(self.repo), "add", "-A"], check=True)
        subprocess.run(["git", "-C", str(self.repo), "commit", "-qm", "base"], check=True)
        self.base = subprocess.run(["git", "-C", str(self.repo), "rev-parse", "HEAD"], capture_output=True, text=True, check=True).stdout.strip()

    def test_auto_splits_only_above_the_line_threshold(self) -> None:
        (self.repo / "a.py").write_text("".join(f"x{i} = {i}\n" for i in range(199)), encoding="utf-8")
        (self.repo / "new.py").write_text("".join(f"y{i} = {i}\n" for i in range(200)), encoding="utf-8")
        at_threshold = review_loop.lenses(str(self.repo), self.base, "auto")
        self.assertEqual((at_threshold["changed_lines"], at_threshold["split"]), (400, False))

        (self.repo / "new.py").write_text("".join(f"y{i} = {i}\n" for i in range(201)), encoding="utf-8")
        above = review_loop.lenses(str(self.repo), self.base, "auto")
        self.assertEqual((above["changed_lines"], above["changed_files"], above["split"]), (401, 2, True))
        self.assertEqual(above["lenses"], list(review_loop.LENSES))

    def test_on_and_off_override_the_threshold_and_invalid_falls_back_to_auto(self) -> None:
        self.assertTrue(review_loop.lenses(str(self.repo), self.base, "on")["split"])
        self.assertFalse(review_loop.lenses(str(self.repo), self.base, "off")["split"])
        fallback = review_loop.lenses(str(self.repo), self.base, "sometimes")
        self.assertEqual((fallback["mode"], fallback["split"]), ("auto", False))
        self.assertIn("warning", fallback)


if __name__ == "__main__":
    unittest.main()
