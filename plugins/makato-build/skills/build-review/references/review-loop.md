# Review Loop

Procedure for Step 5 of `SKILL.md`: one repair round. Run it whenever a merged review R1
reports `critical_count > 0` or `major_count > 0`. One pass through round steps 1–9 is one
repair round; round step 9 either returns to round step 1 or hands back to `SKILL.md` Step 5.

The round has this shape because one reviewer reads a large diff shallowly, because a repair
that fixes one symptom lets the same defect come back, and because a fixed round limit stops
a converging loop and lets a diverging one run. So findings are repaired as invariants on every
site, hard repairs are planned before they are edited, the pre-repair tree gets a full review
while the coder works, and the loop ends on convergence rather than on a count.

Every decision that can be computed comes from a helper — never improvise one:

- `$MAKATO_BUILD_ROOT/shared/review_loop.py` — finding history, merging, convergence,
  partitioning, and the background-pass policy.
- `$MAKATO_BUILD_ROOT/shared/review_scope.py` — snapshots, the repair delta, review scope, and
  the background checkout.

Each helper prints one JSON object on stdout. A usage or input error exits 2 with
`review-loop: <message>` or `review-scope: <message>` on stderr.

---

## State to keep

Values from `SKILL.md` Steps 1–2 and from earlier rounds. Re-expand them in every command;
shell variables do not persist between tool calls.

- `MAKATO_BUILD_ROOT`, `WORKTREE_PATH`, `REPO_ROOT`, `SPEC_FOLDER`, `REVIEW_BASE` — Step 1.
- `STATE` — the loop-state file from Step 2. Its directory also holds the reviewer R1 files
  (`pass-<N>-<lens|single>.json`) and the round findings files (`round-<R>-findings.json`).
- `repair_rounds` — coder repair rounds started in this run; `0` at the start.
- `mode`, `last_scope`, `full_since_repair` — the review-scope bookkeeping from Step 2.
- The reviewer pass counter — the next `PASS_NUMBER`. Every reviewer of one pass shares its
  number; a background pass takes its own.
- `REVIEW_FINDINGS` — the blocking findings this round repairs: the CRITICAL and MAJOR entries
  of a merged R1's `data.findings[]`, unchanged (`id`, `severity`, `category`, `invariant`,
  `file`, `line`, `evidence`, `description`, `sites`, `lenses`).
- `redesign_ids` — from round step 1.
- `PRE_REPAIR_SNAPSHOT`, `REPAIR_ROUND`, `BG_PATH`, and the background pass number — per round.
- The Step 6 counters `background_passes`, `lens_split_passes`, and `repair_plan_reviews`.

---

## Round step 1 — Decide whether another round may start

Ask after every review that reports blockers — the first full pass, each re-review, a
`final-full` pass — naming every blocking finding you are about to repair. A review with no
blockers never calls `next` and writes no `convergence` entry; it goes to `decide --event clean`:

```bash
python3 "$MAKATO_BUILD_ROOT/shared/review_loop.py" next --state "$STATE" \
  --repair-rounds "$repair_rounds" --open "<comma-separated IDs of REVIEW_FINDINGS, no spaces>"
# {"continue":true,"reason":"within_soft_cap","redesign_ids":[],"recurring_ids":[],"new_by_round":{"0":3},"soft_cap":3,"hard_cap":8,"warnings":[]}
```

`next` reads `MAKATO_MAX_REPAIR_ROUNDS` (soft cap, default `3`) and
`MAKATO_MAX_REPAIR_ROUNDS_HARD` (hard cap, default `8`) itself. A value that is not a positive
integer falls back to its default, and a hard cap below the soft cap is raised to it; each
correction is a `warnings` entry. Its rules, in this order:

- `recurring_finding` — an open finding came back a third time after a repair, which is after
  its redesign. Stop, whatever the caps.
- `hard_cap` — `repair_rounds` reached the hard cap. Stop.
- `within_soft_cap` — fewer rounds than the soft cap have run. Continue.
- `converging` — the soft cap is reached, but the last round raised no new blockers, or fewer
  than the round before. Continue.
- `not_converging` — the soft cap is reached and the last round did not shrink the new
  blockers. Stop.

Log every decision: the helper's JSON plus `repair_rounds`. `warnings` stay inside this entry.

