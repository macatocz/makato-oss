# Runtime Verification — Issue #43: Model-Provider Autonomous Acceptance Contract

**Story**: local-openai-gpt-macos-compatibility (Task 4 of 6)
**Satisfies**: AC-1 — "The complete Makato OSS suite can run its autonomous
issue-to-PR/merge workflow with native OpenAI GPT models or selectable
Qwen/OpenAI-compatible models, with easy configuration switching, macOS/Apple
Silicon client support, remote Linux support, and validated optional
tooling."
**Verified**: 2026-09-10
**Status**: Offline fixture path passing. Live path opt-in, not exercised in
this evidence pass (no `MAKATO_MODEL_PROVIDER_LIVE=1` opt-in credentials
supplied in CI — see § Live-path activation below).

## Scope

This contract records the acceptance evidence for the provider-neutral
autonomous canary Task 4 adds. It does NOT re-verify Tasks 1-3 (baseline,
provider profiles, harness adapter) — see their own build.jsonl entries in
`specs/local-openai-gpt-macos-compatibility/build.jsonl`. It also does not
cover Task 5/6 (macOS/remote-Linux preflight, documentation) — those are
goal-mode tasks that run after this task in the plan's `runOrder`.

## Acceptance Evidence

| AC | Description | Status | Evidence |
|----|-------------|--------|----------|
| AC-1a | `e2e-mvp-proof.sh` selects a model profile (`config/model-profiles.yml`) and validates provider-aware auth before every run, without weakening the existing issue-to-PR/merge DoD checks | PASS | `plugins/makato-orchestrate/scripts/tests/e2e-mvp-proof-smoke-tests.sh` T6-T10: default profile resolves without a credential (T6); unsupported profile rejected (T7); missing `OPENAI_API_KEY` rejected by name, never by value (T8); a set credential is never echoed to stdout/stderr (T9); a full stubbed dispatch run with an explicit profile still reports all 3 DoD rows PASS (T10) |
| AC-1b | An OpenAI chat-completions tool-call response and a vLLM/Qwen3 tool-parser response (`tool_format: openai` vs `qwen3` in `config/model-profiles.yml`) normalize to the same canonical `{id, name, arguments}` shape | PASS | `tests/integration/model-provider-dispatch-e2e.sh` Scenarios A/B against `tests/fixtures/model-provider/openai-tool-call.json` (arguments as a JSON-encoded string) and `qwen-tool-call.json` (arguments already a parsed object — the documented vLLM Qwen3 tool-parser quirk) |
| AC-1c | Malformed or truncated provider responses are classified as actionable failures, never silently accepted as success | PASS | `tests/integration/model-provider-dispatch-e2e.sh` Scenarios C (`TRUNCATED_JSON`), D (`MISSING_TOOL_CALLS`), E (`INVALID_ARGUMENTS_TYPE`) |
| AC-1d | R1 terminal envelopes are structurally validated (schema/status/required keys) | PASS | `tests/integration/model-provider-dispatch-e2e.sh` Scenarios F (valid envelope accepted) and G (invalid envelope rejected with ≥2 actionable reasons) |
| AC-1e | Provider-specific credential requirements are correct and never leak a value | PASS | `tests/integration/model-provider-dispatch-e2e.sh` offline auth-requirement scenario: `openai` profile requires `OPENAI_API_KEY`; `qwen-vllm` requires no credential (`scripts/resolve-model-profile.py --emit summary`) |
| AC-1f | Complete autonomous flow: issue claim, worktree, Skill/Task subagent dispatch, filesystem/Bash tool events, streaming, session resume, PR creation, merge-state/board Done detection | PASS | `tests/integration/autonomous-pr-loop-e2e.sh` Scenarios A-F (offline, PATH-stubbed `gh`/harness — no live network call) |
| AC-1g (opt-in, live) | Live OpenAI and live Qwen/Ollama-compatible endpoint health/auth checks | SKIP (not exercised — opt-in prerequisites absent) | `tests/integration/model-provider-dispatch-e2e.sh` Scenario H; requires explicit `MAKATO_MODEL_PROVIDER_LIVE=1`, `OPENAI_API_KEY`, `MAKATO_LIVE_QWEN_ENDPOINT_URL`, `MAKATO_LOOP_DISPATCH_REPO` |

## Test Surface

| File | Role |
|------|------|
| `plugins/makato-orchestrate/scripts/e2e-mvp-proof.sh` | Production: profile selection + provider-aware auth guard (§ AC-1a), preserves the 3 existing DoD rows |
| `plugins/makato-orchestrate/scripts/tests/e2e-mvp-proof-smoke-tests.sh` | Unit-tier: T1-T10, offline, PATH-stubbed |
| `tests/integration/model-provider-dispatch-e2e.sh` | Integration: fixture parsing, tool-call normalization, failure classification, R1 validation, offline auth-requirement check, opt-in live path |
| `tests/integration/autonomous-pr-loop-e2e.sh` | Integration: full offline autonomous-flow proof against real `loop.sh`/`worktree.sh`/`harness-command.sh`/`functions.sh` seams with PATH-stubbed `gh` and a stub harness binary |
| `tests/fixtures/model-provider/openai-tool-call.json` | Sanitized OpenAI-compatible tool-call fixture (arguments as JSON string) |
| `tests/fixtures/model-provider/qwen-tool-call.json` | Sanitized Qwen3/vLLM-compatible tool-call fixture (arguments already a parsed object) |

## Live-Path Activation (opt-in, never run by default)

```bash
MAKATO_MODEL_PROVIDER_LIVE=1 \
OPENAI_API_KEY=<redacted> \
MAKATO_LIVE_QWEN_ENDPOINT_URL=http://localhost:8100/v1 \
MAKATO_LOOP_DISPATCH_REPO=<owner>/<explicit-test-repo> \
  bash tests/integration/model-provider-dispatch-e2e.sh
```

Any missing prerequisite reports Scenario H as `SKIP` (never a silent `PASS`
and never a `FAIL` that blocks the offline gate) — the same "actionable
SKIP, never silently healthy" contract `scripts/preflight-optional-services.sh`
(Task 5) uses for optional-service checks. No credential value is ever
echoed to stdout, stderr, or a fixture file; see `config/model-profiles.yml`'s
credential-redaction contract, which `resolve-model-profile.py` and
`select-model-profile.sh` also honour.

## Conclusion

Task 4's provider-neutral autonomous canary passes its full offline
acceptance surface: profile selection, provider-aware auth, tool-call
normalization across both supported tool formats, failure classification for
malformed/truncated responses, R1 validation, and the complete
issue-claim → worktree → dispatch → resume → PR → merge-state flow — all
without a live network call or credential in the default test path. The
opt-in live path (Scenario H) is documented and wired but was not exercised
in this evidence pass; re-run with the env vars above against a real OpenAI
account and a real Qwen/Ollama-compatible endpoint to extend this table with
live-path PASS rows.
