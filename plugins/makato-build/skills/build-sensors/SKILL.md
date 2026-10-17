---
name: build-sensors
description: >-
  Run pre-commit sensors against staged, all, changed-vs-main, or branch files,
  parse findings via shared/parse-sarif.py into the canonical Finding schema,
  and dispatch sensor-fixer within one shared repair budget. Implements gate-0
  of the build pipeline. Use when: pre-commit hook fails, verifying gate-0 on a
  build, or an autonomous fixer needs to re-run sensors after edits. Trigger
  keywords: run sensors, verify sensors, gate-0, pre-commit, sensor loop.
version: "1.3.0"
argument-hint: "scope=[staged|all|changed-vs-main|branch] spec_key=<story-key>"
tools: Bash, Read, Edit, Write, Agent
metadata:
  authors: [makato-build]
  last_updated: "2026-10-17"
---

# build-sensors

Gate-0 sensor loop: run pre-commit, normalise findings to `list[Finding]`, and dispatch
`sensor-fixer` while one shared Phase 1 repair budget remains.

## Trigger phrases

- `/makato-build:build-sensors`
- `run sensors`
- `verify sensors`
- `gate-0`

## Inputs

| Name | Type | Required | Default | Notes |
|------|------|----------|---------|-------|
| `scope` | enum: `staged` \| `all` \| `changed-vs-main` \| `branch` | no | `staged` | Selects which files pre-commit operates on. |
| `spec_key` | string | yes | — | Used to locate `specs/<key>/build.jsonl`. |
| `max_loops` | integer | no | `5` | Total Phase 1 repair-pass budget across all sensor-fixer dispatches in this invocation. |

Before executing helper commands, resolve `MAKATO_BUILD_ROOT` from
`CLAUDE_PLUGIN_ROOT`, `OMP_PLUGIN_ROOT`, or `PLUGIN_ROOT` (with the
source-checkout fallback under `REPO_ROOT/plugins/makato-build`). Do not search
the consumer repository for installed plugin files.

Read `$MAKATO_BUILD_ROOT/agents/RETURN-CONTRACT.md` before execution. Every exit,
including clean short-circuits and setup failures, uses the final fenced JSON R1
envelope below, with every required field including `tool_calls_used`. Never return
the legacy bare sensor payload or an unfenced JSON object.

Write audit events only through `"$MAKATO_BUILD_ROOT/shared/build-log.sh"`. Build
JSON with `jq -cn` and pass the resulting variable as one quoted argument. Do not
interpolate JSON into an outer quoted `bash -c` command or append raw/pretty JSON
directly to `build.jsonl`; fix a rejected logging invocation before continuing.

---

## Steps

### Step 1 — Detect repository root

```bash
REPO_ROOT="$(git rev-parse --show-toplevel)"
```

If this fails, return R1 `status: "failure"` with `errors: ["not-a-git-repo"]`.

Confirm `pre-commit` is installed: `pre-commit --version`. If not found, return R1
`status: "failure"` with `errors: ["pre-commit-not-installed"]`. Do not install it
silently, as the hook configuration is repo-managed.

### Step 2 — Resolve scope → hook stage + file list

**MANDATORY:** if `scope` was not provided by the caller or the choice is ambiguous,
load `references/scope-and-stage-guide.md` now before selecting. Do NOT load it
for other steps.

Scope selection summary (full rationale and non-convergence playbook in the reference):

| Scope | Hook stage | Use when |
|-------|-----------|----------|
| `staged` | `pre-commit` | Running gate-0 immediately before committing — fastest path. |
| `all` | `manual` | Mid-session full-branch clean check, or when CI has no changed-file sensor scope. |
| `changed-vs-main` | `pre-push` | Final pre-push gate for all files the PR adds to the default branch. |
| `branch` | `manual` | Gate 0 when CI runs sensors on a changed-file diff; includes uncommitted and untracked work. |

Execute the matching script block:

- **`staged`:**
  ```bash
  mapfile -t FILES < <(git diff --cached --name-only)
  [ "${#FILES[@]}" -eq 0 ] && return_clean "no staged files" && exit 0
  pre-commit run --hook-stage pre-commit --files "${FILES[@]}"
  ```

