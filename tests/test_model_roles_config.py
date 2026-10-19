"""Audit tests locking the model-role routing contract.

Every makato subagent is routed through one shared role in config/agent-roles.yml,
so OMP and Claude Code pick the same tier for it.

Test cases:
  (a) Every plugins/*/agents/*.md agent is listed in config/agent-roles.yml, and its
      frontmatter carries exactly one `model:` equal to its role's Claude Code alias
      (claude_aliases), `name:` equal to its file stem, and no `modelRole:` — no
      harness reads that key.
  (b) plugins/makato-orchestrate/config/config.yml declares every canonical role
      under models: with a non-empty base_url.
  (c) parse-config.py emits MAKATO_MODEL_DEFAULT_BASE_URL when run against config.yml.
  (d) No plugins/*/skills/*/SKILL.md frontmatter sets `model:` or `modelRole:`.
  (e) infra/omp-config.yml modelRoles: maps every canonical role and keeps the
      legacy opus/sonnet/haiku aliases.
  (f) infra/omp-config.yml task.agentModelOverrides routes every agent in
      config/agent-roles.yml to "@<role>" — the same role Claude Code uses.
"""

from __future__ import annotations

import pathlib
import re
import subprocess
import sys

import pytest  # type: ignore[reportMissingImports]

REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent
AGENTS_GLOB = "plugins/*/agents/*.md"
SKILLS_GLOB = "plugins/*/skills/*/SKILL.md"
CONFIG_YML = REPO_ROOT / "plugins" / "makato-orchestrate" / "config" / "config.yml"
PARSE_CONFIG = REPO_ROOT / "plugins" / "makato-orchestrate" / "config" / "parse-config.py"
OMP_CONFIG_YML = REPO_ROOT / "infra" / "omp-config.yml"
AGENT_ROLES_YML = REPO_ROOT / "config" / "agent-roles.yml"

# Markdown in agents/ directories that documents agents instead of defining one.
NON_AGENT_FILES = {"RETURN-CONTRACT.md"}

# The canonical Makato model roles (scripts/resolve-model-profile.py EXPECTED_ROLES).
EXPECTED_ROLES = {
    "default",
    "task",
    "smol",
    "tiny",
    "plan",
    "advisor",
    "designer",
    "commit",
    "slow",
    "vision",
    "orchestrator",
}

_FRONTMATTER_KEY_RE = re.compile(r"^([A-Za-z][\w-]*):\s*(.*?)\s*$")


def _load_yaml(path: pathlib.Path) -> object:
    try:
        import yaml  # noqa: PLC0415
    except ImportError:
        pytest.skip(f"PyYAML not installed — cannot parse {path.relative_to(REPO_ROOT)}")
    return yaml.safe_load(path.read_text(encoding="utf-8"))


def _agent_roles() -> tuple[dict, dict]:
    """Return (claude_aliases, agents) from config/agent-roles.yml."""
    data = _load_yaml(AGENT_ROLES_YML)
    aliases = data.get("claude_aliases") if isinstance(data, dict) else None
    agents = data.get("agents") if isinstance(data, dict) else None
    assert isinstance(aliases, dict) and isinstance(agents, dict), "config/agent-roles.yml must define `claude_aliases` and `agents` mappings"
    return aliases, agents


def _frontmatter_keys(md_file: pathlib.Path) -> list[tuple[str, str]]:
    """Return the top-level `key: value` pairs of a file's YAML frontmatter, in order.

    Line-based on purpose: a YAML parser silently keeps only the last of two
    duplicated keys, and a duplicated `model:` is exactly what (a) must catch.
    """
    lines = md_file.read_text(encoding="utf-8").splitlines()
    if not lines or lines[0].strip() != "---":
        return []
    pairs: list[tuple[str, str]] = []
    for line in lines[1:]:
        if line.strip() == "---":
            return pairs
        match = _FRONTMATTER_KEY_RE.match(line)
        if match:
            pairs.append((match.group(1), match.group(2).strip("\"'")))
    return []


# ---------------------------------------------------------------------------
# (a) Agent frontmatter routes through config/agent-roles.yml
# ---------------------------------------------------------------------------


