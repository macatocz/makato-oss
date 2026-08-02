#!/usr/bin/env bash
# manage-stores.sh — register, list, and remove cross-repo store entries in .claude/config.json
#
# Usage:
#   manage-stores.sh register <id> <repo> <description>
#   manage-stores.sh list
#   manage-stores.sh remove <id>
#
#   The config file path can be overridden via MANAGE_STORES_CONFIG (used by tests).
#   Default: <repo-root>/.claude/config.json
#
# Behaviour:
#   register  Appends { "id": ..., "repo": ..., "description": ... } to stores[].
#             If an entry with the same id already exists, it is updated in-place.
#             If .claude/config.json does not exist it is created with an empty stores: [].
#   list      Prints all store entries, one per line: "id  repo  description"
#   remove    Removes the entry with the given id.  Exits 1 if id is not found.
#
# Dependencies: bash, python3 (stdlib only — json module)
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo ".")"
CONFIG_FILE="${MANAGE_STORES_CONFIG:-$REPO_ROOT/.claude/config.json}"

CMD="${1:-}"

usage() {
  cat >&2 << 'EOF'
usage: manage-stores.sh <command> [args]

Commands:
  register <id> <repo> <description>   Add or update a store entry
  list                                  List all store entries
  remove <id>                           Remove a store entry by id
EOF
  exit 1
}

[[ -z "$CMD" ]] && usage

case "$CMD" in
  register)
    ID="${2:-}"
    REPO_ARG="${3:-}"
    DESC="${4:-}"
    [[ -z "$ID" || -z "$REPO_ARG" || -z "$DESC" ]] && {
      echo "manage-stores: register requires: <id> <repo> <description>" >&2
      exit 1
    }
    python3 - "$CONFIG_FILE" "$ID" "$REPO_ARG" "$DESC" << 'PY'
import json, sys, os

config_path, store_id, repo, description = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]

# Create config with empty stores[] if it does not exist
if not os.path.exists(config_path):
    data = {"stores": []}
else:
    try:
        with open(config_path, encoding="utf-8") as fh:
            data = json.load(fh)
    except (json.JSONDecodeError, ValueError) as exc:
        print(f"manage-stores: malformed JSON in {config_path}: {exc}", file=sys.stderr)
        sys.exit(1)

if "stores" not in data or not isinstance(data["stores"], list):
    data["stores"] = []

stores = data["stores"]
new_entry = {"id": store_id, "repo": repo, "description": description}

# Update in-place if id already present; otherwise append
for i, entry in enumerate(stores):
    if entry.get("id") == store_id:
        stores[i] = new_entry
        break
else:
    stores.append(new_entry)

data["stores"] = stores

os.makedirs(os.path.dirname(os.path.abspath(config_path)), exist_ok=True)
with open(config_path, "w", encoding="utf-8") as fh:
    json.dump(data, fh, indent=2, ensure_ascii=False)
    fh.write("\n")
PY
    ;;

  list)
    python3 - "$CONFIG_FILE" << 'PY'
import json, sys, os

config_path = sys.argv[1]

if not os.path.exists(config_path):
    sys.exit(0)

try:
    with open(config_path, encoding="utf-8") as fh:
        data = json.load(fh)
except (json.JSONDecodeError, ValueError) as exc:
    print(f"manage-stores: malformed JSON in {config_path}: {exc}", file=sys.stderr)
    sys.exit(1)

stores = data.get("stores", [])
for entry in stores:
    store_id = entry.get("id", "")
    repo = entry.get("repo", "")
    desc = entry.get("description", "")
    print(f"{store_id}\t{repo}\t{desc}")
PY
    ;;

  remove)
    ID="${2:-}"
    [[ -z "$ID" ]] && {
      echo "manage-stores: remove requires: <id>" >&2
      exit 1
    }
    python3 - "$CONFIG_FILE" "$ID" << 'PY'
import json, sys, os

config_path, store_id = sys.argv[1], sys.argv[2]

if not os.path.exists(config_path):
    print(f"manage-stores: no store with id '{store_id}' found (config not found)", file=sys.stderr)
    sys.exit(1)

try:
    with open(config_path, encoding="utf-8") as fh:
        data = json.load(fh)
except (json.JSONDecodeError, ValueError) as exc:
    print(f"manage-stores: malformed JSON in {config_path}: {exc}", file=sys.stderr)
    sys.exit(1)

stores = data.get("stores", [])
original_len = len(stores)
stores = [s for s in stores if s.get("id") != store_id]

if len(stores) == original_len:
    print(f"manage-stores: no store with id '{store_id}' found", file=sys.stderr)
    sys.exit(1)

data["stores"] = stores
with open(config_path, "w", encoding="utf-8") as fh:
    json.dump(data, fh, indent=2, ensure_ascii=False)
    fh.write("\n")
PY
    ;;

  *)
    echo "manage-stores: unknown command '${CMD}'" >&2
    usage
    ;;
esac
