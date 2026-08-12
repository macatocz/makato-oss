"""Unit tests for synthesize_living_spec.py.

synthesize_living_spec.py populates docs/specs/<capability>.md at archival time
for a `to-issues`-born spec folder that has NO spec-delta.md — synthesising
Current Requirements from plan.md acceptance criteria and/or stories.json
success scenarios (#33). Parallel to sync_living_specs.py (which handles the
spec-delta.md path).

The module functions (parse_plan, parse_stories_json, synthesize, main) are
called directly — no subprocess.
"""

from __future__ import annotations

import json
import os
import sys
import textwrap
from pathlib import Path

import pytest  # type: ignore[import]

# ---------------------------------------------------------------------------
# sys.path wiring — allow ``from synthesize_living_spec import …`` whether
# pytest runs from the repo root or from the scripts/ directory.
# ---------------------------------------------------------------------------
_SCRIPTS_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
# plugins/makato-orchestrate/scripts/
if _SCRIPTS_DIR not in sys.path:
    sys.path.insert(0, _SCRIPTS_DIR)

from synthesize_living_spec import (  # noqa: E402
    main,
    parse_plan,
    parse_stories_json,
    synthesize,
)

# ---------------------------------------------------------------------------
# Fixtures / helpers
# ---------------------------------------------------------------------------

_PLAN_WITH_AC = textwrap.dedent(
    """\
    domain: orchestrate
    # Implementation Plan: 33-archive-spec-to-issues

    ## Story
    **Key:** 33-archive-spec-to-issues
    **Title:** archive-spec: to-issues features populate living spec on archival
    **Phase:** fix

    ## Tasks

    1. Do the first thing.
    2. Do the second thing.

    ## Acceptance criteria

    - Archiving a folder with no spec-delta.md writes a requirement section.
    - The living spec is non-empty and readable afterwards.
    - The spec-delta.md path is left unaffected.

    ## Acceptance Criteria Coverage

    | AC | Description | Covered By |
    |----|-------------|------------|
    | AC-1 | This bullet must NOT be parsed as an acceptance criterion | Task 1 |
    """
)

_STORIES_JSON_SCENARIOS = json.dumps(
    {
        "slug": "33-archive-spec-to-issues",
        "stories": [
            {
                "id": "S1",
                "title": "Synthesise requirements from plan",
                "acceptanceTestCases": [
                    {"scenario": "plan acceptance criteria become SHALL bullets", "gherkin": "..."},
                    {"scenario": "empty inputs are a no-op", "gherkin": "..."},
                ],
            },
            {
                "id": "S2",
                "title": "Skip synthesis when delta present",
                "successScenarios": [
                    "spec-delta.md present short-circuits synthesis",
                ],
            },
        ],
    }
)


def _write(path: str, content: str) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(content)


def _read(path: str) -> str:
    with open(path, encoding="utf-8") as fh:
        return fh.read()


# ---------------------------------------------------------------------------
# parse_plan
# ---------------------------------------------------------------------------


class TestParsePlan:
    def test_title_from_title_field(self) -> None:
        title, _acs = parse_plan(_PLAN_WITH_AC)
        assert title == "archive-spec: to-issues features populate living spec on archival"

    def test_title_falls_back_to_h1_when_no_title_field(self) -> None:
        text = textwrap.dedent(
            """\
            # My Feature Heading

            ## Acceptance criteria

            - Something SHALL happen.
            """
        )
        title, _acs = parse_plan(text)
        assert title == "My Feature Heading"

    def test_h1_strips_implementation_plan_prefix(self) -> None:
        text = textwrap.dedent(
            """\
            # Implementation Plan: 12-some-slug

            ## Acceptance criteria

            - A thing SHALL be true.
            """
        )
        title, _acs = parse_plan(text)
        assert title == "12-some-slug"

    def test_acceptance_criteria_bullets_extracted(self) -> None:
        _title, acs = parse_plan(_PLAN_WITH_AC)
        assert len(acs) == 3
        assert acs[0] == "Archiving a folder with no spec-delta.md writes a requirement section."
        assert acs[2] == "The spec-delta.md path is left unaffected."

    def test_coverage_section_not_parsed_as_criteria(self) -> None:
        """The `## Acceptance Criteria Coverage` table must NOT leak into acs."""
        _title, acs = parse_plan(_PLAN_WITH_AC)
        assert all("must NOT be parsed" not in ac for ac in acs)

    def test_no_ac_section_returns_empty_list(self) -> None:
        text = "# Just a title\n\n## Tasks\n\n1. Do a thing.\n"
        title, acs = parse_plan(text)
        assert title == "Just a title"
        assert acs == []

    def test_star_bullets_supported(self) -> None:
        text = "# T\n\n## Acceptance criteria\n\n* First AC.\n* Second AC.\n"
        _title, acs = parse_plan(text)
        assert acs == ["First AC.", "Second AC."]


