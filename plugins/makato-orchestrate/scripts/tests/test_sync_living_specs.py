"""pytest port of sync-living-specs-smoke-tests.sh (T1–T8).

Covers all 8 bash smoke scenarios plus one end-to-end main() invocation per
exit-code path (exit 0 / exit 1).

The module functions (parse_delta, split_sections, join_chunks, apply_delta,
main) are called directly — no subprocess.
"""

from __future__ import annotations

import os
import sys
import textwrap

import pytest  # type: ignore[import]

# ---------------------------------------------------------------------------
# sys.path wiring — allow ``from sync_living_specs import …`` whether pytest
# is run from the repo root or from the scripts/ directory.
# ---------------------------------------------------------------------------
_SCRIPTS_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
# plugins/makato-orchestrate/scripts/
if _SCRIPTS_DIR not in sys.path:
    sys.path.insert(0, _SCRIPTS_DIR)

from sync_living_specs import (  # noqa: E402
    apply_delta,
    join_chunks,
    main,
    parse_delta,
    req_name_from_heading,
    split_sections,
)

# ---------------------------------------------------------------------------
# Helpers / fixtures
# ---------------------------------------------------------------------------

_EXISTING_SPEC = textwrap.dedent(
    """\
    # Test Capability Spec

    ### Existing Heading

    **SHALL**: This section was always here.

    ### Bar Requirement

    **SHALL**: The original bar behaviour.
    """
)


def _write(path: str, content: str) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(content)


def _read(path: str) -> str:
    with open(path, encoding="utf-8") as fh:
        return fh.read()


# ---------------------------------------------------------------------------
# Unit tests for parse_delta
# ---------------------------------------------------------------------------


class TestParseDelta:
    """Unit-level tests for the parse_delta pure function."""

    def test_parse_added_section(self) -> None:
        delta = textwrap.dedent(
            """\
            ## ADDED Requirements

            ### New Feature

            **SHALL**: The system SHALL support the new feature.
            """
        )
        result = parse_delta(delta)
        assert len(result["ADDED"]) == 1
        name, body = result["ADDED"][0]
        assert name == "New Feature"
        assert any("new feature" in line for line in body)
        assert result["MODIFIED"] == []
        assert result["REMOVED"] == []

    def test_parse_modified_section(self) -> None:
        delta = textwrap.dedent(
            """\
            ## MODIFIED Requirements

            ### Bar Requirement

            **SHALL**: The bar behaviour is now updated.
            """
        )
        result = parse_delta(delta)
        assert len(result["MODIFIED"]) == 1
        assert result["MODIFIED"][0][0] == "Bar Requirement"

    def test_parse_removed_section(self) -> None:
        delta = textwrap.dedent(
            """\
            ## REMOVED Requirements

            ### Old Feature

            **SHALL**: no longer apply.
            """
        )
        result = parse_delta(delta)
        assert len(result["REMOVED"]) == 1
        assert result["REMOVED"][0][0] == "Old Feature"

    def test_template_comment_only_bodies_are_skipped(self) -> None:
        """T8 unit: template comment-only sections produce empty lists."""
        delta = textwrap.dedent(
            """\
            ## ADDED Requirements

            <!-- Add new requirements here -->

            ## MODIFIED Requirements

            <!-- List modified requirements here -->

            ## REMOVED Requirements

            <!-- List removed requirements here -->
            """
        )
        result = parse_delta(delta)
        assert result["ADDED"] == []
        assert result["MODIFIED"] == []
        assert result["REMOVED"] == []


# ---------------------------------------------------------------------------
# Unit tests for split_sections / join_chunks
# ---------------------------------------------------------------------------


class TestSplitJoin:
    def test_roundtrip_preserves_content(self) -> None:
        lines = _EXISTING_SPEC.splitlines()
        chunks = split_sections(lines)
        rejoined = join_chunks(chunks)
        assert rejoined == lines

    def test_heading_none_for_preamble(self) -> None:
        lines = ["# Top level", "", "### First Section", "body"]
        chunks = split_sections(lines)
        # First chunk has None heading (preamble before first ###)
        assert chunks[0][0] is None
        assert "# Top level" in chunks[0][1]

    def test_req_name_from_heading(self) -> None:
        assert req_name_from_heading("### Foo Bar") == "Foo Bar"
        assert req_name_from_heading("## Not a req") is None
        assert req_name_from_heading(None) is None


# ---------------------------------------------------------------------------
# Integration tests — apply_delta (mirrors T3–T8 bash scenarios)
# ---------------------------------------------------------------------------


