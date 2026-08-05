# Branch 1 — Autofix: Standard Substitution Patterns

Load this reference **only when executing Branch 1 for the following rules**:
B101 (production assert), B506 (simple yaml), B405–B410 (XXE), B311 (security random).
Do NOT load for crypto patterns — use `branch1-crypto-patterns.md` for those.

## B101 — assert → raise (production code)

```python
# Before
assert user_id is not None, "user_id required"

# After
if user_id is None:
    raise ValueError("user_id required")
```

## B506 — yaml.load (simple pattern)

Simple pattern: `yaml.load(f)` with no Loader, or `Loader=yaml.Loader` / `Loader=yaml.FullLoader`
in a single top-level call.

```python
# Before
import yaml
data = yaml.load(f)                   # or yaml.load(stream, Loader=yaml.Loader)

# After
import yaml
data = yaml.safe_load(f)
```

If `yaml.load` is inside a class, uses a custom Loader subclass, or is nested inside
conditional logic — escalate to Branch 4 (carry-over). `yaml.safe_load` may reject
constructs the custom Loader was intended to handle.

## B405–B410 — XXE: xml library imports

All these rules share the same fix pattern: swap the stdlib xml library for the
`defusedxml` equivalent.

```python
# Before — B405
import xml.etree.ElementTree as ET
tree = ET.parse(source)

# After
import defusedxml.ElementTree as ET
tree = ET.parse(source)
# Add to project dependencies: defusedxml
```

Apply the same import-swap for:
- B406: `xml.sax` → `defusedxml.sax`
- B408: `xml.dom.minidom` → `defusedxml.minidom`
- B409: `xml.dom.pulldom` → `defusedxml.pulldom`

For B407 (`xml.dom.expatbuilder`): swap to `defusedxml` generic parse API.

For B410 (lxml) — non-obvious: `defusedxml` does NOT wrap lxml.
Add a parser argument instead:

```python
# Before
from lxml import etree
tree = etree.parse(source)

# After
from lxml import etree
parser = etree.XMLParser(resolve_entities=False)
tree = etree.parse(source, parser)
```

Note: `resolve_entities=False` is the correct lxml flag. The `defusedxml` import-swap
pattern does NOT work here.
