"""Tests for the provider-neutral model profile resolver and OMP installer (AC-1, task 2).

Covers the task 2 unit_test_spec and integration_test_spec:
  - profile parsing/validation with temporary YAML fixtures
  - every canonical role present per profile
  - profile-specific tool format selected
  - OpenAI credentials required only at execution time (not at parse/dry-run time)
  - error output (and dry-run output) never contains key material
  - `scripts/select-model-profile.sh --dry-run` for each real profile produces
    OMP provider/role documents that a fixture parser can evaluate, and
    switching profiles changes only provider/model routing — not role names.
  - config/agent-roles.yml validation, and installs (a profile or
    --agents-only) that merge into existing OMP files without dropping user
    settings, refuse unmergeable files without writing anything, and put the
    credential only into models.yml.

Import strategy: importlib.util.spec_from_file_location — required for the
non-package filename ``resolve-model-profile.py`` (see test_parse_config_models.py
for the established pattern in this repo).
"""

from __future__ import annotations

import importlib.util
import json
import os
import pathlib
import re
import stat
import subprocess
import sys

import pytest  # type: ignore[reportMissingImports]

REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent
RESOLVER = REPO_ROOT / "scripts" / "resolve-model-profile.py"
SELECTOR = REPO_ROOT / "scripts" / "select-model-profile.sh"
REAL_PROFILES_FILE = REPO_ROOT / "config" / "model-profiles.yml"
REAL_AGENT_ROLES_FILE = REPO_ROOT / "config" / "agent-roles.yml"

EXPECTED_ROLES = (
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
)

REAL_PROFILE_NAMES = ("openai", "qwen-vllm", "apple-ollama")


def _load_module():
    spec = importlib.util.spec_from_file_location("resolve_model_profile", RESOLVER)
    assert spec is not None and spec.loader is not None, f"Could not create ModuleSpec for {RESOLVER}"
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)  # type: ignore[union-attr]
    return mod


def _roles_block(roles: dict) -> str:
    lines = [f"      {role}: {model}" for role, model in roles.items()]
    return "\n".join(lines)


def _all_roles(model_id: str = "open") -> dict:
    return dict.fromkeys(EXPECTED_ROLES, model_id)


def _write_fixture(tmp_path: pathlib.Path, profiles: dict, *, default_profile: str = "qwen-vllm") -> pathlib.Path:
    """Build a minimal model-profiles.yml fixture from a {name: {...}} dict."""
    chunks = [f"default_profile: {default_profile}", "profiles:"]
    for name, cfg in profiles.items():
        chunks.append(f"  {name}:")
        chunks.append(f"    provider: {cfg.get('provider', name)}")
        chunks.append(f'    base_url: "{cfg["base_url"]}"')
        chunks.append(f'    api_key_env: "{cfg.get("api_key_env", "")}"')
        chunks.append(f"    api: {cfg.get('api', 'openai-completions')}")
        chunks.append(f"    tool_format: {cfg['tool_format']}")
        chunks.append(f"    context_window: {cfg.get('context_window', 8192)}")
        chunks.append(f"    max_tokens: {cfg.get('max_tokens', 1024)}")
        chunks.append("    roles:")
        chunks.append(_roles_block(cfg["roles"]))
    text = "\n".join(chunks) + "\n"
    p = tmp_path / "model-profiles.yml"
    p.write_text(text, encoding="utf-8")
    return p


def _selector(args: list[str], omp_dir: pathlib.Path, **extra_env: str) -> subprocess.CompletedProcess[str]:
    """Run select-model-profile.sh against OMP files in omp_dir, with no ambient OPENAI_API_KEY."""
    env = {k: v for k, v in os.environ.items() if k != "OPENAI_API_KEY"}
    env.update(OMP_CONFIG_FILE=str(omp_dir / "config.yml"), OMP_MODELS_FILE=str(omp_dir / "models.yml"), MAKATO_PYTHON_BIN=sys.executable, **extra_env)
    return subprocess.run(["bash", str(SELECTOR), *args], capture_output=True, text=True, timeout=30, env=env)


def _expected_overrides(mod) -> dict:
    return {agent: f"@{role}" for agent, role in mod.load_agent_roles(str(REAL_AGENT_ROLES_FILE)).items()}


