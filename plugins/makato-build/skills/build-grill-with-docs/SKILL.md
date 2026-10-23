---
name: build-grill-with-docs
description:
  Align implementation plan terminology to the codebase domain model — grill plan, terminology
  conflicts, glossary.md enrichment, ADR decisions. Interactive interview, or with --autonomous
  decide with the recommended option and ask only the costly open questions in ONE ticket comment
  while the card waits in Blocked. Use after /refine, before /implement-tdd or /implement-goal.
  Optional but recommended for complex stories.
version: "1.10.0"
argument-hint: "[work-item-key] [--autonomous]"
allowed-tools: [Bash, Read, Glob]
metadata:
  Authors: makato-build team
  last_updated: "2026-10-23"
---

## When to Use

Use after `/refine` (plan.md exists) and before `/implement-tdd` or `/implement-goal`. The
implementation plan is in place but may contain spec-language that doesn't match how the codebase
actually names things. This skill probes those mismatches and enriches the feature `glossary.md`
(produced by `/makato-plan:stress-test-artifact`) with codebase name annotations before any code is
written.

**Do NOT use** as a substitute for `/refine` (this skill does not produce an implementation plan) or
as a substitute for `/makato-plan:stress-test-artifact` (that skill stress-tests spec artifacts and
owns the canonical domain vocabulary; this one maps that vocabulary to live code symbols).

**Do NOT use** on a greenfield service with no existing codebase to probe — the skill's entire value
comes from comparing spec language to live code symbols. With no code to search, every proposed term
is an unverifiable assumption, not a codebase alignment.

## Input

- `<work-item-key>` — work item whose plan and glossary are being aligned.
- `--autonomous` — activation flag (see Step 0). `$AGENT_ID` or a `task_id` in the context bundle
  activate the same mode.
- `ISSUE_NUMBER` — autonomous mode only: the GitHub issue whose card carries the work item. The
  skill asks its open questions on this issue; without it every question is decided (Step 5a).
- `REPO` — autonomous mode only, optional: `owner/name` of that issue; derived from the checkout
  when absent.
- `MAKATO_GRILL_MODE` — autonomous mode only: `ask` (default; costly open questions go to the
  ticket) or `decide` (never ask; always take the recommended option).
- `MAKATO_BUILD_ROOT` — absolute installed build-plugin root. Resolve from
  `CLAUDE_PLUGIN_ROOT`, `OMP_PLUGIN_ROOT`, or `PLUGIN_ROOT` when the caller
  does not supply it; use it for suite-owned helpers.
- `MAKATO_ORCHESTRATE_ROOT` — optional absolute installed orchestrate-plugin
  root. When absent, skip the best-effort workflow-state update without
  probing the consumer repository.

## Workflow

### Step 0 — Pick the mode

Autonomous mode is active when ANY of these holds (`$MAKATO_BUILD_ROOT/AUTONOMOUS-MODE.md` §
_Activation triggers_): `--autonomous` on the command line, `$AGENT_ID` set in the environment, or a
`task_id` in the context bundle. Otherwise the skill is interactive and every "ask" below means
asking the user in chat. Remember which trigger fired (`cli_flag`, `agent_id`, `task_id_bundle`)
for the bypass log.

**Headless guard.** `MAKATO_HEADLESS=1` with none of the three triggers means nobody can answer
and the interview would deadlock. Do not prompt and do not fall back to autonomous mode: write
`{step:"session", status:"error", data:{halt_code:"MISSING_INPUT", message:"build-grill-with-docs
invoked headless (MAKATO_HEADLESS=1) without an autonomous trigger"}}` through `build-log.sh`,
return an R1 `failure` with `errors: ["MISSING_INPUT: headless-without-autonomous"]` and
`data.halt_code: "MISSING_INPUT"`, and stop.

