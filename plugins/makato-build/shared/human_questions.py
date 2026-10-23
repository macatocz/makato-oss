#!/usr/bin/env python3
"""human_questions.py — batched questions for a human from an autonomous build skill.

An autonomous skill must never block on an interactive prompt. When it hits a
decision it cannot settle from the code, it asks through the ticket instead:

  post     move the board card to Blocked (verified by re-reading it), then post
           ONE GitHub issue comment with ALL open questions (each with lettered
           options and exactly one recommendation) and write an
           `awaiting-answers-<issue>.json` marker next to the spec artefacts.
           When the card cannot be blocked and observed (no board configured,
           issue not on the board, write refused) NOTHING is posted and the
           result is `{"state": "unavailable"}`: nobody could ever see the
           "moved back" signal, so the caller must decide with the recommended
           options instead of waiting. A failed comment puts the card back.
  status   what the board says now: waiting | answered | expired | closed |
           unobservable | none. This is what the loop polls for every parked ticket.
  wait     poll `status` until the human moves the card back to Ready or
           In progress. Returns in slices (--timeout) so one tool call never
           outlives the host's shell limit; call it again to keep waiting.
  collect  read the human's replies written after the question comment, merge
           them per question, fall back to the recommended option for anything
           left unanswered, and claim the card (Ready -> In progress; after an
           expiry also Blocked -> In progress).
  resolve  delete the marker; optionally post a closing comment that lists
           what was applied.

Moving the card back IS the "I have answered" signal; the replies are read only
then. MAKATO_QUESTIONS_MAX_WAIT_SECS (default 0 = wait forever) turns a wait that
is too long into `expired`, and `collect` then applies the recommendations. An
answer that is free text (or picks an option flagged `followup`) is reported with
`followup: true` so the skill can raise a NEW round with just the questions that
answer created. Rounds are capped (--max-rounds).

Questions file (`post --questions-file`):

  {"intro": "optional text",
   "questions": [{"id": "Q1", "title": "...", "context": "...",
                  "options": [{"id": "A", "label": "...", "why": "...", "recommended": true,
                               "followup": false, "effect": "what the skill records if chosen"}, ...]}]}

Reply format the human is asked to use (one line per question):

  Q1: A
  Q2: B - optional note
  Q3: free text when no option fits
  all: recommended

Exit codes: 0 ok / answered; 2 usage or invalid questions; 3 GitHub failure;
5 round limit reached; 10 still waiting (slice elapsed); 11 board not
observable; 12 max wait expired; 13 issue closed.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path

MARKER_PREFIX = "awaiting-answers-"
COMMENT_MARKER = "<!-- makato:questions"
BLOCKED = "Blocked"
DEFAULT_ANSWER_STATUSES = ("Ready", "In progress")
MAX_COMMENT_CHARS = 60000
GH_TIMEOUT_SECS = 60

EXIT_OK = 0
EXIT_USAGE = 2
EXIT_GITHUB = 3
EXIT_ROUND_LIMIT = 5
EXIT_WAITING = 10
EXIT_UNOBSERVABLE = 11
EXIT_EXPIRED = 12
EXIT_CLOSED = 13

_BOARD_QUERY = (
    "query($owner:String!,$name:String!,$number:Int!){repository(owner:$owner,name:$name){issue(number:$number){state "
    'projectItems(first:20){nodes{id project{id} fieldValueByName(name:"Status"){... on ProjectV2ItemFieldSingleSelectValue{name optionId}}}}}}}'
)
_Q_LINE = re.compile(r"^\s*(?:[-*]\s+)?(?:Q\s*(\d+)\s*[:.)=\-\u2013\u2014]|(\d+)\s*[:)=])\s*(\S.*?)\s*$", re.IGNORECASE)
_ALL_LINE = re.compile(r"^\s*(?:all|v[sš]e|everything)\s*[:=]\s*(\S.*?)\s*$", re.IGNORECASE)
_ACCEPT_WORD = re.compile(r"^(?:recommended|recommendations?|default|defaults|ok|yes|ano|doporu\w*)\b", re.IGNORECASE)
_OPTION_VALUE = re.compile(r"^([A-Za-z])(?:\s*[:,;.)\-\u2013\u2014]+\s*(.*))?$")


class HqError(Exception):
    """A failure with a specific exit code."""

    def __init__(self, message: str, code: int = EXIT_USAGE) -> None:
        super().__init__(message)
        self.code = code


def _now() -> str:
    now = datetime.now(timezone.utc)
    return now.strftime("%Y-%m-%dT%H:%M:%S.") + f"{now.microsecond // 1000:03d}Z"


def _epoch(iso: str) -> float:
    return datetime.strptime(iso, "%Y-%m-%dT%H:%M:%S.%fZ").replace(tzinfo=timezone.utc).timestamp()


# --------------------------------------------------------------------------- GitHub


def _gh(args: list[str], *, host: str = "", cwd: str | None = None, input_text: str | None = None) -> str:
    env = {**os.environ, "GH_PROMPT_DISABLED": "1", "GH_NO_UPDATE_NOTIFIER": "1"}
    if host and host != "github.com":
        env["GH_HOST"] = host
    try:
        result = subprocess.run(["gh", *args], capture_output=True, text=True, input=input_text, cwd=cwd, env=env, timeout=GH_TIMEOUT_SECS, check=False)
    except subprocess.TimeoutExpired as exc:
        raise HqError("GitHub CLI timed out", EXIT_GITHUB) from exc
    except OSError as exc:
        raise HqError(f"Cannot execute the GitHub CLI: {exc.strerror}", EXIT_GITHUB) from exc
    if result.returncode:
        first = (result.stderr.strip().splitlines() or ["no error output"])[0][:200]
        raise HqError(f"gh {args[0]} failed: {first}", EXIT_GITHUB)
    return result.stdout


def _project_config(root: str) -> dict:
    path = Path(root) / ".claude" / "config.json"
    try:
        value = json.loads(path.read_text(encoding="utf-8")).get("github_project")
    except (OSError, ValueError):  # fmt: skip
        return {}
    return value if isinstance(value, dict) else {}


def _derive_repo(root: str, host: str) -> str:
    out = _gh(["repo", "view", "--json", "nameWithOwner", "-q", ".nameWithOwner"], host=host, cwd=root).strip()
    if not re.fullmatch(r"[^/\s]+/[^/\s]+", out):
        raise HqError("Cannot determine the repository; pass --repo owner/name", EXIT_GITHUB)
    return out


class Board:
    """The one board card (and issue state) the questions are attached to."""

    def __init__(self, repo: str, issue: int, cfg: dict) -> None:
        self.repo = repo
        self.issue = issue
        self.cfg = cfg
        self.host = str(cfg.get("host") or "github.com")
        status = (cfg.get("fields") or {}).get("status") or {}
        self.field_id = status.get("id") or cfg.get("status_field_id") or ""
        self.options = status.get("options") or cfg.get("options") or {}
        self.project_id = cfg.get("project_node_id") or ""

    @property
    def configured(self) -> bool:
        return bool(self.field_id and self.project_id)

    def read(self) -> dict:
        owner, name = self.repo.split("/", 1)
        raw = _gh(["api", "graphql", "-f", f"query={_BOARD_QUERY}", "-f", f"owner={owner}", "-f", f"name={name}", "-F", f"number={self.issue}"], host=self.host)
        try:
            issue = json.loads(raw)["data"]["repository"]["issue"]
            nodes = issue["projectItems"]["nodes"]
        except (ValueError, KeyError, TypeError) as exc:  # fmt: skip
            raise HqError("Unexpected GitHub GraphQL response for the board card", EXIT_GITHUB) from exc
        node = next((n for n in nodes if not self.project_id or (n.get("project") or {}).get("id") == self.project_id), None)
        value = ((node or {}).get("fieldValueByName") or {}).get("name")
        return {"issue_state": issue.get("state"), "status": value, "item_id": (node or {}).get("id")}

    def set_status(self, item_id: str, option_key: str) -> bool:
        option_id = self.options.get(option_key)
        if not (self.configured and item_id and option_id):
            return False
        try:
            _gh(["project", "item-edit", "--id", item_id, "--project-id", self.project_id, "--field-id", self.field_id, "--single-select-option-id", option_id], host=self.host)
        except HqError:
            return False
        return True


# --------------------------------------------------------------------------- questions


def validate_questions(doc: object) -> tuple[str, list[dict]]:
    if not isinstance(doc, dict) or not isinstance(doc.get("questions"), list) or not doc["questions"]:
        raise HqError("questions file must be an object with a non-empty 'questions' list")
    seen: set[str] = set()
    questions: list[dict] = []
    for q in doc["questions"]:
        if not isinstance(q, dict):
            raise HqError("every question must be an object")
        qid = str(q.get("id", ""))
        if not re.fullmatch(r"Q\d+", qid) or qid in seen:
            raise HqError(f"question id must be unique and look like Q1, Q2 ... (got {qid!r})")
        seen.add(qid)
        if not str(q.get("title", "")).strip():
            raise HqError(f"{qid}: title is required")
        options = q.get("options")
        if not isinstance(options, list) or len(options) < 2:
            raise HqError(f"{qid}: at least two options are required")
        ids: set[str] = set()
        for opt in options:
            oid = str(opt.get("id", "")) if isinstance(opt, dict) else ""
            if not re.fullmatch(r"[A-Z]", oid) or oid in ids or not str(opt.get("label", "")).strip():
                raise HqError(f"{qid}: option ids must be unique single capital letters with a label (got {oid!r})")
            ids.add(oid)
        if sum(1 for opt in options if opt.get("recommended") is True) != 1:
            raise HqError(f"{qid}: exactly one option must be marked recommended")
        questions.append(q)
    return str(doc.get("intro", "")).strip(), questions


def render_comment(key: str, issue: int, round_no: int, max_rounds: int, intro: str, questions: list[dict], skill: str) -> str:
    follow_up = round_no > 1
    head = "Follow-up questions" if follow_up else "Decisions needed before implementation"
    lines = [
        f"{COMMENT_MARKER} v1 key={key} issue={issue} round={round_no} -->",
        f"### {head} (round {round_no} of {max_rounds})",
        "",
        intro or (f"`{skill}` found decisions it cannot settle from the code alone." if not follow_up else "Your previous answers raised these additional questions."),
        "",
        (
            "This ticket is parked in **Blocked** while the build pipeline waits for you. Reply in **one comment**, then move the card back to **Ready** or "
            "**In progress** and the pipeline resumes. Anything you leave unanswered takes the recommended option."
        ),
        "",
    ]
    for q in questions:
        lines += ["---", "", f"**{q['id']} \u2014 {str(q['title']).strip()}**", ""]
        if str(q.get("context", "")).strip():
            lines += [str(q["context"]).strip(), ""]
        for opt in q["options"]:
            text = f"- **{opt['id']}** \u2014 {str(opt['label']).strip()}"
            if str(opt.get("why", "")).strip():
                text += f" \u2014 {str(opt['why']).strip()}"
            if opt.get("recommended") is True:
                text += " **(recommended)**"
            if opt.get("followup") is True:
                text += " _(may raise a follow-up question)_"
            lines.append(text)
        lines.append("")
    first = questions[0]["id"]
    lines += [
        "---",
        "",
        "**How to answer** \u2014 one line per question:",
        "",
        "```text",
        f"{first}: {questions[0]['options'][0]['id']}",
        f"{questions[-1]['id']}: {questions[-1]['options'][-1]['id']} - optional note",
        "Q9: free text when no option fits",
        "```",
        "",
        "Write `all: recommended` to accept every recommendation.",
    ]
    body = "\n".join(lines) + "\n"
    if len(body) > MAX_COMMENT_CHARS:
        raise HqError(f"rendered comment is {len(body)} characters; GitHub's limit is 65536 — shorten the questions")
    return body


def _recommended(question: dict) -> str:
    return next(o["id"] for o in question["options"] if o.get("recommended") is True)


def parse_answers(bodies: list[str], questions: list[dict]) -> tuple[dict, bool]:
    """Merge reply comments (oldest first; a later line wins) into {qid: {choice, text, note}} and an accept-all flag."""
    by_id = {q["id"]: {o["id"] for o in q["options"]} for q in questions}
    answers: dict[str, dict] = {}
    accept_all = False
    for body in bodies:
        for raw in body.replace("**", "").splitlines():
            line = raw.strip().strip("`")
            if not line or line.startswith(">"):
                continue
            all_match = _ALL_LINE.match(line)
            if all_match:
                accept_all = bool(_ACCEPT_WORD.match(all_match.group(1)))
                continue
            match = _Q_LINE.match(line)
            if not match:
                continue
            qid = f"Q{int(match.group(1) or match.group(2))}"
            if qid not in by_id:
                continue
            value = match.group(3).strip()
            if _ACCEPT_WORD.match(value) and not _OPTION_VALUE.match(value):
                answers[qid] = {"choice": None, "text": None, "note": None, "accepted_recommended": True}
                continue
            opt = _OPTION_VALUE.match(value)
            if opt and opt.group(1).upper() in by_id[qid]:
                answers[qid] = {"choice": opt.group(1).upper(), "text": None, "note": (opt.group(2) or "").strip() or None, "accepted_recommended": False}
            else:
                answers[qid] = {"choice": None, "text": value, "note": None, "accepted_recommended": False}
    return answers, accept_all


def merge_answers(questions: list[dict], parsed: dict, accept_all: bool) -> dict:
    merged: dict[str, dict] = {}
    for q in questions:
        qid = q["id"]
        got = parsed.get(qid)
        rec = _recommended(q)
        if got is None:
            merged[qid] = {"choice": rec, "text": None, "note": None, "source": "user-accept-all" if accept_all else "recommended", "followup": False}
            continue
        if got["accepted_recommended"]:
            merged[qid] = {"choice": rec, "text": None, "note": None, "source": "user", "followup": False}
            continue
        flagged = bool(got["choice"]) and any(o["id"] == got["choice"] and o.get("followup") is True for o in q["options"])
        merged[qid] = {"choice": got["choice"], "text": got["text"], "note": got["note"], "source": "user", "followup": got["choice"] is None or flagged}
    return merged


# --------------------------------------------------------------------------- marker


def marker_path(spec_dir: str, issue: int) -> Path:
    return Path(spec_dir) / f"{MARKER_PREFIX}{issue}.json"


def load_marker(spec_dir: str, issue: int) -> dict | None:
    path = marker_path(spec_dir, issue)
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return None
    except (OSError, ValueError) as exc:  # fmt: skip
        raise HqError(f"unreadable marker {path}: {exc}") from exc
    return value if isinstance(value, dict) else None


def save_marker(spec_dir: str, issue: int, marker: dict) -> None:
    marker["updated_at"] = _now()
    path = marker_path(spec_dir, issue)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=str(path.parent), prefix=f".{MARKER_PREFIX}", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(marker, handle, indent=2, ensure_ascii=False)
            handle.write("\n")
        os.replace(tmp, path)
    except BaseException:
        Path(tmp).unlink(missing_ok=True)
        raise


def _require_marker(spec_dir: str, issue: int) -> dict:
    marker = load_marker(spec_dir, issue)
    if marker is None:
        raise HqError(f"no {MARKER_PREFIX}{issue}.json in {spec_dir}; nothing is awaiting answers")
    return marker


def _board_for(marker: dict) -> Board:
    return Board(marker["repo"], int(marker["issue"]), _project_config(marker.get("root") or "."))


def _answer_statuses() -> tuple[str, ...]:
    raw = os.environ.get("MAKATO_QUESTIONS_ANSWER_STATUSES", "")
    parsed = tuple(s.strip() for s in raw.split(",") if s.strip())
    return parsed or DEFAULT_ANSWER_STATUSES


def evaluate(marker: dict) -> dict:
    """Classify the wait from the live board: waiting | answered | expired | closed | unobservable."""
    base = {"round": marker.get("round"), "comment_url": marker.get("comment_url"), "board_status": None}
    if not (marker.get("board") or {}).get("managed"):
        return {**base, "state": "unobservable", "reason": (marker.get("board") or {}).get("reason", "board not managed")}
    live = _board_for(marker).read()
    base["board_status"] = live["status"]
    if live["issue_state"] == "CLOSED":
        return {**base, "state": "closed"}
    if live["status"] in _answer_statuses():
        return {**base, "state": "answered"}
    max_wait = float(os.environ.get("MAKATO_QUESTIONS_MAX_WAIT_SECS", "0") or 0)
    if max_wait > 0 and time.time() - _epoch(marker["posted_at"]) > max_wait:
        return {**base, "state": "expired", "max_wait_secs": max_wait}
    return {**base, "state": "waiting"}


# --------------------------------------------------------------------------- commands


def cmd_post(args: argparse.Namespace) -> dict:
    try:
        doc = json.loads(Path(args.questions_file).read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:  # fmt: skip
        raise HqError(f"cannot read questions file: {exc}") from exc
    intro, questions = validate_questions(doc)

    existing = load_marker(args.spec_dir, args.issue)
    if existing and existing.get("comment_id") and not existing.get("answered_at"):
        return {"state": "already-posted", "round": existing.get("round"), "comment_url": existing.get("comment_url"), "marker": str(marker_path(args.spec_dir, args.issue))}
    round_no = int(existing["round"]) + 1 if existing and existing.get("answered_at") else 1
    if round_no > args.max_rounds:
        raise HqError(f"round limit reached ({args.max_rounds}); apply the recommended options instead of asking again", EXIT_ROUND_LIMIT)

    body = render_comment(args.key, args.issue, round_no, args.max_rounds, intro, questions, args.skill)
    if args.dry_run:
        return {"state": "dry-run", "round": round_no, "body": body}

    cfg = _project_config(args.root)
    repo = args.repo or _derive_repo(args.root, str(cfg.get("host") or "github.com"))
    board = Board(repo, args.issue, cfg)

    # Block the card BEFORE asking: if the board cannot be moved and re-read, nobody could ever observe the "moved back" signal, so
    # nothing is posted and the caller falls back to deciding with the recommended options.
    blocked = _block_card(board)
    if not blocked["managed"]:
        return {"state": "unavailable", "round": round_no, "reason": blocked["reason"]}

    marker = {
        "schema": 1, "key": args.key, "issue": args.issue, "repo": repo, "root": args.root, "skill": args.skill,
        "round": round_no, "max_rounds": args.max_rounds, "posted_at": _now(), "comment_id": None, "comment_url": None,
        "board": blocked, "questions": questions, "answered_at": None, "answers": None,
        "history": (existing or {}).get("history", []),
    }  # fmt: skip
    save_marker(args.spec_dir, args.issue, marker)  # written before the comment so a crash in between cannot double-post silently
    try:
        url = _gh(["issue", "comment", str(args.issue), "--repo", repo, "--body-file", "-"], host=board.host, input_text=body).strip().splitlines()[-1]
        found = re.search(r"#issuecomment-(\d+)", url)
        if not found:
            raise HqError(f"cannot read the new comment id from {url!r}", EXIT_GITHUB)
    except (HqError, IndexError) as exc:
        _undo_block(board, blocked)
        if existing is not None:
            save_marker(args.spec_dir, args.issue, existing)
        else:
            marker_path(args.spec_dir, args.issue).unlink(missing_ok=True)
        if isinstance(exc, HqError):
            raise
        raise HqError("GitHub returned no comment URL", EXIT_GITHUB) from exc
    marker["comment_id"], marker["comment_url"] = int(found.group(1)), url
    save_marker(args.spec_dir, args.issue, marker)
    return {"state": "posted", "round": round_no, "comment_url": url, "board": blocked, "marker": str(marker_path(args.spec_dir, args.issue)), "question_ids": [q["id"] for q in questions]}


def _block_card(board: Board) -> dict:
    """Move the card to Blocked and prove it; otherwise the later 'moved back' signal would be meaningless."""
    if not board.configured:
        return {"managed": False, "reason": "no github_project board configured in .claude/config.json"}
    try:
        live = board.read()
    except HqError as exc:
        return {"managed": False, "reason": str(exc)}
    if live["item_id"] is None:
        return {"managed": False, "reason": "issue is not on the project board"}
    before = live["status"]
    if before != BLOCKED and not board.set_status(live["item_id"], "blocked"):
        return {"managed": False, "reason": "could not move the card to Blocked (blocked option missing in config or item-edit failed)"}
    try:
        after = board.read()["status"]
    except HqError as exc:
        return {"managed": False, "reason": str(exc)}
    if after != BLOCKED:
        return {"managed": False, "reason": f"card is '{after}' after the move to Blocked"}
    return {"managed": True, "item_id": live["item_id"], "status_before": before, "blocked_status": BLOCKED}


def _undo_block(board: Board, blocked: dict) -> None:
    """Put the card back where it was when the question comment could not be posted. Best effort."""
    before = str(blocked.get("status_before") or "")
    if before and before != BLOCKED:
        board.set_status(str(blocked["item_id"]), before.lower().replace(" ", "_"))


def cmd_status(args: argparse.Namespace) -> dict:
    marker = load_marker(args.spec_dir, args.issue)
    if marker is None or not marker.get("comment_id"):
        return {"state": "none"}
    if marker.get("answered_at"):
        # Collected but not resolved yet: the run that collected them died or is still working. The card decides whether anyone should resume it.
        live = evaluate(marker)
        return {**live, "state": "waiting" if live["state"] == "expired" else live["state"], "collected": True}
    return evaluate(marker)


def _exit_for(state: str) -> int:
    return {"answered": EXIT_OK, "waiting": EXIT_WAITING, "unobservable": EXIT_UNOBSERVABLE, "closed": EXIT_CLOSED, "expired": EXIT_EXPIRED}.get(state, EXIT_OK)


def cmd_wait(args: argparse.Namespace) -> tuple[dict, int]:
    marker = _require_marker(args.spec_dir, args.issue)
    deadline = time.monotonic() + args.timeout if args.timeout > 0 else None
    failures = 0
    while True:
        try:
            result = {"state": "answered", "round": marker.get("round"), "collected": True} if marker.get("answered_at") else evaluate(marker)
            failures = 0
        except HqError as exc:
            failures += 1
            if failures >= args.max_failures:
                return {"state": "unobservable", "reason": f"board unreadable {failures} times in a row: {exc}"}, EXIT_UNOBSERVABLE
            result = {"state": "waiting", "transient_error": str(exc)}
        if result["state"] != "waiting":
            return result, _exit_for(result["state"])
        if deadline is not None and time.monotonic() >= deadline:
            return result, EXIT_WAITING
        pause = args.interval if deadline is None else max(0.0, min(args.interval, deadline - time.monotonic()))
        time.sleep(pause)


def _comment_bodies_after(marker: dict) -> list[str]:
    path = f"repos/{marker['repo']}/issues/{marker['issue']}/comments?per_page=100"
    raw = _gh(["api", path, "--paginate"], host=_board_for(marker).host)
    decoder, pos, comments = json.JSONDecoder(), 0, []
    while pos < len(raw):
        while pos < len(raw) and raw[pos].isspace():
            pos += 1
        if pos >= len(raw):
            break
        try:
            chunk, pos = decoder.raw_decode(raw, pos)
        except ValueError as exc:  # fmt: skip
            raise HqError("unreadable comments response from GitHub", EXIT_GITHUB) from exc
        comments.extend(chunk if isinstance(chunk, list) else [chunk])
    after = [c for c in comments if int(c.get("id", 0)) > int(marker["comment_id"]) and COMMENT_MARKER not in str(c.get("body", ""))]
    return [str(c.get("body", "")) for c in sorted(after, key=lambda c: int(c["id"]))]


def cmd_collect(args: argparse.Namespace) -> tuple[dict, int]:
    marker = _require_marker(args.spec_dir, args.issue)
    if marker.get("answered_at") and marker.get("answers"):
        return {"state": "collected", "round": marker["round"], "answers": marker["answers"], "resolved": _resolved(marker), "reused": True, **_followup_summary(marker["answers"])}, EXIT_OK
    claimed = False
    expired = False
    if not args.force:
        state = evaluate(marker)
        if state["state"] not in ("answered", "expired"):
            return state, _exit_for(state["state"])
        expired = state["state"] == "expired"
        if not args.no_claim:
            claimed = _claim(marker, (BLOCKED, "Ready") if expired else ("Ready",))
    parsed, accept_all = parse_answers(_comment_bodies_after(marker), marker["questions"])
    answers = merge_answers(marker["questions"], parsed, accept_all)
    marker["answered_at"], marker["answers"] = _now(), answers
    marker["history"] = [*marker.get("history", []), {"round": marker["round"], "answered_at": marker["answered_at"], "answers": answers}]
    save_marker(args.spec_dir, args.issue, marker)
    collected = {"state": "collected", "round": marker["round"], "answers": answers, "resolved": _resolved(marker)}
    return {**collected, "claimed": claimed, "expired": expired, "accept_all": accept_all, **_followup_summary(answers)}, EXIT_OK


def _resolved(marker: dict) -> list[dict]:
    """Each question joined with the option that won, so a skill can apply the outcome without re-reading the marker."""
    out = []
    for q in marker["questions"]:
        answer = marker["answers"][q["id"]]
        option = next((o for o in q["options"] if o["id"] == answer["choice"]), None)
        out.append(
            {
                "id": q["id"],
                "title": q["title"],
                "choice": answer["choice"],
                "label": option["label"] if option else None,
                "effect": option.get("effect") if option else None,
                "text": answer["text"],
                "note": answer["note"],
                "source": answer["source"],
                "followup": answer["followup"],
            }
        )
    return out


def _followup_summary(answers: dict) -> dict:
    return {
        "unanswered": [qid for qid, a in answers.items() if a["source"] != "user"],
        "followups_needed": [qid for qid, a in answers.items() if a["followup"]],
    }


def _claim(marker: dict, from_statuses: tuple[str, ...] = ("Ready",)) -> bool:
    """Move the card to In progress so the loop does not hand the ticket to a second worker. Best effort."""
    board = _board_for(marker)
    try:
        live = board.read()
    except HqError:
        return False
    if live["status"] not in from_statuses or not live["item_id"]:
        return False
    return board.set_status(live["item_id"], "in_progress")


def cmd_resolve(args: argparse.Namespace) -> dict:
    marker = _require_marker(args.spec_dir, args.issue)
    posted = False
    if args.comment_file:
        try:
            body = Path(args.comment_file).read_text(encoding="utf-8")
        except OSError as exc:
            raise HqError(f"cannot read comment file: {exc}") from exc
        _gh(["issue", "comment", str(marker["issue"]), "--repo", marker["repo"], "--body-file", "-"], host=_board_for(marker).host, input_text=body)
        posted = True
    marker_path(args.spec_dir, args.issue).unlink(missing_ok=True)
    return {"state": "resolved", "round": marker.get("round"), "comment_posted": posted}


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)

    def common(p: argparse.ArgumentParser) -> None:
        p.add_argument("--spec-dir", required=True, help="spec folder that holds the awaiting-answers marker")
        p.add_argument("--issue", required=True, type=int)

    post = sub.add_parser("post", help="post all questions, block the card, write the marker")
    common(post)
    post.add_argument("--key", required=True)
    post.add_argument("--questions-file", required=True)
    post.add_argument("--repo", default="")
    post.add_argument("--root", default=os.getcwd(), help="checkout whose .claude/config.json names the board")
    post.add_argument("--skill", default="build-grill-with-docs")
    post.add_argument("--max-rounds", type=int, default=int(os.environ.get("MAKATO_GRILL_MAX_QUESTION_ROUNDS", "3") or 3))
    post.add_argument("--dry-run", action="store_true", help="render the comment only; no GitHub, no marker")

    status = sub.add_parser("status", help="print waiting|answered|closed|unobservable|none")
    common(status)

    wait = sub.add_parser("wait", help="poll until the card is moved back; returns in slices")
    common(wait)
    wait.add_argument("--interval", type=float, default=60.0)
    wait.add_argument("--timeout", type=float, default=540.0, help="slice length in seconds (0 = until answered)")
    wait.add_argument("--max-failures", type=int, default=5)

    collect = sub.add_parser("collect", help="read the replies and merge them per question")
    common(collect)
    collect.add_argument("--force", action="store_true", help="collect even though the card was not moved back (recommended fills the gaps)")
    collect.add_argument("--no-claim", action="store_true", help="do not move Ready -> In progress")

    resolve = sub.add_parser("resolve", help="delete the marker; optionally post a closing comment")
    common(resolve)
    resolve.add_argument("--comment-file", default="")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        if args.command == "post":
            out, code = cmd_post(args), EXIT_OK
        elif args.command == "status":
            out, code = cmd_status(args), EXIT_OK
        elif args.command == "wait":
            out, code = cmd_wait(args)
        elif args.command == "collect":
            out, code = cmd_collect(args)
        else:
            out, code = cmd_resolve(args), EXIT_OK
    except HqError as exc:
        print(json.dumps({"state": "error", "error": str(exc)}))
        return exc.code
    print(json.dumps(out, ensure_ascii=False))
    return code


if __name__ == "__main__":
    sys.exit(main())
