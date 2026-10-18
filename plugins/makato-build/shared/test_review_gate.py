"""Unit tests for review_gate — PO-owned review loop gate and ledger.

Run from repo root:
    python3 -m pytest plugins/makato-build/shared/test_review_gate.py -q

Covers every decision reason, first-match order, finding identity across
rounds (fingerprint, prior_id, line drift, reopen), attempts, stagnation,
idempotent re-reconcile, the legacy errors[] fallback, limit parsing, the
working-tree fingerprint (untracked files, specs/ exclusion) and CLI exit codes.
"""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

_HERE = Path(__file__).parent.resolve()
if str(_HERE) not in sys.path:
    sys.path.insert(0, str(_HERE))

import review_gate as gate  # noqa: E402

REV = "sha256:abc"
LIMITS = {"max_repair_rounds": 3, "max_finding_attempts": 2, "max_stagnant_rounds": 2}


def finding(file="src/auth.py", symbol="verify_token", category="security",
            rule="jwt-expiration", severity="MAJOR", line=42, **extra):
    return {"file": file, "symbol": symbol, "category": category, "rule": rule,
            "severity": severity, "line": line,
            "description": extra.pop("description", f"{rule} defect"), **extra}


def r1(round_, findings=(), revision=REV, status=None, **data):
    blocking = [f for f in findings if f["severity"] in gate.BLOCKING]
    payload = {"round": round_, "review_revision": revision, "findings": list(findings),
               "critical_count": sum(f["severity"] == "CRITICAL" for f in blocking),
               "major_count": sum(f["severity"] == "MAJOR" for f in blocking)}
    payload.update(data)
    return {"schema": "r1", "agent": "build-review",
            "status": status or ("failure" if blocking else "success"),
            "errors": [], "data": payload}


def fresh(limits=None):
    return gate.new_ledger("42", "base-sha", dict(limits or LIMITS))


class DecisionTests(unittest.TestCase):
    def test_clean_first_round_is_success(self):
        ledger = fresh()
        decision = gate.reconcile(ledger, r1(0), REV)
        self.assertEqual((decision["decision"], decision["reason"]), ("SUCCESS", gate.ALL_VERIFIED))

    def test_blocking_finding_continues_with_repair_ids_ordered_critical_first(self):
        ledger = fresh()
        major = finding(rule="a", severity="MAJOR")
        critical = finding(rule="b", severity="CRITICAL")
        decision = gate.reconcile(ledger, r1(0, [major, critical]), REV)
        self.assertEqual(decision["decision"], "CONTINUE")
        ids = decision["repair_ids"]
        self.assertEqual(ledger["findings"][ids[0]]["severity"], "CRITICAL")
        self.assertEqual(len(ids), 2)

    def test_suggestions_and_nitpicks_never_block(self):
        ledger = fresh()
        decision = gate.reconcile(ledger, r1(0, [finding(severity="SUGGESTION"),
                                                 finding(rule="x", severity="NITPICK")]), REV)
        self.assertEqual(decision["decision"], "SUCCESS")
        self.assertEqual(ledger["findings"], {})

    def test_fix_then_clean_review_verifies_and_succeeds(self):
        ledger = fresh()
        first = gate.reconcile(ledger, r1(0, [finding()]), REV)
        fid = first["repair_ids"][0]
        decision = gate.reconcile(ledger, r1(1), REV)
        self.assertEqual(decision["decision"], "SUCCESS")
        self.assertEqual(ledger["findings"][fid]["status"], "verified")
        self.assertEqual(ledger["findings"][fid]["attempts"], 1)
        self.assertEqual(ledger["rounds"][-1]["verified_ids"], [fid])

    def test_max_rounds_stops_after_configured_repairs(self):
        ledger = fresh({**LIMITS, "max_finding_attempts": 10, "max_stagnant_rounds": 10})
        decisions = []
        for rnd in range(4):
            # a different new finding each round keeps the loop from stagnating on attempts
            findings = [finding(rule=f"r{rnd}", severity="CRITICAL")] if rnd < 3 else [finding(rule="r3")]
            decisions.append(gate.reconcile(ledger, r1(rnd, findings), REV))
        self.assertEqual([d["decision"] for d in decisions[:3]], ["CONTINUE"] * 3)
        self.assertEqual((decisions[3]["decision"], decisions[3]["reason"]), ("STOP", gate.MAX_ROUNDS))

    def test_two_fixed_two_new_counts_as_stagnation(self):
        ledger = fresh({**LIMITS, "max_repair_rounds": 10, "max_finding_attempts": 10})
        gate.reconcile(ledger, r1(0, [finding(rule="a"), finding(rule="b")]), REV)
        d1 = gate.reconcile(ledger, r1(1, [finding(rule="c"), finding(rule="d")]), REV)
        self.assertEqual(d1["decision"], "CONTINUE")
        self.assertEqual(ledger["stagnant_rounds"], 1)
        d2 = gate.reconcile(ledger, r1(2, [finding(rule="e"), finding(rule="f")]), REV)
        self.assertEqual((d2["decision"], d2["reason"]), ("STOP", gate.NO_PROGRESS))

    def test_progress_resets_stagnation(self):
        ledger = fresh({**LIMITS, "max_repair_rounds": 10, "max_finding_attempts": 10})
        gate.reconcile(ledger, r1(0, [finding(rule="a"), finding(rule="b")]), REV)
        gate.reconcile(ledger, r1(1, [finding(rule="a"), finding(rule="b")]), REV)
        self.assertEqual(ledger["stagnant_rounds"], 1)
        gate.reconcile(ledger, r1(2, [finding(rule="a")]), REV)
        self.assertEqual(ledger["stagnant_rounds"], 0)

    def test_finding_that_survives_two_attempts_is_not_actionable(self):
        ledger = fresh({**LIMITS, "max_stagnant_rounds": 10})
        gate.reconcile(ledger, r1(0, [finding()]), REV)
        gate.reconcile(ledger, r1(1, [finding()]), REV)
        decision = gate.reconcile(ledger, r1(2, [finding()]), REV)
        self.assertEqual((decision["decision"], decision["reason"]), ("STOP", gate.NO_ACTIONABLE_FINDINGS))
        only = next(iter(ledger["findings"].values()))
        self.assertEqual(only["attempts"], 2)

    def test_attempts_count_even_when_repairer_claims_success(self):
        ledger = fresh()
        gate.reconcile(ledger, r1(0, [finding()]), REV)
        gate.reconcile(ledger, r1(1, [finding()], coder={"status": "success"}), REV)
        self.assertEqual(next(iter(ledger["findings"].values()))["attempts"], 1)