# ---------------------------------------------------------------------------
# Unit: fixture-based parsing and validation (module-level, no subprocess)
# ---------------------------------------------------------------------------


def test_valid_profile_resolves_with_every_canonical_role(tmp_path: pathlib.Path) -> None:
    mod = _load_module()
    cfg = _write_fixture(
        tmp_path,
        {
            "qwen-vllm": {
                "base_url": "http://localhost:8100/v1",
                "tool_format": "qwen3",
                "roles": _all_roles("open"),
            }
        },
    )
    doc = mod.load_profiles(str(cfg))
    profile = mod.resolve_profile(doc, "qwen-vllm")
    assert set(profile["roles"].keys()) == set(EXPECTED_ROLES)
    assert profile["tool_format"] == "qwen3"


def test_profile_specific_tool_format_selected(tmp_path: pathlib.Path) -> None:
    """Two profiles with different tool_format values each resolve their own."""
    mod = _load_module()
    cfg = _write_fixture(
        tmp_path,
        {
            "qwen-vllm": {"base_url": "http://localhost:8100/v1", "tool_format": "qwen3", "roles": _all_roles("open")},
            "openai": {
                "base_url": "https://api.openai.com/v1",
                "tool_format": "openai",
                "api_key_env": "OPENAI_API_KEY",
                "roles": _all_roles("gpt-4o"),
            },
        },
    )
    doc = mod.load_profiles(str(cfg))
    assert mod.resolve_profile(doc, "qwen-vllm")["tool_format"] == "qwen3"
    assert mod.resolve_profile(doc, "openai")["tool_format"] == "openai"


def test_unsupported_profile_raises_with_known_profiles_listed(tmp_path: pathlib.Path) -> None:
    mod = _load_module()
    cfg = _write_fixture(
        tmp_path,
        {"qwen-vllm": {"base_url": "http://localhost:8100/v1", "tool_format": "qwen3", "roles": _all_roles("open")}},
    )
    doc = mod.load_profiles(str(cfg))
    try:
        mod.resolve_profile(doc, "bogus-provider")
        raise AssertionError("expected ProfileError for unsupported profile")
    except mod.ProfileError as exc:
        assert "bogus-provider" in str(exc)
        assert "qwen-vllm" in str(exc)


def test_missing_role_is_detected(tmp_path: pathlib.Path) -> None:
    """A profile missing one canonical role must fail validation, naming the gap."""
    mod = _load_module()
    incomplete_roles = _all_roles("open")
    del incomplete_roles["vision"]
    cfg = _write_fixture(
        tmp_path,
        {"qwen-vllm": {"base_url": "http://localhost:8100/v1", "tool_format": "qwen3", "roles": incomplete_roles}},
    )
    doc = mod.load_profiles(str(cfg))
    try:
        mod.resolve_profile(doc, "qwen-vllm")
        raise AssertionError("expected ProfileError for missing role")
    except mod.ProfileError as exc:
        assert "vision" in str(exc)


def test_unsupported_tool_format_is_rejected(tmp_path: pathlib.Path) -> None:
    mod = _load_module()
    cfg = _write_fixture(
        tmp_path,
        {"weird": {"base_url": "http://localhost:9/v1", "tool_format": "xml-legacy", "roles": _all_roles("m")}},
    )
    doc = mod.load_profiles(str(cfg))
    try:
        mod.resolve_profile(doc, "weird")
        raise AssertionError("expected ProfileError for unsupported tool_format")
    except mod.ProfileError as exc:
        assert "xml-legacy" in str(exc)


def test_endpoint_normalization_strips_trailing_slash(tmp_path: pathlib.Path) -> None:
    mod = _load_module()
    cfg = _write_fixture(
        tmp_path,
        {"qwen-vllm": {"base_url": "http://localhost:8100/v1///", "tool_format": "qwen3", "roles": _all_roles("open")}},
    )
    doc = mod.load_profiles(str(cfg))
    profile = mod.resolve_profile(doc, "qwen-vllm")
    assert profile["base_url"] == "http://localhost:8100/v1"


def test_endpoint_without_scheme_is_rejected(tmp_path: pathlib.Path) -> None:
    mod = _load_module()
    cfg = _write_fixture(
        tmp_path,
        {"bad": {"base_url": "localhost:8100/v1", "tool_format": "qwen3", "roles": _all_roles("open")}},
    )
    doc = mod.load_profiles(str(cfg))
    try:
        mod.resolve_profile(doc, "bad")
        raise AssertionError("expected ProfileError for schemeless base_url")
    except mod.ProfileError as exc:
        assert "http" in str(exc)


