"""Finding history, lens merging, convergence and repair partitioning for the build-review repair loop.

``review_scope.py`` decides *what* the next review covers; this helper remembers
*what was found* across passes, so the loop can merge parallel lens reviews,
recognise a finding that keeps coming back, stop when repairs no longer converge
and split a round's repairs into file-disjoint groups:

    init       create (or resume) the per-story loop state file
    lenses     should this full pass be split into parallel lens reviews?
    merge      merge one or more diff-reviewer R1 results into one R1 and record the pass
    repaired   record that a repair round claimed to fix finding ids
    next       convergence decision: may another repair round start?
    partition  group a round's findings into file-disjoint repair groups
    background should a background full pass of the pre-repair tree run this round?

Input problems exit 2 with ``review-loop: <message>`` on stderr.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import tempfile
from collections.abc import Iterable
from pathlib import Path

import review_scope

LENSES = ("security-privacy", "state-concurrency", "error-handling", "resources-performance", "contract-ac")
LENS_MODES = ("auto", "on", "off")
SPLIT_MIN_CHANGED_LINES = 400
SPLIT_MIN_CHANGED_FILES = 15
DEFAULT_SOFT_CAP = 3
DEFAULT_HARD_CAP = 8
DEFAULT_MAX_GROUPS = 4
SITE_LINE_TOLERANCE = 3
SEVERITY_RANK = {"CRITICAL": 4, "MAJOR": 3, "SUGGESTION": 2, "NITPICK": 1}
BLOCKING = ("CRITICAL", "MAJOR")
REDESIGN_RECURRENCES = 2
STOP_RECURRENCES = 3
STATE_VERSION = 1
_ID_PATTERN = re.compile(r"^F-(\d+)$")


class LoopError(RuntimeError):
    """An input problem that makes the loop state unreliable."""


# ---------------------------------------------------------------- state


def _load_state(path: str) -> dict:
    try:
        with open(path, encoding="utf-8") as handle:
            state = json.load(handle)
    except FileNotFoundError:
        raise LoopError(f"no loop state at {path}; run init first") from None
    except (OSError, json.JSONDecodeError) as exc:
        raise LoopError(f"unreadable loop state {path}: {exc}") from None
    if not isinstance(state, dict) or state.get("version") != STATE_VERSION:
        raise LoopError(f"unsupported loop state in {path}")
    return state


def _save_state(path: str, state: dict) -> None:
    directory = os.path.dirname(os.path.abspath(path))
    os.makedirs(directory, exist_ok=True)
    handle, tmp = tempfile.mkstemp(prefix=".review-loop-", suffix=".json", dir=directory)
    try:
        with os.fdopen(handle, "w", encoding="utf-8") as out:
            json.dump(state, out, indent=1, sort_keys=True)
            out.write("\n")
        os.replace(tmp, path)
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise


def init(path: str, story: str, review_base: str) -> dict[str, object]:
    """Resume the state of the same story and base; anything else starts a fresh history."""
    if os.path.exists(path):
        try:
            state = _load_state(path)
        except LoopError:
            state = None
        if state is not None and state.get("story") == story and state.get("review_base") == review_base:
            return {"state": path, "resumed": True, "next_id": state["next_id"]}
    state = {"version": STATE_VERSION, "story": story, "review_base": review_base, "next_id": 1, "passes": [], "findings": {}}
    _save_state(path, state)
    return {"state": path, "resumed": False, "next_id": 1}


def _id_key(finding_id: str) -> tuple[int, str]:
    match = _ID_PATTERN.match(finding_id)
    return (int(match.group(1)), finding_id) if match else (sys.maxsize, finding_id)


def _ids(raw: str | None) -> list[str]:
    return [item.strip() for item in (raw or "").split(",") if item.strip()]


# ---------------------------------------------------------------- lenses


def lenses(worktree: str, review_base: str, mode: str | None) -> dict[str, object]:
    """Split a full pass into parallel lens reviews when the change is too large for one careful reviewer."""
    raw = mode if mode is not None else os.environ.get("MAKATO_REVIEW_LENSES")
    warning = None
    value = (raw or "auto").strip().lower() or "auto"
    if value not in LENS_MODES:
        warning = f"invalid MAKATO_REVIEW_LENSES {raw!r}; using auto"
        value = "auto"
    changed_lines = 0
    tracked: set[str] = set()
    fields = review_scope._nul_split(review_scope._git(worktree, "diff", "--numstat", "--no-renames", "-z", review_base))
    for entry in fields:
        added, deleted, path = entry.split("\t", 2)
        tracked.add(path)
        changed_lines += (int(added) if added.isdigit() else 0) + (int(deleted) if deleted.isdigit() else 0)
    untracked = review_scope._nul_split(review_scope._git(worktree, "ls-files", "--others", "--exclude-standard", "-z"))
    for path in untracked:
        text = review_scope._read_text(worktree, path)
        if text is not None:
            changed_lines += len(text.splitlines())
    changed_files = len(tracked | set(untracked))
    split = value == "on" or (value == "auto" and (changed_lines > SPLIT_MIN_CHANGED_LINES or changed_files > SPLIT_MIN_CHANGED_FILES))
    result: dict[str, object] = {"split": split, "lenses": list(LENSES) if split else [], "changed_lines": changed_lines, "changed_files": changed_files, "mode": value}
    if warning:
        result["warning"] = warning
    return result


# ---------------------------------------------------------------- merge


def _parse_r1(path: str) -> dict:
    """The R1 object of a reviewer result: a plain JSON file, or the last JSON object in a transcript."""
    try:
        text = Path(path).read_text(encoding="utf-8")
    except OSError as exc:
        raise LoopError(f"cannot read {path}: {exc}") from None
    try:
        value = json.loads(text)
    except json.JSONDecodeError:
        value = None
        decoder = json.JSONDecoder()
        index = 0
        while (start := text.find("{", index)) != -1:
            try:
                candidate, end = decoder.raw_decode(text, start)
            except json.JSONDecodeError:
                index = start + 1
                continue
            if isinstance(candidate, dict):
                value = candidate
            index = end
    if not isinstance(value, dict):
        raise LoopError(f"{path}: no R1 JSON object")
    return value


def _site(raw: object, where: str) -> dict:
    if not isinstance(raw, dict) or not isinstance(raw.get("file"), str) or not raw["file"] or isinstance(raw.get("line"), bool) or not isinstance(raw.get("line"), int):
        raise LoopError(f"{where}: every site needs a file and an integer line")
    site = {"file": raw["file"], "line": raw["line"]}
    if raw.get("note"):
        site["note"] = raw["note"]
    return site


def _validated_findings(path: str, r1: dict) -> list[dict]:
    data = r1.get("data")
    if not isinstance(data, dict) or not isinstance(data.get("findings"), list):
        raise LoopError(f"{path}: data.findings must be a list")
    findings: list[dict] = []
    counts: dict[str, int] = dict.fromkeys(BLOCKING, 0)
    for number, raw in enumerate(data["findings"], start=1):
        where = f"{path}: finding {number}"
        if not isinstance(raw, dict) or raw.get("severity") not in SEVERITY_RANK:
            raise LoopError(f"{where}: severity must be one of {', '.join(SEVERITY_RANK)}")
        finding = dict(raw)
        finding["lens"] = raw.get("lens") or data.get("lens")
        if finding["severity"] in BLOCKING:
            counts[finding["severity"]] += 1
            if not isinstance(raw.get("invariant"), str) or not raw["invariant"].strip():
                raise LoopError(f"{where}: a blocking finding needs an invariant")
            if not isinstance(raw.get("sites"), list) or not raw["sites"]:
                raise LoopError(f"{where}: a blocking finding needs at least one site")
            finding["sites"] = [_site(site, where) for site in raw["sites"]]
        elif isinstance(raw.get("sites"), list) and raw["sites"]:
            finding["sites"] = [_site(site, where) for site in raw["sites"]]
        elif isinstance(raw.get("file"), str) and isinstance(raw.get("line"), int) and not isinstance(raw.get("line"), bool):
            finding["sites"] = [{"file": raw["file"], "line": raw["line"]}]
        else:
            finding["sites"] = []
        findings.append(finding)
    for severity, field in (("CRITICAL", "critical_count"), ("MAJOR", "major_count")):
        if data.get(field) != counts[severity]:
            raise LoopError(f"{path}: data.{field}={data.get(field)!r} but {counts[severity]} {severity} finding(s) listed")
    return findings


def _near(left: list[dict], right: list[dict]) -> bool:
    return any(a["file"] == b["file"] and abs(a["line"] - b["line"]) <= SITE_LINE_TOLERANCE for a in left for b in right)


def _components(count: int, linked: Iterable[tuple[int, int]]) -> list[list[int]]:
    parent = list(range(count))

    def find(item: int) -> int:
        while parent[item] != item:
            parent[item] = parent[parent[item]]
            item = parent[item]
        return item

    for left, right in linked:
        root_left, root_right = find(left), find(right)
        if root_left != root_right:
            parent[max(root_left, root_right)] = min(root_left, root_right)
    groups: dict[int, list[int]] = {}
    for item in range(count):
        groups.setdefault(find(item), []).append(item)
    return sorted(groups.values(), key=lambda members: members[0])


def _known_id(finding: dict, state: dict) -> str | None:
    value = finding.get("id")
    return value if isinstance(value, str) and value in state["findings"] else None


def merge(state_path: str, pass_number: int, scope: str, after_round: int, snapshot: str | None, drop_ids: list[str], r1_files: list[str]) -> dict:
    """Merge reviewer R1 results into one R1 and record the pass; the state changes only if every input is valid."""
    state = _load_state(state_path)
    inputs = [(path, _parse_r1(path)) for path in r1_files]
    if not inputs:
        raise LoopError("merge needs at least one R1 file")
    findings = [finding for path, r1 in inputs for finding in _validated_findings(path, r1)]
    if drop_ids:
        dropped_sites = [site for finding_id in drop_ids for site in state["findings"].get(finding_id, {}).get("sites", [])]
        findings = [finding for finding in findings if finding.get("id") not in drop_ids and not _near(finding["sites"], dropped_sites)]

    pairs = []
    for left in range(len(findings)):
        for right in range(left + 1, len(findings)):
            same_id = findings[left].get("id") not in (None, "new") and findings[left].get("id") == findings[right].get("id")
            if same_id or _near(findings[left]["sites"], findings[right]["sites"]):
                pairs.append((left, right))

    merged: list[dict] = []
    new_blocking: list[str] = []
    for members in _components(len(findings), pairs):
        group = [findings[index] for index in members]
        lead = max(group, key=lambda finding: SEVERITY_RANK[finding["severity"]])  # max() keeps the first of equals
        prior = sorted({known for finding in group if (known := _known_id(finding, state))}, key=_id_key)
        if prior:
            finding_id = prior[0]
        else:
            finding_id = f"F-{state['next_id']:03d}"
            state["next_id"] += 1
        sites: dict[tuple[str, int], dict] = {}
        for finding in group:
            for site in finding["sites"]:
                sites.setdefault((site["file"], site["line"]), site)
        result = {key: lead.get(key) for key in ("severity", "category", "invariant", "file", "line", "evidence", "description")}
        result["id"] = finding_id
        result["sites"] = [sites[key] for key in sorted(sites)]
        result["lenses"] = sorted({finding["lens"] for finding in group if finding.get("lens")})
        if len(prior) > 1:
            result["merged_ids"] = prior[1:]
        merged.append(result)

    merged.sort(key=lambda finding: (-SEVERITY_RANK[finding["severity"]], _id_key(finding["id"])))
    blocking = [finding for finding in merged if finding["severity"] in BLOCKING]
    for finding in merged:
        record = state["findings"].setdefault(finding["id"], {"raised_in": [], "repair_claims": []})
        record.update({"severity": finding["severity"], "invariant": finding["invariant"], "file": finding["file"], "sites": [{"file": s["file"], "line": s["line"]} for s in finding["sites"]]})
        if finding["severity"] in BLOCKING:
            if not record["raised_in"]:
                new_blocking.append(finding["id"])
            record["raised_in"].append({"pass": pass_number, "after_round": after_round})
    state["passes"].append({"pass": pass_number, "scope": scope, "after_round": after_round, "snapshot": snapshot, "blocking": [f["id"] for f in blocking], "new_blocking": new_blocking})

    counts = {severity: sum(1 for finding in merged if finding["severity"] == severity) for severity in SEVERITY_RANK}
    statuses = [r1.get("status") for _, r1 in inputs]
    status = "partial" if "partial" in statuses else ("failure" if counts["CRITICAL"] + counts["MAJOR"] else "success")
    contract = [r1 for _, r1 in inputs if r1["data"].get("lens") == "contract-ac"]
    if contract:
        verdicts = contract[0]["data"].get("ac_verdicts") or []
    elif len(inputs) == 1:
        verdicts = inputs[0][1]["data"].get("ac_verdicts") or []
    else:
        verdicts = []
    reviewed = [r1["data"].get("files_reviewed") for _, r1 in inputs]
    _save_state(state_path, state)
    return {
        "schema": "r1",
        "agent": "diff-reviewer",
        "status": status,
        "summary": f"merged {len(inputs)} reviewer result(s)",
        "files_changed": [],
        "tests_written": [],
        "errors": [f"{f['file']}:{f['line']} — [{f['severity']}][{f['category']}] {f['description']}" for f in blocking],
        "data": {
            "pass_number": pass_number,
            "review_scope": scope,
            "lenses": sorted({lens for _, r1 in inputs if (lens := r1["data"].get("lens"))}),
            "critical_count": counts["CRITICAL"],
            "major_count": counts["MAJOR"],
            "suggestion_count": counts["SUGGESTION"],
            "nitpick_count": counts["NITPICK"],
            "files_reviewed": max((value for value in reviewed if isinstance(value, int) and not isinstance(value, bool)), default=0),
            "findings": merged,
            "ac_verdicts": verdicts,
        },
    }


# ---------------------------------------------------------------- repairs and convergence


def repaired(state_path: str, repair_round: int, ids: list[str]) -> dict[str, object]:
    state = _load_state(state_path)
    unknown = [finding_id for finding_id in ids if finding_id not in state["findings"]]
    if unknown:
        raise LoopError(f"unknown finding id(s): {', '.join(unknown)}")
    for finding_id in ids:
        claims = state["findings"][finding_id]["repair_claims"]
        if repair_round not in claims:
            claims.append(repair_round)
    _save_state(state_path, state)
    return {"round": repair_round, "ids": ids}


def recurrences(record: dict) -> int:
    """Repair claims that a later review contradicted by raising the finding again."""
    raised_after = [raise_["after_round"] for raise_ in record["raised_in"]]
    return sum(1 for claim in record["repair_claims"] if any(after >= claim for after in raised_after))


def _cap(raw: str | None, default: int, name: str, warnings: list[str]) -> int:
    if raw is None or raw.strip() == "":
        return default
    value = raw.strip()
    if value.isdigit() and int(value) > 0:
        return int(value)
    warnings.append(f"invalid {name} {raw!r}; using {default}")
    return default


def next_round(state_path: str, repair_rounds: int, open_ids: list[str], soft_cap: str | None, hard_cap: str | None) -> dict[str, object]:
    state = _load_state(state_path)
    unknown = [finding_id for finding_id in open_ids if finding_id not in state["findings"]]
    if unknown:
        raise LoopError(f"unknown finding id(s): {', '.join(unknown)}")
    warnings: list[str] = []
    soft = _cap(soft_cap if soft_cap is not None else os.environ.get("MAKATO_MAX_REPAIR_ROUNDS"), DEFAULT_SOFT_CAP, "MAKATO_MAX_REPAIR_ROUNDS", warnings)
    hard = _cap(hard_cap if hard_cap is not None else os.environ.get("MAKATO_MAX_REPAIR_ROUNDS_HARD"), DEFAULT_HARD_CAP, "MAKATO_MAX_REPAIR_ROUNDS_HARD", warnings)
    if hard < soft:
        warnings.append(f"MAKATO_MAX_REPAIR_ROUNDS_HARD {hard} is below the soft cap {soft}; using {soft}")
        hard = soft

    counts = {finding_id: recurrences(state["findings"][finding_id]) for finding_id in open_ids}
    new_by_round: dict[int, int] = {}
    for record in state["findings"].values():
        if record["raised_in"]:
            first = record["raised_in"][0]["after_round"]
            new_by_round[first] = new_by_round.get(first, 0) + 1
    recurring = sorted((finding_id for finding_id, count in counts.items() if count >= STOP_RECURRENCES), key=_id_key)
    redesign = sorted((finding_id for finding_id, count in counts.items() if count == REDESIGN_RECURRENCES), key=_id_key)

    if recurring:
        go, reason = False, "recurring_finding"
    elif repair_rounds >= hard:
        go, reason = False, "hard_cap"
    elif repair_rounds < soft:
        go, reason = True, "within_soft_cap"
    else:
        new_last, new_prev = new_by_round.get(repair_rounds, 0), new_by_round.get(repair_rounds - 1, 0)
        go = new_last == 0 or new_last < new_prev
        reason = "converging" if go else "not_converging"
    return {
        "continue": go,
        "reason": reason,
        "redesign_ids": redesign,
        "recurring_ids": recurring,
        "new_by_round": {str(key): new_by_round[key] for key in sorted(new_by_round)},
        "soft_cap": soft,
        "hard_cap": hard,
        "warnings": warnings,
    }


def partition(findings_path: str, ids: list[str], max_groups: int) -> dict[str, list[dict]]:
    """File-disjoint repair groups: findings that share a site file stay with one coder."""
    if max_groups < 1:
        raise LoopError("--max-groups must be at least 1")
    r1 = _parse_r1(findings_path)
    raw_data = r1.get("data")
    data: dict = raw_data if isinstance(raw_data, dict) else {}
    by_id = {finding.get("id"): finding for finding in data.get("findings") or [] if isinstance(finding, dict)}
    unknown = [finding_id for finding_id in ids if finding_id not in by_id]
    if unknown:
        raise LoopError(f"{findings_path}: unknown finding id(s): {', '.join(unknown)}")
    chosen = sorted(set(ids), key=_id_key)
    files = [
        {site["file"] for site in by_id[finding_id].get("sites") or [] if isinstance(site, dict) and site.get("file")} | ({by_id[finding_id]["file"]} if by_id[finding_id].get("file") else set())
        for finding_id in chosen
    ]
    pairs = [(left, right) for left in range(len(chosen)) for right in range(left + 1, len(chosen)) if files[left] & files[right]]
    groups = [{"ids": [chosen[index] for index in members], "files": set().union(*(files[index] for index in members))} for members in _components(len(chosen), pairs)]
    while len(groups) > max_groups:
        order = sorted(range(len(groups)), key=lambda index: (len(groups[index]["files"]), index))
        keep, absorb = sorted(order[:2])
        groups[keep] = {"ids": sorted(groups[keep]["ids"] + groups[absorb]["ids"], key=_id_key), "files": groups[keep]["files"] | groups[absorb]["files"]}
        del groups[absorb]
        groups.sort(key=lambda group: _id_key(group["ids"][0]))
    return {"groups": [{"group": number, "ids": group["ids"], "files": sorted(group["files"])} for number, group in enumerate(groups, start=1)]}


def background(state_path: str, repair_round: int, mode: str | None) -> dict[str, object]:
    resolved, warning = review_scope.resolve_mode(mode if mode is not None else os.environ.get("MAKATO_REVIEW_SCOPE"))
    state = _load_state(state_path)
    previous = [entry for entry in state["passes"] if entry["scope"] == "background-full"]
    if resolved == "full":
        result: dict[str, object] = {"run": False, "reason": "legacy full mode reviews everything every pass"}
    elif repair_round < 2:
        result = {"run": False, "reason": "round 1 relies on the full first pass"}
    elif not previous:
        result = {"run": True, "reason": "first background full pass"}
    elif previous[-1]["new_blocking"]:
        result = {"run": True, "reason": "last background pass found new blockers"}
    else:
        result = {"run": False, "reason": "last background pass found nothing new"}
    if warning:
        result["warning"] = warning
    return result


# ---------------------------------------------------------------- CLI


def _main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)

    cmd = sub.add_parser("init", help="create or resume the loop state")
    cmd.add_argument("--state", required=True)
    cmd.add_argument("--story", required=True)
    cmd.add_argument("--review-base", required=True)

    cmd = sub.add_parser("lenses", help="lens-split decision for a full pass")
    cmd.add_argument("--worktree", required=True)
    cmd.add_argument("--review-base", required=True)
    cmd.add_argument("--mode", default=None, help="auto|on|off; defaults to $MAKATO_REVIEW_LENSES")

    cmd = sub.add_parser("merge", help="merge reviewer R1 files and record the pass")
    cmd.add_argument("--state", required=True)
    cmd.add_argument("--pass", dest="pass_number", type=int, required=True)
    cmd.add_argument("--scope", required=True, choices=("full", "delta", "final-full", "background-full"))
    cmd.add_argument("--after-round", type=int, required=True)
    cmd.add_argument("--snapshot", default=None)
    cmd.add_argument("--drop-ids", default="")
    cmd.add_argument("r1_files", nargs="+")

    cmd = sub.add_parser("repaired", help="record a repair round's claimed fixes")
    cmd.add_argument("--state", required=True)
    cmd.add_argument("--round", dest="repair_round", type=int, required=True)
    cmd.add_argument("--ids", required=True)

    cmd = sub.add_parser("next", help="may another repair round start?")
    cmd.add_argument("--state", required=True)
    cmd.add_argument("--repair-rounds", type=int, required=True)
    cmd.add_argument("--open", dest="open_ids", default="")
    cmd.add_argument("--soft-cap", default=None)
    cmd.add_argument("--hard-cap", default=None)

    cmd = sub.add_parser("partition", help="file-disjoint repair groups")
    cmd.add_argument("--findings", required=True, help="merged R1 file")
    cmd.add_argument("--ids", required=True)
    cmd.add_argument("--max-groups", type=int, default=DEFAULT_MAX_GROUPS)

    cmd = sub.add_parser("background", help="should a background full pass run this round?")
    cmd.add_argument("--state", required=True)
    cmd.add_argument("--repair-round", type=int, required=True)
    cmd.add_argument("--mode", default=None, help="delta|full; defaults to $MAKATO_REVIEW_SCOPE")

    args = parser.parse_args(argv)
    try:
        if args.command == "init":
            result: object = init(args.state, args.story, args.review_base)
        elif args.command == "lenses":
            result = lenses(args.worktree, args.review_base, args.mode)
        elif args.command == "merge":
            result = merge(args.state, args.pass_number, args.scope, args.after_round, args.snapshot, _ids(args.drop_ids), args.r1_files)
        elif args.command == "repaired":
            result = repaired(args.state, args.repair_round, _ids(args.ids))
        elif args.command == "next":
            result = next_round(args.state, args.repair_rounds, _ids(args.open_ids), args.soft_cap, args.hard_cap)
        elif args.command == "partition":
            result = partition(args.findings, _ids(args.ids), args.max_groups)
        else:
            result = background(args.state, args.repair_round, args.mode)
    except (LoopError, review_scope.ScopeError) as exc:
        print(f"review-loop: {exc}", file=sys.stderr)
        return 2
    print(json.dumps(result))
    return 0


if __name__ == "__main__":
    raise SystemExit(_main(sys.argv[1:]))
