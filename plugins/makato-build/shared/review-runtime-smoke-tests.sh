#!/usr/bin/env bash
# Real run-skill/runtime integration smoke using a disposable controlled executable.
# Requires Python 3 and Git; it does not invoke an LLM or make quality claims.
set -euo pipefail

BUILD_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PYTHONPATH="$BUILD_ROOT/shared:$BUILD_ROOT/scripts/tests${PYTHONPATH:+:$PYTHONPATH}" \
  python3 -m unittest test_review_runtime test_run_skill_runtime