**In autonomous mode the skill never prompts and never waits for chat input.** Every point below
that would ask the user has an autonomous rule, and there are exactly two mechanisms for an open
question (Step 5a): **decide** with the recommended option, or **ask through the ticket** — one
batched comment, the card parked in Blocked, the session ending as `awaiting_answers`. Log each
default taken with `"$MAKATO_BUILD_ROOT/shared/log-bypass.sh"`. Never forward `--autonomous` to
another skill.

---

### Step 1 — Resolve work item, load glossary, locate ADR path

Interactive: ask _"Which work item are we aligning? (e.g. DCP-1234)"_ — or use the passed argument.
Autonomous: the key MUST be passed; if it is missing, return R1 `failure` with
`errors: ["MISSING_INPUT: build-grill-with-docs in autonomous mode requires a work-item-key"]`.
Resolve the target repository root before reading any spec artifact:

```bash
MAKATO_BUILD_ROOT="${MAKATO_BUILD_ROOT:-${CLAUDE_PLUGIN_ROOT:-${OMP_PLUGIN_ROOT:-${PLUGIN_ROOT:-$(git rev-parse --show-toplevel)/plugins/makato-build}}}}"
if [[ -n "${WORKTREE_PATH:-}" ]]; then
  REPO_ROOT="${MAKATO_TARGET_REPO_ROOT:-$(git -C "$WORKTREE_PATH" rev-parse --show-toplevel)}"
else
  REPO_ROOT="${MAKATO_TARGET_REPO_ROOT:-$(git rev-parse --show-toplevel)}"
fi
```

Read `plan.md` from the resolved spec folder (`$REPO_ROOT/specs/<key>-*/`) (required). If missing, stop:

> "Run `/refine` first — `plan.md` is required."

Read `prd.md`, `design.md`, and `decisions.md` from `$REPO_ROOT/specs/<key>-*/` if they exist.

Load `glossary.md` from `$REPO_ROOT/specs/<key>-*/` as baseline if present — this is the feature
vocabulary written by `/makato-plan:stress-test-artifact`. Terms already there are established: do
not re-ask their meaning unless a codebase probe reveals a conflict. If `glossary.md` does not exist
it will be created in Step 6.

**ADR path lookup (Step 1 only):** Read the criteria reference exactly once now from the skill-local
URI `skill://build-grill-with-docs/references/adr-criteria.md`. Do not prepend the `@` sigil to this
URI, and do not load the reference again at any later step.

Probe these directories in order **under `$REPO_ROOT`**, never relative to the installed skill
directory or the caller's current directory:

```text
$REPO_ROOT/specs/ADR
$REPO_ROOT/docs/governance/adr
$REPO_ROOT/docs/adr
$REPO_ROOT/adr
$REPO_ROOT/.adr
$REPO_ROOT/decisions/adr
$REPO_ROOT/doc/adr
```

Use Glob with each absolute path (or an equivalent `test -d "$REPO_ROOT/<candidate>"` loop) and
select the first existing directory. For SAGIBEAST, this MUST resolve to `$REPO_ROOT/specs/ADR` when
that directory exists. Never pass the bare comma-separated candidate list to Glob; that resolves
against the wrong root and produces a false `ADR_DIR_NOT_FOUND`.

If no candidate exists, report `ADR_DIR_NOT_FOUND` with every absolute path checked and continue
only after recording that no ADR can be created. Never substitute a skill-local path for the target
repository's ADR directory.

```text
1. Create the resolved ADR directory and write ADRs there
2. Skip ADRs for this story — capture decisions in decisions.md only
```

Interactive: wait for the user's numbered choice before continuing. Record the resolved path (or
`skip`). Autonomous: a resolved directory is used as is; with no candidate take option 2 (skip)
— never create a new top-level directory in the target repository unattended — and log the bypass
(`gate: "adr-dir-missing"`, `default_taken: "skip-adrs"`).

