"""Behavioral tests for the batched human-questions helper.

GitHub is replaced by an in-memory board/issue at the `_gh` process boundary, so the
whole post -> wait -> collect -> resolve life cycle runs offline against real files.
"""

from __future__ import annotations

import io
import json
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest.mock import patch

# pytest runs with --import-mode=importlib, which does not put this directory on sys.path.
sys.path.insert(0, str(Path(__file__).resolve().parent))

import human_questions as hq  # noqa: E402

REPO = "example/project"
PROJECT = "PVT_project"
OPTIONS = {"ready": "opt-ready", "in_progress": "opt-prog", "blocked": "opt-block"}
NAMES = {"opt-ready": "Ready", "opt-prog": "In progress", "opt-block": "Blocked"}


def question(qid: str, *, rec: str = "A", followup_on: str = "") -> dict:
    return {
        "id": qid,
        "title": f"Decision {qid}",
        "context": "why it matters",
        "options": [
            {"id": "A", "label": "first", "recommended": rec == "A", "followup": followup_on == "A"},
            {"id": "B", "label": "second", "recommended": rec == "B", "followup": followup_on == "B"},
        ],
    }


class FakeGitHub:
    """Just enough of issue comments + a project board card behind the gh CLI."""

    def __init__(self, status: str = "In progress", issue_state: str = "OPEN", on_board: bool = True) -> None:
        self.status = status
        self.issue_state = issue_state
        self.on_board = on_board
        self.comments: list[dict] = []
        self.edits = 0
        self.fail_edit = False
        self.fail_comment = False

    def human_says(self, body: str) -> None:
        self.comments.append({"id": 9000 + len(self.comments), "body": body})

    def __call__(self, args: list[str], *, host: str = "", cwd: str | None = None, input_text: str | None = None) -> str:
        if args[:2] == ["api", "graphql"]:
            node = {"id": "item-1", "project": {"id": PROJECT}, "fieldValueByName": {"name": self.status}} if self.on_board else None
            return json.dumps({"data": {"repository": {"issue": {"state": self.issue_state, "projectItems": {"nodes": [node] if node else []}}}}})
        if args[:2] == ["project", "item-edit"]:
            if self.fail_edit:
                raise hq.HqError("gh project failed: denied", hq.EXIT_GITHUB)
            self.edits += 1
            self.status = NAMES[args[args.index("--single-select-option-id") + 1]]
            return ""
        if args[:2] == ["issue", "comment"]:
            if self.fail_comment:
                raise hq.HqError("gh issue failed: rate limited", hq.EXIT_GITHUB)
            comment_id = 1000 + len(self.comments)
            self.comments.append({"id": comment_id, "body": input_text or ""})
            return f"https://github.com/{REPO}/issues/{args[2]}#issuecomment-{comment_id}\n"
        if args[0] == "api" and "/comments" in args[1]:
            return json.dumps(self.comments)
        raise AssertionError(f"unexpected gh call: {args}")


