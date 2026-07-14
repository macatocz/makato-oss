# Dimension Deep-Dive Reference

## D1: Knowledge Delta

**Red flags** (instant score ≤5):

- "What is [basic concept]" sections
- Step-by-step tutorials for standard operations
- Explaining how to use common libraries
- Generic best practices ("write clean code", "handle errors")
- Definitions of industry-standard terms

**Green flags** (high knowledge delta):

- Decision trees for non-obvious choices ("when X fails, try Y because Z")
- Trade-offs only an expert would know ("A is faster but B handles edge case C")
- Edge cases from real-world experience
- "NEVER do X because [non-obvious reason]"
- Domain-specific thinking frameworks

**Cross-skill duplication**: If a skill contains step-by-step mechanics for an external system (API
commands, auth flows, host detection), check whether another skill in the installation already owns
that domain. Duplicated mechanics are not expert knowledge — they are a copy of another skill's
knowledge, and they drift when the owning skill updates. Score as [R] Redundant.

**Evaluation questions**:

1. For each section, ask: "Does Claude already know this?"
2. "Is this explaining TO Claude or FOR Claude?"
3. "Does another skill already own these mechanics?"
4. Count paragraphs: Expert vs Activation vs Redundant

---

## D2: Mindset + Appropriate Procedures

**Key distinction**:

| Type                       | Example                                               | Value                           |
| -------------------------- | ----------------------------------------------------- | ------------------------------- |
| Thinking patterns          | "Before designing, ask: What makes this memorable?"   | High — shapes decision-making   |
| Domain-specific procedures | "OOXML workflow: unpack → edit XML → validate → pack" | High — Claude may not know this |
| Generic procedures         | "Step 1: Open file, Step 2: Edit, Step 3: Save"       | Low — Claude already knows      |

**Valuable procedures** — non-obvious ordering, critical steps, proprietary workflows.

**Redundant procedures** — generic file ops, standard programming patterns, well-documented
libraries, or mechanics that another skill already owns (see Pattern 12: The Copy-Paste
Integration).

**Expert thinking patterns look like**:

```markdown
Before [action], ask yourself:

- **Purpose**: What problem does this solve? Who uses it?
- **Constraints**: What are the hidden requirements?
- **Differentiation**: What makes this solution memorable?
```

**The test**:

1. Does it tell Claude WHAT to think about? (thinking patterns)
2. Does it tell Claude HOW to do things it wouldn't know? (domain procedures)

**Preference persistence**: When a skill collects user input, check whether the answer's lifetime
matches its storage:

| Scope   | Lifetime              | Storage                                        | Example                             |
| ------- | --------------------- | ---------------------------------------------- | ----------------------------------- |
| Session | Dies with the process | Conversation context                           | "Which file to analyze?"            |
| Project | Same within a repo    | `~/.claude/projects/<repo>/memory/`            | "Quick or Full scan for this repo?" |
| User    | Same everywhere       | `~/.config/claude-skills/<name>/settings.json` | "Preferred output format"           |

If a skill re-asks a question whose answer rarely changes, it should persist the answer at the
appropriate scope. If the "right" answer is the same for every user, the skill's defaults are wrong
— update the skill itself, don't add a settings file.

---

## D3: Anti-Pattern Quality

Half of expert knowledge is knowing what NOT to do. Claude hasn't stepped on the landmines — it
doesn't know Inter is overused or purple gradients are the signature of AI-generated content.

**Expert anti-patterns** (specific + reason):

```markdown
NEVER use generic AI-generated aesthetics:

- Overused fonts (Inter, Roboto, Arial)
- Cliched colors (purple gradients on white)
- Default border-radius on everything
```

**Weak anti-patterns** (no value):

```markdown
Avoid mistakes. Be careful with edge cases. Don't write bad code.
```

**The test**: Would an expert say "yes, I learned this the hard way"? Or "this is obvious to
everyone"?

---

## D4: Specification Compliance

**Frontmatter requirements**:

