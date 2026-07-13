---
name: build-resolve-finding
description: Per-finding decision tree that resolves a single sensor finding via 4 branches — autofix, tech-skill route (action `skill` or `autofix-then-skill` fallback), safe-automated action (redact/upgrade/suppress), or carry-over to draft PR. Use when sensor-fixer dispatches a finding for repair.
version: "1.1.0"
tools: All tools
---

# build-resolve-finding

## 1. Overview

This skill is the **per-finding decision engine** invoked by the `sensor-fixer` orchestrator. It receives a single normalized sensor finding (one rule violation in one file), decides which of four branches applies, executes that branch, and returns a structured outcome.

The four branches are:

1. **Autofix** — the tool itself can fix it (e.g., `ruff --fix`, `prettier --write`). Run the tool, re-verify the hook.
2. **Tech-skill route** — the finding maps to a specialized skill via `finding-routes.json` (e.g., a typing fix, a lint pattern). Load that skill, apply one fix attempt.
3. **Safe-automated action** — finding has a deterministic, safe remediation we can always perform without judgment: secrets → quarantine + redact + issue; CVE → upgrade-or-ignore; bandit warning → suppress with justified reason.
4. **Carry-over** — the finding is structural and cannot be auto-resolved. Record it in the draft PR description; leave the hook red in CI; let a human address it.

**Knowledge of *how* to fix a class of finding lives here**, in this skill — not in `sensor-fixer`. The orchestrator only dispatches; this skill decides and acts.

### Relationship to `sensor-fixer` Phase 0

`sensor-fixer` v1.1.0+ runs a batched-autofix **Phase 0** before dispatching this skill. Phase 0 collects every finding whose route action is `autofix` or `autofix-then-skill`, groups by `cmd`, runs each distinct cmd once on the union of files, then re-parses and drops resolved findings.

This skill is only invoked for findings that **survived** Phase 0. The consequence:

- A finding with route `action: "autofix"` that reaches this skill is **already-attempted-and-failed-by-the-CLI**. Branch 1 still re-runs the autofix on this single file (the targeted retry may succeed where the batched call did not), but if it still fails, the finding falls through to Branch 4 carry-over.
- A finding with route `action: "autofix-then-skill"` that reaches this skill goes directly to Branch 2 using `route.fallback_skill` — the batched autofix has already had its shot.

## 2. Inputs (Finding shape)

The caller passes a single finding object — the canonical Finding contract is
[`shared/finding-schema.md`](../../shared/finding-schema.md):

```json
{
  "tool": "ruff | prettier | mypy | bandit | gitleaks | trivy | <other>",
  "rule": "<rule id, e.g. E501, B101, generic-secret, CVE-2024-12345>",
  "path": "<repo-relative file path>",
  "line": 123,
  "message": "<verbatim sensor message>",
  "severity": "low | medium | high | critical",
  "autofix_available": true,
  "repo_root": "/abs/path/to/repo",
  "attempt": 1,
  "model_override": null
}
```

