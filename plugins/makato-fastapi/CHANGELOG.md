# Changelog — makato-fastapi

## [1.1.0] — 2026-08-08

### Changed
- Raised `fastapi` skill to grade B via skill-judge rubric (commit `522570e`, PR #694)
- Added MANDATORY trigger annotations to every Quick Reference table row in `SKILL.md`
- Tightened progressive-disclosure structure across `SKILL.md` and all six reference files —
  no behavior, contract, or output changes

## [0.1.0] — 2026-07-14

### Added
- Initial plugin with governance files
- Plugin manifest (plugin.json)
- Contributor guide (AGENTS.md)
- `fastapi` reference skill (SKILL.md + 6 references: path-operations, dependencies,
  streaming, responses, pydantic, other-tools) covering `Annotated` parameters and
  dependencies, router composition, return-type / `response_model` filtering, streaming
  (JSON Lines / SSE / bytes), Pydantic conventions, and the recommended tooling ecosystem
- `config/skill-bundles.yml` — routes FastAPI files and task text to the `fastapi` skill via
  makato-build's inject-skills resolver
- `pre-commit/validate-skill-bundles.sh` — authoring gate rejecting wide globs without a
  content or task-text precision filter