def test_openai_credentials_not_required_at_parse_time(tmp_path: pathlib.Path, monkeypatch) -> None:
    """resolve_profile() must succeed even when OPENAI_API_KEY is unset — structural

    validation is credential-blind by design; only the execution-time installer
    (select-model-profile.sh, without --dry-run) enforces credential presence.
    """
    mod = _load_module()
    monkeypatch.delenv("OPENAI_API_KEY", raising=False)
    cfg = _write_fixture(
        tmp_path,
        {
            "openai": {
                "base_url": "https://api.openai.com/v1",
                "tool_format": "openai",
                "api_key_env": "OPENAI_API_KEY",
                "roles": _all_roles("gpt-4o"),
            }
        },
    )
    doc = mod.load_profiles(str(cfg))
    profile = mod.resolve_profile(doc, "openai")  # must not raise
    assert profile["api_key_env"] == "OPENAI_API_KEY"


def test_emit_summary_never_contains_key_material(tmp_path: pathlib.Path, monkeypatch) -> None:
    mod = _load_module()
    monkeypatch.setenv("OPENAI_API_KEY", "sk-TESTSECRETVALUE12345")
    cfg = _write_fixture(
        tmp_path,
        {
            "openai": {
                "base_url": "https://api.openai.com/v1",
                "tool_format": "openai",
                "api_key_env": "OPENAI_API_KEY",
                "roles": _all_roles("gpt-4o"),
            }
        },
    )
    doc = mod.load_profiles(str(cfg))
    profile = mod.resolve_profile(doc, "openai")
    summary = mod.emit_summary("openai", profile)
    serialized = json.dumps(summary)
    assert "sk-TESTSECRETVALUE12345" not in serialized
    assert summary["api_key_env"] == "OPENAI_API_KEY"


def test_emit_omp_models_never_contains_key_material(tmp_path: pathlib.Path, monkeypatch) -> None:
    mod = _load_module()
    monkeypatch.setenv("OPENAI_API_KEY", "sk-TESTSECRETVALUE12345")
    cfg = _write_fixture(
        tmp_path,
        {
            "openai": {
                "base_url": "https://api.openai.com/v1",
                "tool_format": "openai",
                "api_key_env": "OPENAI_API_KEY",
                "roles": _all_roles("gpt-4o"),
            }
        },
    )
    doc = mod.load_profiles(str(cfg))
    profile = mod.resolve_profile(doc, "openai")
    doc_text = mod.emit_omp_models(profile)
    assert "sk-TESTSECRETVALUE12345" not in doc_text
    assert "${OPENAI_API_KEY}" in doc_text


def test_emit_omp_models_uses_empty_sentinel_when_no_credential(tmp_path: pathlib.Path) -> None:
    mod = _load_module()
    cfg = _write_fixture(
        tmp_path,
        {"qwen-vllm": {"base_url": "http://localhost:8100/v1", "tool_format": "qwen3", "roles": _all_roles("open")}},
    )
    doc = mod.load_profiles(str(cfg))
    profile = mod.resolve_profile(doc, "qwen-vllm")
    doc_text = mod.emit_omp_models(profile)
    assert "apiKey: EMPTY" in doc_text


def test_emit_omp_config_has_every_canonical_role_key(tmp_path: pathlib.Path) -> None:
    mod = _load_module()
    cfg = _write_fixture(
        tmp_path,
        {"qwen-vllm": {"base_url": "http://localhost:8100/v1", "tool_format": "qwen3", "roles": _all_roles("open")}},
    )
    doc = mod.load_profiles(str(cfg))
    profile = mod.resolve_profile(doc, "qwen-vllm")
    doc_text = mod.emit_omp_config(profile)
    for role in EXPECTED_ROLES:
        assert f"{role}: local/open" in doc_text or f"{role}: qwen-vllm/open" in doc_text or f"{role}: " in doc_text
    assert "format: qwen3" in doc_text


