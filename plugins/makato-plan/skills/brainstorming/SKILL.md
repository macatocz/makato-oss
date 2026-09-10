---
name: brainstorming
description: >-
  Structured divergent-convergent ideation on a feature — brainstorm, explore ideas, ideate,
  creative exploration, explore feature angles. Use when starting a new feature that needs
  ideation before PRD.
version: "1.3.1"
modelRole: designer
allowed-tools: [Bash]
mcp_server: github
metadata:
  last_updated: "2026-08-05"
---

# Brainstorming Ideas Into Designs

Structured exploration of a feature through divergent ideation (62 techniques) followed by
convergent selection (top 3-5 concepts with rationale). Produces documented decisions ready for
grilling and PRD creation.

## When to Use

- Starting work on a new feature that needs creative exploration
- Need structured ideation before committing to an approach
- Want to ensure all angles are explored before PRD
- Comparing multiple approaches to a feature

## When NOT to Use

- Feature is already well-defined with clear requirements (go straight to PRD)
- Quick bug fix or small change (no brainstorming needed)
- Technical refinement of already-shaped stories

---

## Anti-patterns

These are failure modes that only practitioners learn through repeated facilitation errors. Each
NEVER has a concrete WHY — the non-obvious reason most violators don't discover until it's too late.

**NEVER organize ideas into themes mid-ideation (Step 4).**
Why: Taxonomizing forces evaluation — the brain switches from generative to analytical mode the
moment you name a category. Once a user sees "Performance Ideas" and "UX Ideas" on the screen,
they start fitting new ideas into existing buckets rather than generating orthogonal concepts.
This collapses the divergence phase prematurely. Clustering belongs in Step 5 only.

**NEVER block on an idea count — use coverage gates, not volume gates.**
Why: A team can generate 50 variants of "make the button bigger" and zero architectural alternatives.
Count-based gates create the illusion of thorough exploration while allowing a narrow idea space.
The convergence gate must verify at least 3 domain perspectives (User/UX, Business/Value,
Process/Operations, Edge cases/Risks) — not that a magic number was hit.

**NEVER skip rejected-option capture at convergence (Step 6).**
Why: Six months later a new team member proposes the same approach you rejected. Without documented
rationale they have no signal it was considered — they re-investigate, re-present, and consume
planning cycles. The cost of not writing "why we didn't pick X" is repeated re-evaluation of
the same solution space in every subsequent planning cycle.

**NEVER generate more than 2 ideas in a row as the facilitator.**
Why: The moment Claude produces a stream of ideas, the user's cognitive posture shifts from
co-creator to judge. They begin reacting to Claude's ideas rather than generating their own.
The outcome is a list of Claude's ideas with user stamps — not the user's domain expertise
expressed as concepts. The facilitator's ideas are invariably lower-quality than the user's
because Claude lacks operational and business context.

**NEVER write the spec folder path as `pwd`-relative; always anchor to REPO_ROOT.**
Why: Sub-agents inherit an unpredictable working directory. A `specs/{slug}/` relative path
that resolves correctly from the user's cwd silently resolves to a different location when the
doc-writer agent is dispatched. The canonical anchor is:
```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
```
All artifact paths must be expressed as `$REPO_ROOT/specs/{slug}/...` in agent dispatch prompts.

**NEVER skip the open-questions startup check when `decisions.md` exists (Step 1.3).**
Why: The parking lot persists open questions across sessions for exactly this reason. Brainstorming
over a question that is already parked generates ideas that collapse when the unknown resolves.
Users forget they parked a question; the startup check is the only guard against re-diverging into
an already-identified unknown.

---

## Constants

- **CONTEXT_SCOUT_TOKEN_BUDGET: 2000** — Maximum tokens returned by a single context-scout dispatch.

---

## Workflow

### Step 1: Detect Feature Origin

When the user runs `/brainstorming [arg]`, detect the origin in this order:

**1. GitHub Issue** — arg matches `https://github.com/owner/repo/issues/123` or short form
`owner/repo#123`:

Use the GitHub MCP to fetch the issue:

```text
mcp: mcp__plugin_general_github-mcp__get_issue(owner, repo, issue_number)
```

Extract: title, body. Slug is derived from the issue title (kebab-case, max 60 chars).
Record `source: "github:{owner}/{repo}#{number}"` — this will be written to `stories.json` later.

Offer to import attachments if any exist on the issue.

**2. Existing slug** — `specs/{arg}/` directory exists on disk:

```bash
ls specs/{arg}/
```

If found → resume prior session. Load existing `brainstorm.md` and `decisions.md`.

**3. Plain text** — any other non-empty arg:

Use the arg as the feature description. Derive the slug from it:

- Lowercase, replace spaces and special chars with hyphens
- Truncate to 60 chars
- Example: "Checkout cart redesign" → `checkout-cart-redesign`

**4. No arg** — auto-detect most recently modified `specs/*/` folder:

```bash
ls -td specs/*/ | head -1
```

If a folder exists → offer to resume it. If no `specs/` folder or user declines → prompt:
"Describe the feature in one line:" and derive slug from their answer.

---

After detecting origin, determine the spec folder path: `specs/{slug}/`

Present a brief summary and confirm this is the feature to brainstorm.

---

### Step 1.1: Import Attachments (GitHub Issue origin only)

Skip this step if origin was plain text or existing slug with no new attachments.

Check if reference files already exist:

```bash
ls specs/{slug}/reference/original/
```

**If `reference/original/` exists and is non-empty**: prior import completed. Load converted
markdown from `reference/*.md` and images from `reference/original/` as context. Inform the user:

> "Found existing reference files — loading as context."

**If no reference directory or empty**: check for attachments on the GitHub Issue.

If attachments exist, offer download:

```text
AskUserQuestion:
  question: "Issue has {N} attachments. Import for brainstorming context?"
  options:
    - "Yes — download all (Recommended)"
    - "Images only"
    - "Skip — brainstorm without attachments"
```

**If "Yes — download all" accepted:**

1. Download every attachment to `specs/{slug}/reference/original/`. Write base64-decoded bytes
   to disk for every attachment — visual inspection is not a substitute for the write step.
   Skipping the write step is a bug.

2. Resolve the absolute path to the reference directory:

   ```bash
   realpath specs/{slug}/reference/original/
   ```

3. Convert non-image files to markdown using markitdown:

   ```text
   mcp: markitdown convert_to_markdown(uri: "file://{resolved_path}/{filename}")
   ```

   Save output as `specs/{slug}/reference/{filename}.md`.

4. Verify every attachment landed on disk before continuing:

   ```bash
   ls specs/{slug}/reference/original/
   ```

5. Images remain in `reference/original/` — read them visually via the Read tool (multimodal)
   when needed during ideation.

**If "Images only" accepted:**

1. Download image attachments to `specs/{slug}/reference/original/`.
2. Verify with `ls specs/{slug}/reference/original/` that every image is saved.
3. No conversion step.

**Directory layout:**

```text
reference/
├── feature-brief.md      ← converted markdown (what skills consume as text)
└── original/
    ├── feature-brief.pptx  ← source binary (provenance)
    └── screenshot.png       ← images read directly via Read tool
```

Use markdown files in `reference/` as text context. For images in `reference/original/`,
describe them visually using the Read tool (multimodal).

---

### Step 1.2: Scan Repository Context

Spawn the `context-scout` agent with the feature summary and keywords. Include in the dispatch
prompt: the feature summary, extracted keywords, and instruction to return synthesized insights
(not file paths).

The agent scans `context/{REPO_NAME}/` directories and returns distilled findings — 2-3 sentences
per relevant area covering constraints, existing patterns, and architectural decisions.

**If no `context/` directory exists**: skip this step silently. Note:

> "No repository context found — proceeding with feature information only."

Use the scout's synthesized findings directly as background context for ideation. Do not re-read
the underlying files.

---

### Step 1.3: Open Questions Startup Check

Check if a decisions file already exists for this feature:

```bash
ls specs/{slug}/decisions.md
```

If found, read the Open Questions table. If questions exist:

```text
AskUserQuestion:
  question: "Found {N} open questions from a prior session. Revisit any before starting?"
  options:
    - "Yes — show me the questions (Recommended)"
    - "No — start fresh"
```

If yes: present each open question and resolve or re-park.
After all questions are resolved or re-parked, proceed to Step 2.

---

### Step 2: Session Setup

Check for existing brainstorm:

```bash
ls specs/{slug}/brainstorm.md
```

**If found**: offer to continue from where it left off or start fresh.

- If continuing: skip to Step 3 (Technique Selection) — goals and constraints are already set.
- If starting fresh: proceed through the Session Setup steps below.

**If new session**:

1. Confirm the brainstorming topic (derived from feature description + context)
2. Set goals: what does a successful brainstorm look like?
3. Identify known constraints (from feature description + context-scout + attachments)
4. Ask time available:

```text
AskUserQuestion:
  question: "How much time for this brainstorming session?"
  options:
    - "Quick (15 min) — focused, 1 technique"
    - "Standard (30 min) — 2-3 techniques, thorough exploration"
    - "Deep (60+ min) — multiple techniques, exhaustive coverage"
```

---

### Step 3: Technique Selection

Load @references/techniques.md — MANDATORY at Step 3 ONLY. Do NOT preload at skill start.

Present selection options:

```text
AskUserQuestion:
  question: "How should we pick brainstorming techniques?"
  options:
    - "AI-recommended based on the feature type (Recommended)"
    - "Browse by category and pick"
    - "Random selection"
    - "Quick start: 5 Whys + Mind Mapping"
```

For AI-recommended: analyze the feature description and suggest 2-3 techniques from different
categories that fit the problem type (e.g., deep analysis for ambiguous problems, creative for
UX features).

Require at least 2 techniques before proceeding (unless Quick 15-min session — 1 technique is
fine).

---

### Step 4: Ideation

Load @references/facilitation-rules.md — MANDATORY at Step 4 ONLY. Do NOT preload at skill start.
Load @references/open-questions.md — MANDATORY at Step 4 ONLY when a question needs parking.
Do NOT load open-questions.md speculatively; load it only when a question surfaces during ideation.

Apply selected techniques one at a time. For each technique:

1. Explain it briefly to the user
2. Facilitate: ask probing questions that pull ideas OUT of the user
3. Track idea count visibly: "That's idea #23. Let's keep going!"

**Convergence gate (coverage-based, NOT number-based):**

Before moving to Step 5, verify:

- At least 2 techniques have been applied (1 for Quick mode)
- At least 3 domain perspectives have been explored: User/UX, Business/Value,
  Process/Operations, Edge cases/Risks

Track idea count as a motivational metric but do not block on it. If the user feels they've
covered enough ground, let them move on.

**Anti-bias pivot** — every ~10 ideas or when the user gets repetitive, prompt a perspective
shift:

- User/UX perspective → Business/Value perspective
- Business/Value → Process/Operations
- Process/Operations → Edge cases/Risks

**Energy checkpoint** every 4-5 exchanges.

**If the user is stuck**: offer a starting angle from the current technique rather than generating
ideas for them.

**Parking questions**: If an unanswerable question surfaces during ideation, park it (note as Q#
for later persistence to decisions.md). Use @references/open-questions.md (already loaded above)
for parking rules.

---

### Step 5: Pattern Finding

Review all generated ideas. Cluster into 5-8 themes.

For each theme:

- Give it a memorable name (e.g., "Speed Demons", "Safety Nets", "User Delight")
- List which ideas belong to it
- Extract insight: what does this cluster tell us?

Present the themed clusters to the user. Ask if any ideas are miscategorized or if they see
patterns the clustering missed.

---

### Step 6: Convergence (Top 3-5)

For each theme, ask the user to rate 1-5 (or skip).

Select top 3-5 ideas from highest-rated themes. For each finalist:

- Problem it solves
- High-level approach
- Key risks
- Why better than alternatives considered

**Capture rejected options with rationale.** Future team members will re-propose them without
understanding why they were dismissed.

Rank final concepts by recommendation strength.

---

### Step 7: HTML Review & Approval Gate

> **MAKATO_PLAN_NO_HTML guard**: Check `MAKATO_PLAN_NO_HTML` env var. If set, skip this HTML generation step entirely and proceed to Step 8.

Dispatch the `doc-writer` agent to generate the HTML review. Include in the prompt:

- **MODE**: html-review
- **TEMPLATE_PATH**: the absolute path to this skill's `templates/brainstorm-review.html`
- **OUTPUT_PATH**: `specs/{slug}/reviews/brainstorm-review.html`
- **CONTENT**: structured brainstorming results including:
  - feature_name (feature summary)
  - date (today)
  - slug (feature slug)
  - stats: idea_count, theme_count, top_count, decision_count
  - observations (context-scout synthesis)
  - key_decisions (convergence decisions, table rows)
  - top_concepts (ranked top 3-5 with rationale) — doc-writer must expand `{{CONCEPT_SLIDES}}`
    into one full `<div class="slide">` per concept, each with its own per-concept feedback
    textarea (see template comments for exact structure)
  - rejected_ideas (rejected options with reasons)
  - open_questions (parked questions)

Once the agent returns, open the HTML file in the browser (use the command for the user's OS):

Detect the OS by running:

```bash
uname -s 2>/dev/null || echo "Windows"
```

`Darwin` → macOS, `Linux` → Linux, anything else → Windows.

```bash
open specs/{slug}/reviews/brainstorm-review.html        # macOS
xdg-open specs/{slug}/reviews/brainstorm-review.html    # Linux
start specs/{slug}/reviews/brainstorm-review.html       # Windows
```

Tell the user:

> "I've opened the brainstorming summary in your browser. Review the observations, decisions,
> and top concepts. Let me know if anything needs revision, or approve to write the final
> artifacts."

**If revisions requested**: adjust content and re-dispatch doc-writer.
**If approved**: proceed to Step 8.

---

### Step 8: Write Artifacts

Resolve the repo root before dispatching — sub-agents inherit an unpredictable cwd:

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
```

> **MAKATO_PLAN_NO_HTML guard**: Check `MAKATO_PLAN_NO_HTML` env var. If set, skip this doc-writer dispatch entirely and proceed to the next step.

Dispatch the `doc-writer` agent to write the canonical files. Include in the prompt:

- **MODE**: write-artifacts
- **TEMPLATE_PATHS**: absolute paths to this skill's `templates/brainstorm-template.md` and
  `templates/decisions-template.md`
- **OUTPUT_PATH**: `$REPO_ROOT/specs/{slug}/`
- **CONTENT**: the full structured brainstorming results (same as Step 7, plus all ideas by
  theme)

Files written:

- `$REPO_ROOT/specs/{slug}/brainstorm.md` — all ideas, themes, top concepts
- `$REPO_ROOT/specs/{slug}/decisions.md` — decisions + open questions with Q# IDs

---

### Step 9: Status Confirmation & Handoff

```text
AskUserQuestion:
  question: "Brainstorm captured. Mark as Approved for grilling phase?"
  options:
    - "Yes — mark as Approved (Recommended)"
    - "Keep as Draft — I want to review first"
```

**If Approved**: update Status field in brainstorm.md from Draft to Approved.

**If Draft**: the brainstorm.md remains with Status: Draft. Remind the user:

> "Brainstorm saved as Draft in `specs/{slug}/brainstorm.md`. Run /brainstorming again when ready to approve."

Display completion hook:

```text
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Brainstorm Complete! What's Next?

Your ideas are captured and decisions documented.

Recommended next steps:
  1. Run /stress-test-artifact — stress-test your decisions
  2. Run /create-prd — formalize into requirements

The grill will challenge assumptions, probe edge cases,
and strengthen your decisions before committing to PRD.
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```
