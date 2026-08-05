---
name: build-resolve-finding
description: >-
  Per-finding decision tree that resolves a single sensor finding via 4 branches —
  autofix (targeted CLI retry), tech-skill route (action `skill` or `autofix-then-skill`
  fallback), safe-automated action (redact/upgrade/suppress), or carry-over to draft PR.
  Use when sensor-fixer dispatches a finding for repair.
version: "1.1.0"
argument-hint: "{finding JSON object from sensor-fixer}"
allowed-tools: all
metadata:
  Authors: makato-build
  last_updated: "2026-08-05"
---

# build-resolve-finding

**Do NOT load** `references/default-fix-commands.md` or `references/output-envelope.md`
up front — each has a MANDATORY trigger below at the exact point of use.

## 1. Overview

This skill is the **per-finding decision engine** invoked by the `sensor-fixer` orchestrator.
It receives a single normalized sensor finding (one rule violation in one file), decides which
of four branches applies, executes that branch, and returns a structured outcome.

**Knowledge of *how* to fix a class of finding lives here**, in this skill — not in
`sensor-fixer`. The orchestrator only dispatches; this skill decides and acts.

The four branches are:

1. **Autofix** — the tool itself can fix it (e.g., `ruff --fix`, `prettier --write`).
   Run the tool, re-verify the hook.
2. **Tech-skill route** — the finding maps to a specialized skill via `finding-routes.json`
   (e.g., a typing fix, a lint pattern). Load that skill, apply one fix attempt.
3. **Safe-automated action** — deterministic remediation requiring no judgment:
   secrets → quarantine + redact + issue; CVE → upgrade-or-ignore;
   bandit warning → suppress with justified reason.
4. **Carry-over** — structural findings that cannot be auto-resolved. Record in the draft PR
   description; leave the hook red; let a human address it.

### Relationship to `sensor-fixer` Phase 0

`sensor-fixer` v1.1.0+ runs a batched-autofix **Phase 0** before dispatching this skill.
Phase 0 collects every finding whose route action is `autofix` or `autofix-then-skill`,
groups by `cmd`, runs each distinct cmd once on the union of files, then re-parses and drops
resolved findings.

This skill is only invoked for findings that **survived** Phase 0. The consequence:

- A finding with route `action: "autofix"` that reaches this skill is
  **already-attempted-and-failed-by-the-CLI**. Branch 1 still re-runs the autofix on this
  single file (a targeted retry may succeed where the batched call did not — e.g. when a
  non-fatal failure on an unrelated file aborted the batch before reaching this one). If the
  targeted retry still fails, the finding falls through to Branch 4 carry-over.
- A finding with route `action: "autofix-then-skill"` that reaches this skill goes directly
  to Branch 2 using `route.fallback_skill` — the batched autofix has already had its shot.

## 2. Inputs (Finding shape)

The caller passes a single finding object. The canonical Finding contract is documented in
[`shared/finding-schema.md`](../../shared/finding-schema.md). Key fields consumed here:

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