`attempt` increments on retry. `model_override` is set by the caller if a tier escalation is in effect (see §5). **Reserved/inert (#287):** no runtime consumes `model_override` yet — this skill is invoked via the Skill tool, which has no `model` parameter, so the field is documented for a future Agent-tool-based dispatch but currently has no effect.

## 3. Decision tree

```
                        ┌─────────────────────────────┐
                        │  Finding arrives            │
                        │  (post-Phase-0 in sensor-   │
                        │   fixer v1.1.0+)            │
                        └──────────────┬──────────────┘
                                       │
                          autofix_available == true?
                                       │
                  ┌────────────yes─────┴──────no────────┐
                  │                                     │
        ┌─────────▼─────────┐               ┌───────────▼──────────┐
        │  BRANCH 1         │               │  Look up route in     │
        │  Autofix          │               │  finding-routes.json  │
        │  (targeted retry) │               │  by "<tool>:<rule>"   │
        └─────────┬─────────┘               └───────────┬──────────┘
                  │                                     │
                  │                  ┌──────────────────┼──────────────────┐
                  │                  │                  │                  │
                  │             action=skill   action=autofix-       action=safe-auto-*
                  │                  │         then-skill                   │
                  │                  │                  │                  │
                  │                  │         (Phase 0 already ran)       │
                  │                  │                  │                  │
                  │                  ▼                  ▼                  ▼
                  │             ┌─────────────────────────┐         ┌───────────┐
                  │             │  BRANCH 2 — Tech-skill  │         │ BRANCH 3  │
                  │             │  route.skill           │         │ Safe-auto │
                  │             │   OR                   │         └─────┬─────┘
                  │             │  route.fallback_skill  │               │
                  │             └─────────┬──────────────┘               │
                  │                       │                              │
                  │                       │      no route /              │
                  │                       │      structural              │
                  │                       │           │                  │
                  │                       │     ┌─────▼─────┐            │
                  │                       │     │ BRANCH 4  │            │
                  │                       │     │ Carry-over│            │
                  │                       │     └─────┬─────┘            │
                  │                       │           │                  │
                  └───────────────────────┴───────────┴──────────────────┘
                                       │
                              Re-run hook on file
                                       │
                              ┌────────┴────────┐
                              │                 │
                            green             still red
                              │                 │
                          resolved          failed / carry-over
```

### Branch 1 — Autofix (`autofix_available == true`)

```
1. cmd = finding-routes.json["<tool>:<rule>"].cmd
        OR default: <tool> --fix <path>
2. Run cmd from repo_root.
3. Re-run the originating hook on <path> only:
        pre-commit run <hook_id> --files <path>
4. If hook now exits 0:
        outcome = "resolved"
   Else:
        outcome = "failed"   # caller may retry or escalate tier
```

**Targeted retry rationale.** `sensor-fixer` Phase 0 already ran this cmd on the union of all autofix-eligible files in a batch. If the finding reached this skill, the batched call did not clear it — but a single-file invocation can still succeed when, for instance, the batched call had a non-fatal failure on an unrelated file that aborted before reaching this one. Re-run targeted, then fall through to carry-over if it still fails.

Default fix commands when no route is configured:

| tool     | default cmd                      |
|----------|----------------------------------|
| ruff     | `ruff check --fix <path>`        |
| ruff-format | `ruff format <path>`          |
| prettier | `prettier --write <path>`        |
| eslint   | `eslint --fix <path>`            |
| black    | `black <path>`                   |
| isort    | `isort <path>`                   |

### Branch 2 — Tech-skill route (`action == "skill"` or `action == "autofix-then-skill"`)

```
1. route = finding-routes.json["<tool>:<rule>"]
2. Pick the skill name:
        action == "skill"              → skill_name = route.skill
        action == "autofix-then-skill" → skill_name = route.fallback_skill
                                         (Phase 0 already ran route.cmd and
                                          did not clear this finding)
3. Load skill: skill_name (e.g. "makato-doc:markdown", "typing-fixer",
   "react-hook-deps-fixer", "makato-build:build-simplify").
4. Pass {finding, repo_root} to that skill.
5. Skill applies pattern in-place. ONE fix attempt only.
6. Re-run originating hook on <path>.
7. Report outcome ∈ {resolved, failed}, set skill_used = skill_name.
```

The called skill is responsible for its own internal logic; this skill does not retry it.

**Why two action values dispatch to the same branch.** `skill` means "this rule class needs reasoning — there is no CLI autofix worth attempting." `autofix-then-skill` means "this rule class is split — most members of the class have a CLI autofix, but a structural subset does not." Phase 0 in `sensor-fixer` already attempted the autofix on the full batch; whatever reaches this branch is the structural subset, and the route's `fallback_skill` is the domain expert for that subset (e.g. `makato-doc:markdown` for residual MD0xx after `markdownlint --fix`).

### Branch 3 — Safe-automated actions

Three deterministic sub-actions, dispatched by `action` value in `finding-routes.json`.

#### 3a. `action == "redact-and-issue"` (gitleaks / secret scanners)

```
1. Read <path>:<line>; identify the literal secret value.
2. Choose env var NAME from rule context (e.g. AWS_ACCESS_KEY_ID, OPENAI_API_KEY).
3. Replace literal in source with: os.environ["NAME"]
   (or the language-appropriate equivalent — process.env.NAME, std::env::var, etc.)
4. Quarantine the original literal:
        mkdir -p <repo_root>/.secrets/quarantine
        echo "<literal>" > <repo_root>/.secrets/quarantine/<sha>.txt
   where <sha> = sha256(literal)[:12].
5. Verify .gitignore contains an entry for ".secrets/" — add it if missing.
6. Call create-issue skill with:
        title: "rotate KEY <prefix>"            # <prefix> = first 6 chars of literal
        body : finding.message + redaction details + path:line + sha pointer
7. git add <path> .gitignore && git commit -m "chore(security): redact <NAME>"
8. Re-run gitleaks hook on <path> → expect green.
9. outcome = "resolved" if hook green, else "failed".
```

**Never** commit the raw literal. **Always** create the rotation issue, even if the credential looks expired or fake — it is not this skill's job to judge.

#### 3b. `action == "upgrade-or-ignore"` (trivy / dependency CVEs)

```
1. Detect package manager:
        - pyproject.toml + uv.lock → "uv lock --upgrade-package <pkg>"
        - pyproject.toml + poetry.lock → "poetry update <pkg>"
        - package.json + pnpm-lock.yaml → "pnpm update <pkg>"
        - package.json + package-lock.json → "npm update <pkg>"
        - package.json + yarn.lock → "yarn upgrade <pkg>"
2. Run upgrade cmd.
3. Re-run gates: trivy + project's test suite (fast subset).
4. If green:
        git add <lockfile> <manifest>
        git commit -m "chore(deps): upgrade <pkg> for <CVE>"
        outcome = "resolved"
5. If still red OR no upgrade exists:
        Append to <repo_root>/.trivyignore:
                <CVE>  # expires:YYYY-MM-DD reason:no-fix-available
            where YYYY-MM-DD = today + 30 days.
        Call create-issue skill: title "review CVE <CVE> ignore by <date>".
        outcome = "resolved" (with caveat: tracked in issue).
```

**Always** prefer the upgrade. `.trivyignore` is the fallback only when upgrade is not viable.

#### 3c. `action == "suppress-with-reason"` (bandit / similar)

```
1. Read <path>:<line>.
2. Compose a SPECIFIC justification — must reference:
        - what the construct is (e.g. "subprocess call to git")
        - why it is safe here (e.g. "args fully constructed from internal constants")
3. Reject and return outcome = "failed" if the only reason you can write is generic
   ("not a real risk", "false positive", "won't exploit").
4. Append inline at end of offending line:
        # nosec B<id>: <specific reason>
5. Re-run bandit on <path>.
6. outcome = "resolved" if green, else "failed".
```

### Branch 4 — Carry-over

```
Triggered when:
  - no route entry exists, AND
  - autofix_available is false, AND
  - finding is structural (e.g. mypy strict-mode error, complex lint)
Steps:
  1. Format finding for human review:
        - <tool>:<rule> at <path>:<line>
        - <message>
        - severity
  2. If a draft PR already exists for this branch:
        gh pr edit <num> --body "$(existing_body)\n\n## Carry-over: <tool>:<rule>\n…"
     Else:
        Stash entry into <repo_root>/.makato/carry-over.jsonl
        for build-create-pr to consume.
  3. Leave the failing hook red — DO NOT suppress, DO NOT --no-verify.
  4. outcome = "carry-over"
```

## 4. Output JSON

```json
{
  "action": "autofix | skill | autofix-then-skill | redact-and-issue | upgrade-or-ignore | suppress-with-reason | carry-over",
  "outcome": "resolved | failed | carry-over",
  "skill_used": "<skill name or null>",
  "retried": false,
  "escalated": false,
  "jsonl_entry": {
    "ts": "<ISO-8601>",
    "tool": "<tool>",
    "rule": "<rule>",
    "path": "<path>",
    "line": 123,
    "branch": "1|2|3a|3b|3c|4",
    "outcome": "resolved | failed | carry-over"
  }
}
```

`action` in the output is the route's declared action value verbatim (`"autofix-then-skill"` resolves to Branch 2 with `route.fallback_skill`; the action string is preserved for audit). `jsonl_entry` is appended by the caller to the run log; this skill produces it but does not write it.

## 5. References — autonomy table (PLAN §7)

- **Secrets (gitleaks):** ALWAYS quarantine + redact + open rotation issue. Never bypass; never commit the literal even temporarily.
- **CVEs (trivy):** ALWAYS upgrade-first. Only fall back to `.trivyignore` with a 30-day expiry and a tracking issue.
- **Same finding seen twice within a run:** the *caller* (`sensor-fixer`) is responsible for tier-escalating the model on retry. This skill simply honors `finding.model_override` if set; it does not decide escalation. **⚠ Not yet wired (#287):** no runtime currently consumes `model_override` — this skill runs under the Skill tool, which cannot switch models mid-invocation. The field and the escalation policy are documented intent; they take effect only once a future Agent-tool-based dispatch reads the override.

## 6. Hard rules

- **NEVER** rewrite git history (`git rebase`, `git filter-branch`, `git push --force` on shared branches). Redactions are forward commits.
- **NEVER** use `git commit --no-verify` or `pre-commit run --no-verify`. If hooks fail, the finding goes to Branch 4 carry-over — not bypass.
- **NEVER** write a generic suppression reason. `# nosec B101: false positive` is rejected; `# nosec B101: subprocess args are hardcoded constants in CI bootstrap` is accepted.
- **ALWAYS** prefer a dependency upgrade over adding to `.trivyignore`. Reach for `.trivyignore` only after upgrade is attempted and proven not viable.
- **ALWAYS** ensure `.gitignore` covers `.secrets/` before writing to `.secrets/quarantine/`.
- **ALWAYS** open a tracking issue when a secret is redacted or a CVE is ignored — visibility beats convenience.
