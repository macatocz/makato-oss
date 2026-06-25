<!-- markdownlint-disable MD013 -->
# Field-type routing — per-type write call reference (v2.4.0+)

This file documents how each supported GitHub Projects v2 field type maps to a `gh project item-edit` flag, how the source signal is resolved for each type, and how iteration IDs are fetched at runtime. Referenced by `sync-process.md` (field-write loop) and `init-wizard.md` (field discovery).

## Supported types and write flags

| Type string | `gh project item-edit` flag | Value shape | Source signal |
|---|---|---|---|
| `"single-select"` | `--single-select-option-id <option-id>` | String — opaque GitHub option ID from `fields.<key>.options.<value>` | Label prefix matching `fields.<key>.signal_prefix` (default: field key, e.g. `priority:`) |
| `"iteration"` | `--iteration-id <iteration-id>` | String — live iteration ID (not cached in config; resolved at run start) | `iter:<title>` label; fallback: current active iteration when `current_only: true` |
| `"number"` | `--number <N>` | Integer or float | `points:N` label (canonical); `size:S/M/L/XL` label (deprecated fallback, see `SIZE_MAP`) |
| `"date"` | `--date <YYYY-MM-DD>` | ISO-8601 date string | Milestone `due_on` |

## `SIZE_MAP` constant

```python
SIZE_MAP = {"S": 1, "M": 3, "L": 8, "XL": 13}
```

`SIZE_MAP` maps t-shirt size labels to story point integers. It is the default mapping used when a `size:*` label is present and no `points:N` label overrides it. The spec deprecates `size:*` in favor of `points:N` (D5), so a deprecation log line is emitted when `SIZE_MAP` is consulted.

Operators with non-standard size-to-point mappings can override this by adding a `size_map` sub-key to the `estimate` field entry in config:

```json
"estimate": {
  "id": "PVTNF_…",
  "name": "Estimate",
  "type": "number",
  "size_map": { "XS": 1, "S": 2, "M": 5, "L": 8, "XL": 13 }
}
```

When `size_map` is present in config, it replaces `SIZE_MAP` entirely for that run.

## Signal resolution per field type

### single-select

Source signal: the label whose prefix is `signal_prefix` (defaults to the field key in lowercase, e.g. `priority`).

```python
def resolve_single_select_signal(field_key: str, field_cfg: dict, labels: list[str]) -> str | None:
    """Return the option value label fragment (e.g. 'p1') or None if no matching label."""
    prefix = field_cfg.get("signal_prefix", field_key) + ":"
    matching = [l.split(":", 1)[1] for l in labels if l.startswith(prefix)]
    if len(matching) > 1:
        # Multi-label soft-warn handled in extract_signals (sync-process.md Step 2.5)
        pass
    return matching[0] if matching else None
```

Option ID resolution: after resolving the label fragment, look up the corresponding option ID:

```python
def resolve_single_select_option_id(field_cfg: dict, signal_value: str) -> tuple[str | None, str | None]:
    """Return (option_id, error). error is None on success."""
    options = field_cfg.get("options", {})
    # Exact match first; then case-insensitive
    if signal_value in options:
        return options[signal_value], None
    lower_signal = signal_value.lower()
    for key, opt_id in options.items():
        if key.lower() == lower_signal:
            return opt_id, None
    known = list(options.keys())
    return None, (
        f"signal value '{signal_value}' not found in options {known}. "
        f"Check config or re-run '--init' to refresh option IDs."
    )
```

Full `item-edit` invocation for single-select:

```bash
GH_HOST=github.com timeout ${ITP_GH_TIMEOUT_SECONDS:-30} \
  gh project item-edit \
    --id "$PROJECT_ITEM_ID" \
    --project-id "$PROJECT_NODE_ID" \
    --field-id "$FIELD_ID" \
    --single-select-option-id "$OPTION_ID"
```

### iteration

Source signal: `iter:<title>` label, with a fallback to the current active iteration.

```python
def resolve_iteration_signal(field_cfg: dict, labels: list[str]) -> str | None:
    """Return the iteration title from an iter:* label, or None for fallback-to-current."""
    iter_labels = [l.split(":", 1)[1] for l in labels if l.startswith("iter:")]
    return iter_labels[0] if iter_labels else None
```

Iteration ID resolution requires a live `gh project field-list` call (or a cached field-with-options payload from `--init`) to map title → ID. Fetch once per run and cache in memory:

```python
def build_iteration_map(project_number: int, owner: str, field_id: str) -> dict[str, str]:
    """Build a title → iteration-id map for the given iteration field.

    Returns dict mapping lowercase(title) → iteration_id.
    Makes one gh API call; result is cached for the batch.
    """
    import subprocess, json
    raw = subprocess.run(
        f"GH_HOST=github.com timeout {os.environ.get('ITP_GH_TIMEOUT_SECONDS', '30')} "
        f"gh project field-list {project_number} --owner {owner} --format json",
        shell=True, capture_output=True, text=True
    )
    if raw.returncode != 0:
        return {}  # Soft failure — iteration writes will produce no_signal
    payload = json.loads(raw.stdout)
    for f in payload.get("fields", []):
        if f["id"] == field_id:
            options = f.get("options", {})  # gh may use "configuration.iterations"
            # Handle both flat options[] and configuration.iterations[]
            iterations = (
                f.get("configuration", {}).get("completedIterations", []) +
                f.get("configuration", {}).get("iterations", []) +
                f.get("options", [])
            )
            return {it["title"].lower(): it["id"] for it in iterations if "title" in it and "id" in it}
    return {}
```

Resolution logic:

```python
def resolve_iteration_id(
    field_cfg: dict,
    signal_title: str | None,
    iteration_map: dict[str, str],
    current_iteration_id: str | None,
) -> tuple[str | None, str | None]:
    """Return (iteration_id, error).

    - If signal_title is set, look it up (case-insensitive substring match).
    - If no signal_title and current_only is True, return current_iteration_id.
    - If no signal_title and current_only is False, return (None, None) — no_signal.
    """
    if signal_title:
        lower = signal_title.lower()
        # Exact match
        if lower in iteration_map:
            return iteration_map[lower], None
        # Substring match
        for title_key, iter_id in iteration_map.items():
            if lower in title_key or title_key in lower:
                return iter_id, None
        return None, f"iteration title '{signal_title}' not found in project. Available: {list(iteration_map.keys())}"

    if field_cfg.get("current_only", True) and current_iteration_id:
        return current_iteration_id, None

    return None, None  # no_signal — write will be skipped
```

Full `item-edit` invocation for iteration:

```bash
GH_HOST=github.com timeout ${ITP_GH_TIMEOUT_SECONDS:-30} \
  gh project item-edit \
    --id "$PROJECT_ITEM_ID" \
    --project-id "$PROJECT_NODE_ID" \
    --field-id "$FIELD_ID" \
    --iteration-id "$ITERATION_ID"
```

**Current-iteration discovery:** to identify the "active" iteration (for `current_only: true` fallback), look for the iteration in `iterations[]` whose `startDate` ≤ today ≤ `startDate + duration_days`. If no iteration is active, log:

```
[issue-to-project] WARN: iteration field has no active iteration — skipping
```

and record `outcome: "no_signal"`. Continue without aborting.

### number

Source signal: `points:N` label (canonical). Fallback: `size:S/M/L/XL` label mapped via `SIZE_MAP` (or per-field `size_map` override in config).

Signal extraction is handled in `sync-process.md` Step 2.5 (`extract_signals`). By the time `resolve_field_write` is called, `signal_value` is already an integer or `None`.

Full `item-edit` invocation for number:

```bash
GH_HOST=github.com timeout ${ITP_GH_TIMEOUT_SECONDS:-30} \
  gh project item-edit \
    --id "$PROJECT_ITEM_ID" \
    --project-id "$PROJECT_NODE_ID" \
    --field-id "$FIELD_ID" \
    --number "$ESTIMATE_VALUE"
```

`$ESTIMATE_VALUE` must be a plain integer (no quotes that would be interpreted as string by `gh`). Use `str(int(signal_value))` to serialize.

### date

Source signal: milestone `due_on` from the issue entry in `created-issues.json`.

`due_on` is an ISO-8601 datetime string from the GitHub API (e.g. `"2026-09-30T07:00:00Z"`). Truncate to `YYYY-MM-DD` before passing to `--date`:

```python
def resolve_date_signal(raw_due_on: str | None) -> str | None:
    """Return YYYY-MM-DD or None."""
    if not raw_due_on:
        return None
    return raw_due_on[:10]  # safe — GitHub always emits YYYY-MM-DDTHH:MM:SSZ
```

Full `item-edit` invocation for date:

```bash
GH_HOST=github.com timeout ${ITP_GH_TIMEOUT_SECONDS:-30} \
  gh project item-edit \
    --id "$PROJECT_ITEM_ID" \
    --project-id "$PROJECT_NODE_ID" \
    --field-id "$FIELD_ID" \
    --date "$DATE_VALUE"
```

## `resolve_field_write` dispatch function

