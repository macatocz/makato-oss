#!/usr/bin/env python3
"""Emit bash variable assignments from config.yml for loop.sh to eval.

loop.sh sources this via:  eval "$(python3 config/parse-config.py config/config.yml)"

Each config entry emits `NAME="${ENV:-default}"` (or `NAME="default"` when no env
key), preserving loop.sh's historical env-override contract byte-for-byte. Entries
with `export: true` are prefixed `export`. Stdlib-only when PyYAML is absent — the
config.yml grammar is restricted to one flow-style mapping per line.
"""
import re
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
        # Split on commas that separate key: value pairs.
        for pair in re.split(r",\s*(?=[A-Za-z_])", inner):
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


def load(path):
    with open(path, encoding="utf-8") as fh:
        text = fh.read()
    try:
        import yaml  # noqa: PLC0415
        data = yaml.safe_load(text)
        return [e for e in (data or []) if isinstance(e, dict)]
    except ImportError:
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