**ADR fallback**: if the user chooses to skip or the ADR directory cannot be created, do not
silently drop ADR-worthy decisions. For each decision that meets the ADR criteria (Step 7), append
it to `decisions.md` in the resolved spec folder with an `[ADR-PENDING]` marker and a note:
`(ADR path unresolved — promote to ADR when directory is available)`. This preserves the decision
for future promotion without blocking the session.

**Artifact URI guard:** Read `local://` or `artifact://` only when that exact URI was emitted by a
preceding tool or agent in this run. Never invent a placeholder such as `local://no-such`; if no
artifact URI was emitted, use the canonical repository path or report the missing artifact.

**Complexity check** — Assess complexity by counting tasks and architectural layers from the plan.
Note the overall complexity level (>7 tasks, >8 file targets, or >3 spec files flags high
complexity) and proceed with enhanced attention to alignment depth.

**Resume check (autonomous only).** Set `SPEC_DIR` to the resolved `$REPO_ROOT/specs/<key>-*/` folder.
If `$SPEC_DIR/awaiting-answers-$ISSUE_NUMBER.json` exists, an earlier run of this skill asked
questions through the ticket and this run is a **resume** — go to Step 5b after Step 4. Absent: a
fresh run.

---

### Step 2 — Log session start

Run:

```bash
"$MAKATO_BUILD_ROOT/shared/build-log.sh" "<key>" '{"ts":"<ISO8601>","skill":"build-grill-with-docs","story":"<key>","step":"session","status":"start","data":{"mode":"interactive|autonomous","resume":true|false,"has_glossary":true|false,"adr_path":"<path>|skip"}}'
```

---

### Step 3 — Inventory domain terms from plan + spec

Scan `plan.md` and spec artifacts for domain-specific nouns: entities, states, actions,
relationships. Build a candidate list. Skip any term already present in `glossary.md` with no
codebase conflict detected — it is already established. Do not ask the user about it again.

Dispatch the `knowledge-scout` agent with REPO_ROOT (the target codebase root), REPO_NAME (last path
segment of REPO_ROOT), and the candidate term list as KEYWORDS. This is best-effort — proceed
normally if the agent returns `loaded: false`.

If the agent returns findings: inject any `## Hard Constraints`, `## Standards`, and learnings-based
findings as additional conflict evidence in the candidate list. A term already documented as
resolved in `learnings/` does not need to be raised in the alignment interview — mark it as
confirmed and note the source. Only re-raise a learnings/-confirmed term if fresh codebase evidence
directly contradicts the learnings/ record.

---

### Step 4 — Probe codebase for canonical names

For each candidate term, search the codebase: class names, field names, enum values, table/column
names, API path segments, method names. Build a conflict map: _spec term → codebase term(s)_. Flag
conflicts and synonyms. Mark confirmed clean matches.

**Multi-symbol mapping**: when a spec term resolves to two or more distinct codebase symbols (e.g.,
`Payment` → `PaymentIntent`, `PaymentMethod`, `PaymentRecord`), do NOT collapse to the nearest
match. List all candidate symbols separately in the conflict map and flag the spec term as
underspecified. The spec term may represent multiple domain concepts that were conflated under one
name in the plan — each must be explicitly disambiguated in the alignment interview (Step 5), not
guessed here.

If codebase exploration answers a question outright, record the answer and skip asking the user.

Load `@references/context-md-format.md` — the format all resolved terms will use when writing
glossary entries. Do NOT load this reference before Step 4; it is only needed when writing entries
in Steps 5–6.

---

### Step 5 — Conduct alignment interview

**Autonomous mode skips this interview** and runs Steps 5a/5b instead; the rules for a disagreeing
user and for cross-subsystem naming debt below still apply to what those steps record.

Number every question (Q1, Q2…). For each conflict or ambiguity: state the conflict, surface the
codebase evidence, propose a canonical resolution, wait for confirmation. Resolve depth-first —
exhaust each branch before moving to the next topic.

