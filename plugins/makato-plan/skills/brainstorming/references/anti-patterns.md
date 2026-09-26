# Brainstorming Anti-Patterns

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
