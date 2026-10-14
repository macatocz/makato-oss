#!/usr/bin/env bash
# Behavioral smoke tests for source capture, validation, and ambiguous spec keys.
# Full capture/persist/recall behavior: tests/test_capture_memory.py.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WRITE_LESSONS="$SCRIPT_DIR/write-lessons.sh"
FAIL=0

_pass() { printf '  ✓ %s\n' "$1"; }
_fail() { printf '  ✗ %s\n' "$1"; FAIL=$((FAIL + 1)); }

# ---------------------------------------------------------------------------
# Build a throwaway git repo sandbox with a specs/<key>-<slug>/ folder.
# Echoes the sandbox root. Caller is responsible for rm -rf.
# ---------------------------------------------------------------------------
_mk_sandbox() {
  local key="$1"
  local root
  root="$(mktemp -d)"
  (
    cd "$root" || exit 1
    git init -q
    git config user.email "test@example.com"
    git config user.name "Test"
    git remote add origin "https://github.com/macatocz/makato.git"
    mkdir -p "specs/${key}-some-slug"
    mkdir -p ".makato/memory"
    : > ".makato/memory/procedural.jsonl"
    : > ".makato/memory/semantic.jsonl"
  )
  echo "$root"
}

CL_REL() { echo "specs/$1-some-slug/change-lessons.jsonl"; }



# ===========================================================================
# T3 — appending a procedural record produces a valid JSON line
# ===========================================================================
echo "T3: procedural record is valid JSON"
KEY="473-makato-build-lane-lesson-and-fact-write"
SB="$(_mk_sandbox "$KEY")"
(
  cd "$SB" || exit 1
  bash "$WRITE_LESSONS" "$KEY" procedural local \
    "Guard tier and scope before appending" "shell,tech:harness" >/dev/null 2>&1
)
CL="$SB/$(CL_REL "$KEY")"
if [[ -f "$CL" ]] && [[ "$(wc -l < "$CL" | tr -d ' ')" == "1" ]] \
   && python3 -c "import json,sys; json.loads(open('$CL').readline())" 2>/dev/null; then
  _pass "one valid JSON line written"
else
  _fail "expected one valid JSON line in $CL"
fi
rm -rf "$SB"

# ===========================================================================
# T4 — record has all required fields, non-empty
# ===========================================================================
echo "T4: record has ts, tier, text, tags, scope, key, repo"
KEY="473-makato-build-lane-lesson-and-fact-write"
SB="$(_mk_sandbox "$KEY")"
(
  cd "$SB" || exit 1
  bash "$WRITE_LESSONS" "$KEY" procedural generalizable \
    "Reuse build-log.sh REPO_ROOT trick" "shell" >/dev/null 2>&1
)
CL="$SB/$(CL_REL "$KEY")"
CHECK="$(python3 - "$CL" <<'PY'
import json, sys
rec = json.loads(open(sys.argv[1]).readline())
required = ["ts", "tier", "text", "tags", "scope", "key", "repo"]
missing = [f for f in required if f not in rec or (rec[f] == "" if f != "tags" else False)]
# tags must be a list
if not isinstance(rec.get("tags"), list):
    missing.append("tags(not-list)")
print("OK" if not missing else "MISSING:" + ",".join(missing))
PY
)"
if [[ "$CHECK" == "OK" ]]; then
  _pass "all required fields present and non-empty"
else
  _fail "field check: $CHECK"
fi
rm -rf "$SB"

# ===========================================================================
# T5 — semantic record preserves tier=semantic, scope=generalizable
# ===========================================================================
echo "T5: semantic record preserves tier=semantic scope=generalizable"
KEY="473-makato-build-lane-lesson-and-fact-write"
SB="$(_mk_sandbox "$KEY")"
(
  cd "$SB" || exit 1
  bash "$WRITE_LESSONS" "$KEY" semantic generalizable \
    "testcontainers need a colima socket override" "tech:harness,docker" >/dev/null 2>&1
)
CL="$SB/$(CL_REL "$KEY")"
CHECK="$(python3 - "$CL" <<'PY'
import json, sys
rec = json.loads(open(sys.argv[1]).readline())
ok = rec.get("tier") == "semantic" and rec.get("scope") == "generalizable"
print("OK" if ok else f"tier={rec.get('tier')} scope={rec.get('scope')}")
PY
)"
if [[ "$CHECK" == "OK" ]]; then
  _pass "tier=semantic scope=generalizable preserved"
