---
name: crafting-effective-readmes
description: >-
  Use when creating, updating, or reviewing project documentation for any
  project type. Triggers on: "README", "readme", "docs", "documentation",
  "getting started", "document this", "add docs", "write a readme", "update
  the docs", "project docs", "how do I use this", or any request to explain
  or document a project for others. Do NOT use for: general prose editing
  (use writing-clearly-and-concisely), API reference generation, or in-code
  docstrings.
version: "1.5.0"
argument-hint: "[existing-readme-path] or 'new'"
allowed-tools: Read Write Glob
metadata:
  Authors: makato-doc team
  last_updated: "2026-08-05"
---

# Crafting Effective READMEs

## Tools

| Reference | Load trigger | Do NOT load |
| --------- | ------------ | ----------- |
| `using-references.md` | **MANDATORY**: any new README before picking a template | For section updates to existing READMEs |
| `templates/oss.md` | **MANDATORY**: new OSS README | All other project types |
| `templates/internal.md` | **MANDATORY**: new internal/team tool README | All other project types |
| `templates/personal.md` | **MANDATORY**: new personal project README | All other project types |
| `templates/xdg-config.md` | **MANDATORY**: new config folder README | All other project types |
| `section-checklist.md` | **MANDATORY**: adding/reviewing sections or post-draft check | When creating a brand-new README from template |
| `style-guide.md` | **MANDATORY**: before drafting any README body | Do NOT load for quick section-add reviews |
| `references/art-of-readme.md` | **MANDATORY**: README feels complete but flat — needs reader-journey critique | All other cases; do not load proactively |
| `references/make-a-readme.md` | **MANDATORY**: unsure what to include in a specific section (Prerequisites, Badges, ToC) | When the loaded template already covers the section |
| `references/standard-readme-spec.md` | **MANDATORY**: OSS project targeting spec compliance or automated README linting | Non-OSS projects |
| `references/standard-readme-example-minimal.md` | **MANDATORY**: OSS library or CLI that needs a minimal footprint | Full-featured OSS or non-OSS projects |
| `references/standard-readme-example-maximal.md` | **MANDATORY**: full OSS README with badges, ToC, Contributing, Changelog | Simple projects or non-OSS |

## Workflow

### Step 1: Identify the primary audience and template

Ask: **Who will read this? What do they need to go from zero to working?** This frames every section
decision that follows. Pick the template for the **primary audience** — borrow additional sections
from other templates afterward.

| Situation | Template |
| --------- | -------- |
| New README — OSS project | `templates/oss.md` |
| New README — internal/team tool | `templates/internal.md` |
| New README — personal project | `templates/personal.md` |
| New README — config folder | `templates/xdg-config.md` |
| Adding or reviewing a section | `section-checklist.md` |
| Existing README missing most sections | Treat as new — pick template above |
| Unsure which type applies | Ask the user before loading any template |

### Step 2: Read the Style Guide before drafting

`style-guide.md` contains common README anti-patterns and the NEVER list. Read it in full before
drafting anything — skipping this step is how anti-patterns get reintroduced.

### Step 3: Draft in expert order — Usage first, Installation second

Counter-intuitively, draft the **Usage** section before **Installation**. Writing the primary
command or invocation first reveals which prerequisites actually matter, preventing
over-specified install steps — the most common source of first-run support tickets. It also
forces the Why/pitch vocabulary to align with the literal symbols the reader will type.

Expert heuristics to apply while writing each section:

- **Keep the dead zone empty.** Everything between "install complete" and "first successful run"
  gets scanned past. Readers in execution mode scan for the next command, not for explanatory
  prose. Move all context to after the first working example.
- **Audit vocabulary alignment between Why and Usage.** If Why says "streaming pipeline" but
  Usage shows `run_job()`, readers must mentally bridge the gap at the moment of highest
  attention. That gap is a drop-off point — match the term used in the pitch to the symbol
  in the code sample.
- **Ask "what question would a reader have at exactly this point?"** — not "what do I know
  about this topic?" These produce structurally different answers: the first gives the reader
  their next action, the second gives the author's mental model.