- **`all`:**
  ```bash
  # git add -N registers untracked files as intent-to-add so --all-files sees them.
  # Without this, new files created this session pass gate-0 locally but fail CI
  # (where the file is tracked after commit and hooks scan it — e.g. biome on a new
  # JSON fixture, bandit on a new tool script). git add -N is reversible.
  mapfile -t UNTRACKED < <(git ls-files --others --exclude-standard)
  [ "${#UNTRACKED[@]}" -gt 0 ] && git add -N -- "${UNTRACKED[@]}"
  pre-commit run --hook-stage manual --all-files
  ```

- **`changed-vs-main`:**
  ```bash
  DEFAULT_REF="$("$MAKATO_BUILD_ROOT/shared/default-branch.sh" 2>/dev/null || echo main)"
  mapfile -t FILES < <(git diff "$DEFAULT_REF" --name-only)
  [ "${#FILES[@]}" -eq 0 ] && return_clean "no files changed vs main" && exit 0
  pre-commit run --hook-stage pre-push --files "${FILES[@]}"
  ```

- **`branch`:**
  ```bash
  DEFAULT_REF="$("$MAKATO_BUILD_ROOT/shared/default-branch.sh")"
  BASE_SHA="$(git merge-base HEAD "$DEFAULT_REF")"
  mapfile -t TRACKED < <(git diff --name-only --diff-filter=d "$BASE_SHA")
  mapfile -t UNTRACKED < <(git ls-files --others --exclude-standard)
  [ "${#UNTRACKED[@]}" -gt 0 ] && git add -N -- "${UNTRACKED[@]}"
  FILES=("${TRACKED[@]}" "${UNTRACKED[@]}")
  [ "${#FILES[@]}" -eq 0 ] && return_clean "no branch files changed" && exit 0
  pre-commit run --hook-stage manual --files "${FILES[@]}"
  ```

  This matches CI's manual changed-file lane while including uncommitted work.
  The empty-set guard MUST run before pre-commit; never let an empty `--files`
  list degrade into an all-files run.

### Step 3 — Capture run output

Persist stdout+stderr for each pre-commit run under
`$REPO_ROOT/.pre-commit-trash/run-<ts>.log`; keep the last run's repo-relative
path as `final_run_log`. Parse the final run's hook sections into
`hooks: {"<hook id>":"passed|failed|skipped"}`. A hook absent from that run is
not added to the map.

### Step 4 — Short-circuit on clean run

If exit code == 0, emit this event through the build-log helper:
```json
{"ts":"<ISO-8601>","action":"sensors-clean","scope":"<scope>","loops":<n>,"hooks":{"<hook id>":"passed"},"final_run_log":".pre-commit-trash/run-<ts>.log"}
```
Return the Output R1 envelope with `data.ok: true`, the actual shared-budget
units consumed, empty resolved/residual arrays, and the repo-relative audit and
final-run paths.

### Step 5 — Collect and normalise findings

**MANDATORY:** load `../../shared/finding-schema.md` now to verify the canonical `Finding`
shape before parsing. Do NOT load it before Step 5 — the schema is only needed at this point.

Gather every SARIF artefact written under `.pre-commit-trash/` plus stdout for hooks that
do not emit SARIF. Pipe each artefact through
`"$MAKATO_BUILD_ROOT/shared/parse-sarif.py"`.

The parser normalises everything to `list[Finding]` with the canonical shape:
`{tool, rule, path, line, column, message, severity, autofix_available, raw}`.
This shape is the sole contract between `build-sensors` and `sensor-fixer`.

### Step 6 — Dispatch `sensor-fixer`

If residual findings remain and the shared budget is positive, dispatch with:

```json
{"FINDINGS":[...],"REPO_ROOT":"...","SPEC_KEY":"...","MAX_LOOPS":<remaining budget>}
```

`MAX_LOOPS` is the remaining Phase 1 repair-pass budget, not a fresh per-dispatch
allowance. `sensor-fixer.data.loops` reports the Phase 1 passes it consumed.

### Step 7 — Re-run loop

After each fixer return, update:

```text
REMAINING_BUDGET = max(0, REMAINING_BUDGET - max(1, sensor_fixer.data.loops))
LOOPS += max(1, sensor_fixer.data.loops)
```

Re-run pre-commit with the same scope and capture its output. If clean, finish.
If findings remain and the budget is positive, dispatch sensor-fixer with that
remaining budget. If findings remain at zero budget, return them as residuals
without another dispatch. Initialize `REMAINING_BUDGET` from `max_loops` (default
`5`) and `LOOPS` to `0`; clean sensor runs do not consume repair passes.

