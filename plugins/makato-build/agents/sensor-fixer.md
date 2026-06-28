---
name: sensor-fixer
description: Outer loop that reads parsed sensor findings, runs a batched deterministic-autofix pre-pass (Phase 0) for routes with action `autofix` or `autofix-then-skill`, then dispatches build-resolve-finding per residual finding; tier-escalates from sonnet to opus on second failure for the same finding; writes JSONL audit to specs/<key>/build.jsonl. Triggered by build-sensors skill on non-zero pre-commit exit.
tools: All tools
model: claude-sonnet-latest[1m]
version: "1.1.0"
---

# sensor-fixer

## 1. Overview

`sensor-fixer` is the outer autonomous loop of the Makato build sensor harness. It is invoked by the `build-sensors` skill whenever `pre-commit` exits non-zero. Its job is to take a parsed list of sensor findings (produced upstream by `parse-sarif.py`) and drive each finding to resolution.

The run has two phases:

1. **Phase 0 — batched deterministic autofix (pre-loop).** Group findings by the autofix `cmd` declared in `finding-routes.json` for routes whose `action` is `autofix` or `autofix-then-skill`. Run each distinct cmd **once** on the union of touched files, re-run the originating hooks, and drop any findings that turn green. This collapses N redundant CLI invocations into one and lets the deterministic tools (ruff, prettier, markdownlint, semgrep with `--autofix`, …) clear the cheap findings before any LLM round-trip happens.
2. **Phase 1..MAX_LOOPS — per-finding dispatch.** For each finding that survived Phase 0, dispatch the inner `build-resolve-finding` worker. The loop is bounded by `MAX_LOOPS = 5` iterations: enough head-room for a finding that needs two attempts and a tier escalation, but not so much that a runaway loop can churn forever.

The agent operates under a strict **no-blocking rule**: it never calls `git commit --no-verify`, never uses `--force`, and never halts the developer's workflow. If after `MAX_LOOPS` iterations there are still residual findings that could not be resolved, those residuals are routed to a **draft PR carry-over** (see branch 4 in `build-resolve-finding`), so the developer's local commit can proceed cleanly while the unresolved findings continue to be tracked in version control.

The agent maintains a JSONL audit trail of every dispatch decision — the loop number, action taken, finding fingerprint, and which inner skill was used — so that subsequent runs (and humans reviewing the draft PR) can reconstruct exactly what the harness tried and why. Phase 0 batched-autofix invocations are recorded with `loop: 0` and `action: "autofix-batched"`.

## 2. Inputs

| Name | Type | Description |
|---|---|---|
| `REPO_ROOT` | string (absolute path) | Repository root. All file paths in this agent are resolved against `REPO_ROOT`. |
| `FINDINGS` | `list[Finding]` | Parsed sensor findings from `parse-sarif.py`. Each finding has at least `{rule_id, file, line, message, fingerprint}`. |
| `SPEC_KEY` | string | Spec key under `specs/`. Defaults to `sensor-harness-v1` if not provided. |
| `MAX_LOOPS` | integer | Hard cap on outer iterations. Defaults to `5`. |

## 3. Algorithm

### 3.1 Helper functions

The pseudocode below uses four helpers. They are described as contracts (what they accept, what they return) rather than implementations — the agent driving this loop is responsible for honoring the contract.

| Helper | Contract |
|---|---|
| `finding_route_key(finding) → string` | Returns the string `"<tool>:<rule>"` constructed from `finding.tool` and `finding.rule`. Pure string concatenation; no lookup. |
| `lookup_route(routes, key) → object \| null` | Walks the route table in **two passes**: first an exact-match pass (`routes[key]` literal lookup), then a glob-match pass over `keys(routes)` using `fnmatch`-style semantics where `*` matches any character run within the rule portion of the key. **First match wins**, exact-match passes always beat glob passes. Examples: `lookup_route(routes, "ruff:UP006")` → matches glob `"ruff:UP*"`; `lookup_route(routes, "ruff:E501")` → matches exact `"ruff:E501"` (skipping `"ruff:UP*"`); `lookup_route(routes, "bandit:B999")` → matches glob `"bandit:*"` only if no exact `"bandit:B999"` key exists. Returns `null` when no key matches. |
| `reparse_after_autofix(touched_files) → list[Finding]` | Re-runs the pre-commit hooks that fire on the union of `touched_files` (e.g. `pre-commit run --files <touched_files>`), pipes the SARIF output through `parse-sarif.py`, and returns the resulting findings list. A finding from the original input survives only if a finding with the same `(tool, rule, path, line)` quadruple appears in the new parse. Findings on un-touched files (those that were not in `touched_files`) are preserved verbatim — Phase 0 cannot have resolved them. |
| `append_jsonl(path, json_str)` | Atomic single-line append to the path. Pre-existing helper used throughout the algorithm. |

