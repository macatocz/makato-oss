---
name: skill-judge
description: >-
  Use when reviewing or auditing a SKILL.md file, scoring skill quality, asking "is this a good
  skill?", improving skill design, or checking if a skill follows patterns. Triggers on: SKILL.md,
  skill review, skill audit, skill score, skill judge, evaluate skill. Do NOT use for general code
  review or security audits.
version: "2.8.0"
license: MIT
compatibility: "Claude Code; no additional tool dependencies"
argument-hint: "[path/to/SKILL.md or skill-name]"
allowed-tools: Read Bash Glob
hooks: ["skill review", "skill audit", "evaluate skill", "skill score", "skill judge", "is this a good skill", "improve skill", "fix skill", "rewrite skill", "skill quality", "skill check"]
metadata:
  Authors: makato
  version: "2.8.0"
  last_updated: "2026-07-14"
  mcp_server: none
---

# Skill Judge

Evaluate Agent Skills against official specifications and patterns derived from 17+ official
examples. 12 failure patterns codified.

**Fully autonomous** — every invocation produces a complete scored evaluation (all 8 dimensions,
D1–D8, 120 points), a grade, and a report with actionable improvements. No confirmation prompts,
no human gates: the skill scores and reports, it never stops to ask what to do next. It does not
edit the target SKILL.md — it produces the assessment and leaves the fix to the operator.

---

## Core Philosophy

> **Good Skill = Expert-only Knowledge − What Claude Already Knows**

Redundant content wastes context that is shared across system prompts, conversation history, and
other Skills. Categorize every section as **[E] Expert** (keep), **[A] Activation** (keep if brief),
or **[R] Redundant** (delete). Target: >70% Expert, <20% Activation, <10% Redundant.

---

## Before Evaluating — Ask Yourself

These four questions shape everything that follows. Answer them before assigning a single score:

1. **What is the single most expensive mistake I could make here?** Inflating D1 because the skill looks polished.
2. **Do I know this domain well enough to judge knowledge delta?** If not, cap D1/D2/D3 at 10 and weight D4/D5/D7/D8 instead.
3. **What pattern is this Skill targeting?** Identify it before scoring — pattern mismatch is a D7 deduction, not a D1 one.
4. **What would an expert already know?** That baseline is your D1 zero-point.

---

## Evaluation Dimensions (120 points total)

Full red/green flags, examples, and anti-pattern tests: **MANDATORY** load
[`references/dimensions.md`](references/dimensions.md) at Step 3 for any dimension scoring below 12
or when the domain is unfamiliar. **Do NOT Load** until you are actively scoring a dimension.

### D1: Knowledge Delta (20 points) — THE CORE DIMENSION

| Score | Threshold |
| ----- | --------- |
| 16-20 | Pure delta — every paragraph earns its tokens; no [R] content |
| 11-15 | Mostly expert; minor [A] sections dilute slightly |
| 6-10  | Mixed; [R] basics coexist with genuine expertise |
| 0-5   | Restates basics Claude already knows |

Classify every section **[E] Expert / [A] Activation / [R] Redundant**. Target: >70% E, <20% A,
<10% R. Count paragraphs before assigning the score — don't estimate the ratio.

### D2: Mindset + Appropriate Procedures (15 points)

| Score | Threshold |
| ----- | --------- |
| 12-15 | Shapes thinking AND provides non-obvious procedures |
| 8-11  | Good balance; either thinking or procedures but not both |
| 4-7   | Domain procedures only; no thinking framework |
| 0-3   | Generic procedures Claude already knows |

**User input pattern**: Freeform "ask the user what X they want" → deduct 2-3 pts from D2. A skill
that collects choices should direct Claude to use `AskUserQuestion` with selectable options; it
delivers a clean value instead of requiring intent parsing.

### D3: Anti-Pattern Quality (15 points)

| Score | Threshold |
| ----- | --------- |
| 12-15 | Expert NEVERs with explicit WHY — things only experience teaches |
| 8-11  | Specific NEVER list with some reasoning |
| 4-7   | Generic warnings ("be careful", "avoid errors") |
| 0-3   | No anti-patterns |

A dedicated anti-patterns section with **WHY on each item** is the reliable path to 12+.

