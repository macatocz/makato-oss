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

## Action

The hook command:
1. Scans `specs/*/build.jsonl` for the most recently modified file.
2. Reads all entries in order.
3. Finds the last `skill: build-push-to-git, step: session, status: ok` entry (push detected).
4. If no push entry is found: exits 0 silently — no push happened in this session.
5. If a push is found: checks whether a valid verify entry exists after the last implementation/review session-end.
6. If yes: exits 0 silently — push was preceded by verify, all good.
7. If no: prints a warning to stdout.

> "Push detected for `<story>` without a verify pass after the last implementation session. Consider running /verify and pushing again if gates have not been checked."

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

## How It Works

The `Stop` hook fires at the end of every Claude turn. The hook command is pure file I/O — fast and side-effect-free. It exits silently in the common case (no push, or push preceded by verify). When it injects a warning:

- Claude Code feeds the message back as context for the next turn
- Claude surfaces it to the user and can suggest running `/build-verify`

This is advisory — the push has already happened. The hook's value is surfacing the gap so the user can decide to re-verify and re-push, not to prevent it retroactively.

> **Note:** The `Stop` hook stdout injection behavior (stdout printed by the hook being re-injected as Claude context) is an observed behavior, not a documented contract. If the warning does not appear automatically, check the hook output in `.claude/` logs.

**Prerequisites:** Node.js must be available on `PATH` in the shell Claude Code runs in. If Node.js is missing, the hook exits silently and the verify warning will not fire.

**Silent-exit cases** (hook produces no output, all normal):
- `specs/` directory does not exist
- No `build.jsonl` files found under `specs/`
- No `build-push-to-git` session-end entry found in the most recent log
- Push detected and verify pass is present after the last implementation session
- JSON parse error on any log line (malformed JSONL — treated as absent)

## Scope

Fires after every Claude turn. Exits silently unless a `push-to-git` session-end ok entry exists in the most recently modified `build.jsonl` and that push was not preceded by a valid verify pass.
