#!/usr/bin/env python3
"""Emit bash variable assignments from config.yml for loop.sh to eval.

loop.sh sources this via:  eval "$(python3 config/parse-config.py config/config.yml)"

Each config entry emits `NAME="${ENV:-default}"` (or `NAME="default"` when no env
key), preserving loop.sh's historical env-override contract byte-for-byte. Entries
with `export: true` are prefixed `export`. Stdlib-only when PyYAML is absent — the
config.yml grammar is restricted to one flow-style mapping per line.

Provider-neutral model profile metadata (issue #43 / AC-1): MAKATO_MODEL_PROFILE
is a plain `vars:` entry in config.yml — no credential ever flows through this
emitter. Profile resolution/validation and credential handling live in
config/model-profiles.yml and scripts/resolve-model-profile.py; this module only
ever sees the profile name, which is non-secret.
"""

import sys


def _parse_flow_mappings(text):
    """Minimal parser for `- { k: v, k: v }` lines (stdlib fallback)."""
    entries = []
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or not line.startswith("-"):
            continue
        body = line[1:].strip()
        if not (body.startswith("{") and body.endswith("}")):
            continue
        inner = body[1:-1].strip()
        entry = {}
        # Split on commas that separate key: value pairs, but NOT commas inside
        # quoted strings (e.g. default: "sonnet,haiku,opus").
        for pair in _split_flow_pairs(inner):
            if ":" not in pair:
                continue
            key, val = pair.split(":", 1)
            key = key.strip()
            val = val.strip()
            if len(val) >= 2 and val[0] == val[-1] and val[0] in "\"'":
                val = val[1:-1]
            entry[key] = val
        if entry:
            entries.append(entry)
    return entries


def _split_flow_pairs(inner: str) -> list:
    """Split a YAML flow-mapping body on key-separating commas, ignoring quoted ones.

    A comma is a key separator only when it appears outside a quoted string and
    the next non-space character is an identifier start (letter or underscore).
    This avoids splitting on commas that are part of a quoted default value
    such as ``default: "sonnet,haiku,opus"``.
    """
    pairs: list = []
    in_quote = False
    q_char = ""
    start = 0
    i = 0
    while i < len(inner):
        ch = inner[i]
        if in_quote:
            if ch == q_char and (i == 0 or inner[i - 1] != "\\"):
                in_quote = False
        elif ch in ('"', "'"):
            in_quote = True
            q_char = ch
        elif ch == "," and not in_quote:
            rest = inner[i + 1 :].lstrip()
            if rest and (rest[0].isalpha() or rest[0] == "_"):
                pairs.append(inner[start:i])
                start = i + 1
        i += 1
    pairs.append(inner[start:])
    return pairs


def _expand_models(models):
    """Convert a models: dict into flat-list entries for emit().

    Each role key becomes a MAKATO_MODEL_<ROLE>_BASE_URL entry.  Missing or
    non-dict role values are tolerated — base_url defaults to an empty string.

    Only reachable via the yaml.safe_load path; the stdlib fallback
    (_parse_flow_mappings) cannot handle a top-level dict schema.
    """
    entries = []
    if not isinstance(models, dict):
        return entries
    for role, cfg in models.items():
        base_url = ""
        if isinstance(cfg, dict):
            base_url = cfg.get("base_url") or ""
        entries.append({"var": f"MAKATO_MODEL_{role.upper()}_BASE_URL", "default": base_url})
    return entries


def load(path):
    with open(path, encoding="utf-8") as fh:
        text = fh.read()
    try:
        import yaml  # noqa: PLC0415

        data = yaml.safe_load(text)
        if isinstance(data, list):
            # Existing flat-list path — byte-for-byte identical behaviour.
            return [e for e in (data or []) if isinstance(e, dict)]
        if isinstance(data, dict):
            # New schema branch: top-level mapping may carry a vars: list and/or
            # a models: dict.  The stdlib fallback cannot reach this branch.
            entries = []
            for e in data.get("vars") or []:
                if isinstance(e, dict):
                    entries.append(e)
            entries.extend(_expand_models(data.get("models")))
            return entries
        return []
    except ImportError:
        # stdlib fallback — flat-list only; models: dict schema requires PyYAML.
        return _parse_flow_mappings(text)


def _truthy(v):
    return str(v).strip().lower() in ("1", "true", "yes")


def emit(entries):
    lines = []
    for e in entries:
        var = e.get("var")
        if not var:
            continue
        default = "" if e.get("default") is None else str(e["default"])
        env = e.get("env")
        prefix = "export " if _truthy(e.get("export", False)) else ""
        if env:
            lines.append(f'{prefix}{var}="${{{env}:-{default}}}"')
        else:
            lines.append(f'{prefix}{var}="{default}"')
    return "\n".join(lines)


def main(argv):
    if len(argv) != 2:
        sys.stderr.write("usage: parse-config.py <config.yml>\n")
        return 2
    print(emit(load(argv[1])))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
