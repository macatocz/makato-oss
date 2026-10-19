#!/usr/bin/env python3
"""Resolve and validate a Makato model profile, and merge it into OMP's config.

Typed, provider-neutral resolver/validator for config/model-profiles.yml and
config/agent-roles.yml, and the merge engine behind
scripts/select-model-profile.sh. This module never prints a credential value
or the content of an existing OMP file. `api_key_env` names the environment
variable a profile needs; only `--merge` without `--dry-run` (a real install)
reads it — first to require it before any file is touched, then at write time
to put the value into the OMP models file (mode 600).

CLI usage:
    python3 resolve-model-profile.py <profile> [--config PATH] \
        [--emit {summary,omp-models,omp-config}]
    python3 resolve-model-profile.py --emit omp-agent-overrides [--agent-roles PATH]
    python3 resolve-model-profile.py [<profile>] --merge --omp-config PATH \
        [--omp-models PATH] [--dry-run] [--config PATH] [--agent-roles PATH]

--merge updates only the canonical `modelRoles` keys, `tools.format` and the
makato agent keys of `task.agentModelOverrides` in the OMP config, and only
`providers.<provider>.{baseUrl,apiKey,models}` in the OMP models file; every
other setting is preserved. Without <profile> it merges only the agent-role
overrides. With --dry-run it prints the fragments it would merge and reads or
writes neither OMP file.

Exit codes: 0 on success; 1 on any resolution, validation or merge error
(message on stderr); 2 on a usage error.

Stdlib-only except when merging into an existing, non-blank OMP file, which
needs PyYAML. model-profiles.yml and agent-roles.yml are restricted to nested
mappings of scalars (no lists, no anchors), which the stdlib fallback parser
`_parse_nested_yaml` reads when PyYAML is absent.
"""

from __future__ import annotations

import argparse
import contextlib
import json
import os
import re
import stat
import sys
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_CONFIG_PATH = REPO_ROOT / "config" / "model-profiles.yml"
DEFAULT_AGENT_ROLES_PATH = REPO_ROOT / "config" / "agent-roles.yml"

# The canonical Makato model roles. tests/test_model_roles_config.py,
# tests/test_model_profiles.py and scripts/preflight-omp-context.sh keep their
# own copies on purpose, so each one checks this list independently.
EXPECTED_ROLES = (
    "default",
    "task",
    "smol",
    "tiny",
    "plan",
    "advisor",
    "designer",
    "commit",
    "slow",
    "vision",
    "orchestrator",
)

KNOWN_TOOL_FORMATS = frozenset({"openai", "qwen3"})


class ProfileError(Exception):
    """Raised for any structural profile validation failure.

    Messages built from this exception are safe to print to stderr — they
    never include credential values, only profile/role/field names.
    """


# ---------------------------------------------------------------------------
# stdlib fallback parser (used only when PyYAML is not importable)
# ---------------------------------------------------------------------------


def _strip_comment(line: str) -> str:
    """Strip a trailing `# ...` comment, ignoring `#` inside quoted strings."""
    in_quote = False
    quote_char = ""
    for i, ch in enumerate(line):
        if in_quote:
            if ch == quote_char:
                in_quote = False
        elif ch in ('"', "'"):
            in_quote = True
            quote_char = ch
        elif ch == "#" and (i == 0 or line[i - 1] in (" ", "\t")):
            return line[:i]
    return line


def _coerce_scalar(raw: str):
    val = raw.strip()
    if len(val) >= 2 and val[0] == val[-1] and val[0] in ('"', "'"):
        return val[1:-1]
    if val == "":
        return ""
    if re.fullmatch(r"-?\d+", val):
        return int(val)
    return val


def _parse_nested_yaml(text: str) -> dict:
    """Minimal indentation-based parser for nested `key: value` mappings.

    Supports the restricted grammar model-profiles.yml uses: 2-space nested
    mappings of scalars, with `#` comments (respecting quoted strings) and no
    sequences/anchors. Returns the same shape `yaml.safe_load` would for that
    restricted grammar.
    """
    root: dict = {}
    stack: list[tuple[int, dict]] = [(-1, root)]
    for raw_line in text.splitlines():
        line = _strip_comment(raw_line).rstrip()
        if not line.strip():
            continue
        indent = len(line) - len(line.lstrip(" "))
        content = line.strip()
        if ":" not in content:
            continue
        key, _, rest = content.partition(":")
        key = key.strip()
        rest = rest.strip()
        while stack and indent <= stack[-1][0]:
            stack.pop()
        parent = stack[-1][1]
        if rest == "":
            new_dict: dict = {}
            parent[key] = new_dict
            stack.append((indent, new_dict))
        else:
            parent[key] = _coerce_scalar(rest)
    return root


