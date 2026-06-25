<!-- markdownlint-disable MD013 -->
# Spec: GitHub Enterprise Server Support, v2.6.0

> **Status:** Design. Targets `issue-to-project` v2.6.0. Depends on v1.0.0+ contract.
> **Spec date:** 2026-06-26
> **Predecessor:** `docs/superpowers/specs/2026-06-24-issue-to-project-design.md` (v1.0.0)

## Goal

Allow `issue-to-project` to target a GitHub Enterprise Server (GHES) instance in addition to github.com. Operators configure a `host` in the `github_project` config block; the skill routes all `gh` invocations to that host. v1.0.0 behavior is preserved bit-for-bit when `host` is absent or `"github.com"`.

The driving use-case: teams whose issues and projects live on a corporate GHES instance (`github.example.com`) cannot use v1 at all — the hard-coded `GH_HOST=github.com` prefix causes every `gh` call to target the wrong host and fail pre-flight.

## Non-Goals

- GitHub Enterprise Cloud with data residency. The `gh` CLI treats GEC with data residency as a standard cloud host; operators configure it as `host_type: "cloud"`.
- GHES < 3.10. Projects v2 (the GraphQL surface this skill uses) requires GHES 3.10+. Earlier releases have only classic Projects (completely different API). This spec defines a hard check that fails before any sync attempt.
- Hybrid configs: issues on github.com, project board on GHES, or vice versa. One config block = one host.
- TLS bypass for self-signed certificates. Operators install their CA into the system trust store; the skill never passes `--insecure` or sets `GH_TLS_SKIP_VERIFY`.
- Per-user or per-run host override flags. The host is a config-level concern set once at `--init` time.

## Architecture

### High-level

```
.claude/config.json
  github_project:
    host: "github.example.com"      ← new (default: "github.com")
    host_type: "enterprise"         ← new (default: "cloud")
    min_ghes_version: "3.10"        ← new (enterprise only)
    ... all v1 keys unchanged ...

Pre-flight checks (extended):
  Check 1  gh binary on PATH         (unchanged)
  Check 2  gh auth --hostname <host> (was: GH_HOST=github.com gh auth status)
  Check 3  gh project subcommand     (unchanged)
  Check 4  project OAuth scope       (deferred to first gh project call; unchanged)
  Check 5  GHES version ≥ 3.10       (NEW; enterprise only)

All gh invocations:
  v1: GH_HOST=github.com gh ...
  v2.6: gh --hostname <resolved_host> ...   (env alias still accepted; see D3)

Rate-limit guard:
  429 / X-RateLimit-Remaining:0 → HALT RATE_LIMIT_EXCEEDED

TLS failure guard:
  TLS handshake errors → HALT TLS_TRUST_FAILED
```

No new execution paths, no new subagent fan-out. The same `--init` wizard and 5-step normal-run flow from v1 apply; this spec documents the deltas.

### Why this approach (alternatives considered)

**Flag `--hostname` instead of env `GH_HOST`.** `gh` documents `--hostname` as the per-invocation host specifier; `GH_HOST` is a process-wide env override. Using `--hostname` is explicit, appears in shell history, and is greppable in logs without expanding env vars. It also allows future parallel-host test harnesses without fighting env inheritance. See D3.

**Config-level host, not per-invocation.** One repo, one host. Putting the host in config alongside `project_node_id` means the same config-validation step that already rejects stale IDs can also reject a missing or malformed host. See D2.

**Version gate before any sync, not post-hoc.** GHES 3.9 has no `ProjectV2SingleSelectField` type in its GraphQL schema. Proceeding past pre-flight into step 3 (snapshot) would surface a cryptic `gh api` GraphQL error buried in the middle of output. A pre-flight Check 5 surfaces a human-readable message with the installed version and the 3.10 requirement. See D5.

## Data Flow

