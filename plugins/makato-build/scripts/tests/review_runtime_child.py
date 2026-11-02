#!/usr/bin/env python3
"""Controlled executable for OS-process recovery tests; not an LLM quality fixture."""

from __future__ import annotations

import json
import os
import runpy
import sys
import time
from pathlib import Path


def main() -> None:
    root = Path(os.environ["MAKATO_BUILD_ROOT"])
    sys.path.insert(0, str(root / "shared"))
    import review_loop
    import review_scope

    count = Path(os.environ["HARNESS_COUNT"])
    count.write_text(str(int(count.read_text()) + 1) if count.exists() else "1")
    Path(os.environ["HARNESS_ARGS"]).write_text(json.dumps(sys.argv[1:]))
    time.sleep(float(os.environ.get("HARNESS_DELAY", "0")))
    mode = os.environ.get("HARNESS_RESULT", "certified")
    if mode == "empty":
        return
    if mode == "malformed":
        print("not an R1 result")
        return
    envelope = {
        "schema": "r1",
        "agent": "build-review",
        "status": "success",
        "summary": "Controlled process and gate proof, not LLM review quality",
        "files_changed": [],
        "tests_written": [],
        "errors": [],
        "tool_calls_used": 0,
        "data": {},
    }
    if mode in {"certified", "checkpoint"}:
        worktree = Path(os.environ["WORKTREE_PATH"])
        state = os.environ["MAKATO_REVIEW_LEDGER_STATE"]
        if mode == "certified":
            # A whole review can legitimately change source bytes before certifying the new tree.
            (worktree / "src.py").write_text("value = 3\n")
        current = review_loop.gate(state, "review", str(worktree), "HEAD", expected_ac_ids=["AC-1"])
        fingerprint = current["input_fingerprint"]
        paths = review_scope.changed_files(str(worktree), "HEAD")
        if mode == "checkpoint":
            bound = json.loads(Path(state).read_text())
            paths = sorted(
                set(paths)
                | {"test_src.py"}
                | {"context:" + path for path in bound["context_paths"]}
                | {path if path.startswith("orchestrate:") else "contract:" + path for path in bound["contract_paths"]}
            )
        proof = {"file": "src.py", "line": 1}
        assert runpy.run_path(str(worktree / "src.py"))["value"] == (3 if mode == "certified" else 2)
        reviewer = {
            **envelope,
            "agent": "diff-reviewer",
            "data": {
                "reviewer_id": "controlled-reviewer",
                "input_fingerprint": fingerprint,
                "files_reviewed": len(paths),
                "file_citations": [{"file": path, "line": 1} for path in paths],
                "critical_count": 0,
                "major_count": 0,
                "findings": [],
                "lens": None,
            },
        }
        if mode == "certified":
            runpy.run_path(str(worktree / "test_src.py"))["test_value"]()
            reviewer["data"]["ac_verdicts"] = [
                {
                    "ac_id": "AC-1",
                    "ac_text": "src.py returns value 3.",
                    "verified": True,
                    "evidence": "Executed src.py and test_src.py::test_value; value == 3",
                    "citations": [
                        {**proof, "role": "implementation"},
                        {"file": "test_src.py", "line": 4, "role": "test"},
                    ],
                }
            ]
        ledger = json.loads(Path(state).read_text())
        pass_number = ledger["passes"][-1]["pass"] + 1 if ledger["passes"] else 1
        artifact = Path(state).parent / f"controlled-review-{pass_number}.json"
        artifact.write_text(json.dumps(reviewer))
        review_loop.merge(
            state, pass_number, "final-full" if mode == "certified" else "delta", ledger["max_repair_round"], review_scope.snapshot(str(worktree)), [str(artifact)], input_fingerprint=fingerprint
        )
        evidence = Path(state).parent / f"controlled-completion-{pass_number}.json"
        if mode == "certified":
            after = review_loop.gate(state, "review", str(worktree), "HEAD")["input_fingerprint"]
            evidence.write_text(
                json.dumps(
                    {
                        "input_fingerprint": fingerprint,
                        "mechanical": {
                            "before_fingerprint": fingerprint,
                            "after_fingerprint": after,
                            "no_change": fingerprint == after,
                            "evidence": "Executed behavior and recomputed unchanged source/context manifest",
                        },
                    }
                )
            )
            certified = review_loop.gate(state, "complete", str(worktree), "HEAD", evidence_path=str(evidence))
            assert certified["next_action"] == "complete", certified
            envelope["data"] = {"input_fingerprint": fingerprint, "final_review": True}
        else:
            evidence.write_text(
                json.dumps(
                    {
                        "input_fingerprint": fingerprint,
                        "pass_id": f"P-{pass_number}",
                        "scope": "delta",
                        "task_ids": ["1"],
                        "checkpoint_verified": True,
                        "final_review": False,
                        "reviewer_id": "controlled-checkpoint-verifier",
                        "independent": True,
                        "dispositions": [],
                        "evidence": "Executed completed task behavior and reviewed its current source",
                        "citations": [proof],
                    }
                )
            )
            checkpoint = review_loop.gate(state, "checkpoint", str(worktree), "HEAD", evidence_path=str(evidence))
            assert checkpoint["next_action"] == "review", checkpoint
            envelope["data"] = {
                "input_fingerprint": fingerprint,
                "final_review": False,
                "checkpoint_receipt": checkpoint["checkpoint_receipt"],
            }
        if os.environ.get("HARNESS_PUBLISH_AUDIT", "1") != "0":
            envelope["data"] = review_loop.publish_audit(state, str(worktree), "HEAD")
    print("```json")
    print(json.dumps(envelope))
    print("```")


if __name__ == "__main__":
    main()
