"""Audit tests confirming harness-independence model-role migration (issue #5).

Test cases:
  (a) Zero closed-model references — no frontmatter `model: <provider-value>` line
      exists in any plugins/*/agents/*.md file.
  (b) All 10 model roles present in config.yml models: section with non-empty base_url.
  (c) parse-config.py emits MAKATO_MODEL_DEFAULT_BASE_URL when run against config.yml.
  (d) Zero closed-model references in plugins/*/skills/*/SKILL.md frontmatter (task 2 —
      the Claude-only `model: opus|sonnet|haiku` field is replaced by `modelRole: <role>`).
  (e) infra/omp-config.yml declares every one of the 10 canonical roles under
      modelRoles: (task 2 — provider profile role routing completeness).

These are post-implementation audit tests: Tasks 1-3 (and, for (d)/(e), task 2)
completed the migration; these tests document and lock the achieved state.
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

# Provider-specific model values that must NOT appear in agent frontmatter.
_CLOSED_MODEL_RE = re.compile(
    r"^model:\s*(haiku|sonnet|opus|claude-)",
    re.IGNORECASE,
)

# All 10 canonical model roles for the harness-independence story.
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
}


# ---------------------------------------------------------------------------
# (a) Zero closed-model references in agent frontmatter
# ---------------------------------------------------------------------------


def _closed_model_violations(md_files: list[pathlib.Path]) -> list[str]:
    """Return `path:lineno: line` entries for closed-model frontmatter lines."""
    violations: list[str] = []
    for md_file in sorted(md_files):
        text = md_file.read_text(encoding="utf-8")
        # Inspect only the YAML frontmatter block (between opening --- and closing ---).
        in_frontmatter = False
        for lineno, line in enumerate(text.splitlines(), start=1):
            stripped = line.strip()
            if lineno == 1 and stripped == "---":
                in_frontmatter = True
                continue
            if in_frontmatter and stripped == "---":
                break  # End of frontmatter
            if in_frontmatter and _CLOSED_MODEL_RE.match(stripped):
                violations.append(f"{md_file.relative_to(REPO_ROOT)}:{lineno}: {stripped!r}")
    return violations


def test_no_closed_model_in_agent_frontmatter() -> None:
    """No plugins/*/agents/*.md file may carry a `model: <provider>` frontmatter line.

    Acceptable frontmatter uses `modelRole: <role>` instead.  A match against
    haiku, sonnet, opus, or the `claude-` prefix indicates a closed-model
    reference that must have been replaced in Task 3.
    """
    agent_files = list(REPO_ROOT.glob(AGENTS_GLOB))
    assert agent_files, f"No agent files found under {AGENTS_GLOB!r} — check REPO_ROOT"

    violations = _closed_model_violations(agent_files)
    assert not violations, "Closed-model references found in agent frontmatter — replace with modelRole: <role>:\n" + "\n".join(violations)


# ---------------------------------------------------------------------------
# (d) Zero closed-model references in skill frontmatter (task 2)
# ---------------------------------------------------------------------------


def test_no_closed_model_in_skill_frontmatter() -> None:
    """No plugins/*/skills/*/SKILL.md file may carry a `model: <provider>` line.

    Task 2 replaces the Claude-only `model: opus|sonnet` frontmatter field with
    the canonical `modelRole: <role>` field across every SKILL.md the plan
    targets. This audit generalizes (a) to the skills tree so the migration is
    locked repo-wide, not just for agents.
    """
    skill_files = list(REPO_ROOT.glob(SKILLS_GLOB))
    assert skill_files, f"No skill files found under {SKILLS_GLOB!r} — check REPO_ROOT"

    violations = _closed_model_violations(skill_files)
    assert not violations, "Closed-model references found in skill frontmatter — replace with modelRole: <role>:\n" + "\n".join(violations)


# ---------------------------------------------------------------------------
# (b) All 10 roles present in config.yml with non-empty base_url
# ---------------------------------------------------------------------------


def test_config_yml_has_all_ten_roles() -> None:
    """plugins/makato-orchestrate/config/config.yml must declare all 10 model roles.

    Each role must appear under the top-level `models:` key and carry a
    non-empty `base_url` value.  Task 1 added this section; this test locks it.
    """
    assert CONFIG_YML.exists(), f"config.yml not found at {CONFIG_YML}"

    data: object | None = None
    try:
        import yaml  # noqa: PLC0415

        data = yaml.safe_load(CONFIG_YML.read_text(encoding="utf-8"))
    except ImportError:
        pytest.skip("PyYAML not installed — cannot parse config.yml models block")

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


def test_omp_config_yml_has_all_ten_roles() -> None:
    """infra/omp-config.yml modelRoles: must map every one of the 10 canonical roles.

    Task 2 extends the checked-in OMP role-routing document (installed verbatim
    onto remote Linux/vLLM boxes by infra/bootstrap-vllm.sh) beyond the legacy
    default/opus/sonnet/haiku/smol/slow/plan subset to cover every canonical
    Makato role, while retaining the legacy aliases for existing consumers.
    """
    assert OMP_CONFIG_YML.exists(), f"{OMP_CONFIG_YML} not found"

    data: object | None = None
    try:
        import yaml  # noqa: PLC0415

        data = yaml.safe_load(OMP_CONFIG_YML.read_text(encoding="utf-8"))
    except ImportError:
        pytest.skip("PyYAML not installed — cannot parse infra/omp-config.yml")

    assert isinstance(data, dict), "infra/omp-config.yml must parse as a YAML mapping"
    model_roles = data.get("modelRoles")
    assert isinstance(model_roles, dict), "infra/omp-config.yml must have a top-level `modelRoles:` mapping"

    missing_roles = sorted(role for role in EXPECTED_ROLES if not model_roles.get(role))
    assert not missing_roles, f"infra/omp-config.yml modelRoles: is missing (or empty for) roles: {missing_roles}"

    # Legacy aliases must still be present — switching to canonical roles must
    # not break existing consumers that read opus/sonnet/haiku directly.
    for legacy_role in ("opus", "sonnet", "haiku"):
        assert model_roles.get(legacy_role), f"infra/omp-config.yml must retain legacy role '{legacy_role}' for existing consumers"