```
issue-to-project [slug]
        │
        ▼
[Pre-flight]
  resolve_host()      ← reads github_project.host (default: "github.com")
  gh --hostname <host> auth status
  if enterprise: gh --hostname <host> api /meta → check installed_version ≥ 3.10
        │
        ▼
[Step 1 — Read config]
  validate github_project (existing rules + new host/host_type keys)
        │
        ▼
[Steps 2–5 — unchanged logic, all gh calls use --hostname <host>]
  snapshot: gh --hostname <host> project item-list ...
  add:      gh --hostname <host> project item-add ...
  edit:     gh --hostname <host> project item-edit ...
        │
        ▼
[project-sync.json]
  project.host added to artifact's project block
```

Rate-limit guard wraps every `gh project` call in steps 3 and 4. On HTTP 429 or stderr containing `rate limit exceeded`, immediately HALT `RATE_LIMIT_EXCEEDED` (no retry — the Retry-After is surfaced in the message).

TLS guard wraps the same calls. On stderr matching `certificate verify failed`, `SSL`, `x509`, or `tls:`, immediately HALT `TLS_TRUST_FAILED` with the CA-installation pointer.

## Config Schema (diff vs v1)

New keys in `github_project` block. All existing v1 keys are unchanged and remain required.

```json
{
  "github_project": {
    "host": "github.example.com",
    "host_type": "enterprise",
    "min_ghes_version": "3.10",
    "owner": "myorg",
    "owner_type": "organization",
    "number": 3,
    "url": "https://github.example.com/orgs/myorg/projects/3",
    "project_node_id": "PVT_kwHOA6QjJ84BajMV",
    "status_field_id": "PVTSSF_lAHOA6QjJ84BajMVzhVaBWs",
    "status_field_name": "Status",
    "options": {
      "todo": "f75ad846",
      "in_progress": "47fc9ee4",
      "done": "98236657",
      "blocked": "8b7c5461"
    },
    "init_timestamp": "2026-06-26T10:00:00Z",
    "init_skill_version": "2.6.0"
  }
}
```

| New field | Required | Default | Validation rule |
|---|---|---|---|
| `host` | no | `"github.com"` | Non-empty string. No scheme prefix (`https://` is forbidden). Must not contain a path component. |
| `host_type` | no | `"cloud"` | Enum: `"cloud"` or `"enterprise"`. `"enterprise"` enables Check 5 and the GHES version gate. |
| `min_ghes_version` | no | `"3.10"` | Semver string `"MAJOR.MINOR"`. Only read when `host_type == "enterprise"`. Stored so a future policy can raise the floor without a re-init. |

**Backward compatibility.** A config written by v1 has none of these keys. On read, missing `host` resolves to `"github.com"` and missing `host_type` resolves to `"cloud"`. Missing `min_ghes_version` defaults to `"3.10"`. No config migration or re-init required for existing v1 consumers.

**URL synthesis.** `--init` computes `url` as `https://<host>/<owner_type_path>/<owner>/projects/<number>` where `owner_type_path` is `"users"` (user) or `"orgs"` (organization). With a non-github.com host, the computed URL uses that host verbatim.

**`url` in audit artifact.** The `project.url` field written to `project-sync.json` was implicitly github.com in v1. In v2.6 it is the configured URL, which may be an enterprise URL. This is additive-compatible — the field value changes but the key name does not.

## Audit Artifact (diff vs v1)

One new key in the artifact's `project` block:

```json
"project": {
  "owner": "myorg",
  "number": 3,
  "url": "https://github.example.com/orgs/myorg/projects/3",
  "host": "github.example.com"
}
```

`host` is redundant with the scheme+host in `url` but makes the artifact grep-friendly for operators auditing which GHES instance a sync targeted. `url` already existed in v1; `host` is additive.

`project-sync.schema.json` gains `"host": { "type": "string" }` in the `project` object definition (required: true). Existing v1 artifacts without `host` will fail schema validation if re-validated against the v2.6 schema — see Migration Notes.