```json
{"ts":"<ISO8601>","skill":"build-review","story":"<key>","step":"convergence","status":"ok","data":{"continue":true,"reason":"within_soft_cap","redesign_ids":[],"recurring_ids":[],"new_by_round":{"0":3},"soft_cap":3,"hard_cap":8,"warnings":[],"repair_rounds":0}}
```

**`continue:true`** — keep `redesign_ids`: those open findings have come back twice after a
repair, so round step 4 must plan their next repair. Go on to round step 2.

**`continue:false`** — fail closed. Log the stop, with `reason` copied from `next`
(`recurring_finding`, `hard_cap`, or `not_converging`):

```json
{"ts":"<ISO8601>","skill":"build-review","story":"<key>","step":"repair-loop","status":"error","data":{"reason":"hard_cap","repair_rounds":<repair_rounds>,"repair_rounds_exhausted":true,"unresolved_findings":[{"id":"F-001","severity":"MAJOR","file":"<path>","description":"<one line>"}]}}
```

Then return R1 `failure` with `data.repair_rounds: <repair_rounds>`,
`data.repair_rounds_exhausted:true`, `data.exhaustion_reason: "<reason>"`, and one `errors`
entry per unresolved finding (`<file>:<line> — [<SEVERITY>][<category>] <description>`). Never
turn exhaustion into a clean result and never raise a cap yourself. Autonomous callers map this
failure to HALT-003.

---

## Round step 2 — Retain the findings and take the pre-repair snapshot

`REVIEW_FINDINGS` is the blocking part of the merged R1 in round 1, and the set assembled by
round step 9 afterwards. Do not discard a finding because it appeared in an earlier pass. Log
each one before repair:

```json
{"ts":"<ISO8601>","skill":"build-review","story":"<key>","step":"blocking-finding","status":"warn","data":{"pass":<N>,"severity":"MAJOR","finding":"F-001","file":"<path>","category":"<type>","description":"<one line>","invariant":"<the rule that must hold>","sites":[{"file":"<path>","line":<N>}]}}
```

Capture the snapshot the repair delta is measured against. A details-only continuation in the
same round keeps the same snapshot:

```bash
PRE_REPAIR_SNAPSHOT="$(python3 "$MAKATO_BUILD_ROOT/shared/review_scope.py" snapshot --worktree "$WORKTREE_PATH" | python3 -c 'import json,sys; print(json.load(sys.stdin)["snapshot"])')"
```

Set `REPAIR_ROUND` to `repair_rounds + 1`.

---

## Round step 3 — Start the background full pass

A delta pass cannot see a defect the repair did not touch, and the one full pass that can comes
late. Reviewing the pre-repair tree in full while the coder works moves those findings forward
without adding wall-clock time. Ask the helper:

```bash
python3 "$MAKATO_BUILD_ROOT/shared/review_loop.py" background --state "$STATE" --repair-round "$REPAIR_ROUND"
# {"run":true,"reason":"first background full pass"}
```

**`run:false`** — go to round step 4. The helper says no in round 1 (the first full pass already
reviewed the tree), under `MAKATO_REVIEW_SCOPE=full` (every pass is already full), and when the
last background pass found nothing new. A `warning` key repeats the invalid
`MAKATO_REVIEW_SCOPE` fallback that Step 2 already logged.

**`run:true`** — the reviewers get their own checkout of the snapshot, so they never read files
the coder is editing:

1. Materialize the snapshot. The path must not exist yet.

   ```bash
   BG_PATH="${TMPDIR:-/tmp}/makato-bg-<key>-$REPAIR_ROUND"
   python3 "$MAKATO_BUILD_ROOT/shared/review_scope.py" materialize --worktree "$WORKTREE_PATH" \
     --snapshot "$PRE_REPAIR_SNAPSHOT" --path "$BG_PATH"
   # {"path":"…","commit":"…"}
   ```

   If it fails (exit ≠ 0 — the path exists, or the repository forbids linked worktrees), log
   `{"ts":"<ISO8601>","skill":"build-review","story":"<key>","step":"background-full-pass","status":"warn","data":{"repair_round":<R>,"reason":"<stderr>"}}`,
   skip the background pass for this round, and go to round step 4. The `final-full` pass still
   certifies the tree.
2. Refresh `CHANGED_FILES` inside the checkout with
   `git -C "$BG_PATH" diff --name-only "$REVIEW_BASE"`. The snapshot already holds the files
   that are untracked in the live tree, so nothing is untracked there.
3. Apply the lens policy of Step 4 to the checkout:

   ```bash
   python3 "$MAKATO_BUILD_ROOT/shared/review_loop.py" lenses --worktree "$BG_PATH" --review-base "$REVIEW_BASE"
   ```