### D4: Specification Compliance — Description Especially (15 points)

| Score | Threshold |
| ----- | --------- |
| 14-15 | Perfect frontmatter + description with WHAT + WHEN + trigger KEYWORDS |
| 11-13 | Valid frontmatter; description has WHAT but weak WHEN |
| 6-10  | Has frontmatter but description is vague |
| 0-5   | Missing frontmatter or YAML parse error |

Required frontmatter fields: `name`, `description`, `version`, `compatibility`; `metadata` with
`Authors/version/last_updated`; `allowed-tools` when Bash runs; `argument-hint`, `mcp_server` where
applicable. Missing field → D4 ≤ 13. YAML parse error → D4 ≤ 5.

**`allowed-tools` field**: Skill uses `Bash(...)` but omits `allowed-tools` → deduct 1-2 pts from D4
(users get a permission prompt on every invocation).

### D5: Progressive Disclosure (15 points)

| Score | Threshold |
| ----- | --------- |
| 14-15 | Decision trees + explicit MANDATORY triggers + "Do NOT Load" guidance |
| 11-13 | Good layering with MANDATORY triggers present |
| 6-10  | References exist but unclear when to load them |
| 0-5   | Everything dumped in SKILL.md (>500 lines, no structure) |

A `references/` directory alone is NOT enough for >10. Each reference needs: (a) an explicit
MANDATORY trigger embedded in the workflow step where it is needed, and (b) a "Do NOT Load" line.
Orphan references that are never triggered score as [R] overhead.

**MANDATORY** references and their triggers in this skill:

| Reference | Trigger |
| --------- | ------- |
| `references/dimensions.md` | MANDATORY at Step 3 when a dimension scores below 12 or domain is unfamiliar |
| `references/failure-patterns.md` | MANDATORY at Step 3 before scoring any dimension — contains Pattern 1–12 tests |
| `references/evaluation-protocol.md` | MANDATORY when starting a full evaluation (Steps 1–6) |
| `references/quick-reference.md` | MANDATORY at Step 5 for report generation |

**Do NOT Load** `references/dimensions.md` or `references/quick-reference.md` during first-pass
orientation of the dimensions table above.

### D6: Freedom Calibration (15 points)

| Score | Threshold |
| ----- | --------- |
| 14-15 | Perfect calibration throughout |
| 11-13 | Good; most scenarios correctly calibrated |
| 6-10  | Partial mismatch in some areas |
| 0-5   | Severe mismatch |

**Rigid rules govern** (no agent judgment overrides): YAML error → D4 ≤ 5; YAML parse = D4 ≤ 5;
`disable-model-invocation` present → flag; `references/` without triggers → D5 ≤ 10; `metadata`
fields missing → D4 ≤ 13. These are binary, not judgment calls.

**Agent judgment governs** (principles apply): E/A/R classification of paragraphs; identifying
which pattern a skill follows; assessing whether a procedure is "non-obvious" for D2; scoring
anti-pattern quality for D3.

### D7: Pattern Recognition (10 points)

| Pattern    | ~Lines | Score signal |
| ---------- | ------ | ------------ |
| Mindset    | ~50    | Creative tasks requiring taste |
| Navigation | ~30    | Multiple distinct scenarios, each needing its own guidance |
| Philosophy | ~150   | Art/creation requiring originality |
| Process    | ~200-300 | Complex multi-step projects with phase gates |
| Tool       | ~300-400 | Precise operations on a specific format or target |

Masterful = 9-10; clear pattern with minor deviations = 7-8; partial = 4-6; none = 0-3.

**Pattern tie-breaking** (use the first matching rule):
- Tool vs Process: centers on a decision tree with format constraints → Tool; workflow with
  checkpoints and phase gates → Process.
- Mindset vs Philosophy: goal is taste/judgment → Mindset; goal is originality and craft quality →
  Philosophy.
- Any pattern vs Navigation: multiple distinct sub-scenarios each needing their own guidance file →
  Navigation.

### D8: Practical Usability (15 points)

| Score | Threshold |
| ----- | --------- |
| 14-15 | Comprehensive: edge cases + error handling + decision trees + fallbacks |
| 11-13 | Clear for common cases |
| 6-10  | Usable with noticeable gaps |
| 0-5   | Confusing, incomplete, or contradictory |

