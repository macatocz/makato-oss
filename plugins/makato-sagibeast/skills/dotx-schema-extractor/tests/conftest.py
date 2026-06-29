"""Pytest configuration for dotx-schema-extractor tests.

The test modules import from a sibling package (``fixtures.build_synthetic``),
which only resolves when this directory is on ``sys.path``. ``pytest`` adds
``rootdir`` to ``sys.path`` automatically when ``conftest.py`` is present at
the tests root, so the file's mere presence — together with the explicit
``sys.path`` insertion below as a belt-and-braces guarantee — is sufficient to
make ``fixtures`` importable regardless of where pytest is invoked from
(repo root, plugin root, or this directory).

This conftest is the documented fix for #64 Part B's last AC: making the
dotx-schema-extractor test suite collectable from the repo-level pytest run
without changing the existing test files.
"""

from __future__ import annotations

import os
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)