def test_agent_frontmatter_model_matches_agent_roles() -> None:
    """Each agent's frontmatter `model:` must be the Claude alias of its role in config/agent-roles.yml.

    Claude Code routes a subagent by this alias; OMP routes it by the "@<role>"
    override generated from the same file. Both harnesses key the agent by its
    frontmatter `name:`, so it must match the file stem the roles file lists.
    """
    aliases, agents = _agent_roles()
    agent_files: dict[str, list[pathlib.Path]] = {}
    for path in REPO_ROOT.glob(AGENTS_GLOB):
        if path.name not in NON_AGENT_FILES:
            agent_files.setdefault(path.stem, []).append(path)
    assert agent_files, f"No agent files found under {AGENTS_GLOB!r} — check REPO_ROOT"

    errors = [f"config/agent-roles.yml: role {role!r} is not canonical" for role in sorted(set(agents.values()) - EXPECTED_ROLES)]
    for stem, paths in sorted(agent_files.items()):
        if len(paths) > 1:
            errors.append(f"agent name {stem!r} is defined more than once: {sorted(str(p.relative_to(REPO_ROOT)) for p in paths)}")
        for path in paths:
            rel = path.relative_to(REPO_ROOT)
            keys = _frontmatter_keys(path)
            names = [value for key, value in keys if key == "name"]
            models = [value for key, value in keys if key == "model"]
            if names != [stem]:
                errors.append(f"{rel}: frontmatter name {names} must be exactly [{stem!r}]")
            if any(key == "modelRole" for key, _ in keys):
                errors.append(f"{rel}: remove `modelRole:` — no harness reads it; the role lives in config/agent-roles.yml")
            if stem not in agents:
                errors.append(f"{rel}: agent {stem!r} is not listed in config/agent-roles.yml")
            elif models != [aliases.get(agents[stem])]:
                errors.append(f"{rel}: frontmatter model {models} must be exactly [{aliases.get(agents[stem])!r}], the Claude alias of role {agents[stem]!r}")
    errors.extend(f"config/agent-roles.yml lists {agent!r}, but no {AGENTS_GLOB} file defines it" for agent in sorted(set(agents) - set(agent_files)))
    assert not errors, "Agent model routing is out of sync with config/agent-roles.yml:\n" + "\n".join(errors)


# ---------------------------------------------------------------------------
# (d) Skills never pick their own model
# ---------------------------------------------------------------------------


def test_skill_frontmatter_sets_no_model() -> None:
    """No plugins/*/skills/*/SKILL.md frontmatter may set `model:` or `modelRole:`.

    A skill runs inside the session that loads it. A per-skill model would
    switch models mid-session and discard the prompt cache that session built.
    """
    skill_files = sorted(REPO_ROOT.glob(SKILLS_GLOB))
    assert skill_files, f"No skill files found under {SKILLS_GLOB!r} — check REPO_ROOT"

    violations = [f"{path.relative_to(REPO_ROOT)}: {key}: {value}" for path in skill_files for key, value in _frontmatter_keys(path) if key in ("model", "modelRole")]
    assert not violations, "Skills must not pick their own model — remove these frontmatter keys:\n" + "\n".join(violations)


# ---------------------------------------------------------------------------
# (b) Every canonical role present in config.yml with non-empty base_url
# ---------------------------------------------------------------------------


def test_config_yml_declares_every_canonical_role() -> None:
    """plugins/makato-orchestrate/config/config.yml must declare every canonical model role.

    Each role must appear under the top-level `models:` key and carry a
    non-empty `base_url` value.  Task 1 added this section; this test locks it.
    """
    assert CONFIG_YML.exists(), f"config.yml not found at {CONFIG_YML}"

    data = _load_yaml(CONFIG_YML)
    assert isinstance(data, dict), "config.yml must parse as a YAML mapping"
    models = data.get("models")
    assert isinstance(models, dict), f"config.yml must have a top-level `models:` mapping — found: {type(models).__name__}"

    missing_roles: list[str] = []
    empty_url_roles: list[str] = []
    for role in sorted(EXPECTED_ROLES):
        if role not in models:
            missing_roles.append(role)
            continue
        cfg = models[role]
        base_url = (cfg or {}).get("base_url", "") if isinstance(cfg, dict) else ""
        if not base_url:
            empty_url_roles.append(role)

    errors: list[str] = []
    if missing_roles:
        errors.append(f"Missing roles: {missing_roles}")
    if empty_url_roles:
        errors.append(f"Roles with empty base_url: {empty_url_roles}")
    assert not errors, "config.yml models section is incomplete:\n" + "\n".join(errors)