**When evaluating an unfamiliar domain**: weight D4, D5, D7, and D8 heavily — these are
domain-agnostic. Flag D1, D2, and D3 as "domain expertise required" and note the limitation in your
report rather than guessing.

---

## Navigation

| Your situation| What to do|
| --------------| ----------|
| User provides a SKILL.md path| Load the file, run Steps 1–5 in order|
| User asks "is this a good skill?"| Run full evaluation — do not shortcut to a gut-feel score|
| User asks "why did this score low?"| Focus Step 3 on the failing dimension only; cite line evidence|
| User asks to compare two skills| Run full evaluation on each independently; do not anchor the second score to the first|
| Domain is unfamiliar (e.g. Kubernetes-specific skill)| Cap D1/D2/D3 at 10; weight D4/D5/D7/D8 instead|
| Skill is very short (<50 lines)| Check D4 first — short skills often fail on missing frontmatter; D5 can still score 14-15 with good MANDATORY triggers even without references|
| Re-evaluation after improvements| Compare per-dimension deltas; stop at Step 4 if net change ≤2 points|

## Worked Example

**Input skill**: 80-line `deploy-to-k8s` with procedures for running `kubectl apply`.

**Step 1 scan**: 60% of content describes `kubectl` commands Claude already knows.
Sections on `--dry-run` and namespace targeting are [R] redundant. The one [E]
section is the cluster-specific context injection pattern using `KUBECONFIG` env var.

**Score**: D1 = 6 (mixed: 40% expert). D7 = 5 (missing Philosophy and Navigation).
D3 = 4 (one NEVER without WHY). Total = ~72, Grade D.

**Key improvement path**: Move basic `kubectl` commands to
`references/kubectl-cheatsheet.md` with a MANDATORY trigger. Add Philosophy explaining
why cluster-specific context injection is non-obvious. Add NEVER with WHY for
`--dry-run` omission on production namespaces.

**After improvement**: D1 jumps from 6 to 14; D7 from 5 to 8. Total ~95, Grade B.

---

## Calibration Notes

These are the most common evaluator errors — guard against them:

- **Surface quality bias**: Claude-generated skills look polished. Polished ≠ expert. Always classify
  content as E/A/R regardless of how professional it sounds.

- **Long-skill inflation**: A 400-line skill is not inherently better than an 80-line skill. Dense
  expert knowledge outweighs volume.

- **Reference-file credit**: Do NOT award D5 points above 10 just because a `references/` directory
  exists. Only award 14-15 if each file has an explicit MANDATORY trigger AND "Do NOT Load" guidance.

- **Anchoring in re-evaluation**: Do not let the prior score bias the new score. Re-read the skill
  fresh for each dimension.

- **Dunning-Kruger author effect**: Skill authors consistently overestimate their own knowledge
  delta — they cannot see what they know that Claude doesn't, because they don't know what Claude
  knows. Treat every D1 claim with skepticism; verify by asking "would Claude generate this from its
  training data alone?" Default to a lower D1 score when uncertain.

- **Comprehensiveness inflation**: A skill that covers every case from "what is X" through edge
  cases scores D1 ≤ 12 regardless of how thorough it feels. Comprehensiveness means it restates
  basics Claude already has. Expertise means it contains the *non-obvious* subset only practitioners
  discover through failure.

- **Sequential-evaluation drift**: When evaluating a batch, scores drift upward for later skills
  because the evaluator anchors on earlier reference points. Reset to absolute criteria between
  skills; never score a skill relative to the previous one evaluated.

---

## NEVER Do When Evaluating

- **NEVER** give high scores because it looks professional — Claude is trained to produce polished
  output, so surface quality is a systematically misleading signal

- **NEVER** ignore token waste — every redundant paragraph competes with user input and system
  prompts for the same fixed context window

- **NEVER** let length impress you — a 43-line Skill can outperform a 500-line Skill because density
  of expert knowledge matters more than volume

- **NEVER** skip mentally testing the decision trees — a tree that leads to the wrong choice is
  worse than no tree, because it creates false confidence

- **NEVER** forgive explaining basics with "but it provides helpful context" — Claude already has
  that context; restating it wastes tokens and dilutes the expert signal

