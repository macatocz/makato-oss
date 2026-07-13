---
name: writing-clearly-and-concisely
description: Use when writing, editing, or reviewing prose for clarity. Applies Strunk's rules and avoids common AI writing patterns. Triggers on: "make this clearer", "too wordy", "rewrite", "edit for clarity", "copyedit", "improve writing", "concise", "writing style", "sounds like AI", "proofread", "documentation", "README". Do NOT use for: writing code or technical specifications, creating presentation slides, or README creation as the primary task (use crafting-effective-readmes).
version: "1.4.0"
argument-hint: "[text or file to edit]"
allowed-tools: Read Write Agent
---

# Writing Clearly and Concisely

## Tools

| Tool | Purpose |
| ---- | ------- |
| `Read` | Load reference files from `elements-of-style/` and `signs-of-ai-writing.md` |
| `Edit` | Apply targeted prose edits |

See the **Reference Files** section below for which file to load and when.

## Workflow

1. **Identify scope**: is the request "make this clearer" (surgical) or "rewrite this" (fresh start)?
2. **Check reader context**: who reads this and what do they need? (commit message vs error message vs doc)
3. **Apply Strunk Rule 13** first — omit needless words. Most first drafts are twice as long as needed.
4. **Check active voice**: who is the subject of each sentence? Passive hides responsibility.
5. **Verify point placement**: does each paragraph lead with its key claim? (Strunk: paragraph → topic sentence first)
6. **Load reference if needed**: use the Tools table to choose the right file.

## Mindset

**Read for what's missing, not for what's there.** When reviewing prose, ask: "If I remove
this sentence, does the reader lose anything?" If the answer is no, cut it. Most first drafts
are 50% longer than they need to be — not because the writer is verbose, but because the writer
hasn't yet decided what they're trying to say.

**Match register to reader.** A commit message serves `git log` scanners. An error message
serves a user mid-crisis. Documentation serves someone learning. These are different contexts
with different density requirements. Error messages must be parseable under stress — shorter and
more direct than documentation. Commit messages must survive context loss — they cannot assume
the reader remembers the original ticket.

**Passive voice is a diagnostic signal.** When you see passive voice, ask: "Who is the subject?"
If the answer is obvious and relevant, the sentence should be active. If the actor is genuinely
irrelevant ("The server was rebooted at 3 AM"), passive is correct. But passive used to hide
responsibility or avoid naming a thing is always a defect.

**Sentence length variance is the hidden AI tell.** The Flesch-Kincaid reading ease formula
reveals that most AI-generated text scores below 40 — not because it's complex, but because of
sentence length variance collapse. Human writing alternates 5-word sentences with 25-word
sentences; AI writing converges to 15-18 words per sentence consistently. Readers detect this
convergence before they consciously notice it as "sounds like AI." Inject intentional short
sentences (under 8 words) after long ones.

## Overview

Write with clarity and force. This skill covers what to do (Strunk) and what not to do (AI
patterns).

## Limited Context Strategy

When context is tight:

1. Write your draft using judgment
2. Dispatch a subagent with your draft and the relevant section file
3. Have the subagent copyedit and return the revision

Loading a single section (~1,000-4,500 tokens) instead of everything saves significant context.

Before finalizing any prose, ask yourself:

- **Who reads this, and what do they need?** A commit message serves `git log` scanners. An error
  message serves a user mid-task. Documentation serves someone learning. Each demands different
  density and tone. Error messages must be parseable mid-crisis — shorter and more direct than
  documentation.
- **Is the actor visible in every sentence?** If you wrote "the configuration is loaded" — by
  what? Rewrite: "The server loads the configuration." Passive hides responsibility and adds words.
- **Can I cut this sentence in half without losing meaning?** If yes, do it. Strunk's Rule 13:
  "Omit needless words." The sentence "He is a man who is very ambitious" becomes "He is very
  ambitious." Most first drafts are twice as long as they need to be.
- **Does every adjective earn its place?** Remove it and re-read. If the reader wouldn't miss it,
  delete it. "A robust, scalable solution" says nothing. "Handles 10k requests/second" says
  something.
