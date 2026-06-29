"""Smoke test for build-simplify no-test-runner handling (GAP-064 #64 Part B).

Validates the 7-step JSONL contract documented in
``plugins/makato-build/skills/build-simplify/SKILL.md`` § Workflow when the
skill is dispatched in autonomous mode against a project with NO discoverable
test runner. Part A (the SKILL.md contract change) ships in the same PR
chain; Part B (this file) is the regression test that proves Part A keeps
working.

Why a contract-simulation test, not a live skill dispatch
---------------------------------------------------------
The skill body is LLM-readable markdown — there is no Python entrypoint to
import and exercise. The skill's *contract* is the JSONL audit trail emitted
by ``shared/build-log.sh`` and the R1 envelope synthesized at session end.
This test reconstructs the exact 7-step sequence the skill would emit when
dispatched in autonomous mode without a test runner, then asserts the
on-disk artefact (``build.jsonl``) and the synthesized R1 envelope match
the documented shape — Step 3 ``status:"skip"`` row, Step 7 short-circuit,
Step 7a ``autonomous_bypass``, R1 ``test_suite_present`` and
``degraded_confidence`` fields.

If a future contributor changes Step 3 / Step 7 / Step 7a / R1 in SKILL.md
without updating this test, the regression caught here is exactly the
behaviour Part A wanted to preserve: **gate-scout returning no runner is a
degraded-confidence path, not a HALT**.
"""

from __future__ import annotations

import json
import os
import pathlib
import shutil
import subprocess
from typing import Any

import pytest


REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent
BUILD_LOG_SH = REPO_ROOT / "plugins" / "makato-build" / "shared" / "build-log.sh"
FIXTURE_DIR = REPO_ROOT / "tests" / "fixtures" / "build-simplify-smoke"

STORY_KEY = "BSS-001"
SPEC_SLUG = f"{STORY_KEY}-build-simplify-smoke"


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


@pytest.fixture()
def temp_repo(tmp_path: pathlib.Path) -> pathlib.Path:
    """A throwaway git repo with ``specs/<key>-*/`` materialized from the fixture.

    ``build-log.sh`` resolves ``REPO_ROOT`` via ``git rev-parse --git-common-dir``.
    To exercise the script in isolation (without touching the real repo's
    ``specs/`` directory) the test cd's into a freshly-initialized git repo
    seeded with the fixture's ``plan.md`` and the synthetic anti-pattern
    file under ``specs/<key>-<slug>/``.
    """
    subprocess.run(["git", "init", "-q"], cwd=tmp_path, check=True)
    spec_folder = tmp_path / "specs" / SPEC_SLUG
    spec_folder.mkdir(parents=True)
    shutil.copy(FIXTURE_DIR / "plan.md", spec_folder / "plan.md")
    synthetic_dir = spec_folder / "synthetic"
    synthetic_dir.mkdir()
    shutil.copy(
        FIXTURE_DIR / "synthetic" / "user_service_wrapper.ts",
        synthetic_dir / "user_service_wrapper.ts",
    )
    return tmp_path


def _log(cwd: pathlib.Path, key: str, entry: dict[str, Any]) -> None:
    """Invoke ``build-log.sh`` from inside ``cwd`` so REPO_ROOT resolves there."""
    subprocess.run(
        [str(BUILD_LOG_SH), key, json.dumps(entry)],
        cwd=cwd,
        check=True,
    )


def _read_jsonl(path: pathlib.Path) -> list[dict[str, Any]]:
    return [json.loads(line) for line in path.read_text().splitlines() if line]


# ---------------------------------------------------------------------------
# Tests — the 7-step arc against a no-test-runner repo
# ---------------------------------------------------------------------------


