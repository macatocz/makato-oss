# macOS / Apple Silicon: OpenAI, Qwen, and local-Ollama quick-start

This guide is for a **Mac (Apple Silicon) client** that orchestrates the makato
autonomous loop and needs to select which model provider it talks to. It complements
[`docs/vast-ai-llm-deployment.md`](./vast-ai-llm-deployment.md) (which provisions the
remote Linux/NVIDIA vLLM endpoint) and the root [`README.md`](../README.md#provider-switching)
(which documents the profile-switch commands at the whole-repo level).

Three provider profiles are supported, declared in
[`config/model-profiles.yml`](../config/model-profiles.yml) and resolved/validated by
[`scripts/resolve-model-profile.py`](../scripts/resolve-model-profile.py):

| Profile | Where inference runs | Endpoint | Credential | Tool format |
| --- | --- | --- | --- | --- |
| `qwen-vllm` (default) | Local or **remote Linux/NVIDIA** | `http://localhost:8100/v1` (override `MAKATO_OPEN_ENDPOINT_URL` / `VLLM_API_BASE`) | none | `qwen3` |
| `openai` | Native OpenAI cloud API | `https://api.openai.com/v1` | `OPENAI_API_KEY` | `openai` |
| `apple-ollama` | **Apple Silicon, local** | `http://localhost:11434/v1` (override `MAKATO_APPLE_OLLAMA_BASE_URL`) | none | `openai` |

## Topology: Mac client vs. remote inference

- **The Mac always orchestrates.** `omp`/`claude` and the `makato-orchestrate:loop` skill
  run on the Mac (or in CI) regardless of which profile is active — this is the client
  side of every setup below.
- **`apple-ollama` runs inference locally on the same Mac** via `ollama serve`, using its
  OpenAI-compatible HTTP API. No network egress, no credential.
- **`openai` sends inference requests to `api.openai.com`.** Requires `OPENAI_API_KEY`
  and outbound network access; nothing runs locally beyond the orchestrator.
- **`qwen-vllm` normally means a remote Linux/NVIDIA box serves inference** (vLLM requires
  CUDA — there is no Apple Silicon vLLM path in this repo). The Mac reaches that box over
  SSH tunnel, VPN, or a private network; `infra/bootstrap-vllm.sh` and
  `infra/vllm-serve.sh` both refuse to run on Darwin, and `scripts/macos-setup.sh` never
  attempts to install CUDA/vLLM — that boundary is intentional, not a missing feature.

## Mac quick-start

Run this once per Mac, from a clone of this repository:

```bash
git clone https://github.com/zstary/makato.git
cd makato
bash scripts/macos-setup.sh --dry-run   # report-only: what's missing, nothing installed
```

`scripts/macos-setup.sh`:

- Refuses to run on a non-Darwin host, and warns (does not fail) on non-`arm64` Macs.
- Reports (or, with `--install`, Homebrew-installs) Bash ≥4, Python 3.14, Node.js, `gh`,
  `jq`, OMP (`oh-my-pi`), and Docker Desktop.
- Checks (or installs) the selected model profile via `scripts/select-model-profile.sh`
  — default `qwen-vllm`, override with `--profile` or `MAKATO_MODEL_PROFILE`.
- **Never** installs CUDA or vLLM locally, on any architecture.

```bash
bash scripts/macos-setup.sh --dry-run --profile qwen-vllm    # preview, default profile
bash scripts/macos-setup.sh --install --profile openai        # install tools + openai profile
```

macOS ships Bash 3.2 at `/bin/bash`, which this repo's scripts do not support (associative
arrays, `${BASH_VERSINFO[0]}` etc. need Bash ≥4). `scripts/macos-setup.sh` checks this
explicitly and tells you to `brew install bash` and put `/opt/homebrew/bin` ahead of
`/usr/bin` on `PATH` — see § Troubleshooting below if you hit a syntax error instead.

## Apple Silicon local profile (`apple-ollama`)

