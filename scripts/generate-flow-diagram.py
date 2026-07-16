"""generate-flow-diagram.py — validate + regenerate the makato-flow diagram data.

`docs/assets/makato-flow.html` renders the makato architecture diagram from a single
inline JSON blob (the `<script id="graph-data">` tag). That blob used to be hand-edited
directly in the HTML, so every skill/agent rename or addition silently drifted the
published diagram (#428).

This script splits the concern:

1. `docs/assets/makato-flow.data.json` is the version-controlled *source of truth* for
   the diagram content (lanes, nodes, edges, flows, statusText). A human still authors
   the rich per-node layout/prose fields there — see "Out of scope" below.
2. `docs/assets/makato-flow.inventory.json` is a mapping sidecar that reconciles the
   diagram's node model with the on-disk skill/agent inventory (composite nodes,
   skills rendered as a different node kind, intentionally-undrawn skills, and
   conceptual loop-step nodes with no backing directory).
3. This generator (a) splices the data file into the HTML's graph-data tag so the two
   never diverge, and (b) validates that the diagram's skill/agent inventory matches
   what actually exists under `plugins/*/skills/` and `plugins/*/agents/`.

Modes:
  * default (no flags): regenerate the HTML graph-data blob from the data file, writing
    it back in place. Idempotent — a clean tree yields a byte-identical HTML.
  * `--check`: run inventory + edge validation and a splice into a temp buffer; exit 1
    with a human-readable drift report if any drift exists OR the committed HTML blob is
    stale relative to the data file; exit 0 when clean. This is the CI gate.

Drift classes reported:
  * missing   — a skill/agent exists on disk but no diagram node covers it.
  * orphan    — a diagram skill/agent node references a name that no longer exists on
                disk (and is not declared conceptual in the sidecar).
  * stale-edge — an edge `from`/`to` or a flow `seq[]` id is absent from `nodes[].id`.
                An edge endpoint may also be a synthetic `cluster:<name>` anchor
                (a plugin bounding-box); it is valid when some node carries that
                `cluster`, else reported as stale.

Out of scope (intentional): auto-generating the rich per-node layout/prose fields
(`col`, `subrow`, `kicker`, `desc`, `inp`, `out`, `ctx`, `meta`, `cluster`, `color`)
from frontmatter. SKILL.md / agent frontmatter carries only name/description/version —
not layout — so those fields remain hand-authored in the data file. This generator
*forces a genuinely new skill/agent to be added as a node* (CI fails until it is), but a
human still places and describes that node.

Stdlib-only; no third-party dependencies.

Usage:
  python3 scripts/generate-flow-diagram.py            # regenerate HTML blob in place
  python3 scripts/generate-flow-diagram.py --check     # CI gate: exit 1 on drift/stale
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

# Repo-relative default locations. Resolved against --repo-root (default: the repo the
# script lives in, i.e. two levels up from this file: scripts/ -> repo root).
DEFAULT_HTML = Path("docs/assets/makato-flow.html")
DEFAULT_DATA = Path("docs/assets/makato-flow.data.json")
DEFAULT_INVENTORY = Path("docs/assets/makato-flow.inventory.json")

# The graph-data script tag markers. The blob is the single line between them.
OPEN_TAG = '<script id="graph-data" type="application/json">'
CLOSE_TAG = "</script>"


def repo_root_default() -> Path:
    """Return the repo root inferred from this file's location (scripts/<file>)."""
    return Path(__file__).resolve().parent.parent


def read_json(path: Path) -> dict:
    """Load a JSON file as a dict. Raises on missing/malformed (caller decides policy)."""
    return json.loads(path.read_text(encoding="utf-8"))


def _frontmatter_name(md_path: Path) -> str | None:
    """Extract the `name:` field from a Markdown file's YAML frontmatter, if present."""
    try:
        text = md_path.read_text(encoding="utf-8")
    except OSError:
        return None
    m = re.match(r"^---\s*\n(.*?)\n---", text, re.S)
    if not m:
        return None
    nm = re.search(r"^name:\s*(.+?)\s*$", m.group(1), re.M)
    if not nm:
        return None
    return nm.group(1).strip().strip('"').strip("'")


