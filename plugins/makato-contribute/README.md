# makato-contribute

**Goal**: Help contributors participate in makato-suite development while keeping all content within the framework's guardrails.

**How**: Provide skills and agents (shipped as a plugin) that create new plugins, skills, agents, and hooks — all pre-validated against suite conventions.

**Why**: Active participation in the framework should be easy and encouraged, but every contribution must fit together coherently. These tools encode the guardrails so contributors don't have to memorize them.

## What Belongs Here

- Skills that create or scaffold plugins, skills, agents, or hooks
- Validation helpers for contributors
- Tools that teach or enforce makato conventions

## What Does NOT Belong Here

- End-user workflow skills (those belong in toolkits)
- Foundation/contract definitions (those belong in core)
- Anything not directly helping contributors create correct plugins

## Skills

| Skill | Description | Version |
|-------|-------------|---------|
| [makato-plugin-creator](skills/makato-plugin-creator/) | Create a complete, working plugin via interview-driven Plan→Present→Build workflow | 2.0.0 |
| [makato-skill-creator](skills/makato-skill-creator/) | Create a complete, working skill inside an existing plugin with guardrails | 1.1.1 |
| [manage-pr](skills/manage-pr/) | Triage and resolve PR review-bot comments — validate, rate, fix, and reply via gh CLI | 1.0.0 |

## Installation

```bash
claude --plugin-dir ./plugins/makato-contribute
```

## Version

0.3.0
