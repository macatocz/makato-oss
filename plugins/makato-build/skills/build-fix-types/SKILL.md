---
name: build-fix-types
description: >-
  Per-finding decision tree that resolves Python type errors reported by pyright or
  mypy via 6 ranked branches — narrow, annotate, TypeVar/Generic, Protocol, cast,
  type:ignore-with-justification. Dispatched by build-resolve-finding for any
  `pyright:*` or `mypy:*` finding routed here in `shared/finding-routes.json`.
  Never invoked directly by the user. Trigger keywords: pyright, mypy, type error,
  reportOptionalMemberAccess, union-attr, no-untyped-def, finding-routes.json.
version: "1.3.0"
argument-hint: "<finding-json>"
tools: Read, Edit, Bash
metadata:
  authors: ["makato-build"]
  last_updated: "2026-08-05"
---

# build-fix-types

## 1. Overview

This skill is the **type-error repair engine** invoked by `build-resolve-finding` whenever
a pyright or mypy finding is routed here through
`$MAKATO_BUILD_ROOT/shared/finding-routes.json`.
It receives a single normalized finding, classifies it into one of six fix branches,
loads the branch reference, applies the code edit in place, and returns a structured outcome.

The six branches, **ordered from least invasive to most invasive**:

| # | Name | Invasiveness | When |
|---|------|-------------|------|
| 1 | Narrow | Low | Union is wider than needed; add guard |
| 2 | Annotate | Low | Missing or wrong type annotation |
| 3 | TypeVar/Generic | Medium | Function polymorphic across unrelated types |
| 4 | Protocol | Medium | Structural subtyping / duck-typed interface |
| 5 | cast | Medium-High | Type provably correct but checker can't infer |
| 6 | type: ignore | High | Stub absent; no other branch applies |

**Knowledge of which branch fits which error lives here (Section 3) — never in
`build-resolve-finding`.** The orchestrator only dispatches; this skill decides and acts.

## 2. Inputs

The caller passes a single finding object (canonical shape from
[`shared/finding-schema.md`](../../shared/finding-schema.md)):

The caller also supplies `MAKATO_BUILD_ROOT`, the absolute installed
makato-build plugin root. Use it for suite-owned helpers and references; do
not resolve helpers from the consumer repository's current directory.

Optional `CI_CONTEXT` activates the caller's strict CI-recovery policy before
classification: load `$MAKATO_BUILD_ROOT/shared/ci-recovery.md`. Branch 6 ignores,
checker suppression/config weakening and carry-over are forbidden in this mode.
Use a genuine safe repair from branches 1–5 and re-run the originating check;
if none applies, return `status:"error", fix_applied:false` with the concrete
blocker. Ordinary sensor mode retains the classification policy below.

```json
{
  "tool": "pyright | mypy",
  "rule": "<rule id, e.g. reportOptionalMemberAccess, union-attr>",
  "path": "<repo-relative file path>",
  "line": 123,
  "message": "<verbatim sensor message>",
  "severity": "low | medium | high | critical",
  "autofix_available": false,
  "repo_root": "/abs/path/to/repo",
  "attempt": 1,
  "model_override": null
}
```

