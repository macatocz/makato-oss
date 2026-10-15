"""Behavioral CI inspector tests against a fake GitHub process/API boundary.

Local branch/HEAD/private-directory checks use real disposable Git repositories.
No test matches implementation source text or contacts GitHub.
"""

from __future__ import annotations

import io
import json
import stat
import subprocess
import tempfile
import unittest
from contextlib import redirect_stdout
from copy import deepcopy
from dataclasses import dataclass
from pathlib import Path
from unittest.mock import patch
from urllib.parse import parse_qs, urlparse

import ci_checks

REAL_RUN = subprocess.run
REPO = "example/project"
PREFIX = f"repos/{REPO}"
FEATURE_UNAVAILABLE = "Upgrade to GitHub Pro or make this repository public to enable this feature."


@dataclass
class Response:
    body: object
    code: int = 0


class GitHubBoundary:
    """Serve supported gh API requests; reject any unexpected/mutating command."""

    def __init__(self, sha: str) -> None:
        self.sha = sha
        self.pr = {"number": 17, "state": "open", "merged": False, "head": {"sha": sha, "ref": "feature"}, "base": {"ref": "main"}}
        self.final_pr: dict | None = None
        self.protection: dict | None = None
        self.graphql_errors: list[dict] | None = None
        self.rules = []
        self.branch = {"name": "main", "protected": False}
        self.checks = []
        self.statuses = []
        self.runs = []
        self.jobs = {}
        self.pinned = {}
        self.current = {}
        self.logs = {}
        self.overrides = {}
        self.totals = {}
        self.requests = []
        self.pr_reads = 0

    def external(self, name="lint", conclusion="success", *, check_id=1, app_id=99, status="completed"):
        check = {
            "id": check_id,
            "name": name,
            "head_sha": self.sha,
            "app": {"id": app_id, "slug": "external-ci"},
            "status": status,
            "conclusion": conclusion,
            "details_url": "https://ci.example/check",
            "output": {"title": "External diagnostic", "summary": "check failed in source.py:9"},
        }
        self.checks.append(check)
        return check

    def action(self, names=("test",), conclusions=("success",), *, run_id=101, workflow_id=1, attempt=1, workflow="CI", run_conclusion=None):
        if run_conclusion is None:
            run_conclusion = "failure" if any(c in {"failure", "timed_out", "cancelled"} for c in conclusions) else "success"
        run = {
            "id": run_id,
            "head_sha": self.sha,
            "run_attempt": attempt,
            "workflow_id": workflow_id,
            "name": workflow,
            "status": "completed",
            "conclusion": run_conclusion,
            "html_url": f"https://github.com/{REPO}/actions/runs/{run_id}",
        }
        self.runs.append(run)
        jobs = []
        for index, (name, conclusion) in enumerate(zip(names, conclusions)):
            job_id = run_id * 100 + attempt * 10 + index
            url = f"https://github.com/{REPO}/actions/runs/{run_id}/job/{job_id}"
            job = {
                "id": job_id,
                "run_id": run_id,
                "run_attempt": attempt,
                "head_sha": self.sha,
                "name": name,
                "status": "completed",
                "conclusion": conclusion,
                "html_url": url,
                "check_run_url": f"https://api.github.com/{PREFIX}/check-runs/{job_id}",
                "steps": [{"name": "Run tests", "conclusion": conclusion}],
            }
            jobs.append(job)
            self.checks.append({"id": job_id, "name": name, "head_sha": self.sha, "status": "completed", "conclusion": conclusion, "app": {"id": 15368, "slug": "github-actions"}, "details_url": url})
            self.logs[job_id] = f"full setup for {job_id}\n\x1b[31m##[error] {name}: source.py:8 assertion failed\x1b[0m\nfull trailing output\n"
        self.jobs[(run_id, attempt)] = jobs
        return run, jobs

    def required(self, *contexts, app_id=None):
        self.protection = {
            "requiresStatusChecks": True,
            "requiredStatusCheckContexts": list(contexts),
            "requiredStatusChecks": [{"context": context, "app": {"databaseId": app_id, "slug": "ci"} if app_id else None} for context in contexts],
        }

    def _page(self, path, params, values, key=None):
        page = int(params["page"][0])
        if params.get("per_page") != ["100"]:
            raise AssertionError("API pagination must request 100 items")
        batch = values[(page - 1) * 100 : page * 100]
        return {key: batch, "total_count": self.totals.get(path, len(values))} if key else batch

    def _response(self, path, params):
        if path in self.overrides:
            value = self.overrides[path]
            return value(params) if callable(value) else value
        if path == f"{PREFIX}/pulls/17":
            self.pr_reads += 1
            return self.pr if self.pr_reads == 1 or self.final_pr is None else self.final_pr
        if path == f"{PREFIX}/rules/branches/main":
            return self.rules
        if path == f"{PREFIX}/branches/main":
            return self.branch
        if path == f"{PREFIX}/commits/{self.sha}/check-runs":
            if params.get("filter") != ["all"]:
                raise AssertionError("All check attempts must be visible at the API boundary")
            return self._page(path, params, self.checks, "check_runs")
        if path == f"{PREFIX}/commits/{self.sha}/statuses":
            return self._page(path, params, self.statuses)
        if path == f"{PREFIX}/actions/runs":
            if params.get("head_sha") != [self.sha]:
                raise AssertionError("Run query is not pinned to PR HEAD")
            return self._page(path, params, self.runs, "workflow_runs")
        suffix = path.removeprefix(f"{PREFIX}/actions/")
        parts = suffix.split("/")
        if len(parts) >= 2 and parts[0] == "runs":
            run_id = int(parts[1])
            if len(parts) >= 4 and parts[2] == "attempts":
                attempt = int(parts[3])
                if len(parts) == 5 and parts[4] == "jobs":
                    return self._page(path, params, self.jobs[(run_id, attempt)], "jobs")
                return self.pinned.get((run_id, attempt), next(r for r in self.runs if r["id"] == run_id and r["run_attempt"] == attempt))
            return self.current.get(run_id, next(r for r in self.runs if r["id"] == run_id))
        if len(parts) >= 2 and parts[0] == "jobs":
            job_id = int(parts[1])
            if len(parts) == 3 and parts[2] == "logs":
                return self.logs[job_id]
            return next(job for jobs in self.jobs.values() for job in jobs if job["id"] == job_id)
        raise AssertionError(f"Unexpected API request: {path}")

    def __call__(self, command, **kwargs):
        if command[0] == "git":
            return REAL_RUN(command, **kwargs)
        if command[:2] != ["gh", "api"]:
            raise AssertionError(f"Unexpected process: {command}")
        if kwargs["env"].get("GH_PROMPT_DISABLED") != "1":
            raise AssertionError("GitHub prompts must be disabled")
        if not 0 < kwargs["timeout"] <= 30:
            raise AssertionError("GitHub calls require bounded timeouts")
        if command[2] == "graphql":
            fields = dict(command[index + 1].split("=", 1) for index in range(3, len(command), 2))
            if command[3::2] != ["-f"] * len(fields) or not fields["query"].startswith("query("):
                raise AssertionError("Only a read-only GraphQL query is allowed")
            self.requests.append(("graphql", fields))
            graphql_body: dict = {"data": {"repository": {"ref": {"branchProtectionRule": self.protection}}}}
            if self.graphql_errors:
                graphql_body["errors"] = self.graphql_errors
            body = graphql_body
        else:
            if command[2:4] != ["--method", "GET"] or len(command) not in {5, 6}:
                raise AssertionError(f"Only REST GET is allowed: {command}")
            url = urlparse(command[4])
            if len(command) == 6 and (command[5] != "--allow-escape-sequences" or not url.path.endswith("/logs") or not hasattr(kwargs.get("stdout"), "write")):
                raise AssertionError("Escape sequences may be downloaded only into private log files")
            params = parse_qs(url.query)
            self.requests.append((url.path, params))
            body = self._response(url.path, params)
        response = body if isinstance(body, Response) else Response(body)
        if hasattr(kwargs.get("stdout"), "write"):
            if response.code == 0:
                data = response.body if isinstance(response.body, str) else json.dumps(response.body)
                if "\x1b" in data and "--allow-escape-sequences" not in command:
                    return subprocess.CompletedProcess(command, 1, None, b"the response contains terminal escape sequences")
                kwargs["stdout"].write(data.encode())
            return subprocess.CompletedProcess(command, response.code, None, b"PRIVATE CLI STDERR")
        return subprocess.CompletedProcess(command, response.code, json.dumps(response.body), "PRIVATE CLI STDERR")


class InspectorTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.worktree = self.root / "worktree"
        self.worktree.mkdir()
        REAL_RUN(["git", "init", "-q", "--initial-branch=feature", str(self.worktree)], check=True)
        REAL_RUN(
            ["git", "-C", str(self.worktree), "-c", "user.name=CI Test", "-c", "user.email=ci@example.test", "-c", "commit.gpgsign=false", "commit", "--quiet", "--allow-empty", "-m", "fixture"],
            check=True,
        )
        self.sha = REAL_RUN(["git", "-C", str(self.worktree), "rev-parse", "HEAD"], capture_output=True, text=True, check=True).stdout.strip()
        self.output = self.root / "private"
        self.api = GitHubBoundary(self.sha)

    def inspect(self):
        with patch.object(ci_checks.subprocess, "run", side_effect=self.api):
            return ci_checks.inspect(REPO, 17, self.worktree, self.output)

    def test_green_is_bound_to_matching_branch_and_head(self):
        self.api.action()
        result = self.inspect()
        self.assertEqual(result["status"], "green")
        self.assertEqual(result["head_sha"], self.sha)
        self.assertEqual(result["pr_number"], 17)
        self.assertEqual(result["errors"], [])
        self.assertEqual(result["failures"], [])
        self.assertEqual(self.api.pr_reads, 2)

    def test_empty_inventory_is_pending_never_green(self):
        result = self.inspect()
        self.assertEqual(result["status"], "pending")
        self.assertEqual(result["checks"], [])

    def test_missing_required_context_is_visible_and_pending(self):
        self.api.external()
        self.api.required("not-yet-registered", app_id=15368)
        result = self.inspect()
        missing = next(c for c in result["checks"] if c["name"] == "not-yet-registered")
        self.assertEqual(result["status"], "pending")
        self.assertEqual(missing["state"], "missing")
        self.assertTrue(missing["required"])
        self.assertEqual(missing["app_id"], 15368)

    def test_classic_and_ruleset_requirements_are_combined_with_app_binding(self):
        self.api.external("test", app_id=99)
        self.api.required("test", app_id=15368)
        self.api.rules = [{"type": "required_status_checks", "parameters": {"required_status_checks": [{"context": "security", "integration_id": -1}]}}]
        result = self.inspect()
        self.assertEqual(result["status"], "pending")
        required = {(c["name"], c["app_id"], c["state"]) for c in result["checks"] if c["required"]}
        self.assertEqual(required, {("test", 15368, "missing"), ("security", None, "missing")})

    def test_required_status_and_check_with_same_context_both_have_to_pass(self):
        self.api.external("build")
        self.api.statuses = [{"id": 1, "context": "build", "state": "pending"}]
        self.api.required("build")
        result = self.inspect()
        self.assertEqual(result["status"], "pending")
        self.assertTrue(all(c["required"] for c in result["checks"]))

    def test_required_skipped_fails_closed_but_optional_skipped_is_nonblocking(self):
        self.api.external("skip", "skipped")
        self.assertEqual(self.inspect()["status"], "green")
        self.api.required("skip")
        self.api.pr_reads = 0
        result = self.inspect()
        self.assertEqual(result["status"], "blocked")
        self.assertIn("required skipped checks fail closed", result["failures"][0]["summary"])

    def test_optional_actions_skipped_is_nonblocking(self):
        self.api.action(conclusions=("skipped",), run_conclusion="skipped")
        self.assertEqual(self.inspect()["status"], "green")

    def test_all_failed_jobs_have_complete_private_attempt_pinned_logs(self):
        _, jobs = self.api.action(("lint", "unit"), ("failure", "failure"), attempt=3)
        result = self.inspect()
        self.assertEqual(result["status"], "repair")
        self.assertEqual({failure["job_id"] for failure in result["failures"]}, {job["id"] for job in jobs})
        for failure in result["failures"]:
            path = Path(failure["log_path"])
            self.assertEqual(path.read_text(), self.api.logs[failure["job_id"]])
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
            self.assertEqual(stat.S_IMODE(path.parent.stat().st_mode), 0o700)
            self.assertFalse(path.is_relative_to(self.worktree))
            self.assertIn("attempt-3", path.name)
            self.assertIn("Run tests", failure["summary"])
            self.assertIn("source.py:8", failure["summary"])
            self.assertEqual((failure["workflow"], failure["run_id"], failure["attempt"]), ("CI", 101, 3))

    def test_cancelled_and_timed_out_jobs_are_terminal_failures(self):
        self.api.action(("cancelled", "timed"), ("cancelled", "timed_out"))
        result = self.inspect()
        self.assertEqual(result["status"], "repair")
        self.assertEqual(len(result["failures"]), 2)

    def test_pending_workflow_cannot_authorize_repair_of_completed_failure(self):
        run, _ = self.api.action(conclusions=("failure",))
        run.update(status="in_progress", conclusion=None)
        self.assertEqual(self.inspect()["status"], "pending")

    def test_new_run_before_jobs_register_is_pending(self):
        run, jobs = self.api.action()
        run.update(status="queued", conclusion=None)
        jobs.clear()
        self.api.checks.clear()
        result = self.inspect()
        self.assertEqual(result["status"], "pending")

    def test_external_failure_is_diagnostic_but_not_speculative_local_repair(self):
        self.api.external("third-party", "failure")
        result = self.inspect()
        self.assertEqual(result["status"], "blocked")
        failure = result["failures"][0]
        self.assertIn("source.py:9", failure["summary"])
        self.assertIsNone(failure["run_id"])
        self.assertIsNone(failure["log_path"])

    def test_status_contexts_choose_latest_update(self):
        self.api.statuses = [
            {"id": 9, "context": "external", "state": "success"},
            {"id": 2, "context": "external", "state": "failure"},
        ]
        self.api.required("external")
        result = self.inspect()
        self.assertEqual(result["status"], "green")
        self.assertEqual(len(result["checks"]), 1)

    def test_duplicate_check_names_choose_latest_within_app_not_across_apps(self):
        self.api.external("quality", "success", check_id=10)
        self.api.external("quality", "failure", check_id=1)
        self.api.external("quality", "failure", check_id=2, app_id=77)
        result = self.inspect()
        self.assertEqual(result["status"], "blocked")
        self.assertEqual(len(result["checks"]), 2)
        self.assertEqual(len(result["failures"]), 1)

    def test_old_failed_run_does_not_shadow_latest_success(self):
        self.api.action(conclusions=("failure",), run_id=100)
        self.api.action(run_id=101)
        result = self.inspect()
        self.assertEqual(result["status"], "green")
        self.assertEqual({c["run_id"] for c in result["checks"]}, {101})
        self.assertEqual(result["failures"], [])

    def test_rerun_uses_latest_attempt_not_old_failed_jobs(self):
        old_run, _ = self.api.action(conclusions=("failure",), attempt=1)
        self.api.runs.remove(old_run)
        self.api.action(attempt=2)
        result = self.inspect()
        self.assertEqual(result["status"], "green")
        self.assertEqual({c["attempt"] for c in result["checks"]}, {2})
        self.assertEqual(result["failures"], [])

    def test_same_named_jobs_in_distinct_workflows_are_not_collapsed(self):
        self.api.action(run_id=100, workflow_id=1, workflow="CI", conclusions=("failure",))
        self.api.action(run_id=101, workflow_id=2, workflow="Other CI")
        result = self.inspect()
        self.assertEqual(result["status"], "repair")
        self.assertEqual({c["workflow"] for c in result["checks"]}, {"CI", "Other CI"})

    def test_new_attempt_started_during_inspection_is_pending(self):
        run, _ = self.api.action(conclusions=("failure",))
        self.api.current[101] = {**run, "run_attempt": 2, "status": "queued", "conclusion": None}
        self.assertEqual(self.inspect()["status"], "pending")

    def test_changed_head_after_logs_is_stale_and_keeps_original_evidence_sha(self):
        self.api.action(conclusions=("failure",))
        self.api.final_pr = deepcopy(self.api.pr)
        self.api.final_pr["head"]["sha"] = "b" * 40
        result = self.inspect()
        self.assertEqual(result["status"], "stale")
        self.assertEqual(result["head_sha"], self.sha)
        self.assertTrue(result["failures"][0]["log_path"])
        self.assertEqual(self.api.requests[-1][0], f"{PREFIX}/pulls/17")

    def test_changed_base_invalidates_required_check_inventory(self):
        self.api.external()
        self.api.final_pr = deepcopy(self.api.pr)
        self.api.final_pr["base"]["ref"] = "release"
        self.assertEqual(self.inspect()["status"], "stale")

    def test_wrong_local_branch_blocks_green(self):
        self.api.external()
        self.api.pr["head"]["ref"] = "other-branch"
        result = self.inspect()
        self.assertEqual(result["status"], "blocked")
        self.assertTrue(any("branch does not match" in error for error in result["errors"]))

    def test_unpushed_local_commit_blocks_old_remote_green(self):
        self.api.external()
        REAL_RUN(
            ["git", "-C", str(self.worktree), "-c", "user.name=CI Test", "-c", "user.email=ci@example.test", "-c", "commit.gpgsign=false", "commit", "--quiet", "--allow-empty", "-m", "unpushed"],
            check=True,
        )
        result = self.inspect()
        self.assertEqual(result["status"], "blocked")
        self.assertTrue(any("HEAD does not match" in error for error in result["errors"]))

    def test_worktree_mismatch_also_blocks_repair(self):
        self.api.action(conclusions=("failure",))
        self.api.pr["head"]["ref"] = "different"
        self.assertEqual(self.inspect()["status"], "blocked")

    def test_closed_pr_is_observation_only_even_on_nonmatching_local_branch(self):
        self.api.action()
        self.api.pr.update(state="closed", merged=True)
        self.api.pr["head"]["ref"] = "deleted-feature"
        self.assertEqual(self.inspect()["status"], "closed")

    def test_unknown_terminal_conclusion_is_blocked(self):
        self.api.external(conclusion="new-unknown-conclusion")
        self.assertEqual(self.inspect()["status"], "blocked")

    def test_foreign_sha_in_check_is_not_accepted(self):
        self.api.external()["head_sha"] = "b" * 40
        self.assertEqual(self.inspect()["status"], "blocked")

    def test_foreign_sha_or_attempt_in_actions_metadata_is_not_accepted(self):
        run, _ = self.api.action()
        self.api.pinned[(101, 1)] = {**run, "head_sha": "b" * 40}
        self.assertEqual(self.inspect()["status"], "blocked")

    def test_wrong_attempt_job_is_not_accepted(self):
        _, jobs = self.api.action()
        jobs[0]["run_attempt"] = 2
        self.assertEqual(self.inspect()["status"], "blocked")

    def test_permissions_or_unknown_requirements_never_become_green(self):
        self.api.external()
        self.api.overrides[f"{PREFIX}/rules/branches/main"] = Response({"message": "Resource not accessible", "status": "403"}, 1)
        result = self.inspect()
        self.assertEqual(result["status"], "blocked")
        self.assertTrue(any("Required-check inventory unavailable" in error for error in result["errors"]))
        self.assertNotIn("PRIVATE CLI STDERR", json.dumps(result))

    def test_graphql_partial_error_is_not_empty_protection(self):
        self.api.external()
        self.api.graphql_errors = [{"message": "FORBIDDEN"}]
        self.assertEqual(self.inspect()["status"], "blocked")

    def test_explicit_unsupported_rules_plan_and_unprotected_branch_are_known_empty(self):
        self.api.external()
        self.api.overrides[f"{PREFIX}/rules/branches/main"] = Response({"message": FEATURE_UNAVAILABLE, "status": "403"}, 1)
        self.assertEqual(self.inspect()["status"], "green")
        self.assertTrue(any(path == f"{PREFIX}/branches/main" for path, _ in self.api.requests))

    def test_plan_error_does_not_bypass_protected_branch(self):
        self.api.external()
        self.api.branch["protected"] = True
        self.api.overrides[f"{PREFIX}/rules/branches/main"] = Response({"message": FEATURE_UNAVAILABLE, "status": "403"}, 1)
        self.assertEqual(self.inspect()["status"], "blocked")

    def test_plan_error_does_not_bypass_classic_protection(self):
        self.api.external()
        self.api.required("missing")
        self.api.overrides[f"{PREFIX}/rules/branches/main"] = Response({"message": FEATURE_UNAVAILABLE, "status": "403"}, 1)
        self.assertEqual(self.inspect()["status"], "blocked")

    def test_required_workflow_rule_is_explicitly_unsupported_not_ignored(self):
        self.api.external()
        self.api.rules = [{"type": "workflows", "parameters": {"workflows": []}}]
        self.assertEqual(self.inspect()["status"], "blocked")

    def test_pagination_finds_failure_after_first_hundred_check_runs(self):
        for index in range(100):
            self.api.external(f"pass-{index}", check_id=index + 1)
        self.api.external("last-failure", "failure", check_id=101)
        result = self.inspect()
        self.assertEqual(result["status"], "blocked")
        self.assertEqual(len(result["checks"]), 101)
        self.assertEqual(result["failures"][0]["name"], "last-failure")

    def test_pagination_finds_failure_after_first_hundred_jobs(self):
        names = tuple(f"job-{index}" for index in range(101))
        conclusions = ("success",) * 100 + ("failure",)
        self.api.action(names, conclusions)
        result = self.inspect()
        self.assertEqual(result["status"], "repair")
        self.assertEqual(len(result["checks"]), 101)
        self.assertEqual(result["failures"][0]["name"], "job-100")

    def test_status_pagination_not_limited_to_first_hundred_contexts(self):
        self.api.statuses = [{"id": index + 1, "context": f"status-{index}", "state": "success"} for index in range(100)]
        self.api.statuses.append({"id": 101, "context": "last", "state": "pending"})
        result = self.inspect()
        self.assertEqual(result["status"], "pending")
        self.assertEqual(len(result["checks"]), 101)

    def test_incomplete_api_page_never_becomes_green(self):
        self.api.external()
        self.api.totals[f"{PREFIX}/commits/{self.sha}/check-runs"] = 2
        self.assertEqual(self.inspect()["status"], "blocked")

    def test_api_timeout_is_blocked_not_green(self):
        self.api.external()

        def timeout(_):
            raise subprocess.TimeoutExpired("gh api", 30)

        self.api.overrides[f"{PREFIX}/actions/runs"] = timeout
        self.assertEqual(self.inspect()["status"], "blocked")

    def test_log_failure_does_not_prevent_other_failed_job_downloads(self):
        _, jobs = self.api.action(("first", "second"), ("failure", "failure"))
        self.api.overrides[f"{PREFIX}/actions/jobs/{jobs[0]['id']}/logs"] = Response({"message": "expired", "status": "410"}, 1)
        result = self.inspect()
        self.assertEqual(result["status"], "blocked")
        self.assertEqual(len(result["failures"]), 2)
        self.assertIsNone(result["failures"][0]["log_path"])
        self.assertTrue(Path(result["failures"][1]["log_path"]).is_file())
        self.assertEqual(len(list(self.output.rglob("*.log"))), 1)

    def test_final_head_api_failure_is_blocked(self):
        self.api.external()

        def pr_read(_):
            self.api.pr_reads += 1
            return self.api.pr if self.api.pr_reads == 1 else Response({"message": "unavailable", "status": "503"}, 1)

        self.api.overrides[f"{PREFIX}/pulls/17"] = pr_read
        self.assertEqual(self.inspect()["status"], "blocked")

    def test_public_diagnostics_directory_is_rejected_without_chmodding_it(self):
        self.api.action(conclusions=("failure",))
        self.output.mkdir(mode=0o755)
        self.output.chmod(0o755)
        result = self.inspect()
        self.assertEqual(result["status"], "blocked")
        self.assertEqual(stat.S_IMODE(self.output.stat().st_mode), 0o755)
        self.assertEqual(list(self.output.iterdir()), [])

    def test_symlink_diagnostics_directory_is_rejected(self):
        self.api.action(conclusions=("failure",))
        target = self.root / "target"
        target.mkdir(mode=0o700)
        self.output.symlink_to(target, target_is_directory=True)
        self.assertEqual(self.inspect()["status"], "blocked")
        self.assertEqual(list(target.iterdir()), [])

    def test_diagnostics_inside_worktree_are_rejected_before_creating_directory(self):
        self.api.action(conclusions=("failure",))
        self.output = self.worktree / "private"
        result = self.inspect()
        self.assertEqual(result["status"], "blocked")
        self.assertFalse(self.output.exists())

    def test_private_logs_in_own_git_metadata_are_available_on_normal_clone(self):
        self.api.action(conclusions=("failure",))
        self.output = self.worktree / ".git" / "makato-ci" / "17"
        result = self.inspect()
        self.assertEqual(result["status"], "repair")
        log = Path(result["failures"][0]["log_path"])
        self.assertTrue(log.is_relative_to(self.output))
        self.assertEqual(stat.S_IMODE(log.stat().st_mode), 0o600)
        tracked = REAL_RUN(["git", "-C", str(self.worktree), "status", "--porcelain"], capture_output=True, text=True, check=True).stdout
        self.assertEqual(tracked, "")

    def test_diagnostics_inside_another_git_repository_are_rejected(self):
        self.api.action(conclusions=("failure",))
        other = self.root / "other"
        REAL_RUN(["git", "init", "--quiet", str(other)], check=True)
        self.output = other / "private"
        self.assertEqual(self.inspect()["status"], "blocked")
        self.assertFalse(self.output.exists())

    def test_cli_emits_json_contract_and_zero_exit_for_actionable_result(self):
        self.api.action(conclusions=("failure",))
        output = io.StringIO()
        with patch.object(ci_checks.subprocess, "run", side_effect=self.api), redirect_stdout(output):
            code = ci_checks.main(["--repo", REPO, "--pr", "17", "--worktree", str(self.worktree), "--output-dir", str(self.output)])
        result = json.loads(output.getvalue())
        self.assertEqual(code, 0)
        self.assertEqual(result["status"], "repair")
        self.assertEqual(set(result), {"status", "head_sha", "pr_number", "checks", "failures", "errors"})
        self.assertEqual(set(result["failures"][0]), {"name", "workflow", "run_id", "job_id", "attempt", "log_path", "summary"})

    def test_partial_rerun_keeps_prior_successful_job_and_latest_failed_job_execution(self):
        old_run, old_jobs = self.api.action(("lint", "unit"), ("success", "failure"), attempt=1)
        self.api.runs.remove(old_run)
        self.api.action(("unit",), ("success",), attempt=2)
        self.api.required("lint", "unit", app_id=15368)
        result = self.inspect()
        self.assertEqual(result["status"], "green")
        self.assertEqual({(c["name"], c["attempt"]) for c in result["checks"]}, {("lint", 1), ("unit", 2)})
        self.assertEqual(result["failures"], [])

    def test_partial_rerun_failure_log_uses_actual_job_attempt(self):
        old_run, _ = self.api.action(("lint", "unit"), ("success", "failure"), attempt=1)
        self.api.runs.remove(old_run)
        self.api.action(("unit",), ("failure",), attempt=2)
        result = self.inspect()
        self.assertEqual(result["status"], "repair")
        self.assertEqual(len(result["failures"]), 1)
        self.assertEqual(result["failures"][0]["attempt"], 2)
        self.assertIn("attempt-2", result["failures"][0]["log_path"])

    def test_missing_job_name_returns_blocked_json_instead_of_crashing(self):
        _, jobs = self.api.action()
        del jobs[0]["name"]
        result = self.inspect()
        self.assertEqual(result["status"], "blocked")
        self.assertTrue(result["errors"])

    def test_malformed_external_diagnostic_is_blocked_not_green(self):
        self.api.external()["output"] = "invalid output"
        self.assertEqual(self.inspect()["status"], "blocked")

    def test_unknown_required_app_binding_cannot_be_satisfied_by_any_app(self):
        self.api.external()
        self.api.required("lint", app_id=99)
        assert self.api.protection is not None
        self.api.protection["requiredStatusChecks"][0]["app"]["databaseId"] = None
        self.assertEqual(self.inspect()["status"], "blocked")

    def test_workflow_run_pagination_selects_latest_run_after_first_hundred(self):
        for run_id in range(100, 200):
            self.api.action(run_id=run_id)
        self.api.action(run_id=200, conclusions=("failure",))
        result = self.inspect()
        self.assertEqual(result["status"], "repair")
        self.assertEqual({c["run_id"] for c in result["checks"]}, {200})

    def test_neutral_required_check_is_nonblocking(self):
        self.api.external(conclusion="neutral")
        self.api.required("lint")
        self.assertEqual(self.inspect()["status"], "green")

    def test_duplicate_display_names_in_same_attempt_do_not_hide_a_failure(self):
        self.api.action(("test", "test"), ("failure", "success"))
        result = self.inspect()
        self.assertEqual(result["status"], "repair")
        self.assertEqual(len(result["checks"]), 2)
        self.assertEqual(len(result["failures"]), 1)

    def test_summary_includes_actual_python_exception_diagnostic(self):
        _, jobs = self.api.action(conclusions=("failure",))
        self.api.logs[jobs[0]["id"]] = "setup\nAssertionError: invoice total 15 != 18\nFAILED (failures=1)\nfull teardown\n"
        result = self.inspect()
        self.assertIn("AssertionError: invoice total 15 != 18", result["failures"][0]["summary"])
        self.assertEqual(Path(result["failures"][0]["log_path"]).read_text(), self.api.logs[jobs[0]["id"]])

    def test_malformed_status_state_returns_blocked_instead_of_crashing(self):
        self.api.statuses = [{"id": 1, "context": "external", "state": {"unknown": True}}]
        self.assertEqual(self.inspect()["status"], "blocked")

    def test_malformed_base_branch_returns_blocked_instead_of_crashing(self):
        self.api.pr["base"]["ref"] = ["main"]
        self.assertEqual(self.inspect()["status"], "blocked")

    def test_invalid_paginated_total_cannot_authorize_green(self):
        self.api.external()
        self.api.totals[f"{PREFIX}/commits/{self.sha}/check-runs"] = True
        self.assertEqual(self.inspect()["status"], "blocked")


if __name__ == "__main__":
    unittest.main()