# ---------------------------------------------------------------------------
# Loading and resolution
# ---------------------------------------------------------------------------


def _read_config_document(path: Path) -> object:
    """Parse a repo config file with PyYAML when importable, else with the stdlib fallback."""
    text = path.read_text(encoding="utf-8")
    try:
        import yaml  # noqa: PLC0415
    except ImportError:
        return _parse_nested_yaml(text)
    return yaml.safe_load(text)


def load_profiles(path: str) -> dict:
    """Load the model-profiles.yml document (PyYAML if available, else fallback)."""
    p = Path(path)
    if not p.exists():
        raise FileNotFoundError(f"model-profiles.yml not found at {p}")
    data = _read_config_document(p)
    if not isinstance(data, dict) or not isinstance(data.get("profiles"), dict):
        raise ProfileError(f"{p} must define a top-level 'profiles' mapping")
    return data


def load_agent_roles(path: str) -> dict[str, str]:
    """Load config/agent-roles.yml as {agent: role}.

    Every role must be canonical and have a `claude_aliases` entry, so both
    OMP and Claude Code can route every listed agent.
    """
    p = Path(path)
    if not p.exists():
        raise FileNotFoundError(f"agent-roles.yml not found at {p}")
    data = _read_config_document(p)
    aliases = data.get("claude_aliases") if isinstance(data, dict) else None
    agents = data.get("agents") if isinstance(data, dict) else None
    if not isinstance(aliases, dict) or not isinstance(agents, dict) or not agents:
        raise ProfileError(f"{p} must define top-level 'claude_aliases' and non-empty 'agents' mappings")
    non_canonical = sorted({str(role) for role in [*aliases, *agents.values()] if role not in EXPECTED_ROLES})
    if non_canonical:
        raise ProfileError(f"{p} uses non-canonical roles {non_canonical} — expected one of {list(EXPECTED_ROLES)}")
    unaliased = sorted({str(role) for role in agents.values() if not aliases.get(role)})
    if unaliased:
        raise ProfileError(f"{p} has no claude_aliases entry for roles {unaliased}")
    return {str(agent): str(role) for agent, role in agents.items()}


def normalize_base_url(raw: object) -> str:
    """Strip trailing slashes and require an explicit http(s) scheme."""
    if not isinstance(raw, str) or not raw.strip():
        raise ProfileError("base_url must be a non-empty string")
    normalized = raw.strip()
    if not (normalized.startswith("http://") or normalized.startswith("https://")):
        raise ProfileError(f"base_url must start with http:// or https:// (got {normalized!r})")
    while normalized.endswith("/"):
        normalized = normalized[:-1]
    return normalized


def resolve_profile(doc: dict, name: str) -> dict:
    """Validate and return a resolved copy of the named profile.

    Never reads or emits credential values — only validates that api_key_env
    (when declared) is a non-empty string naming the required env var.
    """
    profiles = doc.get("profiles") or {}
    if name not in profiles:
        known = ", ".join(sorted(profiles.keys()))
        raise ProfileError(f"Unsupported provider profile: {name!r}. Known profiles: {known}")

    raw = profiles[name]
    if not isinstance(raw, dict):
        raise ProfileError(f"Profile {name!r} must be a mapping")

    profile = dict(raw)

    roles = dict(profile.get("roles") or {})
    missing = sorted(set(EXPECTED_ROLES) - set(roles.keys()))
    if missing:
        raise ProfileError(f"Profile {name!r} is missing role mappings: {missing}")
    profile["roles"] = roles

    tool_format = profile.get("tool_format")
    if tool_format not in KNOWN_TOOL_FORMATS:
        raise ProfileError(f"Profile {name!r} has unsupported tool_format {tool_format!r} — expected one of {sorted(KNOWN_TOOL_FORMATS)}")

    profile["base_url"] = normalize_base_url(profile.get("base_url"))
    profile["provider"] = profile.get("provider") or name
    profile["api_key_env"] = profile.get("api_key_env") or ""
    profile["context_window"] = profile.get("context_window") or 0
    profile["max_tokens"] = profile.get("max_tokens") or 0
    profile["api"] = profile.get("api") or "openai-completions"
    profile["name"] = name
    return profile