`autofix_available` is always `false` for findings reaching this skill — type checkers do
not provide automated fixes. `attempt` increments on retry. `model_override` is reserved/inert
(#287): this skill runs under the Skill tool which has no `model` parameter.

## 3. Classification (Step 1)

Match the finding's `(tool, rule, message keywords)` against the dispatch table.
The first row that matches wins.

**If no row matches:** return `status: "error"` with `fix_applied: false`. Log a `decision`
entry naming the unmatched `(tool, rule)`. The caller escalates to carry-over for human review.
Never apply Branch 6 for an unrecognized code — see "No match" below.

**After matching:** look up the rule in Section 3a and set `finding.repair_hint` when a
mapping exists. Leave the field absent (not `null`, not `""`) when no mapping exists.

**After classifying:** load the matching branch reference file before proceeding to Step 2.
The reference contains the fix patterns, decision tree, and escalation logic for that branch.
Do NOT load reference files for branches you are not executing.

### Pyright codes

| Rule | Message keyword | Branch | Reason |
|------|-----------------|--------|--------|
| `reportOptionalMemberAccess` | — | 1 (Narrow) | Member access on `T \| None` |
| `reportOptionalSubscript` | — | 1 (Narrow) | Subscript on `T \| None` |
| `reportPossiblyUnbound` | — | 1 (Narrow) | Variable may be unbound on some path |
| `reportMissingReturnType` | — | 2 (Annotate) | Return type omitted |
| `reportMissingParameterType` | — | 2 (Annotate) | Parameter type omitted |
| `reportReturnType` | — | 2 (Annotate) | Return annotation present but wrong |
| `reportInvalidTypeVarUse` | — | 3 (TypeVar) | Existing TypeVar misused |
| `reportArgumentType` | — | 3 (TypeVar) | Argument type mismatch — function called with incompatible type; often needs TypeVar to be genuinely polymorphic. If the function is not polymorphic, use Branch 1 or Branch 2. |
| `reportOperatorIssue` | — | 1 (Narrow) | Operator unsupported for union type — narrow first; Branch 4 (Protocol) if structural |
| `reportIndexIssue` | — | 1 (Narrow) | Subscript/index type error — narrow index or container |
| `reportIncompatibleMethodOverride` | — | 4 (Protocol) | Override signature mismatch — structural subtype |
| `reportGeneralTypeIssues` | contains `\| None` | 1 (Narrow) | Generic error with None in union |
| `reportGeneralTypeIssues` | contains `cannot infer` | 5 (cast) | Inference failure, type provable |
| `reportGeneralTypeIssues` | contains `is not assignable`, polymorphic call sites | 3 (TypeVar) | Same fn used with multiple element types |
| `reportGeneralTypeIssues` | (no keyword above) | 5 (cast) | Default for generic issues — try cast first |
| `reportUnknownMemberType` | — | 6 (ignore) | Member type from missing/wrong stubs |

### Mypy codes

| Rule | Message keyword | Branch | Reason |
|------|-----------------|--------|--------|
| `union-attr` | — | 1 (Narrow) | Attribute access on union including None |
| `optional` | — | 1 (Narrow) | Implicit Optional handling |
| `no-untyped-def` | — | 2 (Annotate) | Function definition missing annotations |
| `return-value` | annotation absent | 2 (Annotate) | No return type declared — add annotation |
| `return-value` | annotation exists but wrong | 1 (Narrow) | Return type incompatible — narrow return or fix annotation |
| `no-any-return` | — | 2 (Annotate) | Function returns Any but annotated otherwise |
| `type-var` | — | 3 (TypeVar) | TypeVar binding error |
| `override` | — | 4 (Protocol) | Method override signature mismatch |
| `assignment` | contains `cannot infer` | 5 (cast) | Inference failure |
| `assignment` | (no keyword above) | 1 (Narrow) | Most assignment errors are narrowing |
| `misc` | contains `incompatible` or `mismatch` | 4 (Protocol) | Structural subtype required |
| `import-untyped` | — | 6 (ignore) | Library has no type stubs |
| `import-not-found` | — | 6 (ignore) | Library missing entirely from stub paths |
| `attr-defined` | — | 6 (ignore) | Attribute missing from library stub |

### No match

If no row matches, return `status: "error"` with `fix_applied: false`. Log a `decision` entry
naming the unmatched `(tool, rule)`. The `mypy:*` glob in `finding-routes.json` routes all
mypy findings here; this skill covers common codes but not the full space. Carry-over is the
correct outcome for any code not in the table. **Do not apply Branch 6** for unrecognized
codes — silently suppressing an unknown type error is worse than leaving it unresolved.

## 3a. repair_hint mapping

Findings whose rule is listed below get `finding.repair_hint` set before the skill acts.
Rules absent from the table leave `repair_hint` absent. The `repair_hint` string follows the
WHAT/WHY/FIX sub-structure from [`shared/finding-schema.md`](../../shared/finding-schema.md).

**Why only 6 rules have repair_hints:** these are the rules most frequently misclassified
by the caller. The repair_hint gives the caller an early signal before the branch reference
is loaded. Rules routed unambiguously (e.g., `reportOptionalMemberAccess` always → Branch 1)
do not need a hint — the classification table is sufficient.

| Rule | repair_hint |
|------|-------------|
| `reportArgumentType` | `"WHAT: Argument type does not match the parameter's declared type.\nWHY: Passing the wrong type may cause runtime failures or silent data corruption.\nFIX: Check the function signature and either cast the value, narrow the union, or change the call site to pass a compatible type."` |
| `reportReturnType` | `"WHAT: The function's return expression does not match its declared return type.\nWHY: A wrong return annotation either lies to callers or indicates the function body returns an unexpected type.\nFIX: Tighten the annotation to match what the function actually returns, or fix the return expression."` |
| `reportOptionalMemberAccess` | `"WHAT: Attribute access on a value that may be None.\nWHY: Accessing a member on None raises AttributeError at runtime.\nFIX: Guard with 'if x is not None:' or 'assert x is not None' before the access, or change the type to non-optional."` |
| `reportPossiblyUnbound` | `"WHAT: Variable may be unbound on some code path reaching this use.\nWHY: An unbound variable raises NameError at runtime on the unguarded path.\nFIX: Initialise the variable before any conditional that might skip its assignment, or restructure the control flow."` |
| `reportMissingReturnType` | `"WHAT: Function is missing a return type annotation.\nWHY: Missing return type makes the function opaque to the type checker and callers.\nFIX: Infer the return type from the return expressions and add an explicit annotation (e.g. '-> str:', '-> None:')."` |
| `reportMissingParameterType` | `"WHAT: One or more parameters are missing type annotations.\nWHY: Unannotated parameters widen to Any, defeating type checking for the whole function.\nFIX: Add type annotations for each unannotated parameter, inferring types from call sites or doc-comments."` |

## 4. Decision Branches (Step 2)

**MANDATORY: Load the reference file for the branch you are executing before reading its fix
patterns. Do NOT load reference files for branches you are not executing.**

| Branch | Reference file | Load trigger |
|--------|---------------|--------------|
| 1 — Narrow | `references/branch-1-narrow.md` | Classification routed to Branch 1 |
| 2 — Annotate | `references/branch-2-annotate.md` | Classification routed to Branch 2 |
| 3 — TypeVar/Generic | `references/branch-3-typevar.md` | Classification routed to Branch 3 |
| 4 — Protocol | `references/branch-4-protocol.md` | Classification routed to Branch 4 |
| 5 — cast | `references/branch-5-cast.md` | Classification routed to Branch 5 |
| 6 — type: ignore | `references/branch-6-ignore.md` | Classification routed to Branch 6 OR Branch 1–5 escalation falls through |

**Do NOT Load** any branch reference file when the finding was not classified into that
branch and no escalation is in progress.

Each branch reference contains:
- The specific fix patterns with code examples
- The exact decision point between sub-patterns (e.g., `assert` vs `if`-guard in Branch 1)
- The escalation logic to the next branch when the current branch doesn't apply
- Branch-specific anti-patterns

## 5. Anti-patterns

### NEVER apply Branch 6 for an unrecognized rule code
**WHY:** `# type: ignore` on an unknown rule means you are suppressing something you don't
understand. The suppression hides the real problem and makes it invisible to future reviewers.
Carry-over forces a human to see the error and extend the classification table.

### NEVER bundle fixes for multiple findings in one edit
**WHY:** The sensor-fixer loop re-runs the type checker after each fix to confirm the error
is resolved and no new errors were introduced. Bundling makes the loop non-deterministic —
a fix for finding B may mask finding A's failure, or the combined edit may introduce a third
error that neither fix alone would produce.

### NEVER use `cast(...)` without an inline justification comment
**WHY:** `cast` is a runtime no-op. Six months later, no reviewer (human or agent) can tell
whether the cast is still correct without the justification. An unjustified cast is
indistinguishable from a lazy suppression, and gets treated as such in review.

### NEVER add a narrowing guard that changes observable runtime behavior
**WHY:** A type fix that silently changes behavior (e.g., adding `if x is None: return 0`
where the original raised `TypeError`) may break callers that depended on the exception.
This is a design change, not a type fix — escalate to `/refine` instead.

### NEVER use bare `# type: ignore` (without an error code)
**WHY:** Bare ignore suppresses every error on that line including future ones. The error-code
form `# type: ignore[attr-defined]` is re-checked when the library adds stubs — the bare
form silently stays suppressed forever and the underlying issue never resurfaces.

### NEVER read from the disk state you have in context — always re-read before editing
**WHY:** The sensor-fixer loop may dispatch multiple findings against the same file in sequence.
Each `build-fix-types` invocation is a separate agent call; the in-context file content is
from the prior read. A second fixing agent that edits from stale in-context content will
stomp the first fix. Always `Read` the file immediately before the `Edit` call.

## 6. Output Contract

Return a single JSON object to the caller:

```json
{
  "status": "ok | warn | error",
  "branch": 1,
  "file": "src/example.py",
  "line": 42,
  "fix_applied": true,
  "fix_description": "Added `assert x is not None` to narrow Optional[str]"
}
```

Field semantics:
- `status: "ok"` — fix applied via branches 1–5; expected to pass re-verification.
- `status: "warn"` — fix applied via Branch 6 (type: ignore). Flag for human review.
- `status: "error"` — could not apply any fix safely; finding escalates to carry-over.
- `branch` — integer 1–6 indicating which branch was used.
- `fix_applied` — `true` if the file was edited, `false` if the skill bailed (`status` will
  be `"error"` in that case).
- `fix_description` — one-line human-readable description of the edit.

## 7. Logging

Append JSONL entries to `specs/<story-key>/build.jsonl` via
`"$MAKATO_BUILD_ROOT/shared/build-log.sh"`; do not rely on the consumer
repository's current directory.

Required entries:

```jsonl
{"ts":"<ISO8601>","skill":"build-fix-types","story":"<key>","step":"session","status":"start","data":{"tool":"pyright","rule":"reportOptionalMemberAccess","path":"src/example.py","line":42}}
{"ts":"<ISO8601>","skill":"build-fix-types","story":"<key>","step":"classify","status":"ok","data":{"branch":1,"reason":"reportOptionalMemberAccess → Narrow"}}
{"ts":"<ISO8601>","skill":"build-fix-types","story":"<key>","step":"apply","status":"ok","data":{"file":"src/example.py","line":42,"fix_description":"Added assert"}}
{"ts":"<ISO8601>","skill":"build-fix-types","story":"<key>","step":"session","status":"ok","data":{"branch":1,"fix_applied":true}}
```

Branch 6 application additionally requires:

```jsonl
{"ts":"<ISO8601>","skill":"build-fix-types","story":"<key>","step":"suppress","status":"warn","data":{"file":"src/example.py","line":42,"error_code":"attr-defined","reason":"numpy stubs missing private_attr"}}
```

When a branch escalation occurs (e.g., Branch 1 → Branch 3), log each skipped branch:

```jsonl
{"ts":"<ISO8601>","skill":"build-fix-types","story":"<key>","step":"escalate","status":"decision","data":{"from_branch":1,"to_branch":3,"reason":"narrow not safe – widespread use"}}
```

## 8. Test Fixtures

`test-fixtures/` (sibling to this SKILL.md) contains a manually verifiable recipe to confirm
routing and branch coverage:

- `type-error-sample.py` — four intentional violations covering Branches 1, 2, 3, 6.
- `test-fixtures/README.md` — manual route-verification recipe using `jq` against
  `shared/finding-routes.json`; end-to-end smoke test procedure (lands with issue #58).

Branches 4 (Protocol) and 5 (cast) have no fixture functions — their real-world triggers
require an override mismatch with a concrete base class or a specific inference-failure context
impractical to produce without a full type stub setup.

## 9. When to Use

Dispatched by `build-resolve-finding` Branch 2 (tech-skill route) for any finding matching
`pyright:*` or `mypy:*` in `shared/finding-routes.json`. **Not invoked directly by the user.**
If a user types `/build-fix-types`, respond with:

> "This skill is the per-finding type-error engine dispatched by `build-resolve-finding`.
> It is not invoked directly. To trigger it, run `/build-sensors` against a branch with
> pyright/mypy violations, or pass a finding JSON via `build-resolve-finding`."