# ---------------------------------------------------------------------------
# (c) parse-config.py emits MAKATO_MODEL_DEFAULT_BASE_URL
# ---------------------------------------------------------------------------


def test_parse_config_emits_default_base_url_var() -> None:
    """Invoking parse-config.py against config.yml must emit MAKATO_MODEL_DEFAULT_BASE_URL.

    Task 2 extended parse-config.py to handle the models: dict schema and emit
    MAKATO_MODEL_<ROLE>_BASE_URL assignments.  The DEFAULT role is the canonical
    sentinel — its presence confirms the emission logic is wired up correctly.
    """
    assert PARSE_CONFIG.exists(), f"parse-config.py not found at {PARSE_CONFIG}"
    assert CONFIG_YML.exists(), f"config.yml not found at {CONFIG_YML}"

    result = subprocess.run(
        [sys.executable, str(PARSE_CONFIG), str(CONFIG_YML)],
        capture_output=True,
        text=True,
        timeout=10,
    )
    assert result.returncode == 0, f"parse-config.py exited {result.returncode}; stderr: {result.stderr!r}"
    assert "MAKATO_MODEL_DEFAULT_BASE_URL" in result.stdout, f"Expected MAKATO_MODEL_DEFAULT_BASE_URL in parse-config.py output.\nActual stdout:\n{result.stdout}"


# ---------------------------------------------------------------------------
# (e) infra/omp-config.yml declares every canonical role (task 2)
# ---------------------------------------------------------------------------


def test_omp_config_yml_maps_every_canonical_role() -> None:
    """infra/omp-config.yml modelRoles: must map every canonical role.

    Task 2 extends the checked-in OMP role-routing document (installed verbatim
    on fresh remote Linux/vLLM boxes by infra/bootstrap-vllm.sh; re-runs merge
    the qwen-vllm profile via scripts/select-model-profile.sh) beyond the legacy
    default/opus/sonnet/haiku/smol/slow/plan subset to cover every canonical
    Makato role, while retaining the legacy aliases for existing consumers.
    """
    assert OMP_CONFIG_YML.exists(), f"{OMP_CONFIG_YML} not found"

    data = _load_yaml(OMP_CONFIG_YML)
    assert isinstance(data, dict), "infra/omp-config.yml must parse as a YAML mapping"
    model_roles = data.get("modelRoles")
    assert isinstance(model_roles, dict), "infra/omp-config.yml must have a top-level `modelRoles:` mapping"

    missing_roles = sorted(role for role in EXPECTED_ROLES if not model_roles.get(role))
    assert not missing_roles, f"infra/omp-config.yml modelRoles: is missing (or empty for) roles: {missing_roles}"

    # Legacy aliases must still be present — switching to canonical roles must
    # not break existing consumers that read opus/sonnet/haiku directly.
    for legacy_role in ("opus", "sonnet", "haiku"):
        assert model_roles.get(legacy_role), f"infra/omp-config.yml must retain legacy role '{legacy_role}' for existing consumers"


# ---------------------------------------------------------------------------
# (f) infra/omp-config.yml routes every agent through its shared role
# ---------------------------------------------------------------------------


def test_omp_config_yml_agent_overrides_mirror_agent_roles() -> None:
    """infra/omp-config.yml task.agentModelOverrides must equal {agent: "@<role>"} from config/agent-roles.yml.

    infra/bootstrap-vllm.sh installs this file verbatim on a fresh remote box
    (a re-run merges via the installer instead), so it must carry the same
    agent → role routing the installer writes.
    """
    _, agents = _agent_roles()
    data = _load_yaml(OMP_CONFIG_YML)
    task = data.get("task") if isinstance(data, dict) else None
    overrides = task.get("agentModelOverrides") if isinstance(task, dict) else None
    assert overrides == {agent: f"@{role}" for agent, role in agents.items()}, 'infra/omp-config.yml task.agentModelOverrides must mirror config/agent-roles.yml agents as "@<role>" values'