4. Increment the reviewer pass counter — the background pass takes its own `PASS_NUMBER` — and
   log the start:

   ```json
   {"ts":"<ISO8601>","skill":"build-review","story":"<key>","step":"background-full-pass","status":"start","data":{"repair_round":<R>,"pass":<BG pass>,"snapshot":"<PRE_REPAIR_SNAPSHOT>"}}
   ```

   Then dispatch the `diff-reviewer` agents as **background agents** and do not wait for them:
   one per lens in a single message when `split:true`, otherwise one without `LENS`. The inputs
   are those of Step 4 except `WORKTREE_PATH` = `BG_PATH`, `PRIOR_FINDINGS` empty,
   `REVIEW_SCOPE: full`, and no `REPAIR_DELTA` or `PRIOR_AC_VERDICTS`; `REPO_ROOT`,
   `REVIEW_BASE`, `PLAN_CONTEXT`, and `STORY_KEY` are unchanged. Each reviewer's R1 is saved to
   `"$(dirname "$STATE")/pass-<BG pass>-<lens|single>.json"`.
5. If the runner cannot run an agent in the background while you continue, run this review now,
   to completion, before round step 4. It is then a sequential extra pass; round step 8 still
   merges and releases it.

Remember `BG_PATH` and the background pass number for round step 8. From the moment
`materialize` succeeds, every exit from the round — a failure R1 included — first abandons the
unfinished background reviewers and releases the checkout (round step 8, item 4).

---

## Round step 4 — Design pre-check

Run this step only when `REVIEW_FINDINGS` contains a CRITICAL finding or a finding whose ID is
in `redesign_ids`; otherwise go to round step 5 without `APPROVED_PLANS`. A repair that fixes
one symptom of a design defect is the repair that comes back. Checking the design first costs
one coder dispatch and one reviewer dispatch, and it does **not** consume a repair round.

1. **Plan.** Dispatch one `coder` in review-repair mode with `REPAIR_PHASE: plan`, every finding
   of `REVIEW_FINDINGS` (the plans are reviewed together, so findings that share a design are
   judged together), and the inputs of round step 5 (`REPAIR_ROUND`, `MAX_REPAIR_ROUNDS`,
   `PLAN_CONTEXT`, `STORY_KEY`, `JSONL_PATH`, `REPO_ROOT`, `MAKATO_BUILD_ROOT`,
   `WORKTREE_PATH`, `GATE_COMMANDS`). It edits nothing and returns `data.plans[]`, one plan per
   finding. A plan phase that is not `success`, or that omits a finding, is a failed repair:
   round step 6, **Failure**. Log:

   ```json
   {"ts":"<ISO8601>","skill":"build-review","story":"<key>","step":"repair-plan","status":"ok","data":{"repair_round":<R>,"ids":["F-001"]}}
   ```

2. **Prove the tree is untouched.** Run the `snapshot` command of round step 2 again. It must
   print `PRE_REPAIR_SNAPSHOT`; otherwise return R1 `failure` with
   `errors:["plan phase edited the worktree"]` and log terminal `step:"session"`,
   `status:"error"`.