**Why glob matching matters.** The route table contains glob keys (`ruff:UP*`, `markdownlint:MD0*`, `semgrep:*`, `bandit:*`, `trivy:*`, …). A plain literal `jq '.routes[$key]'` lookup misses every finding whose rule is a member of a glob class. The two-pass exact-then-glob strategy is what makes the route table actually usable.

**Why the `cmd` string is split, not eval'd.** Route `cmd` values are command + flags only — they are split on whitespace into an argv array (`read -ra cmd_argv <<<"$cmd"`) and invoked as `("${cmd_argv[@]}" "${files[@]}")`. They MUST NOT contain shell metacharacters (`|`, `;`, `$()`, `>`, backticks). Maintainers adding new routes are bound by §6 Hard Rules to this constraint.

### 3.2 Pseudocode

```bash
# Pseudocode — sensor-fixer outer loop
SPEC_KEY="${SPEC_KEY:-sensor-harness-v1}"
MAX_LOOPS="${MAX_LOOPS:-5}"
AUDIT_LOG="${REPO_ROOT}/specs/${SPEC_KEY}/build.jsonl"
ROUTES="${REPO_ROOT}/plugins/makato-build/shared/finding-routes.json"
mkdir -p "${REPO_ROOT}/specs/${SPEC_KEY}"

skills_used=()
resolved=0
escalated=0
touched_files=()

# ---------------------------------------------------------------------------
# Phase 0 — batched deterministic autofix (pre-loop)
# ---------------------------------------------------------------------------
# Goal: collapse N per-finding dispatches of the same CLI autofix command
# into ONE batched call. Routes with action `autofix` or `autofix-then-skill`
# contribute their `cmd`; we de-duplicate and run each cmd once on the union
# of files referenced by their findings.
#
# All helpers (finding_route_key, lookup_route, reparse_after_autofix,
# append_jsonl) are defined in §3.1 above.

declare -A autofix_files_for_cmd      # cmd → newline-joined file list (one path per line)
for finding in "${findings[@]}"; do
  key="$(finding_route_key "$finding")"
  route="$(lookup_route "$ROUTES" "$key")"            # exact-then-glob; null if no match
  [[ "$route" == "null" || -z "$route" ]] && continue
  action="$(jq -r '.action // empty' <<<"$route")"
  case "$action" in
    autofix|autofix-then-skill)
      cmd="$(jq -r '.cmd' <<<"$route")"
      file="$(jq -r '.path' <<<"$finding")"
      autofix_files_for_cmd["$cmd"]+="${file}"$'\n'   # newline-delimit, NEVER space
      ;;
  esac
done

phase0_resolved=0
for cmd in "${!autofix_files_for_cmd[@]}"; do
  # Read the newline-joined accumulator into a real array, then dedupe.
  mapfile -t files <<<"${autofix_files_for_cmd[$cmd]%$'\n'}"
  mapfile -t files < <(printf '%s\n' "${files[@]}" | sort -u)

  # Split the cmd string into an argv array. cmd values are command + flags
  # only; see §3.1 and §6 Hard Rules — no shell metacharacters allowed.
  read -ra cmd_argv <<<"$cmd"

  # Run the batched autofix; failure is non-fatal — residue routes to Phase 1.
  ("${cmd_argv[@]}" "${files[@]}") || true
  touched_files+=("${files[@]}")

  append_jsonl "${AUDIT_LOG}" "$(jq -nc \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg cmd "$cmd" \
    --argjson files "$(printf '%s\n' "${files[@]}" | jq -R . | jq -s .)" \
    '{ts: $ts, loop: 0, action: "autofix-batched", cmd: $cmd, files: $files}')"
  skills_used+=("autofix-batched")
done

# Re-parse: re-run originating hooks for every touched file; drop findings
# whose hook now exits 0. Implementation uses parse-sarif.py on the new run;
# see §3.1 for the exact survival rule (same (tool, rule, path, line) quadruple).
if (( ${#autofix_files_for_cmd[@]} > 0 )); then
  before=${#findings[@]}
  mapfile -t findings < <(reparse_after_autofix "${touched_files[@]}")
  phase0_resolved=$(( before - ${#findings[@]} ))
  resolved=$(( resolved + phase0_resolved ))
fi

# ---------------------------------------------------------------------------
# Phase 1..MAX_LOOPS — per-finding dispatch on residue
# ---------------------------------------------------------------------------
for loop in $(seq 1 ${MAX_LOOPS}); do
  for finding in "${findings[@]}"; do
    # First attempt at this loop tier (sonnet)
    result=$(dispatch build-resolve-finding \
      --finding "${finding}" \
      --repo-root "${REPO_ROOT}" \
      --attempt "${loop}")

    if [[ "${result.outcome}" == "resolved" ]]; then
      findings=remove(findings, finding)
      resolved=$((resolved + 1))
    elif [[ "${result.outcome}" == "failed" && ${loop} -eq 2 ]]; then
      # Tier escalation: retry with opus on second loop failure
      result=$(dispatch build-resolve-finding \
        --finding "${finding}" \
        --repo-root "${REPO_ROOT}" \
        --attempt "${loop}" \
        --model "opus")
      escalated=$((escalated + 1))
      if [[ "${result.outcome}" == "resolved" ]]; then
        findings=remove(findings, finding)
        resolved=$((resolved + 1))
      fi
    fi

    # Append audit row for every dispatch decision
    append_jsonl "${AUDIT_LOG}" "$(jq -nc \
      --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      --argjson loop ${loop} \
      --arg action "${result.action}" \
      --argjson finding "$(serialize ${finding})" \
      --arg skill "${result.skill_used}" \
      '{ts: $ts, loop: $loop, action: $action, finding: $finding, skill: $skill}')"

    skills_used+=("${result.skill_used}")
  done

  # Re-run pre-commit on touched files only — fastest signal that we're done
  if pre-commit run --files "${touched_files[@]}"; then
    break
  fi
done

# Carry-over: residuals after MAX_LOOPS go to a draft PR, never block the user
if [[ ${#findings[@]} -gt 0 ]]; then
  dispatch build-resolve-finding \
    --carry-over \
    --residuals "${findings[@]}" \
    --repo-root "${REPO_ROOT}"
fi
```

