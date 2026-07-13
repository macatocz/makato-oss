# Test Baseline Guide

## Scope

This guide is about **what to do once the test command is known** — record
pre-existing failure counts, decide whether the baseline is broken, and how to
log the decision. It is intentionally **not** a discovery algorithm: discovering
the project's unit-test command is `gate-scout`'s job (`agents/gate-scout.md`),
dispatched by every consuming skill (`build-simplify`, `build-implement-tdd`,
`build-implement-goal`, `build-verify`). If you arrived here looking for "how
do I find the test command on this repo", see `gate-scout.md` Step 1–2 — this
file does not duplicate that map (#97).

## Purpose

Establishing a test baseline before any code changes ensures this session's failures are
distinguishable from pre-existing ones. The contract: zero **new** failures introduced.
Pre-existing failures are not this session's responsibility.

## How to Establish the Baseline

Run the full existing test suite. Record the count of passing and failing tests.

If the test environment is unrunnable (build fails, test runner crashes, missing deps):
stop and report. Do not proceed without a working baseline.

## Broken Baseline Gate

If `pre_existing_failures > 0`, do not silently proceed. Present the user with a choice:

> "`<N>` pre-existing test failure(s) detected.
>
> **(A) Continue with broken baseline** — new failures will be tracked separately against
> this count. Any new failure introduced by this session must be fixed before completion.
> **(B) Fix baseline first** — pause this session; fix the pre-existing failures, re-run
> the suite, then restart this step."

Wait for the user's choice. If (B): stop here. If (A): continue, tracking new failures
as `current_failures - pre_existing_failures` throughout the session.

## Logging

Minimum log entries:

```
{"ts":"…","skill":"<skill>","story":"<key>","step":"baseline","status":"ok","data":{"pre_existing_failures":<N>,"baseline_mode":"<proceed|halted>"}}
```

If `pre_existing_failures > 0` and user chose continue:
```
{"ts":"…","skill":"<skill>","story":"<key>","step":"baseline-gate","status":"decision","data":{"pre_existing_failures":<N>,"user_choice":"continue"}}
```

For skills that only track pass/fail count (not the broken baseline gate):
```
{"ts":"…","skill":"<skill>","story":"<key>","step":"baseline","status":"ok","data":{"passing":<N>,"failing":<N>}}
```

## New Failure Check

Throughout the session, when comparing test results to baseline:
- New failures = current failure count − pre_existing_failures
- Zero new failures is the gate at each VERIFY step
- A simplification or fix that introduces even one new failure must be reverted before proceeding

Cross-task sweep: the outer loop in `build-implement-tdd` Step 6 applies the same `current_failures − pre_existing_failures == 0` gate to the accumulated prior-task test set after each task. See `build-implement-tdd/SKILL.md` § *Cross-task regression sweep*.