- Record each resolved term immediately (do not batch).
- Stress-test with edge cases when a term's boundary is unclear.
- If the user says "skip": park as open question, move on.

**When the user disagrees with the proposed canonical term:**

1. Ask for their preferred term.
2. Check whether that preferred term conflicts with another codebase symbol found in Step 4. If yes,
   surface the conflict before accepting.
3. Accept the user's choice — they own the domain vocabulary.
4. Record the divergence in `decisions.md`:
   `(canonical term '<user-term>' chosen by user; codebase symbol is '<original symbol>')`.

**When the same spec term is used differently across subsystems** (e.g., `Account` means
`UserAccount` in the auth module and `BillingAccount` in the payments module): this is system-level
naming debt, not a feature-level alignment gap. Document the divergent usage in `decisions.md` with
an explicit note. Do not attempt to resolve it in this session — cross-module renaming requires
coordination beyond this skill's scope.

---

### Step 5a — Autonomous alignment: decide, or ask through the ticket

Finish Steps 3–4 for EVERY term first, so all open questions are known before anything is asked.
Then sort each conflict from the Step 4 map:

| Class   | Test                                                                                                                                                                                                                                                                         | Action                                                                                                                                                                                       |
| ------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Settled | One codebase symbol matches, or `learnings/`, `design.md`, `prd.md` already decide it                                                                                                                                                                                        | Record the resolution. No question.                                                                                                                                                          |
| Decide  | Evidence is incomplete, but a wrong pick is cheap to reverse (internal naming, a synonym, an annotation-only `_Code_:` line)                                                                                                                                                 | Take the **recommended** resolution: the existing codebase symbol — a rename costs more than an annotation. Record `(autonomous: recommended — <reason>)` in `decisions.md`; log the bypass. |
| Ask     | A wrong pick is costly AND nothing in the repository settles it: the decision passes the ADR three-criteria test, OR the spec term maps to two or more distinct symbols with different behaviour (Step 4 multi-symbol mapping), OR the canonical term would rename a persisted or public name (column, API field, enum value, event) | Collect into ONE batch (below).                                                                                                                                                              |

Record Settled and Decide terms immediately (Step 6 glossary entry plus `decisions.md`), exactly as
the interactive path does, so a later resume never re-asks them.

If the Ask class is empty, nothing is asked. If `MAKATO_GRILL_MODE=decide` or `ISSUE_NUMBER` is
unset (there is no ticket to ask on), take the recommended resolution for the Ask items too, mark
each `assumed` in `decisions.md`, list it in `data.assumed`, and continue with Step 6.

**Batch.** Write every Ask item into ONE questions file — never one post per question. Each question
has an `id` (`Q1`…), `title`, `context` (the spec term and the code evidence as `path:line`), and
2–4 `options` (`id` A…, `label`, `why`, and `effect` = exactly what the skill will record if chosen).
Exactly one option is `recommended: true` — the one you would take with no human around. Set
`followup: true` on an option whose choice would raise new questions. A free-text reply is always
accepted and always counts as a follow-up. Then post once:

```bash
Q_DIR="$(mktemp -d)"
Q_FILE="$Q_DIR/questions.json"   # {"intro": "...", "questions": [{"id": "Q1", "title": "...", "context": "...", "options": [...]}]}
python3 "$MAKATO_BUILD_ROOT/shared/human_questions.py" post \
  --spec-dir "$SPEC_DIR" --issue "$ISSUE_NUMBER" --key "<key>" \
  --questions-file "$Q_FILE" --root "$REPO_ROOT" ${REPO:+--repo "$REPO"}
rm -rf "$Q_DIR"
```

`post` moves the card to Blocked (re-read to confirm), posts the comment, and writes
`$SPEC_DIR/awaiting-answers-$ISSUE_NUMBER.json`. Read the JSON on stdout and the exit code:

| Result                              | Meaning                                                                                                      | Do                                                                                                                                                                  |
| ----------------------------------- | ------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `state: posted` or `already-posted` | The questions are on the ticket and the card is Blocked.                                                      | **Park.** Steps 6–7 do not run for the asked terms. Go to Step 8, parked ending.                                                                                     |
| `state: unavailable` (exit 0)       | The card cannot be blocked and observed (no board config, issue not on the board, board write refused). Nothing was posted. | Nobody would ever see the "answered" signal. Take the recommended option for every Ask item, mark `assumed` with the returned `reason`, continue with Step 6.       |
| exit 5                              | The question-round cap (`MAKATO_GRILL_MAX_QUESTION_ROUNDS`, default 3) is reached.                            | Same as `unavailable`, reason `question rounds exhausted`.                                                                                                           |
| any other non-zero exit             | GitHub or input failure (`error` in the JSON).                                                                | Retry once. If it still fails: recommended option for every Ask item, `assumed`, reason = the error. The card was left untouched.                                    |

Questions that are asked together are answered together. Only an answer that creates a NEW
question justifies another round (Step 5b).

---

### Step 5b — Resume after the ticket was answered

Reached from the Step 1 resume check. Ask the helper where the ticket stands:

```bash
python3 "$MAKATO_BUILD_ROOT/shared/human_questions.py" status --spec-dir "$SPEC_DIR" --issue "$ISSUE_NUMBER"
```

| `state`        | Do                                                                                                                                                                                |
| -------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `waiting`      | The card is still Blocked. Change nothing, do not post again; end with the parked ending (Step 8).                                                                                |
| `answered`     | The card was moved back to Ready or In progress. `collect` (below).                                                                                                               |
| `expired`      | `MAKATO_QUESTIONS_MAX_WAIT_SECS` ran out. `collect` (below); unanswered questions take the recommended option.                                                                     |
| `unobservable` | The board can no longer be read. `collect --force`: read the replies anyway.                                                                                                     |
| `closed`       | The ticket was closed. Run `resolve` to drop the marker, apply nothing, return R1 `partial` with `data.ticket_closed: true`.                                                       |
| `none`         | No marker after all. Treat as a fresh run (Step 5a).                                                                                                                              |

```bash
python3 "$MAKATO_BUILD_ROOT/shared/human_questions.py" collect --spec-dir "$SPEC_DIR" --issue "$ISSUE_NUMBER"
```

`collect` reads only the replies written after the question comment, claims the card
(Ready → In progress), and returns `resolved[]` — one entry per question with `choice`, `label`,
`effect`, `text`, `note`, `source` (`user`, `user-accept-all`, or `recommended` for a question nobody
answered) and `followup`. Apply each entry like an interview answer:

- `choice` set → record the resolution the option's `effect` describes.
- `text` set (free text) → the user owns the domain vocabulary: check the term against the Step 4
  symbols, surface a conflict as a new question, otherwise accept it and record
  `(canonical term '<text>' chosen by user; codebase symbol is '<original symbol>')`.
- `source: recommended` → record it as decided by default (`no reply — recommended option taken`).
- Add `note` to the `decisions.md` entry verbatim.

If `followups_needed` is non-empty, derive ONLY the new questions those answers raise, post them as
ONE batch (Step 5a; the helper numbers the round), and park again. Every other answered question is
recorded now; they are not asked again. If that post returns `unavailable` or exit 5, take the
recommended option for the follow-ups, mark them `assumed`, and continue.

With no follow-ups left, continue with Step 6. The marker is removed in Step 8, after the writes.

---

### Step 6 — Enrich glossary.md

Write to `glossary.md` in the resolved spec folder. Lazy-create the file with the makato-plan header
format if it doesn't exist:

```markdown
# {Feature name} — Glossary

Feature-scoped vocabulary for this story. Domain terms from shaping; codebase mappings from
/grill-with-docs.

## Language

## Relationships

## Flagged ambiguities
```