### Step 8 — Write outcome to build log

Emit the outcome through the same build-log helper, never direct file appends.

```json
{"ts":"<ISO-8601>","action":"sensors-loop-complete","scope":"<scope>","loops":<n>,"resolved":[...],"residual":[...],"hooks":{"<hook id>":"passed|failed|skipped"},"final_run_log":".pre-commit-trash/run-<ts>.log"}
```

---

## Output

The final content must be a fenced `json` block conforming to R1. Put the sensor
payload under `data`; callers read `data.ok` and `data.residual`, not top-level
legacy fields. Use actual measured values in place of the example counts.

```json
{
  "schema": "r1",
  "agent": "build-sensors",
  "status": "success",
  "summary": "All selected sensor hooks passed.",
  "files_changed": [],
  "tests_written": [],
  "errors": [],
  "tool_calls_used": 0,
  "data": {
    "ok": true,
    "scope": "branch",
    "loops": 0,
    "resolved": [],
    "residual": [],
    "hooks": {"ruff":"passed","pyright":"passed"},
    "final_run_log": ".pre-commit-trash/run-<ts>.log",
    "jsonl_path": "specs/<spec_key>/build.jsonl"
  }
}
```

`data.ok` is true only when the final pre-commit run exits 0. `data.scope`,
`data.hooks`, and `data.final_run_log` describe that final run; before any run,
use an empty hooks map and `null` for `final_run_log`. `data.loops` is the total
shared-budget units consumed across fixer dispatches. Setup or execution
failures return `status: "failure"`, `data.ok: false` and non-empty `errors`.
Residual findings at exhausted budget return `partial` in ordinary sensor mode,
or `failure` during CI repair; include every residual and never claim success.

---

## Anti-patterns

**NEVER** bypass with `git commit --no-verify` or `SKIP=<hook>`.
WHY: the pre-commit hook is the last defense before the diff reaches CI. Bypassing it
guarantees a pipeline failure on the remote (10× more expensive than a local fix). In the
autonomous loop the bypass is silent — no JSONL residual — so the orchestrator treats the
build as clean when it is not.

**NEVER** pass `--files` an unquoted variable that may contain filenames with spaces.
WHY: `pre-commit run --files $FILES` word-splits on spaces, turning one two-word filename
into two non-existent paths. Most hooks silently skip missing paths, giving a false-clean
result. Use bash arrays (`"${FILES[@]}"`) and `mapfile` — see Step 2 scripts.

**NEVER** call `pre-commit run --files ''` (empty FILES argument) without short-circuiting.
WHY: an empty `--files` argument causes many hooks to scan all files or crash with an empty
path error. Always check `[ "${#FILES[@]}" -eq 0 ]` before invoking pre-commit for
`staged`, `changed-vs-main`, and `branch` scopes (Step 2 scripts include this guard).

**NEVER** block the caller on residual findings after `MAX_LOOPS`.
WHY: the orchestrator may have cross-issue context the sensor loop does not — a carry-over
finding under a parallel PR, or a deliberate suppression. Returning residuals in the payload
preserves that decision point rather than deadlocking the build pipeline.

**ALWAYS** write a JSONL entry even on failure or early abort.
WHY: `build.jsonl` is the only spec artefact committed to the repo (#99 contract). A missing
entry is indistinguishable from a crash. Downstream audit tools and `session-status` reconstruct
the build timeline exclusively from this log.

**NEVER** install `pre-commit` or modify hook configuration inside this skill.
WHY: hook configuration is repo-managed and pinned in `.pre-commit-config.yaml`. Silent
installation changes hook versions, which can alter which findings are emitted mid-session
and corrupt the JSONL audit trail with version-skew noise.

---

## References

| Reference | Load trigger |
|-----------|-------------|
| `references/scope-and-stage-guide.md` | **MANDATORY at Step 2** when `scope` is absent or ambiguous. Covers hook-stage rationale, the `git add -N` CI/local mismatch pattern, and non-convergence playbook. |
| `../../shared/finding-schema.md` | **MANDATORY at Step 5** before parsing findings. Canonical `Finding` shape, forbidden field names, `repair_hint` contract, severity vocabulary note. |
