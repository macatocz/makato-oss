#!/usr/bin/env bash
# Contract / smoke test for the unified Finding schema across the sensor loop (#230).
#
# The makato-build sensor loop passes a normalised Finding object through:
#
#     build-sensors → sensor-fixer → build-resolve-finding → build-fix-types
#                                                           → build-fix-security
#
# shared/parse-sarif.py (class Finding) is the SOLE emitter and the source of
# truth for the shape. Issue #230 was documentation drift: build-sensors/SKILL.md
# and agents/sensor-fixer.md documented a stale shape
# ({tool, rule_id, file, line, severity, message, fixable}) that no longer
# matched the emitter or the three fixer consumers ({rule, path, autofix_available}).
#
# This test pins the contract so the drift cannot silently return:
#   A1 — the emitter's serialised keys equal the documented canonical set exactly.
#   A2 — the two rewritten artefacts carry no forbidden field names
#        (rule_id, fixable, or a Finding-level `file` JSON key).
#   A3 — the three fixer consumers still read the canonical names.
#   A4 — shared/finding-schema.md exists and is linked from all four loop artefacts.
#   A5 — parse-sarif.py --selftest still exits 0 (no runtime behaviour change).
#
# A1/A5 execute the real parse-sarif.py; A2/A3/A4 grep the committed prose.
# No mutation, no network.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
FAIL=0

PARSE_SARIF="$PLUGIN_DIR/shared/parse-sarif.py"
SCHEMA_DOC="$PLUGIN_DIR/shared/finding-schema.md"
SENSORS_MD="$PLUGIN_DIR/skills/build-sensors/SKILL.md"
FIXER_MD="$PLUGIN_DIR/agents/sensor-fixer.md"
RESOLVE_MD="$PLUGIN_DIR/skills/build-resolve-finding/SKILL.md"
FIXTYPES_MD="$PLUGIN_DIR/skills/build-fix-types/SKILL.md"
FIXSEC_MD="$PLUGIN_DIR/skills/build-fix-security/SKILL.md"

# The canonical Finding key set, sorted. This is the ONE place the contract is
# hard-coded; A1 proves the emitter agrees, the docs prose is checked against it
# by A2/A3.
CANONICAL="autofix_available column line message path raw rule severity tool"

_pass() { printf '  \xe2\x9c\x93 %s\n' "$1"; }
_fail() { printf '  \xe2\x9c\x97 %s\n' "$1"; FAIL=$((FAIL + 1)); }

# ---- A1: emitter's serialised keys == canonical set -----------------------
echo "A1: parse-sarif.py Finding.to_dict() keys == documented canonical set"
EMITTED_KEYS="$(
  python3 - "$PARSE_SARIF" <<'PY'
import importlib.util, sys
path = sys.argv[1]
spec = importlib.util.spec_from_file_location("parse_sarif_under_test", path)
mod = importlib.util.module_from_spec(spec)
# Register before exec so @dataclass introspection can resolve the module dict.
sys.modules["parse_sarif_under_test"] = mod
spec.loader.exec_module(mod)
fixture = {
    "version": "2.1.0",
    "runs": [
        {
            "tool": {"driver": {"name": "ruff", "rules": [{"id": "F401"}]}},
            "results": [
                {
                    "ruleId": "F401",
                    "level": "warning",
                    "message": {"text": "unused import"},
                    "locations": [
                        {
                            "physicalLocation": {
                                "artifactLocation": {"uri": "a.py"},
                                "region": {"startLine": 3, "startColumn": 1},
                            }
                        }
                    ],
                    "fixes": [{}],
                }
            ],
        }
    ],
}
finding = mod.parse_sarif(fixture)[0]
print(" ".join(sorted(finding.to_dict().keys())))
PY
)"
EMITTED_SORTED="$(printf '%s\n' "$EMITTED_KEYS" | tr ' ' '\n' | sort | tr '\n' ' ' | sed 's/ *$//')"
CANONICAL_SORTED="$(printf '%s\n' "$CANONICAL" | tr ' ' '\n' | sort | tr '\n' ' ' | sed 's/ *$//')"
if [[ "$EMITTED_SORTED" == "$CANONICAL_SORTED" ]]; then
  _pass "emitter keys match canonical: $CANONICAL_SORTED"
else
  _fail "emitter keys drifted — got [$EMITTED_SORTED] expected [$CANONICAL_SORTED]"
fi

# ---- A2: no forbidden field names in the two rewritten artefacts ----------
echo "A2: build-sensors + sensor-fixer carry no rule_id / fixable / Finding-level file"
for f in "$SENSORS_MD" "$FIXER_MD"; do
  base="$(basename "$(dirname "$f")")/$(basename "$f")"
  if grep -qE '\brule_id\b' "$f"; then
    _fail "$base still references 'rule_id'"
  else
    _pass "$base free of 'rule_id'"
  fi
  if grep -qE '\bfixable\b' "$f"; then
    _fail "$base still references 'fixable'"
  else
    _pass "$base free of 'fixable'"
  fi
  # Finding-level `file` key: match it only inside a brace-delimited shape
  # description (", file," / "{file," / "`file`" as a JSON key), not prose like
  # "file path". The stale docs wrote it as `file` inside the shape listing.
  # shellcheck disable=SC2016  # backticks are a literal grep pattern, not a subshell
  if grep -qE '[{,] *"?file"?[,: ]|`file`[ ,]' "$f"; then
    _fail "$base appears to use a Finding-level 'file' key in a shape description"
  else
    _pass "$base free of Finding-level 'file' key"
  fi
done

# ---- A3: the three fixer consumers still read the canonical names ----------
echo "A3: build-resolve-finding / build-fix-types / build-fix-security stay canonical"
for f in "$RESOLVE_MD" "$FIXTYPES_MD" "$FIXSEC_MD"; do
  base="$(basename "$(dirname "$f")")/$(basename "$f")"
  if grep -qE '"rule"' "$f" && grep -qE '"path"' "$f" \
      && grep -qE '"autofix_available"' "$f"; then
    _pass "$base reads rule/path/autofix_available"
  else
    _fail "$base missing one of the canonical consumer fields"
  fi
  if grep -qE '\brule_id\b|\bfixable\b' "$f"; then
    _fail "$base reintroduced a forbidden field name"
  else
    _pass "$base free of forbidden field names"
  fi
done

# ---- A4: shared reference doc exists and is linked from all four artefacts --
echo "A4: shared/finding-schema.md exists and is linked from every loop artefact"
if [[ -f "$SCHEMA_DOC" ]]; then
  _pass "shared/finding-schema.md exists"
else
  _fail "shared/finding-schema.md is missing"
fi
for f in "$SENSORS_MD" "$FIXER_MD" "$RESOLVE_MD" "$FIXTYPES_MD" "$FIXSEC_MD"; do
  base="$(basename "$(dirname "$f")")/$(basename "$f")"
  if grep -qE 'finding-schema\.md' "$f"; then
    _pass "$base links to finding-schema.md"
  else
    _fail "$base does not link to finding-schema.md"
  fi
done

# ---- A5: parse-sarif.py --selftest still green (no behaviour change) --------
echo "A5: parse-sarif.py --selftest exits 0"
if python3 "$PARSE_SARIF" --selftest >/dev/null 2>&1; then
  _pass "parse-sarif.py --selftest passes"
else
  _fail "parse-sarif.py --selftest failed — runtime behaviour changed"
fi

echo
if (( FAIL == 0 )); then
  echo "All Finding-schema contract tests passed."
  exit 0
else
  echo "$FAIL Finding-schema contract test(s) failed."
  exit 1
fi
