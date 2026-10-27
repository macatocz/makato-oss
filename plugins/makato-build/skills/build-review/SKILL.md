---
name: build-review
description: >-
  Adversarial quality review of the branch diff. Large changes get a parallel
  lens-split full pass. CRITICAL and MAJOR findings go to the coder in both
  manual and autonomous modes, fixed as invariants on every site (CRITICAL
  ones after a design pre-check), then re-reviewed by delta passes plus a
  background full pass. The repair loop ends on convergence — soft cap
  MAKATO_MAX_REPAIR_ROUNDS (default 3), hard cap
  MAKATO_MAX_REPAIR_ROUNDS_HARD (default 8), recurring findings stop it — and
  one final full pass certifies the whole tree. Auto-fixes mechanical issues.
  Reports SUGGESTION and NITPICK findings. Use after simplify, before verify.
  Trigger keywords: review, adversarial, diff-review, code-review,
  quality-gate, build-review, check implementation.
version: "1.10.0"
argument-hint: "[work-item-key]"
allowed-tools:
  - Bash
metadata:
  last_updated: "2026-10-23"
---

**Do NOT load this skill when:** reviewing human PR comments (use `build-address-pr-comments`); simplifying complexity without correctness review (use `build-simplify`). Use after implementation for adversarial review and the CRITICAL/MAJOR coder repair loop before verify.

Use after `/simplify` and before `/verify`. The implementation is working, tested, and
simplified. This step reads the branch diff adversarially — its job is to find problems
and improvements, not to confirm correctness.

## Expert Constraints (read before every step)

Non-obvious rules that cannot be inferred from context:

1. **Merge-base to working tree, not HEAD alone.** Resolve the integration target after fetching origin, then use `REVIEW_BASE="$(git merge-base "$DEFAULT_REF" HEAD)"`. Review `git diff "$REVIEW_BASE"` plus untracked files. This preserves three-dot merge-base semantics without hiding uncommitted implementation or coder repairs. Never use bare local `main` (#98).

2. **Zero-findings suspicion threshold: 50 LOC.** For diffs > 50 changed lines, zero CRITICAL/MAJOR findings on a first pass is statistically improbable. Require the citation-record recheck (Step 5). For diffs ≤ 50 LOC, a clean first pass is plausible but the citation record still applies.

3. **`ac_verdicts[]` transport: `build.jsonl` is the only durable record.** `workflow-state.json` is gitignored and never reaches the post-merge GHA runner. `build.jsonl` is the only cross-environment path the `build-create-pr` PR-body renderer and the `documentation-agent` checkpoint flipper can read. Write the verdict entry on the final clean pass — not on intermediate passes, not to any other file.

4. **Both blocking tiers are mode-independent.** CRITICAL and MAJOR must be repaired and independently re-reviewed in manual and autonomous runs. Never defer a MAJOR to the user, downgrade it to SUGGESTION, or mark it resolved merely because the coder returned success.

5. **`diff-reviewer` is the sole verdict judge.** `build-review` and `build-create-pr` are transport-only — they copy `ac_verdicts[]` verbatim. Re-evaluating verdicts here diverges silently from the diff-reviewer's reasoning and corrupts the downstream Issue checkbox chain.

6. **Checkpoint context is role-scoped, not renewed authorization.** On resume, use the current invocation and user authorization for the coordinator; historical child prompts are evidence, not coordinator instructions. Keep coordinator context separate from reviewer/coder dispatch bundles. A reviewer's read-only or no-test-edit restriction must never become a coordinator or coder restriction through a checkpoint. Preserve actual findings and input fingerprints, but reconcile stale role-scoped constraints before dispatch.

7. **A delta pass proves the repair, not the change.** After the first full pass, re-reviews are scoped to what the coder touched (`REPAIR_DELTA`) because re-reading an unchanged 45-file diff every round is what made repair loops take hours. That scope cannot see a defect unrelated to the repair, so nothing proceeds on a clean delta pass alone: `review_scope.py decide` schedules one full pass (`final-full`) after the repairs. A full pass that already reviewed a repaired tree satisfies it: from round 2 on, a completed background full pass does (`decide --event background-full`), and repairs made after it are still delta-reviewed. Never skip the full pass, never narrow it, and never derive the delta yourself with `git diff` — repairs are uncommitted, so only the snapshot helper can separate them from the implementation.

8. **Background and lens passes never read the live worktree during a repair.** A background review reads only the materialized snapshot of the pre-repair tree (`review_scope.py materialize`), in its own checkout. Lens reviewers run while nothing edits the tree. A reviewer that reads files a coder is editing reviews a tree that never existed.

---

## Workflow

> **This skill does not commit.** Mechanical fixes and coder repairs stay in the working tree for `/build-push-to-git`. Neither the skill nor its coder dispatch may stage, commit, or push.

### Step 1 — Ask for work item key and load context

If no argument was passed, invoke `AskUserQuestion`:
- question: *"Which work item are we reviewing?"*
- hint: `e.g. #123 — or pass directly: /makato-build:build-review #123`

Resolve `MAKATO_BUILD_ROOT` from the runner plugin-root variables. Apply the workspace
entry guard in `$MAKATO_BUILD_ROOT/AUTONOMOUS-MODE.md`: `WORKTREE_PATH` is required
in autonomous mode; manual mode defaults to the current git worktree. Missing autonomous
workspace returns R1 failure, never a fallback to the main checkout.

```bash
cd "$WORKTREE_PATH"
REPO_ROOT="${MAKATO_TARGET_REPO_ROOT:-$(cd "$(git rev-parse --git-common-dir)/.." && pwd)}"
SPEC_FOLDER="$(python3 "$MAKATO_BUILD_ROOT/shared/spec_folder.py" "$REPO_ROOT" "<key>")"
```

Read `plan.md` from that folder if it exists. Extract the acceptance criteria and task list —
these are the correctness contract. Every AC must be demonstrably covered by the diff.

Fetch origin (`git fetch origin --quiet`), then resolve
`DEFAULT_REF="$("$MAKATO_BUILD_ROOT/shared/default-branch.sh")"`. If origin is unreachable,
use the helper's local fallback. Set `REVIEW_BASE="$(git merge-base "$DEFAULT_REF" HEAD)"`
once for this run. Before **every** review pass, refresh `CHANGED_FILES` as the deduplicated
union of `git diff --name-only "$REVIEW_BASE"` and `git ls-files --others --exclude-standard`.
Use NUL-delimited output when processing paths programmatically. Read untracked files directly;
`git diff` does not include them. All code reads and commands run in `WORKTREE_PATH`;
only spec reads and audit writes use the selected `REPO_ROOT`-rooted `SPEC_FOLDER`.

`CHANGED_FILES` is the whole-change set. Full passes review all of it; delta passes
receive `REPAIR_DELTA` (Step 5) and re-read only the repair and its neighbours.

---

### Step 2 — Resolve the repair-round caps, open the loop state, and log session start

Set `MAX_REPAIR_ROUNDS` from `MAKATO_MAX_REPAIR_ROUNDS`. It must be a positive
integer; if unset, use `3`; if invalid, warn and use `3`. This is the **soft cap**:
once it is reached, another repair round starts only while the loop is converging.
Set `MAX_REPAIR_ROUNDS_HARD` from `MAKATO_MAX_REPAIR_ROUNDS_HARD` the same way
(default `8`; a value below the soft cap is raised to it). This is the **hard cap**:
no round starts once it is reached. `review_loop.py next` re-validates and enforces both
(`references/review-loop.md`); this skill passes only `MAX_REPAIR_ROUNDS` to the coder and
records both in the log. The caps apply to coder repair dispatches in this build-review loop
only. A repair round is one coder repair dispatch followed by an independent diff-reviewer
re-review. Initialize `repair_rounds` to `0`. Mechanical fixes, the design pre-check, the
background full pass, and any reviewer re-pass they require do not consume a coder repair
round.

When a value is invalid, log it — `reason` names the variable (`invalid MAKATO_MAX_REPAIR_ROUNDS` or `invalid MAKATO_MAX_REPAIR_ROUNDS_HARD`) and `fallback` is its default (`3` or `8`):

```json
{"ts":"<ISO8601>","skill":"build-review","story":"<key>","step":"repair-loop","status":"warn","data":{"reason":"invalid MAKATO_MAX_REPAIR_ROUNDS","fallback":3}}
```

Resolve the review-scope policy. `MAKATO_REVIEW_SCOPE` is `delta` (default) or
`full`; `full` restores the previous behaviour of reviewing every changed file on
every pass. Every scope decision comes from the helper — never improvise one:

```bash
python3 "$MAKATO_BUILD_ROOT/shared/review_scope.py" decide --event start
# {"next":"full","reason":"…","full_since_repair":false,"mode":"delta"}
```

Keep in memory: `mode` (from the output), `last_scope` (the `next` of the decision that
scheduled the pass just reviewed), and `full_since_repair` (copied from the latest
`decide` output). A `warning` key means `MAKATO_REVIEW_SCOPE` was invalid and the helper
fell back to `delta`: log it as `step:"repair-loop"`, `status:"warn"`. If the helper
fails (exit ≠ 0), log the error and review every pass as `full` — never a narrower
scope than the helper approved.

`MAKATO_REVIEW_LENSES` is `auto` (default), `on`, or `off`: whether a full pass is split
into one reviewer per lens (Step 4). The helper reads and validates it; log the effective
value (`auto` when unset or invalid) in the session start entry.

Open the loop state. It records every finding with the passes that raised it and the
repair rounds that claimed to fix it — the only way to see that one invariant keeps
coming back. It lives in the worktree's git directory, so it is never committed:

```bash
STATE="$(git -C "$WORKTREE_PATH" rev-parse --absolute-git-dir)/makato-review-loop/<key>.json"
python3 "$MAKATO_BUILD_ROOT/shared/review_loop.py" init --state "$STATE" --story <key> --review-base "$REVIEW_BASE"
# {"state":"…","resumed":false,"next_id":1}
```

`resumed:true` means a run on the same story and `REVIEW_BASE` already recorded history
(an interrupted or follow-up session): keep it, so finding IDs continue from `next_id` and
earlier raises and repair claims still count toward recurrence. `repair_rounds` still starts
at `0`. If `init` fails (exit ≠ 0), log terminal `step:"session"`, `status:"error"` and
return a non-success R1; never review without the state, because finding IDs, merging,
and the convergence decision depend on it.

Run:

```bash
"$MAKATO_BUILD_ROOT/shared/build-log.sh" "<key>" '{"ts":"<ISO8601>","skill":"build-review","story":"<key>","step":"session","status":"start","data":{"files_changed":<N>,"pass":1,"max_repair_rounds":<MAX_REPAIR_ROUNDS>,"max_repair_rounds_hard":<MAX_REPAIR_ROUNDS_HARD>,"review_scope_mode":"<delta|full>","review_lenses":"<auto|on|off>"}}'
```

---

### Step 3 — Auto-fix mechanical issues

Load `@references/mechanical-fixes.md`.

Apply all applicable fixes silently — these are never findings:
- Formatting drift (indentation, spacing) — run the project's formatter if one is configured
- Import ordering and unused import removal
- Trailing whitespace

Log:
```
{"ts":"<ISO8601>","skill":"build-review","story":"<key>","step":"mechanical-fixes","status":"ok","data":{"fixes_applied":<N>}}
```

---

### Step 4 — Review the diff (via diff-reviewer agent) — loops

**MANDATORY: Load `@references/review-criteria.md` before dispatching the diff-reviewer agent.** Its four-tier severity rubric governs which findings enter the repair loop in both modes.

Dispatch the `diff-reviewer` agent with:
- `STORY_KEY`: the work item key
- `PASS_NUMBER`: starts at 1; increment on every re-dispatch. All lens reviewers of one pass share its number
- `CHANGED_FILES`: freshly collected tracked changes and untracked paths from Step 1
- `PLAN_CONTEXT`: acceptance criteria, tasks, and constraints from the resolved plan
- `REPO_ROOT`: common repository root for spec context
- `WORKTREE_PATH`: resolved workspace; the reviewer must read the same files the coder edits
- `REVIEW_BASE`: merge-base SHA resolved in Step 1
- `PRIOR_FINDINGS`: prior pass's findings with source evidence — each with its stable `id`, `invariant`, and `sites`, so the reviewer can re-check every site and re-raise a returned finding under the same `id`; empty on pass 1
- `REVIEW_SCOPE`: `full` when the scope decision's `next` is `full` or `final-full`; `delta` when it is `delta`
- `REPAIR_DELTA`: (`delta` only) the JSON printed by `review_scope.py delta` in Step 5 — pre/post snapshot ids, touched files, neighbours
- `PRIOR_AC_VERDICTS`: (`delta` only) the `data.ac_verdicts[]` retained by Step 4a from the previous pass
- `LENS`: (lens-split `full` / `final-full` passes only) one of `security-privacy`, `state-concurrency`, `error-handling`, `resources-performance`, `contract-ac`; omitted otherwise

**Lens-split full pass.** One reviewer reading a large diff reads it shallowly, and blockers
then surface only in late full passes. Before every `full` or `final-full` dispatch, ask
whether the change is large enough to split the review:

```bash
python3 "$MAKATO_BUILD_ROOT/shared/review_loop.py" lenses --worktree "$WORKTREE_PATH" --review-base "$REVIEW_BASE"
# {"split":true,"lenses":["security-privacy","state-concurrency","error-handling","resources-performance","contract-ac"],"changed_lines":812,"changed_files":59,"mode":"auto"}
```

With `split:true`, dispatch **one `diff-reviewer` per lens in a single message** (parallel
agents): same inputs, same `PASS_NUMBER`, `REVIEW_SCOPE: full`, and `LENS: <lens>`. Each
reads the whole reviewed set and reports only its own lens; each receives the same
`PRIOR_FINDINGS`, and duplicate re-raises merge by `id` below. With `split:false`, dispatch
one reviewer without `LENS`. A `delta` pass is always a single reviewer without `LENS`.
`MAKATO_REVIEW_LENSES` (`auto`, `on`, `off`) steers the helper; `auto` splits above 400
changed lines or 15 changed files. A `warning` key means the value was invalid and `auto`
applied: log it as `step:"repair-loop"`, `status:"warn"`. If the helper fails (exit ≠ 0),
log the error and dispatch a single reviewer without `LENS`.

The agent applies the adversarial lens across all seven categories (correctness, edge cases, error handling, security, contract, test coverage, optimizations) — or, with `LENS`, only the categories of that lens — and returns findings classified as CRITICAL, MAJOR, SUGGESTION, or NITPICK with source-anchored evidence. Every CRITICAL and MAJOR finding states an `invariant` (the rule that must hold) and its `sites` (every place, changed or unchanged, where it must hold), so the repair fixes the rule rather than the symptom. As of diff-reviewer v1.1.0 it also returns `data.ac_verdicts[]` — one `{ac_id, ac_text, verified, evidence, reason}` per acceptance criterion in `PLAN_CONTEXT`; on a lens-split pass only the `contract-ac` reviewer returns them.

On a `delta` dispatch `CHANGED_FILES` is still passed (the reviewer needs the whole-change set for caller lookups) but only the delta is re-read. If the returned `data.review_scope` is `full` for a `delta` dispatch, the reviewer widened it; record that pass as `full` (`last_scope:"full"`, `full_since_repair:true`).

**Merge before judging.** Save each reviewer's R1 to `"$(dirname "$STATE")/pass-<N>-<lens|single>.json"` (`single` for a reviewer without `LENS`; the helper reads the last JSON object in the file) and merge them — a lone reviewer's too — so every finding gets a stable ID and the loop state records the pass:

```bash
PASS_SNAPSHOT="$(python3 "$MAKATO_BUILD_ROOT/shared/review_scope.py" snapshot --worktree "$WORKTREE_PATH" | python3 -c 'import json,sys; print(json.load(sys.stdin)["snapshot"])')"
python3 "$MAKATO_BUILD_ROOT/shared/review_loop.py" merge --state "$STATE" --pass <N> \
  --scope <full|final-full|delta> --after-round "$repair_rounds" --snapshot "$PASS_SNAPSHOT" \
  "$(dirname "$STATE")"/pass-<N>-*.json
```

`--scope` is the scope the pass actually had (`full` for a `delta` dispatch the reviewer widened). The merged R1 — `status`, the severity counts, `errors`, and `data.findings[]` with `id`, `invariant`, `sites`, and `lenses` — is the single input to Steps 4a and 5; a lens reviewer's own R1 is never judged alone. Findings whose sites sit within three lines of each other in one file merge into one finding at the highest severity. If `merge` exits 2 (a blocking finding without `invariant` or `sites`, counts that disagree with the findings, no R1 object), re-dispatch the reviewer it names once, passing the helper's message; a second exit 2 is a partial review (Step 5).

`--snapshot` records the tree the pass reviewed. Nothing edits the live tree while a live
pass runs, so taking it after the reviewers return is exact. It is optional bookkeeping: if
the `snapshot` helper fails, omit the flag and log the error as `step:"repair-loop"`,
`status:"warn"`.

Log:
```
{"ts":"<ISO8601>","skill":"build-review","story":"<key>","step":"lens-merge","status":"ok","data":{"pass":<N>,"scope":"<full|final-full|delta>","lenses":["<lens>",…],"inputs":<k>,"critical":<N>,"major":<N>}}
{"ts":"<ISO8601>","skill":"build-review","story":"<key>","step":"analyze","status":"ok","data":{"pass":<N>,"scope":"<full|final-full|delta>","lenses":["<lens>",…],"files_reviewed":<N>,"critical":<N>,"major":<N>,"suggestion":<N>,"nitpick":<N>}}
```

`lenses` is `[]` when a single reviewer without `LENS` ran.

#### Step 4a — Retain the per-AC verdict set until the final clean pass

Keep the merged R1's `data.ac_verdicts[]` unchanged in memory. A lens-split pass is a
full-scope pass; its verdicts come from the `contract-ac` reviewer, and the other lenses
return none. Only after Step 5 and Step 5.5 confirm a complete, clean review of the final
working tree, copy it **verbatim** into the following `build.jsonl` entry. Never persist an
intermediate pass as final verification.
This is the durable transport to the PR body and post-merge runner; the last
`ac-verification` line wins:

```
{"ts":"<ISO8601>","skill":"build-review","story":"<key>","step":"ac-verification","status":"ok","data":{"pass":<N>,"ac_verdicts":[{"ac_id":"AC-1","ac_text":"…","verified":true,"evidence":"…","reason":""}]}}
```

When `ac_verdicts` is absent (diff-reviewer predates v1.1.0) or empty, log the entry with
`"ac_verdicts":[]` and `status:"warn"` so the downstream skills degrade to the all-or-nothing
fallback rather than silently skipping checkbox marking.

Delta passes carry verdicts forward from `PRIOR_AC_VERDICTS`; keep the array from the
most recent live-tree R1 verbatim — never the one from a background pass, which describes
the pre-repair tree. The persisted entry is therefore only as trustworthy as the
full-scope pass behind it — which is why Step 5 never accepts a clean delta pass alone.

---

### Step 5 — Blocking-findings loop and zero-findings gate

**CRITICAL and MAJOR are blocking in both manual and autonomous mode.**
The review skill owns this loop; the read-only `diff-reviewer` does not apply repairs.

Parse the merged R1 printed by Step 4's `merge`. Missing/malformed R1, missing or invalid severity counts,
`partial`, or an incomplete file review cannot pass this gate. A `failure` with
blocking findings is a repair request, not a reason to skip to `/build-verify`.
A failure without actionable findings is a blocked review; surface its errors.
For a partial/incomplete review, re-dispatch the reviewer to cover the missing
files if actionable; otherwise return non-success with a terminal session error.
Never turn an unreadable file or absent count into a zero-findings result.

**If `critical_count > 0` OR `major_count > 0`:**

**MANDATORY: Load `@references/review-loop.md` and run one repair round from it.** It holds
the exact commands, dispatch inputs, log entries, and failure handling. The round runs these
steps in this order:

1. **Continuation decision.** `review_loop.py next` decides whether a repair round may start.
   `MAX_REPAIR_ROUNDS` is the soft cap and `MAKATO_MAX_REPAIR_ROUNDS_HARD` the hard cap; past
   the soft cap the loop goes on only while the number of new blockers keeps shrinking. A
   finding that has come back twice after repairs is escalated to a redesign (step 4), and
   one that comes back after the redesign stops the loop. There is no fixed round limit to
   check by hand.
2. **Findings and snapshot.** Retain every blocking finding as `REVIEW_FINDINGS` — with its
   stable ID, `invariant`, and `sites` — and log it. Capture `PRE_REPAIR_SNAPSHOT` and set
   `REPAIR_ROUND` to `repair_rounds + 1`.
3. **Background full pass.** From round 2, when the helper asks for it: review
   `PRE_REPAIR_SNAPSHOT` in full, in a separate checkout, while the coder repairs.
4. **Design pre-check.** Only for a CRITICAL finding or one that already came back twice: the
   `coder` plans (`REPAIR_PHASE: plan`) and the `diff-reviewer` approves or sends the plans
   back (`REVIEW_MODE: repair-plan`). It consumes no repair round.
5. **Partition and apply.** File-disjoint finding groups; one **`coder` in review-repair mode**
   per group, in parallel — not the reviewer and not a new planning cycle — each repairing the
   invariant on every site of its findings.
6. **Validate** every coder R1: per-finding details that agree with the tree, accounting for
   every site, and edits that stay inside the coder's partition.
7. **Record the repair, then re-review it.** Coder success is **not** review approval. Run
   Step 3 (its mechanical changes belong to the repair), measure the repair with
   `review_scope.py delta`, ask `decide --event repaired` for the scope, and dispatch Step 4
   on the repaired tree. This independent re-review completes the repair round.
8. **Finish the background pass.** Merge it without this round's finding IDs, record the
   coverage with `decide --event background-full`, and release its checkout.
9. **Open blockers.** The blocking IDs of the re-review plus those of the background pass.
   None open: continue with the zero-findings flow below. Otherwise they become the next
   `REVIEW_FINDINGS` and the round restarts at step 1.

When step 1 returns `continue:false`, fail closed: return R1 `failure` with
`data.repair_rounds`, `data.repair_rounds_exhausted:true`, `data.exhaustion_reason`
(`recurring_finding`, `hard_cap`, or `not_converging`), and the unresolved findings in
`errors`, and log `step:"repair-loop"`, `status:"error"` (the entry is in the reference).
If a coder cannot complete a repair or its verification, return a non-success R1 containing
the unresolved findings and the concrete blocker, and log terminal `step:"session"`,
`status:"error"`; never emit a clean result or advance to verify/push.

The loop continues until a complete merged R1 reports `status:"success"`,
`critical_count == 0`, and `major_count == 0`, with no background blocker open.
SUGGESTION and NITPICK do not trigger repairs. No `major-autofix` bypass entry is emitted:
both modes require the same action, so no human approval gate is being bypassed.

**If zero blocking findings on the first pass:**
Use the merge-base-to-working-tree diff (`git diff "$REVIEW_BASE" --stat`) and the
untracked additions for the changed-LOC count. For diffs ≤ 50 LOC a clean first pass
is plausible, but the citation record still applies. For larger diffs, perform a
source-anchored recheck:
for every changed file, produce a citation record confirming it is clean:

```
file: <path>:<line-range> | concern: <what was checked> | verdict: clean | evidence: <exact code or line reference>
```

Every changed file must have a citation. A file without one is not reviewed — go back
and read it. *"Reviewed and found nothing"* is not acceptable evidence.

Log:
```
{"ts":"<ISO8601>","skill":"build-review","story":"<key>","step":"zero-findings-recheck","status":"start","data":{"files_to_cite":<N>}}
{"ts":"<ISO8601>","skill":"build-review","story":"<key>","step":"zero-findings-recheck","status":"ok","data":{"files_cited":<N>}}
```

Return to Step 4 if the source-anchored recheck surfaces new findings.

**If a pass after one or more repairs returns zero blocking findings — decide the scope:**

A pass is clean only when round step 9 of `references/review-loop.md` finds no open
blocker — neither in the re-review nor in that round's background pass. A clean `delta`
pass proves the repair is sound, not that the change is. Ask the helper what must happen
before proceeding:

```bash
python3 "$MAKATO_BUILD_ROOT/shared/review_scope.py" decide --event clean \
  --last-scope "$last_scope" --full-since-repair "$full_since_repair" --repair-rounds "$repair_rounds"
```

- `next:"done"` — a full-scope review has covered the tree since its last repair (a completed background full pass counts); continue.
- `next:"final-full"` — dispatch Step 4 with `REVIEW_SCOPE: full` (incremented pass counter, refreshed `CHANGED_FILES`, empty `PRIOR_FINDINGS`, no `REPAIR_DELTA`; lens-split like any full pass and merged with `--scope final-full`). This is the single pass that certifies the whole tree after repairs; log `step:"final-full-pass"`, `status:"start"`/`"ok"`. Blocking findings from it enter the repair round in `references/review-loop.md` like any other: they consume a repair round, the convergence caps apply, and their repair is delta-reviewed.

Log each decision: `{"skill":"build-review","story":"<key>","step":"scope-decision","status":"ok","data":{"pass":<N>,"event":"clean","next":"<done|final-full>","reason":"…"}}`.

**Only a complete review with zero CRITICAL and zero MAJOR findings may proceed.**
After the first-pass recheck (when required), continue to Step 5.5.

---

### Step 5.5 — Final mechanical pass

Re-apply Step 3 after the blocking loop, taking a snapshot first
(`review_scope.py snapshot`, as in round step 2 of `references/review-loop.md`). If Step 3 changes any file,
measure it with `review_scope.py delta`, ask `decide --event mechanical` (it returns
`delta`), increment the reviewer pass counter, and return to Step 4 with that
`REPAIR_DELTA`; when that pass is clean, ask `decide --event clean` again — a formatter-only
change after a full pass does not trigger another full pass. This mechanical re-pass
and its reviewer re-dispatch do not increment `repair_rounds` or consume a coder repair
round. Only a coder repair dispatch starts a repair round. Only an unchanged
mechanical pass permits persisting Step 4a's verdicts and proceeding to Step 6.

Log:
```
{"ts":"<ISO8601>","skill":"build-review","story":"<key>","step":"mechanical-fixes-post","status":"ok","data":{"fixes_applied":<N>}}
```

---

### Step 6 — Present final report and hand off

Present the clean-run findings to the user:

- **CRITICAL and MAJOR findings** — list the verified repairs and pass count. Both
  open counts must be zero. Any surviving or regressed finding returns to Step 5.
- **SUGGESTION findings** — list with file, line, description. The user may address these
  before `/verify` if desired; they do not block.
- **NITPICK findings** — list with file, line, description. Purely informational.

Run:

```bash
"$MAKATO_BUILD_ROOT/shared/build-log.sh" "<key>" '{"ts":"<ISO8601>","skill":"build-review","story":"<key>","step":"session","status":"ok","data":{"passes":<N>,"full_passes":<N>,"delta_passes":<N>,"background_passes":<N>,"lens_split_passes":<N>,"repair_plan_reviews":<N>,"criticals_fixed":<N>,"majors_fixed":<N>,"criticals_open":0,"majors_open":0,"suggestions":<N>,"nitpicks":<N>}}'
```

`passes`, `full_passes`, and `delta_passes` count live-tree review passes; a lens-split pass
is one pass. `background_passes` counts completed background full passes, `lens_split_passes`
counts full-scope passes (live or background) merged from more than one lens reviewer, and
`repair_plan_reviews` counts `diff-reviewer` dispatches in `REVIEW_MODE: repair-plan`.

Tell the user:
*"\<N\> criticals and \<N\> majors fixed across \<N\> passes. No blocking findings remain. \<N\> suggestions and \<N\> nitpicks noted above.*
*Pipeline remaining: `/build-verify` → `/build-push-to-git` → `/build-create-pr`*
*Next: run `/build-verify` to confirm all quality gates pass."*

Return the R1 envelope from `$MAKATO_BUILD_ROOT/agents/RETURN-CONTRACT.md` with `agent:"build-review"`,
`status:"success"`, accumulated `files_changed`/`tests_written`, `errors:[]`,
and `data:{passes,full_passes,delta_passes,background_passes,lens_split_passes,repair_plan_reviews,critical_count:0,major_count:0}`. A caller must not infer success
from a prose report or a coder result.

---

## Anti-patterns

### NEVER diff against bare local `main` — WHY: PR-bleed

Diff against the merge-base with the fetched integration target, not the local branch
tip. Include working-tree repairs and untracked files; reviewing `HEAD` alone repeatedly
reviews the old bug and misses the uncommitted fix.

### NEVER commit during this skill — WHY: atomic-commit model

`/build-push-to-git` owns the commit step. Each commit must map to exactly one plan task and carry a conventional commit message derived from the plan. Ad-hoc commits during review produce un-attributable changesets that bisect incorrectly and confuse the post-merge documentation-agent that reads `build.jsonl` to reconstruct the session.

### NEVER accept "reviewed and found nothing" without source-anchored citations — WHY: non-falsifiable claim

Zero findings on a > 50 LOC diff without per-file citation records is not evidence of correctness — it is evidence of a passive scan. The citation format (`file:path:range | concern | verdict: clean | evidence: code line`) forces an active verification act: you must name the concern you looked for and quote the code that addresses it. A file without a citation is not reviewed; go back and read it.

### NEVER re-evaluate `ac_verdicts` in this skill or in `build-create-pr` — WHY: chain integrity

`diff-reviewer` is the only agent that reads both the diff AND the acceptance criteria simultaneously with the adversarial lens. Re-evaluating verdicts here or in `build-create-pr` uses only partial context (e.g., no diff, or no AC text) and silently diverges from the diff-reviewer's reasoning. The downstream `documentation-agent` in `makato-orchestrate` uses `build.jsonl` as the authoritative verdict source to flip Issue checkboxes; a re-evaluated verdict that contradicts the diff-reviewer's corrupts the audit trail irrecoverably.

### NEVER downgrade a correctness concern to SUGGESTION to avoid blocking — WHY: silent PR escape

SUGGESTION and NITPICK are informational in both modes. Anything touching correctness,
security, or a real failure path is MAJOR or CRITICAL and must enter the coder repair
loop. See `references/review-criteria.md` for the classification boundary.

### NEVER accept a clean delta pass as approval — WHY: delta review cannot see unrelated defects

A delta pass re-reads the repair and its neighbours. A defect the repair did not touch is invisible to it by construction, so a clean delta pass followed by proceeding would turn a cost control into a coverage hole. The `final-full` decision from `review_scope.py decide` exists to close it; obey it.

### NEVER build the repair delta from `git diff` — WHY: repairs are uncommitted

Coder repairs and mechanical fixes stay in the working tree beside the original implementation, so `git diff "$REVIEW_BASE"` shows both and `git diff HEAD` shows the whole implementation. `review_scope.py snapshot` / `delta` compare two exact working-tree states with a throw-away index and never touch the real index or working tree.

### NEVER treat a background finding for an id repaired this round as open — WHY: it describes the pre-repair tree

The background pass reviews `PRE_REPAIR_SNAPSHOT`, which still holds the defect the coder is fixing in the same round. Merge it with `--drop-ids` set to this round's `REVIEW_FINDINGS` IDs, so those findings — and any finding within three lines of their recorded sites — are dropped; counting them as open sends a fixed defect back to the coder and burns a repair round on a ghost. What survives the drop is a real blocker of the pre-repair tree: it joins the next round's `REVIEW_FINDINGS`, and if the repair happened to fix it, the coder reports it `already resolved` instead of editing.
