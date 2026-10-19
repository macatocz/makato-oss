"""Resolve provider-neutral skill roles and effort from workflow schemas."""

from __future__ import annotations

import re
from collections.abc import Collection, Mapping
from pathlib import Path
from typing import Any

import yaml
from yaml.constructor import ConstructorError
from yaml.nodes import MappingNode

DEFAULT_SCHEMA = Path(__file__).resolve().parents[1] / "config" / "default-workflow-schema.yml"
EFFORTS = frozenset({"off", "minimal", "low", "medium", "high", "xhigh", "max", "auto", "inherit"})
_ROLE = re.compile(r"[A-Za-z][A-Za-z0-9_-]*\Z")
_NAME = re.compile(r"[a-z0-9][a-z0-9_-]*\Z")
_QUALIFIED = re.compile(r"[a-z0-9][a-z0-9_-]*:[a-z0-9][a-z0-9_-]*\Z")


class SkillExecutionError(ValueError):
    """An execution setting cannot be resolved safely."""


class _UniqueSafeLoader(yaml.SafeLoader):
    """Safe YAML with duplicate-key rejection and YAML 1.2 boolean spelling."""

    yaml_implicit_resolvers = {key: [(tag, pattern) for tag, pattern in resolvers if tag != "tag:yaml.org,2002:bool"] for key, resolvers in yaml.SafeLoader.yaml_implicit_resolvers.items()}

    def construct_mapping(self, node: MappingNode, deep: bool = False) -> dict[Any, Any]:
        self.flatten_mapping(node)
        result: dict[Any, Any] = {}
        for key_node, value_node in node.value:
            key = self.construct_object(key_node, deep=deep)
            try:
                duplicate = key in result
            except TypeError as exc:
                raise ConstructorError(
                    "while reading a mapping",
                    node.start_mark,
                    "mapping keys must be scalar values",
                    key_node.start_mark,
                ) from exc
            if duplicate:
                raise ConstructorError(
                    "while reading a mapping",
                    node.start_mark,
                    f"duplicate key {key!r}; keep one value for this key",
                    key_node.start_mark,
                )
            result[key] = self.construct_object(value_node, deep=deep)
        return result


_UniqueSafeLoader.add_implicit_resolver(
    "tag:yaml.org,2002:bool",
    re.compile(r"(?:true|false|True|False|TRUE|FALSE)\Z"),
    list("tTfF"),
)


def _mapping(value: Any, location: str) -> Mapping[str, Any]:
    if not isinstance(value, dict) or any(not isinstance(key, str) for key in value):
        raise SkillExecutionError(f"{location}: expected a mapping with string keys")
    return value


def _read_schema(path: Path) -> Mapping[str, Any]:
    try:
        text = path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as exc:
        raise SkillExecutionError(f"Cannot read workflow schema {path}: {exc}") from exc
    try:
        # _UniqueSafeLoader subclasses yaml.SafeLoader; bandit only recognises the stock safe loader names.
        data = yaml.load(text, Loader=_UniqueSafeLoader)  # nosec B506
    except yaml.YAMLError as exc:
        raise SkillExecutionError(f"{path}: invalid YAML: {exc}") from exc
    return _mapping({} if data is None else data, str(path))


def _fields(data: Mapping[str, Any], allowed: set[str], location: str) -> None:
    unknown = sorted(set(data) - allowed)
    if unknown:
        raise SkillExecutionError(f"{location}: unknown execution field(s) {', '.join(unknown)}; allowed fields: {', '.join(sorted(allowed))}")


def _settings(value: Any, location: str) -> dict[str, str]:
    data = _mapping(value, location)
    _fields(data, {"role", "effort"}, location)
    result: dict[str, str] = {}
    if "role" in data:
        role = data["role"]
        if not isinstance(role, str) or not _ROLE.fullmatch(role):
            raise SkillExecutionError(
                f"{location}.role: expected a model role such as PLAN or REVIEW (letter followed by letters, digits, '_' or '-'); configure concrete providers in OMP modelRoles, not here"
            )
        result["role"] = role.upper()
    if "effort" in data:
        effort = data["effort"]
        if not isinstance(effort, str) or effort not in EFFORTS:
            raise SkillExecutionError(f"{location}.effort: expected one of {', '.join(sorted(EFFORTS))}; use inherit to leave OMP thinking settings unchanged")
        result["effort"] = effort
    return result


