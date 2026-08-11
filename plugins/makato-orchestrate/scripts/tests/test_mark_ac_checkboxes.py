"""pytest port of mark-ac-checkboxes-smoke-tests.sh (T1–T10).

Covers all 10 bash smoke scenarios plus one end-to-end main() invocation per
exit-code path (exit 0 / exit 1).

The module functions (normalize, load_verdicts, mark_checkboxes, process_files,
main) are called directly — no subprocess.
"""

from __future__ import annotations

import io
import json
import os
import sys

import pytest  # type: ignore[import]

# ---------------------------------------------------------------------------
# sys.path wiring — allow ``from mark_ac_checkboxes import …`` whether pytest
# is run from the repo root or from the scripts/ directory.
# ---------------------------------------------------------------------------
_SCRIPTS_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
if _SCRIPTS_DIR not in sys.path:
    sys.path.insert(0, _SCRIPTS_DIR)

from mark_ac_checkboxes import (  # noqa: E402
    main,
    mark_checkboxes,
    normalize,
    process_files,
)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

_BODY3 = "## Definition of Done\n\n- [ ] Alpha behaviour works\n- [ ] Beta behaviour works"

_BODY7 = "- [ ] Completely different wording one\n- [ ] Completely different wording two"


def _write(path: str, content: str) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(content)


def _run_process(
    verdicts: list[dict] | str,
    body: str,
    tmp_path: pytest.TempPathFactory,
) -> tuple[str, dict]:
    """Run process_files with string/list inputs; return (body_out, summary_dict)."""
    v_path = str(tmp_path / "v.json")
    b_path = str(tmp_path / "b.md")
    if isinstance(verdicts, list):
        _write(v_path, json.dumps(verdicts))
    else:
        _write(v_path, verdicts)
    _write(b_path, body)
    out_buf = io.StringIO()
    err_buf = io.StringIO()
    rc = process_files(v_path, b_path, stdout=out_buf, stderr=err_buf)
    assert rc == 0
    summary = json.loads(err_buf.getvalue().strip())
    return out_buf.getvalue(), summary


# ---------------------------------------------------------------------------
# Unit tests for normalize
# ---------------------------------------------------------------------------


class TestNormalize:
    def test_strips_leading_ac_label(self) -> None:
        assert normalize("AC-1: Alpha behaviour works.") == "alpha behaviour works"

    def test_strips_scenario_label(self) -> None:
        assert normalize("Scenario 2: Foo bar") == "foo bar"

    def test_collapses_whitespace(self) -> None:
        assert normalize("  foo   bar  ") == "foo bar"

    def test_strips_trailing_punctuation(self) -> None:
        assert normalize("something.") == "something"


# ---------------------------------------------------------------------------
# Unit tests for mark_checkboxes
# ---------------------------------------------------------------------------


class TestMarkCheckboxes:
    # T3: granular — matched verified box flips, other untouched
    def test_T3_granular_matched_flips_other_untouched(self) -> None:
        verdicts = [
            {"ac_id": "AC-1", "ac_text": "Alpha behaviour works", "verified": True},
            {"ac_id": "AC-2", "ac_text": "Beta behaviour works", "verified": False},
        ]
        body, summary = mark_checkboxes(verdicts, _BODY3)
        assert "- [x] Alpha behaviour works" in body
        assert "- [ ] Beta behaviour works" in body
        assert summary["mode"] == "granular"
        assert summary["boxes_checked"] == 1

    # T4: granular — verified==false leaves box unchecked
    def test_T4_false_verdict_stays_unchecked(self) -> None:
        verdicts = [
            {"ac_id": "AC-1", "ac_text": "Alpha behaviour works", "verified": True},
            {"ac_id": "AC-2", "ac_text": "Beta behaviour works", "verified": False},
        ]
        body, _ = mark_checkboxes(verdicts, _BODY3)
        assert "- [ ] Beta behaviour works" in body

    # T5: never flips [x] back to [ ]
    def test_T5_never_unchecks_existing_x(self) -> None:
        body5 = "- [x] Already done\n- [ ] Alpha behaviour works"
        verdicts = [{"ac_id": "AC-1", "ac_text": "Already done", "verified": False}]
        body, _ = mark_checkboxes(verdicts, body5)
        assert "- [x] Already done" in body

    # T6: normalization pairs AC-N-prefixed text with plain issue line
    def test_T6_normalization_strips_ac_prefix(self) -> None:
        verdicts = [{"ac_id": "AC-1", "ac_text": "AC-1: Alpha behaviour works.", "verified": True}]
        body, summary = mark_checkboxes(verdicts, _BODY3)
        assert "- [x] Alpha behaviour works" in body
        assert summary["mode"] == "granular"

    # T7: fallback-all — 0 matches + all verified → all checked
    def test_T7_fallback_all_checks_every_box(self) -> None:
        verdicts = [
            {"ac_id": "AC-1", "ac_text": "nonmatching alpha", "verified": True},
            {"ac_id": "AC-2", "ac_text": "nonmatching beta", "verified": True},
        ]
        body, summary = mark_checkboxes(verdicts, _BODY7)
        assert summary["mode"] == "fallback-all"
        assert body.count("- [x]") == 2

    # T8: fallback-none — 0 matches + one gap → none checked
    def test_T8_fallback_none_leaves_all_unchecked(self) -> None:
        verdicts = [
            {"ac_id": "AC-1", "ac_text": "nonmatching alpha", "verified": True},
            {"ac_id": "AC-2", "ac_text": "nonmatching beta", "verified": False},
        ]
        body, summary = mark_checkboxes(verdicts, _BODY7)
        assert summary["mode"] == "fallback-none"
        assert body.count("- [x]") == 0
        assert "- [ ] Completely different wording one" in body

    # T9: empty verdict array → skipped, body unchanged
    def test_T9_empty_verdicts_is_skipped(self) -> None:
        body, summary = mark_checkboxes([], _BODY3)
        assert summary["mode"] == "skipped"
        assert body == _BODY3

    # T10: indentation and label text preserved byte-for-byte except marker
    def test_T10_indent_and_spacing_preserved(self) -> None:
        body10 = "  - [ ]   Indented alpha with spacing"
        verdicts = [{"ac_id": "AC-1", "ac_text": "Indented alpha with spacing", "verified": True}]
        body, _ = mark_checkboxes(verdicts, body10)
        assert "  - [x]   Indented alpha with spacing" in body