def test_stdlib_fallback_matches_pyyaml(tmp_path: pathlib.Path) -> None:
    """The stdlib nested-mapping fallback parser must match yaml.safe_load."""
    mod = _load_module()
    cfg = _write_fixture(
        tmp_path,
        {
            "qwen-vllm": {"base_url": "http://localhost:8100/v1", "tool_format": "qwen3", "roles": _all_roles("open")},
            "openai": {
                "base_url": "https://api.openai.com/v1",
                "tool_format": "openai",
                "api_key_env": "OPENAI_API_KEY",
                "roles": _all_roles("gpt-4o"),
            },
        },
    )
    text = cfg.read_text(encoding="utf-8")
    stdlib_doc = mod._parse_nested_yaml(text)
    import yaml  # noqa: PLC0415

    pyyaml_doc = yaml.safe_load(text)
    assert stdlib_doc == pyyaml_doc


# ---------------------------------------------------------------------------
# CLI-contract tests (subprocess against the real resolver script)
# ---------------------------------------------------------------------------


def test_cli_unsupported_profile_exits_nonzero_and_lists_known(tmp_path: pathlib.Path) -> None:
    cfg = _write_fixture(
        tmp_path,
        {"qwen-vllm": {"base_url": "http://localhost:8100/v1", "tool_format": "qwen3", "roles": _all_roles("open")}},
    )
    result = subprocess.run(
        [sys.executable, str(RESOLVER), "bogus", "--config", str(cfg)],
        capture_output=True,
        text=True,
        timeout=10,
    )
    assert result.returncode != 0
    assert "bogus" in result.stderr
    assert "qwen-vllm" in result.stderr


def test_cli_emit_summary_is_valid_json(tmp_path: pathlib.Path) -> None:
    cfg = _write_fixture(
        tmp_path,
        {"qwen-vllm": {"base_url": "http://localhost:8100/v1", "tool_format": "qwen3", "roles": _all_roles("open")}},
    )
    result = subprocess.run(
        [sys.executable, str(RESOLVER), "qwen-vllm", "--config", str(cfg), "--emit", "summary"],
        capture_output=True,
        text=True,
        timeout=10,
        check=True,
    )
    payload = json.loads(result.stdout)
    assert payload["profile"] == "qwen-vllm"
    assert set(payload["roles"].keys()) == set(EXPECTED_ROLES)


# ---------------------------------------------------------------------------
# Integration: the real config/model-profiles.yml + select-model-profile.sh
# ---------------------------------------------------------------------------


def test_real_model_profiles_file_has_all_required_profiles() -> None:
    assert REAL_PROFILES_FILE.exists(), f"{REAL_PROFILES_FILE} must exist (task 2)"
    mod = _load_module()
    doc = mod.load_profiles(str(REAL_PROFILES_FILE))
    for name in REAL_PROFILE_NAMES:
        profile = mod.resolve_profile(doc, name)  # must not raise for any required profile
        assert set(profile["roles"].keys()) == set(EXPECTED_ROLES)


def test_select_model_profile_dry_run_requires_no_credentials(monkeypatch) -> None:
    """--dry-run must succeed for the openai profile even with no OPENAI_API_KEY set."""
    env = {k: v for k, v in os.environ.items() if k != "OPENAI_API_KEY"}
    result = subprocess.run(
        ["bash", str(SELECTOR), "openai", "--dry-run"],
        capture_output=True,
        text=True,
        timeout=15,
        env=env,
    )
    assert result.returncode == 0, result.stderr
    assert "modelRoles" in result.stdout
    assert "providers" in result.stdout


def test_select_model_profile_install_requires_credentials_when_declared(tmp_path: pathlib.Path) -> None:
    """Without --dry-run, installing the openai profile must fail loudly, writing

    nothing, when OPENAI_API_KEY is unset — credentials are required only at
    execution time, and this IS execution time.
    """
    result = _selector(["openai"], tmp_path)
    assert result.returncode != 0
    assert "OPENAI_API_KEY" in result.stderr
    assert not list(tmp_path.iterdir())


def test_select_model_profile_never_leaks_credential_value(tmp_path: pathlib.Path) -> None:
    """Dry-run output must never contain the actual secret value, even when set."""
    env = {**os.environ, "OPENAI_API_KEY": "sk-TESTSECRETVALUE12345"}
    result = subprocess.run(
        ["bash", str(SELECTOR), "openai", "--dry-run"],
        capture_output=True,
        text=True,
        timeout=15,
        env=env,
    )
    assert result.returncode == 0, result.stderr
    assert "sk-TESTSECRETVALUE12345" not in result.stdout
    assert "sk-TESTSECRETVALUE12345" not in result.stderr


