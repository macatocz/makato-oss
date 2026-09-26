#!/usr/bin/env python3
"""Resolve and validate a Makato model profile from config/model-profiles.yml.

Typed, provider-neutral profile resolver/validator. This module NEVER emits
credential values — `api_key_env` names the environment variable a profile
needs at install time; the resolver never reads or prints that variable's
value. scripts/select-model-profile.sh is the only place a credential value
is ever read from the environment, and only when installing (not --dry-run).

CLI usage:
    python3 resolve-model-profile.py <profile> [--config PATH] \
        [--emit {summary,omp-models,omp-config}]

Exit codes: 0 on success; 1 on any resolution/validation error (message on
stderr, never containing credential material).

Stdlib-only when PyYAML is absent — the model-profiles.yml grammar is
restricted to nested mappings of scalars (no lists, no anchors), handled by
the stdlib fallback parser `_parse_nested_yaml`.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_CONFIG_PATH = REPO_ROOT / "config" / "model-profiles.yml"

# The ten canonical Makato model roles (mirrors tests/test_model_roles_config.py
# EXPECTED_ROLES — kept in sync manually since the two modules must not import
# each other).
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


def load_profiles(path: str) -> dict:
    """Load the model-profiles.yml document (PyYAML if available, else fallback)."""
    p = Path(path)
    if not p.exists():
        raise FileNotFoundError(f"model-profiles.yml not found at {p}")
    text = p.read_text(encoding="utf-8")
    try:
        import yaml  # noqa: PLC0415

        data = yaml.safe_load(text)
    except ImportError:
        data = _parse_nested_yaml(text)
    if not isinstance(data, dict) or not isinstance(data.get("profiles"), dict):
        raise ProfileError(f"{p} must define a top-level 'profiles' mapping")
    return data


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


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("profile", help="Profile name (e.g. openai, qwen-vllm, apple-ollama)")
    parser.add_argument("--config", default=str(DEFAULT_CONFIG_PATH), help="Path to model-profiles.yml")
    parser.add_argument(
        "--emit",
        choices=["summary", "omp-models", "omp-config"],
        default="summary",
        help="What to print: a redacted JSON summary, or a generated OMP document",
    )
    args = parser.parse_args(argv[1:])

    try:
        doc = load_profiles(args.config)
        profile = resolve_profile(doc, args.profile)
    except (ProfileError, FileNotFoundError) as exc:
        sys.stderr.write(f"ERROR: {exc}\n")
        return 1

    if args.emit == "summary":
        print(json.dumps(emit_summary(args.profile, profile), indent=2, sort_keys=True))
    elif args.emit == "omp-models":
        print(emit_omp_models(profile), end="")
    else:
        print(emit_omp_config(profile), end="")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