class ValidationTests(unittest.TestCase):
    def test_stale_review_stops(self):
        decision = gate.reconcile(fresh(), r1(0, revision="sha256:old"), REV)
        self.assertEqual((decision["decision"], decision["reason"]), ("STOP", gate.STALE_REVIEW))

    def test_invalid_reviews_stop_before_any_other_rule(self):
        cases = {
            "missing": None,
            "partial": r1(0, status="partial"),
            "wrong schema": {**r1(0), "schema": "x"},
            "wrong round": r1(5),
            "count mismatch": r1(0, [finding()], major_count=3),
            "success with blocking": r1(0, [finding()], status="success"),
            "failure without findings": r1(0, status="failure"),
            "non-int count": r1(0, critical_count="1"),
        }
        for name, payload in cases.items():
            with self.subTest(name):
                decision = gate.reconcile(fresh(), payload, REV)
                self.assertEqual((decision["decision"], decision["reason"]), ("STOP", gate.INVALID_REVIEW))

    def test_invalid_review_leaves_findings_untouched(self):
        ledger = fresh()
        gate.reconcile(ledger, r1(0, [finding()]), REV)
        before = json.dumps(ledger["findings"], sort_keys=True)
        gate.reconcile(ledger, r1(1, status="partial"), REV)
        self.assertEqual(json.dumps(ledger["findings"], sort_keys=True), before)

    def test_reconcile_is_idempotent_for_the_same_round(self):
        ledger = fresh()
        payload = r1(0, [finding()])
        first = gate.reconcile(ledger, payload, REV)
        again = gate.reconcile(ledger, payload, REV)
        self.assertEqual(first, again)
        self.assertEqual(len(ledger["rounds"]), 1)

    def test_idempotent_after_terminal_decision(self):
        ledger = fresh()
        payload = r1(0)
        gate.reconcile(ledger, payload, REV)
        self.assertEqual(gate.reconcile(ledger, payload, REV)["decision"], "SUCCESS")