# ---------------------------------------------------------------------------
# Emission (summary / OMP documents) — never includes credential values
# ---------------------------------------------------------------------------


def emit_summary(name: str, profile: dict) -> dict:
    return {
        "profile": name,
        "provider": profile["provider"],
        "base_url": profile["base_url"],
        "tool_format": profile["tool_format"],
        "context_window": profile["context_window"],
        "max_tokens": profile["max_tokens"],
        "api_key_env": profile["api_key_env"] or None,
        "roles": {role: profile["roles"][role] for role in EXPECTED_ROLES},
    }


def emit_omp_models(profile: dict) -> str:
    """Render the OMP `providers:` document fragment for this profile.

    apiKey is either the literal `EMPTY` sentinel (no credential required) or
    a `${ENV_VAR}` placeholder naming the required variable — never a value.
    """
    api_key_env = profile["api_key_env"]
    api_key_line = f"${{{api_key_env}}}" if api_key_env else "EMPTY"
    model_ids = sorted({str(v) for v in profile["roles"].values()})

    lines = [
        "providers:",
        f"  {profile['provider']}:",
        f"    baseUrl: {profile['base_url']}",
        f"    apiKey: {api_key_line}",
        "    models:",
    ]
    for model_id in model_ids:
        lines.append(f"      - id: {model_id}")
        lines.append(f"        contextWindow: {profile['context_window']}")
        lines.append(f"        maxTokens: {profile['max_tokens']}")
        lines.append(f"        api: {profile['api']}")
    return "\n".join(lines) + "\n"


def emit_omp_config(profile: dict) -> str:
    """Render the OMP `modelRoles:` + `tools:` document fragment for this profile."""
    lines = ["modelRoles:"]
    for role in EXPECTED_ROLES:
        lines.append(f"  {role}: {profile['provider']}/{profile['roles'][role]}")
    lines.append("")
    lines.append("tools:")
    lines.append(f"  format: {profile['tool_format']}")
    return "\n".join(lines) + "\n"


def emit_omp_agent_overrides(agent_roles: dict[str, str]) -> str:
    """Render the OMP `task.agentModelOverrides` fragment routing each makato agent to `@<role>`.

    The `@<role>` indirection keeps concrete models in OMP `modelRoles`, so
    /model → Roles stays the one place to change them.
    """
    lines = ["task:", "  agentModelOverrides:"]
    lines.extend(f'    {agent}: "@{role}"' for agent, role in agent_roles.items())
    return "\n".join(lines) + "\n"


def config_fragments(profile: dict | None, agent_roles: dict[str, str]) -> list[str]:
    """OMP config fragments a merge applies: the profile's roles and tool format (if any), then the agent overrides."""
    fragments = [emit_omp_config(profile)] if profile is not None else []
    fragments.append(emit_omp_agent_overrides(agent_roles))
    return fragments


def render_dry_run(profile: dict | None, agent_roles: dict[str, str], config_path: Path, models_path: Path | None) -> str:
    """Render what a merge would apply, headed by each target path — never a target's current content."""
    sections = []
    if profile is not None:
        sections.append(f"# --- dry-run: would merge into {models_path} (not written) ---\n{emit_omp_models(profile)}")
    sections.append(f"# --- dry-run: would merge into {config_path} (not written) ---\n" + "\n".join(config_fragments(profile, agent_roles)))
    return "".join(sections)


# ---------------------------------------------------------------------------
# Merge into the user's OMP files — never prints a credential or file content
# ---------------------------------------------------------------------------