class Case(unittest.TestCase):
    def setUp(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        self.spec = self.root / "specs" / "42-demo"
        self.spec.mkdir(parents=True)
        (self.root / ".claude").mkdir()
        cfg = {"github_project": {"host": "github.com", "project_node_id": PROJECT, "fields": {"status": {"id": "field-1", "options": OPTIONS}}}}
        (self.root / ".claude" / "config.json").write_text(json.dumps(cfg), encoding="utf-8")
        self.gh = FakeGitHub()
        patcher = patch.object(hq, "_gh", self.gh)
        patcher.start()
        self.addCleanup(patcher.stop)
        env = patch.dict("os.environ", {"MAKATO_QUESTIONS_MAX_WAIT_SECS": "", "MAKATO_QUESTIONS_ANSWER_STATUSES": ""})
        env.start()
        self.addCleanup(env.stop)

    def run_cli(self, *argv: str) -> tuple[int, dict]:
        out = io.StringIO()
        with redirect_stdout(out):
            code = hq.main(list(argv))
        return code, json.loads(out.getvalue())

    def write_questions(self, questions: list[dict], name: str = "q.json") -> str:
        path = self.root / name
        path.write_text(json.dumps({"questions": questions}), encoding="utf-8")
        return str(path)

    def post(self, questions: list[dict], *extra: str) -> tuple[int, dict]:
        return self.run_cli(
            "post", "--spec-dir", str(self.spec), "--issue", "42", "--key", "42-demo", "--repo", REPO, "--root", str(self.root),
            "--questions-file", self.write_questions(questions), *extra,
        )  # fmt: skip

    def common(self) -> list[str]:
        return ["--spec-dir", str(self.spec), "--issue", "42"]

    def age_marker(self) -> None:
        """Pretend the question comment was posted long ago, so the wait deadline is already past."""
        marker = hq.load_marker(str(self.spec), 42)
        assert marker is not None
        marker["posted_at"] = "2020-01-01T00:00:00.000Z"
        hq.save_marker(str(self.spec), 42, marker)


class ReplyParsing(unittest.TestCase):
    def merged(self, replies: list[str], questions: list[dict]) -> dict:
        parsed, accept_all = hq.parse_answers(replies, questions)
        return hq.merge_answers(questions, parsed, accept_all)

    def test_letters_notes_and_free_text_land_on_the_right_question(self) -> None:
        qs = [question("Q1"), question("Q2"), question("Q3")]
        got = self.merged(["Q1: b\nQ2: B - because latency\nQ3: use the legacy adapter instead"], qs)
        self.assertEqual((got["Q1"]["choice"], got["Q1"]["followup"]), ("B", False))
        self.assertEqual((got["Q2"]["choice"], got["Q2"]["note"]), ("B", "because latency"))
        self.assertEqual((got["Q3"]["choice"], got["Q3"]["text"], got["Q3"]["followup"]), (None, "use the legacy adapter instead", True))

    def test_unanswered_questions_take_the_recommended_option_and_are_reported(self) -> None:
        qs = [question("Q1", rec="B"), question("Q2")]
        got = self.merged(["Q2: B"], qs)
        self.assertEqual((got["Q1"]["choice"], got["Q1"]["source"]), ("B", "recommended"))
        self.assertEqual(hq._followup_summary(got)["unanswered"], ["Q1"])

    def test_accept_all_marks_gaps_as_a_user_decision_but_explicit_lines_still_win(self) -> None:
        qs = [question("Q1"), question("Q2", rec="B")]
        got = self.merged(["all: recommended\nQ1: B"], qs)
        self.assertEqual((got["Q1"]["choice"], got["Q1"]["source"]), ("B", "user"))
        self.assertEqual((got["Q2"]["choice"], got["Q2"]["source"]), ("B", "user-accept-all"))

    def test_markdown_decoration_quotes_and_unknown_ids_are_tolerated(self) -> None:
        qs = [question("Q1"), question("Q2")]
        got = self.merged(["> Q1: A (quoted reply from a mail client)\n- **Q1**: B\n`Q2: recommended`\nQ7: A\nplain chatter"], qs)
        self.assertEqual(got["Q1"]["choice"], "B")
        self.assertEqual((got["Q2"]["choice"], got["Q2"]["source"]), ("A", "user"))

    def test_later_comment_overrides_earlier_one(self) -> None:
        qs = [question("Q1")]
        self.assertEqual(self.merged(["Q1: A", "Q1: B"], qs)["Q1"]["choice"], "B")

    def test_option_flagged_as_followup_asks_for_another_round(self) -> None:
        qs = [question("Q1", followup_on="B")]
        got = self.merged(["Q1: B"], qs)
        self.assertEqual(hq._followup_summary(got)["followups_needed"], ["Q1"])


class QuestionValidation(unittest.TestCase):
    def test_one_recommendation_per_question_is_enforced(self) -> None:
        bad = question("Q1")
        bad["options"][1]["recommended"] = True
        with self.assertRaises(hq.HqError):
            hq.validate_questions({"questions": [bad]})
        none = question("Q1")
        none["options"][0]["recommended"] = False
        with self.assertRaises(hq.HqError):
            hq.validate_questions({"questions": [none]})

    def test_duplicate_ids_and_single_option_are_rejected(self) -> None:
        with self.assertRaises(hq.HqError):
            hq.validate_questions({"questions": [question("Q1"), question("Q1")]})
        single = question("Q1")
        single["options"] = single["options"][:1]
        with self.assertRaises(hq.HqError):
            hq.validate_questions({"questions": [single]})

    def test_rendered_comment_lists_every_question_and_marks_the_recommendation(self) -> None:
        body = hq.render_comment("42-demo", 42, 1, 3, "", [question("Q1"), question("Q2", rec="B")], "build-grill-with-docs")
        self.assertTrue(body.startswith(hq.COMMENT_MARKER))
        self.assertIn("Q1", body)
        self.assertIn("Q2", body)
        self.assertEqual(body.count("**(recommended)**"), 2)
        self.assertIn("Blocked", body)


class Lifecycle(Case):
    def test_post_asks_everything_once_blocks_the_card_and_waiting_ends_when_it_moves_back(self) -> None:
        code, posted = self.post([question("Q1"), question("Q2")])
        self.assertEqual((code, posted["state"], posted["question_ids"]), (0, "posted", ["Q1", "Q2"]))
        self.assertEqual(self.gh.status, "Blocked")
        self.assertEqual(len(self.gh.comments), 1)
        self.assertIn("Q2", self.gh.comments[0]["body"])

        code, state = self.run_cli("status", *self.common())
        self.assertEqual((code, state["state"], state["board_status"]), (0, "waiting", "Blocked"))
        code, _ = self.run_cli("wait", *self.common(), "--timeout", "0.05", "--interval", "0.01")
        self.assertEqual(code, hq.EXIT_WAITING)
        code, collected = self.run_cli("collect", *self.common())
        self.assertEqual((code, collected["state"]), (hq.EXIT_WAITING, "waiting"))

        self.gh.human_says("Q1: B\nQ2: A - fine")
        self.gh.status = "Ready"
        code, done = self.run_cli("wait", *self.common(), "--timeout", "5", "--interval", "0.01")
        self.assertEqual((code, done["state"]), (0, "answered"))
        code, collected = self.run_cli("collect", *self.common())
        self.assertEqual(code, 0)
        self.assertEqual(collected["answers"]["Q1"]["choice"], "B")
        self.assertEqual(collected["answers"]["Q2"]["note"], "fine")
        self.assertTrue(collected["claimed"])
        by_id = {r["id"]: r for r in collected["resolved"]}
        self.assertEqual((by_id["Q1"]["title"], by_id["Q1"]["choice"], by_id["Q1"]["label"]), ("Decision Q1", "B", "second"))
        self.assertEqual((by_id["Q2"]["label"], by_id["Q2"]["note"], by_id["Q2"]["source"]), ("first", "fine", "user"))
        self.assertEqual(self.gh.status, "In progress")

        code, again = self.run_cli("collect", *self.common())
        self.assertEqual((code, again["reused"]), (0, True))

        # Collected but never resolved (the run died): the card alone says whether to resume.
        code, alive = self.run_cli("status", *self.common())
        self.assertEqual((code, alive["state"], alive["collected"]), (0, "answered", True))
        self.gh.status = "Blocked"
        with patch.dict("os.environ", {"MAKATO_QUESTIONS_MAX_WAIT_SECS": "1"}):
            self.age_marker()
            self.assertEqual(self.run_cli("status", *self.common())[1]["state"], "waiting")
        self.gh.status = "In progress"
        code, resolved = self.run_cli("resolve", *self.common())
        self.assertEqual((code, resolved["state"]), (0, "resolved"))
        self.assertEqual(self.run_cli("status", *self.common())[1]["state"], "none")

    def test_posting_twice_while_unanswered_does_not_duplicate_the_comment(self) -> None:
        self.post([question("Q1")])
        code, second = self.post([question("Q1")])
        self.assertEqual((code, second["state"]), (0, "already-posted"))
        self.assertEqual(len(self.gh.comments), 1)

    def test_comments_by_the_pipeline_never_count_as_answers(self) -> None:
        self.post([question("Q1", rec="B")])
        self.gh.comments.append({"id": 5000, "body": f"{hq.COMMENT_MARKER} v1 -->\nQ1: A"})
        self.gh.status = "In progress"
        _, collected = self.run_cli("collect", *self.common())
        self.assertEqual((collected["answers"]["Q1"]["choice"], collected["answers"]["Q1"]["source"]), ("B", "recommended"))

    def test_only_replies_written_after_the_question_comment_are_read(self) -> None:
        self.gh.comments.append({"id": 10, "body": "Q1: A (older chatter)"})
        self.post([question("Q1", rec="B")])
        self.gh.status = "Ready"
        _, collected = self.run_cli("collect", *self.common())
        self.assertEqual(collected["answers"]["Q1"]["source"], "recommended")

    def test_second_round_is_numbered_and_the_round_cap_stops_endless_asking(self) -> None:
        self.post([question("Q1")], "--max-rounds", "2")
        self.gh.status = "Ready"
        self.run_cli("collect", *self.common())
        code, second = self.post([question("Q1")], "--max-rounds", "2")
        self.assertEqual((code, second["round"]), (0, 2))
        self.assertIn("round 2 of 2", self.gh.comments[-1]["body"])
        self.gh.status = "Ready"
        self.run_cli("collect", *self.common())
        code, third = self.post([question("Q1")], "--max-rounds", "2")
        self.assertEqual((code, third["state"]), (hq.EXIT_ROUND_LIMIT, "error"))

    def test_closed_issue_ends_the_wait_instead_of_polling_forever(self) -> None:
        self.post([question("Q1")])
        self.gh.issue_state = "CLOSED"
        code, state = self.run_cli("wait", *self.common(), "--timeout", "5", "--interval", "0.01")
        self.assertEqual((code, state["state"]), (hq.EXIT_CLOSED, "closed"))

    def test_waiting_beyond_the_configured_maximum_expires_and_collect_falls_back_to_the_recommendation(self) -> None:
        self.post([question("Q1", rec="B")])
        self.age_marker()
        with patch.dict("os.environ", {"MAKATO_QUESTIONS_MAX_WAIT_SECS": "60"}):
            self.assertEqual(self.run_cli("status", *self.common())[1]["state"], "expired")
            code, state = self.run_cli("wait", *self.common(), "--timeout", "5", "--interval", "0.01")
            self.assertEqual((code, state["state"]), (hq.EXIT_EXPIRED, "expired"))
            code, collected = self.run_cli("collect", *self.common())
        self.assertEqual(code, 0)
        self.assertEqual((collected["expired"], collected["answers"]["Q1"]["choice"], collected["answers"]["Q1"]["source"]), (True, "B", "recommended"))
        self.assertEqual(self.gh.status, "In progress")

    def test_an_answer_that_arrives_before_the_deadline_wins_over_expiry(self) -> None:
        self.post([question("Q1")])
        self.age_marker()
        self.gh.status = "Ready"
        with patch.dict("os.environ", {"MAKATO_QUESTIONS_MAX_WAIT_SECS": "60"}):
            self.assertEqual(self.run_cli("status", *self.common())[1]["state"], "answered")

    def test_custom_answer_statuses_are_honoured(self) -> None:
        self.post([question("Q1")])
        self.gh.status = "In progress"
        with patch.dict("os.environ", {"MAKATO_QUESTIONS_ANSWER_STATUSES": "Ready"}):
            self.assertEqual(self.run_cli("status", *self.common())[1]["state"], "waiting")
        self.assertEqual(self.run_cli("status", *self.common())[1]["state"], "answered")


class UnavailableBoard(Case):
    def test_card_that_cannot_be_blocked_means_nothing_is_posted_and_the_caller_decides_itself(self) -> None:
        self.gh.fail_edit = True
        code, posted = self.post([question("Q1")])
        self.assertEqual((code, posted["state"]), (0, "unavailable"))
        self.assertEqual(self.gh.comments, [])
        self.assertEqual(self.gh.status, "In progress")
        self.assertEqual(list(self.spec.iterdir()), [])
        self.assertEqual(self.run_cli("status", *self.common())[1]["state"], "none")

    def test_issue_missing_from_the_board_is_unavailable(self) -> None:
        self.gh.on_board = False
        _, posted = self.post([question("Q1")])
        self.assertEqual(posted["state"], "unavailable")
        self.assertIn("not on the project board", posted["reason"])
        self.assertEqual(self.gh.comments, [])

    def test_missing_board_config_is_unavailable(self) -> None:
        (self.root / ".claude" / "config.json").write_text("{}", encoding="utf-8")
        _, posted = self.post([question("Q1")])
        self.assertEqual(posted["state"], "unavailable")
        self.assertEqual(self.gh.comments, [])

    def test_failed_comment_puts_the_card_back_and_leaves_no_marker(self) -> None:
        self.gh.fail_comment = True
        code, out = self.post([question("Q1")])
        self.assertEqual((code, out["state"]), (hq.EXIT_GITHUB, "error"))
        self.assertEqual(self.gh.status, "In progress")
        self.assertEqual(self.run_cli("status", *self.common())[1]["state"], "none")

    def test_failed_follow_up_comment_keeps_the_previous_round_intact(self) -> None:
        self.post([question("Q1")])
        self.gh.human_says("Q1: B")
        self.gh.status = "Ready"
        self.run_cli("collect", *self.common())
        self.gh.fail_comment = True
        code, _ = self.post([question("Q1")])
        self.assertEqual(code, hq.EXIT_GITHUB)
        self.assertEqual(self.gh.status, "In progress")
        code, again = self.run_cli("collect", *self.common())
        self.assertEqual((code, again["answers"]["Q1"]["choice"]), (0, "B"))

    def test_replies_can_be_collected_before_the_card_moves_when_forced(self) -> None:
        self.post([question("Q1", rec="B")])
        self.gh.human_says("Q1: A")
        code, collected = self.run_cli("collect", *self.common(), "--force")
        self.assertEqual((code, collected["answers"]["Q1"]["choice"]), (0, "A"))
        self.assertEqual(self.gh.status, "Blocked")

    def test_dry_run_touches_neither_github_nor_disk(self) -> None:
        code, out = self.post([question("Q1")], "--dry-run")
        self.assertEqual((code, out["state"]), (0, "dry-run"))
        self.assertEqual(self.gh.comments, [])
        self.assertEqual(list(self.spec.iterdir()), [])


if __name__ == "__main__":
    unittest.main()
