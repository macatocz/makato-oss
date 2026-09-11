---
name: build-grill-with-docs
description: Align implementation plan terminology to the codebase domain model — grill plan, terminology conflicts, glossary.md enrichment, ADR decisions. Use after /refine, before /implement-tdd or /implement-goal. Optional but recommended for complex stories.
version: "1.5.0"
modelRole: advisor
argument-hint: "[work-item-key]"
allowed-tools: [Bash]
metadata:
  Authors: makato-build team
  last_updated: "2026-08-05"
---

## When to Use

Use after `/refine` (plan.md exists) and before `/implement-tdd` or `/implement-goal`. The implementation plan is in place but may contain spec-language that doesn't match how the codebase actually names things. This skill probes those mismatches and enriches the feature `glossary.md` (produced by `/makato-plan:stress-test-artifact`) with codebase name annotations before any code is written.

**Do NOT use** as a substitute for `/refine` (this skill does not produce an implementation plan) or as a substitute for `/makato-plan:stress-test-artifact` (that skill stress-tests spec artifacts and owns the canonical domain vocabulary; this one maps that vocabulary to live code symbols).

**Do NOT use** on a greenfield service with no existing codebase to probe — the skill's entire value comes from comparing spec language to live code symbols. With no code to search, every proposed term is an unverifiable assumption, not a codebase alignment.

## Workflow

This skill is a terminology/alignment pass, not a quality gate. Do not run the
target project's full test suite while probing symbols. Test execution belongs
to `build-start`, implementation, and `build-verify`, which obtain the
authoritative gate-scout command map and runner prefix.

### Step 1 — Resolve work item, load glossary, locate ADR path

Ask: *"Which work item are we aligning? (e.g. DCP-1234)"* — or use the passed argument.

Resolve `MAKATO_BUILD_ROOT` from the runner plugin-root variables and resolve
`SPEC_FOLDER` with
`python3 "$MAKATO_BUILD_ROOT/shared/spec_folder.py" "$REPO_ROOT" "<key>"`.
Read `plan.md` from that folder (required). If missing, stop:

> "Run `/refine` first — `plan.md` is required."

Read `prd.md`, `design.md`, `decisions.md` from the resolved spec folder if they exist.

Load `glossary.md` from the resolved spec folder as baseline if present — this is the feature vocabulary written by `/makato-plan:stress-test-artifact`. Terms already there are established: do not re-ask their meaning unless a codebase probe reveals a conflict. If `glossary.md` does not exist it will be created in Step 6.

**ADR path lookup** — load `@references/adr-criteria.md` for the probe order. Do NOT load this reference before reaching this step. Scan the primary repo root and use the first match. If none found, present the following numbered options to the user:

```
1. Create docs/governance/adr/ and write ADRs there
2. Skip ADRs for this story — capture decisions in decisions.md only
```

Wait for the user's numbered choice before continuing. Record the resolved path (or `skip`).

**ADR fallback**: if the user chooses to skip or the ADR directory cannot be created, do not silently drop ADR-worthy decisions. For each decision that meets the ADR criteria (Step 7), append it to `decisions.md` in the resolved spec folder with an `[ADR-PENDING]` marker and a note: `(ADR path unresolved — promote to ADR when directory is available)`. This preserves the decision for future promotion without blocking the session.

**Complexity check** — Assess complexity by counting tasks and architectural layers from the plan. Note the overall complexity level (>7 tasks, >8 file targets, or >3 spec files flags high complexity) and proceed with enhanced attention to alignment depth.

---

### Step 2 — Log session start

Run:

```bash
"$MAKATO_BUILD_ROOT/shared/build-log.sh" "<key>" '{"ts":"<ISO8601>","skill":"build-grill-with-docs","story":"<key>","step":"session","status":"start","data":{"has_glossary":true|false,"adr_path":"<path>|skip"}}'
```

---

### Step 3 — Inventory domain terms from plan + spec

Scan `plan.md` and spec artifacts for domain-specific nouns: entities, states, actions, relationships. Build a candidate list. Skip any term already present in `glossary.md` with no codebase conflict detected — it is already established. Do not ask the user about it again.

Dispatch the `knowledge-scout` agent with REPO_ROOT (the target codebase root), REPO_NAME (last path segment of REPO_ROOT), and the candidate term list as KEYWORDS. This is best-effort — proceed normally if the agent returns `loaded: false`.

