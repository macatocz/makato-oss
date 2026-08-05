# promote-ready — Operator Recovery Reference

Load this file when a TOCTOU skip is observed during a batch promotion run, or
when deciding whether to re-run after a partial batch. Not needed for read-only
`plan` / `--dry-run` invocations.

---

## TOCTOU Skip Recovery Decision Tree

A TOCTOU skip fires when a board item moved off `Todo`/`Blocked` between the
plan snapshot and the `item-edit` write. The skip is printed as:

```
SKIP #<n> <slug>: status changed to <new-status> since snapshot — not promoting
```

**Is the new status `Ready` or higher (`In progress` / `In review` / `Done`)?**

- **Yes → nothing to do.** The item is already correctly positioned. The
  concurrent mover (another promote-ready run, `loop`, or `sync-lifecycle`) won
  the race, and the board is correct. Re-running is safe but will produce the
  same skip.

- **No (status is `Blocked` or `Todo` again after the snapshot window)** → This
  is unexpected. Check `loop run --status` / `gh project item-list` to confirm
  the current status. If it is genuinely back to `Todo`/`Blocked`, re-running
  promote-ready is safe — it will re-snapshot and re-promote.

**Is re-running immediately safe after any skip?**

Yes. The script is fully idempotent:

- Items already at `Ready`/`In progress`/`In review`/`Done` are forward-only
  skipped.
- Items still at `Todo`/`Blocked` that were skipped due to a TOCTOU race are
  re-evaluated against the fresh board snapshot.
- No partial state is left on disk or on the board from a skipped item.

The only reason to wait before re-running is if you are trying to promote the
**next wave** — for that, wait until the current wave's PRs merge and their
board Status flips to `Done` (see Wave Sequencing below).

---

## Partial Batch Recovery

A batch is "partial" when some items in the recommended wave were promoted and
some were TOCTOU-skipped.

**To check if a partial batch completed correctly:**

```bash
# See which items in the plan are now at Ready (promoted) vs still at Todo/Blocked
plugins/makato-orchestrate/scripts/promote-ready.sh plan <slug>
```

- Items that appear in `Already progressing (skipped)` were promoted (or
  claimed by loop) — they are correctly positioned.
- Items that still appear in `Wave 0 → promote now` were skipped — safe to
  promote by re-running with `--yes`.

**Re-run is always safe.** The forward-only guard means a re-run never rolls
back an item that was successfully promoted in the partial batch.

---

## Wave Sequencing Decision Tree

Use this when deciding whether to promote the next dependency wave.

**Can the next wave be promoted now?**

1. Check that **every issue in the current wave** has Status = `Done` on the
   board (i.e., its PR merged and `sync-lifecycle` or `documentation-agent`
   advanced it to Done).

   ```bash
   plugins/makato-orchestrate/scripts/promote-ready.sh plan <slug>
   ```

   If Wave 0 still shows items in `Ready` / `In progress` / `In review`, they
   are still in flight — **do not promote Wave 1 yet.** `loop` is single-threaded
   per worktree; lengthening the queue is safe, but items whose dependencies
   are not actually `Done` will fail their acceptance criteria at PR time.

2. If Wave 0 is fully `Done`, re-run:

   ```bash
   plugins/makato-orchestrate/scripts/promote-ready.sh run <slug> --yes
   ```

   The script will now surface Wave 1 (formerly blocked) as the new `promote
   now` set and leave Wave 2+ still in `Blocked`/`Todo`.

**What if `loop` is running and I re-promote?**

Adding items to `Ready` only lengthens the `loop` queue — it is safe. `loop` is
FIFO single-threaded, so the new `Ready` items will be picked up after the
currently `In progress` item completes. The board CAS claim prevents double-dispatch.

**What if a wave has zero items after re-promotion?**

This happens when all remaining issues were either TOCTOU-claimed by `loop`
already or are still blocked by an unfiled upstream story. Run
`plan --json | jq '.blocked'` to inspect blockers. For unfiled story blockers,
the issue must be filed (via `to-issues` or manually) and stamped `status:ready-for-dev`
before it can be unblocked.