def _execution(
    schema: Mapping[str, Any],
    path: Path,
    known_skills: Collection[str] | None = None,
    *,
    allow_unknown: bool = False,
) -> tuple[dict[str, str], dict[str, dict[str, str]]]:
    if "skill_execution" not in schema:
        return {}, {}
    location = f"{path}: skill_execution"
    section = _mapping(schema["skill_execution"], location)
    _fields(section, {"defaults", "skills"}, location)
    defaults = _settings(section.get("defaults", {}), f"{location}.defaults")
    skills = _mapping(section.get("skills", {}), f"{location}.skills")
    resolved: dict[str, dict[str, str]] = {}
    for key, value in skills.items():
        if not _QUALIFIED.fullmatch(key):
            raise SkillExecutionError(f"{location}.skills: invalid skill key {key!r}; use a qualified plugin:skill key such as 'makato-build:build-review'")
        if known_skills is not None and key not in known_skills and not allow_unknown:
            raise SkillExecutionError(f"{location}.skills: unknown skill {key!r}; use a skill from the built-in skill_execution.skills map in {DEFAULT_SCHEMA}")
        resolved[key] = _settings(value, f"{location}.skills[{key!r}]")
    return defaults, resolved


def _canonical_skill(skill: str, known_skills: Collection[str], *, allow_unknown: bool = False) -> str:
    if not isinstance(skill, str) or not (_QUALIFIED.fullmatch(skill) or _NAME.fullmatch(skill)):
        raise SkillExecutionError(f"Invalid skill {skill!r}; use plugin:skill, for example makato-build:build-review")
    if skill in known_skills:
        return skill
    if ":" not in skill:
        matches = sorted(key for key in known_skills if key.split(":", 1)[1] == skill)
        if len(matches) == 1:
            return matches[0]
        if matches:
            raise SkillExecutionError(f"Ambiguous skill {skill!r}; use a qualified name: {', '.join(matches)}")
    if allow_unknown:
        return skill
    raise SkillExecutionError(f"Unknown skill {skill!r}; use a qualified name from the built-in skill_execution.skills map")


def canonical_skill(skill: str, default_schema: Path | None = None) -> str:
    """Return a registered plugin:skill, requiring unique unqualified names."""
    path = default_schema if default_schema is not None else DEFAULT_SCHEMA
    _, skills = _execution(_read_schema(path), path)
    return _canonical_skill(skill, skills)


def resolve_execution(
    repo_root: Path,
    skill: str,
    default_schema: Path | None = None,
    *,
    allow_unknown: bool = False,
) -> dict[str, str]:
    """Return ``role`` (uppercase) and ``effort`` without choosing a provider.

    Merge each field independently, in order: built-in defaults, built-in skill,
    project defaults, project skill. A project workflow need not contain an
    execution section or artifacts. ``allow_unknown`` is only for workflow-schema
    consumers that support custom artifact skills; launchers must remain strict.
    """
    path = default_schema if default_schema is not None else DEFAULT_SCHEMA
    defaults, skills = _execution(_read_schema(path), path)
    name = _canonical_skill(skill, skills, allow_unknown=allow_unknown)
    project_path = repo_root / ".claude" / "workflow-schema.yml"
    project_defaults: dict[str, str] = {}
    project_skills: dict[str, dict[str, str]] = {}
    if project_path.exists():
        project_schema = _read_schema(project_path)
        known_project_skills = set(skills)
        artifacts = project_schema.get("artifacts", [])
        if isinstance(artifacts, list):
            for artifact in artifacts:
                if isinstance(artifact, dict) and isinstance(artifact.get("skill"), str):
                    known_project_skills.add(artifact["skill"])
        project_defaults, project_skills = _execution(project_schema, project_path, known_project_skills, allow_unknown=allow_unknown)
    return {
        "role": "DEFAULT",
        "effort": "inherit",
        **defaults,
        **skills.get(name, {}),
        **project_defaults,
        **project_skills.get(name, {}),
    }