def discover_skills(repo_root: Path) -> set[str]:
    """Enumerate installed skills as `plugins/*/skills/*/SKILL.md` (name or dir name)."""
    skills: set[str] = set()
    for skill_md in repo_root.glob("plugins/*/skills/*/SKILL.md"):
        name = _frontmatter_name(skill_md) or skill_md.parent.name
        skills.add(name)
    return skills


def discover_agents(repo_root: Path) -> set[str]:
    """Enumerate installed agents as `plugins/*/agents/*.md` (name or file stem).

    RETURN-CONTRACT.md and other non-agent Markdown files without a `name:` matching an
    agent are still included by stem; the diagram sidecar's unmappedAgents can exclude
    any that should not appear. In practice every real agent carries frontmatter.
    """
    agents: set[str] = set()
    for agent_md in repo_root.glob("plugins/*/agents/*.md"):
        if agent_md.name == "RETURN-CONTRACT.md":
            continue
        name = _frontmatter_name(agent_md) or agent_md.stem
        agents.add(name)
    return agents


def node_labels_by_kind(data: dict, kind: str) -> list[str]:
    """Return the `label` of every node whose `kind` matches."""
    return [n.get("label", "") for n in data.get("nodes", []) if n.get("kind") == kind]


def covered_names(labels: list[str], node_sources: dict[str, list[str]]) -> set[str]:
    """Expand node labels into the set of disk names they cover.

    A label maps to itself by default; a label listed in `nodeSources` (a composite
    node) maps to the several disk names it covers instead.
    """
    covered: set[str] = set()
    for label in labels:
        if label in node_sources:
            covered.update(node_sources[label])
        else:
            covered.add(label)
    return covered


def detect_drift(data: dict, inventory: dict, repo_root: Path) -> list[str]:
    """Return a list of human-readable drift findings (empty when clean)."""
    findings: list[str] = []

    node_sources: dict[str, list[str]] = inventory.get("nodeSources", {})
    unmapped_skills = set(inventory.get("unmappedSkills", {}))
    unmapped_agents = set(inventory.get("unmappedAgents", {}))
    conceptual = set(inventory.get("conceptualNodes", {}))

    # --- Skills ---
    disk_skills = discover_skills(repo_root)
    skill_labels = node_labels_by_kind(data, "skill")
    covered_skills = covered_names(skill_labels, node_sources)

    for name in sorted(disk_skills - covered_skills - unmapped_skills):
        findings.append(
            f"ERROR: [missing] skill '{name}' exists on disk but no diagram node covers "
            f"it (add a node, list it under nodeSources of a composite node, or add it "
            f"to unmappedSkills in makato-flow.inventory.json)"
        )
    for name in sorted(covered_skills - disk_skills - conceptual):
        findings.append(
            f"ERROR: [orphan] skill node '{name}' has no matching skill on disk "
            f"(rename/remove the node, or declare it under conceptualNodes)"
        )

    # --- Agents ---
    disk_agents = discover_agents(repo_root)
    agent_labels = node_labels_by_kind(data, "agent")
    covered_agents = covered_names(agent_labels, node_sources)

    for name in sorted(disk_agents - covered_agents - unmapped_agents):
        findings.append(
            f"ERROR: [missing] agent '{name}' exists on disk but no diagram node covers "
            f"it (add a node or add it to unmappedAgents in makato-flow.inventory.json)"
        )
    for name in sorted(covered_agents - disk_agents - conceptual):
        findings.append(
            f"ERROR: [orphan] agent node '{name}' has no matching agent on disk "
            f"(rename/remove the node, or declare it under conceptualNodes)"
        )

    # --- Stale edges / flows ---
    node_ids = {n.get("id") for n in data.get("nodes", [])}
    # An edge endpoint may also be a synthetic "cluster:<name>" anchor: the HTML
    # renderer resolves it to the dashed plugin bounding-box built from every node
    # carrying that `cluster`. Valid cluster names are the distinct `cluster` fields
    # present on the nodes, so a typo'd "cluster:foo" is still caught.
    cluster_ids = {
        "cluster:" + n["cluster"]
        for n in data.get("nodes", [])
        if n.get("cluster")
    }
    valid_edge_ids = node_ids | cluster_ids
    for edge in data.get("edges", []):
        for end in ("from", "to"):
            ref = edge.get(end)
            if ref is not None and ref not in valid_edge_ids:
                hint = (
                    " (no node has this cluster)"
                    if isinstance(ref, str) and ref.startswith("cluster:")
                    else ""
                )
                findings.append(
                    f"ERROR: [stale-edge] edge {end}='{ref}' is not a known node id"
                    f"{hint}"
                )
    flows = data.get("flows", {})
    flow_items = flows.items() if isinstance(flows, dict) else enumerate(flows)
    for scope, flow in flow_items:
        for ref in flow.get("seq", []):
            if ref not in node_ids:
                findings.append(
                    f"ERROR: [stale-edge] flow '{scope}' seq id '{ref}' is not a known "
                    f"node id"
                )

    return findings


