---
name: build-sensors
description: Run pre-commit sensors against staged/all/changed files, parse findings, dispatch sensor-fixer agent until clean or MAX_LOOPS=5. Use when pre-commit hook fails, when verifying gate-0 on a build, or when an autonomous fixer needs to re-run sensors after edits.
version: "1.1.0"
tools: Bash, Read, Edit, Write, Agent
---

# build-sensors

Run pre-commit sensors against the chosen file scope, parse findings, and dispatch the `sensor-fixer` agent in a bounded loop until the working tree is clean or the loop budget is exhausted. This skill implements **gate-0** of the build pipeline.

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

## Steps

1. **Detect repository root.**
   ```bash
   REPO_ROOT="$(git rev-parse --show-toplevel)"
   ```
   Abort with `{ok: false, error: "not-a-git-repo"}` if this fails.

2. **Resolve hook stage and file list from `scope`:**

   - `staged` →
     ```bash
     FILES="$(git diff --cached --name-only)"
     pre-commit run --hook-stage pre-commit --files $FILES
     ```
   - `all` →
     ```bash
     # Make untracked files visible to `--all-files` (which scans `git ls-files`
     # = tracked + intent-to-add only). Without this, a NEW source/test/fixture
     # file added this session passes Gate 0 locally and only fails in CI, where
     # it is tracked after the commit (e.g. biome reformatting a new JSON fixture,
     # or bandit flagging a new tool script → "files were modified by this hook").
     UNTRACKED="$(git ls-files --others --exclude-standard)"
     [ -n "$UNTRACKED" ] && git add -N -- $UNTRACKED
     pre-commit run --hook-stage manual --all-files
     ```
   - `changed-vs-main` →
     ```bash
     DEFAULT_BRANCH="$(shared/default-branch.sh 2>/dev/null || echo main)"
     FILES="$(git diff "origin/${DEFAULT_BRANCH}" --name-only)"
     pre-commit run --hook-stage pre-push --files $FILES
     ```

3. **Run pre-commit and capture the exit code.** Persist stdout/stderr to a temporary log under `$REPO_ROOT/.pre-commit-trash/run-<ts>.log`.

4. **If exit code == 0:** append a clean-run entry to `specs/<spec_key>/build.jsonl`:
   ```json
   {"ts": "<ISO-8601>", "action": "sensors-clean", "scope": "<scope>", "loops": <n>}
   ```
   Return `{ok: true, loops: <n>, resolved: [], residual: [], jsonl_path: "specs/<spec_key>/build.jsonl"}`.

5. **Otherwise, collect findings.** Gather every SARIF artefact written under `.pre-commit-trash/` plus tool stdout for hooks that don't emit SARIF. Pipe each artefact through the shared `parse-sarif.py` helper (located at `<plugin-root>/shared/parse-sarif.py`; resolve at runtime via `git rev-parse --show-toplevel` + plugin lookup). The shared parser normalises everything to `list[Finding]` with the canonical shape `{tool, rule, path, line, column, message, severity, autofix_available, raw}` — see [`shared/finding-schema.md`](../../shared/finding-schema.md) for the field-by-field contract. This shape is fixed at the emitter and read unchanged by `sensor-fixer` and every downstream fixer.

6. **Dispatch the `sensor-fixer` agent** with the payload:
   ```json
   {"FINDINGS": [...], "REPO_ROOT": "...", "SPEC_KEY": "..."}
   ```
   The agent edits the working tree and returns control.

7. **Re-run pre-commit** with the same scope. Loop steps 3–7 until either:
   - the run is clean, or
   - `loops == MAX_LOOPS` (default `5`).

8. **Append outcome to `specs/<spec_key>/build.jsonl`:**
   ```json
   {"ts": "<ISO-8601>", "action": "sensors-loop-complete", "scope": "<scope>",
    "loops": <n>, "resolved": [...], "residual": [...]}
   ```

## Output

Return a single JSON object:

```json
{
  "ok": true | false,
  "loops": <int>,
  "resolved": [<Finding>, ...],
  "residual": [<Finding>, ...],
  "jsonl_path": "specs/<spec_key>/build.jsonl"
}
```

`ok` is `true` when the final pre-commit run exits 0; otherwise `false` with `residual` populated.

## Hard rules

- **Never** bypass with `git commit --no-verify` or `SKIP=...`.
- **Never** block the caller on residual findings — return them in the payload and let the orchestrator decide.
- **Always** write a JSONL entry, even on failure or early abort, so the build timeline stays auditable.
- **Never** exceed `MAX_LOOPS` (default 5); residual findings after the cap are reported, not retried.