- **NEVER** overlook missing anti-patterns — their absence means the Skill omits half of expert
  knowledge (knowing what NOT to do)

- **NEVER** assume all procedures are valuable — generic file ops and standard patterns Claude
  already knows add weight without adding knowledge (see Pattern 4: The Checkbox Procedure)

- **NEVER** undervalue the description field — a Skill with great content but poor description is
  never activated and therefore completely useless (see Pattern 6: The Invisible Skill)

- **NEVER** put "when to use" info only in the body — the Agent decides whether to load the Skill
  based on the description alone; body content is invisible at that decision point (see Pattern 7:
  The Wrong Location)

- **NEVER** overlook freeform user-input instructions — when a Skill tells Claude to "ask the user
  what X they want" without specifying `AskUserQuestion`, it produces inconsistent answers and poor
  UX; Skills should direct Claude to use `AskUserQuestion` with selectable options whenever the
  valid answer set is known

- **NEVER** score D5 above 10 because `references/` exists — orphan references (Pattern 3) are worse
  than no references because they create false confidence; verify each file has an explicit
  MANDATORY trigger before awarding points above 10

- **NEVER** treat "comprehensive" as a proxy for "expert" — a skill that is comprehensive
  *because* it restates basics for completeness earns a D1 penalty, not a bonus; the
  evaluator's job is to identify what the skill adds, not what it covers
- **NEVER** score D4 above 5 if the YAML frontmatter has a syntax error — two patterns that
  pass visual inspection but break `yaml.safe_load()`:
  1. **Unquoted `colon: space` in a plain scalar value** — e.g.,
     `compatibility: Requires git. Optional: prettier` — the `": "` after `Optional` is a YAML
     mapping indicator, causing a parse error. Fix: quote the value or use `>-` block scalar.
  2. **Multi-line value at column 0 without a block scalar indicator** — e.g., a description
     that wraps to a new line starting at col-0 without `>-` or `|`. The second line is
     interpreted as a new mapping key, not a continuation. Fix: use `description: >-` and
     indent continuation lines by 2+ spaces.
  WHY: YAML errors cause the plugin loader to skip the entire SKILL.md silently — no error
  message, skill simply never appears in `/skills`. A skill with a YAML error is operationally
  worthless regardless of content quality.

- **NEVER** score D4 above 10 if `disable-model-invocation: true` is set without flagging it
  — this field hides the skill from the AI system-reminder; the skill can only be invoked via
  `/skill-name` and is never auto-suggested from user intent keywords. Deduct 2–3 points from D4
  and note it in the report unless the skill body explicitly states it is a pure bash-script tool.
  WHY: the side-effect (hidden from system-reminder) is non-obvious from the field name; a skill
  invisible to the AI cannot fulfill its description's activation criteria regardless of how well
  the trigger keywords are written.

- **NEVER** score D4 above 13 without verifying every required frontmatter field is present
  and correctly spelled — `mcp_server`, `argument-hint`, `compatibility`, `allowed-tools`,
  `metadata` with `Authors/version/last_updated` are all required; a missing field silently
  prevents the skill from activating in the correct context. WHY: Claude Code uses the
  description and frontmatter to decide whether to load a skill; incomplete frontmatter
  produces a skill that appears correct but never fires or fires with wrong tool permissions

- **NEVER apply sequential scoring pressure** — when evaluating multiple skills in one
  session, the first skill anchors your scale; evaluate each skill independently against the
  rubric, not relative to the previous. WHY: sequential anchoring causes score drift of 3-5
  points per session; D1 calibration is especially vulnerable because the first "pure
  knowledge delta" example biases subsequent assessments — reset to absolute criteria between
  every skill evaluation

---

## Second Worked Example (Borderline Case)

**Input skill**: 220-line `create-jira-ticket` skill with step-by-step Jira API calls,
field definitions, and project key lookups.

**Step 1 scan**: 80% of content describes standard REST API calls and Jira field names Claude
knows from training. The [E] sections: (a) org-specific epic key mapping table, (b) field ID
`customfield_10240` is the sprint field in this org, (c) why Story Points default to 3 for
spikes but 5-8 for features in this team's velocity model.

