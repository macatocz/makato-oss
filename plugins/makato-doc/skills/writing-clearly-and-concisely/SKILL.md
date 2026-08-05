---
name: writing-clearly-and-concisely
description: >-
  Use when writing, editing, or reviewing prose for clarity. Applies Strunk's
  rules and avoids common AI writing patterns. Triggers on: "make this clearer",
  "too wordy", "rewrite", "edit for clarity", "copyedit", "improve writing",
  "concise", "writing style", "sounds like AI", "proofread", "documentation",
  "README". Do NOT use for: writing code or technical specifications, creating
  presentation slides, or README creation as the primary task (use
  crafting-effective-readmes).
version: "1.6.0"
argument-hint: "[text or file to edit]"
allowed-tools: Read Write Edit Agent
---

# Writing Clearly and Concisely

## Tools

| Tool | Purpose |
| ---- | ------- |
| `Read` | Load reference files from `elements-of-style/` and `signs-of-ai-writing.md` |
| `Edit` | Apply targeted prose edits |

See the **Reference Files** section below for which file to load and when.

## Workflow

1. **Classify scope** — "make this clearer" = surgical (preserve structure and voice); "rewrite
   this" = fresh start (preserve only the meaning). Ambiguous? See **Scope Ambiguity** below.
2. **Identify reader and register** — commit message: scannable at 2 seconds, no prior context
   assumed; error message: condition + remedy, terse; documentation: dense OK; API reference:
   skip prose preamble entirely.
3. **Nominalization audit** — count nouns ending in -tion, -ment, -ance, -al per paragraph. More
   than 2 in one paragraph signals structural energy loss; recast each as a verb.
4. **Apply the 50% cut test** — for each sentence, can the next sentence absorb its meaning? If
   yes, merge or delete. Most first drafts are 50% longer than needed.
5. **Check sentence-length variance** — are all sentences 15–18 words? That is the AI convergence
   band. Inject intentional short sentences (under 8 words) to restore variance.
6. **Load reference if needed** — consult the Reference Files table; resolve scope first so you
   choose the right section.

## Scope Ambiguity

When the edit request is ambiguous, use AskUserQuestion with selectable options:

> What level of edit do you want?
> - **Surgical** — tighten sentences, cut hedges, fix passive voice; preserve all structure and voice
> - **Structural** — reorder paragraphs, reframe topic sentences, merge thin sections; keep the author's voice
> - **Rewrite** — start from the intended meaning; replace the draft entirely

**Defaults**: "make this clearer" → Surgical. "Rewrite this" → Rewrite.

**Scope escalation fallback**: if you cannot apply Surgical fixes without changing more than 30%
of the words or restructuring more than 2 paragraphs, surface the escalation before proceeding:

> "This text needs structural changes beyond surgical edits. Do you want (1) surgical fixes only,
> preserving structure even if some clarity issues remain, or (2) a structural rewrite?"

**Input format**: if the user provides a file path, use `Read` → `Edit` workflow. If the user
pastes inline text, write the edited version directly in the reply.

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

## Limited Context Strategy

Token-budget thresholds:

- **> 16k tokens available**: load inline whichever section(s) the task requires
- **8k–16k tokens**: load at most one section; pick by task type — structural edit →
  `03-elementary-principles-of-composition.md`, grammar → `02-elementary-rules-of-usage.md`,
  word choice → `05-words-and-expressions-commonly-misused.md`
- **< 8k tokens**: do NOT load any reference file; apply the inline rules in this skill only;
  if a reference-dependent pass is still needed, dispatch a subagent with your draft and one
  section file and ask for the copyedited revision

Before finalizing any prose, ask:

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
| Formatting conventions (headings, quotations, numerals) | Read [`04-a-few-matters-of-form.md`](elements-of-style/04-a-few-matters-of-form.md) ONLY IF user asks about heading styles, quotation marks, or numeral formatting | ~1,200 |
| Strunk's historical scope and intent | **Do NOT load** [`01-introductory.md`](elements-of-style/01-introductory.md) — the actionable rules are in sections 02–05; load only if the user asks about the philosophy behind the rules | 500 |

**Do NOT load** `signs-of-ai-writing.md` for routine writing tasks — the AI patterns listed
below cover 90% of cases and cost 25x less context. Load `signs-of-ai-writing.md` only when
the text has pervasive AI patterns that the inline list doesn't resolve.

## AI Writing Patterns to Avoid

LLMs regress to statistical means, producing generic, puffy prose. Avoid:

- **Puffery:** pivotal, crucial, vital, testament, enduring legacy
- **Empty "-ing" phrases:** ensuring reliability, showcasing features, highlighting capabilities
- **Promotional adjectives:** groundbreaking, seamless, robust, cutting-edge
- **Overused AI vocabulary:** delve, leverage, multifaceted, foster, realm, tapestry
- **Formatting overuse:** excessive bullets, emoji decorations, bold on every other word

Be specific, not grandiose. Say what it actually does.

## Anti-patterns

- **NEVER open with "This document..." or "This section..."** — WHY: the reader is already inside
  the document; naming the container adds no information and delays the key claim; it signals the
  writer hasn't committed to a thesis and is describing structure instead of leading with it.
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
  document** — WHY: a reader who encounters 'you should install' followed by 'the user should
  configure' is involuntarily stepped outside the document's frame; they must mentally translate
  between pronouns rather than follow the argument; over multiple edit cycles this compounds
  because each editor defaults to their own preferred frame, producing a chimeric document where
  no single reader is clearly addressed.

Every rule here has valid exceptions. Passive voice is correct when the actor is irrelevant ("The
server was rebooted at 3 AM" — who did it doesn't matter). A throat-clearing opener works in a
gentle correction. Break a rule when breaking it makes the sentence clearer — but know which rule
you're breaking and why. When editing someone else's text, tighten their voice — don't replace it
with yours.

## Bottom Line

Prose fails when it requires a second reading. AI-generated text has a systematic failure mode:
it hedges, qualifies, and inflates — "It is important to note that the API might potentially
return an error" contains four evasions in one sentence. Strip them and replace them with what
the writer actually means.

Use the thinking questions above, load the reference you need, and cut until every word earns
its place. Match scope to the request: "make this clearer" means surgical fixes; "rewrite this"
means start fresh.
