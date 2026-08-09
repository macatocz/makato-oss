<!-- markdownlint-disable MD013 MD040 -->
# PR-comment reply templates

> **Status**: Authoritative reply text for `build-address-pr-comments` (interactive **and** autonomous modes). One template per classification tier plus one per autonomous-only fallback. SKILL.md MUST reference this file rather than inlining the prose.

## Why this file exists

`build-address-pr-comments` posts a reply to every comment it classifies — both human reviewer feedback and bot findings. The reply text used to live inline in the skill body. As of GAP-011 (#36) the skill runs headlessly under `--autonomous`, where reply wording is a load-bearing contract: PO-agent and downstream readers parse the leading marker (`[MUST-FIX]`, `[DEFERRED]`, `[STRUCTURAL]`, `[OUT-OF-SCOPE]`) to reconstruct what the skill decided. Inlined prose drifts between revisions and across reviewers; an external template file pins it.

Templates use a small placeholder vocabulary documented under each section. Substitution is plain string-replace at template-render time (no Jinja, no shell expansion).

## Common conventions

- Keep replies factual and brief — 1-2 sentences.
- Lead with a bracketed marker (`[MUST-FIX]`, `[SHOULD-FIX]`, `[CONSIDER]`, `[OUT-OF-SCOPE]`, `[STRUCTURAL]`, `[DEFERRED]`) so PO-agent and humans can scan the thread without re-classifying.
- Append `— autonomous mode` as the closing clause when posted under `--autonomous`. The marker stays the same; the closing clause documents that the decision was taken without a human at the prompt.
- Never quote the entire original comment. Quote only when the reply would otherwise be ambiguous about which line/finding it addresses.

## Placeholders

| Placeholder | Filled from | Example |
|---|---|---|
| `<commit-sha>` | Short SHA of the commit that applied the fix (`git rev-parse --short HEAD` after Step 8 commit) | `a1b2c3d` |
| `<fix-summary>` | One sentence describing the change | `null-check added on receipt path` |
| `<reason>` | One sentence explaining a skip / deferral / out-of-scope decision | `comment touches files outside this task's diff scope` |
| `<key>` | Work-item key from Step 1 | `GAP-011` or `#36` |
| `<follow-up-issue>` | URL of the issue opened by `gh issue create` (OUT-OF-SCOPE only) | `https://github.com/owner/repo/issues/142` |
| `<comment-summary>` | ≤ 80-char gloss of the original comment (STRUCTURAL only) | `data model needs separate join table, not a column` |

If a placeholder has no value, leave it as `<placeholder>` in the output — the skill MUST fail-loud on render rather than post a half-rendered reply.

---

## MUST-FIX (applied)

Applies when a MUST-FIX (non-STRUCTURAL) comment was implemented and pushed.

```text
[MUST-FIX] Fixed in `<commit-sha>` — <fix-summary>.
```

Autonomous-mode variant (append the closing clause):

```text
[MUST-FIX] Fixed in `<commit-sha>` — <fix-summary>. — autonomous mode
```

---

## SHOULD-FIX (applied)

Applies when a SHOULD-FIX comment was implemented and pushed. In autonomous mode this template is used only when the comment's files fall inside the original task diff (the SHOULD-FIX scope guard in AUTONOMOUS-MODE.md Step 5).

```text
[SHOULD-FIX] Fixed in `<commit-sha>` — <fix-summary>.
```

Autonomous variant:

```text
[SHOULD-FIX] Fixed in `<commit-sha>` — <fix-summary>. — autonomous mode
```

---

## SHOULD-FIX (deferred — autonomous-only)

Applies when a SHOULD-FIX in autonomous mode touches files **outside** the current task's diff. The skill does not expand its blast radius silently; it marks the comment DEFERRED and lets the PO-agent decide whether to spin a follow-up. (In interactive mode the user is asked instead — this template is autonomous-only.)

```text
[DEFERRED] Noted — autonomous mode is not extending this PR's scope to <reason>. Will surface via PO-agent for follow-up. — autonomous mode
```

The matching `build.jsonl` entry MUST set `data.event: "autonomous_bypass"`, `data.gate: "should-fix-scope-guard"`, `data.default_taken: "defer"`, and include `data.comment_id` plus the offending file list.

---

## CONSIDER (implemented)

Applies when the user approved a CONSIDER suggestion in interactive mode and the skill implemented it.

```text
[CONSIDER] Fixed in `<commit-sha>` — <fix-summary>.
```

---

## CONSIDER (deferred — interactive choice)

Applies when the user chose to skip a CONSIDER suggestion, or autonomous mode skipped it per fixed policy. The `<reason>` field documents why.

```text
[CONSIDER] Noted — deferred; <reason>.
```

Autonomous variant (fixed policy reason):

```text
[CONSIDER] Noted — deferred under autonomous-mode policy (skip CONSIDER tier). — autonomous mode
```

---

## OUT-OF-SCOPE

Applies when a comment requests something outside the work-item's acceptance criteria. The skill keeps the reply non-defensive — it states the scope boundary, never a judgment on the suggestion.

Interactive (no follow-up issue):

```text
[OUT-OF-SCOPE] This falls outside the scope of `<key>` — <reason>. Will track separately.
```

Autonomous (follow-up issue created via `gh issue create` — AC4):

```text
[OUT-OF-SCOPE] This falls outside the scope of `<key>` — <reason>. Tracked separately at <follow-up-issue>. — autonomous mode
```

The autonomous variant requires the follow-up issue to exist before the reply is posted. The skill MUST NOT post the autonomous template with a placeholder URL — if `gh issue create` failed, the skill HALTs (`HALT-005` per the cross-skill rule) rather than posting a half-rendered reply.

---

## STRUCTURAL MUST-FIX (autonomous HALT — AC3)

Applies once per autonomous session when one or more MUST-FIX comments are flagged STRUCTURAL. The skill posts a single summary reply on the PR (as a general PR comment, not a per-line reply), applies the `needs-human-review` label, and exits with `HALT-003`. The reply enumerates each STRUCTURAL comment by short summary so the operator does not have to re-read every thread.

Single STRUCTURAL item:

```text
[STRUCTURAL] Autonomous mode cannot re-plan the implementation approach for this finding — <comment-summary>. Applying `needs-human-review`; exiting `HALT-003`. Operator action required: review the finding and re-shape the story, or override the structural call and re-run interactively.
```

Multiple STRUCTURAL items (use a bulleted list under the marker line):

```text
[STRUCTURAL] Autonomous mode cannot re-plan the implementation approach for the following findings. Applying `needs-human-review`; exiting `HALT-003`. Operator action required: review each finding and re-shape the story, or override the structural calls and re-run interactively.

- <comment-summary 1>
- <comment-summary 2>
- ...
```

Notes:

- The summary reply is posted **before** the label is applied and the HALT is logged — if posting fails, the skill still completes the HALT but the failure is logged to `build.jsonl` with `data.event: "summary_reply_failed"` so the operator sees the gap.
- `comment-summary` is the first 80 chars of each STRUCTURAL comment body, with any newlines collapsed to spaces.
- The label `needs-human-review` is applied via `gh issue edit` on the **PR's underlying issue**, not the PR itself, because the PO-agent reads it from the issue (AC3 wording is on the PR; behaviorally the issue carries the label per `halt-conditions.md`). The skill applies it to both for redundancy.

---

## Bot vs human author

The classification guide (`references/comment-classification-guide.md`) treats bots and humans uniformly at the tier level — content overrides source heuristics. Reply templates likewise do not branch on author type. A CI bot that posted a build-failure comment receives the same `[MUST-FIX] Fixed in <commit-sha> — ...` reply as a human reviewer.

The skill MAY suppress the reply entirely when the bot's UI already auto-resolves on push (e.g. some lint bots mark their own findings resolved when a follow-up commit removes the warning). When suppressing, log `data.event: "reply_suppressed"` with `data.author_type: "bot"` and the bot's login. Default: post the reply.

---

## Versioning

This template file is referenced (not embedded) by `build-address-pr-comments`. Changes:

- Adding a new template section, or adding placeholders that DON'T break existing renders, is a minor (skill bumps minor version, this file has no version field).
- Removing a template section, renaming a placeholder, or changing the marker vocabulary is a breaking change — coordinate with all consumers (currently just `build-address-pr-comments`) and bump the skill's MAJOR version.

The skill itself reads this file at runtime; there is no compile step. Test new templates by running the skill against a sandbox PR before merging.

## SENSOR-BOT (delegated)

Delegated to sensor-fixer. Applied Phase 0 autofix for `<tool>:<rule>`. See `build.jsonl` for audit trail.

---

## REVIEW-FEEDBACK PROMOTION (harness issue opened)

A recurring **<proposed-rule>** finding has been detected across prior PRs on this repo.
A candidate pre-commit rule has been proposed in: <harness-issue>

This comment will not need manual attention in future sessions once the harness check is in place.
