<!-- markdownlint-disable MD013 MD024 -->
# makato-orchestrate/scripts — Refactor & Migration Plan

> Deep analysis + staged plan for restructuring the 20 production scripts under
> `plugins/makato-orchestrate/scripts/`. Produced from a full read-through, a
> shellcheck baseline, a caller/coupling audit, and a 23-agent parallel
> migration-profile workflow with an adversarial second-opinion pass.
>
> **Decision taken:** hybrid migration. Process-orchestration scripts stay bash;
> pure-logic scripts move to Python (stdlib-only) matching the
> `makato-build/shared/*.py` precedent. Windows is **not** a target (it is not
> supported today either) — the migration win is testability + typing +
> replacing fragile `jq`, not cross-OS reach.

> **Baseline commit:** analysis ran against `715003c`. See §0 for the delta
> introduced by commits landed **after** this plan was drafted — the plan is
> reconciled to current HEAD.

## 0. Post-plan commits to loop.sh (reconciliation)

The working branch changed between drafting and this update: analysis baseline
was `715003c` on `feat/779-…`; current HEAD is `9722084` on
`fix/743-783-loop-session-safety-folderless-demote`. Two commits touched
`loop.sh` (+212 lines) and `loop-smoke-tests.sh` (+126 lines) in that window:

| Commit | Subject | loop.sh impact |
| --- | --- | --- |
| `f9d2c9e` | reap-and-resume killed PO-agent at phase:pr (#732) (#802) | resume path for a PO-agent killed while `phase=pr` |
| `9722084` | loop bg-session guard + `--status` passthrough (#743); demote folderless-Ready to Todo (#783) | **+2 new functions** `_check_session_safety` (ancestry-walk SIGTERM guard, `MAKATO_LOOP_ALLOW_BG_SESSION=1` bypass) and `_auto_seed_demote_to_todo` (folderless-Ready → Todo) |

**Effect on this plan (all still hold, numbers refreshed):**

- `loop.sh` grew **6554 → 6981 LOC**, **78 → 83 functions**. Still a
  process-orchestrator (bash-native, `jq`-heavy) → **stays bash**; §2a unchanged.
- Both new functions **already carry `# ---` comment headers** — no §3 debt added.
- Uncommented-function count went **6 → 7**: the new laggard is
  `_emit_langfuse_trace` (line 5004). §4 uncommented-line list is refreshed
  below.
- Two new `MAKATO_*` hooks to preserve if their carriers are ever touched:
  `MAKATO_LOOP_ALLOW_BG_SESSION` (session guard bypass — CI/headless).
- shellcheck findings are **the same 6**, only line numbers shifted (refreshed
  in §6). No new errors; still 0.
- New `_check_session_safety` (nohup+disown ancestry guard) **reinforces** the
  §9 caveat: any PR touching `loop.sh` must halt the running loop first and be
  launched detached — this is now enforced in-code, not just convention.
- `_auto_seed_demote_to_todo` runs on the live dispatch/seed path → include it
  in the §8.5 boot-path smoke check (`loop.sh run --dry-run --once`).

## 1. Baseline findings

| Metric | Value |
| --- | --- |
| Production scripts | 20 (`*.sh`, excl. test twins) |
| Test twins | 22 (`*-smoke-tests.sh` + `loop-change-dispatch-integration-tests.sh`) |
| shellcheck **errors** (production) | **0** |
| shellcheck warnings / info / style (production) | 4 / 4 / 1 |
| shellcheck error in tests | 1 (`loop-smoke-tests.sh:3927`, SC2328, pre-existing) |
| Monoliths | `loop.sh` 6981 LOC / 83 fns (was 6554/78 at baseline `715003c`); `loop-smoke-tests.sh` 7732 LOC |
| Function-comment coverage (loop.sh) | 76/83 have a preceding `# ---` block |

**Headline:** the production scripts are already clean. This is polish +
strategic migration, not a rescue. No shell *errors* exist to fix — only 9
low-severity findings.

### Coupling facts that gate the plan

- **Tests are move-safe.** 18/20 test files resolve their target via
  `REPO_ROOT="$(git rev-parse --show-toplevel)"` → absolute path. Only 3
  (`archive-spec`, `loop-halt-watch`, `loop-supervisor`) assume co-location via
  `$SCRIPT_DIR/<prod>.sh` and need a one-line path edit if moved.
- **CI hardcodes 8 test paths** in `.github/workflows/validate.yml` (lines
  79, 82, 100, 103, 109, 112, 118, 121). Moving/renaming tests requires editing
  these + `AGENTS.md` File Structure + `README.md`.
- **loop.sh calls candidates as external `exec`**, never by sourcing functions:
  `pr_bin="$script_dir/promote-ready.sh"`, `materialize_sh=...`,
  `validate_sh=...`, each with a *degrade-silently-if-absent* guard and a
  `MAKATO_*_PATH` override. **A Python port needs no structural change to the
  live loop.sh** — only the invocation line `bash X.sh` → `python3 X.py`.
- **~30 `MAKATO_*_OVERRIDE` / `*_TEST_*` env hooks** exist purely so smoke tests
  run offline (no `gh`/network). Every port must preserve these names exactly.
- **Python precedent** (`makato-build/shared/*.py`): stdlib-only, importable
  module + `test_*.py` collected via root `pyproject.toml` `testpaths`. Ports
  must be **both** a CLI (`argparse` + `main()`) *and* importable (logic in
  functions) so pytest tests call functions directly, not subprocesses.

## 2. Classification (per-script)

Adversarial finding that reshaped this: most "migrate" candidates are already a
**thin bash wrapper around a large `python3` heredoc**. So "migration" is mostly
mechanical **extraction** of embedded Python into a tested module — low risk —
not a bash→python rewrite. The adversarial pass also *downgraded* several
candidates: if the bash glue is trivial and the heredoc already carries all
logic, extraction only pays off when it buys testability/typing.

### 2a. Stay bash — process orchestration (refactor only, no migration)

| Script | LOC | Why bash | Action |
| --- | --- | --- | --- |
| `loop.sh` | 6981 | 140+ proc-calls (kill/trap/nohup/worktree/exec claude), 238× jq, bash-native; +2 fns post-plan (§0) | §3 sections + headers + §5 shell fixes |
| `context-handoff.sh` | 503 | 9 proc-calls, `claude --resume`, worktree, resume-script emit | headers + shellcheck |
| `loop-fleet.sh` | 365 | multi-loop process supervision, pidfiles | headers + fix SC2329 |
| `loop-supervisor.sh` | 244 | liveness watchdog, SIGTERM, pidfile | headers |
| `loop-halt-watch.sh` | 106 | macOS notifier, poll+notify daemon, `kill -0` | headers |
| `archive-spec.sh` | 437 | **adversarial STAY-BASH (high)** — zero JSON, runs in GHA with no Claude CLI, purely mechanical `git mv`+issue-close | headers + shellcheck |
| `resolve-append-only-conflict.sh` | 87 | git merge-driver, no logic to gain from Python | headers |
| `should-materialize-spec.sh` | 225 | git-probe heavy (129 bash / 80 py), gate for live loop | headers; extract only if it grows |

### 2b. Migrate to Python — pure-logic, extraction win

Ordered by ascending risk. Each: extract heredoc → `X.py` (module + `main()`),
port the bash smoke twin → `test_X.py` (pytest), swap caller invocation, keep
env-hook names.

| Order | Script | LOC | bash/py split | Tests | Callers to update | Risk |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | `sync-living-specs.sh` | 231 | 6 / 189 | 8 | 1 skill md | lowest — glue is 6 lines |
| 2 | `mark-ac-checkboxes.sh` | 138 | 29 / 91 | 10 | 1 skill md, CI | low |
| 3 | `generate-run-report.sh` | 207 | 52 / 138 | 8 | loop.sh `_emit_run_report`, 1 md | low (loop.sh exec swap) |
| 4 | `generate-progress.sh` | 204 | 26 / 157 | 6 | documentation-agent.md §7.5 | low |
| 5 | `generate-quality-doc.sh` | 310 | 109 / 163 | 6 | documentation-agent.md §7.6, 3 md | low |
| 6 | `generate-layer-report.sh` | 326 | 129 / 167 | 8 | none (unwired) | low |
| 7 | `emit-needs-planning-signal.sh` | 269 | 58 / 183 | 7 | 2 md | low |
| 8 | `emit-reshape-request.sh` | 261 | 56 / 182 | 12 | 1 md; sources workflow-state.sh | medium — schema-validated JSON |
| 9 | `lesson-prune.sh` | 393 | 61 / 287 | 12 | 1 md | low-medium |

### 2c. Deferred / conditional (adversarial STAY-BASH, high confidence)

| Script | LOC | Verdict rationale | Action |
| --- | --- | --- | --- |
| `promote-lessons.sh` | 366 | zero jq; 230 py / 25 bash glue — already Python-in-heredoc; extraction has low marginal value | leave; extract only alongside a behavior change |
| `promote-ready.sh` | 797 | dependency-graph engine already a 228-line Python heredoc (lines 197–419); "only warranted if the engine grows" | **optional** extract engine → `promote-ready-engine.py` + pytest, keep bash glue; do last, own PR |
| `validate-plan-body.sh` | 139 | 0 embedded py, 130 bash — pure grep/regex guard on the live dispatch path | leave bash (or port only if bundled with a rule change) |

## 3. Deliverable 1 — comment convention

**Target shape** (matches the request: short headers, prose only for the hard
parts). One block immediately above every function, uniform structure:

```bash
# <one-line purpose — imperative, what it does, not how>
# Args:    $1 <name>, $2 <name>   (omit line if none)
# Reads:   <env vars / files it consumes>   (omit if none)
# Outputs: <stdout / files written / exit codes>   (omit if none)
# <extra prose ONLY for non-obvious algorithm/edge-case — else drop>
```

Rules:

- Keep the existing `# ---` box divider **only** for major *section* breaks
  inside `loop.sh` (see §4), not per-function — it is visual noise on small fns.
- The 7 uncommented `loop.sh` functions get a header. At current HEAD
  (`9722084`) these are: `_project_item_id_for_issue` (854),
  `_gh_project_item_list` (941), `_reset_poll_skip_count` (1187),
  `_reconcile_orphaned_in_progress` (1790), `_derive_key_for_issue` (2950),
  `_auto_seed_block_full` (3905), `_emit_langfuse_trace` (5004). (Line numbers
  drift with each loop.sh commit — re-derive at implementation time.)
- Long inline explanation blocks *inside* function bodies stay only where they
  document a genuine gotcha (rate-budget math, CAS race, poison-pill). Elsewhere
  collapse to one line.
- Python ports use a module docstring + per-function docstrings (same 4 fields:
  purpose / Args / Reads / Returns) — matches `skill_routing.py`.

## 4. Deliverable 1b — loop.sh sectioning (no split)

`loop.sh` stays one file (live 12h+ system, bash-native, boot-path risk). Add
explicit navigable section banners grouping the 78 functions:

```text
CONFIG & CONSTANTS · TIME/SLEEP HELPERS · PROJECT-CONFIG READ ·
GRAPHQL/BOARD POLL · RATE BUDGET · STATUS FILE I/O · IN-FLIGHT FILTER ·
KEY DERIVATION · AUTO-SEED GATE · RECONCILERS (orphaned/stale) ·
WORKTREE + SPECS REAPER · DISPATCH · RUN LOOP · SUBCOMMAND ROUTER
```

A future full split into sourced modules is tracked as a **separate issue**, not
done here.

## 5. Deliverable 2 — separate test files

**Target:** `plugins/makato-orchestrate/scripts/tests/` (keeps `git rev-parse`
paths valid for 18/20; closest to code; pytest `testpaths` picks up
`plugins/**/tests/` automatically for the Python ports).

Steps:

1. `git mv` each `*-smoke-tests.sh` / `*-integration-tests.sh` into `scripts/tests/`.
2. Fix the 3 co-located tests (`archive-spec`, `loop-halt-watch`,
   `loop-supervisor`): `SCRIPT_DIR/../<prod>.sh` (one line each).
3. Update the 8 hardcoded paths in `.github/workflows/validate.yml`.
4. Update `AGENTS.md` File Structure block + the "twin" prose, and `README.md`
   test rows.
5. Python ports land their `test_*.py` in the same `tests/` dir (pytest) — the
   `.sh` twin is deleted only when its `.py` replacement is green in CI.

> Note: AGENTS.md currently documents the co-located `*-smoke-tests.sh` **twin**
> convention as intentional. This plan changes that convention → the AGENTS.md
> update is mandatory, not optional.

## 6. Deliverable 3 — shell problems to fix

All low-severity; exact findings:

| File:line | Code | Fix |
| --- | --- | --- |
| `emit-reshape-request.sh:48` | SC2034 `SCRIPT_DIR` unused | remove or `# shellcheck disable` w/ reason |
| `emit-reshape-request.sh:59` | SC2034 `BUILD_LOG` unused | same (this file migrates → resolve in port) |
| `loop.sh:450` | SC2034 `STALL_THRESHOLD_SECS` unused | verify vs watchdog; remove if dead |
| `loop.sh:745,846` | SC2016 expansion in single quotes | intended (jq programs) → `# shellcheck disable=SC2016` |
| `loop.sh:4557` | SC2143 `[ -n "$(grep)" ]` | → `grep -q` |
| `loop.sh:4852` | SC2155 declare+assign masks rc | split `local x; x="$(...)"` |
| `loop.sh:5334` | SC2086 unquoted expansion | quote it |
| `loop-fleet.sh:148` | SC2329 function never invoked | confirm dead → remove, or wire |
| `loop-smoke-tests.sh:4248` | SC2328 redirect steals cmd-sub output | fix redirection (pre-existing test bug) |

Add a repo `.shellcheckrc` (or per-file directives) so intended `jq`-program
single-quotes (SC2016) don't reappear as noise.

## 7. Deliverable 4 — Python port pattern (reference)

Each `X.py`:

```python
"""<purpose>. Ported from scripts/X.sh (#<issue>). stdlib-only."""
from __future__ import annotations
import argparse, json, os, sys
from pathlib import Path

def load_...(...): ...        # pure functions — unit-testable
def build_report(...): ...    # no I/O in the core where avoidable

def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser()
    # mirror the .sh flags EXACTLY (same names, same exit codes 0/64/1)
    ...
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
```

- **stdlib-only** (no PyYAML unless already needed) — matches `skill_routing.py`.
- Preserve exit codes (`64`=usage/EX_USAGE, `1`=fatal I/O, `0`=success incl.
  tolerated skips) — CI/callers check them.
- Preserve every `MAKATO_*` env hook name via `os.environ.get`.
- Replace `gh` shell-outs with `subprocess.run(["gh", ...])` — cannot be
  eliminated (live data), but wrap behind the same override hook the `.sh` used.
- `test_X.py`: port each `T1..TN` scenario to a pytest function calling the
  module's functions directly (fast, no subprocess), plus one end-to-end
  `main()` invocation per exit-code path.

## 8. Deliverable 5 — verification gate (definition of done)

1. `shellcheck` clean (0 errors, 0 warnings) on every remaining `.sh`; intended
   findings carry a justified `# shellcheck disable`.
2. Every ported script: `python3 -m pytest plugins/makato-orchestrate/scripts/tests/ -v` green; scenario count ≥ original bash `T#` count.
3. **Logic-equivalence check** per port: run old `.sh` and new `.py` against the
   same fixture set, diff stdout + written files + exit code byte-for-byte
   before deleting the `.sh`.
4. Bash smoke suites still green for un-migrated scripts (run all twins).
5. `loop.sh` boot path unaffected: `loop.sh run --dry-run --once` and
   `loop-smoke-tests.sh` pass after section/comment/shellcheck edits.
6. Docs updated: `AGENTS.md`, `README.md`, `CHANGELOG.md` per PR.

## 9. Suggested PR sequence (small, reversible, one concern each)

| PR | Scope | Risk |
| --- | --- | --- |
| A | Shell fixes (§6) across all bash + `.shellcheckrc` | very low |
| B | Comment convention + loop.sh sectioning (§3, §4) — no logic change | low |
| C | `git mv` tests → `scripts/tests/` + fix 8 CI paths + 3 co-located + docs (§5) | low (CI-visible) |
| D | Python ports #1–#3 (sync-living-specs, mark-ac, generate-run-report) + pytest | low |
| E | Python ports #4–#7 (generate-progress/quality-doc/layer-report, emit-nps) | low |
| F | Python ports #8–#9 (emit-reshape, lesson-prune) | medium |
| G | *(optional)* extract `promote-ready-engine.py` + pytest | medium |

**Do not** batch these — loop.sh is a live autonomous system; each PR must be
independently verifiable and revertible. Halt the running loop (`touch
~/.claude/HALT`) before any PR that touches `loop.sh` (B, and the exec-swap in D).

## 10. Explicitly out of scope

- Splitting `loop.sh` into sourced modules (separate tracked issue).
- Migrating `loop.sh` / process orchestrators to Python (no OS-portability win;
  high risk on a live system).
- Windows support (not a current target; not created by this migration).
- Porting `promote-lessons` / `validate-plan-body` (adversarial: no marginal
  value without a bundled behavior change).