def test_switching_profiles_changes_only_provider_routing_not_role_names() -> None:
    """Dry-run role-config documents across all three profiles share identical

    role-name keys (modelRoles:) — only the provider/model side of each mapping
    (and tools.format) may differ between profiles.
    """
    env = {k: v for k, v in os.environ.items() if k != "OPENAI_API_KEY"}
    env["OPENAI_API_KEY"] = "sk-TESTSECRETVALUE12345"  # present so openai profile also succeeds
    role_key_sets = {}
    tool_formats = {}
    provider_lines = {}
    for name in REAL_PROFILE_NAMES:
        result = subprocess.run(
            ["bash", str(SELECTOR), name, "--dry-run"],
            capture_output=True,
            text=True,
            timeout=15,
            env=env,
            check=True,
        )
        out = result.stdout
        role_lines = [line.strip().split(":", 1)[0].strip() for line in out.splitlines() if ":" in line and line.strip().split(":", 1)[0].strip() in EXPECTED_ROLES]
        role_key_sets[name] = set(role_lines)
        fmt_line = next((line for line in out.splitlines() if line.strip().startswith("format:")), "")
        tool_formats[name] = fmt_line.strip()
        provider_lines[name] = next((line for line in out.splitlines() if "baseUrl:" in line), "")

    # Role-name keys are identical across every profile — role names are never
    # provider-specific.
    assert role_key_sets["openai"] == role_key_sets["qwen-vllm"] == role_key_sets["apple-ollama"] == set(EXPECTED_ROLES)

    # Provider routing (base URL) differs meaningfully between profiles.
    assert provider_lines["openai"] != provider_lines["qwen-vllm"]
    assert provider_lines["apple-ollama"] != provider_lines["qwen-vllm"]

    # qwen-vllm keeps the checked-in qwen3 tool format; openai selects its own.
    assert tool_formats["qwen-vllm"] == "format: qwen3"
    assert tool_formats["openai"] == "format: openai"


# ---------------------------------------------------------------------------
# config/agent-roles.yml validation
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    ("aliases", "agents", "bad_role"),
    [
        ({"task": "inherit", "advisr": "opus"}, {"coder": "task"}, "advisr"),
        ({"task": "inherit"}, {"coder": "taks"}, "taks"),
        ({"task": "inherit"}, {"coder": "task", "diff-reviewer": "advisor"}, "advisor"),
    ],
    ids=["non-canonical-alias-role", "non-canonical-agent-role", "role-without-alias"],
)
def test_load_agent_roles_rejects_unroutable_roles(tmp_path: pathlib.Path, aliases: dict, agents: dict, bad_role: str) -> None:
    """Every role must be canonical and have a Claude alias, or one harness could not route the agent."""
    mod = _load_module()
    lines = ["claude_aliases:", *(f"  {role}: {alias}" for role, alias in aliases.items()), "agents:", *(f"  {agent}: {role}" for agent, role in agents.items())]
    roles_file = tmp_path / "agent-roles.yml"
    roles_file.write_text("\n".join(lines) + "\n", encoding="utf-8")
    try:
        mod.load_agent_roles(str(roles_file))
    except mod.ProfileError as exc:
        assert bad_role in str(exc)
    else:
        raise AssertionError(f"expected ProfileError naming role {bad_role!r}")


@pytest.mark.parametrize("config_file", [REAL_PROFILES_FILE, REAL_AGENT_ROLES_FILE], ids=lambda path: path.name)
def test_stdlib_fallback_reads_real_config_files_like_pyyaml(config_file: pathlib.Path) -> None:
    """Installs on boxes without PyYAML parse these files with the stdlib fallback, which must agree with PyYAML."""
    import yaml  # noqa: PLC0415

    text = config_file.read_text(encoding="utf-8")
    assert _load_module()._parse_nested_yaml(text) == yaml.safe_load(text)


# ---------------------------------------------------------------------------
# Integration: select-model-profile.sh merging into existing OMP files
# ---------------------------------------------------------------------------

