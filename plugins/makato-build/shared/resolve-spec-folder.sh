#!/usr/bin/env bash
# Resolve a work-item key to one spec folder.
# Exact folder wins; numeric issue keys can resolve through created-issues.json;
# otherwise a single matching key-prefix folder is accepted.
set -u

if [[ "$#" -ne 2 ]]; then
  echo "usage: resolve-spec-folder.sh <specs-dir> <key>" >&2
  exit 64
fi

specs_dir="$1"
key="$2"
exact="$specs_dir/$key"

if [[ -d "$exact" ]]; then
  printf '%s\n' "$exact"
  exit 0
fi

if [[ "$key" =~ ^[0-9]+$ ]]; then
  if ! command -v jq >/dev/null 2>&1; then
    echo "resolve-spec-folder: jq is required to map issue #$key through created-issues.json" >&2
    exit 69
  fi

  local_owners=()
  while IFS= read -r -d '' manifest; do
    if jq -e --arg issue "$key" \
      'any(.issues[]?; (.issue_number | tostring) == $issue)' \
      "$manifest" >/dev/null 2>&1; then
      local_owners+=("${manifest%/created-issues.json}")
    fi
  done < <(find "$specs_dir" -mindepth 2 -maxdepth 2 -type f -name 'created-issues.json' -print0 2>/dev/null)

  if ((${#local_owners[@]} > 1)); then
    printf 'resolve-spec-folder: issue #%s appears in multiple created-issues.json files:\n' "$key" >&2
    printf '  %s\n' "${local_owners[@]}" >&2
    exit 2
  fi
  if ((${#local_owners[@]} == 1)); then
    printf '%s\n' "${local_owners[0]}"
    exit 0
  fi
fi

matches=()
for candidate in "$specs_dir/${key}"-*/; do
  [[ -d "$candidate" ]] && matches+=("${candidate%/}")
done

if ((${#matches[@]} > 1)); then
  printf 'resolve-spec-folder: ambiguous spec folders for key %q under %s:\n' "$key" "$specs_dir" >&2
  printf '  %s\n' "${matches[@]}" >&2
  exit 2
fi
if ((${#matches[@]} == 1)); then
  printf '%s\n' "${matches[0]}"
  exit 0
fi

printf "resolve-spec-folder: no spec folder found for '%s' under %s\n" "$key" "$specs_dir" >&2
exit 1