If the agent returns findings: inject any `## Hard Constraints`, `## Standards`, and learnings-based findings as additional conflict evidence in the candidate list. A term already documented as resolved in `learnings/` does not need to be raised in the alignment interview — mark it as confirmed and note the source. Only re-raise a learnings/-confirmed term if fresh codebase evidence directly contradicts the learnings/ record.

---

### Step 4 — Probe codebase for canonical names

For each candidate term, search the codebase: class names, field names, enum values, table/column names, API path segments, method names. Build a conflict map: *spec term → codebase term(s)*. Flag conflicts and synonyms. Mark confirmed clean matches.

**Multi-symbol mapping**: when a spec term resolves to two or more distinct codebase symbols (e.g., `Payment` → `PaymentIntent`, `PaymentMethod`, `PaymentRecord`), do NOT collapse to the nearest match. List all candidate symbols separately in the conflict map and flag the spec term as underspecified. The spec term may represent multiple domain concepts that were conflated under one name in the plan — each must be explicitly disambiguated in the alignment interview (Step 5), not guessed here.

If codebase exploration answers a question outright, record the answer and skip asking the user.

Load `@references/context-md-format.md` — the format all resolved terms will use when writing glossary entries. Do NOT load this reference before Step 4; it is only needed when writing entries in Steps 5–6.

---

### Step 5 — Conduct alignment interview

Number every question (Q1, Q2…). For each conflict or ambiguity: state the conflict, surface the codebase evidence, propose a canonical resolution, wait for confirmation. Resolve depth-first — exhaust each branch before moving to the next topic.

- Record each resolved term immediately (do not batch).
- Stress-test with edge cases when a term's boundary is unclear.
- If the user says "skip": park as open question, move on.

**When the user disagrees with the proposed canonical term:**
1. Ask for their preferred term.
2. Check whether that preferred term conflicts with another codebase symbol found in Step 4. If yes, surface the conflict before accepting.
3. Accept the user's choice — they own the domain vocabulary.
4. Record the divergence in `decisions.md`: `(canonical term '<user-term>' chosen by user; codebase symbol is '<original symbol>')`.

**When the same spec term is used differently across subsystems** (e.g., `Account` means `UserAccount` in the auth module and `BillingAccount` in the payments module): this is system-level naming debt, not a feature-level alignment gap. Document the divergent usage in `decisions.md` with an explicit note. Do not attempt to resolve it in this session — cross-module renaming requires coordination beyond this skill's scope.

---

### Step 6 — Enrich glossary.md

Write to `glossary.md` in the resolved spec folder. Lazy-create the file with the makato-plan header format if it doesn't exist:

```markdown
# {Feature name} — Glossary

Feature-scoped vocabulary for this story. Domain terms from shaping; codebase mappings from /grill-with-docs.

## Language

## Relationships

## Flagged ambiguities
```

For **existing entries** (from `/makato-plan:stress-test-artifact`): add a `_Code_: <symbol>` line when the codebase name differs from the canonical term. If the codebase matches the canonical term exactly, leave the entry unchanged.

For **new terms** not yet in `glossary.md`: append a full entry under `## Language` following the format from `@references/context-md-format.md`.

Do not overwrite or rewrite existing definitions — only add `_Code_:` annotations and new entries. The audit trail for revisions lives in `decisions.md`, not in `glossary.md`. Exception: if a codebase probe proves an entry is factually wrong, note the correction reason in `decisions.md` first, then update the entry.

---

### Step 7 — Route decisions: decisions.md vs ADR

Load `@references/adr-criteria.md`. Do NOT reload if already loaded in Step 1 — use the same loaded instance. Load `@templates/adr.md` only when writing a new ADR file — do NOT load it speculatively before confirming an ADR is warranted.

For each decision surfaced during the interview, apply the three-criteria test and routing rule from `adr-criteria.md`. Present each proposed ADR to the user before writing. Skip this step entirely if the ADR path resolved to `skip` in Step 1.

**After routing each decision** (whether written to an ADR file, appended to
`decisions.md`, or marked `[ADR-PENDING]`), check for
`workflow-state-*.json` under `SPEC_FOLDER`. Only perform the best-effort
append when `MAKATO_ORCHESTRATE_ROOT` is supplied; otherwise record
`decisions_persisted_to_state: 0` and continue without probing the consumer
repository:

```bash
# Find all per-issue workflow-state files for this KEY
WS_FILES=""
if [[ -n "${MAKATO_ORCHESTRATE_ROOT:-}" ]]; then
  WS_FILES="$(ls "$SPEC_FOLDER"/workflow-state-*.json 2>/dev/null || true)"
fi

if [[ -n "$WS_FILES" ]]; then
  for WS_FILE in $WS_FILES; do
    # Derive ISSUE_NUMBER from the filename (workflow-state-<N>.json)
    ISSUE_NUMBER="${WS_FILE##*workflow-state-}"
    ISSUE_NUMBER="${ISSUE_NUMBER%.json}"
    SPEC_KEY="$(basename "$(dirname "$WS_FILE")")"
    "$MAKATO_ORCHESTRATE_ROOT/shared/workflow-state.sh" append-decision \
      "$SPEC_KEY" "$ISSUE_NUMBER" \
      "$(jq -n \
        --arg title "<decision title>" \
        --arg chosen "<chosen approach>" \
        --argjson rejected '["<alt1>","<alt2>"]' \
        --arg rationale "<rationale>" \
        --arg source "<adr-file-path or decisions.md>" \
        '{title:$title, chosen:$chosen, rejected:$rejected, rationale:$rationale, source:$source}')" \
      2>/dev/null || true  # best-effort: never block the session on a state write
  done
fi
```

Replace `<decision title>`, `<chosen approach>`, `<rejected alternatives>`, `<rationale>`, and `<source>` with the actual values from the decision just routed. The `rejected` array may be empty (`[]`) when no alternatives were considered. The `source` field should be the ADR file path (e.g., `docs/governance/adr/adr-001.md`) or `decisions.md` as applicable.

**This write is best-effort.** A failed `append-decision` call (missing workflow-state, schema version mismatch, jq error) MUST NOT block the session or abort Step 7. Log a brief inline note if the write fails, then continue to the next decision. The `workflow-state.json` write is a convenience; the ADR file or `decisions.md` entry is the primary record.

---

### Step 8 — Log session end and hand off

Run:

```bash
"$MAKATO_BUILD_ROOT/shared/build-log.sh" "<key>" '{"ts":"<ISO8601>","skill":"build-grill-with-docs","story":"<key>","step":"session","status":"ok","data":{"terms_resolved":<N>,"terms_skipped":<M>,"adrs_written":<K>,"decisions_updated":<J>,"decisions_persisted_to_state":<P>}}'
```

`decisions_persisted_to_state` is the count of decisions successfully written to `workflow-state.json` via `append-decision` in Step 7. Zero is a valid value when no workflow-state file exists for the KEY or all writes failed.

Tell the user: *"Alignment complete. `glossary.md` enriched with `<N>` terms. Next: `/implement-tdd` or `/implement-goal`."*

---

## Anti-patterns

**NEVER run without `plan.md` present.** WHY: without the implementation plan there is no specification to align against; the interview generates conflicts anchored to shaping artifacts alone, not to what will actually be built. The result: wrong canonical terms embedded in `glossary.md` before the first line of code is written. Run `/refine` first.

**NEVER collapse a multi-symbol mapping to the nearest match without user confirmation.** WHY: when one spec term resolves to multiple codebase symbols, collapsing hides a domain split that the spec conflated under one name. The failure mode: the implementation uses the wrong type in a conditional branch; the type error surfaces only at integration time when both symbols co-exist in the same data flow. List all candidate symbols and resolve explicitly.

**NEVER over-trigger the three-criteria test.** WHY: applying all-three-criteria too loosely produces ADR inflation — tens of trivial ADRs that nobody reads. The failure mode: the ADR directory becomes a junk drawer and future maintainers stop consulting it entirely, defeating its purpose. Terminology-alignment decisions ("use `revocation` not `cancellation`") fail criterion 1 (trivially reversible) and belong in `decisions.md`, not ADRs.

**NEVER re-surface a learnings/-confirmed term as a new conflict.** WHY: the knowledge-scout flags terms already resolved and stored in `learnings/`. Re-raising them ignores institutional memory, wastes the alignment session, and risks overwriting a prior resolution that was correct. Only re-raise if fresh codebase evidence directly contradicts the learnings/ record — and if you do, note the contradiction explicitly.

**NEVER silently overwrite an existing `glossary.md` definition.** WHY: the file is co-owned with `/makato-plan:stress-test-artifact`, which owns the canonical vocabulary layer. Silently rewriting an entry destroys the audit trail and may corrupt downstream specs (design.md, prd.md) that reference the original definition. If a probe proves an entry is factually wrong, record the correction reason in `decisions.md` first, then update the entry.

**NEVER attempt to resolve a cross-subsystem terminology inconsistency in a single alignment session.** WHY: when the same spec term means different things in two modules, the fix requires renaming usages across module boundaries — a refactoring story, not a single-session terminology alignment. Documenting the divergence is in scope; resolving it is not.
