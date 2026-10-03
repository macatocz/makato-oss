---
name: pre-push
trigger: Stop
action: inject
version: "2.0.0"
---
## Post-Push Verify Advisory

After a git push is detected in the session, this hook warns when the verify gate has not run
since the last implementation. The notification is advisory: it does not block commits or pushes.

## Trigger

Claude Code's `Stop` event fires after every Claude turn. This hook scans `build.jsonl` for a
recently completed `build-push-to-git` session. If a push is detected and no verify pass exists
after the last implementation session, the hook injects a warning message.

## Recency Check

A verify pass is current only when it appears after the most recent `implement-tdd`,
`implement-goal`, `simplify`, or `review` session-end entry in the same file. A verify pass from
a prior implementation does not suppress the advisory.

## Settings Wiring

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

Node.js must be available on `PATH`.

## Validation Authority

This hook reports missing evidence; it does not perform validation. `build-sensors` validates the
changed files, `build-verify` runs the project gates, and GitHub Actions provides the authoritative
remote result. Projects may configure E2E execution for local or remote placement.