# ---------------------------------------------------------------------------
# parse_stories_json
# ---------------------------------------------------------------------------


class TestParseStoriesJson:
    def test_acceptance_test_cases_scenarios(self) -> None:
        pairs = parse_stories_json(_STORIES_JSON_SCENARIOS)
        assert pairs[0][0] == "Synthesise requirements from plan"
        assert pairs[0][1] == [
            "plan acceptance criteria become SHALL bullets",
            "empty inputs are a no-op",
        ]

    def test_success_scenarios_key(self) -> None:
        pairs = parse_stories_json(_STORIES_JSON_SCENARIOS)
        assert pairs[1][0] == "Skip synthesis when delta present"
        assert pairs[1][1] == ["spec-delta.md present short-circuits synthesis"]

    def test_invalid_json_returns_empty(self) -> None:
        assert parse_stories_json("{not valid json") == []

    def test_missing_stories_key_returns_empty(self) -> None:
        assert parse_stories_json('{"slug": "x"}') == []

    def test_top_level_list_supported(self) -> None:
        text = json.dumps([{"title": "Bare Story", "successScenarios": ["a scenario"]}])
        pairs = parse_stories_json(text)
        assert pairs == [("Bare Story", ["a scenario"])]

    def test_story_without_scenarios_yields_empty_scenario_list(self) -> None:
        text = json.dumps({"stories": [{"title": "No scenarios here"}]})
        pairs = parse_stories_json(text)
        assert pairs == [("No scenarios here", [])]


# ---------------------------------------------------------------------------
# synthesize
# ---------------------------------------------------------------------------


