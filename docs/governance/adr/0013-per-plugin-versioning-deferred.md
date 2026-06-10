# ADR-0013: Per-Plugin Versioning — Deferred

## Status

Deferred (revisit when makato-build ships its first skills, or when at least two plugins have independent release cadence)

## Date

2026-05-19

## Context

ADR-0009 established that `plugin.json` carries no `version` field — Claude Code's plugin cache uses the git commit SHA for invalidation, so every merge to `main` is automatically picked up by users on the `latest` channel. Repo-level versioning is handled by release-please, producing one CHANGELOG and one `vX.Y.Z` tag for the entire suite.

A second model exists and is documented by Anthropic: each plugin declares its own `version` in `plugin.json`. Brad Bonanno's "Build an Execution Layer for Your Company Brain" demonstrates this pattern in practice — his marketplace manager skill bumps each plugin's version on every change. The Anthropic plugin-marketplace docs explicitly warn (Version resolution section) that pinning a `version` and then forgetting to bump it leaves users on a stale cache, since the version string — not the SHA — becomes the cache key.

The question raised was whether to switch from the SHA-based model to per-plugin semver, motivated by:
- Independent plugin lifecycles (e.g., `makato-plan@1.2.0` while `makato-build@0.4.0`)
- Per-plugin changelogs that consumers can read without scanning a repo-level log dominated by one plugin's churn
- Closer alignment with how mature plugin ecosystems present versions to end users

Comparison of the two models:

|                              | No `version` (current, ADR-0009) | Per-plugin `version` (proposed)                        |
|------------------------------|----------------------------------|--------------------------------------------------------|
| Cache invalidation key       | git commit SHA                   | the `version` string                                   |
| User sees update when        | any commit changes plugin files  | author bumps `version` in `plugin.json`                |
| Authoring overhead           | zero                             | every plugin-touching PR bumps that plugin's version   |
| "Forgot to bump" risk        | none                             | real — silent stale cache for all consumers            |
| Independent plugin lifecycles | hard — one repo tag covers all   | clean — each plugin moves on its own clock             |
| Per-plugin changelogs        | not natural at repo level        | natural                                                |
| Aligns with current repo state | yes                            | requires rewriting AGENTS.md and migrating four plugins |

The dominant argument *against* flipping today is asymmetric risk vs. reward: makato-plan ships nearly every meaningful skill in the suite, the other plugins are scaffolding, and the repo tag effectively *is* the makato-plan version already. Per-plugin semver buys little in this state, while introducing a foot-gun (forgotten bump → users stuck on old cache) that the current model does not have.

The dominant argument *for* flipping eventually is that the current model is invisible — consumers cannot answer "what version of makato-plan am I on?" except via commit SHA — and that limitation gets more painful as the suite grows past one active plugin.

## Decision

**Keep the current model (no `version` in `plugin.json`, SHA-based cache invalidation, repo-level release-please) for now.** Do not migrate to per-plugin versioning at this time.

Revisit this decision when *any* of the following becomes true:

1. **makato-build starts shipping skills.** Once two plugins have meaningful, independent release cadence, the repo-level changelog stops representing what consumers care about.
2. **A second plugin's PRs frequently land without touching makato-plan.** This is the operational signal that plugin lifecycles have actually diverged.
3. **A consumer asks "what version of plugin X am I on?"** more than once. The current model has no good answer; if that question becomes recurring, the model is failing its users.

Before flipping, the following must be in place (cheap to do later, expensive to retrofit if missed):

- Update AGENTS.md — drop the "no `version` in plugin.json" rule established in ADR-0009.
- Add `version` field to every `plugin.json`, picking a sensible starting number (likely mirroring the current repo version).
- Add a CI check that any PR touching `plugins/<X>/**` also bumps `plugins/<X>/.claude-plugin/plugin.json` `version`. **Without this guard, the foot-gun fires within a sprint** — see Anthropic's explicit warning on stale-cache risk. Initial rollout can be warn-only to build muscle memory before becoming blocking.
- Decide whether release-please continues cutting a repo-level tag (probably yes, but its role becomes "snapshot of the suite at a moment in time," not "the version").
- Consider whether per-plugin CHANGELOGs should be wired into release-please as separate components, or whether each plugin's `CHANGELOG.md` is maintained by hand.

## Consequences

- ADR-0009's "no `version` in plugin.json" rule remains in force. AGENTS.md:73 unchanged.
- Consumers continue to upgrade by `claude plugin marketplace update <name>` followed by `claude plugin update` — the plugin cache notices the new commit SHA and refreshes.
- The "stable" vs "latest" distinction continues to be expressed as floating git tags moved by CI and release-please, not as differing `version` strings (per ADR-0009).
- The decision to defer is itself recorded — future contributors will not need to re-derive the tradeoff from scratch.
- When the trigger conditions are met, this ADR is superseded by a new ADR ("Per-Plugin Versioning — Adopted") rather than amended.