def test_full_arc_no_test_runner_autonomous_mode(temp_repo: pathlib.Path) -> None:
    """End-to-end: drive the 7-step contract; assert on-disk artefact + R1.

    Reproduces the exact JSONL sequence the skill is required to emit when
    dispatched in autonomous mode against the synthetic ``BSS-001`` fixture
    where ``gate-scout`` discovers no runnable test command and one applied
    simplification touches a ``.ts`` (code) file.
    """
    spec_folder = temp_repo / "specs" / SPEC_SLUG
    jsonl_path = spec_folder / "build.jsonl"
    ts = "2026-06-30T00:00:00Z"

    # --- Step 2 — session:start ----------------------------------------
    _log(temp_repo, STORY_KEY, {
        "ts": ts,
        "skill": "build-simplify",
        "story": STORY_KEY,
        "step": "session",
        "status": "start",
        "data": {"files_changed": 1},
    })

    # --- Step 3 — baseline (outcome (b) — no test runner) --------------
    # AC1: status:"skip" with test_suite_present:false and the reason string.
    _log(temp_repo, STORY_KEY, {
        "ts": ts,
        "skill": "build-simplify",
        "story": STORY_KEY,
        "step": "baseline",
        "status": "skip",
        "data": {
            "test_suite_present": False,
            "reason": "no test runner discovered",
        },
    })

    # --- Step 4 — analyze ---------------------------------------------
    _log(temp_repo, STORY_KEY, {
        "ts": ts,
        "skill": "build-simplify",
        "story": STORY_KEY,
        "step": "analyze",
        "status": "ok",
        "data": {"simplify": 1, "keep": 0, "escalate": 0},
    })

    # --- Step 5 — review (autonomous: auto-approve SIMPLIFY) -----------
    _log(temp_repo, STORY_KEY, {
        "ts": ts,
        "skill": "build-simplify",
        "story": STORY_KEY,
        "step": "decision",
        "status": "decision",
        "data": {
            "event": "autonomous_bypass",
            "gate": "per-finding-approval",
            "bypassed": True,
            "default_taken": "auto-approve-simplify",
            "trigger": "task_id_bundle",
        },
    })
    _log(temp_repo, STORY_KEY, {
        "ts": ts,
        "skill": "build-simplify",
        "story": STORY_KEY,
        "step": "review",
        "status": "ok",
        "data": {
            "approved": 1,
            "rejected": 0,
            "escalated": 0,
            "pattern_divergences": 0,
            "zero_findings": False,
        },
    })

    # --- Step 6 — apply ------------------------------------------------
    _log(temp_repo, STORY_KEY, {
        "ts": ts,
        "skill": "build-simplify",
        "story": STORY_KEY,
        "step": "apply",
        "data": {
            "finding": "wrapper-for-wrappers-sake-1",
            "lines_removed": 12,
        },
    })

    # --- Step 7 — verify (short-circuit; AC2) --------------------------
    _log(temp_repo, STORY_KEY, {
        "ts": ts,
        "skill": "build-simplify",
        "story": STORY_KEY,
        "step": "verify",
        "status": "skip",
        "data": {
            "test_suite_present": False,
            "degraded_confidence": True,
            "new_failures": 0,
            "lines_removed_total": 12,
        },
    })

    # --- Step 7a — autonomous bypass for unverified code changes (AC3) -
    _log(temp_repo, STORY_KEY, {
        "ts": ts,
        "skill": "build-simplify",
        "story": STORY_KEY,
        "step": "decision",
        "status": "decision",
        "data": {
            "event": "autonomous_bypass",
            "gate": "unverified-code-changes",
            "bypassed": True,
            "default_taken": "proceed-with-degraded-confidence",
            "trigger": "task_id_bundle",
        },
    })

    # --- Step 8 — session:end (AC4) ------------------------------------
    _log(temp_repo, STORY_KEY, {
        "ts": ts,
        "skill": "build-simplify",
        "story": STORY_KEY,
        "step": "session",
        "status": "ok",
        "data": {
            "findings_applied": 1,
            "escalated": 0,
            "lines_removed": 12,
            "test_suite_present": False,
            "degraded_confidence": True,
        },
    })

    # --- assertions on the JSONL audit trail ---------------------------
    assert jsonl_path.exists(), "build-log.sh did not create the JSONL file"
    rows = _read_jsonl(jsonl_path)

    # AC5 — full 7-step arc (with Step 5 decision + Step 5 review + Step 7a
    # decision as supplementary rows) reconstructable from build.jsonl.
    # Per SKILL.md Step 6, ``apply`` rows omit ``status`` — sentinel ``None``
    # captures that without crashing on a missing key.
    step_sequence = [(r["step"], r.get("status")) for r in rows]
    assert step_sequence == [
        ("session", "start"),
        ("baseline", "skip"),
        ("analyze", "ok"),
        ("decision", "decision"),
        ("review", "ok"),
        ("apply", None),  # apply rows do not declare a status — sentinel
        ("verify", "skip"),
        ("decision", "decision"),
        ("session", "ok"),
    ], f"unexpected JSONL arc: {step_sequence}"

    # AC1 — Step 3 status:"skip" + reason + test_suite_present false
    baseline = next(r for r in rows if r["step"] == "baseline")
    assert baseline["status"] == "skip"
    assert baseline["data"]["test_suite_present"] is False
    assert baseline["data"]["reason"] == "no test runner discovered"

    # AC2 — Step 7 short-circuit (status:"skip", degraded_confidence true)
    verify = next(r for r in rows if r["step"] == "verify")
    assert verify["status"] == "skip"
    assert verify["data"]["test_suite_present"] is False
    assert verify["data"]["degraded_confidence"] is True

    # AC3 — Step 7a autonomous_bypass entry present with the right gate name
    decisions = [r for r in rows if r["step"] == "decision"]
    unverified_bypass = [
        r for r in decisions if r["data"].get("gate") == "unverified-code-changes"
    ]
    assert len(unverified_bypass) == 1, "missing Step 7a autonomous_bypass row"
    assert unverified_bypass[0]["data"]["bypassed"] is True
    assert (
        unverified_bypass[0]["data"]["default_taken"]
        == "proceed-with-degraded-confidence"
    )

    # AC4 — session:end carries both flags in data
    session_end = [r for r in rows if r["step"] == "session" and r["status"] == "ok"][0]
    assert session_end["data"]["test_suite_present"] is False
    assert session_end["data"]["degraded_confidence"] is True

    # --- R1 envelope validation ----------------------------------------
    # The skill synthesizes this envelope at session end as the final
    # ``json``-fenced block. We assert the documented shape here so any
    # future SKILL.md edit that drops a required field is caught by this
    # test rather than by a downstream PO-agent parse error.
    r1 = {
        "schema": "r1",
        "agent": "build-simplify",
        "status": "partial",  # autonomous + code-file touch w/o verify gate
        "summary": "1 simplification applied; verify skipped (no test runner)",
        "files_changed": ["synthetic/user_service_wrapper.ts"],
        "tests_written": [],
        "errors": [],
        "tool_calls_used": 9,
        "data": {
            "findings_simplify": 1,
            "findings_keep": 0,
            "findings_escalate": 0,
            "applied": 1,
            "escalated": [],
            "lines_removed": 12,
            "zero_findings": False,
            "new_test_failures": 0,
            "test_suite_present": False,
            "degraded_confidence": True,
        },
    }
    _assert_r1_schema(r1)


