#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

ALLOWED=(
  ".claude"
  ".claude-plugin"
  ".github"
  ".git"
  "plugins"
  "packages"
  "docs"
  "scripts"
  "specs"
  "tests"
)

ALLOWED_FILES=(
  "CLAUDE.md"
  "AGENTS.md"
  "CHANGELOG.md"
  "CONTRIBUTING.md"
  "README.md"
  "LICENSE"
  ".editorconfig"
  ".gitignore"
  "package.json"
  ".markdownlint.json"
  ".markdownlintignore"
  "release-please-config.json"
  ".release-please-manifest.json"
  ".git"
  ".pre-commit-config.yaml"
  "pyproject.toml"
  "renovate.json"
)

ERRORS=0

is_ignored() {
  git -C "$REPO_ROOT" check-ignore -q "$1" 2>/dev/null
}

for entry in "$REPO_ROOT"/*/; do
  dirname="$(basename "$entry")"
  is_ignored "$entry" && continue
  found=false
  for allowed in "${ALLOWED[@]}"; do
    if [ "$dirname" = "$allowed" ]; then
      found=true
      break
    fi
  done
  if [ "$found" = false ]; then
    echo "ERROR: Unexpected directory at root: $dirname/"
    ERRORS=$((ERRORS + 1))
  fi
done

for entry in "$REPO_ROOT"/.[^.]*/; do
  if [ -d "$entry" ]; then
    dirname="$(basename "$entry")"
    is_ignored "$entry" && continue
    found=false
    for allowed in "${ALLOWED[@]}"; do
      if [ "$dirname" = "$allowed" ]; then
        found=true
        break
      fi
    done
    if [ "$found" = false ]; then
      echo "ERROR: Unexpected hidden directory at root: $dirname/"
      ERRORS=$((ERRORS + 1))
    fi
  fi
done

for entry in "$REPO_ROOT"/*; do
  if [ -f "$entry" ]; then
    filename="$(basename "$entry")"
    is_ignored "$entry" && continue
    found=false
    for allowed in "${ALLOWED_FILES[@]}"; do
      if [ "$filename" = "$allowed" ]; then
        found=true
        break
      fi
    done
    if [ "$found" = false ]; then
      echo "ERROR: Unexpected file at root: $filename"
      ERRORS=$((ERRORS + 1))
    fi
  fi
done

for entry in "$REPO_ROOT"/.[^.]*; do
  if [ -f "$entry" ]; then
    filename="$(basename "$entry")"
    is_ignored "$entry" && continue
    found=false
    for allowed in "${ALLOWED_FILES[@]}"; do
      if [ "$filename" = "$allowed" ]; then
        found=true
        break
      fi
    done
    if [ "$found" = false ]; then
      echo "ERROR: Unexpected hidden file at root: $filename"
      ERRORS=$((ERRORS + 1))
    fi
  fi
done

if [ $ERRORS -eq 0 ]; then
  echo "Root structure: OK"
  exit 0
else
  echo "Root structure: $ERRORS error(s)"
  exit 1
fi