def splice_html(html_text: str, data: dict) -> str:
    """Return HTML with the graph-data blob replaced by the compact-serialized data.

    The replacement is the exact JS `JSON.stringify` form (no whitespace,
    ensure_ascii=False) so the round-trip is byte-identical to a hand-authored blob.
    Raises ValueError if the graph-data script tag cannot be located.
    """
    blob = json.dumps(data, separators=(",", ":"), ensure_ascii=False)
    # Match the open tag, any single-line blob, then the close tag.
    pattern = re.compile(
        re.escape(OPEN_TAG) + r"\n.*?\n" + re.escape(CLOSE_TAG),
        re.S,
    )
    replacement = f"{OPEN_TAG}\n{blob}\n{CLOSE_TAG}"
    new_text, count = pattern.subn(lambda _: replacement, html_text, count=1)
    if count != 1:
        raise ValueError("could not locate the graph-data script tag in the HTML")
    return new_text


def run(
    repo_root: Path, html_path: Path, data_path: Path, inventory_path: Path, check: bool
) -> int:
    """Execute the generator. Returns a process exit code (0 clean, 1 drift/stale)."""
    data = read_json(data_path)
    inventory = read_json(inventory_path) if inventory_path.exists() else {}
    html_text = html_path.read_text(encoding="utf-8")

    findings = detect_drift(data, inventory, repo_root)
    spliced = splice_html(html_text, data)

    if check:
        stale = spliced != html_text
        if stale:
            findings.append(
                "ERROR: [stale-html] committed makato-flow.html graph-data differs from "
                "makato-flow.data.json — run `python3 scripts/generate-flow-diagram.py` "
                "and commit the result"
            )
        if findings:
            print("makato-flow drift check: FAIL")
            for f in findings:
                print(f)
            return 1
        print("makato-flow drift check: OK")
        return 0

    # Default mode: regenerate in place. Still surface inventory drift as a warning so a
    # local run is informative, but do not fail — --check is the gate.
    if findings:
        print("WARNING: inventory drift detected (run --check for the gate):")
        for f in findings:
            print(f)
    if spliced != html_text:
        html_path.write_text(spliced, encoding="utf-8")
        print(f"regenerated {html_path} graph-data blob from {data_path}")
    else:
        print(f"{html_path} graph-data already up to date")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Validate + regenerate the makato-flow diagram graph-data blob."
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="CI gate: exit 1 on inventory drift or a stale committed HTML blob.",
    )
    parser.add_argument(
        "--repo-root",
        type=Path,
        default=repo_root_default(),
        help="Repo root to scan (default: inferred from this script's location).",
    )
    args = parser.parse_args(argv)

    repo_root: Path = args.repo_root
    html_path = repo_root / DEFAULT_HTML
    data_path = repo_root / DEFAULT_DATA
    inventory_path = repo_root / DEFAULT_INVENTORY

    return run(repo_root, html_path, data_path, inventory_path, args.check)


if __name__ == "__main__":
    sys.exit(main())