_USER_CONFIG = """\
# hand-written settings the installer must keep
modelRoles:
  task: vendor/pinned-task
  my-custom-role: vendor/custom
  judge: vendor/judge
retry:
  fallbackChains:
    default: [vendor/fallback]
tools:
  format: openai
  keepThis: true
task:
  eager: true
  agentModelOverrides:
    coder: vendor/pinned-coder
    my-own-agent: vendor/agent
defaultThinkingLevel: max
"""


def _user_models(provider: str) -> str:
    return f"providers:\n  anthropic:\n    apiKey: USER-SECRET-SENTINEL\n  {provider}:\n    baseUrl: http://stale.example:1/v1\n    headers:\n      X-Keep: kept\n"


def test_profile_install_merges_without_dropping_user_settings(tmp_path: pathlib.Path) -> None:
    """A profile install updates only the canonical roles, tools.format, the makato agent overrides and its own provider entry."""
    import yaml  # noqa: PLC0415

    mod = _load_module()
    profile = mod.resolve_profile(mod.load_profiles(str(REAL_PROFILES_FILE)), "qwen-vllm")
    config_file, models_file = tmp_path / "config.yml", tmp_path / "models.yml"
    config_file.write_text(_USER_CONFIG, encoding="utf-8")
    config_file.chmod(0o640)
    models_file.write_text(_user_models(profile["provider"]), encoding="utf-8")

    result = _selector(["qwen-vllm"], tmp_path)
    assert result.returncode == 0, result.stderr
    assert "WARN" not in result.stderr, "every role the agents use has a model after a profile install"
    assert "USER-SECRET-SENTINEL" not in result.stdout + result.stderr

    expected = yaml.safe_load(_USER_CONFIG)
    expected["modelRoles"].update({role: f"{profile['provider']}/{model}" for role, model in profile["roles"].items()})
    expected["tools"]["format"] = profile["tool_format"]
    expected["task"]["agentModelOverrides"].update(_expected_overrides(mod))
    assert yaml.safe_load(config_file.read_text(encoding="utf-8")) == expected
    assert stat.S_IMODE(config_file.stat().st_mode) == 0o640

    fragment = yaml.safe_load(mod.emit_omp_models(profile))["providers"][profile["provider"]]
    assert yaml.safe_load(models_file.read_text(encoding="utf-8"))["providers"] == {
        "anthropic": {"apiKey": "USER-SECRET-SENTINEL"},
        profile["provider"]: {"headers": {"X-Keep": "kept"}, **fragment},
    }
    assert stat.S_IMODE(models_file.stat().st_mode) == 0o600


def test_agents_only_merges_only_agent_overrides(tmp_path: pathlib.Path) -> None:
    """--agents-only leaves modelRoles, tools and models.yml alone, and warns about roles the agents use that modelRoles lacks."""
    import yaml  # noqa: PLC0415

    mod = _load_module()
    config_file = tmp_path / "config.yml"
    config_file.write_text(_USER_CONFIG, encoding="utf-8")

    result = _selector(["--agents-only"], tmp_path)
    assert result.returncode == 0, result.stderr
    assert not (tmp_path / "models.yml").exists()

    expected = yaml.safe_load(_USER_CONFIG)
    expected["task"]["agentModelOverrides"].update(_expected_overrides(mod))
    assert yaml.safe_load(config_file.read_text(encoding="utf-8")) == expected

    warned = re.search(r"no modelRoles entry for (.+?);", result.stderr)
    used_roles = set(mod.load_agent_roles(str(REAL_AGENT_ROLES_FILE)).values())
    assert warned is not None, result.stderr
    assert set(warned.group(1).split(", ")) == used_roles - {"task"}


def test_dry_run_neither_reads_nor_writes_omp_files(tmp_path: pathlib.Path) -> None:
    """--dry-run prints only the fragments it would merge — never an existing file's content — and changes nothing."""
    import yaml  # noqa: PLC0415

    originals = {name: f"secret: {name.upper()}-SENTINEL\n" for name in ("config.yml", "models.yml")}
    for name, text in originals.items():
        (tmp_path / name).write_text(text, encoding="utf-8")

    profile_run = _selector(["openai", "--dry-run"], tmp_path)
    agents_run = _selector(["--agents-only", "--dry-run"], tmp_path)
    for result in (profile_run, agents_run):
        assert result.returncode == 0, result.stderr
        assert "SENTINEL" not in result.stdout + result.stderr
    assert yaml.safe_load(agents_run.stdout) == {"task": {"agentModelOverrides": _expected_overrides(_load_module())}}
    assert {path.name: path.read_text(encoding="utf-8") for path in tmp_path.iterdir()} == originals