- **Does the sentence end on the word that matters most?** Strunk's Rule 18: place the emphatic
  word at the end. "Humanity has hardly advanced in fortitude since that time, though in
  philanthropy it has" — the stress falls on _has_, not on _fortitude_. Rearrange so the key idea
  lands last.

## Quick Calibration

| Before | After | Why |
| --- | --- | --- |
| This groundbreaking feature leverages cutting-edge technology to deliver a seamless experience. | This feature uses WebSocket connections to update the dashboard in real time. | Replace puffery with what it actually does |
| It is important to note that the API might potentially return an error in certain situations. | The API returns an error when the token expires. | Kill the throat-clearing; name the condition |
| The configuration file is read by the application at startup and the necessary parameters are extracted. | The application reads its configuration at startup. | Active voice; cut the obvious second clause |

## Reference Files

Strunk's full text with examples lives in `elements-of-style/`. Load the section you need:

| Task | Action | ~Tokens |
| ---- | ------ | ------- |
| Editing prose for clarity or concision | **MANDATORY**: read [`03-elementary-principles-of-composition.md`](elements-of-style/03-elementary-principles-of-composition.md) | 4,500 |
| Reviewing text that sounds AI-generated | Load [`signs-of-ai-writing.md`](signs-of-ai-writing.md) ONLY IF the AI pattern list below is insufficient | 25,000 |
| Grammar or punctuation questions | Read [`02-elementary-rules-of-usage.md`](elements-of-style/02-elementary-rules-of-usage.md) | 2,500 |
| Word choice or common misuse | Read [`05-words-and-expressions-commonly-misused.md`](elements-of-style/05-words-and-expressions-commonly-misused.md) | 4,000 |

**Do NOT load** `signs-of-ai-writing.md` for routine writing tasks — the AI patterns listed
below cover 90% of cases and cost 25x less context. Load `signs-of-ai-writing.md` only when
the text has pervasive AI patterns that the inline list doesn't resolve.

**Do NOT load** `04-a-few-matters-of-form.md` unless the user asks about formatting conventions
(headings, quotations, numerals).

## When to Use

**When NOT to use:** Do NOT use for code formatting/style (use linters), translating between
languages, or generating new content from scratch (use write-a-prd or similar).

| Task | Action |
| ---- | ------ |
| Prose is clear but verbose | Apply Strunk Rule 13 (omit needless words) — no reference needed |
| Text "sounds like AI" | Apply AI patterns list below; load `signs-of-ai-writing.md` only if patterns persist |
| Grammar question | Load `02-elementary-rules-of-usage.md` |
| Structuring an argument | Load `03-elementary-principles-of-composition.md` |
| Word choice | Load `05-words-and-expressions-commonly-misused.md` |
| Editing someone else's text | Tighten their voice — do NOT replace it with yours |
| "Rewrite this completely" | Start fresh — do not attempt surgical edits |
| "Make this clearer" | Surgical fixes only — do not change the author's structure |

## AI Writing Patterns to Avoid

LLMs regress to statistical means, producing generic, puffy prose. Avoid:

- **Puffery:** pivotal, crucial, vital, testament, enduring legacy
- **Empty "-ing" phrases:** ensuring reliability, showcasing features, highlighting capabilities
- **Promotional adjectives:** groundbreaking, seamless, robust, cutting-edge
- **Overused AI vocabulary:** delve, leverage, multifaceted, foster, realm, tapestry
- **Formatting overuse:** excessive bullets, emoji decorations, bold on every other word

Be specific, not grandiose. Say what it actually does.

## Philosophy

Prose that requires a second reading has failed. The reader's time is the scarce resource —
every excess word, every hedged construction, every passive clause is a tax the writer imposes
on the reader. Good writing respects the reader's time by doing the editorial work in advance:
choosing the right word, cutting the unnecessary sentence, leading with the point rather than
the context.

AI-generated text has a systematic failure mode: it hedges, qualifies, and inflates. The hedges
are not politeness — they are evasions. "It is important to note that the API might potentially
return an error" contains four separate evasions in one sentence. This skill exists to strip
them out and replace them with what the writer actually means.