The field-write loop in `sync-process.md` calls this function to get the right `gh` flag and value for any configured field:

```python
def resolve_field_write(
    field_key: str,
    field_cfg: dict,
    signal_value,
    gp: dict,
    iteration_map: dict | None = None,
    current_iteration_id: str | None = None,
) -> tuple[str | None, str | None, str | None]:
    """Return (write_flag, write_value_str, error).

    write_flag is the --single-select-option-id / --iteration-id / --number / --date flag name.
    write_value_str is the string to pass after the flag.
    error is None on success, a string description on failure (signals no_signal or write_failed).
    """
    field_type = field_cfg["type"]

    if field_type == "single-select":
        option_id, err = resolve_single_select_option_id(field_cfg, str(signal_value))
        if err:
            return None, None, err
        return "--single-select-option-id", option_id, None

    if field_type == "iteration":
        iteration_id, err = resolve_iteration_id(
            field_cfg, signal_value, iteration_map or {}, current_iteration_id
        )
        if err:
            return None, None, err
        if iteration_id is None:
            return None, None, None  # no_signal
        return "--iteration-id", iteration_id, None

    if field_type == "number":
        try:
            return "--number", str(int(signal_value)), None
        except (TypeError, ValueError) as e:
            return None, None, f"estimate value '{signal_value}' is not a valid integer: {e}"

    if field_type == "date":
        date_str = resolve_date_signal(signal_value)
        if not date_str:
            return None, None, None  # no_signal
        return "--date", date_str, None

    # Unknown type — should have been caught at config validation
    return None, None, f"unsupported field type '{field_type}'"
```

## Per-type log line format

Successful write:

```
[issue-to-project] issue #<N>: <FieldName> → <value> (set)
```

Examples:

```
[issue-to-project] issue #47: Priority → p1 (set)
[issue-to-project] issue #47: Estimate → 3 (set)
[issue-to-project] issue #47: Iteration → no_signal (skipped)
[issue-to-project] issue #47: Target Date → 2026-09-30 (set)
```

Failed write:

```
[issue-to-project] WARN: issue #<N> field '<FieldName>': write failed: <gh error text>
```

No-signal (field skipped because no source label):

```
[issue-to-project] issue #<N>: <FieldName> → no_signal (skipped)
```

## Error modes summary

| Error mode | Detected when | Severity | Action |
|---|---|---|---|
| Config references a field `type` not in the write matrix (e.g. `"text"`) | Step 1 config validation | **Abort** | Exit 1, HALT `FIELD_TYPE_UNSUPPORTED` |
| Cached field `id` missing from live project (snapshot returns no such field) | Step 3 snapshot enrichment | **Abort** | Exit 1, HALT `FIELD_NOT_FOUND` |
| `item-edit` for a non-Status field fails | Step 4 field-write loop, per-field | **Soft-warn** | Log WARN, record `outcome: "write_failed"`, continue to next field |
| Iteration field has no active iteration on the project | Step 4 per-issue | **Soft-warn** | Log WARN, record `outcome: "no_signal"`, continue |
| `points:N` value is not a valid integer | Step 2.5 signal extraction | **Soft-warn** | Log WARN, `signals["estimate"] = None`, continue |
| Multiple `priority:*` labels on one issue | Step 2.5 | **Soft-warn** | Log WARN "first occurrence wins", continue |
| `size:*` label present (deprecated) | Step 2.5 | **Soft-warn** | Log WARN "use points:N instead", still apply `SIZE_MAP` as fallback |
| Single-select option not found in config `options` dict | `resolve_single_select_option_id` | **Soft-warn** | Return error string; record `outcome: "no_signal"` in field outcome |

## Backward compatibility

- All v1.0.0–v2.3.0 behavior is unchanged. The field-write loop is additive: it runs only when `gp.get("fields")` is present and `fields_config` has keys beyond `status`.
- v1 consumers with flat `status_field_id` / `options.*` config get zero field-write behavior; the `fields[]` array in result rows is `[]` (empty).
- v2.4 artifacts with `fields[]` are backward-incompatible with schema versions `"1"`, `"1.1"`, `"1.2"`, `"2"`, `"2.1"`, `"2.2"`, `"2.3"` — those schemas did not declare the `fields` property on result rows. Downstream consumers must accept `schema_version: "2.4"` and treat `fields[]` as optional/additive.
- The v1 `final_status` key is kept on every result row in v2.4 as an alias for `fields[name="Status"].current_value`. It will be removed in v2.5. Downstream scripts reading `final_status` directly should migrate to `fields[]` before the v2.5 upgrade.