@pytest.mark.parametrize(
    ("config_text", "models_text", "message"),
    [
        ("modelRoles:\n  - not-a-mapping\n", None, "'modelRoles' is not a mapping"),
        ("task:\n  agentModelOverrides: pinned\n", None, "'task.agentModelOverrides' is not a mapping"),
        ("- a\n- list\n", None, "'(root)' is not a mapping"),
        ("modelRoles: {}\n", "providers: stale\n", "'providers' is not a mapping"),
        ("modelRoles:\n  task: a/b\napiKey: SECRET-SENTINEL: [x\n", None, "as YAML (line 3, column"),
    ],
    ids=["list-roles", "scalar-overrides", "list-root", "scalar-providers-in-models", "parse-error"],
)
def test_install_refuses_unmergeable_files_and_writes_nothing(tmp_path: pathlib.Path, config_text: str, models_text: str | None, message: str) -> None:
    """Both files are validated before either is written; errors never quote file content."""
    files = {"config.yml": config_text} if models_text is None else {"config.yml": config_text, "models.yml": models_text}
    for name, text in files.items():
        (tmp_path / name).write_text(text, encoding="utf-8")

    result = _selector(["qwen-vllm"], tmp_path)
    assert result.returncode == 1
    assert message in result.stderr
    assert "SENTINEL" not in result.stderr
    assert {path.name: path.read_text(encoding="utf-8") for path in tmp_path.iterdir()} == files


def test_install_writes_credential_only_into_models_file(tmp_path: pathlib.Path) -> None:
    """The credential lands in models.yml (mode 600) — fresh or merged — and never in output or config.yml."""
    import yaml  # noqa: PLC0415

    fake_api_key = 'sk-TEST:"quoted" #not-a-comment'
    for existing_models in (None, _user_models("openai")):
        omp_dir = tmp_path / ("fresh" if existing_models is None else "merged")
        omp_dir.mkdir()
        if existing_models is not None:
            (omp_dir / "models.yml").write_text(existing_models, encoding="utf-8")

        result = _selector(["openai"], omp_dir, OPENAI_API_KEY=fake_api_key)
        assert result.returncode == 0, result.stderr
        assert "sk-TEST" not in result.stdout + result.stderr
        assert "sk-TEST" not in (omp_dir / "config.yml").read_text(encoding="utf-8")
        assert yaml.safe_load((omp_dir / "models.yml").read_text(encoding="utf-8"))["providers"]["openai"]["apiKey"] == fake_api_key
        assert stat.S_IMODE((omp_dir / "models.yml").stat().st_mode) == 0o600


def test_install_without_pyyaml_writes_fresh_files_but_refuses_to_merge(tmp_path: pathlib.Path) -> None:
    """Without PyYAML, fresh OMP files are still written; merging into an existing one is refused untouched."""
    import yaml  # noqa: PLC0415

    mod = _load_module()
    blocker = tmp_path / "hide-pyyaml"
    blocker.mkdir()
    (blocker / "yaml.py").write_text('raise ImportError("PyYAML hidden for this test")\n', encoding="utf-8")
    no_pyyaml = {"PYTHONPATH": os.pathsep.join(filter(None, [str(blocker), os.environ.get("PYTHONPATH")]))}

    fresh = tmp_path / "fresh"
    result = _selector(["qwen-vllm"], fresh, **no_pyyaml)
    assert result.returncode == 0, result.stderr
    config = yaml.safe_load((fresh / "config.yml").read_text(encoding="utf-8"))
    assert set(config["modelRoles"]) == set(EXPECTED_ROLES)
    assert config["task"]["agentModelOverrides"] == _expected_overrides(mod)
    assert yaml.safe_load((fresh / "models.yml").read_text(encoding="utf-8"))["providers"]

    existing = tmp_path / "existing"
    existing.mkdir()
    (existing / "config.yml").write_text(_USER_CONFIG, encoding="utf-8")
    result = _selector(["--agents-only"], existing, **no_pyyaml)
    assert result.returncode == 1
    assert "PyYAML is required" in result.stderr
    assert (existing / "config.yml").read_text(encoding="utf-8") == _USER_CONFIG
