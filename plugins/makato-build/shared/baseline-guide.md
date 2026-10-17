# Test Baseline Guide

## Scope

This guide is about what to do once the unit-test command is known: record
pre-existing failure identities, decide whether the baseline is broken, and
log the decision. It is intentionally not a discovery algorithm: `gate-scout`
discovers the command (`agents/gate-scout.md`), dispatched by the consuming
implementation and verification skills (`build-implement-tdd`,
`build-implement-goal`, `build-verify`). `build-simplify` uses gate-scout only
to discover the command for targeted verification; it does not load this guide
or run a baseline suite.

## Purpose

Establishing a test baseline before any code changes ensures this session's failures are
distinguishable from pre-existing ones. The contract: zero **new** failures introduced.
Pre-existing failures are not this session's responsibility.

**CI recovery exception:** when `CI_FAILURES` is supplied, load
`$MAKATO_BUILD_ROOT/shared/ci-recovery.md`. The identified failures are repair
obligations, even if compilation currently fails; do not prompt to accept them
as pre-existing or subtract them from the completion gate. Compare failure
identities as well as counts, and retain real environment/permission blockers.

## How to Establish or Reuse the Baseline

A branch base has one fresh baseline; later implementation passes reuse it.

Before running tests, read this spec folder's `build.jsonl`. Set
`DEFAULT_REF="$("$MAKATO_BUILD_ROOT/shared/default-branch.sh")"`, get the
current branch name, and compute
`base_sha="$(git merge-base HEAD "$DEFAULT_REF")"`.

Find the latest `step:"baseline", status:"ok"` row from either
`build-implement-tdd` or `build-implement-goal`. If it has the same `branch`
and `base_sha`, a `failures` array, and `baseline_mode:"proceed"`, reuse it
instead of running tests: copy its `failures`, `pre_existing_failures`, and
`cmd`, record `reused:true`, and set `source_ts` to that row's `ts`. Otherwise
(no such row, a different base, or a `"halted"` row) run gate-scout's exact
`unit` command once and record its failing test IDs in `failures`, with
`pre_existing_failures` equal to that array's length, `reused:false`, and
`source_ts:null`. Never replace a reusable baseline with a later run: the
baseline describes the branch base, and a run over this branch's changes would
absorb earlier passes' regressions into the pre-existing set.

## Broken Baseline Gate

The gate runs only after a fresh baseline run. If `pre_existing_failures > 0`,
present the user with a choice:

> "`<N>` pre-existing test failure(s) detected.
>
> **(A) Continue with broken baseline** — new failures will be tracked by
> test identity against this failure set. Any new failure introduced by this
> session must be fixed before completion.
> **(B) Fix baseline first** — pause this session; fix the pre-existing failures,
> re-run the unit command, then restart this step."

Autonomous mode proceeds on a fresh broken baseline. Record the resulting mode
as `baseline_mode:"proceed"` or `"halted"`. A reused row is not a fresh run:
do not repeat the gate; continue with `baseline_mode:"proceed"`.

## Logging

Every `baseline` row from `build-implement-tdd` or `build-implement-goal`
includes:

```
{"ts":"…","skill":"<skill>","story":"<key>","step":"baseline","status":"ok","data":{"pre_existing_failures":<N>,"failures":["<test id>",...],"branch":"<git branch>","base_sha":"<git merge-base HEAD $DEFAULT_REF>","cmd":"<exact unit command>","reused":<bool>,"source_ts":"<source row ts>"|null,"baseline_mode":"<proceed|halted>"}}
```

The `failures` array is the baseline failure set; `pre_existing_failures` is
its size. `source_ts` is the timestamp of the baseline row whose failures were
reused, or `null` when this row ran the command.

## New Failure Check

For each targeted verification run, compare failed test identities with
`BASELINE_FAILURES` (the row's `data.failures`), not aggregate failure counts.
A selected test failing outside that baseline failure set is a new failure.
Zero new failures in the selected tests is the gate. A simplification or fix
that introduces even one new failure must be reverted before proceeding.