## Argv & Flag Contract

No new flags. The `--hostname` surface is internal to skill invocations; operators interact only via config. All v1 env vars (`DRY_RUN`, `ITP_GH_TIMEOUT_SECONDS`, `PROJECT_LIST_LIMIT`) are unchanged.

**NEVER list addition.** The v1 SKILL.md NEVER line `"NEVER target the enterprise GitHub host or set GH_HOST to an enterprise endpoint"` is replaced with:

> **NEVER use `GH_ENTERPRISE_TOKEN`.** Authentication is always via `gh auth login --hostname <host>`. The `GH_ENTERPRISE_TOKEN` env var bypasses the token store and is incompatible with the `project` OAuth scope flow.

> **NEVER pass `--insecure` or set `GH_TLS_SKIP_VERIFY`.** Self-signed CA? Install it in the system trust store. The skill does not weaken TLS.

> **NEVER log the configured `host` value in log lines that also contain issue content, project node IDs, or user data** — enterprise hostnames are internal infrastructure. The `[issue-to-project]` prefix lines may log `host` in isolation (e.g. pre-flight messages) but must not concatenate it with sensitive values.

## Error Handling

All v1 error handling is unchanged. New entries:

| Failure mode | When detected | Severity | Action |
|---|---|---|---|
| `host` contains `://` scheme prefix | Step 1 (config validation) | **Abort** | Exit 1, HALT `MALFORMED_CONFIG`: `"issue-to-project: github_project.host must not include a scheme (https://). Set it to the bare hostname, e.g. 'github.example.com'."` |
| `host_type` not `"cloud"` or `"enterprise"` | Step 1 | **Abort** | Exit 1, HALT `MALFORMED_CONFIG`: `"issue-to-project: github_project.host_type must be 'cloud' or 'enterprise', got '<value>'."` |
| `gh auth status` fails for configured host | Check 2 | **Abort** | Exit 1, HALT `PREFLIGHT_FAILED`: `"issue-to-project: 'gh' is not authenticated for host <host>. Run 'gh auth login --hostname <host>' then retry."` |
| GHES version < 3.10 | Check 5 (enterprise only) | **Abort** | Exit 1, HALT `GHES_TOO_OLD`: `"issue-to-project: GHES <installed_version> on <host> does not support Projects v2 (requires 3.10+). Upgrade GHES or use classic Projects instead."` |
| `/meta` API call fails during Check 5 | Check 5 | **Abort** | Exit 1, HALT `PREFLIGHT_FAILED`: `"issue-to-project: could not read /meta from <host> to verify GHES version: <error>. Check network access and authentication."` |
| HTTP 429 or rate-limit stderr from `gh project` | Step 3 or Step 4 | **Abort** | Exit 1, HALT `RATE_LIMIT_EXCEEDED`: `"issue-to-project: rate limit exceeded on <host>. Retry-After: <value from header or 'unknown'>. Re-run after the wait window."` |
| TLS handshake / certificate error from `gh` | Step 3 or Step 4 | **Abort** | Exit 1, HALT `TLS_TRUST_FAILED`: `"issue-to-project: TLS error connecting to <host>. Install the GHES CA certificate into the system trust store. See your GHES administrator."` |

## Cross-cutting

### Exit codes

Unchanged from v1: `0` success/partial, `1` abort or zero items synced, `2` `--init` user-cancelled.

### HALT codes (new + inherited)

Inherited v1 codes are immutable. New codes in v2.6:

| HALT code | Meaning | Exit |
|---|---|---|
| `GHES_TOO_OLD` | GHES installed version is below the required floor (3.10) | 1 |
| `RATE_LIMIT_EXCEEDED` | HTTP 429 or rate-limit signal from `gh project` call | 1 |
| `TLS_TRUST_FAILED` | TLS/SSL certificate verification failed (self-signed CA not trusted) | 1 |

