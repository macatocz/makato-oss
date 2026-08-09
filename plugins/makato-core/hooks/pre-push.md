---
name: pre-push
trigger: Stop
action: inject
version: "1.1.1"
---
# Pre-Push Hook

> **Mission**: After a git push is detected in the session, warn if the verify gate has not been run since the last implementation. Advisory — does not block the push but surfaces the gap so the user can act.

## Trigger

Claude Code's `Stop` event fires after every Claude turn. This hook checks whether a `build-push-to-git` session or a raw `git push` was recently completed by scanning `build.jsonl`. If a push is detected and no verify pass exists after the last implementation session, the hook injects a warning message.

## Recency Check

A verify pass is considered valid only if it appears **after** the most recent `implement-tdd`, `implement-goal`, `simplify`, or `review` session-end entry in the same file. A verify pass from a prior session does not satisfy this gate.

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
            "command": "node -e \"const fs=require('fs');const specDir='specs';if(!fs.existsSync(specDir))process.exit(0);const files=fs.readdirSync(specDir).map(d=>({d,f:specDir+'/'+d+'/build.jsonl'})).filter(x=>fs.existsSync(x.f)).sort((a,b)=>fs.statSync(b.f).mtimeMs-fs.statSync(a.f).mtimeMs);if(!files.length)process.exit(0);const{d,f}=files[0];const raw=fs.readFileSync(f,'utf8').trim().split('\\n').filter(Boolean);const lines=raw.map(l=>{try{return JSON.parse(l)}catch{return null}}).filter(Boolean);const implSkills=['build-implement-tdd','build-implement-goal','build-simplify','build-review'];let lastPushIdx=-1,lastVerifyIdx=-1,lastImplIdx=-1;lines.forEach((l,i)=>{if(l.skill==='build-push-to-git'&&l.step==='session'&&l.status==='ok')lastPushIdx=i;if(l.skill==='build-verify'&&l.step==='session'&&l.status==='ok')lastVerifyIdx=i;if(implSkills.includes(l.skill)&&l.step==='session'&&l.status==='ok')lastImplIdx=i;});if(lastPushIdx<0)process.exit(0);if(lastImplIdx>=0&&lastVerifyIdx>=0&&lastVerifyIdx>lastImplIdx)process.exit(0);console.log('Push detected for '+d+' without a verify pass after the last implementation session. Consider running /verify and pushing again if gates have not been checked.');\""
          }
        ]
      }
    ]
  }
}
```

## Pre-Push Blocking Gate (PreToolUse)

Blocks `git push` at the tool-call boundary unless the project's `pre-commit` pre-push hook stage passes.

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash(git push*)",
        "hooks": [
          {
            "type": "command",
            "command": "pre-commit run --hook-stage pre-push --all-files",
            "blocking": true,
            "timeout": 120000
          }
        ]
      }
    ]
  }
}
```

Add to `permissions.deny` to prevent bypass:

```json
{
  "permissions": {
    "deny": ["Bash(git push --no-verify *)"]
  }
}
```

**Prerequisites:** Node.js and `pre-commit` must be available on `PATH`.

## Bypass Prevention

Add the following entry to the consumer repo's `.claude/settings.json` (or the user-level `~/.claude/settings.json`) to block `--no-verify` at the permission layer before the hook ever runs:

```json
{
  "permissions": {
    "deny": ["Bash(git push --no-verify *)"]
  }
}
```

This prevents agents from issuing `git push --no-verify` regardless of hook configuration. Adding this entry is the **consumer repo's responsibility** at setup time — the makato-core hook documentation describes what to add, but does not write the file automatically.