For **existing entries** (from `/makato-plan:stress-test-artifact`): add a `_Code_: <symbol>` line
when the codebase name differs from the canonical term. If the codebase matches the canonical term
exactly, leave the entry unchanged.

For **new terms** not yet in `glossary.md`: append a full entry under `## Language` following the
format from `@references/context-md-format.md`.

Do not overwrite or rewrite existing definitions — only add `_Code_:` annotations and new entries.
The audit trail for revisions lives in `decisions.md`, not in `glossary.md`. Exception: if a
codebase probe proves an entry is factually wrong, note the correction reason in `decisions.md`
first, then update the entry.

---

### Step 7 — Route decisions: decisions.md vs ADR

**ADR routing:** Reuse the criteria reference already loaded in Step 1. Do not issue another
reference read or invent an `@references/...` URI here. Apply the three-criteria test to every
decision, then create the ADR under the `ADR_DIR` discovered in Step 1.

Load the skill-local `templates/adr.md` only when writing a new ADR, never speculatively. Resolve it
as `templates/adr.md` relative to this skill directory; do not use an `@templates/...` URI.

For each decision surfaced during the interview, apply the three-criteria test and routing rule from
`adr-criteria.md`. Interactive: present each proposed ADR to the user before writing. Autonomous: do
not ask — write the ADR when all three criteria hold, and say in its Context where the decision came
from (the ticket answer, or `autonomous: recommended`). Skip this step entirely if the ADR path
resolved to `skip` in Step 1; ADR-worthy decisions then take the `[ADR-PENDING]` fallback below.

**After routing each decision** (whether written to an ADR file, appended to `decisions.md`, or
marked `[ADR-PENDING]`), check whether a `workflow-state.json` exists for the current KEY. Use the
spec-folder glob from Step 1 (`specs/<KEY>-*/`) to find `workflow-state-*.json`; if multiple
issue-scoped files exist, write to all of them (one call per file):

```bash
# Find all per-issue workflow-state files for this KEY
WS_FILES="$(ls "$REPO_ROOT"/specs/<KEY>-*/workflow-state-*.json 2>/dev/null || true)"

if [[ -n "$WS_FILES" ]] &&
   [[ -n "${MAKATO_ORCHESTRATE_ROOT:-}" ]] &&
   [[ -x "$MAKATO_ORCHESTRATE_ROOT/shared/workflow-state.sh" ]]; then
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

Replace `<decision title>`, `<chosen approach>`, `<rejected alternatives>`, `<rationale>`, and
`<source>` with the actual values from the decision just routed. The `rejected` array may be empty
(`[]`) when no alternatives were considered. The `source` field should be the ADR file path (e.g.,
`docs/governance/adr/adr-001.md`) or `decisions.md` as applicable.

**This write is best-effort.** A failed `append-decision` call (missing workflow-state, schema
version mismatch, jq error) MUST NOT block the session or abort Step 7. Log a brief inline note if
the write fails, then continue to the next decision. The `workflow-state.json` write is a
convenience; the ADR file or `decisions.md` entry is the primary record.

---

### Step 8 — Log session end and hand off

Run:

```bash
"$MAKATO_BUILD_ROOT/shared/build-log.sh" "<key>" '{"ts":"<ISO8601>","skill":"build-grill-with-docs","story":"<key>","step":"session","status":"ok","data":{"terms_resolved":<N>,"terms_skipped":<M>,"adrs_written":<K>,"decisions_updated":<J>,"decisions_persisted_to_state":<P>}}'
```

`decisions_persisted_to_state` is the count of decisions successfully written to
`workflow-state.json` via `append-decision` in Step 7. Zero is a valid value when no workflow-state
file exists for the KEY or all writes failed.

Interactive: tell the user _"Alignment complete. `glossary.md` enriched with `<N>` terms. Next:
`/implement-tdd` or `/implement-goal`."_

#### Step 8 — autonomous endings

Autonomous mode ends in exactly one of two ways. Both write `status:"ok"` to the session line —
`check-session-tail.sh` treats only `ok` and `error` as terminal, and a parked session is a clean
exit, not a failure.

**Parked** (Step 5a posted, or Step 5b is still `waiting`). Log
`{"step":"session","status":"ok","data":{"mode":"autonomous","awaiting_answers":true,"round":<N>,"questions":<Q>,"comment_url":"<url>"}}`
and return R1 `partial` with `data.awaiting_answers: true`. Do not apply `needs-human-review`, do
not post a HALT comment: the helper's ticket comment already is the request, and the card in Blocked
is the state. Do not sleep or poll — the orchestrator watches the card and re-dispatches the skill
when a human moves it back to Ready or In progress.

**Done** (no question is left open). Write the closing comment and drop the marker, but only when a
marker exists — after Steps 6–7 have written everything:

```bash
C_FILE="$(mktemp)"   # one line per question: "Q1 → B (<label>) — answered", "Q2 → A — no reply, recommended taken"
python3 "$MAKATO_BUILD_ROOT/shared/human_questions.py" resolve \
  --spec-dir "$SPEC_DIR" --issue "$ISSUE_NUMBER" --comment-file "$C_FILE"
