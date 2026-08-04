#!/usr/bin/env python3
"""Claude Code → Langfuse session tracing hook.

Fires on Stop events. Reads the session JSONL transcript incrementally,
emits structured per-turn traces to Langfuse.

Credentials are loaded from (in priority order):
  1. Environment variables: CC_LANGFUSE_PUBLIC_KEY / CC_LANGFUSE_SECRET_KEY / CC_LANGFUSE_BASE_URL
  2. .env file at MAKATO_ROOT/.env  (dotenv-style, KEY=value lines)
  3. ~/.zshrc managed block (compatibility with impact-claude-market setup)

Opt-in gate: TRACE_TO_LANGFUSE=true (env or .env file).
"""

import contextlib
import hashlib
import json
import os
import re
import sys
import time
import urllib.request
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

try:
    import fcntl as _fcntl
except ImportError:
    _fcntl = None  # type: ignore[assignment]

try:
    from langfuse import Langfuse, propagate_attributes  # type: ignore[import-untyped]
except Exception:
    sys.exit(0)

STATE_DIR = Path.home() / ".claude" / "state"
LOG_FILE = STATE_DIR / "langfuse_hook_makato.log"
STATE_FILE = STATE_DIR / "langfuse_state_makato.json"
LOCK_FILE = STATE_DIR / "langfuse_state_makato.lock"

DEBUG = os.environ.get("CC_LANGFUSE_DEBUG", "").lower() == "true"
MAX_CHARS = int(os.environ.get("CC_LANGFUSE_MAX_CHARS", "20000"))

SENSITIVE_KEYS = frozenset(
    {
        "password", "secret", "token", "api_key", "apikey",
        "credential", "private_key", "secret_key", "access_key", "webhook",
    }
)
SENSITIVE_PREFIXES = ("sk-", "pk-lf-", "sk-lf-", "AKIA", "ghp_", "ghs_")
_MAX_SANITIZE_DEPTH = 5
_SENSITIVE_VALUE_RE = re.compile(
    r"(sk-[a-zA-Z0-9]{10,}|pk-lf-[a-f0-9-]+|AKIA[A-Z0-9]{12,}|ghp_[a-zA-Z0-9]{30,})"
)


# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

def _log(level: str, message: str) -> None:
    try:
        STATE_DIR.mkdir(parents=True, exist_ok=True)
        ts = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S")
        with open(LOG_FILE, "a", encoding="utf-8") as f:
            f.write(f"{ts} [{level}] {message}\n")
    except Exception:
        pass


def debug(msg: str) -> None:
    if DEBUG:
        _log("DEBUG", msg)


def info(msg: str) -> None:
    _log("INFO", msg)


def error(msg: str) -> None:
    _log("ERROR", msg)


# ---------------------------------------------------------------------------
# Sanitisation
# ---------------------------------------------------------------------------

def sanitize_value(val: str) -> str:
    if not val:
        return val
    for prefix in SENSITIVE_PREFIXES:
        if val.startswith(prefix) and len(val) > len(prefix) + 4:
            return f"{prefix}***REDACTED***"
    return _SENSITIVE_VALUE_RE.sub("***REDACTED***", val)


def sanitize_dict(d: Any, depth: int = 0) -> Any:
    if depth > _MAX_SANITIZE_DEPTH:
        return d
    if isinstance(d, dict):
        return {
            k: "***REDACTED***" if any(sk in k.lower() for sk in SENSITIVE_KEYS)
            else sanitize_dict(v, depth + 1)
            for k, v in d.items()
        }
    if isinstance(d, list):
        return [sanitize_dict(item, depth + 1) for item in d]
    if isinstance(d, str):
        return sanitize_value(d)
    return d


