# Skill Adoption Audit — Auditor Runbook

> **Audience:** the rotating auditor (D14) for a single audit cycle.
> **Goal:** take you from *"a flag just fired"* to *"a refinement PR is filed
> and the state machine is advanced"* without needing to contact the original
> author (validates assumption **A4** — auditor time is bounded).
>
> This runbook is the onboarding procedure for the `agent-skill-routing` audit
> loop. It ships **before** the first signal-triggered event (story S6) so the
> first auditor has a procedure the moment the first flag fires. Read it once
> end-to-end, then use the numbered checklists per phase.

---

## Overview — the audit cycle at a glance

The audit is a feedback loop that keeps skill auto-discovery honest: an
analyzer watches skill-invocation telemetry, flags domains where adoption
looks low, and a human auditor spot-checks a sample of recent PRs to decide
whether the low number is *real under-adoption* (skills exist but agents skip
them) or *noise* (the work genuinely needed no skill). Findings drive F1
bundle refinements.

```text
 [ S6 analyzer ]              [ YOU, the auditor ]                 [ outcome ]
 rolling 7-day        flag       triage a sample of PRs      refinement PR +
 adoption < 50%  ─────────▶   (start 10, +5 per dirty,  ───▶  state-machine
 over ≥ 5 sessions            cap 30) → record verdicts        advance
 (D15)                        per PR (D16)                     (D16)
```

Three decisions govern the loop:

| Decision | What it defines | Where it lives |
|----------|-----------------|----------------|
| **D14** | Rotating single-auditor role — one auditor owns one cycle end-to-end. | This runbook. |
| **D15** | Flag trigger — rolling 7-day adoption `< 50%` over `≥ 5` sessions for a domain. | `scripts/audit-skill-adoption.py` → appends to `docs/skill-audit-notes.md`. |
| **D16** | Sample-size state machine — start 10, `+5` per dirty cycle, cap 30; 3 consecutive clean → scale down, 3 consecutive dirty → escalate to R&D. | `.claude/state/audit-state.json` (machine state) + this runbook (decision rules). |