All v1 HALT codes (`PREFLIGHT_FAILED`, `MISSING_CONFIG`, `MALFORMED_CONFIG`, `MISSING_INPUT`, `MALFORMED_INPUT`, `EMPTY_INPUT`, `AMBIGUOUS_SLUG`, `SNAPSHOT_FAILED`, `STALE_CONFIG`, `TOTAL_SYNC_FAILED`, `AUDIT_WRITE_FAILED`, `AUDIT_SCHEMA_FAILED`, `INIT_FAILED`, `USER_CANCELLED`) are unchanged in meaning, trigger condition, and exit code.

### Logging

Log prefix rules from v1 (`[issue-to-project]` / `[issue-to-project:auto]`) are unchanged. New v2.6 log lines:

```
[issue-to-project] Targeting host: github.example.com (enterprise, GHES 3.14.2)
[issue-to-project] Check 5: GHES version 3.14.2 >= 3.10 — ok
[issue-to-project] WARN: rate limit on github.example.com; Retry-After: 60s
```

The `host` value is permitted in progress-level log lines. It must not be concatenated with issue titles, user logins, or project node IDs in the same line (see NEVER section).

### Idempotency contract

Unchanged. The re-run guard (snapshot in step 3), the `added_blocked_edit_failed` no-retry rule, and the `needs_status_retry` annotation all behave identically on GHES.

## Return Format (R1)

The R1 sentinel format is unchanged. Callers that parse `RESULT: {json}` see no new required keys. The `artifact_path` still points to `specs/<slug>/project-sync.json` (relative, host-agnostic).

Optional additive key available to callers who inspect it:

```json
RESULT: {"status":"ok","slug":"my-feat","artifact_path":"specs/my-feat/project-sync.json",
         "host":"github.example.com",
         "issues_in_input":8,"already_on_board":0,"added":8,"set_blocked":1,"left_default":7,
         "add_failed":0,"edit_failed":0,"skipped_after_total_failure":0,"dry_run":0}
```

`host` is additive; existing parsers that only read the v1 keys are unaffected.

## Decisions

**D1 — `gh --hostname <host>` flag over `GH_HOST=<host>` env prefix.**
_Decided:_ All `gh` invocations use `gh --hostname <resolved_host> ...` rather than prepending `GH_HOST=<host>`.
_Reasons:_ (1) `--hostname` is scoped to the single invocation; `GH_HOST` is process-wide and leaks into any subprocess that inherits the environment. (2) Explicit flag is greppable in logs and shell history without expanding env vars. (3) `gh` documents `--hostname` as the canonical per-call override.
_Rejected alternatives:_ (a) `GH_HOST=<host> gh ...` prefix — process-wide, env-inheritance risk, v1's own pattern that this spec supersedes; (b) `GITHUB_HOST` env var — not a `gh` CLI variable, would be silently ignored.
_Implications:_ Every `gh` call site in `references/` and `SKILL.md` is updated. Existing v1 callers who set `GH_HOST` externally still work (env var is still read by `gh`); they just no longer need it.

**D2 — Host lives in config, not in argv or env.**
_Decided:_ The host is read from `github_project.host` in `.claude/config.json`, set once at `--init` time.
_Reasons:_ (1) Config-level host means the same validation step that rejects stale `project_node_id` also rejects a malformed host — single validation point. (2) Per-run host flags would allow accidental mis-targeting of a different host than the one the cached `project_node_id` belongs to, producing confusing `STALE_CONFIG`-style errors.
_Rejected alternatives:_ (a) `ITP_HOST` env var — invisible to casual readers of the skill, not self-documenting, not version-controlled alongside the config; (b) `--hostname <host>` argv flag — same mis-targeting risk, and conflates transport config with invocation semantics.
_Implications:_ Multi-host scenarios (issues on GHES A, board on GHES B) are impossible by design. One config block = one host. This is documented in Non-Goals.