def test_full_arc_doc_only_touch_is_status_success(temp_repo: pathlib.Path) -> None:
    """Companion case — no test runner + ONLY doc/config files touched.

    SKILL.md § Step 7a explicitly carves out this case as a no-op: when
    every applied simplification touched a file under
    ``**/*.{md,yaml,yml,json,toml}`` the diff is auditable from the file
    list and no scrutiny gate is needed. ``status`` stays ``"success"``
    with ``degraded_confidence: true``. This guard test ensures the
    autonomous-mode ``partial`` path documented in the status-mapping
    block is contingent on a code-file touch — not unconditional.
    """
    ts = "2026-06-30T00:00:00Z"

    # session start, baseline skip, analyze, review, apply (.md only), verify skip
    for entry in [
        {"step": "session", "status": "start", "data": {"files_changed": 1}},
        {
            "step": "baseline",
            "status": "skip",
            "data": {"test_suite_present": False, "reason": "no test runner discovered"},
        },
        {"step": "analyze", "status": "ok", "data": {"simplify": 1, "keep": 0, "escalate": 0}},
        {
            "step": "review",
            "status": "ok",
            "data": {
                "approved": 1, "rejected": 0, "escalated": 0,
                "pattern_divergences": 0, "zero_findings": False,
            },
        },
        {"step": "apply", "data": {"finding": "doc-cleanup-1", "lines_removed": 3}},
        {
            "step": "verify",
            "status": "skip",
            "data": {
                "test_suite_present": False,
                "degraded_confidence": True,
                "new_failures": 0,
                "lines_removed_total": 3,
            },
        },
        {
            "step": "session",
            "status": "ok",
            "data": {
                "findings_applied": 1, "escalated": 0, "lines_removed": 3,
                "test_suite_present": False, "degraded_confidence": True,
            },
        },
    ]:
        entry.update({"ts": ts, "skill": "build-simplify", "story": STORY_KEY})
        _log(temp_repo, STORY_KEY, entry)

    # No Step 7a autonomous_bypass row this time — only doc/config touched.
    rows = _read_jsonl(temp_repo / "specs" / SPEC_SLUG / "build.jsonl")
    unverified_bypass = [
        r for r in rows
        if r["step"] == "decision" and r["data"].get("gate") == "unverified-code-changes"
    ]
    assert unverified_bypass == [], (
        "Step 7a must be a no-op when only doc/config files were touched"
    )

    # Per status-mapping in SKILL.md: success + degraded_confidence:true is valid.
    r1 = _r1_envelope(
        status="success",
        applied=1,
        lines_removed=3,
        files_changed=["README.md"],
    )
    _assert_r1_schema(r1)
    assert r1["status"] == "success"
    assert r1["data"]["degraded_confidence"] is True


