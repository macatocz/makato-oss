<!-- markdownlint-disable MD013 -->
# Changelog — makato-orchestrate

Changes are grouped by skill/component. Within each group, latest version on top. Each version block lists one sub-bullet per logical change.

---

## Plugin scaffold (GAP-001 / #23)

- **0.1.0** — Initial plugin scaffold
  - `.claude-plugin/plugin.json` created with name, description, author (no `version` field — repo-level release-please + git tags carry the version per suite convention)
  - `AGENTS.md` — Contributor guide: goal, orchestrate boundary, scope inclusions/exclusions, decision test, design principles (state SoT, HALT codes, R1 end-to-end, resumability), security model (PO-agent `bypassPermissions` + safeguards), agent roster table (stubs), skill authoring rules, file structure, `--autonomous` invocation contract, versioning, PR checklist
  - `README.md` — User-facing overview: status banner with tracking-issue references for each follow-up gap, orchestrate boundary, upstream/downstream integration with `makato-plan` and `makato-build`, sibling `issue-to-project` lifecycle hand-off, `--autonomous` propagation table, skills/agents/hooks scaffold tables linked to tracking issues, `orchestrate.jsonl` logging schema, high-level workflow ASCII diagram, file-structure listing, see-also references (AgenticSystem PRD, RETURN-CONTRACT.md, AUTONOMOUS-MODE.md)
  - `CLAUDE.md` — `@AGENTS.md` reference (matches makato-build / makato-change pattern)
  - Directory structure: `skills/`, `agents/`, `hooks/`, `shared/` created with `.gitkeep` placeholders so the empty subdirectories are tracked
  - Root `.claude-plugin/marketplace.json` extended with the `makato-orchestrate` entry so the plugin is discoverable from the makato-suite marketplace