> **Note on artifact availability.** The analyzer, the human-readable
> `docs/skill-audit-notes.md`, and the machine-readable
> `.claude/state/audit-state.json` are delivered by story **S6 (#149)**. This
> runbook documents their *expected shape* so the procedure is ready first. If
> a path below does not yet exist in your checkout, S6 has not landed — do not
> improvise; wait for the analyzer.

---

## Before you start — the auditor's checklist

- [ ] You are the **sole** auditor for this cycle. D14 is a single-auditor
      rotation; concurrent audits are out of scope (v2).
- [ ] You can read `docs/skill-audit-notes.md` (the flag log).
- [ ] You can read `.claude/state/audit-state.json` (the state machine).
- [ ] You have `gh` authenticated with `repo` scope (to list merged PRs and
      file the refinement PR).
- [ ] You have ~30–60 minutes. If a cycle needs more, that is itself a signal
      the sample is too large — see the escalation rule (Phase 5).

---

## Phase 1 — Interpret the D15 flag

**Trigger:** a new flag entry appended to `docs/skill-audit-notes.md` by the
analyzer.

A flag entry looks like this (D15 shape):

```markdown
## FLAG 2026-07-14 — domain: makato-database

- window: 2026-07-07 → 2026-07-14 (rolling 7 days)
- sessions_observed: 8            # ≥ 5 required to flag
- skill_invocations: 3
- eligible_sessions: 8            # sessions where a DB skill was applicable
- adoption_rate: 0.375           # 3/8 → below the 0.50 threshold
- status: OPEN
```

### Checklist — interpret the flag

1. [ ] Read the **newest** `## FLAG` entry with `status: OPEN`. Work one flag
       per cycle; if several are open, take the oldest OPEN flag first (FIFO).
2. [ ] Confirm it genuinely fired per D15: `sessions_observed ≥ 5` **and**
       `adoption_rate < 0.50`. If either is false, the entry is malformed —
       note it and skip (do not audit a non-qualifying flag).
3. [ ] Record the flagged **domain** (e.g. `makato-database`) and the
       **window** — you will only sample PRs merged inside that window.
4. [ ] Note the `adoption_rate` — this is your baseline to beat or confirm.

**Exit condition:** you know the domain and the date window to audit.

---

## Phase 2 — Select the D16 sample

**Sample size comes from the state machine, not from you.** Read it; don't
guess.

The state file (D16 shape) looks like this:

```json
{
  "domains": {
    "makato-database": {
      "current_sample_size": 10,
      "consecutive_clean": 0,
      "consecutive_dirty": 0,
      "last_cycle": "2026-07-07",
      "status": "active"
    }
  }
}
```

### Checklist — select the sample

1. [ ] Open `.claude/state/audit-state.json` and read
       `domains.<flagged-domain>.current_sample_size`.
       - If the domain has no entry yet, this is its **first** cycle → use the
         default start size **10**.
2. [ ] List merged PRs touching the flagged domain inside the flag window:
       ```bash
       gh pr list --state merged --search "merged:2026-07-07..2026-07-14" \
         --json number,title,files,mergedAt --limit 100
       ```
       Keep only PRs whose changed files fall under the flagged domain's
       plugin path (e.g. `plugins/makato-database/`).
3. [ ] Take the **most recent N** PRs, where N = `current_sample_size`. If
       fewer than N qualifying PRs exist in the window, audit all of them and
       note the shortfall (a thin window is not a dirty verdict).
4. [ ] Write the selected PR numbers into your working notes — this is the
       sample you will grade in Phase 3.

**Sample-size rules (reference — you *apply* these in Phase 5, not here):**

- Start at **10**.
- **+5** for each dirty cycle, **capped at 30**.
- After **3 consecutive clean** cycles → scale the size back down.
- After **3 consecutive dirty** cycles → escalate to R&D (see Phase 5).

**Exit condition:** you have a concrete list of PR numbers to grade.

---

## Phase 3 — Record a verdict per PR

For **each** PR in the sample, record three booleans and classify it. Use this
exact verdict format so results are comparable across cycles and auditors:

```text
PR #<n> | applied=<yes|no> | skill_invoked=<yes|no> | false_positive=<yes|no> | note="<one line>"
```

Field meanings:

| Field | Question you are answering |
|-------|----------------------------|
| `applied` | Was a domain skill *applicable* to this PR's work at all? |
| `skill_invoked` | Did the author actually invoke the relevant skill? |
| `false_positive` | Was the low-adoption signal wrong here — i.e. no skill was needed, so a miss is not a real miss? |

### Classification rule (per PR)

- **CLEAN** — the PR is *not* evidence of under-adoption. Either the skill was
  invoked (`skill_invoked=yes`), **or** no skill applied
  (`applied=no` → `false_positive=yes`).
- **DIRTY** — the PR *is* evidence of under-adoption: a skill applied
  (`applied=yes`) but was not invoked (`skill_invoked=no`,
  `false_positive=no`).

### Checklist — record verdicts

1. [ ] For each sampled PR, open its diff and check whether a domain skill was
       applicable and whether it was invoked (look for the skill in the PR's
       commit trailers / invocation log).
2. [ ] Write one verdict line per PR in the format above.
3. [ ] Tally: count DIRTY PRs. This tally drives the cycle outcome in Phase 5.
4. [ ] A cycle is a **dirty cycle** if the dirty rate confirms real
       under-adoption (dirty PRs dominate the sample); it is a **clean cycle**
       if the flag was mostly false positives / already-invoked skills.

**Exit condition:** every sampled PR has a verdict line and you know whether
this cycle is clean or dirty.

---

## Phase 4 — File the refinement PR

Findings are only useful if they feed F1 bundle refinements. **PR creation is
manual** (per D14 findings-both) — you author it; the loop does not.

### Checklist — file the PR

1. [ ] Create a branch: `git checkout -b audit/<domain>-<cycle-date>`.
2. [ ] Append your verdict lines and the cycle outcome to
       `docs/skill-audit-notes.md` under the flag you audited, and flip the
       flag's `status: OPEN` → `status: TRIAGED`.
3. [ ] If the cycle was **dirty**, propose the concrete F1 bundle refinement
       your findings point to (e.g. add a trigger phrase to a skill's
       `description:`, add an archetype to `task-skill-map.json`, or tighten a
       skill bundle). Reference the specific skill/bundle in the PR body.
4. [ ] Label the PR **`type:audit-refinement`** and reference the bundle you
       are refining. Link back to the flag entry.
5. [ ] Open the PR:
       ```bash
       gh pr create --label type:audit-refinement \
         --title "audit(<domain>): cycle <date> findings + bundle refinement" \
         --body "Triages FLAG <date> for <domain>. Sample N=<n>, dirty=<d>. \
                  Refines bundle <bundle>. See docs/skill-audit-notes.md."
       ```

**Exit condition:** a `type:audit-refinement` PR is open, referencing the
bundle refinement and the flag.

---

## Phase 5 — Advance the D16 state machine

After filing, update `.claude/state/audit-state.json` for the flagged domain.
This is what makes the audit *adaptive*.

### Decision rules

```text
                     ┌─────────────────────────────────────────────┐
   this cycle CLEAN  │  consecutive_clean += 1                      │
                     │  consecutive_dirty  = 0                      │
                     │  if consecutive_clean == 3:                  │
                     │      current_sample_size = max(10, size − 5) │  ← SCALE DOWN
                     │      consecutive_clean = 0                   │
                     └─────────────────────────────────────────────┘

                     ┌─────────────────────────────────────────────┐
   this cycle DIRTY  │  consecutive_dirty += 1                      │
                     │  consecutive_clean  = 0                      │
                     │  current_sample_size = min(30, size + 5)     │  ← GROW (cap 30)
                     │  if consecutive_dirty == 3:                  │
                     │      status = "escalated-to-rnd"             │  ← ESCALATE
                     └─────────────────────────────────────────────┘
```

### Checklist — advance the state

1. [ ] Set `last_cycle` to today's date.
2. [ ] If **clean**: increment `consecutive_clean`, reset `consecutive_dirty`
       to 0. On the **3rd** consecutive clean cycle, reduce
       `current_sample_size` by 5 (floor 10) and reset `consecutive_clean` to
       0 — the domain is healthy, sample less next time.
3. [ ] If **dirty**: increment `consecutive_dirty`, reset `consecutive_clean`
       to 0, and grow `current_sample_size` by 5 (cap 30). On the **3rd**
       consecutive dirty cycle, set `status: "escalated-to-rnd"` and alert the
       team — repeated under-adoption is a systemic discovery gap, not a
       per-PR miss, and needs an R&D fix beyond bundle tweaks.
4. [ ] Commit the state change on your audit branch (same PR as Phase 4).

**Exit condition:** the state machine reflects this cycle; the next auditor
inherits the correct sample size and streak counters.

---

## Worked example

A concrete run-through with mock data. It shows **both** outcome paths so you
recognize each when you hit it.

### Setup — the flag

`docs/skill-audit-notes.md` gains:

```markdown
## FLAG 2026-07-14 — domain: makato-database

- window: 2026-07-07 → 2026-07-14 (rolling 7 days)
- sessions_observed: 8
- skill_invocations: 3
- eligible_sessions: 8
- adoption_rate: 0.375
- status: OPEN
```

`.claude/state/audit-state.json` has no `makato-database` entry yet → first
cycle → sample size **10**.

### Phase 2 — sample

`gh pr list` inside the window returns 12 merged PRs touching
`plugins/makato-database/`. Take the most recent **10**.

### Phase 3 — verdicts (mock)

```text
PR #401 | applied=yes | skill_invoked=yes | false_positive=no  | note="used manage-postgres"
PR #402 | applied=no  | skill_invoked=no  | false_positive=yes | note="pure README typo, no DB skill applies"
PR #403 | applied=yes | skill_invoked=no  | false_positive=no  | note="hand-wrote migration, skipped skill"  ← DIRTY
PR #404 | applied=yes | skill_invoked=yes | false_positive=no  | note="used manage-postgres"
PR #405 | applied=no  | skill_invoked=no  | false_positive=yes | note="CI config only"
PR #406 | applied=yes | skill_invoked=no  | false_positive=no  | note="raw SQL, no skill"                    ← DIRTY
PR #407 | applied=yes | skill_invoked=yes | false_positive=no  | note="used manage-postgres"
PR #408 | applied=no  | skill_invoked=no  | false_positive=yes | note="docs"
PR #409 | applied=yes | skill_invoked=yes | false_positive=no  | note="used manage-postgres"
PR #410 | applied=no  | skill_invoked=no  | false_positive=yes | note="test fixture only"
```

Tally: **2 DIRTY** out of 6 applicable PRs (4 false positives). The flagged
0.375 adoption was mostly **false positives** — half the "misses" were PRs
where no DB skill applied. Only 2 genuine misses.

### Outcome path A — CLEAN cycle (scale down)

Interpretation: 2 genuine misses in a sample of 10 is within tolerance; the
flag was largely noise. **Verdict: CLEAN.**

State update (assume this was the domain's **3rd** consecutive clean cycle,
and the size had previously grown above the floor):

```json
"makato-database": {
  "current_sample_size": 10,       // 3rd clean → size − 5, but never below the floor of 10
  "consecutive_clean": 0,          // reset after scale-down
  "consecutive_dirty": 0,
  "last_cycle": "2026-07-14",
  "status": "active"
}
```

> The floor is **10**; scale-down never drops below the start size. The
> mechanic is: reset the clean streak and shrink toward the floor. A
> refinement PR is still filed (documenting the false-positive pattern so the
> analyzer can be tuned), labeled `type:audit-refinement`.

### Outcome path B — DIRTY cycle (grow, then escalate)

Now assume a different, worse sample: **7 DIRTY** out of 10 — genuine skill
skips dominate. **Verdict: DIRTY.**

State update after this cycle (assume it is the **3rd** consecutive dirty
cycle for the domain):

```json
"makato-database": {
  "current_sample_size": 30,       // grown +5 per dirty, capped at 30
  "consecutive_clean": 0,
  "consecutive_dirty": 3,
  "last_cycle": "2026-07-14",
  "status": "escalated-to-rnd"     // 3rd dirty → alert the team
}
```

Action: file the `type:audit-refinement` PR **and** alert the team — three
straight dirty cycles means discovery is systemically failing for this domain
(the skill exists but agents never reach for it), which needs an R&D fix
(e.g. F5 domain-tagged schema), not another bundle tweak.

### What the two paths teach

- **Path A** shows when to **shrink** the sample: the domain is healthy, keep
  auditing but lighter.
- **Path B** shows when to **alert**: repeated real under-adoption escalates
  out of the per-cycle loop to R&D.

---

## Quick reference card

| Phase | You do | Source of truth |
|-------|--------|-----------------|
| 1 | Read newest OPEN flag; confirm D15 threshold | `docs/skill-audit-notes.md` |
| 2 | Read sample size; list domain PRs in window | `.claude/state/audit-state.json` + `gh pr list` |
| 3 | One verdict line per PR; tally dirty | your notes |
| 4 | File `type:audit-refinement` PR | `gh pr create` |
| 5 | Advance state machine (clean/dirty rules) | `.claude/state/audit-state.json` |

**Two numbers to remember:** sample starts at **10**, caps at **30**. **Two
streaks to watch:** 3 clean → scale down, 3 dirty → escalate.