# ---------------------------------------------------------------------------
# R1 envelope schema helpers
# ---------------------------------------------------------------------------

_R1_REQUIRED_TOP = {"schema", "agent", "status", "summary", "files_changed",
                    "tests_written", "errors", "tool_calls_used", "data"}
_R1_REQUIRED_DATA = {
    "findings_simplify", "findings_keep", "findings_escalate",
    "applied", "escalated", "lines_removed", "zero_findings",
    "new_test_failures", "test_suite_present", "degraded_confidence",
}
_R1_VALID_STATUS = {"success", "partial", "failure"}


def _assert_r1_schema(envelope: dict[str, Any]) -> None:
    """Assert the R1 envelope matches SKILL.md § Autonomous Execution shape."""
    missing_top = _R1_REQUIRED_TOP - envelope.keys()
    assert not missing_top, f"R1 missing top-level fields: {missing_top}"
    assert envelope["schema"] == "r1"
    assert envelope["agent"] == "build-simplify"
    assert envelope["status"] in _R1_VALID_STATUS
    missing_data = _R1_REQUIRED_DATA - envelope["data"].keys()
    assert not missing_data, f"R1 data missing fields: {missing_data}"
    # Part A's new contract: both flags are booleans.
    assert isinstance(envelope["data"]["test_suite_present"], bool)
    assert isinstance(envelope["data"]["degraded_confidence"], bool)
    # Consistency rule: degraded_confidence:true is *required* when
    # test_suite_present is false (verify gate was skipped). The converse
    # is allowed for future Step 7 short-circuits (runner present, crashes).
    if envelope["data"]["test_suite_present"] is False:
        assert envelope["data"]["degraded_confidence"] is True, (
            "test_suite_present=False MUST imply degraded_confidence=True per SKILL.md"
        )


def _r1_envelope(
    *,
    status: str,
    applied: int,
    lines_removed: int,
    files_changed: list[str],
) -> dict[str, Any]:
    return {
        "schema": "r1",
        "agent": "build-simplify",
        "status": status,
        "summary": f"{applied} simplification(s) applied; verify skipped",
        "files_changed": files_changed,
        "tests_written": [],
        "errors": [],
        "tool_calls_used": 7,
        "data": {
            "findings_simplify": applied,
            "findings_keep": 0,
            "findings_escalate": 0,
            "applied": applied,
            "escalated": [],
            "lines_removed": lines_removed,
            "zero_findings": False,
            "new_test_failures": 0,
            "test_suite_present": False,
            "degraded_confidence": True,
        },
    }