**D3 — `GH_HOST` env var accepted as an alias but `--hostname` is the documented path.**
_Decided:_ The skill documents `gh auth login --hostname <host>` and `gh --hostname <host>` as the recommended interface. `GH_HOST` still works because `gh` reads it, but the skill does not set it.
_Reasons:_ (1) Operators familiar with v1 may have `GH_HOST` in their environment; breaking them silently is worse than letting them keep it. (2) Documenting only one interface prevents "which one wins?" questions.
_Rejected alternatives:_ (a) Actively forbid `GH_HOST` — overly restrictive, would require stripping the env var before exec; (b) Prefer `GH_HOST` — regresses to v1's process-wide pattern.
_Implications:_ SKILL.md note: "If `GH_HOST` is set in your environment to a different host than `github_project.host`, `gh` will use `GH_HOST`. Unset it to avoid confusion."

**D4 — Token management via `gh auth login --hostname`; `GH_ENTERPRISE_TOKEN` stays on the NEVER list.**
_Decided:_ v2.6 authenticates to GHES via `gh auth login --hostname <host>`, which stores credentials in the `gh` token store keyed by hostname. `GH_ENTERPRISE_TOKEN` remains forbidden.
_Reasons:_ (1) `GH_ENTERPRISE_TOKEN` is a flat env var; it cannot carry the `project` OAuth scope and has no `read:project` grant mechanism. (2) Token store entries are per-hostname, enabling multi-host setups at the OS level without conflicting env vars.
_Rejected alternatives:_ (a) `GH_ENTERPRISE_TOKEN` — cannot acquire `project` scope; (b) PAT via `echo $TOKEN | gh auth login --with-token` — works but operators must manage scope grants manually; add as a documented fallback, not the primary path.
_Implications:_ The exact invocation for GHES auth is documented in Migration Notes: `gh auth login --hostname github.example.com --scopes project,read:project`. Check 2 failure message includes this command.

**D5 — Hard version gate at pre-flight Check 5 (`/meta` → `installed_version` ≥ 3.10).**
_Decided:_ When `host_type == "enterprise"`, pre-flight calls `gh --hostname <host> api /meta` and extracts `installed_version`, comparing it against `min_ghes_version` (default `"3.10"`).
_Reasons:_ (1) GHES 3.9 and earlier have no Projects v2 GraphQL surface; proceeding would produce cryptic GraphQL `unknown type` errors mid-sync. (2) The `/meta` endpoint is unauthenticated on GHES (returns public instance metadata), so this check does not require a valid token.
_Rejected alternatives:_ (a) Rely on GraphQL schema introspection — verbose, slow, fires after config read rather than at pre-flight; (b) No version check, document the ≥ 3.10 requirement — silently fails with unhelpful errors on 3.9.
_Implications:_ Operators on GHES 3.9 get a clear error. Operators on a future GHES 4.x that raises the `min_ghes_version` floor can update the config without a re-init.

**D6 — `min_ghes_version` stored in config, not hardcoded in skill.**
_Decided:_ `min_ghes_version` is a config key (default `"3.10"`) rather than a compile-time constant in the skill.
_Reasons:_ (1) If GitHub raises the Projects v2 feature floor (unlikely but possible), operators can update their config without waiting for a skill release. (2) Enterprises running a certified GHES release may want to pin to a higher floor for internal compliance reasons.
_Rejected alternatives:_ (a) Hardcode `"3.10"` in skill — simpler but inflexible; (b) Let operators specify a lower floor — creates false confidence; the skill will error on the GraphQL call anyway.
_Implications:_ Validation must compare semver strings correctly (`"3.9"` < `"3.10"` — string comparison fails here; use tuple comparison on split integers).

