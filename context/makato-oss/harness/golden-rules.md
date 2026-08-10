# makato Golden Rules & Hard Constraints

> **Scope**: Non-negotiable boundaries every agent and contributor must respect
> across the makato monorepo. `context-scout` surfaces these as **Critical**-tier
> hard constraints. Violating one is grounds for rejecting a PR in review.

## Plugin isolation

- **No cross-plugin `../../` paths.** A skill references only its own plugin
  (`../shared/`) — never another plugin's internals. Plugins integrate through
  documented contracts (READMEs / AGENTS.md), not file reach-through.
- Each plugin's `AGENTS.md` is authoritative for that plugin's surface. Do not
  re-derive a plugin's conventions from a neighbouring plugin.

## Autonomous loop safety

- `~/.claude/HALT` is checked before every dispatch — it is NEVER skipped.
- The PO-agent is the **sole writer** of `workflow-state.json`.
- Agents never edit target-repo source files when their role is orchestration
  only (PO-agent, documentation-agent).

## Provenance & routing

- Issues entering the autonomous loop carry a `to-issues` provenance footer so
  `_derive_key_for_issue` can derive the KEY. Hand-filed issues are stamped by
  `seed-issue` before dispatch.
- Spec folders are resolved via `makato.config.json → specsRoot`, then
  `specs/index.yml`. No env-var fallback, no sibling-directory autodetect.

## Skill routing default-on

- Every agent is skill-routed unless it declares `skill_routing: disabled` in
  frontmatter. Opt-outs are enumerated in the root `AGENTS.md`.

<!-- POPULATE: add repo-specific golden rules as they are ratified. Keep each
     rule to a single enforceable sentence; link to the authoritative source. -->
