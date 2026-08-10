# Contract: loop.sh KEY-derivation → makato-change dispatch seam

> **Seam #2 of 5** from the suite feature audit
> (`docs/makato-feature-audit.md` → Cross-plugin integration seams).
>
> This document is the authoritative reference for the boundary between
> `plugins/makato-orchestrate/scripts/loop.sh` and the
> `makato-change:orchestrate --autonomous` skill. It contains **no code
> duplication** — all implementation details reference line ranges in
> `loop.sh` as the single source of truth. (issue #717)

---

## 1 — How `_derive_key_for_issue` maps a `type:change` issue to a KEY

**Function:** `_derive_key_for_issue` — `loop.sh` lines 2709–2850.

The function accepts `<ISSUE_NUMBER> [<REPO>]` and resolves a KEY through
three ordered fallbacks:

| Priority | Source | Pattern |
|----------|--------|---------|
| 1 (primary) | Issue body — to-issues provenance footer | `` *Feature slug: `<slug>` — produced by to-issues …* `` |
| 2 (fallback) | Issue body — top-of-body reference | `specs/<slug>/stories.json` |
| 3 (title fallback, #232) | Issue title — normalised | `<issue>-<lowercased-title-max-40-chars>` |

**Normalisation rule** (title fallback, loop.sh lines 2784–2791):
lowercase → non-alphanumeric to `-` → collapse runs → strip leading/trailing
`-` → truncate to 40 chars → strip trailing `-`. Identical to the
`seed-issue` SLUG convention.

**Test seams (offline):**
- `MAKATO_LOOP_ISSUE_BODY_OVERRIDE=<file>` — replaces the `gh issue view`
  body fetch with file contents.
- `MAKATO_LOOP_ISSUE_TITLE_OVERRIDE=<string>` — replaces the `gh issue view`
  title fetch.

The derived KEY is used as-is for `type:change` issues: the
`_cmd_dispatch` routing block (Section 3) sets
`BRANCH=feat/<KEY>` only for non-change issues; change-orchestrate owns
its own branch/worktree lifecycle.

---

## 2 — Dispatch prompt shape passed to `makato-change:orchestrate --autonomous`

**Location:** `loop.sh` lines 5093–5096.

When `issue_type == "type:change"`, `_cmd_dispatch` builds the following
dispatch prompt (exact template, with variable substitutions):

```
Use the Skill tool to invoke the makato-change:orchestrate skill with
args '<KEY> --autonomous'. Required env: ISSUE_NUMBER=<N> ISSUE_KEY=<KEY>
REPO=<MAKATO_LOOP_DISPATCH_REPO> REPO_ROOT=<REPO_ROOT>.
MAKATO_HEADLESS=1 is already exported. The skill owns the
analyze→design→execute→resolve-review loop and writes
change-state-<N>.json + a workflow-state-<N>.json loop-compat stub.
Return R1 envelope verbatim.
```

**Required fields present in the prompt:**

| Field | Value | Purpose |
|-------|-------|---------|
| `makato-change:orchestrate` | literal | Identifies the skill to invoke |
| `--autonomous` | literal flag | Activates headless mode per `AUTONOMOUS-MODE.md` |
| `ISSUE_NUMBER=<N>` | integer | GitHub issue number |
| `ISSUE_KEY=<KEY>` | derived KEY | Spec-folder key for state file naming |
| `REPO=<owner/name>` | string | Target repository (from `MAKATO_LOOP_DISPATCH_REPO`) |
| `REPO_ROOT=<path>` | absolute path | Main checkout root for worktree isolation (#467) |

`MAKATO_HEADLESS=1` is exported into the subprocess environment
(`loop.sh` line 5137) as a defensive belt: any skill that ignores the
delegation prompt and falls back to interactive mode HALTs with
`MISSING_INPUT` instead of hanging on `AskUserQuestion` (the #163 fix).

**Dry-run equivalent** (`--dry-run`, `loop.sh` line 4875):

```
loop: --dry-run — would exec: <CLAUDE_BIN> --dangerously-skip-permissions
  -p "<dispatch makato-change:orchestrate --autonomous for issue #<N>
      KEY=<KEY> REPO=<REPO> REPO_ROOT=<REPO_ROOT>>"
```

---

## 3 — `workflow-state-N.json` schema fields loop reads to determine phase

**Function:** `in_flight_issues` — `loop.sh` lines 1431–1447.

`in_flight_issues` scans `$SPECS_DIR` (depth 2) for files matching
`workflow-state-*.json` (and legacy `workflow-state.json`). For each
file it runs:

```
jq -r 'select(.current_phase != "done") | (.issue_number // empty)'
```

**Fields loop reads:**

| Field | Type | Meaning |
|-------|------|---------|
| `current_phase` | string | Phase of the current run. Only `"done"` is treated as complete. |
| `issue_number` | integer | Issue this state belongs to. Used to match back to the dispatch queue. |

**Loop-compat stub requirement:** `makato-change:orchestrate` writes a
`workflow-state-<N>.json` stub alongside its own `change-state-<N>.json`
so `in_flight_issues` can track the change issue the same way it tracks
po-agent issues. The stub must contain at minimum:

```json
{
  "issue_number": <N>,
  "current_phase": "<active-phase>"
}
```

While the change pipeline is running, `current_phase` is any value other
than `"done"` (e.g. `"analyze"`, `"design"`, `"execute"`). When the
pipeline finishes, the stub is updated to `"done"`.

**Test seam (offline):** point `SPECS_DIR` at a temporary directory
containing fixture `workflow-state-<N>.json` files to exercise
`in_flight_issues` without any live state.

---

## 4 — How loop.sh determines an issue is done

An issue is no longer in-flight when **either** of the following is true:

1. **`current_phase == "done"`** — `in_flight_issues` does not emit the
   issue number, so the dispatch gate (loop.sh lines 4983–4990) does not
   skip it on the next poll round. The loop can pick it up for a
   re-dispatch if the board Status returns to Ready (normal completion
   flow: board advances to Done by `documentation-agent`).

2. **No `workflow-state-<N>.json` exists** — `in_flight_issues` finds
   no file for the issue and emits nothing. Treated identically to `done`.

**Poll flow (simplified):**

```
loop tick
  └─ _cmd_dispatch(issue)
       ├─ in_flight_issues()        ← reads SPECS_DIR/**workflow-state-*.json
       │    └─ if issue in set → "skip dispatch (in-flight)"
       └─ if not in-flight → exec claude -p "<dispatch prompt>"
```

The CAS claim (`MAKATO_LOOP_CLAIM_ON_DISPATCH=1`, loop.sh line ~5028) moves
the board card to `In progress` atomically before forking claude, providing
the cross-machine double-dispatch lock. `in_flight_issues` is the
single-machine guard; the board CAS is the cross-machine guard.

---

## 5 — Test coverage

The integration test at
`plugins/makato-orchestrate/scripts/tests/loop-change-dispatch-integration-tests.sh`
exercises all four properties described above:

| Test | Property verified |
|------|-------------------|
| T_CD1 | KEY derived from to-issues footer (Section 1) |
| T_CD2 | Dispatch prompt fields (Section 2) |
| T_CD3 | In-flight gate blocks second dispatch (Section 3) |
| T_CD4 | `current_phase:"done"` does not block advancement (Section 4) |

All four tests are offline (no live `gh` calls).