`attempt` increments on retry. `model_override` is set by the caller if a tier escalation is
in effect. **Reserved/inert (#287):** no runtime consumes `model_override` yet — this skill is
invoked via the Skill tool, which has no `model` parameter, so the field is documented for a
future Agent-tool-based dispatch but currently has no effect.

The route lookup key is `"<tool>:<rule>"` — concatenation of `tool` and `rule`.

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
              │                  ▼                  ▼                  ▼
              │             ┌─────────────────────────┐         ┌───────────┐
              │             │  BRANCH 2 — Tech-skill  │         │ BRANCH 3  │
              │             │  route.skill           │         │ Safe-auto │
              │             │   OR                   │         └─────┬─────┘
              │             │  route.fallback_skill  │               │
              │             └─────────┬──────────────┘               │
              │                       │                              │
              │          no route / structural / skill HALT          │
              │                       │                              │
              │                 ┌─────▼─────┐                        │
              │                 │ BRANCH 4  │                        │
              │                 │ Carry-over│                        │
              │                 └─────┬─────┘                        │
              │                       │                              │
              └───────────────────────┴──────────────────────────────┘
                                   │
                          Re-run hook on file
                                   │
                          ┌────────┴────────┐
                          │                 │
                        green             still red
                          │                 │
                      resolved          failed / carry-over
```

### Route-resolution fallbacks

**finding-routes.json absent:** treat every finding as having no route entry.
`autofix_available == true` → Branch 1 with default cmd table; otherwise → Branch 4.

**Key `<tool>:<rule>` not found:** fall through to the wildcard `<tool>:*` entry if one
exists. If no wildcard matches either → same fallback as "file absent" above.

**MANDATORY — load `references/default-fix-commands.md` now if entering Branch 1 without a
matching route entry**, to determine the default cmd for the tool.

### Branch 1 — Autofix (`autofix_available == true`)

```
1. cmd = finding-routes.json["<tool>:<rule>"].cmd
        OR fallback default cmd (see references/default-fix-commands.md)
2. Run cmd from repo_root.
3. Re-run the originating hook on <path> only:
        pre-commit run <hook_id> --files <path>
4. If hook now exits 0:
        outcome = "resolved"
   Else:
        outcome = "failed"  → proceed to Branch 4 carry-over
```

**Targeted retry rationale.** Phase 0 already ran this cmd on the union of all
autofix-eligible files in a batch. A single-file invocation can still succeed when the batched
call had a non-fatal failure on an unrelated file that aborted before reaching this one.

### Branch 2 — Tech-skill route (`action == "skill"` or `action == "autofix-then-skill"`)

```
1. route = finding-routes.json["<tool>:<rule>"]
2. Pick the skill name:
        action == "skill"              → skill_name = route.skill
        action == "autofix-then-skill" → skill_name = route.fallback_skill
                                         (Phase 0 already ran route.cmd)
3. Load skill: skill_name (e.g. "makato-build:build-fix-types",
   "makato-doc:markdown", "makato-build:build-simplify").
4. Pass {finding, repo_root} to that skill.
5. Skill applies pattern in-place. ONE fix attempt only.
6. Re-run originating hook on <path>.
7. If outcome == "resolved": report resolved, set skill_used = skill_name.
   If outcome == "failed":   report failed.
   If called skill itself HALTs (returns a HALT code): do NOT re-invoke.
        Record the HALT code + skill_name in Branch 4 carry-over as
        "skill-halted: <code>" reason. outcome = "carry-over".
```

**Why two action values dispatch to the same branch.** `skill` means "this rule class needs
reasoning — there is no CLI autofix worth attempting." `autofix-then-skill` means "most members
of this rule class have a CLI autofix, but a structural subset does not." Phase 0 already
attempted the autofix on the full batch; whatever reaches this branch is the structural subset,
and `route.fallback_skill` is the domain expert for that subset (e.g. `makato-doc:markdown`
for residual MD0xx after `markdownlint --fix`).

The called skill is responsible for its own internal logic; this skill does not retry it.

### Branch 3 — Safe-automated actions

Three deterministic sub-actions, dispatched by `action` value in `finding-routes.json`.

#### 3a. `action == "redact-and-issue"` (gitleaks / secret scanners)

```
1. Read <path>:<line>; identify the literal secret value.
2. Choose env var NAME from rule context (e.g. AWS_ACCESS_KEY_ID, OPENAI_API_KEY).
3. Replace literal in source with: os.environ["NAME"]
   (or the language-appropriate equivalent — process.env.NAME, std::env::var, etc.)
4. Quarantine the original literal:
        REPO=$(git -C <path_dir> rev-parse --show-toplevel)
        mkdir -p "$REPO/.secrets/quarantine"
        echo "<literal>" > "$REPO/.secrets/quarantine/<sha>.txt"
   where <sha> = sha256(literal)[:12].
5. Verify .gitignore contains an entry for ".secrets/" — add it if missing.
6. Call create-issue skill with:
        title: "rotate KEY <prefix>"       # <prefix> = first 6 chars of literal
        body:  finding.message + redaction details + path:line + sha pointer
7. git add <path> .gitignore && git commit -m "chore(security): redact <NAME>"
8. Re-run gitleaks hook on <path> → expect green.
9. outcome = "resolved" if hook green, else "failed".
```

**Never** commit the raw literal. **Always** create the rotation issue, even if the credential
looks expired or fake — it is not this skill's job to judge authenticity.

#### 3b. `action == "upgrade-or-ignore"` (trivy / dependency CVEs)

```
1. Detect package manager from repo_root:
        - pyproject.toml + uv.lock        → "uv lock --upgrade-package <pkg>"
        - pyproject.toml + poetry.lock    → "poetry update <pkg>"
        - package.json + pnpm-lock.yaml   → "pnpm update <pkg>"
        - package.json + package-lock.json → "npm update <pkg>"
        - package.json + yarn.lock         → "yarn upgrade <pkg>"
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
3. Reject and return outcome = "failed" if the only reason available is generic
   ("not a real risk", "false positive", "won't exploit").
4. Append inline at end of offending line:
        # nosec B<id>: <specific reason>
5. Re-run bandit on <path>.
6. outcome = "resolved" if green, else "failed".
```

### Branch 4 — Carry-over

```
Triggered when:
  - autofix_available is false AND no usable route exists, OR
  - Branch 1 targeted retry failed, OR
  - Branch 2 called skill returned "failed" or HALT, OR
  - Branch 3c generic justification rejected.
Steps:
  1. Format finding for human review:
        - <tool>:<rule> at <path>:<line>
        - <message>
        - severity
        - carry-over reason (e.g. "autofix-failed", "no-route", "skill-halted: HALT-006",
          "generic-suppression-rejected")
  2. If a draft PR already exists for this branch:
        gh pr edit <num> --body "$(existing_body)\n\n## Carry-over: <tool>:<rule>\n…"
     Else:
        Stash entry into <repo_root>/.makato/carry-over.jsonl
        for build-create-pr to consume.
  3. Leave the failing hook red — DO NOT suppress, DO NOT --no-verify.
  4. outcome = "carry-over"
```

## 4. Output

**MANDATORY — load `references/output-envelope.md` before returning**, to confirm the
envelope shape and `jsonl_entry` structure you must emit to `sensor-fixer`.

## 5. Autonomy reference

- **Secrets (gitleaks):** ALWAYS quarantine + redact + open rotation issue. Never bypass;
  never commit the literal even temporarily.
- **CVEs (trivy):** ALWAYS upgrade-first. Only fall back to `.trivyignore` with a 30-day
  expiry and a tracking issue.
- **Same finding seen twice within a run:** the *caller* (`sensor-fixer`) is responsible for
  tier-escalating the model on retry. This skill honors `finding.model_override` if set; it
  does not decide escalation. **Not yet wired (#287):** no runtime currently consumes
  `model_override` — this skill runs under the Skill tool, which cannot switch models
  mid-invocation. Documented intent only; takes effect once a future Agent-tool dispatch reads
  the override.

## 6. Anti-patterns

These are failures that appear plausible but reliably cause harm in this skill's domain.

**NEVER call the routed skill a second time if it HALT-exits.**
Why: a HALT from a repair skill (e.g. `build-fix-types` returns HALT-006 for a missing plan)
signals a structural precondition failure, not a transient error. Re-invoking spins indefinitely
and consumes token budget while the underlying cause (missing spec artifact, ambiguous type) is
invisible. Route to Branch 4 carry-over with the HALT code captured in the reason field.

**NEVER write to `.secrets/quarantine/` using `pwd`-relative paths.**
Why: `sensor-fixer` may invoke this skill from a worktree directory that differs from
`repo_root`. A relative path silently lands the quarantine file outside the repo, the
`.gitignore` entry misses it, and the literal can end up staged. Always derive the quarantine
directory from `git rev-parse --show-toplevel` or the `finding.repo_root` field.

**NEVER suppress a bandit finding whose justification cannot reference a specific construct.**
Why: generic suppression comments (`# nosec B101: false positive`) accumulate silently and
convert security-scanning gates into dead checks. The reject-on-generic rule in Branch 3c
exists precisely because "sounds fine" suppressions are the primary source of scan-gate
erosion — the only recoverable path is carry-over, which keeps the hook red and forces a
human decision.

**NEVER attempt a dependency upgrade without running the test suite fast subset afterward.**
Why: `uv lock --upgrade-package <pkg>` can silently introduce an incompatible transitive
dependency that passes `trivy` but breaks runtime. The `.trivyignore` fallback with a tracking
issue is preferable to a green sensor gate masking a broken build.

**NEVER write a `.trivyignore` entry without the `expires:` and `reason:` inline comment.**
Why: unexpired, unexplained entries accumulate across branches and repositories.
Within 30 days no one remembers why the CVE was ignored; the rotation-issue link is the only
audit trail. A bare `CVE-XXXX-YYYY` line in `.trivyignore` is operationally equivalent to
having no ignore policy at all.

**NEVER force-push or rebase to recover from a failed redaction commit.**
Why: the commit that introduced the secret already landed in `origin`. Force-pushing does not
remove it from forks, caches, or CI logs — it only breaks bisect for every other contributor.
The correct remediation is a forward redaction commit, immediate secret rotation, and the
create-issue call that this skill mandates.

## 7. Hard rules

- **NEVER** rewrite git history (`git rebase`, `git filter-branch`, `git push --force` on
  shared branches). Redactions are forward commits.
- **NEVER** use `git commit --no-verify` or `pre-commit run --no-verify`. If hooks fail, the
  finding goes to Branch 4 carry-over — not bypass.
- **NEVER** write a generic suppression reason. `# nosec B101: false positive` is rejected;
  `# nosec B101: subprocess args are hardcoded constants in CI bootstrap` is accepted.
- **ALWAYS** prefer a dependency upgrade over adding to `.trivyignore`. Reach for
  `.trivyignore` only after upgrade is attempted and proven not viable.
- **ALWAYS** ensure `.gitignore` covers `.secrets/` before writing to `.secrets/quarantine/`.
- **ALWAYS** open a tracking issue when a secret is redacted or a CVE is ignored — visibility
  beats convenience.