**Score**: D1 = 9 (mixed: org-specific config is expert, but the API mechanics are [R]).
D5 = 8 (references exist but no MANDATORY triggers). D7 = 6 (no Philosophy). Total ≈ 97 → Grade B.

**Key insight**: The skill *is* expert for this org, but the expert content is buried inside
generic API boilerplate. Move the generic Jira API steps to `references/jira-api-basics.md`
with "Do NOT Load for standard ops." The org-specific epic map and field IDs belong in the
main body. After that, D1 jumps from 9 to 15.

**Trap**: A naive evaluator would give this D1 = 14 because it "contains org-specific config."
The expert calibration is to notice the ratio: 80% generic, 20% expert. Weighted D1 = 0.2×20
= 4 + baseline ≈ 9. This is the comprehensiveness-inflation failure mode.

---

| Blocker| Recovery|
| --------------------------------------------------| -----------------------------------------------------------------------------------|
| File is not named `SKILL.md` (e.g. `skill.md`)| Flag immediately — Claude Code only loads `SKILL.md` (exact case); score D4 at 0|
| SKILL.md has no frontmatter| Score D4 at 0, note "invalid format", evaluate remaining dimensions|
| SKILL.md is empty or missing| Do NOT ask — emit a structured `Cannot evaluate` result stating the resolved path, whether the file is missing or empty (0 bytes), and the one input needed (a non-empty `SKILL.md`); then stop. No score, no report body|
| Skill spans multiple files (commands/, sub-skills)| Evaluate SKILL.md as the entry point; score sub-files under D5|
| Domain is completely unfamiliar| Cap D1/D2/D3 at 10, flag "domain expertise required" in each|
| No `references/` directory| Score D5 on SKILL.md structure alone — not every skill needs references|

---

## Evaluation Workflow (Steps 1–6)

Every invocation runs the full evaluation — there are no shortcut modes.

**Step 1**: First-pass E/A/R scan. Mark every section Expert / Activation / Redundant.

**Step 2**: Structure analysis. Check frontmatter validity, line count, references, pattern.

**Step 3**: Score each dimension.

- **MANDATORY**: Load [`references/failure-patterns.md`](references/failure-patterns.md) **before
  scoring any dimension**. It contains Pattern 1–12 recognition tests that directly inform D1–D3.
  **Do NOT skip** — evaluating without it produces inflated D1/D3 scores.
- **MANDATORY**: Load [`references/dimensions.md`](references/dimensions.md) for any dimension
  scoring below 12, or when the domain is unfamiliar. **Do NOT Load** for dimensions already
  clearly above threshold.
- **MANDATORY**: Load [`references/evaluation-protocol.md`](references/evaluation-protocol.md) for
  the full Step 1–6 protocol, orientation questions, and re-evaluation guidance. **Do NOT Load**
  during a first-pass orientation of the dimensions table above.

**Step 4**: Calculate total. D1+D2+D3+D4+D5+D6+D7+D8. Grade: A 108-120, B 96-107, C 84-95, D 72-83, F <72.

**Step 5**: Generate report.

- **MANDATORY**: Load [`references/quick-reference.md`](references/quick-reference.md) to write
  the report using the canonical template. **Do NOT Load** before Step 5 — it is only needed at
  report generation time.

**Step 6**: Re-evaluate. Compare per-dimension deltas to prior report. Stop at ≤2-point delta:
"Score is stable."

- **NEVER skip evaluating D4 (Spec Compliance) even when the skill is clearly expert-level** —
  WHY: missing frontmatter fields break automated tool triggering regardless of content quality;
  a 120/120 content skill that fails to trigger because mcp_server is missing is operationally
  worthless.
- **NEVER conflate 'comprehensive' with 'high quality' in D8** — WHY: a 500-line skill with
  detailed procedures but no decision trees scores lower than a 200-line skill with clear worked
  examples; comprehensiveness without navigability increases cognitive load; measure usefulness,
  not length.
- **NEVER rate D3 (Anti-Patterns) above 12 unless NEVER items include explicit WHY reasoning** —
  anti-patterns without WHY are style preferences, not expert knowledge; WHY transforms a
  prohibition into a transferable lesson. WHY: a NEVER list without WHY requires trusting the
  author's judgment rather than understanding the failure mode.
