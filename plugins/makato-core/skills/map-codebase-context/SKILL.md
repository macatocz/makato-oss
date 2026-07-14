---
name: map-codebase-context
description: Use when the user says "zoom out", "show me the big picture", "what calls this", "map the dependencies", "I don't know this area", "higher level view", "how does this module connect", or "give me context on this code". Do NOT use when already understanding the component or debugging a single file.
version: "1.5.0"
argument-hint: "[optional: module or file name]"
allowed-tools: Read Bash Grep Glob
---
# Map Codebase Context

## Tools

| Tool     | Purpose                                           |
| -------- | ------------------------------------------------- |
| `LSP`  | Go-to-definition, find-references, call hierarchy |
| `Grep` | Pattern search for symbols, imports, usage        |
| `Read` | Inspect file content and understand context       |
| `Glob` | List files to map project structure               |

## Workflow

Two-phase: map call hierarchy up (who calls this) and down (what this calls) to 2 hops, then
present a consolidated picture of scope, risk, and impact before any changes.

## Philosophy

Orientation is a prerequisite for correct action. An engineer who edits a module without
understanding what calls it and what it calls is operating on local information in a global
system — the change may be locally correct and globally wrong. This skill exists to make the
global context explicit before any changes are made.

The 2-hop limit is intentional. Transitive dependency graphs grow exponentially and model the
entire codebase in worst case — which is the opposite of orientation. Two hops up (who calls
this) and two hops down (what this calls) produces a map that fits in one conversation turn and
answers the actual question: "what would break, and what would be affected?"

## Mindset

**Read at least one real caller before concluding.** The call graph from grep shows structure;
reading one actual caller shows intent. A module named `UserService` might only be called from
admin scripts — the name tells you what it is, the caller tells you when and why it's used. Both
are necessary for correct orientation.

**Data flow reveals coupling that control flow hides.** Knowing that A calls B is less useful
than knowing that A passes a partially-validated object to B that B validates further. Incomplete
validation across a call boundary is a bug waiting to happen — and it's invisible in the call
graph but obvious in the data contract.

**Ranked recommendations, not lists.** The user asked you to orient them — that includes
prioritizing what to read next. An unranked list of 10 files forces the user to do the
prioritization work they asked you to do. Three files with explicit rationale ("because it
defines the contract", "because it shows the edge cases") is immediately actionable.

For the code in question, produce a higher-level map using only real file paths and function
names found in the codebase — never invent.

## Expert Signals

**The module name is the least reliable signal.** `UserService` might only be called from
admin scripts. `NotificationManager` might be the critical path for every order confirmation.
Names communicate intent, not usage. Usage is in the callers. Read one actual caller before
concluding anything about what a module does in practice.

**Data contracts across call boundaries predict bug density.** Modules that pass raw
structs, unvalidated user input, or partially-constructed objects across their interfaces
accumulate bugs at those boundaries — the receiving module implicitly depends on properties
the sending module doesn't guarantee. Identifying these contracts is higher-value orientation
than mapping the full call graph.

**Two-hop caller analysis surfaces hidden coupling.** Reading one hop up reveals who calls
the module. Reading two hops reveals who *depends on the assumption* that this module
behaves a certain way. Two-hop analysis is where hidden coupling becomes visible: if
module C calls B which calls A, and C hardcodes a response format that only makes sense
given A's internal structure, the real dependency is C→A, but it is invisible in the
direct call graph. When the user says "I can't change A without breaking everything,"
the culprit is almost always a two-hop assumption.

**Know when NOT to zoom out.** Zooming out is a context-loading operation; it costs
tokens and slows momentum. Do not invoke it during: (a) a targeted bug fix where the
affected file is already identified — read the bug, not the architecture; (b) a green-field
module with no callers yet — there is no context to map; (c) user-initiated deadline
pressure where a faster path to a decision matters more than orientation depth. Offer
to zoom out after the immediate task, not before.

## What to Show

1. **What module/layer is this?** — Name it and describe its responsibility in one sentence.
2. **What calls it?** — List the main callers or entry points (function names, files, services).
   Limit to 2 hops up the call chain; do not enumerate all transitive callers.
3. **What does it call?** — List its key dependencies (downstream modules, external services,
   data stores). Limit to direct dependencies — do not recurse into their dependencies.
4. **How does it fit the overall architecture?** — One paragraph placing it in the system:
   what layer it belongs to, what abstractions it hides, and what invariants it enforces.
5. **What should I read next?** — The 2–3 most important files to understand this area deeply.
   Justify each choice: "because it defines the interface" / "because it shows the contract".

If you need to explore the codebase to answer, do so before responding.

## Exploration Approach

Before reporting:

- Use `Grep` to find callers: search for the function or class name being used as an import or
  call site
- Use `Glob` to locate related files (same directory, same prefix, same test directory)
- Use `Read` on key files identified by grep — read the relevant section, not the entire file
- Read at least one actual caller before concluding about the call pattern — the import graph
  reveals intent that the implementation hides

For architecture-specific patterns (layered, event-driven, microservices, pipeline):

**MANDATORY**: load [`references/exploration-patterns.md`](references/exploration-patterns.md)
when the architecture type is unclear or when standard grep patterns haven't revealed the
entry points or call structure.

**Do NOT load** `references/exploration-patterns.md` for simple single-file orientation or
when the call structure is already clear from the first grep.

## When to Use

| When to use                                           | When NOT to use                                           |
| ----------------------------------------------------- | --------------------------------------------------------- |
| Deep in a feature, lost orientation across modules    | Clear plan exists — orientation not needed               |
| Need to understand data flow across 3+ files          | Only need a single file — read it directly               |
| Want to know callers/callees and why something exists | Want code review — use`/self-review` or `/pr-review` |

**Entry:** Run when answering "where does this data come from and go?" requires traversing ≥3 files.

**Reference:** `references/exploration-patterns.md` — **MANDATORY for complex multi-module orientation**.
**Do NOT load** for single-file questions or when call structure is already clear.

## Constraints

- **NEVER list all transitive dependencies** — stop at 2 hops. WHY: transitive graphs grow
  exponentially and obscure the immediate context; a 6-hop dependency map tells the user
  everything except what they actually need to orient.
- **NEVER assume you understand the architecture without reading at least one actual caller** —
  abstractions lie. WHY: a module named `UserService` might actually be called only from admin
  scripts, not from user-facing flows; reading the name produces the wrong mental model.
- **NEVER skip data flow analysis** — control flow without data flow is incomplete orientation.
  WHY: knowing that A calls B is less useful than knowing that A passes a partially-validated
  object to B that B validates further; the data contract reveals coupling that the call graph
  hides.
- **NEVER fabricate file paths or function names** — use only names found via `Grep` or `Glob`.
  WHY: invented names send the user to files that don't exist and waste their orientation time
  on a false map.
- **NEVER provide more than 5 "read next" recommendations** — ranked top-3 is more actionable
  than an unranked list of 10. WHY: an unranked list forces the user to re-prioritize what you
  were asked to prioritize; a ranked list of 3 with rationale is immediately actionable.
- **NEVER zoom out without first reading the test suite** — WHY: tests are the only
  machine-verifiable specification of intended behavior; code without tests has no observable
  contract; zooming out without tests means analyzing structure without semantics.
- **NEVER present more than 5 'important things to know' after zooming out** — WHY: working
  memory capacity is 7±2 items; presenting 10 conclusions forces the user to re-prioritize;
  a ranked list of 5 with rationale is immediately actionable.
