# Self-Containment Rules

## Core Principle

A skill directory must be understandable and functional when viewed in isolation. A contributor should be able to read the skill directory and understand everything about it without navigating elsewhere.

## Rules

### 1. No Escaping Paths

Never use parent-directory references (`..` + `/`) to access files outside the skill directory.

**One exception**: the plugin's own `shared/` directory (accessed via parent-path + `shared/`) is allowed for large resources shared across multiple skills.

### 2. Local References

All reference files must live inside the skill's `references/` subdirectory. Do not reference:
- Files from other skills
- Files from other plugins
- Framework directories
- Repository-level docs

### 3. Local Templates

All output templates must live inside the skill's `templates/` subdirectory. Template content is never shared across skills.

### 4. No External Imports

Do not reference:
- Other plugins' directories
- Root-level documentation
- External URLs for critical content (informational links are fine)

## When Two Skills Need the Same Reference

Options (in order of preference):
1. Each skill gets its own copy of the reference (preferred)
2. Place in the plugin-level `shared/` directory (for large resources only)

Duplication is preferred over hidden dependencies.

## Validation

The `check-self-contained.sh` script scans for `../` patterns in skill files. Any path escaping the skill directory is rejected. To share files across skills inside a plugin, create a symlink at the skill root (e.g., `skills/<name>/shared` → `../../shared`); skill files then reference `shared/<file>` without any `../`. Symlinks resolving within the plugin's own directory are preserved by Claude Code's plugin cache.

```bash
./scripts/check-self-contained.sh plugins/<plugin>/skills/<skill>
```