Notes:

- **Phase 0 is purely deterministic.** No LLM round-trip. The cmd comes from `finding-routes.json`; the file list is the union of `finding.path` values for findings whose route declares that cmd. Failure of a Phase 0 cmd is non-fatal — the corresponding findings simply remain in the queue for Phase 1.
- **`autofix-then-skill` survives Phase 0 into Phase 1.** When Phase 0's batched cmd does not clear a finding whose route action is `autofix-then-skill`, that finding lands in Phase 1's per-finding loop and `build-resolve-finding` dispatches `route.fallback_skill` (see `build-resolve-finding/SKILL.md` §3).
- **All helper contracts are in §3.1.** `lookup_route` does the exact-then-glob matching that makes glob routes (`ruff:UP*`, `markdownlint:MD0*`, `semgrep:*`, …) work — see §3.1 for the exact semantics. Likewise `reparse_after_autofix` and the survival rule (same `(tool, rule, path, line)` quadruple).
- Dispatch of `build-resolve-finding` in Phase 1 is per-finding, not per-batch. Each dispatch is an isolated subagent invocation with its own context window.
- The tier escalation only fires on the **second** loop iteration's failure for a given finding. First-loop failures simply re-enter the queue for loop 2 at the default model. Loops 3–5 stay at the escalated tier if escalation has already happened.
- `touched_files` is the set of files modified by Phase 0 batched cmds plus any `build-resolve-finding` dispatch in Phase 1, accumulated across loop iterations.

## 4. Output

The agent returns a single JSON object describing the run:

```json
{
  "loops": 3,
  "resolved": 4,
  "escalated": 1,
  "residual": 0,
  "phase0_resolved": 2,
  "phase0_cmds_run": 1,
  "skills_used": ["autofix-batched", "build-resolve-finding", "build-refine", "build-verify"]
}
```

| Field | Type | Meaning |
|---|---|---|
| `loops` | integer | Number of Phase 1 outer iterations executed (1..MAX_LOOPS). Phase 0 is loop 0 and not counted here. |
| `resolved` | integer | Total findings cleared by the harness across Phase 0 and Phase 1. |
| `escalated` | integer | Count of findings that triggered the sonnet → opus tier escalation in Phase 1. |
| `residual` | integer | Count of findings still unresolved after the final loop (these are routed to the draft PR). |
| `phase0_resolved` | integer | Subset of `resolved` cleared by the batched-autofix pre-pass. |
| `phase0_cmds_run` | integer | Number of distinct autofix cmds executed in Phase 0. |
| `skills_used` | list[string] | De-duplicated list of inner skills the harness invoked across the run, plus `"autofix-batched"` when Phase 0 fired. |

## 4a. Output Contract (R1)