# ---------------------------------------------------------------------------
# Credential resolution — env → .env file → ~/.zshrc managed block
# ---------------------------------------------------------------------------

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
    """Look for .env in MAKATO_ROOT (script's repo root) or CWD."""
    # Try: repo root via __file__ (hooks/ → plugin → plugins → repo root)
    candidates = [
        Path(__file__).parent.parent.parent.parent / ".env",  # plugins/makato-observability/hooks → repo
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
    # Priority 1: environment
    public_key = os.environ.get("CC_LANGFUSE_PUBLIC_KEY") or os.environ.get("LANGFUSE_PUBLIC_KEY")
    secret_key = os.environ.get("CC_LANGFUSE_SECRET_KEY") or os.environ.get("LANGFUSE_SECRET_KEY")
    host = (
        os.environ.get("CC_LANGFUSE_BASE_URL")
        or os.environ.get("LANGFUSE_BASE_URL")
        or ""
    )

    # Priority 2: .env file
    if not public_key or not secret_key:
        dotenv = _find_dotenv()
        public_key = public_key or dotenv.get("CC_LANGFUSE_PUBLIC_KEY") or dotenv.get("LANGFUSE_PUBLIC_KEY")
        secret_key = secret_key or dotenv.get("CC_LANGFUSE_SECRET_KEY") or dotenv.get("LANGFUSE_SECRET_KEY")
        host = host or dotenv.get("CC_LANGFUSE_BASE_URL") or dotenv.get("LANGFUSE_BASE_URL") or ""

    # Priority 3: ~/.zshrc managed block (compatibility)
    if not public_key or not secret_key:
        zshrc = _read_zshrc_exports()
        public_key = public_key or zshrc.get("CC_LANGFUSE_PUBLIC_KEY") or zshrc.get("LANGFUSE_PUBLIC_KEY")
        secret_key = secret_key or zshrc.get("CC_LANGFUSE_SECRET_KEY") or zshrc.get("LANGFUSE_SECRET_KEY")
        host = host or zshrc.get("CC_LANGFUSE_BASE_URL") or zshrc.get("LANGFUSE_BASE_URL") or ""

    if not host:
        host = "https://cloud.langfuse.com"

    return public_key, secret_key, host


def _resolve_trace_flag() -> bool:
    flag = os.environ.get("TRACE_TO_LANGFUSE", "")
    if flag.lower() == "true":
        return True
    if flag.lower() == "false":
        return False
    dotenv = _find_dotenv()
    flag = dotenv.get("TRACE_TO_LANGFUSE", "")
    if flag.lower() == "true":
        return True
    if flag.lower() == "false":
        return False
    zshrc = _read_zshrc_exports()
    return zshrc.get("TRACE_TO_LANGFUSE", "").lower() == "true"


# ---------------------------------------------------------------------------
# Makato-specific context enrichment
# ---------------------------------------------------------------------------

def _get_loop_phase() -> str | None:
    """Read current_phase from the most recent workflow-state-*.json under specs/."""
    cwd = Path(os.environ.get("PWD", "")) or Path.cwd()
    specs_dir = cwd / "specs"
    if not specs_dir.exists():
        return None
    try:
        candidates = list(specs_dir.rglob("workflow-state*.json"))
        if not candidates:
            return None
        latest = max(candidates, key=lambda p: p.stat().st_mtime)
        data = json.loads(latest.read_text(encoding="utf-8"))
        return str(data.get("current_phase", "")) or None
    except Exception:
        return None


def _get_makato_version() -> str | None:
    """Read version from plugins/makato-orchestrate CHANGELOG first line."""
    try:
        changelog = Path(__file__).parent.parent.parent / "makato-orchestrate" / "CHANGELOG.md"
        if not changelog.exists():
            return None
        for line in changelog.read_text(encoding="utf-8").splitlines():
            m = re.search(r"v(\d+\.\d+\.\d+)", line)
            if m:
                return m.group(1)
    except Exception:
        pass
    return None


# ---------------------------------------------------------------------------
# Token usage
# ---------------------------------------------------------------------------

def get_usage(msg: dict[str, Any]) -> dict[str, int] | None:
    m = msg.get("message")
    if not isinstance(m, dict):
        return None
    usage = m.get("usage")
    if not isinstance(usage, dict):
        return None
    inp = int(usage.get("input_tokens", 0))
    out = int(usage.get("output_tokens", 0))
    cache_creation = int(usage.get("cache_creation_input_tokens", 0))
    cache_read = int(usage.get("cache_read_input_tokens", 0))
    return {
        "input": inp,
        "output": out,
        "total": inp + out,
        "cache_creation_input_tokens": cache_creation,
        "cache_read_input_tokens": cache_read,
    }


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def get_user_id() -> str | None:
    return os.environ.get("CC_LANGFUSE_USER_ID") or os.environ.get("USER") or os.environ.get("LOGNAME") or None


def get_project_name() -> str | None:
    cwd = os.environ.get("PWD") or os.getcwd()
    return Path(cwd).name if cwd else None


def get_content(msg: dict[str, Any]) -> Any:
    if not isinstance(msg, dict):
        return None
    if "message" in msg and isinstance(msg.get("message"), dict):
        return msg["message"].get("content")
    return msg.get("content")


def get_role(msg: dict[str, Any]) -> str | None:
    t = msg.get("type")
    if t in ("user", "assistant"):
        return t
    m = msg.get("message")
    if isinstance(m, dict):
        r = m.get("role")
        if r in ("user", "assistant"):
            return r
    return None


def is_tool_result(msg: dict[str, Any]) -> bool:
    if get_role(msg) != "user":
        return False
    content = get_content(msg)
    if isinstance(content, list):
        return any(isinstance(x, dict) and x.get("type") == "tool_result" for x in content)
    return False


def iter_tool_results(content: Any) -> list[dict[str, Any]]:
    if isinstance(content, list):
        return [x for x in content if isinstance(x, dict) and x.get("type") == "tool_result"]
    return []


def iter_tool_uses(content: Any) -> list[dict[str, Any]]:
    if isinstance(content, list):
        return [x for x in content if isinstance(x, dict) and x.get("type") == "tool_use"]
    return []


def extract_text(content: Any) -> str:
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts = []
        for x in content:
            if isinstance(x, dict) and x.get("type") == "text":
                parts.append(x.get("text", ""))
            elif isinstance(x, str):
                parts.append(x)
        return "\n".join(p for p in parts if p)
    return ""


def truncate_text(s: str, max_chars: int = MAX_CHARS) -> tuple[str, dict[str, Any]]:
    if s is None:
        return "", {"truncated": False, "orig_len": 0}
    orig_len = len(s)
    if orig_len <= max_chars:
        return s, {"truncated": False, "orig_len": orig_len}
    head = s[:max_chars]
    return head, {
        "truncated": True, "orig_len": orig_len, "kept_len": len(head),
        "sha256": hashlib.sha256(s.encode("utf-8")).hexdigest(),
    }


def get_model(msgs: list[dict[str, Any]]) -> str:
    for msg in msgs:
        m = msg.get("message")
        if isinstance(m, dict):
            model = m.get("model")
            if model and model != "<synthetic>":
                return model
    return "claude"


def get_message_id(msg: dict[str, Any]) -> str | None:
    m = msg.get("message")
    if isinstance(m, dict):
        mid = m.get("id")
        if isinstance(mid, str) and mid:
            return mid
    return None


# ---------------------------------------------------------------------------
# Skill / agent tag extraction
# ---------------------------------------------------------------------------

_skill_plugin_cache: dict[str, dict[str, str]] = {}


def _scan_plugin_dir(plugin_dir: Path, mapping: dict[str, str]) -> None:
    pname = plugin_dir.name
    for sub in ("skills", "agents"):
        d = plugin_dir / sub
        if d.is_dir():
            for entry in d.iterdir():
                if entry.is_dir():
                    mapping.setdefault(entry.name if sub == "skills" else entry.stem, pname)


def _build_skill_plugin_map() -> dict[str, str]:
    if "v" in _skill_plugin_cache:
        return _skill_plugin_cache["v"]
    mapping: dict[str, str] = {}
    plugins_dir = Path(__file__).parent.parent.parent
    if plugins_dir.is_dir():
        for d in plugins_dir.iterdir():
            if d.is_dir():
                _scan_plugin_dir(d, mapping)
    _skill_plugin_cache["v"] = mapping
    return mapping


def _extract_skill_agent_tags(assistant_msgs: list[dict[str, Any]]) -> tuple[list[str], set[str]]:
    tags: list[str] = []
    seen: set[str] = set()
    used_plugins: set[str] = set()
    mapping = _build_skill_plugin_map()
    for msg in assistant_msgs:
        for tu in iter_tool_uses(get_content(msg)):
            name = tu.get("name") or ""
            inp = tu.get("input") or {}
            if name == "Skill":
                skill = inp.get("skill")
                if skill and isinstance(skill, str):
                    tag = f"skill:{skill}"
                    if tag not in seen:
                        seen.add(tag)
                        tags.append(tag)
                    if ":" in skill:
                        used_plugins.add(skill.split(":")[0])
                    elif skill in mapping:
                        used_plugins.add(mapping[skill])
            elif name == "Agent":
                agent_type = inp.get("subagent_type") or inp.get("description")
                if agent_type and isinstance(agent_type, str):
                    short = agent_type[:40]
                    tag = f"agent:{short}"
                    if tag not in seen:
                        seen.add(tag)
                        tags.append(tag)
                    if ":" in agent_type:
                        used_plugins.add(agent_type.split(":")[0])
                    elif agent_type in mapping:
                        used_plugins.add(mapping[agent_type])
    return tags, used_plugins


# ---------------------------------------------------------------------------
# File locking & state
# ---------------------------------------------------------------------------

class FileLock:
    def __init__(self, path: Path, timeout_s: float = 2.0):
        self.path = path
        self.timeout_s = timeout_s
        self._fh: Any | None = None

    def __enter__(self) -> "FileLock":
        STATE_DIR.mkdir(parents=True, exist_ok=True)
        self._fh = open(self.path, "a+", encoding="utf-8")
        if _fcntl is not None:
            deadline = time.time() + self.timeout_s
            while True:
                try:
                    _fcntl.flock(self._fh.fileno(), _fcntl.LOCK_EX | _fcntl.LOCK_NB)
                    break
                except BlockingIOError:
                    if time.time() > deadline:
                        break
                    time.sleep(0.05)
        return self

    def __exit__(self, exc_type: Any, exc: Any, tb: Any) -> None:
        if self._fh is not None:
            if _fcntl is not None:
                with contextlib.suppress(Exception):
                    _fcntl.flock(self._fh.fileno(), _fcntl.LOCK_UN)
            with contextlib.suppress(Exception):
                self._fh.close()


def load_state() -> dict[str, Any]:
    try:
        if not STATE_FILE.exists():
            return {}
        return json.loads(STATE_FILE.read_text(encoding="utf-8"))
    except Exception:
        return {}


def save_state(state: dict[str, Any]) -> None:
    try:
        STATE_DIR.mkdir(parents=True, exist_ok=True)
        tmp = STATE_FILE.with_suffix(".tmp")
        tmp.write_text(json.dumps(state, indent=2, sort_keys=True), encoding="utf-8")
        os.replace(tmp, STATE_FILE)
    except Exception as e:
        debug(f"save_state failed: {e}")


def state_key(session_id: str, transcript_path: str) -> str:
    return hashlib.sha256(f"{session_id}::{transcript_path}".encode("utf-8")).hexdigest()


# ---------------------------------------------------------------------------
# Hook payload & transcript parsing
# ---------------------------------------------------------------------------

def read_hook_payload() -> dict[str, Any]:
    try:
        data = sys.stdin.read()
        return json.loads(data) if data.strip() else {}
    except Exception:
        return {}


def extract_session_and_transcript(payload: dict[str, Any]) -> tuple[str | None, Path | None]:
    session_id = (
        payload.get("sessionId")
        or payload.get("session_id")
        or payload.get("session", {}).get("id")
    )
    transcript = (
        payload.get("transcriptPath")
        or payload.get("transcript_path")
        or payload.get("transcript", {}).get("path")
    )
    transcript_path = None
    if transcript:
        with contextlib.suppress(Exception):
            transcript_path = Path(transcript).expanduser().resolve()
    return session_id, transcript_path


@dataclass
class SessionState:
    offset: int = 0
    buffer: str = ""
    turn_count: int = 0


def load_session_state(global_state: dict[str, Any], key: str) -> SessionState:
    s = global_state.get(key, {})
    return SessionState(
        offset=int(s.get("offset", 0)),
        buffer=str(s.get("buffer", "")),
        turn_count=int(s.get("turn_count", 0)),
    )


def write_session_state(global_state: dict[str, Any], key: str, ss: SessionState) -> None:
    global_state[key] = {
        "offset": ss.offset,
        "buffer": ss.buffer,
        "turn_count": ss.turn_count,
        "updated": datetime.now(timezone.utc).isoformat(),
    }


def read_new_jsonl(transcript_path: Path, ss: SessionState) -> tuple[list[dict[str, Any]], SessionState]:
    if not transcript_path.exists():
        return [], ss
    try:
        with open(transcript_path, "rb") as f:
            f.seek(ss.offset)
            chunk = f.read()
            new_offset = f.tell()
    except Exception as e:
        debug(f"read_new_jsonl failed: {e}")
        return [], ss
    if not chunk:
        return [], ss
    text = chunk.decode("utf-8", errors="replace")
    combined = ss.buffer + text
    lines = combined.split("\n")
    ss.buffer = lines[-1]
    ss.offset = new_offset
    msgs: list[dict[str, Any]] = []
    for raw_line in lines[:-1]:
        stripped = raw_line.strip()
        if not stripped:
            continue
        try:
            msgs.append(json.loads(stripped))
        except Exception:
            continue
    return msgs, ss


# ---------------------------------------------------------------------------
# Turn building
# ---------------------------------------------------------------------------

@dataclass
class Turn:
    user_msg: dict[str, Any]
    assistant_msgs: list[dict[str, Any]]
    tool_results_by_id: dict[str, Any]
    start_time: datetime | None = None
    end_time: datetime | None = None
    tool_use_timestamps: dict[str, datetime] | None = None
    tool_result_timestamps: dict[str, datetime] | None = None
    tool_errors_by_id: dict[str, bool] | None = None


def _parse_ts(msg: dict[str, Any]) -> datetime | None:
    ts = msg.get("timestamp")
    if not isinstance(ts, str):
        return None
    try:
        return datetime.fromisoformat(ts.replace("Z", "+00:00"))
    except Exception:
        return None


def build_turns(messages: list[dict[str, Any]]) -> list[Turn]:
    turns: list[Turn] = []
    current_user: dict[str, Any] | None = None
    assistant_order: list[str] = []
    assistant_latest: dict[str, dict[str, Any]] = {}
    tool_results_by_id: dict[str, Any] = {}
    tool_use_timestamps: dict[str, datetime] = {}
    tool_result_timestamps: dict[str, datetime] = {}
    tool_errors_by_id: dict[str, bool] = {}
    last_assistant_ts: datetime | None = None

    def flush_turn() -> None:
        nonlocal current_user, assistant_order, assistant_latest
        nonlocal tool_results_by_id, tool_use_timestamps, tool_result_timestamps
        nonlocal tool_errors_by_id, last_assistant_ts
        if current_user is None or not assistant_latest:
            return
        assistants = [assistant_latest[mid] for mid in assistant_order if mid in assistant_latest]
        turns.append(Turn(
            user_msg=current_user,
            assistant_msgs=assistants,
            tool_results_by_id=dict(tool_results_by_id),
            start_time=_parse_ts(current_user),
            end_time=last_assistant_ts,
            tool_use_timestamps=dict(tool_use_timestamps),
            tool_result_timestamps=dict(tool_result_timestamps),
            tool_errors_by_id=dict(tool_errors_by_id),
        ))

    for msg in messages:
        role = get_role(msg)
        if is_tool_result(msg):
            msg_ts = _parse_ts(msg)
            for tr in iter_tool_results(get_content(msg)):
                tid = tr.get("tool_use_id")
                if not tid:
                    continue
                tid_str = str(tid)
                tool_results_by_id[tid_str] = tr.get("content")
                if msg_ts is not None:
                    tool_result_timestamps[tid_str] = msg_ts
                if tr.get("is_error") is True:
                    tool_errors_by_id[tid_str] = True
            continue
        if role == "user":
            flush_turn()
            current_user = msg
            assistant_order, assistant_latest = [], {}
            tool_results_by_id, tool_use_timestamps = {}, {}
            tool_result_timestamps, tool_errors_by_id = {}, {}
            last_assistant_ts = None
            continue
        if role == "assistant":
            if current_user is None:
                continue
            mid = get_message_id(msg) or f"noid:{len(assistant_order)}"
            if mid not in assistant_latest:
                assistant_order.append(mid)
            assistant_latest[mid] = msg
            ts = _parse_ts(msg)
            if ts is not None:
                last_assistant_ts = ts
            if ts is not None:
                for tu in iter_tool_uses(get_content(msg)):
                    tu_id = tu.get("id")
                    if tu_id:
                        tool_use_timestamps[str(tu_id)] = ts
            continue

    flush_turn()
    return turns


# ---------------------------------------------------------------------------
# Trace emission
# ---------------------------------------------------------------------------

@dataclass
class TraceContext:
    session_id: str
    transcript_path: Path
    user_id: str | None
    project_name: str | None
    makato_version: str | None
    loop_phase: str | None
    issue_trace_id: str | None = None


_PLUGIN_NAMES = {
    "makato-build",
    "makato-change",
    "makato-contribute",
    "makato-core",
    "makato-database",
    "makato-doc",
    "makato-fastapi",
    "makato-langgraph",
    "makato-observability",
    "makato-orchestrate",
    "makato-plan",
    "makato-sagibeast",
    "makato-temporal",
    "makato-ux",
}

_LOOP_PHASES = {
    "seed", "plan", "implement", "review", "verify", "push", "pr", "done",
    "resolve-conflict", "address-pr-comments", "merge", "blocked",
}


def _plugin_from_skill_tag(tag: str) -> str | None:
    """Extract plugin name from skill:plugin:skill-name or agent:plugin:agent-name tag."""
    parts = tag.split(":", 2)
    if len(parts) >= 3 and parts[1] in _PLUGIN_NAMES:
        return parts[1]
    if len(parts) >= 2 and parts[1] in _PLUGIN_NAMES:
        return parts[1]
    return None


def _build_trace_tags(ctx: TraceContext, turn: Turn) -> list[str]:
    tags = ["claude-code", "makato"]
    if ctx.project_name:
        tags.append(f"project:{ctx.project_name}")
    if ctx.makato_version:
        tags.append(f"makato:{ctx.makato_version}")
    if ctx.loop_phase:
        tags.append(f"loop-phase:{ctx.loop_phase}")
        # Normalise to canonical phase name for easy filtering
        phase_normalised = ctx.loop_phase.lower().replace("_", "-")
        if any(phase_normalised.startswith(p) for p in _LOOP_PHASES):
            tags.append(f"phase:{phase_normalised}")

    skill_agent_tags, used_plugins = _extract_skill_agent_tags(turn.assistant_msgs)
    tags.extend(skill_agent_tags)

    # Plugin-level tags — derived from skill/agent tags, enable per-plugin filtering
    # without needing to enumerate every individual skill name in dashboard filters.
    seen_plugins: set[str] = set(used_plugins)
    for t in skill_agent_tags:
        p = _plugin_from_skill_tag(t)
        if p and p not in seen_plugins:
            seen_plugins.add(p)
    for p in sorted(seen_plugins):
        tags.append(f"plugin:{p}")

    entrypoint = turn.user_msg.get("entrypoint")
    if entrypoint and isinstance(entrypoint, str):
        tags.append(f"entrypoint:{entrypoint}")
    return tags


_MAX_TRACE_NAME_LEN = 80


def _build_trace_name(turn_num: int, user_text: str, tags: list[str]) -> str:
    skill_tags = [t for t in tags if t.startswith(("skill:", "agent:"))]
    prefix = ", ".join(t.split(":", 1)[1] for t in skill_tags[:2]) if skill_tags else ""
    snippet = user_text.replace("\n", " ").strip()
    if not snippet:
        return f"Turn {turn_num}"
    if len(snippet) > _MAX_TRACE_NAME_LEN:
        snippet = snippet[:_MAX_TRACE_NAME_LEN] + "..."
    return f"{prefix}: {snippet}" if prefix else snippet


def _tool_calls_from_assistants(assistant_msgs: list[dict[str, Any]]) -> list[dict[str, Any]]:
    calls: list[dict[str, Any]] = []
    for am in assistant_msgs:
        for tu in iter_tool_uses(get_content(am)):
            tid = tu.get("id") or ""
            raw_input = tu.get("input")
            sanitized = (
                sanitize_dict(raw_input)
                if isinstance(raw_input, (dict, list, str, int, float, bool))
                else {}
            )
            calls.append({"id": str(tid), "name": tu.get("name") or "unknown", "input": sanitized})
    return calls


def _enrich_tool_outputs(tool_calls: list[dict[str, Any]], turn: Turn) -> None:
    for c in tool_calls:
        if c["id"] and c["id"] in turn.tool_results_by_id:
            out_raw = turn.tool_results_by_id[c["id"]]
            out_str = out_raw if isinstance(out_raw, str) else json.dumps(out_raw, ensure_ascii=False)
            out_trunc, out_meta = truncate_text(sanitize_value(out_str))
            c["output"] = out_trunc
            c["output_meta"] = out_meta
        else:
            c["output"] = None


def emit_turn(langfuse: Langfuse, turn_num: int, turn: Turn, ctx: TraceContext) -> None:
    user_text_raw = extract_text(get_content(turn.user_msg))
    user_text, user_text_meta = truncate_text(user_text_raw)
    last_assistant = turn.assistant_msgs[-1]
    assistant_text_raw = extract_text(get_content(last_assistant))
    assistant_text, _ = truncate_text(assistant_text_raw)
    model = get_model(turn.assistant_msgs)
    usage = get_usage(last_assistant)
    tool_calls = _tool_calls_from_assistants(turn.assistant_msgs)
    _enrich_tool_outputs(tool_calls, turn)
    tags = _build_trace_tags(ctx, turn)
    trace_name = _build_trace_name(turn_num, user_text_raw, tags)

    trace_metadata: dict[str, Any] = {
        "source": "claude-code",
        "session_id": ctx.session_id,
        "turn_number": turn_num,
        "transcript_path": str(ctx.transcript_path),
        "user_text": user_text_meta,
    }
    if ctx.project_name:
        trace_metadata["project"] = ctx.project_name
    if ctx.loop_phase:
        trace_metadata["loop_phase"] = ctx.loop_phase
    if ctx.issue_trace_id:
        trace_metadata["issue_trace_id"] = ctx.issue_trace_id
    if turn.start_time:
        trace_metadata["start_time"] = turn.start_time.isoformat()
    if turn.end_time:
        trace_metadata["end_time"] = turn.end_time.isoformat()

    with (
        propagate_attributes(
            session_id=ctx.session_id,
            trace_name=trace_name,
            tags=tags,
            user_id=ctx.user_id,
            version=ctx.makato_version,
        ),
        langfuse.start_as_current_observation(
            name=trace_name,
            input={"role": "user", "content": user_text},
            metadata=trace_metadata,
        ) as trace_span,
    ):
        gen_meta: dict[str, Any] = {
            "tool_count": len(tool_calls),
            "tool_names": [tc["name"] for tc in tool_calls],
            "tool_error_count": sum(
                1 for tc in tool_calls if (turn.tool_errors_by_id or {}).get(tc["id"], False)
            ),
        }
        gen_kwargs: dict[str, Any] = {
            "name": "Claude Response",
            "as_type": "generation",
            "model": model,
            "input": {"role": "user", "content": user_text},
            "output": {"role": "assistant", "content": assistant_text},
            "metadata": gen_meta,
        }
        if usage:
            gen_kwargs["usage_details"] = usage
        with langfuse.start_as_current_observation(**gen_kwargs):
            pass

        for tc in tool_calls:
            in_obj = tc["input"]
            if isinstance(in_obj, str):
                in_obj, _ = truncate_text(in_obj)
            tc_id = tc["id"]
            is_err = (turn.tool_errors_by_id or {}).get(tc_id, False)
            tool_meta: dict[str, Any] = {"tool_name": tc["name"], "tool_id": tc_id}
            if (turn.tool_use_timestamps or {}).get(tc_id):
                tool_meta["start_time"] = turn.tool_use_timestamps[tc_id].isoformat()  # type: ignore[index]
            if (turn.tool_result_timestamps or {}).get(tc_id):
                tool_meta["end_time"] = turn.tool_result_timestamps[tc_id].isoformat()  # type: ignore[index]
            tool_kwargs: dict[str, Any] = {
                "name": f"Tool: {tc['name']}",
                "as_type": "tool",
                "input": in_obj,
                "metadata": tool_meta,
            }
            if is_err:
                tool_kwargs["level"] = "ERROR"
                tool_kwargs["status_message"] = "Tool execution failed"
            with langfuse.start_as_current_observation(**tool_kwargs) as tool_obs:
                tool_obs.update(output=tc.get("output"))

        trace_span.update(output={"role": "assistant", "content": assistant_text})


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def _clear_localhost_proxy(host: str) -> None:
    if "localhost" not in host and "127.0.0.1" not in host:
        return
    for var in ("ALL_PROXY", "all_proxy", "HTTPS_PROXY", "https_proxy", "HTTP_PROXY", "http_proxy"):
        os.environ.pop(var, None)


def _check_langfuse_reachable(host: str, timeout: float = 3.0) -> bool:
    health_url = host.rstrip("/") + "/api/public/health"
    try:
        with urllib.request.urlopen(health_url, timeout=timeout) as resp:  # noqa: S310
            return '"status"' in resp.read().decode("utf-8", errors="replace")
    except Exception:
        return False


def main() -> int:
    start = time.time()
    debug("Hook started")

    if not _resolve_trace_flag():
        debug("TRACE_TO_LANGFUSE is not 'true'; exiting.")
        return 0

    public_key, secret_key, host = _resolve_credentials()
    if not public_key or not secret_key:
        debug(f"Missing credentials: pk={'yes' if public_key else 'no'} sk={'yes' if secret_key else 'no'}")
        return 0

    payload = read_hook_payload()
    session_id, transcript_path = extract_session_and_transcript(payload)
    issue_trace_id = payload.get("issue_trace_id")

    if not session_id or not transcript_path or not transcript_path.exists():
        debug("Missing session_id or transcript_path; exiting.")
        return 0

    _clear_localhost_proxy(host)

    if not _check_langfuse_reachable(host):
        error(f"Langfuse not reachable at {host} — traces dropped.")
        return 0

    try:
        langfuse = Langfuse(public_key=public_key, secret_key=secret_key, host=host)
    except Exception as e:
        debug(f"Langfuse init failed: {e}")
        return 0

    ctx = TraceContext(
        session_id=session_id,
        transcript_path=transcript_path,
        user_id=get_user_id(),
        project_name=get_project_name(),
        makato_version=_get_makato_version(),
        loop_phase=_get_loop_phase(),
        issue_trace_id=issue_trace_id,
    )

    try:
        with FileLock(LOCK_FILE):
            state = load_state()
            key = state_key(session_id, str(transcript_path))
            ss = load_session_state(state, key)
            msgs, ss = read_new_jsonl(transcript_path, ss)
            if not msgs:
                write_session_state(state, key, ss)
                save_state(state)
                return 0
            turns = build_turns(msgs)
            if not turns:
                write_session_state(state, key, ss)
                save_state(state)
                return 0
            emitted = 0
            for t in turns:
                emitted += 1
                try:
                    emit_turn(langfuse, ss.turn_count + emitted, t, ctx)
                except Exception as e:
                    debug(f"emit_turn failed: {e}")
            ss.turn_count += emitted
            write_session_state(state, key, ss)
            save_state(state)

        with contextlib.suppress(Exception):
            langfuse.flush()

        info(f"Processed {emitted} turns in {time.time() - start:.2f}s (session={session_id}, loop_phase={ctx.loop_phase})")
        return 0
    except Exception as e:
        debug(f"Unexpected failure: {e}")
        return 0
    finally:
        with contextlib.suppress(Exception):
            langfuse.shutdown()


if __name__ == "__main__":
    sys.exit(main())