def _load_omp_file(path: Path) -> dict | None:
    """Parse an existing OMP file; None when it is absent, blank or comment-only.

    Errors name only the path and a position: PyYAML's own messages quote the
    offending line, which may hold an apiKey.
    """
    if not path.exists():
        return None
    try:
        text = path.read_text(encoding="utf-8")
    except UnicodeDecodeError:
        raise ProfileError(f"cannot parse {path} as YAML (not UTF-8)") from None
    if not text.strip():
        return None
    try:
        import yaml  # noqa: PLC0415
    except ImportError:
        raise ProfileError(f"PyYAML is required to merge into the existing {path}; install it (python3 -m pip install pyyaml) or set MAKATO_PYTHON_BIN to a Python that has it") from None
    try:
        data = yaml.safe_load(text)
    except yaml.YAMLError as exc:
        mark = getattr(exc, "problem_mark", None) or getattr(exc, "context_mark", None)
        position = f" (line {mark.line + 1}, column {mark.column + 1})" if mark is not None else ""
        raise ProfileError(f"cannot parse {path} as YAML{position}") from None
    if data is None:
        return None
    if not isinstance(data, dict):
        raise ProfileError(f"refusing to merge into {path}: '(root)' is not a mapping")
    return data


def _merge_fragment(target: dict, fragment: dict, path: Path, prefix: str = "") -> None:
    """Set every leaf of `fragment` in `target`, creating missing mappings and keeping every other key."""
    for key, value in fragment.items():
        dotted = f"{prefix}.{key}" if prefix else str(key)
        if not isinstance(value, dict):
            target[key] = value
            continue
        child = target.get(key)
        if child is None:
            child = target[key] = {}
        elif not isinstance(child, dict):
            raise ProfileError(f"refusing to merge into {path}: '{dotted}' is not a mapping")
        _merge_fragment(child, value, path, dotted)


def _merge_document(path: Path, fragments: list[str]) -> dict | None:
    """Merge the fragments into the parsed file; None means the file gets the fragments verbatim."""
    existing = _load_omp_file(path)
    if existing is None:
        return None
    import yaml  # noqa: PLC0415 - a non-blank existing file already required PyYAML

    for fragment in fragments:
        _merge_fragment(existing, yaml.safe_load(fragment), path)
    return existing


def _dump_yaml(document: dict) -> str:
    import yaml  # noqa: PLC0415

    return yaml.safe_dump(document, sort_keys=False, default_flow_style=False, allow_unicode=True, width=4096)


def _config_file_mode(path: Path) -> int:
    """Keep an existing file's permissions; a new file gets what a shell redirect would create."""
    with contextlib.suppress(FileNotFoundError):
        return stat.S_IMODE(path.stat().st_mode)
    umask = os.umask(0)
    os.umask(umask)
    return 0o666 & ~umask


def _write_files(files: list[tuple[Path, str, int]]) -> None:
    """Stage every file beside its target, then rename each into place.

    A failure while staging leaves every target untouched. Symlinked targets
    are written through, so dotfile-managed configs keep their links.
    """
    staged: list[tuple[str, str]] = []
    try:
        for path, text, mode in files:
            target = os.path.realpath(path)
            directory = os.path.dirname(target)
            os.makedirs(directory, exist_ok=True)
            fd, tmp_name = tempfile.mkstemp(dir=directory, prefix=f".{os.path.basename(target)}.", suffix=".tmp")
            staged.append((tmp_name, target))
            with os.fdopen(fd, "w", encoding="utf-8") as handle:
                handle.write(text)
                handle.flush()
                os.fsync(handle.fileno())
            os.chmod(tmp_name, mode)
        for tmp_name, target in staged:
            os.replace(tmp_name, target)
    finally:
        for tmp_name, _ in staged:
            with contextlib.suppress(FileNotFoundError):
                os.unlink(tmp_name)