class IdentityTests(unittest.TestCase):
    def test_line_and_wording_drift_keep_the_same_id(self):
        ledger = fresh()
        gate.reconcile(ledger, r1(0, [finding(line=42, description="expired accepted")]), REV)
        gate.reconcile(ledger, r1(1, [finding(line=57, description="tokens past exp pass")]), REV)
        self.assertEqual(len(ledger["findings"]), 1)

    def test_prior_id_wins_over_fingerprint(self):
        ledger = fresh()
        fid = gate.reconcile(ledger, r1(0, [finding(rule="a")]), REV)["repair_ids"][0]
        gate.reconcile(ledger, r1(1, [finding(rule="renamed", prior_id=fid)]), REV)
        self.assertEqual(list(ledger["findings"]), [fid])
        self.assertEqual(ledger["rounds"][-1]["new_ids"], [])

    def test_loose_match_on_file_symbol_category_when_rule_changes(self):
        ledger = fresh()
        gate.reconcile(ledger, r1(0, [finding(rule="a")]), REV)
        gate.reconcile(ledger, r1(1, [finding(rule="b")]), REV)
        self.assertEqual(len(ledger["findings"]), 1)

    def test_verified_finding_that_returns_is_reopened(self):
        ledger = fresh({**LIMITS, "max_repair_rounds": 10, "max_stagnant_rounds": 10})
        gate.reconcile(ledger, r1(0, [finding(rule="a"), finding(rule="b", symbol="other")]), REV)
        gate.reconcile(ledger, r1(1, [finding(rule="b", symbol="other")]), REV)
        fid_a = next(f["id"] for f in ledger["findings"].values() if f["rule"] == "a")
        self.assertEqual(ledger["findings"][fid_a]["status"], "verified")
        gate.reconcile(ledger, r1(2, [finding(rule="a")]), REV)
        self.assertEqual(ledger["findings"][fid_a]["status"], "reopened")
        self.assertIn(fid_a, ledger["rounds"][-1]["reopened_ids"])

    def test_two_findings_with_same_fingerprint_in_one_round_stay_distinct(self):
        ledger = fresh()
        gate.reconcile(ledger, r1(0, [finding(description="one"), finding(description="two")]), REV)
        self.assertEqual(len(ledger["findings"]), 2)

    def test_legacy_errors_fallback(self):
        payload = {"schema": "r1", "status": "failure", "data": {
            "round": 0, "review_revision": REV, "critical_count": 1, "major_count": 1},
            "errors": ["src/a.py:42 — [CRITICAL][security] raw id in query",
                       "src/a.py:67 — [MAJOR][correctness] missing null check"]}
        ledger = fresh()
        decision = gate.reconcile(ledger, payload, REV)
        self.assertEqual(decision["decision"], "CONTINUE")
        self.assertTrue(ledger["rounds"][0]["legacy_findings"])
        self.assertEqual(len(ledger["findings"]), 2)


class RoundControlTests(unittest.TestCase):
    def test_next_round_and_repair_set(self):
        ledger = fresh()
        self.assertEqual(gate.next_round(ledger), 0)
        self.assertEqual(gate.repair_set(ledger)["repair_ids"], [])
        gate.reconcile(ledger, r1(0, [finding()]), REV)
        self.assertEqual(gate.next_round(ledger), 1)
        repair = gate.repair_set(ledger)
        self.assertEqual(repair["round"], 1)
        self.assertEqual(repair["findings"][0]["file"], "src/auth.py")
        self.assertEqual(repair["review_base"], "base-sha")
        self.assertEqual(gate.describe(ledger)["unresolved"][0]["rule"], "jwt-expiration")

    def test_no_round_after_terminal_decision(self):
        ledger = fresh()
        gate.reconcile(ledger, r1(0), REV)
        with self.assertRaises(gate.Refused):
            gate.next_round(ledger)

    def test_limits_parsing(self):
        limits, warnings = gate.read_limits({"MAKATO_MAX_REPAIR_ROUNDS": "5",
                                             "MAKATO_MAX_FINDING_ATTEMPTS": "0",
                                             "MAKATO_MAX_STAGNANT_ROUNDS": "x"})
        self.assertEqual(limits, {"max_repair_rounds": 5, "max_finding_attempts": 2,
                                  "max_stagnant_rounds": 2})
        self.assertEqual(len(warnings), 2)

    def test_parse_r1_takes_last_fenced_block(self):
        text = "prose\n```json\n{\"schema\":\"r0\"}\n```\nmore\n```json\n{\"schema\":\"r1\"}\n```\n"
        self.assertEqual(gate.parse_r1(text), {"schema": "r1"})
        self.assertIsNone(gate.parse_r1("no json here"))


class CliTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)
        self.ledger = self.dir / "review-ledger.json"

    def tearDown(self):
        self.tmp.cleanup()

    def cli(self, *argv, env=None):
        result = subprocess.run([sys.executable, str(_HERE / "review_gate.py"), *argv],
                                capture_output=True, text=True, env=env)
        return result.returncode, json.loads(result.stdout)

    def test_full_cli_flow_and_exit_codes(self):
        code, out = self.cli("init", "--ledger", str(self.ledger), "--key", "42", "--review-base", "b")
        self.assertEqual((code, out["created"]), (0, True))
        code, out = self.cli("init", "--ledger", str(self.ledger), "--key", "42")
        self.assertEqual((code, out["created"]), (0, False))
        self.assertEqual(self.cli("assert-round", "--ledger", str(self.ledger), "--round", "1")[0], 3)
        self.assertEqual(self.cli("assert-round", "--ledger", str(self.ledger), "--round", "0")[0], 0)

        r1_path = self.dir / "r1.md"
        r1_path.write_text("Round done.\n```json\n" + json.dumps(r1(0, [finding()])) + "\n```\n")
        code, out = self.cli("reconcile", "--ledger", str(self.ledger), "--r1", str(r1_path), "--revision", REV)
        self.assertEqual((code, out["decision"]), (0, "CONTINUE"))
        self.assertEqual(out["unresolved"][0]["severity"], "MAJOR")
        self.assertEqual(self.cli("next-round", "--ledger", str(self.ledger))[1], {"round": 1})

        r1_path.write_text(json.dumps(r1(1)))
        code, out = self.cli("reconcile", "--ledger", str(self.ledger), "--r1", str(r1_path), "--revision", REV)
        self.assertEqual(out["decision"], "SUCCESS")
        self.assertEqual(self.cli("next-round", "--ledger", str(self.ledger))[0], 3)
        self.assertEqual(self.cli("decide", "--ledger", str(self.ledger))[1]["reason"], gate.ALL_VERIFIED)
        self.assertEqual(sorted(p.name for p in self.dir.iterdir()), ["r1.md", "review-ledger.json"])

    def test_missing_ledger_is_usage_error(self):
        code, out = self.cli("decide", "--ledger", str(self.ledger))
        self.assertEqual(code, 2)
        self.assertIn("ledger not found", out["error"])

    def test_missing_r1_file_stops_as_invalid(self):
        self.cli("init", "--ledger", str(self.ledger), "--key", "42")
        code, out = self.cli("reconcile", "--ledger", str(self.ledger),
                             "--r1", str(self.dir / "absent.json"), "--revision", REV)
        self.assertEqual((code, out["decision"], out["reason"]), (0, "STOP", gate.INVALID_REVIEW))


class FingerprintTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.repo = Path(self.tmp.name)
        git = ["git", "-C", str(self.repo)]
        subprocess.run([*git, "init", "-q"], check=True)
        subprocess.run([*git, "config", "user.email", "t@example.com"], check=True)
        subprocess.run([*git, "config", "user.name", "t"], check=True)
        (self.repo / "app.py").write_text("x = 1\n")
        subprocess.run([*git, "add", "."], check=True)
        subprocess.run([*git, "commit", "-qm", "base"], check=True)

    def tearDown(self):
        self.tmp.cleanup()

    def fp(self):
        return gate.worktree_fingerprint(self.repo, "HEAD")

    def test_tracked_and_untracked_changes_move_the_fingerprint(self):
        clean = self.fp()
        (self.repo / "app.py").write_text("x = 2\n")
        tracked = self.fp()
        (self.repo / "new.py").write_text("y = 1\n")
        untracked = self.fp()
        self.assertEqual(len({clean, tracked, untracked}), 3)
        self.assertEqual(untracked, self.fp())

    def test_reconcile_with_worktree_uses_ledger_review_base(self):
        base = subprocess.run(["git", "-C", str(self.repo), "rev-parse", "HEAD"],
                              capture_output=True, text=True, check=True).stdout.strip()
        ledger_path = self.repo / "specs" / "42-x" / "review-ledger.json"
        script = str(_HERE / "review_gate.py")
        run = lambda *a: subprocess.run([sys.executable, script, *a], capture_output=True, text=True)
        run("init", "--ledger", str(ledger_path), "--key", "42", "--review-base", base)
        (self.repo / "app.py").write_text("x = 3\n")
        revision = json.loads(run("fingerprint", "--worktree", str(self.repo), "--base", base).stdout)["revision"]
        r1_path = self.repo / "specs" / "42-x" / "review-round-0.r1.md"
        r1_path.write_text("```json\n" + json.dumps(r1(0, revision=revision)) + "\n```\n")
        out = json.loads(run("reconcile", "--ledger", str(ledger_path), "--r1", str(r1_path),
                             "--worktree", str(self.repo)).stdout)
        self.assertEqual(out["decision"], "SUCCESS")

        stale_ledger = self.repo / "specs" / "43-y" / "review-ledger.json"
        run("init", "--ledger", str(stale_ledger), "--key", "43", "--review-base", base)
        (self.repo / "app.py").write_text("x = 4\n")  # tree moves after the review
        out = json.loads(run("reconcile", "--ledger", str(stale_ledger), "--r1", str(r1_path),
                             "--worktree", str(self.repo)).stdout)
        self.assertEqual((out["decision"], out["reason"]), ("STOP", gate.STALE_REVIEW))

    def test_specs_folder_is_excluded(self):
        before = self.fp()
        (self.repo / "specs" / "42-x").mkdir(parents=True)
        (self.repo / "specs" / "42-x" / "build.jsonl").write_text("{}\n")
        self.assertEqual(before, self.fp())


if __name__ == "__main__":
    unittest.main()