3. **Review the plans.** Dispatch `diff-reviewer` with `REVIEW_MODE: repair-plan`, `STORY_KEY`,
   `REPO_ROOT`, `WORKTREE_PATH`, `REVIEW_BASE`, `PLAN_CONTEXT`, `REVIEW_FINDINGS`, and
   `REPAIR_PLANS` (the coder's `data.plans[]`). Its `data.plan_verdicts[]` holds one
   `{id,verdict:"approve|revise",required_changes[]}` per plan. Count one `repair_plan_reviews`
   and log:

   ```json
   {"ts":"<ISO8601>","skill":"build-review","story":"<key>","step":"repair-plan-review","status":"ok","data":{"repair_round":<R>,"iteration":1,"approved":["F-001"],"revise":[]}}
   ```

   A reviewer R1 that is missing, malformed, or `partial` is re-dispatched once. If it is still
   unusable, log the same step with `status:"warn"` and a `reason`, and go to round step 5
   without `APPROVED_PLANS` — a single-phase repair, which the re-review checks as usual.
4. **Revise once.** If any plan got `revise`, dispatch the `coder` again with
   `REPAIR_PHASE: plan` and `PLAN_FEEDBACK`: the `required_changes` of the `revise` verdicts, by
   `id`, together with the previous `plans[]` — a fresh coder has not seen them and must return
   the complete revised set. Then repeat items 2 and 3 with `"iteration":2`. There is no third
   iteration.
5. **Hand over to the apply phase.** `APPROVED_PLANS` is the latest `plans[]`. `PLAN_CONSTRAINTS`
   holds the `required_changes` of every plan whose latest verdict is still `revise`, by `id`;
   it is empty when every plan was approved. The apply coder implements the plans exactly and
   records any departure in `details.assumptions`.

---

## Round step 5 — Partition the findings and repair them

Write the round's findings to a file and let the helper group them. Findings that share a site
file stay in one group, so no two coders edit the same file:

```bash
# first write {"data":{"findings":[<the REVIEW_FINDINGS entries, unchanged>]}} to the file
python3 "$MAKATO_BUILD_ROOT/shared/review_loop.py" partition \
  --findings "$(dirname "$STATE")/round-$REPAIR_ROUND-findings.json" \
  --ids "<comma-separated IDs of REVIEW_FINDINGS, no spaces>"
# {"groups":[{"group":1,"ids":["F-001","F-003"],"files":["api.py","auth.py"]},{"group":2,"ids":["F-002"],"files":["loader.py"]}]}
```

The helper returns at most four groups; beyond that it merges the groups with the fewest files.
Log:

```json
{"ts":"<ISO8601>","skill":"build-review","story":"<key>","step":"repair-partition","status":"ok","data":{"repair_round":<R>,"groups":[{"group":1,"ids":["F-001","F-003"],"files":["api.py","auth.py"]}]}}
```

Dispatch **`coder` in review-repair mode** — not the reviewer and not a new planning cycle —
with:

- `REPAIR_ROUND` and `MAX_REPAIR_ROUNDS` (the soft cap);
- `REVIEW_FINDINGS`: the findings of its group;
- `PLAN_CONTEXT`, `STORY_KEY`, `JSONL_PATH` (`$SPEC_FOLDER/build.jsonl`), `REPO_ROOT`,
  `MAKATO_BUILD_ROOT`, and `WORKTREE_PATH`;
- `GATE_COMMANDS` from implementation; if unavailable, obtain it once from `gate-scout` with
  `REPO_ROOT=WORKTREE_PATH`. Forward available baseline/test evidence without inventing a
  passing baseline;
- `APPROVED_PLANS` and `PLAN_CONSTRAINTS` from round step 4, restricted to its finding IDs —
  only when round step 4 ran.

**One group:** a single coder, with no `ALLOWED_FILES`. **Several groups:** dispatch one coder
per group in a single message so they run at the same time, each with `ALLOWED_FILES` = its
group's `files`. All of them share `REPAIR_ROUND` and `PRE_REPAIR_SNAPSHOT`.

Advance `repair_rounds` to `REPAIR_ROUND` when the first apply-phase coder dispatch of the round
starts — the plan phase of round step 4 does not count. Each coder follows the repair-mode
contract in `$MAKATO_BUILD_ROOT/agents/coder.md`: it repairs the invariant on every site of its
findings, adds a regression test that proves the invariant across those sites, verifies its
repairs, and returns R1.

---

## Round step 6 — Validate every coder result

For each coder R1, check `data.mode`, a matching `repair_round`, `repaired_findings`,
`unresolved_findings`, and `data.details.per_finding`. A successful response reports every
finding it was given repaired, none unresolved, and verification passed; the only accepted
exception is a finding left unresolved with `needs_files` (below). For each supplied finding
require a matching `per_finding` entry with `id`, `root_cause`, `changes`,
`verification:{command,exit_code,result}`, `sites_covered`, and `sites_not_applicable` (both
`[]` for a finding without `sites`). Every changed path a coder reports must appear in the
actual working-tree changes.

- **Site accounting.** Every entry of the finding's `sites` appears in `sites_covered` or in
  `sites_not_applicable` (the latter with a concrete `reason`). A site in neither list, or a
  finding repaired at its primary site with the others unexamined, is a missing detail.
- **Already resolved.** A finding that no longer reproduces comes back in `repaired_findings`
  with `root_cause:"already resolved: <what fixed it>"`, no `changes`, and a `verification`
  command that proves it. That is a valid repair — usually a background finding that an earlier
  repair fixed — and round step 7 claims it like any other.
- **Missing or inconsistent details.** Dispatch exactly one fresh coder continuation for the same
  repair round, with the same `ALLOWED_FILES`, `PRIOR_R1`, and
  `DETAILS_REQUEST:<missing or inconsistent items>`. The allowance is per coder. A second
  incomplete response from that coder is a failure, not permission to infer what changed.
- **Partition integrity** (several coders only). Once every coder, details-only continuations
  included, has finished, and before any `needs_files` continuation, measure the repair:

  ```bash
  python3 "$MAKATO_BUILD_ROOT/shared/review_scope.py" delta --worktree "$WORKTREE_PATH" \
    --review-base "$REVIEW_BASE" --snapshot "$PRE_REPAIR_SNAPSHOT"
  ```

  Every `files[].path` must be a file in some group's `ALLOWED_FILES`, an existing test paired
  with one (`test_<stem>`, `<stem>_test`, `<stem>.test`, `<stem>.spec`), or a new file a coder
  reported in its `changes`. Anything else: return R1 `failure` with
  `errors:["repair edited outside its partition: <paths>"]` and log terminal `step:"session"`,
  `status:"error"`.
- **`needs_files`.** A finding left unresolved with `per_finding[].needs_files:["<path>"]` needs a
  file outside its partition. After the partition check, dispatch ONE sequential coder
  continuation in the same round, with no `ALLOWED_FILES`, for those findings (and their plans),
  passing `PRIOR_R1` of the coder that returned them — its partial edits stay in the tree.
  Validate its R1 like any other.
- **Failure.** A coder that still cannot complete a repair or its verification ends the run:
  return a non-success R1 containing the unresolved findings and the concrete blocker, and log
  terminal `step:"session"`, `status:"error"`. Never emit a clean result or advance to
  verify/push.

---

## Round step 7 — Record the repair, then re-review it independently

1. Record the claims: every finding a coder reported repaired ("already resolved" ones included)
   and nothing a coder left unresolved. A later review that raises a claimed finding again counts
   as a recurrence.

   ```bash
   python3 "$MAKATO_BUILD_ROOT/shared/review_loop.py" repaired --state "$STATE" --round "$REPAIR_ROUND" \
     --ids "<comma-separated IDs of the repaired findings, no spaces>"
   # {"round":2,"ids":["F-001","F-003"]}
   ```

2. Log each verified repair with `step:"fix-blocking"`, `status:"ok"`, and
   `data:{pass,repair_round,severity,finding,file,sites_covered,details:{per_finding:[<matching
   coder entry>]}}`. Copy the matching per-finding entry verbatim into `details.per_finding`, and
   its `sites_covered` into `data.sites_covered`; both are required evidence, not optional prose.
3. Coder success is **not** review approval. Run Step 3 of `SKILL.md` (its mechanical changes
   belong to the repair), then measure the repair and choose the review scope:

   ```bash
   python3 "$MAKATO_BUILD_ROOT/shared/review_scope.py" delta --worktree "$WORKTREE_PATH" \
     --review-base "$REVIEW_BASE" --snapshot "$PRE_REPAIR_SNAPSHOT"
   python3 "$MAKATO_BUILD_ROOT/shared/review_scope.py" decide --event repaired \
     --last-scope "$last_scope" --full-since-repair "$full_since_repair" \
     --repair-rounds "$repair_rounds" --scope-ratio <scope_ratio from the delta output>
   ```

   `delta` prints `REPAIR_DELTA`. `"empty":true` means no repair landed, the mismatch round step 6
   rejects — unless every repaired finding was reported already resolved. `decide` prints the
   scope for the next pass: `delta`, or `full` when the repair plus its neighbours cover most of
   the change. Log it as `step:"scope-decision"`, `status:"ok"`,
   `data:{pass,event:"repaired",next,reason,scope_ratio}`, set `last_scope` to `next`, and copy
   `full_since_repair` from the output.
4. Dispatch Step 4 of `SKILL.md` with an incremented reviewer pass counter, refreshed
   `CHANGED_FILES`, `PRIOR_FINDINGS` (the `REVIEW_FINDINGS` entries, each with its `id`,
   `invariant`, and `sites`), and that scope; a `full` scope is lens-split like any other. Merge
   the result with `--after-round "$REPAIR_ROUND"`. Recheck unresolved findings and newly
   introduced defects against the actual uncommitted working tree. This independent re-review
   completes the repair round. Its blocking IDs are the live blockers for round step 9.

---

## Round step 8 — Finish the background pass

Skip this step when round step 3 started no background pass. Otherwise wait for its reviewers,
then do the following. Release the checkout (item 4) whatever happened.

1. Merge the background reviewers' R1 files. `--after-round` is the round before this repair,
   because the snapshot predates it. `--drop-ids` removes every finding this round repairs,
   because the snapshot still contains those defects:

   ```bash
   python3 "$MAKATO_BUILD_ROOT/shared/review_loop.py" merge --state "$STATE" --pass <BG pass> \
     --scope background-full --after-round "$((REPAIR_ROUND - 1))" --snapshot "$PRE_REPAIR_SNAPSHOT" \
     --drop-ids "<comma-separated IDs of this round's REVIEW_FINDINGS, no spaces>" \
     "$(dirname "$STATE")"/pass-<BG pass>-*.json
   ```

   The helper also drops background findings within three lines of the recorded sites of those
   IDs. The blocking findings that remain are the background blockers: defects of the pre-repair
   tree that this round was not asked to repair. If `merge` exits 2, re-dispatch the reviewer it
   names once, in `BG_PATH`. A second exit 2, or a `partial` merged R1, is an incomplete pass:
   log `step:"background-full-pass"`, `status:"warn"`, `data:{repair_round,pass,reason}`, ignore
   the pass, and skip items 2 and 3.
2. Record the coverage. A completed background full pass reviewed a tree that already held an
   earlier repair, so it can stand in for the `final-full` pass that `decide --event clean` would
   otherwise schedule; repairs made after it are still delta-reviewed.

   ```bash
   python3 "$MAKATO_BUILD_ROOT/shared/review_scope.py" decide --event background-full \
     --last-scope "$last_scope" --full-since-repair "$full_since_repair" --repair-rounds "$REPAIR_ROUND"
   # {"next":"none","reason":"a background full pass covered the tree after an earlier repair","full_since_repair":true,"mode":"delta"}
   ```

   Copy `full_since_repair` from the output and nothing else; `last_scope` belongs to the live
   pass. The helper exits 2 below round 2, and the background pass never runs earlier.
3. Log the result and update the counters (`background_passes` +1; `lens_split_passes` +1 when
   the merged `data.lenses` is not empty). `critical` and `major` are the merged counts and
   `new_blocking` the IDs of its blocking findings, all of them new because its reviewers had no
   prior findings:

   ```json
   {"ts":"<ISO8601>","skill":"build-review","story":"<key>","step":"background-full-pass","status":"ok","data":{"repair_round":<R>,"pass":<BG pass>,"critical":<N>,"major":<N>,"new_blocking":["F-005"]}}
   ```

4. Release the checkout — always, also after an error or an incomplete pass:

   ```bash
   python3 "$MAKATO_BUILD_ROOT/shared/review_scope.py" release --worktree "$WORKTREE_PATH" --path "$BG_PATH"
   # {"released":true}
   ```

---

## Round step 9 — Collect the open blockers

The open blockers are the blocking IDs of the round step 7 re-review plus the background
blockers of round step 8 (none when no background pass ran or when it was ignored).

- **None open:** the round is complete. Return to `SKILL.md` Step 5 and continue with the
  zero-findings flow (`decide --event clean`).
- **Otherwise:** `REVIEW_FINDINGS` becomes the blocking entries of the two merged R1s, and the
  round restarts at round step 1 with `--open` naming exactly those IDs.

A defect that both passes report carries two IDs. Keep both: they share a site file, so
`partition` puts them in one group, and the coder reports the second one already resolved.

---

## When a helper fails

- `init`, `repaired`, `next`, `merge` (after the one reviewer re-dispatch that Step 4 allows),
  and the pre-repair `snapshot`: the round can no longer be tracked or proven. Log the error as
  `step:"session"`, `status:"error"` and return a non-success R1. Never repair or certify
  without the convergence decision.
- `lenses`, `partition`: degrade to the simple form — one reviewer without `LENS`, one coder
  without `ALLOWED_FILES` — and log the error as `step:"repair-loop"`, `status:"warn"`.
- `background`, `materialize`: no background pass this round; log `step:"background-full-pass"`,
  `status:"warn"`.
- `release`: log a `warn`. The checkout is a plain detached worktree, so
  `git -C "$WORKTREE_PATH" worktree remove --force "$BG_PATH"` removes it by hand.
- `delta` and `decide`: as in Step 2 of `SKILL.md`, log the error and review every pass as
  `full` — never a narrower scope than the helper approved.
