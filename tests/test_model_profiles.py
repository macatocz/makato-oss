"""Tests for the provider-neutral model profile resolver (AC-1, task 2).

Covers the task 2 unit_test_spec and integration_test_spec:
  - profile parsing/validation with temporary YAML fixtures
  - all ten canonical roles present per profile
  - profile-specific tool format selected
  - OpenAI credentials required only at execution time (not at parse/dry-run time)
  - error output (and dry-run output) never contains key material
  - `scripts/select-model-profile.sh --dry-run` for each real profile produces
    OMP provider/role documents that a fixture parser can evaluate, and
    switching profiles changes only provider/model routing — not role names.

Import strategy: importlib.util.spec_from_file_location — required for the
non-package filename ``resolve-model-profile.py`` (see test_parse_config_models.py
for the established pattern in this repo).
"""

from __future__ import annotations

import importlib.util
import json
import os
import pathlib
import subprocess
import sys

REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent
RESOLVER = REPO_ROOT / "scripts" / "resolve-model-profile.py"
SELECTOR = REPO_ROOT / "scripts" / "select-model-profile.sh"
REAL_PROFILES_FILE = REPO_ROOT / "config" / "model-profiles.yml"

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


# ---------------------------------------------------------------------------
# Unit: fixture-based parsing and validation (module-level, no subprocess)
# ---------------------------------------------------------------------------


def test_valid_profile_resolves_with_all_ten_roles(tmp_path: pathlib.Path) -> None:
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


def test_emit_omp_config_has_all_ten_role_keys(tmp_path: pathlib.Path) -> None:
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


def test_select_model_profile_install_requires_credentials_when_declared() -> None:
    """Without --dry-run, installing the openai profile must fail loudly when

    OPENAI_API_KEY is unset — credentials are required only at execution time,
    and this IS execution time.
    """
    env = {k: v for k, v in os.environ.items() if k != "OPENAI_API_KEY"}
    result = subprocess.run(
        ["bash", str(SELECTOR), "openai"],
        capture_output=True,
        text=True,
        timeout=15,
        env=env,
    )
    assert result.returncode != 0
    assert "OPENAI_API_KEY" in result.stderr


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