- **Apply the progressive disclosure test:** read the README as if each paragraph is the last
  one the user might read before giving up. Would they have enough to take the next step?
  If not, reorganize so earlier sections enable partial completion.

### Step 4: Post-draft coverage check

Scan `section-checklist.md` to confirm no required section was missed for this project type.
The most surprising differences: config folders skip Installation and use "What's Here" instead;
internal tools always need Architecture; only OSS needs License.

## Mindset

**The reader's next action, not the author's knowledge** — every section must answer "what do I do
next?" not "what does the author know?" This is the organizing principle that explains why
Installation before Why fails, why fictional examples erode trust, and why writing for your
6-months-future self beats writing for peers who already share your context.

**Scan before you read** — readers scan headings to decide if a README is worth reading in full.
A README with poor heading choices fails the scan test before the reader reaches the content.
Write headings as entry points, not as chapter titles.

**README is a marketing document before it is a reference.** The first 10 lines determine whether
a stranger invests the next 5 minutes — they must answer: what is this, who should care, and what
does success look like? The expert mistake is writing the opening for yourself (you already know
why the project exists). The best README authors write the first 10 lines **last** — only after
drafting the full content do they understand what actually matters to a first-time visitor.

## Anti-patterns

- **NEVER put Installation before Why** — readers abandon READMEs when they cannot understand
  why they should care; the "why" is the advertisement, not the setup steps. WHY: a user who
  doesn't understand the value won't finish reading the install command; move the problem
  statement and benefit to the first paragraph, install to the second.
- **NEVER use unverifiable performance claims** ("10x faster", "blazing fast", "99.9% uptime")
  — these read as marketing noise and reduce trust in the entire document. WHY: a claim without
  a benchmark source cannot be evaluated; readers learn to skip unverifiable superlatives, which
  means your real content gets skipped too.
- **NEVER make the example fictional** — a real command with actual output builds more trust
  than a synthetic `your-app-name` placeholder. WHY: fictional examples require the reader to
  mentally translate them; a real example proves the tool works and shows the exact output
  format the reader will see.
- **NEVER write for your peers** — write for your 6-months-future self who has forgotten
  everything; assume the reader has zero context about the project's history or jargon. WHY:
  the author's curse (knowing too much) is the single biggest source of README gaps; every
  "obvious" assumption becomes a support request six months later.
- **NEVER write a README for completeness — write it for the reader's next action** — every
  section should answer "what do I do next?" not "what does the author know?". WHY: documentation
  completeness is not the goal; the goal is getting the reader from zero to working.
- **NEVER ship an 80%-complete README** — if a section is present but incomplete, finish it or
  remove it entirely. WHY: a half-complete section teaches the reader that the README cannot be
  trusted; they stop reading before reaching the complete sections. An absent README is honest
  about its gaps; a near-complete README that fails at the last step destroys trust in all
  future documentation from the same team.
- **NEVER lead with architecture before installation** — readers arrive with a specific goal
  (try the tool, fix the config, understand a flag); they quit on abstractions they haven't
  earned yet. WHY: cognitive overhead before payoff is the #1 README abandonment trigger; the
  architecture explanation only lands when it can attach to a concrete mental model the reader
  has already built by running the tool.
- **NEVER write the README before the feature API is stable** — documentation written too early
  describes an idealized interface that diverges from the final implementation, creating
  technical debt in docs rather than code. WHY: premature documentation locks design decisions
  before implementation reveals what the interface should actually be; it also signals false
  maturity to potential contributors, who arrive expecting the documented behavior and find
  something different.
- **NEVER use past tense in setup instructions** ("changed the config to", "created a file") —
  past tense reads as retrospective narrative, not imperative instruction. WHY: imperative mode
  ("change the config") activates action-oriented working memory while past tense activates
  declarative memory recall; readers in execution mode treat past-tense text as background
  narrative and skip over it without acting.

## Philosophy

A README is a conversion funnel, not a reference document. Its job is to convert a stranger into
a user, a user into a contributor, and a contributor into a maintainer. Every structural decision
— section order, example realism, audience framing — is a conversion decision. The reader does
not read linearly; they scan for the answer to their current question. Expert README authors
write headings that work as standalone answers, not as chapter labels.