class TestSynthesize:
    def _cap(self, tmp_path: Path, cap: str = "33-archive-spec-to-issues") -> tuple[str, str, str]:
        spec_folder = str(tmp_path / cap)
        docs_dir = str(tmp_path / "docs" / "specs")
        os.makedirs(spec_folder, exist_ok=True)
        target = os.path.join(docs_dir, cap + ".md")
        return spec_folder, docs_dir, target

    def test_plan_only_path_writes_shall_section(self, tmp_path: Path) -> None:
        spec_folder, docs_dir, target = self._cap(tmp_path)
        _write(os.path.join(spec_folder, "plan.md"), _PLAN_WITH_AC)
        synthesize(spec_folder, docs_dir)
        assert os.path.isfile(target)
        content = _read(target)
        assert content.count("### ") >= 1
        assert "**SHALL**: Archiving a folder with no spec-delta.md writes a requirement section." in content
        # feature title used as the section heading
        assert "### archive-spec: to-issues features populate living spec on archival" in content

    def test_stories_json_path_writes_section_per_story(self, tmp_path: Path) -> None:
        spec_folder, docs_dir, target = self._cap(tmp_path)
        _write(os.path.join(spec_folder, "stories.json"), _STORIES_JSON_SCENARIOS)
        synthesize(spec_folder, docs_dir)
        content = _read(target)
        assert "### Synthesise requirements from plan" in content
        assert "### Skip synthesis when delta present" in content
        assert "**SHALL**: plan acceptance criteria become SHALL bullets" in content

    def test_both_inputs_contribute_sections(self, tmp_path: Path) -> None:
        spec_folder, docs_dir, target = self._cap(tmp_path)
        _write(os.path.join(spec_folder, "plan.md"), _PLAN_WITH_AC)
        _write(os.path.join(spec_folder, "stories.json"), _STORIES_JSON_SCENARIOS)
        synthesize(spec_folder, docs_dir)
        content = _read(target)
        # plan-derived section
        assert "### archive-spec: to-issues features populate living spec on archival" in content
        # story-derived sections
        assert "### Synthesise requirements from plan" in content

    def test_empty_inputs_is_noop_no_file(self, tmp_path: Path) -> None:
        """plan.md with no AC section + no stories.json → no file created."""
        spec_folder, docs_dir, target = self._cap(tmp_path)
        _write(os.path.join(spec_folder, "plan.md"), "# Title only\n\n## Tasks\n\n1. thing\n")
        synthesize(spec_folder, docs_dir)
        assert not os.path.exists(target)

    def test_missing_inputs_is_noop_no_file(self, tmp_path: Path) -> None:
        """Neither plan.md nor stories.json present → clean no-op."""
        spec_folder, docs_dir, target = self._cap(tmp_path)
        synthesize(spec_folder, docs_dir)
        assert not os.path.exists(target)

    def test_appends_to_existing_file(self, tmp_path: Path) -> None:
        spec_folder, docs_dir, target = self._cap(tmp_path)
        _write(target, "### Pre-existing Requirement\n\n**SHALL**: already here.\n")
        _write(os.path.join(spec_folder, "plan.md"), _PLAN_WITH_AC)
        synthesize(spec_folder, docs_dir)
        content = _read(target)
        assert "### Pre-existing Requirement" in content  # preserved
        assert "already here." in content
        assert "### archive-spec: to-issues features populate living spec on archival" in content

    def test_creates_docs_dir_when_absent(self, tmp_path: Path) -> None:
        spec_folder = str(tmp_path / "fresh-cap")
        os.makedirs(spec_folder)
        docs_dir = str(tmp_path / "docs" / "specs")  # does NOT exist yet
        _write(os.path.join(spec_folder, "plan.md"), _PLAN_WITH_AC)
        synthesize(spec_folder, docs_dir)
        assert os.path.isfile(os.path.join(docs_dir, "fresh-cap.md"))

    def test_capability_derived_from_folder_basename(self, tmp_path: Path) -> None:
        spec_folder, docs_dir, target = self._cap(tmp_path, cap="my-weird-slug")
        _write(os.path.join(spec_folder, "plan.md"), _PLAN_WITH_AC)
        synthesize(spec_folder, docs_dir)
        assert os.path.isfile(os.path.join(docs_dir, "my-weird-slug.md"))


# ---------------------------------------------------------------------------
# main / CLI exit codes
# ---------------------------------------------------------------------------


class TestMainExitCodes:
    def test_missing_args_exits_1(self) -> None:
        with pytest.raises(SystemExit) as exc:
            main([])
        assert exc.value.code == 1

    def test_missing_spec_folder_returns_1(self, tmp_path: Path) -> None:
        rc = main([str(tmp_path / "does-not-exist"), str(tmp_path / "docs")])
        assert rc == 1

    def test_exit_0_success(self, tmp_path: Path) -> None:
        spec_folder = str(tmp_path / "cli-cap")
        os.makedirs(spec_folder)
        _write(os.path.join(spec_folder, "plan.md"), _PLAN_WITH_AC)
        docs_dir = str(tmp_path / "docs" / "specs")
        rc = main([spec_folder, docs_dir])
        assert rc == 0
        assert os.path.isfile(os.path.join(docs_dir, "cli-cap.md"))

    def test_exit_0_noop_when_no_content(self, tmp_path: Path) -> None:
        spec_folder = str(tmp_path / "empty-cap")
        os.makedirs(spec_folder)
        docs_dir = str(tmp_path / "docs" / "specs")
        rc = main([spec_folder, docs_dir])
        assert rc == 0
        assert not os.path.exists(os.path.join(docs_dir, "empty-cap.md"))
