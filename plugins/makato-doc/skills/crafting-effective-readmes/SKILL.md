---
name: crafting-effective-readmes
description: Use when creating, updating, or reviewing project documentation for any project type. Triggers on: "README", "readme", "docs", "documentation", "getting started", "document this", "add docs", "write a readme", "update the docs", "project docs", "how do I use this", or any request to explain or document a project for others. Do NOT use for: general prose editing (use writing-clearly-and-concisely), API reference generation, or in-code docstrings.
version: "1.4.1"
argument-hint: "[existing-readme-path] or 'new'"
allowed-tools: Read Write Glob
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

### Step 3: Draft using the "next action" test

While writing each section, ask: **would a first-time user need this before the next step?** If no,
cut it. A shorter README that is fully read beats a complete one that is skimmed.

### Step 4: Post-draft coverage check

Scan `section-checklist.md` to confirm no required section was missed for this project type.
The most surprising differences: config folders skip Installation and use "What's Here" instead;
internal tools always need Architecture; only OSS needs License.

## Mindset

**The reader's next action, not the author's knowledge** — every section must answer "what do I do
next?" not "what does the author know?" This explains why Installation before Why is wrong (the
reader hasn't decided to install yet), why fictional examples erode trust (they require mental
translation), and why writing for peers fails (peers already know the context; the target
audience doesn't).

**The 80%-complete README is more dangerous than no README.** It creates the illusion of
documentation while hiding the gaps that generate the first support requests. A reader who gets
80% through a README and hits an undocumented step learns that the README cannot be trusted —
and stops reading.

**The progressive disclosure test:** read the README as if each paragraph is the last one the
user might read before giving up. Would they have enough to take the next step? If not, reorganize
so earlier sections enable partial completion.

**Scan before you read** — readers scan headings to decide if a README is worth reading in full.
A README with poor heading choices fails the scan test before the reader reaches the content. Write
headings as entry points, not as chapter titles.

**README is a marketing document before it is a reference.** The first 10 lines determine whether
a stranger invests the next 5 minutes. Those lines must answer: what is this, who should care, and
what does success look like? A README that starts with installation instructions has already lost
the reader who hasn't decided to install yet. The expert mistake is writing a README for yourself
(you already know why the project exists) rather than for the first-time visitor who will make a
30-second decision based on those first 10 lines. The best README authors write the first 10 lines
last — after the full content is done and they understand what actually matters.

## When to Use

| Situation | Action |
| --------- | ------ |
| New README, OSS project | Load `using-references.md`, then `templates/oss.md` |
| New README, internal/team tool | Load `using-references.md`, then `templates/internal.md` |
| New README, personal project | Load `using-references.md`, then `templates/personal.md` |
| New README, config folder | Load `using-references.md`, then `templates/xdg-config.md` |
| Adding or reviewing a section | Load `section-checklist.md` after reading existing README |
| Existing README missing most sections | Treat as new — pick appropriate template above |
| Unsure which type applies | Ask user before loading any template |
| Prose is verbose or unclear | Use `writing-clearly-and-concisely` skill after drafting |

**Gate: Does this project have a primary audience?** If not, ask before writing — a README aimed
at "everyone" will serve no one.

**Gate: Is the Installation section first?** If yes, move the "Why" section above it — a reader
who hasn't decided to install shouldn't be reading Installation.

## Constraints

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
  mentally translate them; a real example proves the tool works and shows the exact output format
  the reader will see.
- **NEVER write for your peers** — write for your 6-months-future self who has forgotten
  everything; assume the reader has zero context about the project's history or jargon. WHY:
  the author's curse (knowing too much) is the single biggest source of README gaps; every
  "obvious" assumption becomes a support request six months later.
- **NEVER write a README for completeness — write it for the reader's next action** — every
  section should answer "what do I do next?" not "what does the author know?". WHY: documentation
  completeness is not the goal; the goal is getting the reader from zero to working.
- **NEVER ship an 80%-complete README** — if a section is present but incomplete, finish it or
  remove it entirely. WHY: a half-complete section teaches the reader that the README cannot be
  trusted; they will stop reading before reaching the complete sections.
- **NEVER lead with architecture before installation** — readers arrive with a specific goal
  (try the tool, fix the config, understand a flag); they quit on abstractions they haven't earned
  yet. WHY: cognitive overhead before payoff is the #1 README abandonment trigger; even if the
  architecture is the most interesting part, the reader needs a working installation first so the
  architecture explanation lands on a concrete mental model rather than an abstract void.
- **NEVER write the README before the feature API is stable** — documentation written too early
  describes an idealized interface that diverges from the final implementation, creating
  technical debt in docs rather than code. WHY: premature documentation locks design decisions
  before implementation reveals what the interface should actually be; it also signals false
  maturity to potential contributors, who arrive expecting the documented behavior and find
  something different.
- **NEVER use past tense in setup instructions** ("changed the config to", "created a file") —
  past tense reads as retrospective narrative, not imperative instruction; users skim past
  tense text as background context rather than executing it. WHY: cognitive processing research
  shows that imperative mode ("change the config") activates action-oriented working memory,
  while past tense activates declarative memory recall; the same instruction in past tense is
  ~40% more likely to be skipped by readers who are scanning.

## Philosophy

A README is not documentation — it is a conversion funnel. Its job is to convert a stranger into
a user, a user into a contributor, and a contributor into a maintainer. Every structural decision
(section order, example realism, audience framing) is a conversion decision, not an organizational
one.

The counterintuitive insight that separates expert README authors from intermediate ones: the
reader does not read linearly. They scan for the answer to their current question. A README that
cannot be navigated by scanning will lose half its readers before they finish the first paragraph.
Expert README authors write headings that work as standalone answers, not as chapter labels.

The 80%-complete README is the most dangerous documentation artifact: it tells the reader it is
complete while hiding the gaps that will cause failures. An absent README is honest about its
limitations. A near-complete README that fails at the last step destroys trust in all future
documentation from the same team.
