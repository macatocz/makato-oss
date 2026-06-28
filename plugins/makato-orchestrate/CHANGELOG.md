<!-- markdownlint-disable MD013 -->
# Changelog — makato-orchestrate

Changes are grouped by skill/component. Within each group, latest version on top. Each version block lists one sub-bullet per logical change.

---

## workflow-state (GAP-003 / #26)

- **1.0.0** — Initial `workflow-state` skill and helper
  - `skills/workflow-state/SKILL.md` — Skill documentation covering schema reference, five subcommands (`init`/`read`/`write`/`patch`/`append-lesson`), staleness rule (>24 h triggers stale at session resume — detection is the caller's responsibility), JSONL audit logging requirement, and HALT codes. `halt_audit[]` accommodates future codes `HALT-007B` (context-ceiling, GAP-004 extension) and `HALT-008` (outer-iteration cap) without schema change.
  - `skills/workflow-state/references/workflow-state.schema.json` — JSON Schema draft-07. All 16 required top-level fields per issue #26. Sub-schemas for `sub_tasks[]`, `halt_audit[]`, and `lessons_learned[]` item shapes (each `additionalProperties: false`). ISO-8601 `format: date-time` on all timestamp fields. Top-level `additionalProperties: false`.
  - `skills/workflow-state/references/smoke-tests.sh` — Manual verification harness covering 9 cases (schema parses, init creates valid file, init refuses duplicate, read returns file, read on missing key returns `{}`, patch updates field and timestamp advances, indexed-path patches, append-lesson grows array, invalid write halts). No automated CI hook — matches `shared/` convention in `makato-build`.
  - `shared/workflow-state.sh` — Shell helper (`set -euo pipefail`, positional args, `${VAR:?msg}` for required args). Spec-folder resolution duplicated from `plugins/makato-build/shared/build-log.sh:13-22` (prefix-match `specs/<key>-*/` → fallback `specs/<key>/` → create placeholder). `jq` for all mutations (per issue #26 AC); `python3 + jsonschema` for validation (matches `plugins/makato-plan/skills/issue-to-project` precedent, fail-open if `jsonschema` is not installed). Atomic writes via `mktemp` + `mv`. `updated_at` injected automatically on every write/patch/append-lesson.
  - `plugins/makato-build/skills/build-implement-tdd/SKILL.md` patched (1.5.0 → 1.6.0) — adds guarded `workflow-state patch` calls after the R1-mirror block on the `r1.status == "success"` branch. Cross-plugin path resolved via `git rev-parse --show-toplevel`; `-x` test skips silently when running in a consumer repo without the `makato-orchestrate` plugin present.

---

## Plugin scaffold (GAP-001 / #23)

- **0.1.0** — Initial plugin scaffold
  - `.claude-plugin/plugin.json` created with name, description, author (no `version` field — repo-level release-please + git tags carry the version per suite convention)
  - `AGENTS.md` — Contributor guide: goal, orchestrate boundary, scope inclusions/exclusions, decision test, design principles (state SoT, HALT codes, R1 end-to-end, resumability), security model (PO-agent `bypassPermissions` + safeguards), agent roster table (stubs), skill authoring rules, file structure, `--autonomous` invocation contract, versioning, PR checklist
  - `README.md` — User-facing overview: status banner with tracking-issue references for each follow-up gap, orchestrate boundary, upstream/downstream integration with `makato-plan` and `makato-build`, sibling `issue-to-project` lifecycle hand-off, `--autonomous` propagation table, skills/agents/hooks scaffold tables linked to tracking issues, `orchestrate.jsonl` logging schema, high-level workflow ASCII diagram, file-structure listing, see-also references (AgenticSystem PRD, RETURN-CONTRACT.md, AUTONOMOUS-MODE.md)
  - `CLAUDE.md` — `@AGENTS.md` reference (matches makato-build / makato-change pattern)
  - Directory structure: `skills/`, `agents/`, `hooks/`, `shared/` created with `.gitkeep` placeholders so the empty subdirectories are tracked
  - Root `.claude-plugin/marketplace.json` extended with the `makato-orchestrate` entry so the plugin is discoverable from the makato-suite marketplace
