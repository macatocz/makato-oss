#!/usr/bin/env bash
# Smoke tests for write-lessons.sh (#473 — build-lane lesson and fact write).
#
# write-lessons.sh is a PURE WRITER: it appends exactly one JSONL lesson record
# to specs/<key>-*/change-lessons.jsonl. The record shape must match what
# promote-lessons.sh (S2/#471) reads from change-lessons.jsonl as "source B":
# fields {ts, tier, text, tags, scope, key, repo}. The writer NEVER touches
# .makato/memory/ — promotion is documentation-agent's job (via promote-lessons.sh).
#
# The tests build a throwaway git sandbox so the script's git-common-dir REPO_ROOT
# resolution and `git remote get-url origin` repo derivation exercise real git plumbing.
#
# Coverage:
#   T1  — script exists at expected path
#   T2  — shebang is #!/usr/bin/env bash
#   T3  — appending a procedural record produces a valid JSON line
#   T4  — record contains all required fields: ts, tier, text, tags, scope, key, repo
#   T5  — semantic record with scope=generalizable preserves tier=semantic
#   T6  — no write to .makato/memory/ during a write-lessons call
#   T7  — REPO_ROOT worktree pattern (git-common-dir) is present in the script
#   T8  — multiple appends grow the file line-count monotonically (append, not overwrite)
#   T9  — invalid tier (episodic) exits non-zero and appends nothing
#   T10 — invalid scope (global) exits non-zero and appends nothing
#   T11 — build-verify SKILL.md documents the write-lessons.sh call-site
#   T12 — build-push-to-git SKILL.md documents the write-lessons.sh call-site
#
# Exit code: number of failures; 0 = all green.

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
# T1 — script exists
# ===========================================================================
echo "T1: write-lessons.sh exists"
if [[ -f "$WRITE_LESSONS" ]]; then
  _pass "found at $WRITE_LESSONS"
else
  _fail "missing at $WRITE_LESSONS"
  # Nothing else can run without the script — bail with the count so far.
  echo ""
  echo "$FAIL test(s) failed."
  exit "$FAIL"
fi

# ===========================================================================
# T2 — shebang
# ===========================================================================
echo "T2: shebang is #!/usr/bin/env bash"
FIRST_LINE="$(head -1 "$WRITE_LESSONS")"
if [[ "$FIRST_LINE" == "#!/usr/bin/env bash" ]]; then
  _pass "$FIRST_LINE"
else
  _fail "unexpected shebang: $FIRST_LINE"
fi

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

# ===========================================================================
# T6 — no write to .makato/memory/ during a call
# ===========================================================================
echo "T6: .makato/memory/ untouched"
KEY="473-makato-build-lane-lesson-and-fact-write"
SB="$(_mk_sandbox "$KEY")"
BEFORE="$(cat "$SB/.makato/memory/procedural.jsonl" "$SB/.makato/memory/semantic.jsonl" | wc -c | tr -d ' ')"
(
  cd "$SB" || exit 1
  bash "$WRITE_LESSONS" "$KEY" semantic generalizable \
    "This must not land in .makato/memory" "shell" >/dev/null 2>&1
)
AFTER="$(cat "$SB/.makato/memory/procedural.jsonl" "$SB/.makato/memory/semantic.jsonl" | wc -c | tr -d ' ')"
if [[ "$BEFORE" == "0" ]] && [[ "$AFTER" == "0" ]]; then
  _pass ".makato/memory/ files remain empty (0 bytes)"
else
  _fail ".makato/memory/ changed: before=$BEFORE after=$AFTER"
fi
rm -rf "$SB"

# ===========================================================================
# T7 — REPO_ROOT worktree pattern present (git-common-dir)
# ===========================================================================
echo "T7: git-common-dir REPO_ROOT pattern present"
if grep -q 'git.*rev-parse.*--git-common-dir' "$WRITE_LESSONS"; then
  _pass "git rev-parse --git-common-dir present"
else
  _fail "git-common-dir REPO_ROOT resolution missing (worktree contract)"
fi

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
LINES="$(wc -l < "$CL" | tr -d ' ')"
if [[ "$LINES" == "3" ]]; then
  _pass "3 appends → 3 lines"
else
  _fail "expected 3 lines, got $LINES"
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
# T11 — build-verify SKILL.md documents the call-site
# ===========================================================================
echo "T11: build-verify SKILL.md documents write-lessons.sh call-site"
BV_SKILL="$SCRIPT_DIR/../skills/build-verify/SKILL.md"
if [[ -f "$BV_SKILL" ]] && grep -q 'write-lessons.sh' "$BV_SKILL"; then
  _pass "call-site documented in build-verify SKILL.md"
else
  _fail "write-lessons.sh call-site missing from build-verify SKILL.md"
fi

# ===========================================================================
# T12 — build-push-to-git SKILL.md documents the call-site
# ===========================================================================
echo "T12: build-push-to-git SKILL.md documents write-lessons.sh call-site"
BP_SKILL="$SCRIPT_DIR/../skills/build-push-to-git/SKILL.md"
if [[ -f "$BP_SKILL" ]] && grep -q 'write-lessons.sh' "$BP_SKILL"; then
  _pass "call-site documented in build-push-to-git SKILL.md"
else
  _fail "write-lessons.sh call-site missing from build-push-to-git SKILL.md"
fi

# ---------------------------------------------------------------------------
echo ""
if [[ "$FAIL" -eq 0 ]]; then
  echo "All 12 tests passed."
else
  echo "$FAIL test(s) failed."
fi
exit "$FAIL"