def merge_into_omp(config_path: Path, agent_roles: dict[str, str], profile: dict | None = None, models_path: Path | None = None) -> list[str]:
    """Merge the agent-role overrides, and the profile when given, into the OMP files.

    Requires the profile's credential and validates both files before writing
    either. Returns the roles makato agents are routed to that the merged
    config's modelRoles does not define.
    """
    if (profile is None) != (models_path is None):
        raise ValueError("models_path is required for, and only for, a profile merge")
    api_key_env = profile["api_key_env"] if profile is not None else ""
    if profile is not None and api_key_env and not os.environ.get(api_key_env):
        raise ProfileError(f"profile {profile['name']!r} requires credential env var {api_key_env} to be set before install (value not shown)")

    fragments = config_fragments(profile, agent_roles)
    merged_config = _merge_document(config_path, fragments)
    files: list[tuple[Path, str, int]] = []
    if profile is not None and models_path is not None:
        models_fragment = emit_omp_models(profile)
        merged_models = _merge_document(models_path, [models_fragment])
        credential = os.environ[api_key_env] if api_key_env else ""
        if merged_models is None:
            models_text = models_fragment.replace(f"${{{api_key_env}}}", json.dumps(credential)) if credential else models_fragment
        else:
            if credential:
                merged_models["providers"][profile["provider"]]["apiKey"] = credential
            models_text = _dump_yaml(merged_models)
        files.append((models_path, models_text, 0o600))
    files.append((config_path, "\n".join(fragments) if merged_config is None else _dump_yaml(merged_config), _config_file_mode(config_path)))
    _write_files(files)

    if merged_config is None:
        configured = set(EXPECTED_ROLES) if profile is not None else set()
    else:
        model_roles = merged_config.get("modelRoles")
        configured = {role for role, model in model_roles.items() if model} if isinstance(model_roles, dict) else set()
    return sorted(set(agent_roles.values()) - configured)


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("profile", nargs="?", help="Profile name (e.g. openai, qwen-vllm, apple-ollama); omit it with --merge to merge only the agent-role overrides")
    parser.add_argument("--config", default=str(DEFAULT_CONFIG_PATH), help="Path to model-profiles.yml")
    parser.add_argument("--agent-roles", default=str(DEFAULT_AGENT_ROLES_PATH), help="Path to agent-roles.yml")
    action = parser.add_mutually_exclusive_group()
    action.add_argument(
        "--emit",
        choices=["summary", "omp-models", "omp-config", "omp-agent-overrides"],
        help="What to print: a redacted JSON summary (the default), or a generated OMP document fragment",
    )
    action.add_argument("--merge", action="store_true", help="Merge into the OMP files named by --omp-config and --omp-models")
    parser.add_argument("--omp-config", type=Path, help="OMP config.yml to merge into")
    parser.add_argument("--omp-models", type=Path, help="OMP models.yml to merge into (profile merges only)")
    parser.add_argument("--dry-run", action="store_true", help="With --merge: print the fragments that would be merged; read and write neither OMP file")
    args = parser.parse_args(argv[1:])

    if not args.merge and (args.omp_config or args.omp_models or args.dry_run):
        parser.error("--omp-config, --omp-models and --dry-run need --merge")
    if args.merge and (args.omp_config is None or bool(args.profile) != (args.omp_models is not None)):
        parser.error("--merge needs --omp-config, plus --omp-models exactly when a profile is given")
    emit = args.emit or ("" if args.merge else "summary")
    if emit in ("summary", "omp-models", "omp-config") and not args.profile:
        parser.error(f"--emit {emit} needs a profile")

    try:
        if emit == "omp-agent-overrides":
            print(emit_omp_agent_overrides(load_agent_roles(args.agent_roles)), end="")
            return 0
        if emit:
            profile = resolve_profile(load_profiles(args.config), args.profile)
            if emit == "summary":
                print(json.dumps(emit_summary(args.profile, profile), indent=2, sort_keys=True))
            elif emit == "omp-models":
                print(emit_omp_models(profile), end="")
            else:
                print(emit_omp_config(profile), end="")
            return 0
        merge_profile = resolve_profile(load_profiles(args.config), args.profile) if args.profile else None
        agent_roles = load_agent_roles(args.agent_roles)
        if args.dry_run:
            print(render_dry_run(merge_profile, agent_roles, args.omp_config, args.omp_models), end="")
            return 0
        missing_roles = merge_into_omp(args.omp_config, agent_roles, merge_profile, args.omp_models)
    except (ProfileError, OSError) as exc:
        sys.stderr.write(f"ERROR: {exc}\n")
        return 1

    if missing_roles:
        sys.stderr.write(f"WARN: {args.omp_config} has no modelRoles entry for {', '.join(missing_roles)}; agents routed to them need it — set it in OMP /model → Roles\n")
    if merge_profile is None:
        print(f"OK: merged agent-role overrides into {args.omp_config}")
    else:
        print(f"OK: merged profile {args.profile!r} into {args.omp_models} and {args.omp_config}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
