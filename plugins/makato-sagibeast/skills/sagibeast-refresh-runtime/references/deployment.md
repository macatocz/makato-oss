# Deployment discovery and refresh commands

Run commands on the selected Docker host. Values below are shell variables populated from observed
metadata, not literal defaults. Use Bash arrays to preserve argument boundaries.

## Read-only discovery

```bash
docker compose ls --format json
docker ps --format '{{.Names}}\t{{.Image}}\t{{.Status}}'
docker inspect "$CONTAINER" --format '{{json .Mounts}}'
docker inspect "$CONTAINER" --format '{{index .Config.Labels "com.docker.compose.project"}}'
docker inspect "$CONTAINER" --format '{{index .Config.Labels "com.docker.compose.project.working_dir"}}'
docker inspect "$CONTAINER" --format '{{index .Config.Labels "com.docker.compose.project.config_files"}}'
docker inspect "$CONTAINER" --format '{{.Image}} {{.State.StartedAt}} {{.HostConfig.NetworkMode}}'
git -C "$REPO" status --porcelain=v1
git -C "$REPO" rev-parse HEAD
git -C "$REPO" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}'
```

Resolve symlinks/mounts and inspect repository deployment instructions. Compose labels may point to
files that have moved; verify every path. Identify env files and profiles from the launch
configuration without printing secret values. List service names using `config --services`; inspect
only relevant fields of effective configuration rather than dumping interpolated secrets.

## Safe tracked-branch refresh

Only after a clean-tree check and acquiring the deployment mechanism's actual exclusivity:

```bash
OLD_SHA=$(git -C "$REPO" rev-parse HEAD)
BRANCH=$(git -C "$REPO" symbolic-ref --short HEAD)
REMOTE=$(git -C "$REPO" config --get "branch.$BRANCH.remote")
git -C "$REPO" fetch "$REMOTE"
TARGET_SHA=$(git -C "$REPO" rev-parse '@{upstream}^{commit}')
git -C "$REPO" merge --ff-only "$TARGET_SHA"
```

Check each command's exit status; do not continue after failure. Detached HEAD, a local upstream
(remote `.`), missing upstream, or divergent history needs an explicit deployment target. A fetch
updates references, so it is not part of check-only mode.

## Targeted Compose rollout

Build `DC` from the discovered working directory, project and ordered config files. Include the
original env-file/profile arguments. Run in that working directory for relative paths.

```bash
DC=(docker compose --project-directory "$COMPOSE_DIR" -p "$PROJECT")
for file in "${COMPOSE_FILES[@]}"; do DC+=(-f "$file"); done
# Add discovered --env-file and --profile arguments before these operations.
"${DC[@]}" config --services
"${DC[@]}" build "${BUILD_SERVICES[@]}"
"${DC[@]}" pull "${PULL_SERVICES[@]}"
"${DC[@]}" up -d --no-deps --force-recreate "${APPLICATION_SERVICES[@]}"
# Run the repository's readiness checks before replacing namespace dependents.
"${DC[@]}" up -d --no-deps --force-recreate "${NETWORK_DEPENDENTS[@]}"
"${DC[@]}" ps --all
```

Run each array-based operation only when that array is nonempty; empty service lists otherwise
select the entire project. Partition services by actual build/image policy. `--no-deps` requires
prerequisites already healthy; it does not perform migrations. Apply dependency-ordered batches
where application services depend on each other. The supported deploy script takes precedence when
it already implements this safely.

## Sagibeast-specific checks

- Vast deployments may use base, dev, documents and vast overlays, plus an optional GPU overlay.
  Derive the actual list; do not assume every environment uses all five.
- The live checkout may be `/opt/sagibeast`, while CI runs under an actions-runner worktree.
  Container bind mounts identify which code is served.
- Discover `fastapi-brain`, `fastapi-body`, `docs-manager`, `temporal-worker`, and
  `temporal-platform-worker` rather than omitting a worker from refresh.
- `frontend` and `docs-manager-proxy` may share Brain's network namespace. Recreate them after the
  new Brain is ready; otherwise they can retain the removed container's network namespace.
- Read the current `scripts/vast-start-sagibeast.sh` or deployment entrypoint if present. It may
  include provisioning/secret operations beyond a targeted refresh.
- Streamlit can retain imported Python modules across script reruns. A mounted new `app.py` does not
  prove the process uses a matching `api_client.py`; recreate the service.
- The historical chat mismatch was `query_stream(..., top_k=...)` against a client without that
  parameter. Compare actual caller/signature and traceback timestamps before editing code.
- Health at `/docs-manager/_stcore/health` proves Streamlit readiness only. Verify authenticated
  `/import` chat separately through the public route, using the configured TLS trust chain.
