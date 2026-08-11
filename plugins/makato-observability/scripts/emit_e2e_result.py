#!/usr/bin/env python3
"""emit_e2e_result.py — Emit E2E pass/fail result to Langfuse as a structured trace.

Reads the E2E outcome from the most recent ``build.jsonl`` entry with
``step:"runtime-qa-findings"`` and emits a Langfuse trace under the makato
project via the Langfuse Python SDK.

Credential resolution (3-tier priority, identical to langfuse_hook.py):
  1. Environment variables: LANGFUSE_PUBLIC_KEY / LANGFUSE_SECRET_KEY / LANGFUSE_HOST
  2. .env file at the repository root (KEY=value format)
  3. ~/.zshrc managed block (compatibility)

Usage:
    python3 emit_e2e_result.py [--key <issue-key>] [--dry-run]

Arguments:
    --key      Spec folder key to search (e.g. "makato-harness-independence").
               When omitted, the most recently modified specs/*/build.jsonl is used.
    --dry-run  Print the trace payload to stdout without emitting to Langfuse.

Exit codes:
    0   Trace emitted (or dry-run printed)
    1   Langfuse credentials missing or host unreachable
    2   No runtime-qa-findings entry found in build.jsonl
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

# ---------------------------------------------------------------------------
# Helpers shared with langfuse_hook.py — keep in sync when patterns change.
# ---------------------------------------------------------------------------

DEBUG = os.environ.get("LANGFUSE_DEBUG", "").lower() == "true"


def debug(msg: str) -> None:
    if DEBUG:
        print(f"[emit_e2e_result DEBUG] {msg}", file=sys.stderr)


def _parse_dotenv(path: Path) -> dict[str, str]:
    """Parse a simple KEY=value .env file. Ignores comments and blank lines."""
    result: dict[str, str] = {}
    try:
        for line in path.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            if "=" not in line:
                continue
            key, _, val = line.partition("=")
            key = key.strip()
            val = val.strip().strip("'\"")
            if key:
                result[key] = val
    except Exception:
        pass
    return result


def _find_dotenv() -> dict[str, str]:
    """Look for .env in repo root (scripts/ → plugin → plugins → repo) or CWD."""
    candidates = [
        Path(__file__).parent.parent.parent.parent / ".env",  # scripts/ → plugin → plugins → repo
        Path(os.environ.get("PWD", "")) / ".env",
        Path.cwd() / ".env",
    ]
    for p in candidates:
        if p.exists():
            debug(f"Loading .env from {p}")
            return _parse_dotenv(p)
    return {}


def _read_zshrc_exports() -> dict[str, str]:
    zshrc = Path.home() / ".zshrc"
    if not zshrc.exists():
        return {}
    try:
        content = zshrc.read_text(encoding="utf-8")
        return {m.group(1): m.group(2) for m in re.finditer(r"export\s+(\w+)='([^']*)'", content)}
    except Exception:
        return {}


def _resolve_credentials() -> tuple[str | None, str | None, str]:
    """Return (public_key, secret_key, host) using the 3-tier resolution from langfuse_hook.py."""
    # Priority 1: environment
    public_key = os.environ.get("LANGFUSE_PUBLIC_KEY")
    secret_key = os.environ.get("LANGFUSE_SECRET_KEY")
    host = os.environ.get("LANGFUSE_HOST", "")

    # Priority 2: .env file
    if not public_key or not secret_key:
        dotenv = _find_dotenv()
        public_key = public_key or dotenv.get("LANGFUSE_PUBLIC_KEY")
        secret_key = secret_key or dotenv.get("LANGFUSE_SECRET_KEY")
        host = host or dotenv.get("LANGFUSE_HOST", "")

    # Priority 3: ~/.zshrc managed block
    if not public_key or not secret_key:
        zshrc = _read_zshrc_exports()
        public_key = public_key or zshrc.get("LANGFUSE_PUBLIC_KEY")
        secret_key = secret_key or zshrc.get("LANGFUSE_SECRET_KEY")
        host = host or zshrc.get("LANGFUSE_HOST", "")

    if not host:
        debug("LANGFUSE_HOST not set; traces disabled")

    return public_key, secret_key, host


def _check_langfuse_reachable(host: str, timeout: float = 3.0) -> bool:
    """Return True if the Langfuse health endpoint responds with a status field."""
    health_url = host.rstrip("/") + "/api/public/health"
    try:
        with urllib.request.urlopen(health_url, timeout=timeout) as resp:  # noqa: S310
            return '"status"' in resp.read().decode("utf-8", errors="replace")
    except Exception:
        return False


# ---------------------------------------------------------------------------
# build.jsonl discovery
# ---------------------------------------------------------------------------

def _find_repo_root() -> Path:
    """Resolve the repository root by walking up from this script."""
    here = Path(__file__).resolve()
    for parent in here.parents:
        if (parent / ".git").exists():
            return parent
    return Path.cwd()


def _find_build_jsonl(key: str | None, specs_dir: Path) -> Path | None:
    """Return the build.jsonl path for the given key, or the most recent one."""
    if key:
        candidates = sorted(specs_dir.glob(f"{key}*/build.jsonl"))
        if candidates:
            return candidates[0]
        # Exact-match fallback
        exact = specs_dir / key / "build.jsonl"
        if exact.exists():
            return exact
        return None
    # No key: pick the most recently modified build.jsonl across all specs
    all_candidates = list(specs_dir.rglob("build.jsonl"))
    if not all_candidates:
        return None
    return max(all_candidates, key=lambda p: p.stat().st_mtime)


def _read_last_runtime_qa_finding(build_jsonl: Path) -> dict[str, Any] | None:
    """Return the most recent step:"runtime-qa-findings" entry from build.jsonl."""
    last_entry: dict[str, Any] | None = None
    try:
        for raw in build_jsonl.read_text(encoding="utf-8").splitlines():
            raw = raw.strip()
            if not raw:
                continue
            try:
                entry = json.loads(raw)
            except json.JSONDecodeError:
                continue
            if entry.get("step") == "runtime-qa-findings":
                last_entry = entry
    except Exception as exc:
        debug(f"Could not read {build_jsonl}: {exc}")
    return last_entry


# ---------------------------------------------------------------------------
# Trace emission
# ---------------------------------------------------------------------------

def _emit_trace(
    public_key: str,
    secret_key: str,
    host: str,
    finding: dict[str, Any],
    dry_run: bool,
) -> None:
    """Emit a Langfuse trace for the runtime-qa-findings entry."""
    try:
        from langfuse import Langfuse  # type: ignore[import-untyped]
    except ImportError:
        print("[emit_e2e_result] ERROR: langfuse package not installed; run `pip install langfuse`", file=sys.stderr)
        sys.exit(1)

    ts = finding.get("ts", datetime.now(tz=timezone.utc).isoformat())
    story = finding.get("story", "unknown")
    data = finding.get("data", {})
    outcome = data.get("outcome", data.get("status", "unknown"))
    critical_count = data.get("critical_count", 0)
    finding_summary = data.get("summary", "E2E run result")

    trace_payload: dict[str, Any] = {
        "name": f"e2e-result:{story}",
        "metadata": {
            "story": story,
            "outcome": outcome,
            "critical_count": critical_count,
            "ts": ts,
            "source": "build.jsonl:runtime-qa-findings",
        },
        "tags": ["e2e", "runtime-qa", story],
        "input": {"story": story, "finding": finding},
        "output": {"outcome": outcome, "summary": finding_summary},
    }

    if dry_run:
        print("[emit_e2e_result] DRY-RUN — trace payload:")
        print(json.dumps(trace_payload, indent=2))
        return

    client = Langfuse(  # type: ignore[reportAttributeAccessIssue]
        public_key=public_key,
        secret_key=secret_key,
        host=host,
    )
    trace = client.trace(**trace_payload)  # type: ignore[reportAttributeAccessIssue]
    client.flush()
    print(f"[emit_e2e_result] Trace emitted: id={trace.id} story={story} outcome={outcome}", file=sys.stderr)
    # Emit JSONL audit entry to stderr for integration with build.jsonl consumers
    audit = {
        "ts": datetime.now(tz=timezone.utc).isoformat(),
        "skill": "emit_e2e_result",
        "story": story,
        "step": "trace-emitted",
        "status": "ok",
        "data": {"trace_id": trace.id, "outcome": outcome, "critical_count": critical_count},
    }
    print(json.dumps(audit), file=sys.stderr)


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--key", default=None, help="Spec folder key (e.g. makato-harness-independence)")
    parser.add_argument("--dry-run", action="store_true", help="Print trace payload without emitting")
    args = parser.parse_args()

    # Resolve credentials
    public_key, secret_key, host = _resolve_credentials()

    if not args.dry_run:
        if not public_key or not secret_key:
            print("[emit_e2e_result] ERROR: LANGFUSE_PUBLIC_KEY and LANGFUSE_SECRET_KEY must be set", file=sys.stderr)
            return 1
        if not host:
            print("[emit_e2e_result] ERROR: LANGFUSE_HOST must be set", file=sys.stderr)
            return 1
        if not _check_langfuse_reachable(host):
            print(f"[emit_e2e_result] ERROR: Langfuse host not reachable: {host}", file=sys.stderr)
            return 1

    # Find build.jsonl
    repo_root = _find_repo_root()
    specs_dir = repo_root / "specs"
    build_jsonl = _find_build_jsonl(args.key, specs_dir)
    if not build_jsonl:
        print(f"[emit_e2e_result] ERROR: No build.jsonl found under {specs_dir} (key={args.key})", file=sys.stderr)
        return 2

    debug(f"Using build.jsonl: {build_jsonl}")

    # Read most recent runtime-qa-findings entry
    finding = _read_last_runtime_qa_finding(build_jsonl)
    if not finding:
        print(f"[emit_e2e_result] ERROR: No step:runtime-qa-findings entry in {build_jsonl}", file=sys.stderr)
        return 2

    debug(f"Found runtime-qa-findings: {json.dumps(finding)[:200]}")

    # Emit trace
    _emit_trace(
        public_key=public_key or "",
        secret_key=secret_key or "",
        host=host,
        finding=finding,
        dry_run=args.dry_run,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