**D7 — Rate-limit events HALT immediately; no automatic retry.**
_Decided:_ A 429 response or `rate limit exceeded` stderr from any `gh project` call causes an immediate `RATE_LIMIT_EXCEEDED` halt with the Retry-After value surfaced in the message.
_Reasons:_ (1) GHES rate limits are per-install and operator-configured; the skill cannot know when the window resets reliably. (2) Automatic retry with sleep introduces unbounded blocking in an interactive skill. (3) The Retry-After value in the message gives the operator everything they need to re-run manually.
_Rejected alternatives:_ (a) Retry with exponential backoff — appropriate for a daemon, not an interactive CLI skill; (b) Soft-warn and continue — would mask real rate-limit problems with partial-success artifacts that mislead callers.
_Implications:_ Operators on heavily loaded GHES instances may see more manual re-runs. The `ITP_GH_TIMEOUT_SECONDS` mechanism from v1 is unrelated and unchanged.

**D8 — TLS errors HALT immediately; no `--insecure` escape hatch.**
_Decided:_ TLS certificate verification failures immediately HALT `TLS_TRUST_FAILED` with a CA-installation pointer. No skill option bypasses TLS.
_Reasons:_ (1) Providing an `--insecure` flag creates a footgun that operators use in production once the urgency passes and never remove. (2) Proper CA trust-store installation is a one-time operator action that fixes all tools, not just this skill. (3) Allowing TLS bypass would make the skill's GraphQL payloads (containing issue URLs and status values) travel unencrypted or unauthenticated.
_Rejected alternatives:_ (a) `ITP_TLS_INSECURE=1` env var — same footgun; (b) Document but allow `GH_EXTRA_TLS_CA` env var — useful addition but out of scope for v2.6; operators use system trust store.
_Implications:_ Operators with self-signed GHES CAs must complete CA trust-store setup before the skill works. The HALT message links to `gh`'s own CA docs.

**D9 — GraphQL schema drift on GHES handled by `--init`-time field discovery, not runtime introspection.**
_Decided:_ The `ProjectV2SingleSelectField` type name and Status field shape are validated at `--init` time via `gh project field-list`. If GHES's schema uses a different type name (observed on 3.10–3.13), `--init` fails with a clear message naming the unexpected type, and the operator files a bug report.
_Reasons:_ (1) Runtime introspection on every sync adds a GraphQL round-trip for the vast majority of runs where the schema hasn't changed. (2) `--init` is the correct place to absorb schema variance — cached IDs insulate normal runs from schema drift. (3) v1 already validates `type == "ProjectV2SingleSelectField"` at `--init`; this spec inherits that check.
_Rejected alternatives:_ (a) Probe schema on every normal run — too expensive; (b) Hardcode a known GHES type-name alias — fragile across GHES versions.
_Implications:_ A GHES schema divergence that breaks `--init` is caught early. Normal runs degrade gracefully with `STALE_CONFIG` or a `gh` error, not a silent mis-configuration.

**D10 — `host` is additive in both config and artifact; no v1 key is renamed.**
_Decided:_ `host` is a new key alongside existing v1 keys in config and in the artifact's `project` block. No v1 key is removed or renamed.
_Reasons:_ (1) The R1 sentinel and `project-sync.json` are consumed by downstream skills; renaming keys breaks them silently. (2) Additive keys are ignored by v1 consumers; v2.6 consumers read the new key.
_Rejected alternatives:_ (a) Rename `url` to `project_url` and extract `host` from it — v1 artifact consumers would break; (b) Add `host` only to the artifact, not config — inconsistent; operators would have to look at two places.
_Implications:_ The `project.host` key in the artifact and the `github_project.host` key in config are always in sync because `--init` writes both from the same resolved value.