Runs inference entirely on the Mac via [Ollama](https://ollama.com)'s OpenAI-compatible
API. Ollama itself is not installed by `scripts/macos-setup.sh` — install and start it,
then pull the models the profile's roles reference (`llama3.1`, `llama3.2`):

```bash
brew install ollama
ollama serve &                 # or: open -a Ollama
ollama pull llama3.1
ollama pull llama3.2
```

Preview, then install the profile (no credential required):

```bash
bash scripts/select-model-profile.sh apple-ollama --dry-run
bash scripts/select-model-profile.sh apple-ollama
```

Run the mandatory Gate 6 preflight before dispatching the PO-agent:

```bash
MAKATO_MODEL_PROFILE=apple-ollama bash scripts/preflight-model-runtime.sh
```

If `ollama serve` is not running, this fails fast with `endpoint unreachable` and the
`ollama serve` remediation hint — see § Troubleshooting.

## Native OpenAI setup (`openai`)

Requires an OpenAI account and an API key. The key is a **runtime input only** — never
put it in a repository file, fixture, or `build.jsonl`.

```bash
bash scripts/select-model-profile.sh openai --dry-run   # preview — no key needed
export OPENAI_API_KEY=sk-...                             # your shell session only
bash scripts/select-model-profile.sh openai              # writes ~/.omp/agent/{models,config}.yml
MAKATO_MODEL_PROFILE=openai bash scripts/preflight-model-runtime.sh
```

`scripts/resolve-model-profile.py` and `scripts/select-model-profile.sh` never read or
print `OPENAI_API_KEY`'s value — only whether it is set. The value is substituted directly
into `~/.omp/agent/models.yml` (mode `600`) at install time and is never echoed to stdout,
stderr, or any log.

## Remote Linux/Qwen (client-side from a Mac)

`qwen-vllm` normally points at a remote Linux/NVIDIA box provisioned per
[`docs/vast-ai-llm-deployment.md`](./vast-ai-llm-deployment.md). From the Mac, either open
an SSH tunnel to the box's local-only port 8100 or reach it over a private network the box
already exposes, then point the profile at that address:

```bash
# Example: tunnel a remote box's local-only vLLM port to this Mac
ssh -N -L 8100:localhost:8100 -p "$VAST_SSH_PORT" -i "$VAST_SSH_KEY" "root@$VAST_HOST" &

bash scripts/select-model-profile.sh qwen-vllm --dry-run   # preview — no credential needed
bash scripts/select-model-profile.sh qwen-vllm             # install (still no credential)

MAKATO_MODEL_PROFILE=qwen-vllm VLLM_API_BASE=http://localhost:8100 \
  bash scripts/preflight-omp-context.sh
MAKATO_MODEL_PROFILE=qwen-vllm bash scripts/preflight-model-runtime.sh
```

`VLLM_API_BASE` (or `MAKATO_OPEN_ENDPOINT_URL`) overrides only where the client looks for
the endpoint — it does not change the profile's declared role/tool-format contract, so a
mismatched `~/.omp/agent/config.yml` (wrong `tools.format`, wrong role mapping) still fails
the preflight with an actionable error naming the exact expected value.

## Optional-service setup

`scripts/preflight-optional-services.sh` checks Playwright MCP, Langfuse, Postgres,
Temporal, and Sagibeast/testbox connectivity. **None of these are required** for the core
autonomous loop or for any provider profile — each one is either `PASS`, `SKIP` (not
configured), or `WARN` (configured but unreachable). A missing or unreachable optional
service is **never** reported as healthy, and it **never** blocks Gate 6 or the loop:

```bash
bash scripts/preflight-optional-services.sh
```

| Service | Local vs. remote | Env input | Default when unset |
| --- | --- | --- | --- |
| Playwright MCP | local (stdio subprocess via `npx`) | `PLAYWRIGHT_MCP_CONFIG` | `plugins/makato-ux/.mcp.json`; `SKIP` if missing/invalid, `WARN` if `npx` is absent |
| Langfuse OTLP | local or remote (classified by hostname) | `LANGFUSE_OTLP_ENDPOINT` | `SKIP` if unset — see [`infra/docker-compose.langfuse.yml`](../infra/docker-compose.langfuse.yml) for a local Docker Desktop stack |
| Postgres | local or remote | `POSTGRES_URL` (or `LANGFUSE_DATABASE_URL`) | `SKIP` if unset |
| Temporal | local or remote | `TEMPORAL_ADDRESS` (`host:port`) | `SKIP` if unset |
| Sagibeast/testbox | remote (SSH) | `SAGIBEAST_SSH_HOST` (default `sagibeast.testbox`), `SAGIBEAST_SSH_CONFIG` | `SKIP` if no matching `Host` alias in `~/.ssh/config` |

Any credential embedded in a connection string (e.g. a Postgres DSN's `user:pass@`) is
redacted before being printed — see `redact_url` in
[`scripts/preflight-optional-services.sh`](../scripts/preflight-optional-services.sh).

To run the Langfuse/Postgres stack locally on a Mac, use Docker Desktop with
[`infra/docker-compose.langfuse.yml`](../infra/docker-compose.langfuse.yml); this repo does
not require it to be running for any of the three model profiles above.

## Troubleshooting matrix

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| `ERROR: profile 'openai' requires credential env var OPENAI_API_KEY to be set before install (value not shown)` | `OPENAI_API_KEY` unset in the shell running `select-model-profile.sh`/`preflight-omp-context.sh` | `export OPENAI_API_KEY=sk-...` in that shell first; the message never reveals a value because none is ever read until this exact check |
| `ERROR: endpoint unreachable — http://localhost:11434/v1/models` | `ollama serve` is not running, or the wrong port/profile is selected | Start Ollama (`ollama serve` / `open -a Ollama`); confirm `MAKATO_APPLE_OLLAMA_BASE_URL` if overridden |
| `ERROR: endpoint unreachable — http://localhost:8100/v1/models` | Remote vLLM box down, SSH tunnel not open, or `VLLM_API_BASE` pointing at the wrong host | Re-open the tunnel; `systemctl status vllm` on the remote box (see `docs/vast-ai-llm-deployment.md`) |
| `ERROR: OMP tools.format must be 'openai' for profile 'apple-ollama' ... (got 'qwen3')` (or similar) | `~/.omp/agent/config.yml` still reflects a previously-installed profile | Rerun `bash scripts/select-model-profile.sh <intended-profile>` (a real install, not `--dry-run`) |
| `ERROR: OMP model configuration not found at ~/.omp/agent/models.yml` | Preflight run before any profile was ever installed | Run `bash scripts/select-model-profile.sh <profile>` once before `scripts/preflight-model-runtime.sh` |
| `MISSING: Bash on PATH is 3.x (need >=5)` or a script fails with an obscure syntax error on macOS | Using macOS's shipped `/bin/bash` 3.2 | `brew install bash`; ensure `/opt/homebrew/bin` precedes `/usr/bin` on `PATH` |
| `infra/bootstrap-vllm.sh` or `infra/vllm-serve.sh` exits immediately with a Darwin/Linux error | Attempting to provision CUDA/vLLM locally on a Mac | These are remote Linux/NVIDIA-only by design; use `scripts/macos-setup.sh` on the Mac and `docs/vast-ai-llm-deployment.md` on the remote box instead |
| Loop won't dispatch after a crash / stale `active_workflow` | `.claude/state/loop-status.json` retains a stale in-flight marker, or `last_session_id` in `workflow-state.json` no longer matches a live session | Clear the stale marker with the `jq`+`sponge` command in root `README.md` § *Recover from a stale active_workflow*; if `--resume <session_id>` fails because the session no longer exists, the stall-resume path skips with `reason:"no_session_id"` in `orchestrate.jsonl` and a fresh dispatch starts instead — this is expected, not a bug |
| Autonomous dispatch silently does nothing headlessly | `MAKATO_HEADLESS=1` was not exported alongside `--autonomous`/`$AGENT_ID` | Every headless caller (`loop.sh`, `context-handoff.sh`) must export `MAKATO_HEADLESS=1`; see `plugins/makato-build/AUTONOMOUS-MODE.md` § *Defensive-headless guard* |

## See also

- [Root `README.md` § Provider switching](../README.md#provider-switching) — the
  whole-repo profile-switch command reference.
- [`docs/vast-ai-llm-deployment.md`](./vast-ai-llm-deployment.md) — the full remote
  Linux/NVIDIA runbook this guide's remote-Qwen section points a Mac client at.
- [`plugins/makato-orchestrate/README.md`](../plugins/makato-orchestrate/README.md) —
  harness adapter, profile propagation, and session-resume contract for the autonomous
  loop.
- [`docs/contracts/runtime-verification/43-model-provider-autonomous-ac.md`](./contracts/runtime-verification/43-model-provider-autonomous-ac.md)
  — the offline acceptance evidence for the complete provider-neutral autonomous flow,
  including the opt-in live-path activation contract.
