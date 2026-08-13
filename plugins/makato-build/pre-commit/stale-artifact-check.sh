#!/usr/bin/env bash
# stale-artifact-check.sh — pre-commit sensor for debug leftovers and temp files (#596)
#
# Flags debug artifacts and staged temp/log files in the session diff:
#   - console.log(  — JS/TS debug output
#   - debugger      — JS/TS debugger statement
#   - pdb.set_trace() / breakpoint() — Python debugger calls
#   - staged *.log files
#   - staged *.tmp / tmp_* / temp_* files
#
# Output per finding: path:line: [stale-artifact/<rule>] message
# Exit nonzero if any finding emitted; exit 0 otherwise.
#
# Invocation: pre-commit `language: system` hook with `pass_filenames: true`
#   pre-commit passes staged filenames as positional arguments.
set -euo pipefail

FAIL=0

for f in "$@"; do
  # -----------------------------------------------------------------------
  # Filename-based checks (no content grep needed)
  # -----------------------------------------------------------------------
  basename_f="$(basename "$f")"

  # *.log staged files
  if [[ "$basename_f" == *.log ]]; then
    echo "${f}: [stale-artifact/log-file] staged *.log file — remove before committing"
    FAIL=1
    continue
  fi

  # *.tmp / tmp_* / temp_* staged files
  if [[ "$basename_f" == *.tmp ]] || \
     [[ "$basename_f" == tmp_* ]] || \
     [[ "$basename_f" == temp_* ]]; then
    echo "${f}: [stale-artifact/temp-file] staged temp file — remove before committing"
    FAIL=1
    continue
  fi

  # -----------------------------------------------------------------------
  # Content-based checks: scan addition lines in the staged diff via awk
  # -----------------------------------------------------------------------
  # Use awk to parse the diff and extract line numbers for matches
  git diff --cached -- "$f" 2>/dev/null | awk '
    # Track current line number in new file from hunk headers
    /^@@ / {
      # Extract new-file start line from "@@ -old +new[,count] @@"
      # sub()+split() is POSIX; 3-arg match() is gawk-only and fails on BSD awk
      tmp = $0
      sub(/^@@ [^+]*\+/, "", tmp)
      split(tmp, a, /[ ,]/)
      hunk_line = a[1] + 0 - 1
      next
    }
    # Deletion lines and context lines: advance counter for context only
    /^\-/ { next }
    /^ / { hunk_line++; next }
    # Addition lines: check for debug patterns
    /^\+/ {
      # Skip the +++ file header line
      if (/^\+\+\+/) { next }
      hunk_line++
      content = substr($0, 2)  # strip leading +

      if (content ~ /console\.log\(/) {
        print FILENAME ":" hunk_line ": [stale-artifact/console-log] console.log( found in addition"
        found = 1
      }
      if (content ~ /\bdebugger\b/) {
        print FILENAME ":" hunk_line ": [stale-artifact/debugger] debugger statement found in addition"
        found = 1
      }
      if (content ~ /pdb\.set_trace\(\)/ || content ~ /breakpoint\(\)/) {
        print FILENAME ":" hunk_line ": [stale-artifact/python-debugger] Python debugger call found in addition"
        found = 1
      }
    }
    END { exit (found ? 1 : 0) }
  ' FILENAME="$f" && true || FAIL=1

done

exit "$FAIL"
