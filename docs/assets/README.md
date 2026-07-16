# docs/assets — architecture diagram

## `makato-flow.html` — the makato architecture flow diagram

An interactive, self-contained HTML diagram of the makato suite: lanes (plugins),
nodes (skills / agents / data / hooks / GHA workflows), edges, and animated flows.
Open it directly in a browser — no server needed.

### Source-of-truth split (#428)

The diagram content is **not** hand-edited inside the HTML anymore. It is split across
three files, kept in sync by a generator:

| File | Role |
|------|------|
| `makato-flow.data.json` | **Source of truth** for diagram content — `lanes`, `nodes`, `edges`, `flows`, `statusText`. Human-authored, pretty-printed, diffable. |
| `makato-flow.inventory.json` | Mapping sidecar reconciling the diagram's node model with the on-disk skill/agent inventory (composite nodes, skills drawn as a non-skill node kind, intentionally-undrawn skills, and conceptual loop-step nodes). |
| `makato-flow.html` | The rendering shell (CSS/JS). Its `<script id="graph-data">` blob is **generated** — spliced in from `makato-flow.data.json` by the generator. |

### `scripts/generate-flow-diagram.py`

```bash
# Regenerate the HTML graph-data blob from the data file (run after editing data.json):
python3 scripts/generate-flow-diagram.py

# CI gate — exit 1 on drift or a stale committed HTML blob:
python3 scripts/generate-flow-diagram.py --check
```

The generator does two things:

1. **Splice.** Serializes `makato-flow.data.json` to the compact JSON form the page
   expects and writes it into the HTML's graph-data tag. Idempotent — a clean tree
   yields a byte-identical HTML.
2. **Validate inventory.** Enumerates skills (`plugins/*/skills/*/SKILL.md`) and agents
   (`plugins/*/agents/*.md`) as ground truth and cross-checks them against the diagram's
   skill/agent nodes, reporting three drift classes:
   - **missing** — a skill/agent on disk with no diagram node covering it.
   - **orphan** — a diagram skill/agent node whose name no longer exists on disk (and is
     not declared conceptual in the sidecar).
   - **stale-edge** — an edge `from`/`to` or a flow `seq[]` id absent from `nodes[].id`.

`.github/workflows/validate.yml` runs `--check` (plus the generator's unit tests) on any
change to the diagram files or to `plugins/*/skills|agents`, so a skill/agent
rename/add/remove now **fails CI** until the diagram is updated — closing the drift gap
that previously required manual catch-up commits.

### Out of scope (intentional)

The generator does **not** auto-generate the rich per-node layout/prose fields
(`col`, `subrow`, `kicker`, `desc`, `inp`, `out`, `ctx`, `meta`, `cluster`, `color`).
SKILL.md and agent frontmatter carry only `name` / `description` / `version` — not
layout — so those fields stay hand-authored in `makato-flow.data.json`. When CI flags a
new skill/agent as *missing*, a human adds the node (placement + prose) to the data file
and, if it is composite/undrawn/conceptual, records that in the inventory sidecar.

To add or rename a skill/agent node:

1. Edit `makato-flow.data.json` (add/rename the node, its edges, and its `statusText`).
2. If the node is composite, intentionally undrawn, or conceptual, update
   `makato-flow.inventory.json` accordingly.
3. Run `python3 scripts/generate-flow-diagram.py` to re-splice the HTML.
4. Commit all changed files together; `--check` must pass.