## Constraints

- **NEVER open with "This document..." or "This section..."** — dead starts that bury the lede;
  lead with what the reader needs to know, not with a description of the container they're already
  reading
- **NEVER hedge with throat-clearing** ("It is important to note that...", "It should be mentioned
  that...", "It is worth noting...") — these add a full clause before the actual content; either
  say it or don't
- **NEVER use passive voice to hide the actor** ("Mistakes were made", "The file is loaded at
  startup") — passive adds words and dodges responsibility; name the subject
- **NEVER use passive voice for instructions or cautions** — WHY: passive voice obscures
  the actor; 'the button should be clicked' doesn't specify who; 'click the button' creates
  unambiguous ownership; passive instructions in safety-critical contexts are associated
  with higher error rates.
- **NEVER default to bullet lists when prose would be clearer** — bullets fragment related ideas
  into isolated fragments; use them for genuinely parallel items, not for narration or argument
- **NEVER add adjectives that don't change the reader's understanding** ("robust system",
  "comprehensive solution", "reliable approach") — if removing the adjective doesn't change what
  the reader learns, it was decoration
- **NEVER write a sentence the reader must re-read** — ambiguity means the sentence has two
  possible parses; restructure so only one reading is possible; keep related words together
  (Strunk's Rule 16)
- **NEVER bury the point after setup or background** — lead with what the reader came for;
  provide context only after they know why they should care; if paragraph three has the key
  insight, move it to paragraph one
- **NEVER edit for conciseness without first identifying what the reader needs to DO
  after reading** — WHY: conciseness that removes action clarity is destructive; a
  500-word explanation that enables correct action is better than a 50-word explanation
  they must re-read 5 times.
- **NEVER start a sentence with 'Note:' or 'Please note:'** — these phrases signal defensive
  writing; confident technical writing incorporates the important information into the flow directly.
  WHY: every sentence in documentation should be important enough to include without hedging;
  if it needs a 'Note:', move it to the lead sentence.
- **NEVER use the phrase 'it is worth noting' in technical documentation** — this phrase adds
  words without adding meaning; what follows it is either worth noting (note it directly) or
  not worth noting (delete it). WHY: meta-commentary about the importance of information is noise.
- **NEVER use nominalization when a verb is available** — nominalization converts verbs into
  nouns ('conduct an investigation' vs 'investigate', 'provide assistance' vs 'help'); each
  nominalization adds at least one extra word and reduces sentence energy. WHY: nominalized
  constructions require an empty verb carrier ('conduct', 'provide', 'perform') that adds bulk
  without meaning; the underlying verb is always clearer and shorter.
- **NEVER use 'very' or 'extremely' as intensifiers in technical documentation** — intensifiers
  weaken rather than strengthen claims; restructure to convey importance through specificity.
  WHY: 'very important' states the author's opinion; a specific consequence ('missing this step
  corrupts your database') makes the reader understand why it matters without an opinion.
- **NEVER use 'as mentioned above' or 'as noted earlier'** — self-references break when documents
  are reorganized and fail readers who entered at this section. WHY: documentation is not read
  linearly; every section should be independently comprehensible; backward references signal
  that sections should be merged or the current section lacks necessary context.
- **NEVER mix second-person ('you should') with third-person ('the user should') in the same
  document** — inconsistent perspective forces mental translation between frames. WHY: person
  inconsistency signals uncertainty about the reader's identity; a document that addresses 'you'
  in some places and 'the user' in others implicitly serves two audiences, which means it is
  two documents poorly merged.

Every rule here has valid exceptions. Passive voice is correct when the actor is irrelevant ("The
server was rebooted at 3 AM" — who did it doesn't matter). A throat-clearing opener works in a
gentle correction. Break a rule when breaking it makes the sentence clearer — but know which rule
you're breaking and why. When editing someone else's text, tighten their voice — don't replace it
with yours.

## Bottom Line

Writing for humans? Use the thinking questions above, load the reference you need, and cut until
every word earns its place. When editing, match the scope to the request — "make this clearer"
means surgical fixes; "rewrite this" means start fresh.
