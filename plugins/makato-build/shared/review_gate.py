#!/usr/bin/env python3
"""Deterministic review gate and finding ledger for the PO-owned review loop.

The PO-agent dispatches ``build-review --round <N>`` once per round and calls
this script between rounds. The script is the only writer of
``specs/<key>-*/review-ledger.json`` and the only place that decides whether a
further repair round may start. LLM sessions execute its decision; they never
compute it.

Subcommands (all print one JSON object to stdout):

``init``          create the ledger (idempotent) and freeze the limits
``fingerprint``   hash the working tree relative to a base ref (excludes specs/)
``next-round``    the round number the PO-agent may dispatch next
``assert-round``  exit 3 unless ``--round`` is exactly that number
``repair-set``    findings the next round must repair
``reconcile``     record a finished round from its R1 and decide the outcome
``decide``        print the stored decision plus unresolved findings

Exit codes: 0 ok, 2 usage / input error, 3 refused (no round allowed).

Limits come from ``MAKATO_MAX_REPAIR_ROUNDS`` (3), ``MAKATO_MAX_FINDING_ATTEMPTS``
(2) and ``MAKATO_MAX_STAGNANT_ROUNDS`` (2). Each must be a positive integer;
anything else falls back to the default with a warning. They are frozen into
the ledger at ``init`` so a resumed run cannot change them.

Run the tests from the repo root:
    python3 -m pytest plugins/makato-build/shared/test_review_gate.py -q
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

SCHEMA = "review-ledger/v1"
BLOCKING = ("CRITICAL", "MAJOR")
SEVERITIES = ("CRITICAL", "MAJOR", "SUGGESTION", "NITPICK")
WEIGHT = {"CRITICAL": 3, "MAJOR": 1}
OPEN_STATUSES = ("open", "reopened")

LIMIT_ENV = {
    "max_repair_rounds": ("MAKATO_MAX_REPAIR_ROUNDS", 3),
    "max_finding_attempts": ("MAKATO_MAX_FINDING_ATTEMPTS", 2),
    "max_stagnant_rounds": ("MAKATO_MAX_STAGNANT_ROUNDS", 2),
}

# Reasons. SUCCESS / CONTINUE / STOP are the only decisions.
ALL_VERIFIED = "ALL_VERIFIED"
REPAIR_REQUIRED = "REPAIR_REQUIRED"
MAX_ROUNDS = "MAX_ROUNDS"
NO_PROGRESS = "NO_PROGRESS"
NO_ACTIONABLE_FINDINGS = "NO_ACTIONABLE_FINDINGS"
STALE_REVIEW = "STALE_REVIEW"
INVALID_REVIEW = "INVALID_REVIEW"

# "<file>:<line> — [<SEVERITY>][<category>] <description>" (diff-reviewer errors[])
_ERROR_LINE = re.compile(
    r"^(?P<file>[^:\s][^:]*?):(?P<line>\d+)?\s*[—-]+\s*"
    r"\[(?P<severity>[A-Z]+)\]\s*\[(?P<category>[^\]]+)\]\s*(?P<description>.+)$"
)
_FENCED_JSON = re.compile(r"```json\s*\n(.*?)\n```", re.DOTALL)


class GateError(Exception):
    """Input or usage error (exit 2)."""


class Refused(Exception):
    """A round is not allowed (exit 3)."""


# --------------------------------------------------------------------------- io


def _now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z")


def load_ledger(path: Path) -> dict[str, Any]:
    try:
        ledger = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError as exc:
        raise GateError(f"ledger not found: {path} (run init first)") from exc
    except json.JSONDecodeError as exc:
        raise GateError(f"ledger is not valid JSON: {path}: {exc}") from exc
    if ledger.get("schema") != SCHEMA:
        raise GateError(f"unsupported ledger schema: {ledger.get('schema')!r}")
    return ledger


def save_ledger(path: Path, ledger: dict[str, Any]) -> None:
    """Atomic write: a killed process leaves either the old or the new file."""
    ledger["updated_at"] = _now()
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".review-ledger.", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(ledger, handle, indent=2, sort_keys=True)
            handle.write("\n")
        os.replace(tmp, path)
    except BaseException:
        Path(tmp).unlink(missing_ok=True)
        raise


def read_limits(environ: dict[str, str]) -> tuple[dict[str, int], list[str]]:
    limits: dict[str, int] = {}
    warnings: list[str] = []
    for key, (env, default) in LIMIT_ENV.items():
        raw = environ.get(env)
        if raw is None or raw == "":
            limits[key] = default
            continue
        try:
            value = int(raw)
        except ValueError:
            value = 0
        if value < 1:
            warnings.append(f"invalid {env}={raw!r}; using {default}")
            value = default
        limits[key] = value
    return limits, warnings


def new_ledger(key: str, review_base: str | None, limits: dict[str, int]) -> dict[str, Any]:
    return {
        "schema": SCHEMA,
        "key": key,
        "review_base": review_base,
        "limits": limits,
        "rounds": [],
        "findings": {},
        "stagnant_rounds": 0,
        "last_decision": None,
        "created_at": _now(),
    }


# ----------------------------------------------------------------- fingerprint


def _git(worktree: Path, *args: str) -> bytes:
    result = subprocess.run(
        ["git", "-C", str(worktree), *args],
        capture_output=True,
        check=False,
    )
    if result.returncode != 0:
        raise GateError(f"git {' '.join(args)} failed: {result.stderr.decode(errors='replace').strip()}")
    return result.stdout


def worktree_fingerprint(worktree: Path, base: str) -> str:
    """Hash tracked changes vs ``base`` plus untracked files, excluding specs/.

    ``specs/`` is excluded because ``build.jsonl`` is un-ignored there and
    changes on every log write; it is never source under review.
    """
    digest = hashlib.sha256()
    digest.update(_git(worktree, "diff", "--binary", base, "--", ".", ":(exclude)specs"))
    untracked = _git(worktree, "ls-files", "--others", "--exclude-standard", "-z")
    for raw in sorted(p for p in untracked.split(b"\0") if p):
        rel = raw.decode("utf-8", errors="surrogateescape")
        if rel == "specs" or rel.startswith("specs/"):
            continue
        digest.update(b"\0untracked\0" + raw + b"\0")
        file_path = worktree / rel
        if file_path.is_file():
            digest.update(file_path.read_bytes())
    return "sha256:" + digest.hexdigest()


# -------------------------------------------------------------------- findings


def _norm(value: Any) -> str:
    return re.sub(r"\s+", " ", str(value or "")).strip().lower()


def finding_fingerprint(finding: dict[str, Any]) -> str:
    """``file|symbol|category|rule``; line numbers and wording drift, so they are excluded.

    When neither ``symbol`` nor ``rule`` is known (legacy ``errors[]`` parse), the
    normalised description is appended so two different findings in one file
    and category do not collapse into one.
    """
    parts = [_norm(finding.get("file")), _norm(finding.get("symbol")),
             _norm(finding.get("category")), _norm(finding.get("rule"))]
    if not parts[1] and not parts[3]:
        parts.append(_norm(finding.get("description")))
    return "|".join(parts)


def finding_id(fingerprint: str, taken: dict[str, Any]) -> str:
    full = hashlib.sha1(fingerprint.encode("utf-8")).hexdigest()
    for size in (6, 8, 10, 40):
        candidate = "RF-" + full[:size]
        existing = taken.get(candidate)
        if existing is None or existing.get("fingerprint") == fingerprint:
            return candidate
    raise GateError(f"cannot allocate a finding id for {fingerprint!r}")


def parse_r1(text: str) -> dict[str, Any] | None:
    """Accept a bare JSON object or a message whose last ```json block is the R1."""
    text = text.strip()
    if not text:
        return None
    try:
        value = json.loads(text)
        return value if isinstance(value, dict) else None
    except json.JSONDecodeError:
        pass
    blocks = _FENCED_JSON.findall(text)
    if not blocks:
        return None
    try:
        value = json.loads(blocks[-1])
    except json.JSONDecodeError:
        return None
    return value if isinstance(value, dict) else None


def extract_findings(r1: dict[str, Any]) -> tuple[list[dict[str, Any]], bool]:
    """Return blocking findings and whether the legacy ``errors[]`` fallback was used."""
    data = r1.get("data") or {}
    structured = data.get("findings")
    if isinstance(structured, list):
        found = [f for f in structured if isinstance(f, dict)]
        legacy = False
    else:
        found = []
        for line in r1.get("errors") or []:
            match = _ERROR_LINE.match(str(line).strip())
            if not match:
                continue
            found.append({
                "file": match["file"].strip(),
                "line": int(match["line"]) if match["line"] else None,
                "severity": match["severity"],
                "category": match["category"].strip(),
                "description": match["description"].strip(),
            })
        legacy = True
    blocking = []
    for finding in found:
        severity = str(finding.get("severity", "")).upper()
        if severity in BLOCKING:
            blocking.append({**finding, "severity": severity})
    return blocking, legacy


# ------------------------------------------------------------------- decisions


def next_round(ledger: dict[str, Any]) -> int:
    if not ledger["rounds"]:
        return 0
    last = ledger["last_decision"] or {}
    if last.get("decision") != "CONTINUE":
        raise Refused(
            f"review loop is terminal ({last.get('decision')}/{last.get('reason')}); no further round"
        )
    return int(last["round"]) + 1


def open_score(ledger: dict[str, Any]) -> int:
    return sum(WEIGHT[f["severity"]] for f in ledger["findings"].values()
               if f["status"] in OPEN_STATUSES)


def _unresolved(ledger: dict[str, Any]) -> list[dict[str, Any]]:
    rows = [f for f in ledger["findings"].values() if f["status"] in OPEN_STATUSES]
    rows.sort(key=lambda f: (-WEIGHT[f["severity"]], f["first_round"], f["id"]))
    return [{k: f.get(k) for k in ("id", "severity", "category", "file", "line", "symbol", "rule",
                                   "description", "evidence", "expected", "acceptance_criteria",
                                   "attempts", "status")} for f in rows]


def _invalid(r1: dict[str, Any] | None, expected_round: int) -> str | None:
    if r1 is None:
        return "R1 missing or not parseable"
    if r1.get("schema") != "r1":
        return f"R1 schema is {r1.get('schema')!r}, expected 'r1'"
    if r1.get("status") not in ("success", "failure"):
        return f"R1 status {r1.get('status')!r} is not a complete review"
    data = r1.get("data")
    if not isinstance(data, dict):
        return "R1 data missing"
    if data.get("round") != expected_round:
        return f"R1 round {data.get('round')!r} != expected {expected_round}"
    return None


def reconcile(ledger: dict[str, Any], r1: dict[str, Any] | None, current_revision: str) -> dict[str, Any]:
    """Record one finished round and decide. Idempotent per round number."""
    data = (r1 or {}).get("data") or {}
    incoming_round = data.get("round") if isinstance(data, dict) else None
    if ledger["rounds"] and incoming_round is not None and incoming_round == ledger["rounds"][-1]["round"]:
        return ledger["last_decision"]  # already reconciled (crash-safe re-run)
    expected = next_round(ledger)

    previous = ledger["last_decision"] or {}
    repaired_ids = list(previous.get("repair_ids") or []) if previous.get("decision") == "CONTINUE" else []
    record: dict[str, Any] = {
        "round": expected,
        "revision": data.get("review_revision") if isinstance(data, dict) else None,
        "current_revision": current_revision,
        "repaired_ids": repaired_ids,
        "verified_ids": [],
        "new_ids": [],
        "reopened_ids": [],
        "legacy_findings": False,
        "ts": _now(),
    }

    def finish(decision: str, reason: str, repair_ids: list[str], detail: str | None = None) -> dict[str, Any]:
        record.update({"decision": decision, "reason": reason, "repair_ids": repair_ids,
                       "open_score": open_score(ledger), "stagnant_rounds": ledger["stagnant_rounds"]})
        if detail:
            record["detail"] = detail
        ledger["rounds"].append(record)
        ledger["last_decision"] = {"round": expected, "decision": decision, "reason": reason,
                                   "repair_ids": repair_ids, "revision": record["revision"],
                                   "detail": detail}
        return ledger["last_decision"]

    problem = _invalid(r1, expected)
    if problem:
        return finish("STOP", INVALID_REVIEW, [], problem)
    assert r1 is not None
    if data.get("review_revision") != current_revision:
        return finish("STOP", STALE_REVIEW, [],
                      f"reviewed {data.get('review_revision')!r}, tree is {current_revision!r}")

    findings, legacy = extract_findings(r1)
    record["legacy_findings"] = legacy
    for key in ("critical_count", "major_count"):
        if key in data and not isinstance(data[key], int):
            return finish("STOP", INVALID_REVIEW, [], f"{key} is not an integer")
    if isinstance(data.get("critical_count"), int) and isinstance(data.get("major_count"), int):
        if data["critical_count"] + data["major_count"] != len(findings):
            return finish("STOP", INVALID_REVIEW, [],
                          f"counts {data['critical_count']}+{data['major_count']} != {len(findings)} blocking findings")
    if r1["status"] == "success" and findings:
        return finish("STOP", INVALID_REVIEW, [], "status success with blocking findings")
    if r1["status"] == "failure" and not findings:
        return finish("STOP", INVALID_REVIEW, [], "status failure without parseable blocking findings")

    # Attempts count every repair the gate asked for, whatever the repairer claimed.
    for fid in repaired_ids:
        if fid in ledger["findings"]:
            ledger["findings"][fid]["attempts"] += 1

    store = ledger["findings"]
    seen: set[str] = set()
    for finding in findings:
        fid = None
        prior = finding.get("prior_id")
        if prior in store and prior not in seen:
            fid = prior
        fingerprint = finding_fingerprint(finding)
        if fid is None:
            for candidate in store.values():
                if candidate["fingerprint"] == fingerprint and candidate["id"] not in seen:
                    fid = candidate["id"]
                    break
        if fid is None:
            loose = (_norm(finding.get("file")), _norm(finding.get("symbol")), _norm(finding.get("category")))
            matches = [c for c in store.values()
                       if c["status"] in OPEN_STATUSES and c["id"] not in seen
                       and (_norm(c.get("file")), _norm(c.get("symbol")), _norm(c.get("category"))) == loose
                       and loose[1]]
            if len(matches) == 1:
                fid = matches[0]["id"]
        if fid is None:
            if any(c["fingerprint"] == fingerprint for c in store.values()):
                fingerprint = fingerprint + "|" + _norm(finding.get("description"))
            fid = finding_id(fingerprint, store)
            store[fid] = {"id": fid, "fingerprint": fingerprint, "status": "open", "attempts": 0,
                          "first_round": expected, "history": []}
            record["new_ids"].append(fid)
        entry = store[fid]
        if entry["status"] == "verified":
            entry["status"] = "reopened"
            record["reopened_ids"].append(fid)
        for key in ("severity", "category", "file", "line", "symbol", "rule", "description",
                    "evidence", "expected", "acceptance_criteria"):
            if finding.get(key) not in (None, "", []):
                entry[key] = finding[key]
        entry["last_seen_round"] = expected
        entry["history"].append({"round": expected, "event": "seen", "severity": entry["severity"]})
        seen.add(fid)

    # A complete review that no longer reports an open finding verifies it.
    for fid, entry in store.items():
        if entry["status"] in OPEN_STATUSES and fid not in seen:
            entry["status"] = "verified"
            entry["verified_round"] = expected
            entry["history"].append({"round": expected, "event": "verified"})
            record["verified_ids"].append(fid)

    score = open_score(ledger)
    if expected > 0:
        prior_score = ledger["rounds"][-1].get("open_score", score) if ledger["rounds"] else score
        progress = score < prior_score
        record["progress"] = progress
        ledger["stagnant_rounds"] = 0 if progress else ledger["stagnant_rounds"] + 1

    limits = ledger["limits"]
    open_rows = [f for f in store.values() if f["status"] in OPEN_STATUSES]
    if not open_rows and r1["status"] == "success":
        return finish("SUCCESS", ALL_VERIFIED, [])
    if expected >= limits["max_repair_rounds"]:
        return finish("STOP", MAX_ROUNDS, [])
    if ledger["stagnant_rounds"] >= limits["max_stagnant_rounds"]:
        return finish("STOP", NO_PROGRESS, [])
    actionable = [f for f in open_rows if f["attempts"] < limits["max_finding_attempts"]]
    if not actionable:
        return finish("STOP", NO_ACTIONABLE_FINDINGS, [])
    actionable.sort(key=lambda f: (-WEIGHT[f["severity"]], f["first_round"], f["id"]))
    return finish("CONTINUE", REPAIR_REQUIRED, [f["id"] for f in actionable])


def repair_set(ledger: dict[str, Any]) -> dict[str, Any]:
    upcoming = next_round(ledger)
    last = ledger["last_decision"] or {}
    ids = list(last.get("repair_ids") or []) if last.get("decision") == "CONTINUE" else []
    findings = []
    for fid in ids:
        entry = ledger["findings"][fid]
        findings.append({k: entry.get(k) for k in (
            "id", "severity", "category", "file", "line", "symbol", "rule", "description",
            "evidence", "expected", "acceptance_criteria", "attempts")})
    return {"round": upcoming, "repair_ids": ids, "findings": findings,
            "review_base": ledger.get("review_base")}


def describe(ledger: dict[str, Any]) -> dict[str, Any]:
    last = ledger["last_decision"]
    if last is None:
        return {"decision": None, "reason": None, "round": None, "repair_ids": [],
                "unresolved": [], "rounds": 0}
    return {**last, "unresolved": _unresolved(ledger), "rounds": len(ledger["rounds"]),
            "stagnant_rounds": ledger["stagnant_rounds"], "limits": ledger["limits"]}


# ------------------------------------------------------------------------- cli


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)

    init = sub.add_parser("init")
    init.add_argument("--ledger", type=Path, required=True)
    init.add_argument("--key", required=True)
    init.add_argument("--review-base")

    fp = sub.add_parser("fingerprint")
    fp.add_argument("--worktree", type=Path, required=True)
    fp.add_argument("--base", required=True)

    for name in ("next-round", "repair-set", "decide"):
        cmd = sub.add_parser(name)
        cmd.add_argument("--ledger", type=Path, required=True)

    assert_round = sub.add_parser("assert-round")
    assert_round.add_argument("--ledger", type=Path, required=True)
    assert_round.add_argument("--round", type=int, required=True)

    rec = sub.add_parser("reconcile")
    rec.add_argument("--ledger", type=Path, required=True)
    rec.add_argument("--r1", type=Path, required=True, help="file holding the build-review R1")
    group = rec.add_mutually_exclusive_group(required=True)
    group.add_argument("--revision", help="current working-tree fingerprint")
    group.add_argument("--worktree", type=Path, help="compute the fingerprint from this worktree")
    rec.add_argument("--base", help="base ref for --worktree (default: ledger review_base)")
    return parser


def run(argv: list[str], environ: dict[str, str]) -> dict[str, Any]:
    args = _parser().parse_args(argv)
    if args.command == "init":
        if args.ledger.exists():
            ledger = load_ledger(args.ledger)
            return {"created": False, "ledger": str(args.ledger), "limits": ledger["limits"],
                    "rounds": len(ledger["rounds"]), "warnings": []}
        limits, warnings = read_limits(environ)
        ledger = new_ledger(args.key, args.review_base, limits)
        save_ledger(args.ledger, ledger)
        return {"created": True, "ledger": str(args.ledger), "limits": limits, "rounds": 0,
                "warnings": warnings}
    if args.command == "fingerprint":
        return {"revision": worktree_fingerprint(args.worktree, args.base)}

    ledger = load_ledger(args.ledger)
    if args.command == "next-round":
        return {"round": next_round(ledger)}
    if args.command == "assert-round":
        allowed = next_round(ledger)
        if args.round != allowed:
            raise Refused(f"round {args.round} not allowed; next allowed round is {allowed}")
        return {"allowed": True, "round": allowed}
    if args.command == "repair-set":
        return repair_set(ledger)
    if args.command == "decide":
        return describe(ledger)
    if args.command == "reconcile":
        if args.revision:
            revision = args.revision
        else:
            base = args.base or ledger.get("review_base")
            if not base:
                raise GateError("--base is required when the ledger has no review_base")
            revision = worktree_fingerprint(args.worktree, base)
        try:
            text = args.r1.read_text(encoding="utf-8")
        except FileNotFoundError:
            text = ""
        reconcile(ledger, parse_r1(text), revision)
        save_ledger(args.ledger, ledger)
        return describe(ledger)
    raise GateError(f"unknown command {args.command}")


def main(argv: list[str] | None = None) -> int:
    try:
        result = run(sys.argv[1:] if argv is None else argv, dict(os.environ))
    except Refused as exc:
        print(json.dumps({"allowed": False, "error": str(exc)}))
        return 3
    except GateError as exc:
        print(json.dumps({"error": str(exc)}))
        return 2
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
