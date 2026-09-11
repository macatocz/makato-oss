---
name: build-sensors
description: >-
  Run pre-commit sensors against staged/all/changed files, parse findings via
  shared/parse-sarif.py into the canonical Finding schema, and dispatch the
  sensor-fixer agent in a bounded loop (MAX_LOOPS=5) until the working tree is
  clean or the cap is hit. Implements gate-0 of the build pipeline. Use when:
  pre-commit hook fails, verifying gate-0 on a build, or an autonomous fixer
  needs to re-run sensors after edits. Trigger keywords: run sensors, verify
  sensors, gate-0, pre-commit, sensor loop.
version: "1.2.1"
argument-hint: "scope=[staged|all|changed-vs-main] spec_key=<story-key>"
tools: Bash, Read, Edit, Write, Agent
metadata:
  authors: [makato-build]
  last_updated: "2026-08-05"
---

# build-sensors

Gate-0 sensor loop: run pre-commit, normalise findings to `list[Finding]`, dispatch
`sensor-fixer`, re-run until clean or `MAX_LOOPS` reached.

## Trigger phrases

- `/makato-build:build-sensors`
- `run sensors`
- `verify sensors`
- `gate-0`

## Inputs

| Name | Type | Required | Default | Notes |
|------|------|----------|---------|-------|
| `scope` | enum: `staged` \| `all` \| `changed-vs-main` | no | `staged` | Selects which files pre-commit operates on. |
| `spec_key` | string | yes | — | Used to locate `specs/<key>/build.jsonl`. |
| `max_loops` | integer | no | `5` | Hard cap on fix-and-rerun iterations. |

---

## Steps

### Step 1 — Detect repository root

```bash
REPO_ROOT="$(git rev-parse --show-toplevel)"
```

Abort with `{ok: false, error: "not-a-git-repo"}` if this fails.

Confirm `pre-commit` is installed: `pre-commit --version`. If not found, abort with
`{ok: false, error: "pre-commit-not-installed"}` — do NOT install it silently, as
the hook configuration is repo-managed.

### Step 2 — Resolve scope → hook stage + file list

**MANDATORY:** if `scope` was not provided by the caller or the choice is ambiguous,
load `references/scope-and-stage-guide.md` now before selecting. Do NOT load it
for other steps.

Scope selection summary (full rationale and non-convergence playbook in the reference):

| Scope | Hook stage | Use when |
|-------|-----------|----------|
| `staged` | `pre-commit` | Running gate-0 immediately before committing — fastest path. |
| `all` | `manual` | Mid-session full-branch clean check, or after sensor-fixer completes. |
| `changed-vs-main` | `pre-push` | Final pre-push gate: everything the PR will add to the default branch. |

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
  DEFAULT_REF="$(shared/default-branch.sh 2>/dev/null || echo main)"
  mapfile -t FILES < <(git diff "$DEFAULT_REF" --name-only)
  [ "${#FILES[@]}" -eq 0 ] && return_clean "no files changed vs main" && exit 0
  pre-commit run --hook-stage pre-push --files "${FILES[@]}"
  ```

### Step 3 — Capture run output

Persist stdout+stderr to `$REPO_ROOT/.pre-commit-trash/run-<ts>.log`.

### Step 4 — Short-circuit on clean run

If exit code == 0, append to `specs/<spec_key>/build.jsonl`:
```json
{"ts": "<ISO-8601>", "action": "sensors-clean", "scope": "<scope>", "loops": <n>}
```
Return `{ok: true, loops: <n>, resolved: [], residual: [], jsonl_path: "specs/<spec_key>/build.jsonl"}`.

### Step 5 — Collect and normalise findings

**MANDATORY:** load `../../shared/finding-schema.md` now to verify the canonical `Finding`
shape before parsing. Do NOT load it before Step 5 — the schema is only needed at this point.

Gather every SARIF artefact written under `.pre-commit-trash/` plus stdout for hooks that
do not emit SARIF. Pipe each artefact through `shared/parse-sarif.py`
(resolved at runtime as `${REPO_ROOT}/<plugin-root>/shared/parse-sarif.py`; locate
`<plugin-root>` by searching for `shared/parse-sarif.py` from `REPO_ROOT`).

The parser normalises everything to `list[Finding]` with the canonical shape:
`{tool, rule, path, line, column, message, severity, autofix_available, raw}`.
This shape is the sole contract between `build-sensors` and `sensor-fixer`.

### Step 6 — Dispatch `sensor-fixer`

```json
{"FINDINGS": [...], "REPO_ROOT": "...", "SPEC_KEY": "..."}
```

The agent edits the working tree and returns control.

### Step 7 — Re-run loop

Re-run pre-commit with the same scope (Steps 3–7) until:
- the run is clean, or
- `loops == MAX_LOOPS` (default `5`).

### Step 8 — Write outcome to build log

```json
{"ts": "<ISO-8601>", "action": "sensors-loop-complete", "scope": "<scope>",
 "loops": <n>, "resolved": [...], "residual": [...]}
```

---

## Output

```json
{
  "ok": true | false,
  "loops": <int>,
  "resolved": [<Finding>, ...],
  "residual": [<Finding>, ...],
  "jsonl_path": "specs/<spec_key>/build.jsonl"
}
```

`ok` is `true` when the final pre-commit run exits 0. `ok: false` with `residual` populated
means the loop hit `MAX_LOOPS` — report and hand off; do not retry.

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
path error. Always check `[ "${#FILES[@]}" -eq 0 ]` before invoking pre-commit for `staged`
and `changed-vs-main` scopes (Step 2 scripts include this guard).

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
