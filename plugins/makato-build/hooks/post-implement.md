---
name: post-implement
trigger: Stop
action: inject
version: "1.1.1"
---

# Post-Implement Hook

> **Mission**: After a successful build-implement-tdd or build-implement-goal session, automatically continue to `/build-simplify` without waiting for the user.

## Trigger

Claude Code's `Stop` event fires after Claude finishes a turn. This hook checks whether that turn ended with a completed implement session by reading the most recent `build.jsonl`. If it did, the hook injects a message that causes Claude to continue with `/simplify` automatically — no user action required.

## Action

The hook command:
1. Scans `specs/*/build.jsonl` for the most recently modified file.
2. Reads the last line of that file.
3. If the last entry has `"skill":"build-implement-tdd"` or `"skill":"build-implement-goal"`, `"step":"session"`, `"status":"ok"` — prints a message to stdout.
4. Claude reads the message and invokes `/build-simplify <key>` automatically.

If the last session entry is not an implement completion, the hook exits 0 silently — the pipeline continues normally.

## Settings.json Wiring

Add the following to `.claude/settings.json` in the target project:

```json
{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "node -e \"const fs=require('fs');const specDir='specs';if(!fs.existsSync(specDir))process.exit(0);const files=fs.readdirSync(specDir).map(d=>({d,f:specDir+'/'+d+'/build.jsonl'})).filter(x=>fs.existsSync(x.f)).sort((a,b)=>fs.statSync(b.f).mtimeMs-fs.statSync(a.f).mtimeMs);if(!files.length)process.exit(0);const{d,f}=files[0];const lines=fs.readFileSync(f,'utf8').trim().split('\\n').filter(Boolean);let last;try{last=JSON.parse(lines[lines.length-1])}catch{process.exit(0)}if(last&&['build-implement-tdd','build-implement-goal'].includes(last.skill)&&last.step==='session'&&last.status==='ok')console.log('implement session for '+d+' completed successfully. Continue the build pipeline by running /build-simplify '+d+' now.').\"
          }
        ]
      }
    ]
  }
}
```

## How It Works

The `Stop` hook fires at the end of every Claude turn. The hook command is fast (pure file I/O, no bash) and exits silently unless an implement session just completed. When it does fire:

- The hook prints a message to stdout
- Claude Code feeds that message back as context for the next turn
- Claude reads it and invokes `/build-simplify <key>` — the pipeline continues without user input

> **Note:** The stdout injection behavior (stdout printed by a `Stop` hook being re-injected as Claude context) is an observed behavior, not a documented contract. If `/build-simplify` does not trigger automatically after an implement session, run `/build-simplify <key>` manually — the pipeline will continue normally from that point.

**Prerequisites:** Node.js must be available on `PATH` in the shell Claude Code runs in. If Node.js is missing, the hook exits silently and auto-continuation will not fire — run `/build-simplify <key>` manually.

**Silent-exit cases** (hook produces no output):
- `specs/` directory does not exist
- No `build.jsonl` files found under `specs/`
- Most recent `build.jsonl` ends with a non-implement session entry
- JSON parse error on the last log line (malformed JSONL)

## Scope

Fires only when the most recently modified `build.jsonl` ends with an implement session-end ok entry. Does not fire on sessions that end with `status: error` or that escalate to `/build-refine` — those require user attention.