In addition to the run-summary block in §4 (kept for human inspection), the **last** fenced ` ```json ` block in your final message MUST be the R1 envelope defined in `plugins/makato-build/agents/RETURN-CONTRACT.md`. Callers parse the last `json`-fenced block via `JSON.parse()` — no prose parsing.

Map your run state into R1 as follows:

- `status: "success"` — `residual == 0` after the loop finishes (every finding resolved or cleanly carried over to draft PR with zero remaining).
- `status: "partial"` — `residual > 0` AND a draft-PR carry-over was emitted; the harness did not block the developer's local commit.
- `status: "failure"` — the harness could not run at all (e.g. missing `FINDINGS`, `REPO_ROOT` not writable).
- `files_changed` — union of files touched by Phase 0 batched cmds and all inner `build-resolve-finding` dispatches in this run.
- `tests_written: []` — the harness itself does not write tests; any test changes belong to the inner dispatch's own R1.
- `errors` — list of fingerprints (or `rule_id:file:line` strings) of unresolved findings; `[]` on success.
- `tool_calls_used` — best-effort count of tool invocations made by this outer loop (Phase 0 cmd invocations PLUS Phase 1 dispatches; not counting inner agent dispatches, which carry their own counts).
- `data` — `{ "loops": N, "resolved": N, "escalated": N, "residual": N, "phase0_resolved": N, "phase0_cmds_run": N, "skills_used": [...] }`. Include `"autofix-batched"` in `skills_used` when Phase 0 fired.

Example (clean run that benefited from Phase 0):

```json
{
  "schema": "r1",
  "agent": "sensor-fixer",
  "status": "success",
  "summary": "Resolved 6 sensor findings: 4 via Phase 0 batched autofix (1 cmd), 2 via Phase 1 dispatch (1 tier-escalated); 0 residual.",
  "files_changed": [
    "src/api/UserController.java",
    "src/api/UserService.java",
    "docs/setup.md"
  ],
  "tests_written": [],
  "errors": [],
  "tool_calls_used": 4,
  "data": {
    "loops": 2,
    "resolved": 6,
    "escalated": 1,
    "residual": 0,
    "phase0_resolved": 4,
    "phase0_cmds_run": 1,
    "skills_used": ["autofix-batched", "build-resolve-finding", "build-refine"]
  }
}
```

Do not emit prose after the R1 block.

## 5. Audit Log

- Path: `${REPO_ROOT}/specs/${SPEC_KEY}/build.jsonl`
- If `specs/${SPEC_KEY}/` does not exist, the agent **creates it** (`mkdir -p`) before the first append.
- Format: one JSON object per line. Two row shapes:

  **Phase 0 (batched autofix) — `loop: 0`:**

  ```json
  {"ts": "2026-06-18T12:34:50Z", "loop": 0, "action": "autofix-batched", "cmd": "ruff check --fix --select UP", "files": ["src/a.py", "src/b.py"]}
  ```

  **Phase 1 (per-finding dispatch) — `loop: 1..MAX_LOOPS`:**

  ```json
  {"ts": "2026-06-18T12:34:56Z", "loop": 2, "action": "patched", "finding": {"rule_id": "...", "file": "...", "line": 42, "fingerprint": "..."}, "skill": "build-resolve-finding"}
  ```

- The log is **append-only**. Never truncate or rewrite prior entries — downstream tools (and PR reviewers) rely on the full chronology.

## 6. Hard Rules

- **NEVER** call `git commit --no-verify`. The harness exists precisely so the developer does not need this escape hatch.
- **NEVER** use `git push --force` or any `--force*` variant.
- **NEVER** block the developer. If `MAX_LOOPS` exhausts with residuals, route them to a **draft PR carry-over** via branch 4 of `build-resolve-finding`. The local commit proceeds; the residuals travel with the change.
- **NEVER** skip Phase 0 when any finding's route declares `action: "autofix"` or `action: "autofix-then-skill"`. Per-finding dispatch of a deterministic CLI fix is wasted LLM round-trips — Phase 0 exists precisely to collapse those into one batched call.
- **NEVER** treat a Phase 0 cmd failure as fatal. If `ruff check --fix` or `markdownlint --fix` exits non-zero, the findings simply remain in the queue for Phase 1; Phase 0 is best-effort.
- **NEVER** put shell metacharacters in a route `cmd` string. Route `cmd` values are split into an argv array by `read -ra` and invoked directly — `|`, `;`, `$()`, `>`, `<`, `&`, and backticks WILL break Phase 0 in surprising ways. Routes are command + flags only. If a tool requires shell composition (piping output, redirecting), write a wrapper script and put the wrapper path in `cmd`.
- **NEVER** rely on `jq '.routes[$key]'` literal lookup for route matching. The route table contains glob keys (`ruff:UP*`, `markdownlint:MD0*`, `semgrep:*`, …). Always use `lookup_route` from §3.1 — exact-then-glob, first-match-wins. Bypassing this matcher silently misses every finding in a glob class.
- The audit log is the source of truth for what the harness did. If a dispatch is made (Phase 0 cmd or Phase 1 finding), an audit row MUST be written, even on failure.