class TestApplyDelta:
    """Integration-level tests for apply_delta using tmp_path fixtures."""

    def _setup_cap(self, tmp_path: pytest.TempPathFactory, cap: str = "test-cap") -> tuple[str, str, str]:
        """Return (cap_dir, docs_dir, target_path)."""
        cap_dir = str(tmp_path / cap)
        docs_dir = str(tmp_path / "docs" / "specs")
        os.makedirs(cap_dir, exist_ok=True)
        os.makedirs(docs_dir, exist_ok=True)
        target = os.path.join(docs_dir, cap + ".md")
        _write(target, _EXISTING_SPEC)
        return cap_dir, docs_dir, target

    # T3: ADDED requirement appended to existing file
    def test_T3_added_appended_to_existing_file(self, tmp_path: pytest.TempPathFactory) -> None:
        cap_dir, docs_dir, target = self._setup_cap(tmp_path)
        delta = os.path.join(cap_dir, "spec-delta.md")
        _write(
            delta,
            textwrap.dedent(
                """\
                ## ADDED Requirements

                ### New Feature

                **SHALL**: The system SHALL support the new feature.
                """
            ),
        )
        apply_delta(delta, docs_dir)
        content = _read(target)
        assert "### New Feature" in content
        assert "new feature" in content
        assert "Existing Heading" in content  # pre-existing preserved

    # T4: MODIFIED replaces matching heading; others untouched
    def test_T4_modified_replaces_matching_heading(self, tmp_path: pytest.TempPathFactory) -> None:
        cap_dir, docs_dir, target = self._setup_cap(tmp_path)
        delta = os.path.join(cap_dir, "spec-delta.md")
        _write(
            delta,
            textwrap.dedent(
                """\
                ## MODIFIED Requirements

                ### Bar Requirement

                **SHALL**: The bar behaviour is now updated.
                """
            ),
        )
        apply_delta(delta, docs_dir)
        content = _read(target)
        assert "now updated" in content
        assert "original bar" not in content
        assert "Existing Heading" in content  # unrelated preserved

    # T5: REMOVED replaced with tombstone comment
    def test_T5_removed_becomes_tombstone(self, tmp_path: pytest.TempPathFactory) -> None:
        cap_dir, docs_dir, target = self._setup_cap(tmp_path)
        delta = os.path.join(cap_dir, "spec-delta.md")
        _write(
            delta,
            textwrap.dedent(
                """\
                ## REMOVED Requirements

                ### Existing Heading

                **SHALL**: no longer apply.
                """
            ),
        )
        apply_delta(delta, docs_dir)
        content = _read(target)
        assert "<!-- REMOVED: Existing Heading -->" in content
        assert "was always here" not in content
        assert "Bar Requirement" in content  # unrelated preserved

    # T6: dangling MODIFIED emits WARN, exits 0, target unchanged
    def test_T6_dangling_modified_warns_but_does_not_fail(self, tmp_path: pytest.TempPathFactory, capsys: pytest.CaptureFixture) -> None:
        cap_dir, docs_dir, target = self._setup_cap(tmp_path)
        before = _read(target)
        delta = os.path.join(cap_dir, "spec-delta.md")
        _write(
            delta,
            textwrap.dedent(
                """\
                ## MODIFIED Requirements

                ### No Such Heading In Target

                **SHALL**: This requirement has no match.
                """
            ),
        )
        import io

        warn_buf = io.StringIO()
        apply_delta(delta, docs_dir, stderr=warn_buf)  # no exception
        warn_output = warn_buf.getvalue()
        assert "WARN" in warn_output
        assert _read(target) == before  # target unchanged

    # T7: ADDED creates target from scratch
    def test_T7_added_creates_file_from_scratch(self, tmp_path: pytest.TempPathFactory) -> None:
        cap_dir = str(tmp_path / "new-cap")
        os.makedirs(cap_dir)
        docs_dir = str(tmp_path / "docs" / "specs")
        # docs_dir does NOT exist — script must create it
        delta = os.path.join(cap_dir, "spec-delta.md")
        _write(
            delta,
            textwrap.dedent(
                """\
                ## ADDED Requirements

                ### First Requirement

                **SHALL**: The system SHALL satisfy the first requirement.
                """
            ),
        )
        apply_delta(delta, docs_dir)
        target = os.path.join(docs_dir, "new-cap.md")
        assert os.path.isfile(target)
        content = _read(target)
        assert "First Requirement" in content
        assert "satisfy the first requirement" in content

    # T8: empty spec-delta is a clean no-op
    def test_T8_empty_spec_delta_is_noop(self, tmp_path: pytest.TempPathFactory) -> None:
        cap_dir, docs_dir, target = self._setup_cap(tmp_path)
        before = _read(target)
        delta = os.path.join(cap_dir, "spec-delta.md")
        _write(
            delta,
            textwrap.dedent(
                """\
                ## ADDED Requirements

                <!-- Add new requirements here -->

                ## MODIFIED Requirements

                <!-- List modified requirements here -->

                ## REMOVED Requirements

                <!-- List removed requirements here -->
                """
            ),
        )
        apply_delta(delta, docs_dir)
        assert _read(target) == before  # unchanged


# ---------------------------------------------------------------------------
# End-to-end main() tests — one per exit-code path
# ---------------------------------------------------------------------------


class TestMainExitCodes:
    """End-to-end coverage of exit codes via main()."""

    # T1: missing args → exit 1 (_Parser.error overrides argparse default code 2 to 1)
    def test_T1_missing_args_exits_1(self) -> None:
        with pytest.raises(SystemExit) as exc:
            main([])
        assert exc.value.code == 1

    # T2: missing spec-delta file → return 1 (not SystemExit — main returns int)
    def test_T2_missing_delta_file_returns_1(self, tmp_path: pytest.TempPathFactory) -> None:
        rc = main([str(tmp_path / "nonexistent" / "spec-delta.md"), str(tmp_path / "docs")])
        assert rc == 1

    # exit 0: happy path
    def test_exit_0_success(self, tmp_path: pytest.TempPathFactory) -> None:
        cap_dir = str(tmp_path / "my-cap")
        os.makedirs(cap_dir)
        delta = os.path.join(cap_dir, "spec-delta.md")
        _write(
            delta,
            textwrap.dedent(
                """\
                ## ADDED Requirements

                ### A Thing

                **SHALL**: exist.
                """
            ),
        )
        docs_dir = str(tmp_path / "docs" / "specs")
        rc = main([delta, docs_dir])
        assert rc == 0
        assert os.path.isfile(os.path.join(docs_dir, "my-cap.md"))
