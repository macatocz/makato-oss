# Decompose Anti-Patterns

Non-obvious failure modes. Each NEVER is grounded in a downstream contract or sprint failure
mode — not generic advice.

**NEVER create a standalone technical enabler story.**
WHY: Produces a story with zero user-observable outcome — cannot be demoed or independently
tested against a Definition of Done. The enabler is only useful when paired with the
user-facing story it enables; splitting it out creates two stories where neither can ship
alone, defeating the vertical-slice contract and poisoning sprint velocity.

**NEVER accept a single-layer or single-repository story.**
WHY: A layer-cut story (UI-only, API-only, DB schema-only) delivers no standalone value and
cannot be tested in a running environment without the other layers. It creates a hidden
"must combine to demo" dependency between board items that appear independent but aren't.

**NEVER write `storyPoints > 13` without recording a BLOCK error.**
WHY: 13 SP is the schema hard cap (enforced in Step 8). An oversized story routinely crosses
sprint boundaries, corrupts velocity measurement, and almost always hides a safe split — the
BLOCK forces re-examination before `to-issues` creates an issue that the team cannot realistically
close in a sprint.

**NEVER emit `tier:`, `points:`, `module:`, `tech:`, or `status:` into `stories[].labels[]`.**
WHY: Each label is owned by a different authoritative source. `tier:` derives from `phase`;
`points:` from `storyPoints`; `module:` from the target repo's ADR folder structure (only
`to-issues` knows this at publish time); `tech:` from `to-issues` text-match; `status:` from
the dependency topo-sort. Emitting them here creates a drift vector: decompose's guess can
conflict with `to-issues`'s derivation, producing mismatched labels on the GitHub issue.

**NEVER mutate `stories.json` after `to-issues` has run.**
WHY: GitHub issues are anchored to story sequence numbers in `created-issues.json`. A sequence
shift after publish breaks the audit trail between each issue and its originating story.
Re-running `to-issues` after mutation creates duplicate issues with no link to the originals.

**NEVER omit `epic.objective` from `stories.json`.**
WHY: `to-issues` validates its presence before rendering the GitHub epic tracking issue title.
A missing objective is a hard publish failure — `to-issues` blocks the entire run, not just
the epic story row. The objective cannot be patched after publish without rewriting the issue.

**NEVER solicit a user choice with freeform prose — always use AskUserQuestion with enum options.**
WHY: Freeform questions cannot be handled by the autonomous loop's headless mode. Enum options
let the loop apply a predictable default (first option) without a human present, enabling
unattended dispatch. Freeform blocks the loop silently.