rm -f "$C_FILE"
```

Then log the normal session end (add `"mode":"autonomous","questions_asked":<Q>,"assumed":<A>` to
`data`) and return R1 `success`. Do not print the "Next:" hand-off line: the PO-agent sequences the
next skill.

---

## Autonomous Execution

Autonomous mode is activated per `$MAKATO_BUILD_ROOT/AUTONOMOUS-MODE.md` § _Activation triggers_
(Step 0). In autonomous mode:

- **Never prompt the user.** The work-item key, the ADR-directory choice, the alignment interview
  and the ADR approval are replaced by the rules in Steps 0, 1, 5a/5b and 7.
- **Ask the ticket, not the chat.** All open, costly questions go out as ONE comment with lettered
  options and exactly one recommendation per question; the card is moved to **Blocked** while they
  wait. A human answers by replying (`Q1: B`, `all: recommended`) and then moving the card back to
  **Ready** or **In progress** — that move is the "I answered" signal. New questions are asked again
  only when an answer creates them, up to `MAKATO_GRILL_MAX_QUESTION_ROUNDS` rounds.
- **When asking is impossible, decide.** No board, no `ISSUE_NUMBER`, a refused board write, or an
  exhausted round budget: take the recommended option, mark it `assumed` in `decisions.md`, and list
  it in `data.assumed` so the review sees it.
- **Log every bypass** with `"$MAKATO_BUILD_ROOT/shared/log-bypass.sh"` (`gate`: `term-resolution`,
  `adr-dir-missing`, `questions-unavailable`, …; `default_taken`: `take-recommended`, `skip-adrs`, …).
- **Emit an R1 envelope** as the final `json`-fenced block (schema: `plugins/makato-build/agents/RETURN-CONTRACT.md`).

### Return Format (R1, when called as a sub-skill)

Top-level fields follow `plugins/makato-build/agents/RETURN-CONTRACT.md` § _R1 envelope schema_.
`agent` is `"build-grill-with-docs"`. `files_changed` lists `glossary.md`, `decisions.md` and any
ADR written. The skill-specific `data` payload:

```json
{
  "data": {
    "mode": "autonomous",
    "awaiting_answers": false,
    "terms_resolved": 0,
    "decided_by_default": 0,
    "questions_asked": 0,
    "answered_by_user": 0,
    "assumed": [{ "term": "<term>", "choice": "<option>", "reason": "<why it was not asked>" }],
    "adrs_written": 0,
    "decisions_updated": 0,
    "round": 0,
    "marker_path": "specs/<key>-<slug>/awaiting-answers-<ISSUE_NUMBER>.json",
    "comment_url": "<url of the question comment, parked only>",
    "ticket_closed": false
  }
}
```

`status` is `success` when every term is resolved, `partial` when parked
(`awaiting_answers: true`; `summary`: `"Asked <Q> questions on #<N>; card Blocked, awaiting answers"`)
or when the ticket was closed (`ticket_closed: true`), and `failure` only for `MISSING_INPUT`
(missing key, `plan.md`, headless-without-autonomous), which is registered in
`plugins/makato-build/halt-codes.md`. A parked `partial` is **not** a HALT: the PO-agent records
`grill-awaiting-answers` in workflow-state and returns without `needs-human-review`.

---

## Anti-patterns

**NEVER run without `plan.md` present.** WHY: without the implementation plan there is no
specification to align against; the interview generates conflicts anchored to shaping artifacts
alone, not to what will actually be built. The result: wrong canonical terms embedded in
`glossary.md` before the first line of code is written. Run `/refine` first.

**NEVER collapse a multi-symbol mapping to the nearest match without user confirmation.** WHY: when
one spec term resolves to multiple codebase symbols, collapsing hides a domain split that the spec
conflated under one name. The failure mode: the implementation uses the wrong type in a conditional
branch; the type error surfaces only at integration time when both symbols co-exist in the same data
flow. List all candidate symbols and resolve explicitly.

**NEVER over-trigger the three-criteria test.** WHY: applying all-three-criteria too loosely
produces ADR inflation — tens of trivial ADRs that nobody reads. The failure mode: the ADR directory
becomes a junk drawer and future maintainers stop consulting it entirely, defeating its purpose.
Terminology-alignment decisions ("use `revocation` not `cancellation`") fail criterion 1 (trivially
reversible) and belong in `decisions.md`, not ADRs.

**NEVER re-surface a learnings/-confirmed term as a new conflict.** WHY: the knowledge-scout flags
terms already resolved and stored in `learnings/`. Re-raising them ignores institutional memory,
wastes the alignment session, and risks overwriting a prior resolution that was correct. Only
re-raise if fresh codebase evidence directly contradicts the learnings/ record — and if you do, note
the contradiction explicitly.

**NEVER silently overwrite an existing `glossary.md` definition.** WHY: the file is co-owned with
`/makato-plan:stress-test-artifact`, which owns the canonical vocabulary layer. Silently rewriting
an entry destroys the audit trail and may corrupt downstream specs (design.md, prd.md) that
reference the original definition. If a probe proves an entry is factually wrong, record the
correction reason in `decisions.md` first, then update the entry.

**NEVER attempt to resolve a cross-subsystem terminology inconsistency in a single alignment
session.** WHY: when the same spec term means different things in two modules, the fix requires
renaming usages across module boundaries — a refactoring story, not a single-session terminology
alignment. Documenting the divergence is in scope; resolving it is not.

**NEVER prompt, wait, sleep or poll inside the skill in autonomous mode.** WHY: the session runs
headless with no stdin; a prompt deadlocks it, and a sleep loop holds a worker slot and a context
window for a human who may answer tomorrow. Park and exit — the orchestrator watches the card.

**NEVER post questions one at a time, and NEVER re-ask a settled or already-answered question.**
WHY: every post blocks the card and costs a human context switch. Finish Steps 3–4 for every term,
post one batch, and open a new round only for questions an answer created. Settled and Decide terms
are written before parking, so the resume never re-asks them.

**NEVER block the card without a posted comment, or post without blocking the card.** WHY: a
comment with the card still Ready gets dispatched again; a Blocked card with no comment is a
silent dead end. `human_questions.py post` does both in order and undoes the block when the comment
fails — do not hand-roll the sequence with `gh`.

**NEVER escalate a question as `needs-human-review` or a HALT code.** WHY: those labels route the
ticket to the operator's incident queue and the loop treats them as failures. A question is a
routine request for input; the Blocked card plus the comment is the whole protocol.