- `name`: lowercase, alphanumeric + hyphens only, ≤64 characters
- `description`: answers WHAT, WHEN, and contains KEYWORDS

**Description activation flow**:

```text
User Request → Agent sees ALL descriptions → Decides which to activate
               (only descriptions, not bodies!)

If description doesn't match → Skill NEVER gets loaded
If description is vague → Skill might not trigger when it should
```

**Description must answer THREE questions**:

1. **WHAT**: What does this Skill do?
2. **WHEN**: In what situations should it be used?
3. **KEYWORDS**: What terms should trigger this Skill?

**Good description**:

```yaml
description: "Create, edit, and analyze .docx files. Use when working with
Word documents, tracked changes, or professional document formatting.
Triggers on: .docx, tracked changes, redline, document review."
```

**Description quality checklist**:

- [ ] Lists specific capabilities (not just "helps with X")
- [ ] Includes explicit trigger scenarios ("Use when...", "When user asks for...")
- [ ] Contains searchable keywords (file extensions, domain terms, action verbs)
- [ ] Includes scenarios where this skill MUST be used

---

## D5: Progressive Disclosure

**Three-layer model**:

```text
Layer 1: Metadata (always in memory) — name + description only (~100 tokens)
Layer 2: SKILL.md Body — decision trees, guidelines (ideal: <500 lines)
Layer 3: references/ — heavy content, loaded on demand (no limit)
```

**Loading trigger quality**:

| Quality   | Characteristics                               |
| --------- | --------------------------------------------- |
| Poor      | References listed at end, no loading guidance |
| Mediocre  | Some triggers but not embedded in workflow    |
| Good      | MANDATORY triggers in workflow steps          |
| Excellent | Conditional triggers + "Do NOT Load" guidance |

**Good loading trigger** (embedded):

```markdown
**MANDATORY - READ ENTIRE FILE**: Load `references/docx-js.md` before proceeding. **Do NOT load**
`references/ooxml.md` for this task.
```

**Bad loading trigger** (just listed):

```markdown
## References

- docx-js.md - for creating documents
```

---

## D6: Freedom Calibration

**The freedom spectrum**:

| Task Type              | Freedom | Why                                                 |
| ---------------------- | ------- | --------------------------------------------------- |
| Creative/Design        | High    | Multiple valid approaches, differentiation is value |
| Code review            | Medium  | Principles exist but judgment required              |
| File format operations | Low     | One wrong byte corrupts file                        |

**The test**: Ask "if Agent makes a mistake, what's the consequence?"

- High consequence → Low freedom (exact scripts)
- Low consequence → High freedom (principles)

---

## D7: Pattern Recognition

**5 official patterns**:

| Pattern    | ~Lines | Use When                               |
| ---------- | ------ | -------------------------------------- |
| Mindset    | ~50    | Creative tasks requiring taste         |
| Navigation | ~30    | Multiple distinct scenarios            |
| Philosophy | ~150   | Art/creation requiring originality     |
| Process    | ~200   | Complex multi-step projects            |
| Tool       | ~300   | Precise operations on specific formats |

---

## D8: Practical Usability

**Check for**:

- Decision trees for multi-path scenarios
- Working code examples (not pseudocode that breaks)
- Fallbacks when the main approach fails
- Edge cases coverage
- Can Agent immediately act, or needs to figure things out?
- **Persistent state stability**: if the skill writes to a file path derived at runtime, would two
  sessions in different directories of the same repo resolve to the same path? (`pwd` breaks in
  worktrees; `git rev-parse --show-toplevel` is stable)

**Good usability** (decision tree + fallback):

```markdown
| Task           | Primary Tool | Fallback  | When to Use Fallback |
| -------------- | ------------ | --------- | -------------------- |
| Read text      | pdftotext    | PyMuPDF   | Need layout info     |
| Extract tables | camelot-py   | tabula-py | camelot fails        |

Common issues:

- Scanned PDF: pdftotext returns blank → Use OCR first
- Encrypted PDF: Permission error → Use PyMuPDF with password
```
