#!/usr/bin/env python3
"""Read-only, SHA-bound PR CI inspection using the GitHub CLI and Python stdlib.

The JSON envelope is {status, head_sha, pr_number, checks, failures, errors}.
A valid invocation exits zero even for blocked/failed CI: callers MUST inspect status.
Only green permits progress; pending is an observation, never permission to repair.
Required skipped checks fail closed; optional skipped and neutral checks are accepted.
Logs are complete, attempt/job-pinned private files, outside tracked worktree paths.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import stat
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from urllib.parse import quote, urlencode, urlparse


class InspectionError(Exception):
    """An observation could not be established safely."""


class APIError(InspectionError):
    def __init__(self, message: str, http_status=None) -> None:
        self.message = message
        self.http_status = str(http_status)
        super().__init__(message)


class GitHub:
    """The only GitHub boundary; REST GETs and a read-only GraphQL query."""

    def __init__(self) -> None:
        self.deadline = time.monotonic() + 120

    def _run(self, args: list[str], *, stdout=None) -> subprocess.CompletedProcess:
        remaining = self.deadline - time.monotonic()
        if remaining <= 0:
            raise InspectionError("GitHub inspection deadline exceeded")
        env = {**os.environ, "GH_PROMPT_DISABLED": "1", "GH_NO_UPDATE_NOTIFIER": "1"}
        try:
            result = subprocess.run(
                ["gh", "api", *args],
                stdout=stdout or subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=stdout is None,
                timeout=min(30, remaining),
                env=env,
                check=False,
            )
        except subprocess.TimeoutExpired as exc:
            raise InspectionError("GitHub API request timed out") from exc
        except OSError as exc:
            raise InspectionError(f"Cannot execute GitHub CLI: {exc.strerror}") from exc
        if result.returncode:
            # Never include CLI stderr (which can contain credentials) or log contents.
            message = ""
            http_status = None
            if stdout is None:
                try:
                    body = json.loads(result.stdout)
                    if isinstance(body, dict) and isinstance(body.get("message"), str):
                        message = body["message"][:240]
                        http_status = body.get("status")
                except (ValueError, TypeError):
                    pass
            raise APIError(message or f"GitHub API request failed (exit {result.returncode})", http_status)
        return result

    def get(self, endpoint: str):
        try:
            return json.loads(self._run(["--method", "GET", endpoint]).stdout)
        except (ValueError, TypeError) as exc:
            raise InspectionError(f"Invalid JSON from GitHub API: {endpoint}") from exc

    def protection(self, owner: str, repo: str, base: str):
        query = (
            "query($owner:String!,$repo:String!,$ref:String!){"
            "repository(owner:$owner,name:$repo){ref(qualifiedName:$ref){"
            "branchProtectionRule{requiresStatusChecks requiredStatusCheckContexts "
            "requiredStatusChecks{context app{databaseId slug}}}}}}"
        )
        try:
            response = json.loads(
                self._run(
                    [
                        "graphql",
                        "-f",
                        f"query={query}",
                        "-f",
                        f"owner={owner}",
                        "-f",
                        f"repo={repo}",
                        "-f",
                        f"ref=refs/heads/{base}",
                    ]
                ).stdout
            )
            if not isinstance(response, dict):
                raise InspectionError("Invalid branch-protection response from GitHub")
            if response.get("errors"):
                raise InspectionError("GitHub GraphQL could not establish branch protection")
            ref = response["data"]["repository"]["ref"]
            if ref is None:
                raise InspectionError("PR base branch no longer exists")
            return ref["branchProtectionRule"]
        except (ValueError, TypeError, KeyError) as exc:
            raise InspectionError("Invalid branch-protection response from GitHub") from exc

    def pages(self, endpoint: str, key: str | None = None, **params) -> list[dict]:
        items: list[dict] = []
        expected = 0
        for page in range(1, 101):
            payload = self.get(f"{endpoint}?{urlencode({**params, 'per_page': 100, 'page': page})}")
            if key:
                if not isinstance(payload, dict) or type(payload.get("total_count")) is not int or payload["total_count"] < 0:
                    raise InspectionError(f"Invalid paginated response: {endpoint}")
                expected = max(expected, payload["total_count"])
                batch = payload.get(key)
            else:
                batch = payload
            if not isinstance(batch, list) or any(not isinstance(item, dict) for item in batch):
                raise InspectionError(f"Invalid paginated entries: {endpoint}")
            items.extend(batch)
            if len(batch) < 100:
                if len(items) < expected:
                    raise InspectionError(f"Incomplete GitHub pagination: {endpoint}")
                return items
        raise InspectionError(f"GitHub pagination limit exceeded: {endpoint}")

    def log(self, repo: str, job_id: int, path: Path) -> None:
        # A job ID is immutable and belongs to the verified run attempt. Unlike
        # `gh run view --log-failed`, this downloads the FULL job log, not excerpts.
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        try:
            with os.fdopen(fd, "wb") as output:
                # Raw log escape sequences are permitted only into this private
                # file, never a terminal (new gh versions otherwise reject logs).
                self._run(["--method", "GET", f"repos/{repo}/actions/jobs/{job_id}/logs", "--allow-escape-sequences"], stdout=output)
            if path.stat().st_size == 0:
                raise InspectionError(f"GitHub returned an empty log for job {job_id}")
        except (InspectionError, OSError):
            path.unlink(missing_ok=True)
            raise


def _git(worktree: Path, *args: str, allow_not_repo: bool = False) -> str:
    try:
        result = subprocess.run(
            ["git", "-C", str(worktree), *args],
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
            env={**os.environ, "LC_ALL": "C"},
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise InspectionError("Cannot inspect the local Git worktree") from exc
    if result.returncode:
        if allow_not_repo and result.returncode == 128 and "not a git repository" in result.stderr:
            return ""
        raise InspectionError(f"Cannot inspect local Git {' '.join(args)}")
    return result.stdout.strip()


def _private_directory(output: Path, worktree: Path) -> Path:
    if output.is_symlink():
        raise InspectionError("Diagnostics directory must not be a symlink")
    try:
        output = output.resolve()
        git_dir = Path(_git(worktree, "rev-parse", "--absolute-git-dir")).resolve()
        in_git_metadata = git_dir in output.parents
        if not in_git_metadata:
            if output == worktree or worktree in output.parents:
                raise InspectionError("Diagnostics directory must be outside tracked worktree paths")
            existing = output
            while not existing.exists():
                existing = existing.parent
            if _git(existing, "rev-parse", "--show-toplevel", allow_not_repo=True):
                raise InspectionError("Diagnostics directory must be outside every Git worktree")
        output.mkdir(mode=0o700, parents=True, exist_ok=True)
        info = output.stat()
        if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.geteuid() or info.st_mode & 0o077:
            raise InspectionError("Diagnostics directory must be owned by this user and mode 0700")
        private = Path(tempfile.mkdtemp(prefix="ci-", dir=output))
        private.chmod(0o700)
        return private
    except OSError as exc:
        raise InspectionError(f"Cannot create private diagnostics directory: {exc.strerror}") from exc


def _positive(value, label: str) -> int:
    if not isinstance(value, int) or isinstance(value, bool) or value <= 0:
        raise InspectionError(f"Missing or invalid {label} from GitHub")
    return value


def _snapshot(gh: GitHub, repo: str, number: int) -> dict:
    response = gh.get(f"repos/{repo}/pulls/{number}")
    try:
        sha = response["head"]["sha"]
        if not isinstance(sha, str) or not re.fullmatch(r"[0-9a-f]{40,64}", sha):
            raise ValueError
        if response["number"] != number or response["state"] not in {"open", "closed"}:
            raise ValueError
        if not isinstance(response["merged"], bool):
            raise ValueError
        if any(not isinstance(response[side]["ref"], str) or not response[side]["ref"] for side in ("head", "base")):
            raise ValueError
        return response
    except (KeyError, TypeError, ValueError) as exc:
        raise InspectionError("Invalid PR identity/state returned by GitHub") from exc


def _requirements(gh: GitHub, repo: str, base: str) -> set[tuple[str, int | None]]:
    owner, name = repo.split("/")
    protection = gh.protection(owner, name, base)
    required: set[tuple[str, int | None]] = set()

    def add(context, app_id=None) -> None:
        if not isinstance(context, str) or not context:
            raise InspectionError("Invalid required-check context returned by GitHub")
        if app_id is not None and (not isinstance(app_id, int) or isinstance(app_id, bool)):
            raise InspectionError("Invalid required-check app binding returned by GitHub")
        required.add((context, app_id if app_id is not None and app_id > 0 else None))

    if protection is not None:
        if not isinstance(protection, dict) or not isinstance(protection.get("requiresStatusChecks"), bool):
            raise InspectionError("Incomplete classic branch-protection metadata")
        if protection["requiresStatusChecks"]:
            checks = protection.get("requiredStatusChecks")
            contexts = protection.get("requiredStatusCheckContexts")
            if not isinstance(checks, list) or not isinstance(contexts, list):
                raise InspectionError("Unknown classic required-check inventory")
            for check in checks:
                if not isinstance(check, dict):
                    raise InspectionError("Invalid classic required-check metadata")
                app = check.get("app")
                if app is not None and not isinstance(app, dict):
                    raise InspectionError("Invalid required-check GitHub App")
                if app is not None:
                    _positive(app.get("databaseId"), "required-check GitHub App ID")
                add(check.get("context"), app.get("databaseId") if app else None)
            for context in contexts:
                if not any(item[0] == context for item in required):
                    add(context)
    try:
        rules = gh.get(f"repos/{repo}/rules/branches/{quote(base, safe='')}")
    except APIError as exc:
        # This exact feature-availability error proves rulesets are disabled
        # for the repository plan; it is NOT a generic authorization fallback.
        unsupported = "Upgrade to GitHub Pro or make this repository public to enable this feature."
        if exc.http_status != "403" or exc.message != unsupported or protection is not None:
            raise
        branch = gh.get(f"repos/{repo}/branches/{quote(base, safe='')}")
        if not isinstance(branch, dict) or branch.get("name") != base or branch.get("protected") is not False:
            raise InspectionError("Cannot establish that rulesets and classic protection are disabled")
        rules = []
    if not isinstance(rules, list):
        raise InspectionError("Unknown active branch-rules inventory")
    for rule in rules:
        if not isinstance(rule, dict) or not isinstance(rule.get("type"), str):
            raise InspectionError("Invalid active branch rule")
        if rule["type"] == "required_status_checks":
            parameters = rule.get("parameters")
            checks = parameters.get("required_status_checks") if isinstance(parameters, dict) else None
            if not isinstance(checks, list):
                raise InspectionError("Unknown ruleset required-check inventory")
            for check in checks:
                if not isinstance(check, dict):
                    raise InspectionError("Invalid ruleset required-check metadata")
                add(check.get("context"), check.get("integration_id"))
        elif rule["type"] in {"workflows", "required_workflows"}:
            raise InspectionError("Required-workflow rules cannot be resolved as status-check contexts")
    return required


def _state(status, conclusion) -> str:
    if not isinstance(status, str) or not isinstance(conclusion, (str, type(None))):
        return "unknown"
    if status in {"queued", "in_progress", "waiting", "pending", "requested"}:
        return "pending"
    if status != "completed":
        return "unknown"
    if conclusion in {"success", "neutral"}:
        return "success"
    if conclusion == "skipped":
        return "skipped"
    if conclusion in {"failure", "cancelled", "timed_out", "action_required", "startup_failure", "stale"}:
        return "failure"
    return "unknown"


def _check(name: str, source: str, status, conclusion, *, workflow=None, run_id=None, job_id=None, attempt=None, app_id=None, details_url=None) -> dict:
    if not isinstance(name, str) or not name:
        raise InspectionError("A check has no name/context")
    return {
        "name": name,
        "workflow": workflow,
        "state": _state(status, conclusion),
        "conclusion": conclusion,
        "required": False,
        "source": source,
        "run_id": run_id,
        "job_id": job_id,
        "attempt": attempt,
        "app_id": app_id,
        "details_url": details_url,
    }


def _actions_ids(check: dict, repo: str) -> tuple[int, int] | None:
    url = check.get("details_url") or ""
    if not isinstance(url, str):
        return None
    match = re.fullmatch(r"/([^/]+/[^/]+)/actions/runs/(\d+)/job/(\d+)/?", urlparse(url).path)
    if match and match[1].lower() == repo.lower():
        return int(match[2]), int(match[3])
    return None


def _validate_run(run: dict, sha: str, run_id=None, attempt=None) -> None:
    if not isinstance(run, dict):
        raise InspectionError("Invalid Actions run metadata")
    _positive(run.get("id"), "Actions run ID")
    _positive(run.get("run_attempt"), "Actions attempt")
    _positive(run.get("workflow_id"), "Actions workflow ID")
    if run.get("head_sha") != sha:
        raise InspectionError(f"Actions run {run['id']} is not for the inspected PR HEAD")
    if run_id is not None and run["id"] != run_id:
        raise InspectionError("GitHub returned the wrong Actions run")
    if attempt is not None and run["run_attempt"] != attempt:
        raise InspectionError("GitHub returned the wrong Actions attempt")
    if not isinstance(run.get("name"), str) or not run["name"]:
        raise InspectionError("Actions workflow name is unavailable")


def _validate_job(job: dict, run: dict, sha: str, *, allow_earlier: bool = False) -> None:
    if not isinstance(job, dict):
        raise InspectionError("Invalid Actions job metadata")
    _positive(job.get("id"), "Actions job ID")
    attempt = _positive(job.get("run_attempt"), "Actions job attempt")
    if job.get("run_id") != run["id"] or (attempt != run["run_attempt"] and not (allow_earlier and attempt < run["run_attempt"])):
        raise InspectionError(f"Actions job {job['id']} does not belong to the pinned run attempt")
    if job.get("head_sha", sha) != sha:
        raise InspectionError(f"Actions job {job['id']} has a different HEAD SHA")
    if not isinstance(job.get("name"), str) or not job["name"]:
        raise InspectionError("Actions job name is unavailable")
    if job.get("check_run_url") is not None and not isinstance(job["check_run_url"], str):
        raise InspectionError("Invalid Actions job check-run identity")
    steps = job.get("steps", [])
    if not isinstance(steps, list) or any(not isinstance(step, dict) or not isinstance(step.get("name"), str) for step in steps):
        raise InspectionError("Invalid Actions job step diagnostics")


def _summary(check: dict, job: dict | None, path: Path | None, diagnostic: str = "") -> str:
    summary = f"{check['name']}: {check['conclusion'] or check['state']}"
    if check["required"] and check["state"] == "skipped":
        summary += "; required skipped checks fail closed"
    if job:
        steps = [step.get("name", "unnamed step") for step in job.get("steps", []) if step.get("conclusion") in ("failure", "cancelled", "timed_out")]
        if steps:
            summary += "; steps: " + ", ".join(steps)
    if path:
        excerpts = []
        with path.open(encoding="utf-8", errors="replace") as lines:
            for line in lines:
                if re.search(r"##\[error\]|\berror:|\bFAILED\b|\b[A-Za-z_]*(?:Error|Exception):", line):
                    excerpts.append(line.strip()[:240])
                    if len(excerpts) == 3:
                        break
        if excerpts:
            summary += "; " + " | ".join(excerpts)
    elif diagnostic:
        summary += "; " + diagnostic[:600]
    return summary[:1000]


def inspect(repo: str, number: int, worktree: Path, output: Path, gh: GitHub | None = None) -> dict:
    """Inspect all latest checks; never repair, push, rerun, or edit the worktree."""
    gh = gh or GitHub()
    result = {"status": "blocked", "head_sha": None, "pr_number": number, "checks": [], "failures": [], "errors": []}
    errors = result["errors"]
    try:
        first = _snapshot(gh, repo, number)
    except InspectionError as exc:
        errors.append(str(exc))
        return result
    sha = result["head_sha"] = first["head"]["sha"]
    worktree = worktree.resolve()
    private = None
    try:
        private = _private_directory(output, worktree)
    except InspectionError as exc:
        errors.append(str(exc))

    required = set()
    try:
        required = _requirements(gh, repo, first["base"]["ref"])
    except InspectionError as exc:
        errors.append(f"Required-check inventory unavailable: {exc}")

    raw_checks: list[dict] = []
    statuses: list[dict] = []
    runs: list[dict] = []
    for endpoint, key, params, destination in [
        (f"repos/{repo}/commits/{sha}/check-runs", "check_runs", {"filter": "all"}, raw_checks),
        (f"repos/{repo}/commits/{sha}/statuses", None, {}, statuses),
        (f"repos/{repo}/actions/runs", "workflow_runs", {"head_sha": sha}, runs),
    ]:
        try:
            destination.extend(gh.pages(endpoint, key, **params))
        except InspectionError as exc:
            errors.append(f"Cannot enumerate {endpoint}: {exc}")

    checks = result["checks"]
    external: dict[tuple, dict] = {}
    raw_by_id = {}
    diagnostics: dict[tuple, str] = {}
    for raw in raw_checks:
        try:
            raw_id = _positive(raw.get("id"), "check-run ID")
            if raw.get("head_sha") != sha:
                raise InspectionError(f"Check {raw_id} is not for the inspected PR HEAD")
            if not isinstance(raw.get("name"), str) or not raw["name"]:
                raise InspectionError(f"Check {raw_id} has no name/context")
            app = raw.get("app")
            if not isinstance(app, dict):
                raise InspectionError(f"Check {raw_id} has unknown GitHub App identity")
            _positive(app.get("id"), "check-run app ID")
            raw_by_id[raw_id] = raw
            if app.get("slug") == "github-actions":
                continue
            check = _check(raw["name"], "check", raw.get("status"), raw.get("conclusion"), app_id=app["id"], details_url=raw.get("details_url"))
            key = (check["name"], app["id"])
            if key not in external or raw_id > external[key]["id"]:
                external[key] = {"id": raw_id, "check": check}
                details = raw.get("output") or {}
                if not isinstance(details, dict):
                    raise InspectionError(f"Check {raw_id} has invalid diagnostic output")
                diagnostics[("check", *key)] = "\n".join(str(details.get(field) or "") for field in ("title", "summary", "text"))
        except InspectionError as exc:
            errors.append(str(exc))
    checks.extend(item["check"] for item in external.values())

    latest_status: dict[str, dict] = {}
    for raw in statuses:
        try:
            _positive(raw.get("id"), "commit-status ID")
            context = raw.get("context")
            if not isinstance(context, str) or not context:
                raise InspectionError("Commit status has no context")
            if context not in latest_status or raw["id"] > latest_status[context]["id"]:
                latest_status[context] = raw
        except InspectionError as exc:
            errors.append(str(exc))
    for context, raw in latest_status.items():
        state = raw.get("state")
        check = _check(context, "status", "completed", state, details_url=raw.get("target_url"))
        check["state"] = {"success": "success", "failure": "failure", "error": "failure", "pending": "pending"}.get(state, "unknown") if isinstance(state, str) else "unknown"
        checks.append(check)
        diagnostics[("status", context, None)] = str(raw.get("description") or "")

    latest_runs: dict[int, dict] = {}
    all_runs = {}
    for run in runs:
        try:
            _validate_run(run, sha)
            all_runs[run["id"]] = run
            old = latest_runs.get(run["workflow_id"])
            if old is None or (run["id"], run["run_attempt"]) > (old["id"], old["run_attempt"]):
                latest_runs[run["workflow_id"]] = run
        except InspectionError as exc:
            errors.append(str(exc))

    jobs_by_id: dict[int, dict] = {}
    pinned_runs = {}
    for latest in latest_runs.values():
        run_id, attempt = latest["id"], latest["run_attempt"]
        try:
            run = gh.get(f"repos/{repo}/actions/runs/{run_id}/attempts/{attempt}")
            _validate_run(run, sha, run_id, attempt)
            pinned_runs[run_id] = run
            jobs = gh.pages(f"repos/{repo}/actions/runs/{run_id}/attempts/{attempt}/jobs", "jobs")
            for job in jobs:
                _validate_job(job, run, sha)
                jobs_by_id[job["id"]] = job
            run_state = _state(run.get("status"), run.get("conclusion"))
            job_failed = any(_state(job.get("status"), job.get("conclusion")) == "failure" for job in jobs)
            if not jobs or run.get("status") != "completed" or run_state == "unknown" or (run_state == "failure" and not job_failed):
                checks.append(
                    _check(
                        run["name"],
                        "actions",
                        run.get("status"),
                        run.get("conclusion"),
                        workflow=run["name"],
                        run_id=run_id,
                        attempt=attempt,
                        details_url=run.get("html_url"),
                    )
                )
        except InspectionError as exc:
            errors.append(f"Cannot inspect Actions run {run_id} attempt {attempt}: {exc}")

    # Jobs from a previous attempt are still effective when GitHub reruns only
    # failed jobs. Keep the latest execution per job name within the latest run;
    # never resurrect an older failure if that job was rerun successfully.
    attempt_changed = False
    for raw_id, raw in raw_by_id.items():
        if raw["app"].get("slug") != "github-actions":
            continue
        ids = _actions_ids(raw, repo)
        if not ids:
            errors.append(f"Cannot resolve Actions check {raw['name']} to a run and job")
            continue
        run_id, job_id = ids
        if run_id not in all_runs:
            errors.append(f"Actions check {raw['name']} has an unenumerated run {run_id}")
        elif run_id in pinned_runs and job_id not in jobs_by_id:
            try:
                job = gh.get(f"repos/{repo}/actions/jobs/{job_id}")
                if not isinstance(job, dict):
                    raise InspectionError("Invalid Actions job metadata")
                job_attempt = _positive(job.get("run_attempt"), "Actions job attempt")
                if job.get("run_id") != run_id or job.get("head_sha", sha) != sha:
                    raise InspectionError("Unmapped Actions job identity does not match PR HEAD/run")
                if job_attempt <= pinned_runs[run_id]["run_attempt"]:
                    _validate_job(job, pinned_runs[run_id], sha, allow_earlier=True)
                    jobs_by_id[job_id] = job
                else:
                    attempt_changed = True
            except InspectionError as exc:
                errors.append(f"Cannot resolve Actions job {job_id}: {exc}")

    latest_job_attempt = {}
    for job in jobs_by_id.values():
        key = (job["run_id"], job["name"])
        latest_job_attempt[key] = max(latest_job_attempt.get(key, 0), job["run_attempt"])
    jobs_by_id = {job["id"]: job for job in jobs_by_id.values() if job["run_attempt"] == latest_job_attempt[(job["run_id"], job["name"])]}

    for job in jobs_by_id.values():
        run = pinned_runs[job["run_id"]]
        check_url = urlparse(job.get("check_run_url") or "").path
        match = re.search(r"/check-runs/(\d+)$", check_url)
        raw = raw_by_id.get(int(match[1]) if match else job["id"], {})
        checks.append(
            _check(
                job["name"],
                "actions",
                job.get("status"),
                job.get("conclusion"),
                workflow=run["name"],
                run_id=run["id"],
                job_id=job["id"],
                attempt=job["run_attempt"],
                app_id=(raw.get("app") or {}).get("id"),
                details_url=job.get("html_url"),
            )
        )

    for context, app_id in sorted(required, key=lambda item: (item[0], item[1] or 0)):
        matching = [check for check in checks if check["name"] == context and (app_id is None or check["app_id"] == app_id)]
        for check in matching:
            check["required"] = True
        if not matching:
            missing = _check(context, "required", None, None, app_id=app_id)
            missing.update(state="missing", required=True)
            checks.append(missing)

    # Multiple failures are collected independently; a bad/missing log never
    # prevents downloading the remaining jobs' full diagnostics.
    for check in checks:
        if check["state"] == "unknown":
            errors.append(f"Unknown check state: {check['name']} ({check['conclusion']})")
        if check["state"] != "failure" and not (check["required"] and check["state"] == "skipped"):
            continue
        job = jobs_by_id.get(check["job_id"])
        log_path = None
        if check["source"] == "actions" and job and private:
            candidate = private / f"run-{check['run_id']}-attempt-{check['attempt']}-job-{check['job_id']}.log"
            try:
                gh.log(repo, check["job_id"], candidate)
                log_path = candidate
            except (InspectionError, OSError) as exc:
                errors.append(f"Cannot obtain full log for job {check['job_id']}: {exc}")
        key = (check["source"], check["name"], check["app_id"])
        try:
            summary = _summary(check, job, log_path, diagnostics.get(key, ""))
        except OSError as exc:
            errors.append(f"Cannot summarize private log for {check['name']}: {exc.strerror}")
            summary = f"{check['name']}: {check['conclusion']}"
        result["failures"].append(
            {
                "name": check["name"],
                "workflow": check["workflow"],
                "run_id": check["run_id"],
                "job_id": check["job_id"],
                "attempt": check["attempt"],
                "log_path": str(log_path) if log_path else None,
                "summary": summary,
            }
        )

    for run_id, pinned in pinned_runs.items():
        try:
            current = gh.get(f"repos/{repo}/actions/runs/{run_id}")
            _validate_run(current, sha, run_id)
            if current["run_attempt"] != pinned["run_attempt"] or current.get("status") != pinned.get("status") or current.get("conclusion") != pinned.get("conclusion"):
                attempt_changed = True
        except InspectionError as exc:
            errors.append(f"Cannot recheck Actions run {run_id}: {exc}")

    # HEAD is deliberately re-read after diagnostics and run-attempt validation.
    try:
        final = _snapshot(gh, repo, number)
    except InspectionError as exc:
        errors.append(f"Cannot recheck PR HEAD: {exc}")
        return result
    if final["head"]["sha"] != sha or final["head"]["ref"] != first["head"]["ref"] or final["base"]["ref"] != first["base"]["ref"]:
        result["status"] = "stale"
        errors.append("PR HEAD or target changed during CI inspection; inspect the new target")
        return result
    if final["state"] == "closed" or final["merged"]:
        result["status"] = "closed"
        return result
    try:
        if Path(_git(worktree, "rev-parse", "--show-toplevel")).resolve() != worktree:
            raise InspectionError("--worktree must identify the worktree root")
        if _git(worktree, "symbolic-ref", "--quiet", "--short", "HEAD") != final["head"]["ref"]:
            raise InspectionError("Local worktree branch does not match the PR head branch")
        if _git(worktree, "rev-parse", "HEAD") != sha:
            raise InspectionError("Local worktree HEAD does not match the inspected PR HEAD")
    except InspectionError as exc:
        errors.append(str(exc))
    if errors:
        return result
    if attempt_changed or not checks or any(check["state"] in {"pending", "missing"} for check in checks):
        result["status"] = "pending"
    elif result["failures"]:
        # External failures and run-level failures without job logs are visible,
        # but do not authorize speculative local repair from incomplete evidence.
        result["status"] = "repair" if all(failure["log_path"] for failure in result["failures"]) else "blocked"
        if result["status"] == "blocked":
            errors.append("Terminal checks lack full Actions job logs; cannot authorize local CI repair")
    else:
        result["status"] = "green"
    return result


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", required=True, help="OWNER/REPO")
    parser.add_argument("--pr", required=True, type=int)
    parser.add_argument("--worktree", required=True, type=Path)
    parser.add_argument("--output-dir", required=True, type=Path)
    args = parser.parse_args(argv)
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]*/[A-Za-z0-9][A-Za-z0-9_.-]*", args.repo) or args.pr <= 0:
        parser.error("--repo must be OWNER/REPO and --pr must be positive")
    print(json.dumps(inspect(args.repo, args.pr, args.worktree, args.output_dir), sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