**D11 — `--init` wizard explicitly prompts for and stores `host` and `host_type` as its first step.**
_Decided:_ The `--init` flow gains a new Step 0 before owner resolution: ask for host (default: `github.com`) and derive `host_type` from whether the entered host is `"github.com"`.
_Reasons:_ (1) All subsequent `gh` calls in `--init` need the correct host; it must be resolved first. (2) Auto-deriving `host_type` from the host value reduces operator error surface (`host_type` is not a well-known concept).
_Rejected alternatives:_ (a) Prompt for `host_type` separately — adds an unnecessary question when `host != github.com` implies enterprise; (b) Infer host from existing `gh auth list` — works for some setups but fails if the operator hasn't yet run `gh auth login --hostname <host>`.
_Implications:_ `--init` error messages now always include the configured host in their text.

**D12 — One config block = one host. Multi-host is out of scope and architecture-level rejected.**
_Decided:_ A single `github_project` block maps to a single host. Two hosts require two repos with separate configs.
_Reasons:_ (1) Cross-host setups (issues on github.com, board on GHES) require host-aware URL parsing and separate token entries for each host — dramatically increases the config schema surface. (2) The `project_node_id`, `status_field_id`, and option IDs are host-scoped; mixing them across hosts would produce opaque GraphQL errors.
_Rejected alternatives:_ (a) `hosts[]` array in config — schema doubles; validation logic for each host is duplicated; `--init` would need a wizard per host; (b) `source_host` / `board_host` split keys — encourages the cross-host anti-pattern.
_Implications:_ Teams with issues on github.com and a project board on GHES cannot use v2.6. This is an explicit Non-Goal documented in the spec header.

## Out of Scope

| ID | Item | Reason |
|---|---|---|
| O1 | GitHub Enterprise Cloud with data residency | GEC-DR appears as a standard cloud host to `gh`; configure as `host_type: "cloud"`. No special handling required. |
| O2 | GHES < 3.10 (classic Projects) | Completely different API surface (REST, not GraphQL Projects v2). Would require a parallel code path, not an extension. |
| O3 | Multi-host config (source host ≠ board host) | Architecture-level rejected in D12. |
| O4 | TLS bypass via env var or flag | Security footgun; rejected in D8. |
| O5 | Automatic retry on rate-limit | Inappropriate for an interactive CLI skill; rejected in D7. |
| O6 | `GH_EXTRA_TLS_CA` env var support | Useful for environments where the CA cannot be in the system store; deferred to a future patch. |
| O7 | GHES instance listing / discovery | Operators know their GHES URL. No need for `gh enterprise list` or similar. |
| O8 | `--retry-blocked-edits` mode | Inherited from v1's O8 out-of-scope. |

## File-by-File Changes

| Status | Path | Change |
|---|---|---|
| **Modify** | `plugins/makato-plan/skills/issue-to-project/SKILL.md` | Bump `version` to `2.6.0`. Replace `GH_HOST=github.com gh ...` pattern with `gh --hostname <resolved_host> ...` throughout. Update Check 2 to use `gh --hostname <host> auth status`. Add Check 5 block (enterprise only). Update NEVER section (remove enterprise prohibition; add `GH_ENTERPRISE_TOKEN` and TLS bypass bans). Add three new HALT codes to the HALT table. Add `host` key description to the config block summary. |
| **Modify** | `plugins/makato-plan/skills/issue-to-project/references/init-wizard.md` | Add Step 0 (prompt for host, derive host_type, run Check 5 for enterprise). Update all `gh` invocations to use `--hostname <host>`. Add `host`, `host_type`, `min_ghes_version` to the config-write template. Document the `gh auth login --hostname <host> --scopes project,read:project` invocation in Check 2 failure recovery. Update URL synthesis formula. |
| **Modify** | `plugins/makato-plan/skills/issue-to-project/references/sync-process.md` | Update all `gh project item-list` / `item-add` / `item-edit` invocations to use `--hostname <host>`. Add rate-limit guard and TLS guard wrappers. Add `host` field to the `project` block written in the artifact. |
| **Modify** | `plugins/makato-plan/skills/issue-to-project/references/config-schema.md` | Add rows for `host`, `host_type`, `min_ghes_version`. Document backward-compat defaults. Add semver-comparison note for `min_ghes_version` (integer-tuple, not string). |
| **Modify** | `plugins/makato-plan/skills/issue-to-project/references/project-sync.schema.json` | Add `"host": { "type": "string" }` to the `project` object definition (`required`). Bump schema `$id` or a `version` field to `"2.6.0"` if present. |
| **Modify** | `plugins/makato-plan/CHANGELOG.md` | Add `**2.6.0**` block under `## issue-to-project skill` listing enterprise host support, three new HALT codes, and migration notes. |