else
  _fail "semantic check: $CHECK"
fi
rm -rf "$SB"

# Capture-time durable routing and linked-worktree behavior are exercised by
# tests/test_capture_memory.py.

# ===========================================================================
# T8 — multiple appends grow line count monotonically
# ===========================================================================
echo "T8: appends grow line count (append, not overwrite)"
KEY="473-makato-build-lane-lesson-and-fact-write"
SB="$(_mk_sandbox "$KEY")"
(
  cd "$SB" || exit 1
  bash "$WRITE_LESSONS" "$KEY" procedural local "first" "a" >/dev/null 2>&1
  bash "$WRITE_LESSONS" "$KEY" procedural local "second" "b" >/dev/null 2>&1
  bash "$WRITE_LESSONS" "$KEY" semantic generalizable "third" "c" >/dev/null 2>&1
)
CL="$SB/$(CL_REL "$KEY")"
if python3 - "$CL" <<'PY'
import json, sys
records = [json.loads(line) for line in open(sys.argv[1])]
assert [record["text"] for record in records] == ["first", "second", "third"]
assert [record["tier"] for record in records] == ["procedural", "procedural", "semantic"]
PY
then
  _pass "later captures preserve earlier source evidence"
else
  _fail "capture overwrote or changed source evidence"
fi
rm -rf "$SB"

# ===========================================================================
# T9 — invalid tier rejected, nothing appended
# ===========================================================================
echo "T9: invalid tier exits non-zero, appends nothing"
KEY="473-makato-build-lane-lesson-and-fact-write"
SB="$(_mk_sandbox "$KEY")"
RC=0
(
  cd "$SB" || exit 1
  bash "$WRITE_LESSONS" "$KEY" episodic local "bad tier" "x" >/dev/null 2>&1
) || RC=$?
CL="$SB/$(CL_REL "$KEY")"
if [[ "$RC" -ne 0 ]] && [[ ! -f "$CL" || "$(wc -l < "$CL" | tr -d ' ')" == "0" ]]; then
  _pass "invalid tier rejected (rc=$RC), no record written"
else
  _fail "invalid tier not rejected: rc=$RC, file=$CL"
fi
rm -rf "$SB"

# ===========================================================================
# T10 — invalid scope rejected, nothing appended
# ===========================================================================
echo "T10: invalid scope exits non-zero, appends nothing"
KEY="473-makato-build-lane-lesson-and-fact-write"
SB="$(_mk_sandbox "$KEY")"
RC=0
(
  cd "$SB" || exit 1
  bash "$WRITE_LESSONS" "$KEY" procedural global "bad scope" "x" >/dev/null 2>&1
) || RC=$?
CL="$SB/$(CL_REL "$KEY")"
if [[ "$RC" -ne 0 ]] && [[ ! -f "$CL" || "$(wc -l < "$CL" | tr -d ' ')" == "0" ]]; then
  _pass "invalid scope rejected (rc=$RC), no record written"
else
  _fail "invalid scope not rejected: rc=$RC, file=$CL"
fi
rm -rf "$SB"



# ===========================================================================
# T14 — ambiguous prefix matches are rejected without writing to either folder
# ===========================================================================
echo "T14: ambiguous spec folders are rejected without appending"
KEY="473-makato-build-lane-lesson-and-fact-write"
SB="$(_mk_sandbox "$KEY")"
mkdir -p "$SB/specs/${KEY}-another-slug"
RC=0
(
  cd "$SB" || exit 1
  bash "$WRITE_LESSONS" "$KEY" procedural local "must not be misrouted" "shell" >/dev/null 2>&1
) || RC=$?
FIRST="$SB/specs/${KEY}-some-slug/change-lessons.jsonl"
SECOND="$SB/specs/${KEY}-another-slug/change-lessons.jsonl"
if [[ "$RC" -ne 0 && ! -e "$FIRST" && ! -e "$SECOND" ]]; then
  _pass "ambiguous prefix rejected (rc=$RC), no folder receives a record"
else
  _fail "ambiguous prefix not rejected safely: rc=$RC, files=$FIRST $SECOND"
fi
rm -rf "$SB"

# ---------------------------------------------------------------------------
echo ""
if [[ "$FAIL" -eq 0 ]]; then
  echo "All capture smoke checks passed."
else
  echo "$FAIL test(s) failed."
fi
exit "$FAIL"
