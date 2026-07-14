---
name: skill-judge
description: >-
  Use when reviewing or auditing a SKILL.md file, scoring skill quality, asking "is this a good
  skill?", improving skill design, or checking if a skill follows patterns. Triggers on: SKILL.md,
  skill review, skill audit, skill score, skill judge, evaluate skill. Do NOT use for general code
  review or security audits.
version: "2.8.0"
license: MIT
argument-hint: "[path/to/SKILL.md or skill-name]"
allowed-tools: Read Bash Glob
hooks: ["skill review", "skill audit", "evaluate skill", "skill score", "skill judge", "is this a good skill", "improve skill", "fix skill", "rewrite skill", "skill quality", "skill check"]
metadata:
  Authors: makato
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

## Evaluation Dimensions (120 points total)

Detail on each dimension's red flags, examples, and anti-pattern tests is in
[`references/dimensions.md`](references/dimensions.md) — loaded conditionally at Step 3.

### D1: Knowledge Delta (20 points) — THE CORE DIMENSION

| Score| Criteria|
| -----| --------------------------------------------------------------------|
| 0-5| Explains basics Claude knows (what is X, standard library tutorials)|
| 6-10| Mixed: some expert knowledge diluted by obvious content|
| 11-15| Mostly expert knowledge with minimal redundancy|
| 16-20| Pure knowledge delta — every paragraph earns its tokens|

### D2: Mindset + Appropriate Procedures (15 points)

| Score| Criteria|
| -----| --------------------------------------------------------------------------|
| 0-3| Only generic procedures Claude already knows|
| 4-7| Has domain procedures but lacks thinking frameworks|
| 8-11| Good balance: thinking patterns + domain-specific workflows|
| 12-15| Expert-level: shapes thinking AND provides procedures Claude wouldn't know|

**User input pattern**: When a skill needs to collect choices from the user, it should direct Claude
to use `AskUserQuestion` with selectable options rather than asking in freeform prose. Freeform
questions produce inconsistent answers and require Claude to parse intent; `AskUserQuestion` gives
the user a structured UI and delivers a clean value. Deduct 2-3 points from D2 when a skill solicits
choices via prose ("ask the user what X they want") without specifying `AskUserQuestion`.

### D3: Anti-Pattern Quality (15 points)

| Score| Criteria|
| -----| ----------------------------------------------------------------------|
| 0-3| No anti-patterns mentioned|
| 4-7| Generic warnings ("avoid errors", "be careful", "consider edge cases")|
| 8-11| Specific NEVER list with some reasoning|
| 12-15| Expert-grade anti-patterns with WHY — things only experience teaches|

### D4: Specification Compliance — Especially Description (15 points)

| Score| Criteria|
| -----| ------------------------------------------------------------------------|
| 0-5| Missing frontmatter, invalid format, or YAML parse error (colon-space in unquoted value; multi-line at col-0 without `>-`/`\|` block scalar)|
| 6-10| Has frontmatter but description is vague or incomplete|
| 11-13| Valid frontmatter, description has WHAT but weak on WHEN|
| 14-15| Perfect: comprehensive description with WHAT, WHEN, and trigger keywords|

**`allowed-tools` field**: If the skill runs any Bash commands, it should declare `allowed-tools` in
the frontmatter to pre-approve them — otherwise users are prompted for permission on every
invocation. Deduct 1-2 points from D4 when a skill uses `Bash(...)` calls but omits `allowed-tools`.
Skills that run no shell commands do not need this field.

### D5: Progressive Disclosure (15 points)

| Score| Criteria|
| -----| --------------------------------------------------------------------|
| 0-5| Everything dumped in SKILL.md (>500 lines, no structure)|
| 6-10| Has references but unclear when to load them|
| 11-13| Good layering with MANDATORY triggers present|
| 14-15| Perfect: decision trees + explicit triggers + "Do NOT Load" guidance|

### D6: Freedom Calibration (15 points)

| Score| Criteria|
| -----| -----------------------------------------------------------------------------|
| 0-5| Severely mismatched (rigid scripts for creative tasks, vague for fragile ops)|
| 6-10| Partially appropriate, some mismatches|
| 11-13| Good calibration for most scenarios|
| 14-15| Perfect freedom calibration throughout|

### D7: Pattern Recognition (10 points)

| Pattern| ~Lines| When to Use|
| ----------| ------| --------------------------------------|
| Mindset| ~50| Creative tasks requiring taste|
| Navigation| ~30| Multiple distinct scenarios|
| Philosophy| ~150| Art/creation requiring originality|
| Process| ~300| Complex multi-step projects|
| Tool| ~400| Precise operations on specific formats|

| Score| Criteria|
| -----| -------------------------------------------------------|
| 0-3| No recognizable pattern, chaotic structure|
| 4-6| Partially follows a pattern with significant deviations|
| 7-8| Clear pattern with minor deviations|
| 9-10| Masterful application of appropriate pattern|

**Pattern tie-breaking**: When a Skill sits between two patterns, ask:

- Tool vs Process: Does it center on a decision tree with format constraints (→ Tool) or a workflow
  with checkpoints and phase gates (→ Process)?

- Mindset vs Philosophy: Is the goal taste/judgment (→ Mindset) or originality and craft quality (→
  Philosophy)?

- Any pattern vs Navigation: Does it contain multiple distinct sub-scenarios that each need their
  own guidance file (→ Navigation)?

### D8: Practical Usability (15 points)

| Score| Criteria|
| -----| --------------------------------------------------------------|
| 0-5| Confusing, incomplete, contradictory, or untested guidance|
| 6-10| Usable but with noticeable gaps|
| 11-13| Clear guidance for common cases|
| 14-15| Comprehensive coverage including edge cases and error handling|

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

**MANDATORY**: Load [`references/evaluation-protocol.md`](references/evaluation-protocol.md) when
conducting a full evaluation (Steps 1-6). Contains the step-by-step protocol, orientation
questions, grade scale, and re-evaluation guidance.

**Do NOT Load** during a first-pass orientation of the dimensions table above — load only when
you begin the full evaluation (every invocation runs the full evaluation).

### Step 3: Score Each Dimension

Score each dimension using the rubric in [Evaluation Dimensions](#evaluation-dimensions-120-points-total).
Assign score with one-line evidence-backed justification per dimension.

### Steps 4–6: Grade, Report, Re-evaluate

**MANDATORY**: Load [`references/evaluation-protocol.md`](references/evaluation-protocol.md) to
execute Steps 4–6 (grade calculation, report generation, and iterative
re-evaluation). **Do NOT Load** for a first-pass orientation — load only when actively scoring.

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
