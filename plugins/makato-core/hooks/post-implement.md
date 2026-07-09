---
name: post-implement
trigger: Stop
action: inject
version: "1.1.1"
---

# Post-Implement Hook

> **Mission**: After a successful build-implement-tdd or build-implement-goal session, automatically continue to `/build-simplify` without waiting for the user.

## Trigger

Claude Code's `Stop` event fires after Claude finishes a turn. This hook checks whether that turn ended with a completed implement session by reading the most recent `build.jsonl`. If it did, the hook injects a message that causes Claude to continue with `/simplify` automatically.

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
            "command": "node -e \"const fs=require('fs');const specDir='specs';if(!fs.existsSync(specDir))process.exit(0);const files=fs.readdirSync(specDir).map(d=>({d,f:specDir+'/'+d+'/build.jsonl'})).filter(x=>fs.existsSync(x.f)).sort((a,b)=>fs.statSync(b.f).mtimeMs-fs.statSync(a.f).mtimeMs);if(!files.length)process.exit(0);const{d,f}=files[0];const lines=fs.readFileSync(f,'utf8').trim().split('\\n').filter(Boolean);let last;try{last=JSON.parse(lines[lines.length-1])}catch{process.exit(0)}if(last&&['build-implement-tdd','build-implement-goal'].includes(last.skill)&&last.step==='session'&&last.status==='ok')console.log('implement session for '+d+' completed successfully. Continue the build pipeline by running /build-simplify '+d+' now.');\""
          }
        ]
      }
    ]
  }
}
```

## How It Works

The `Stop` hook fires at the end of every Claude turn. The hook command is fast (pure file I/O) and exits silently unless an implement session just completed. When it fires, Claude reads the injected message and invokes `/build-simplify <key>` automatically.

**Prerequisites:** Node.js must be available on `PATH`.

**Silent-exit cases** (hook produces no output):
- `specs/` directory does not exist
- No `build.jsonl` files found under `specs/`
- Most recent `build.jsonl` ends with a non-implement session entry
- JSON parse error on the last log line
