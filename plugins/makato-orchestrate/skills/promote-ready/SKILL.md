---
name: promote-ready
description: >-
  Dependency-aware Ready promotion for the autonomous loop (#268). Reads
  the cross-issue dependency graph from `specs/<slug>/created-issues.json`
  (`issues[].blocked_by[]`; fallback `stories.json`
  `stories[].dependencies.blockedBy` via `sequence → githubIssue`), reads
  each issue's live board Status via `gh project item-list`, computes the
  set of *right-now-unblocked* issues (every `blocked_by` predecessor is
  `Done`), arranges them into topological waves, and — after interactive
  approval — promotes them to `Status=Ready` idempotently and forward-only.
  Closes the "FIFO only in v1" gap left by `loop` (#33): nothing else in
  makato reads the dependency graph back at promotion time. Refuses to
  recommend two issues that share one `specs/` folder at once (shared
  `plan.md` collision, #173). `--dry-run` / `plan` prints the
  recommendation without touching the board. `--json` emits machine-readable
  plan output consumed by `loop`'s `_dependency_order` helper.
version: "1.3.0"
argument-hint: "[SLUG] [--dry-run] [--yes] [--json]"
allowed-tools: Bash(plugins/makato-orchestrate/scripts/promote-ready.sh *) Bash(gh project *) Bash(jq *) Bash(python3 *) Read
metadata:
  authors: [makato-orchestrate]
  last_updated: "2026-08-07"
---

## When to Use

Run from the operator's terminal (repo root as cwd) when a spec has more than a
couple of issues with **cross-issue dependencies** and you want the board's
`Ready` column to reflect *what is actually unblocked right now* — not the whole
backlog. The autonomous `loop` (see the `loop` skill) dispatches board `Ready`
items strictly **FIFO and single-threaded**; it does not read the dependency
graph and cannot tell an unblocked issue from one whose upstream is still open.
`loop`'s own pre-poll bridge (`_promote_labelled_ready`, #231) promotes on a
*label*, with no dependency awareness at all.

This skill is the missing dependency-aware layer. Use it:

- Before starting a `loop` run over a decomposed epic, to seed only the
  first wave onto `Ready`.
- After a PR merges, to promote the next wave now that its blocker is
  `Done`.
- Any time you want a read-only picture (`plan` / `--dry-run`) of which
  issues are unblocked, which are deferred by a `plan.md` collision, and
  which are still blocked and by what.

The `loop` skill calls `promote-ready.sh plan --json` at each poll tick
to determine wave-ordered dispatch order (see `loop/SKILL.md` §
*Wave-ordered dispatch*). This is a **read-only** call — it never mutates
the board. The board-mutation path (`run --yes`) is only invoked when
`MAKATO_LOOP_ALLOW_TODO=1` or `--promote-unblocked` is active in `loop`.

## Prerequisites

- Run all invocations from the **repository root** (`git rev-parse --show-toplevel`).
  The scripts are called with relative paths (`plugins/makato-orchestrate/scripts/…`);
  a different cwd silently produces "No such file" errors.
- `.claude/config.json` → `github_project` is populated (owner, number,
  host, `project_node_id`, `fields.status.{id, options.ready, options.done}`).
  Run `/makato-plan:issue-to-project --init` once per repo first. Same
  config contract as `loop`.
- `gh` authenticated with the `project` OAuth scope.
- At least one `specs/<slug>/created-issues.json` (emitted by `to-issues`)
  or `specs/<slug>/stories.json` (emitted by `decompose`) carrying the
  dependency edges.

## Invocation

```bash
# Recommendation only across every spec folder (no board mutation)
plugins/makato-orchestrate/scripts/promote-ready.sh plan

# Recommendation for one spec (accepts exact folder, KEY-slug, or bare slug)
plugins/makato-orchestrate/scripts/promote-ready.sh plan checkout-redesign

# Machine-readable JSON plan (consumed by loop's _dependency_order helper)
plugins/makato-orchestrate/scripts/promote-ready.sh plan --json checkout-redesign

# Promote the unblocked wave after interactive approval
plugins/makato-orchestrate/scripts/promote-ready.sh run checkout-redesign

# Non-interactive promote (CI / scripted operator)
plugins/makato-orchestrate/scripts/promote-ready.sh run checkout-redesign --yes
```

| Command | Purpose |
|---------|---------|
| `plan [SLUG]` | Print the recommendation; never mutates the board (alias for `run --dry-run`). |
| `plan [SLUG] --json` | Print raw `_compute_plan` JSON to stdout; exits 0. Consumed by `loop`'s `_dependency_order` helper for wave-ordered dispatch. Consumers may extract `.ready[].issue`, `.waves`, `.blocked`, `.skipped`, `.deferred_collision`. |
| `run [SLUG] [--dry-run] [--yes] [--json]` | Compute unblocked issues and promote them to `Ready`. Interactive approval unless `--yes`. `--dry-run` prints only. `--json` prints raw plan JSON and exits immediately (no board mutation). |

Without `SLUG`, every `specs/*/` folder with a `created-issues.json`
(fallback `stories.json`) is loaded and the graphs are analyzed together.

## Process

1. **Load the dependency graph.** For the target slug (or every spec
   folder), read `created-issues.json` → `issues[].blocked_by[]` (real
   issue numbers). Fallback: `stories.json` →
   `stories[].dependencies.blockedBy`, which holds **story sequences** —
   translated to issue numbers via `stories[].sequence → githubIssue`.
   Stories with no `githubIssue` (not yet created) are warned and skipped.
2. **Read board Status.** One `gh project item-list --format json` gives
   each issue's current Status (`Done` / `In progress` / `Ready` / `Todo` /
   `Blocked`) and its project item id. `GH_HOST=<host>` prefix (never
   `--hostname`) — `gh project` has no host flag.
3. **Compute unblocked issues.** An issue is promotable now iff its board
   Status ∈ {`Todo`, `Blocked`, off-board} **and every** `blocked_by`
   predecessor is `Done`. Off-board or unknown predecessors are
   conservatively treated as *not Done* (they still block). Issues are
   arranged into topological waves (level = longest `blocked_by` chain).
4. **Recommend.** Print the waves, the promote-now set, the collision
   deferrals, the still-blocked set (with blocking `#`s), and the
   already-progressing skips.
5. **Promote (after approval).** For each recommended issue, resolve its
   board item (add it if absent) and `gh project item-edit` it to
   `Status=Ready`. Idempotent, forward-only, warn-not-fail.

   After each successful promotion, clean up the dependency labels:

   a. **Remove `blocked by` from the promoted issue** — the blocking
      relationship is resolved at promotion time:
      ```bash
      GH_HOST=github.com gh issue edit "$ISSUE_NUMBER" \
        --repo "$TARGET_REPO" \
        --remove-label "blocked by" 2>/dev/null || true
      ```

   b. **Remove `blocking` from upstream issues whose all dependents are now
      promoted.** After the full promotion batch completes, compute the
      reverse dependency graph: for every upstream issue `U`, collect the
      set of all downstream issues that list `U` in their `blocked_by`.
      If every member of that set has now been promoted to `Ready` (or is
      already `In Progress` / `In Review` / `Done`), remove `blocking`
      from `U`:
      ```bash
      GH_HOST=github.com gh issue edit "$UPSTREAM_NUMBER" \
        --repo "$TARGET_REPO" \
        --remove-label "blocking" 2>/dev/null || true
      ```
      This check runs once per upstream issue at the end of the batch, not
      per individual promotion — it avoids a redundant API call when
      multiple dependents of the same upstream issue are promoted in the
      same wave. Best-effort (`|| true`); a label-remove failure never
      aborts or rolls back the board promotion.
6. `--dry-run` / `plan` stops after step 4.

## Never Do

**1. Never use `--hostname` with `gh project`.** `gh project item-list` has no
`--hostname` flag — it silently ignores it and queries the default host instead,
meaning all reads come from the wrong org/instance. Use `GH_HOST=<host>` as an
environment prefix on every `gh project` call.

**2. Never treat an off-board or unknown predecessor as Done.** If a
`blocked_by` issue has no entry in the board snapshot (not yet filed, not
on the board), its actual status is unknown. Treating it as Done would
allow dependent issues to promote past an incomplete upstream, corrupting
wave ordering and causing acceptance-criteria failures at PR time.

**3. Never promote two issues from the same `specs/<slug>/` folder in one
pass.** Both issues share a single `plan.md` in the main checkout (`#173`
isolated `workflow-state-<n>.json` but not `plan.md`). Promoting two
same-folder issues means two concurrent `loop` worktrees will both write
`plan.md`, clobbering each other. Keep the lowest issue number and defer
the rest until the first one's PR merges.

**4. Never roll a board card backward (Ready → Todo, or Done → Ready).** The
board Status is the cross-machine shared lock between `promote-ready`,
`loop`, and `sync-lifecycle`. Rolling backward during a concurrent `loop`
claim resets an item that is already being worked, causing a double-dispatch
race. The forward-only check must run both at plan time and as a TOCTOU
re-poll compare-and-set immediately before each `item-edit`.

**5. Never silently drop an unfiled `stories.json` blocker.** A `blockedBy`
sequence that has no corresponding `githubIssue` is an unfiled upstream. If
it is dropped instead of treated as blocking, the dependent issue gets
promoted to `Ready` with an unresolved dependency, and the PR that lands
will merge against an unverified upstream assumption. Always warn and keep
the dependent blocked until the upstream story is filed.

**6. Never recommend or promote without being in the repo root.** The script
resolves paths like `plugins/makato-orchestrate/scripts/promote-ready.sh`
relative to cwd. Running from a subdirectory produces silent "No such file
or directory" failures — the script exits 127 rather than reporting a graph
or touching the board, but no error is surfaced to the caller.

## Parallel-safety constraints (issue #268)

- **Shared `plan.md` collision.** Issues sharing one `specs/<KEY>-<slug>/`
  folder share a single `plan.md` in the main checkout — `#173` isolated
  `workflow-state-<n>.json` but **not** `plan.md`, so two parallel runs
  from the same folder would clobber it. This skill **never recommends two
  issues from the same folder in one pass**: among unblocked candidates
  sharing a folder it keeps the lowest issue number and **defers** the
  rest (shown under *Deferred — plan.md collision*). Promote the deferred
  sibling on a later pass, after the first one's PR merges.
- **Board Status is the shared lock (#259).** This skill writes the same
  `Status` field `loop` reads and claims (`Ready → In progress`). Every
  write is **idempotent** and **forward-only**: it promotes ONLY from
  {`Todo`, `Blocked`, off-board}, never rolling a card back from `Ready` /
  `In progress` / `In review` / `Done`. The forward-only check runs
  **twice** — once against the board snapshot at plan time, and again as a
  **TOCTOU re-poll compare-and-set** immediately before each `item-edit`:
  if a concurrent `loop` claim (or `sync-lifecycle`) moved the card off
  `Todo`/`Blocked` since the snapshot, the promotion is skipped rather than
  rolling the card backward. So it can never race
  `issue-to-project sync-lifecycle` or the loop claim.
- **Wave-by-wave is the operating model.** `loop` is FIFO single-threaded
  per worktree, so promoting more issues only lengthens its queue (safe),
  but queue *order* is not honored. Promote the next wave only after the
  previous wave's PR merges (flipping its blocker to `Done`), and this
  skill will then surface the newly-unblocked issues.

> **TOCTOU skip recovery** — if one or more items are skipped during a batch
> promotion run, load the operator recovery reference:
> `references/operator-recovery.md`.
>
> **MANDATORY load trigger:** any TOCTOU skip message printed during `run --yes`,
> or any question about whether re-running after a partial batch is safe.
>
> **Do NOT load** for read-only `plan` / `--dry-run` invocations; those never
> mutate the board and produce no skips.

## Environment variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `MAKATO_PROMOTE_CONFIG` | `<repo>/.claude/config.json` | Override config path (tests only). |
| `MAKATO_PROMOTE_SPECS_DIR` | `<repo>/specs` | Override the specs directory (tests only). |
| `MAKATO_PROMOTE_DRYRUN` | unset | Set to `1` for the `--dry-run` default (no board mutation). |
| `MAKATO_PROMOTE_YES` | unset | Set to `1` to skip the interactive approval prompt (like `--yes`). |
| `MAKATO_PROMOTE_GH_OVERRIDE` | unset | Tests only: path to a canned `gh project item-list --format json` payload, read instead of calling `gh`. Mirrors `MAKATO_LOOP_GH_OVERRIDE`. |
| `MAKATO_PROMOTE_EDIT_TEST_FILE` | unset | Tests only: append each intended promotion (`promote #<n> <slug> item=<id>`) here instead of calling `gh project item-edit`. |

## Smoke tests

`scripts/promote-ready-smoke-tests.sh` covers fifteen scenarios, fully
offline (board injected via `MAKATO_PROMOTE_GH_OVERRIDE`, promotions
captured via `MAKATO_PROMOTE_EDIT_TEST_FILE` — `gh` is never invoked):

1. Loads the dependency graph from `created-issues.json`.
2. Computes unblocked issues and arranges topological waves.
3. An issue with a non-`Done` blocker stays blocked (not recommended).
4. The `plan.md` collision guard defers a second same-folder candidate.
5. `--dry-run` makes no board mutation (isolated via `--yes` so the dry-run gate, not the non-TTY guard, is the tested gate).
6. Forward-only — `Ready`/`In progress`/`In review`/`Done` are never re-promoted.
7. Live promote (`--yes`) writes exactly the recommended issues.
8. `stories.json` fallback — `blockedBy` sequences translate via `githubIssue`; a story with no `githubIssue` warns.
9. Off-board issues are promotable when unblocked; an off-board (not-`Done`) blocker still blocks.
10. An **unfiled** `stories.json` blocker (a `blockedBy` sequence whose upstream story has no `githubIssue`) keeps the dependent issue **blocked** — it is never silently dropped.
11. A dependency cycle terminates, warns, and promotes neither member.
12. An all-unparseable graph shows `(no issues in graph)` — no phantom `Wave 0`.
13. A no-such-slug run is clean on bash 3.2 (no `unbound variable` leak).
14. `plan --json` outputs valid JSON with the keys `ready`, `waves`, `blocked`, `skipped`, `deferred_collision`; exits 0 with any valid workspace graph.
15. `plan --json` with a slug-collision graph populates `deferred_collision` with the higher issue number; the lower appears in `ready[]`.

```bash
plugins/makato-orchestrate/scripts/tests/promote-ready-smoke-tests.sh
```

Run in CI via `.github/workflows/validate.yml`.

## Out of scope

- **Dispatch.** This skill only moves cards to `Ready`; `loop` dispatches
  them. It never spawns a PO-agent.
- **Automatic wave chaining.** This skill promotes the currently-unblocked
  wave and stops. It does not watch for merges and auto-promote the next wave
  — that is the deliberate wave-by-wave operating model (re-run after a
  merge). The `loop` skill reads wave ordering via `plan --json` at each tick,
  but the promotion itself (moving `Todo`/`Blocked` → `Ready`) is only
  triggered when `MAKATO_LOOP_ALLOW_TODO=1` or `--promote-unblocked` is set.
- **Cross-folder `plan.md` isolation.** The collision guard *avoids* the
  hazard by deferring; it does not *fix* it. Per-issue `plan.md` isolation
  (the prerequisite for safe same-folder parallelism) is a separate follow-on.
- **Priority ordering within a wave.** Issues within one wave are ordered
  by issue number, not by `priority:`/`severity:` labels.

## Tracking issue

[#268](https://github.com/macatocz/makato/issues/268) — dependency-aware
Ready promotion. Complements the "FIFO only in v1" limitation of the
`loop` skill ([GAP-007 / #33](https://github.com/macatocz/makato/issues/33)).
