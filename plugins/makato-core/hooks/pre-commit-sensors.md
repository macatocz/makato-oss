---
name: pre-commit-sensors
trigger: PreToolUse
matcher: Bash(git commit*)
action: block-on-nonzero
description: Runs pre-commit fast lane on staged files before any git commit; blocks the tool call on non-zero exit so sensor-fixer can dispatch.
---

# pre-commit-sensors

## 1. Purpose

This hook is the **fast lane** gate of the sensor harness. It runs synchronously in front of every `git commit` tool call issued by the agent, executing the consumer repo's `pre-commit` configuration over the staged file set. Typical wall-clock budget is **under 5 seconds** — it is intentionally restricted to cheap, deterministic checks: linters, formatters, style normalizers, secret-regex scanners, and filesystem hygiene rules (trailing whitespace, end-of-file newlines, merge-conflict markers, large-file guards). Anything heavier — type checks, unit tests, integration suites — belongs in the slow lane (post-commit / pre-push) and **must not** be wired into this hook. When any fast-lane check fails, the harness blocks the underlying `git commit` so the agent never produces a commit object that violates baseline hygiene.

## 2. settings.json snippet

Copy the following entry into the consumer repo's `.claude/settings.json` under `hooks.PreToolUse`:

```json
{
  "matcher": "Bash(git commit*)",
  "hooks": [{ "type": "command", "command": "pre-commit run --hook-stage pre-commit --from-ref HEAD --to-ref HEAD --files $(git diff --cached --name-only | tr '\\n' ' ')", "blocking": true, "timeout": 30000 }]
}
```

The 30 s `timeout` is a hard ceiling — if your fast lane regularly approaches it, move checks into the slow lane.

## 3. Failure semantics

- **Exit 0** — hook passes silently; `git commit` proceeds.
- **Exit != 0** — the harness **blocks** `git commit`. The working tree is left as `pre-commit` left it (auto-fixers may have rewritten staged files in place). The hook's stdout/stderr surfaces to the agent.

## 4. Configurable env: emergency bypass

`SENSOR_HARNESS_DISABLE=1` short-circuits the hook to **allow** unconditionally. The bypass is silent — no audit log is emitted; the hook exits 0 without running sensors. Do not set this variable globally in shell profiles.