## Testing Strategy

Inherits v1's static + dry-run + smoke approach. Additions for v2.6:

| Test | What it covers | How |
|---|---|---|
| Backward-compat: v1 config | Config with no `host` key resolves to github.com; no GHES check fires | Dry-run with a v1-format `.claude/config.json`; assert no Check 5 log line |
| Check 5: version parse | `"3.9"` < `"3.10"` comparison using integer tuples, not string comparison | Unit: `python3 -c "assert tuple(int(x) for x in '3.9'.split('.')) < tuple(int(x) for x in '3.10'.split('.'))"` |
| Check 5: GHES too old | Mock `/meta` returning `"installed_version": "3.9.0"` → HALT `GHES_TOO_OLD` | Manual with a mocked `gh` wrapper script returning the fixture |
| Rate-limit guard | Mock `gh project item-list` exiting with `rate limit exceeded` in stderr → HALT `RATE_LIMIT_EXCEEDED` | Manual with mock `gh` wrapper |
| TLS guard | Mock `gh project item-add` exiting with `certificate verify failed` in stderr → HALT `TLS_TRUST_FAILED` | Manual with mock `gh` wrapper |
| Schema: new `host` key required | Artifact without `host` in `project` block fails schema validation | `python3 -c "import jsonschema; ..."` against a v1-format artifact |
| `--hostname` in all gh calls | No `GH_HOST=` prefix appears in any `gh` invocation site | `grep -r 'GH_HOST=' plugins/makato-plan/skills/issue-to-project/` returns zero results |
| GHES `--init` smoke | Init flow against a GHES 3.10+ test instance; verify written config includes `host` and `host_type: "enterprise"` | Manual, one-time against a GHES sandbox |
| Enterprise normal-run smoke | Normal sync against GHES project; artifact `project.host` matches configured host | Manual, one-time per release on GHES sandbox |

## Migration Notes

**Existing v1 consumers (github.com):** No action required. Missing `host` defaults to `"github.com"`; missing `host_type` defaults to `"cloud"`. All v1 configs are valid v2.6 configs with full backward compatibility.

**New GHES consumers:** Run `issue-to-project --init` from the consuming repo root after authenticating:
```sh
gh auth login --hostname github.example.com --scopes project,read:project
issue-to-project --init
# When prompted for host, enter: github.example.com
```
This writes `host`, `host_type: "enterprise"`, and `min_ghes_version: "3.10"` into the `github_project` block.

**Token scopes on GHES:** The `project` scope name is the same on GHES as on github.com. The grant flow differs: `gh auth login --hostname <host>` opens a browser-based device flow targeting the GHES instance. If using a PAT instead: `echo "$PAT" | gh auth login --hostname <host> --with-token`. Ensure the PAT has `repo` and `project` scopes.

**Existing `project-sync.json` artifacts:** v1 artifacts lack `project.host`. The v2.6 schema requires `host`. If downstream tools validate artifacts against the schema, they must handle v1 artifacts by treating missing `host` as `"github.com"`, or re-run `issue-to-project` to regenerate the artifact.

**`GH_HOST` env var:** If set in your shell environment, it overrides `--hostname`. Unset it (`unset GH_HOST`) when running v2.6 against a GHES host that differs from your `GH_HOST` value to avoid silent mis-targeting.