# ---------------------------------------------------------------------------
# Integration tests — process_files
# ---------------------------------------------------------------------------


class TestProcessFiles:
    def test_happy_path_granular(self, tmp_path: pytest.TempPathFactory) -> None:
        body, summary = _run_process(
            [{"ac_id": "AC-1", "ac_text": "Alpha behaviour works", "verified": True}],
            _BODY3,
            tmp_path,
        )
        assert "- [x] Alpha behaviour works" in body
        assert summary["mode"] == "granular"

    def test_malformed_json_raises_system_exit_1(self, tmp_path: pytest.TempPathFactory) -> None:
        v_path = str(tmp_path / "bad.json")
        b_path = str(tmp_path / "b.md")
        _write(v_path, "{not json")
        _write(b_path, "body")
        with pytest.raises(SystemExit) as exc:
            process_files(v_path, b_path)
        assert exc.value.code == 1

    def test_non_array_verdict_raises_system_exit_1(self, tmp_path: pytest.TempPathFactory) -> None:
        v_path = str(tmp_path / "obj.json")
        b_path = str(tmp_path / "b.md")
        _write(v_path, '{"ac_id": "AC-1"}')
        _write(b_path, "body")
        with pytest.raises(SystemExit) as exc:
            process_files(v_path, b_path)
        assert exc.value.code == 1


# ---------------------------------------------------------------------------
# End-to-end main() tests — one per exit-code path
# ---------------------------------------------------------------------------


class TestMainExitCodes:
    # T1: missing args → exit 1
    def test_T1_missing_args_exits_1(self) -> None:
        with pytest.raises(SystemExit) as exc:
            main([])
        assert exc.value.code == 1

    # T2: malformed verdict JSON → exit 1
    def test_T2_malformed_json_exits_1(self, tmp_path: pytest.TempPathFactory) -> None:
        v_path = str(tmp_path / "bad.json")
        b_path = str(tmp_path / "b.md")
        _write(v_path, "{not json")
        _write(b_path, "body")
        with pytest.raises(SystemExit) as exc:
            main([v_path, b_path])
        assert exc.value.code == 1

    # verdicts file not found → exit 1
    def test_missing_verdicts_file_exits_1(self, tmp_path: pytest.TempPathFactory) -> None:
        b_path = str(tmp_path / "b.md")
        _write(b_path, "body")
        rc = main([str(tmp_path / "missing.json"), b_path])
        assert rc == 1

    # body file not found → exit 1
    def test_missing_body_file_exits_1(self, tmp_path: pytest.TempPathFactory) -> None:
        v_path = str(tmp_path / "v.json")
        _write(v_path, "[]")
        rc = main([v_path, str(tmp_path / "missing.md")])
        assert rc == 1

    # exit 0: happy path
    def test_exit_0_success(self, tmp_path: pytest.TempPathFactory) -> None:
        v_path = str(tmp_path / "v.json")
        b_path = str(tmp_path / "b.md")
        _write(v_path, json.dumps([]))
        _write(b_path, _BODY3)
        rc = main([v_path, b_path])
        assert rc == 0
