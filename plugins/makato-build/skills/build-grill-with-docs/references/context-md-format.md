# Glossary Enrichment Format

Rules for how `/grill-with-docs` annotates and extends `glossary.md` in the resolved spec folder (the feature vocabulary file written by `/daff-shape:grill`).

## Entry Shape

Existing entries from `/daff-shape:grill` follow this shape (do not rewrite them):

```markdown
**<Canonical term>**:
<One-sentence definition — what it IS, not what it does.>
_Avoid_: <comma-separated rejected synonyms or spec shorthand>
```

`/grill-with-docs` adds a `_Code_:` line **only when the codebase name differs** from the canonical term:

```markdown
**<Canonical term>**:
<One-sentence definition.>
_Avoid_: <rejected synonyms>
_Code_: `<CodebaseSymbol>` — <one-line note on the discrepancy>
```

Omit `_Code_:` when the codebase uses the canonical term exactly — adding it with "matches" is noise.

## Adding New Terms

For terms not yet in `glossary.md`, append a full entry under `## Language`:

```markdown
**<Canonical term>**:
<One-sentence definition.>
_Avoid_: <rejected synonyms>
_Code_: `<CodebaseSymbol>` — <note if name differs>
```

## Relationships

Bounded cardinality between terms, when stated:

```markdown
- A **<Term A>** contains one or more **<Term B>**
- A **<Term B>** belongs to exactly one **<Term C>**
```

## Glossary Purity Rules

- One sentence per definition. Define what it IS, not what it does or how it is implemented.
- One canonical term per concept. All rejected synonyms go in `_Avoid_`.
- No file paths, class names, method names, or package references in definitions. The `_Code_:` line is the only place for code-level symbols.
- No implementation details (caching strategy, HTTP verb, DB column type, etc.).
- Only domain-meaningful terms. Skip: generic programming nouns (service, handler, controller, util), infrastructure terms (queue, cache, timeout), terms already universally understood.

## Do Not Overwrite Existing Definitions

Replace an existing definition only if the codebase probe reveals it is factually wrong. If you change a definition, note the reason in `decisions.md`. The audit trail lives there, not in `glossary.md`.
