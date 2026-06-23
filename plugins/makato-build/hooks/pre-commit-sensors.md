---
name: pre-commit-sensors
trigger: PreToolUse
matcher: Bash(git commit*)
action: block-on-nonzero
description: Runs pre-commit fast lane on staged files before any git commit; blocks the tool call on non-zero exit so sensor-fixer can dispatch.
---

# pre-commit-sensors

## 1. Purpose

This hook is the **fast lane** gate of the sensor harness. It runs synchronously in front of every `git commit` tool call issued by the agent, executing the consumer repo's `pre-commit` configuration over the staged file set. Typical wall-clock budget is **under 5 seconds** — it is intentionally restricted to cheap, deterministic checks: linters, formatters, style normalizers, secret-regex scanners, and filesystem hygiene rules (trailing whitespace, end-of-file newlines, merge-conflict markers, large-file guards). Anything heavier — type checks, unit tests, integration suites — belongs in the slow lane (post-commit / pre-push) and **must not** be wired into this hook. When any fast-lane check fails, the harness blocks the underlying `git commit` so the agent never produces a commit object that violates baseline hygiene; the failure is then handed off to `sensor-fixer` for repair on the next agent turn.

## 2. settings.json snippet

Copy the following entry into the consumer repo's `.claude/settings.json` under `hooks.PreToolUse`:

```json
{
  "matcher": "Bash(git commit*)",
  "hooks": [{ "type": "command", "command": "pre-commit run --hook-stage pre-commit --from-ref HEAD --to-ref HEAD --files $(git diff --cached --name-only | tr '\n' ' ')", "blocking": true, "timeout": 30000 }]
}
```

Note: `pre-commit` will exit `0` when nothing is staged, so this hook is a no-op for tool calls that don't actually stage changes (e.g. `git commit --amend --no-edit` against an empty index, or accidental dispatches). The 30 s `timeout` is a hard ceiling — well above the 5 s typical budget — and exists only to abort runaway hooks; if your fast lane regularly approaches it, move checks into the slow lane.

## 3. Failure semantics

- **Exit 0** — hook passes silently; the harness allows the `git commit` tool call to proceed unchanged.
- **Exit != 0** — the harness **blocks** the `git commit` tool call. The commit object is never created, the working tree is left exactly as `pre-commit` left it (auto-fixers may have rewritten staged files in place, in which case the new contents sit unstaged), and the hook's stdout/stderr are surfaced to the agent as the tool result.
- The agent is expected to react by re-dispatching `/makato-build:build-sensors staged` on its **next turn**. That command runs `sensor-fixer`, which re-stages auto-fixed files, addresses any remaining failures, and re-attempts the commit. The agent must not retry `git commit` directly without going through the fixer — doing so will simply re-trip the same hook.

## 4. Configurable env: emergency bypass

`SENSOR_HARNESS_DISABLE=1` short-circuits the hook to **allow** unconditionally. This is an escape hatch for genuine emergencies (e.g. tooling outage, broken `pre-commit` cache, hotfix window where the slow lane will catch the gap). Every bypass is appended to the harness JSONL audit log with `reason: "manual-bypass"`, the invoking agent id, the tool call id, the staged file list, and the timestamp, so suppressed events remain reviewable after the fact. Do not set this variable globally in shell profiles; export it inline for a single command, and unset it immediately after.
