# Testbox Sizing Guide

Substrate-agnostic disk-and-RAM math for a sagibeast testbox running the
full test stack (Ubuntu 24.04, Docker, k3d optional).

## Summary

| Layer | Disk | RAM |
| --- | --- | --- |
| Ubuntu 24.04 base OS | ~6 GB | 1 GB idle |
| Docker layer cache (sagibeast full stack) | ~22 GB | — |
| k3d image cache (optional, dev-tier K8s parity) | ~8 GB | 2 GB idle cluster |
| pgvector + bge-m3 model weights + indexes | ~12 GB | 4–8 GB peak |
| Test artefacts, logs, golden files | ~4 GB | — |
| **Total minimum recommended** | **64 GB** | **16 GB** |

## Disk breakdown

### Ubuntu 24.04 base (~6 GB)

A fresh Ubuntu 24.04 server installation with `apt upgrade` occupies roughly
5–6 GB. This includes the kernel, base libraries, and systemd units installed
by cloud-init packages (`docker.io`, `fail2ban`, `step-cli`, `1password-cli`,
`python3-pip`, etc.).

### Docker layer cache — sagibeast full stack (~22 GB)

The full `docker compose -f infra/docker-compose.yml` stack pulls:

| Image | Compressed pull size |
| --- | --- |
| `pgvector/pgvector:pg16` (×2, Brain + Body) | ~400 MB |
| `minio/minio` (×2, Brain-S3 + Body-S3) | ~200 MB |
| `temporalio/auto-setup` | ~1.2 GB |
| `ghcr.io/zitadel/zitadel` | ~180 MB |
| Langfuse (web + worker + clickhouse + redis) | ~3 GB |
| `hashicorp/vault` / `openbao/openbao` (×2) | ~200 MB |
| FastAPI Brain + FastAPI Body (project images) | ~1.5 GB |
| Temporal worker (project image) | ~1.5 GB |
| `tesseract` OCR service | ~800 MB |
| OS-level unpack overhead (2–3× compressed) | — |

Docker stores layers uncompressed on disk. With the 2–3× unpack factor, the
full stack occupies approximately **18–22 GB** of Docker storage
(`/var/lib/docker`).

### k3d image cache (~8 GB, optional)

If `--with-k3d` is passed to `bootstrap.sh`, a single-node k3d cluster pulls:

| Image | Size |
| --- | --- |
| `rancher/k3s` | ~300 MB compressed (~800 MB unpacked) |
| Helm + cert-manager | ~400 MB |
| Any workload images deployed to the cluster | variable |

Reserve **8 GB** for a minimal k3d node with standard workloads. If you deploy
the full sagibeast stack into k3d (rare — only for Kubernetes-shape parity tests
per ADR-0023), add the Docker stack sizes above.

### pgvector + bge-m3 model weights + indexes (~12 GB)

| Component | Size |
| --- | --- |
| bge-m3 ONNX weights (float32) | ~2.3 GB |
| bge-m3 ONNX weights (quantised INT8) | ~560 MB |
| pgvector HNSW indexes (per-tenant, sparse at test time) | ~100 MB |
| LiteLLM local proxy config + cache | ~200 MB |
| Sentence-transformers model cache | ~2 GB |
| **Subtotal** | **~5–7 GB** |

With a running Brain-PG holding HNSW indexes across multiple test tenants, the
resident set grows. Budget **12 GB** for the combined model-weights + index
footprint during a full E2E run.

### Test artefacts, logs, golden files (~4 GB)

| Artefact | Typical size |
| --- | --- |
| `tests/fixtures/golden/` (xlsm + JSON snapshots) | ~500 MB |
| pytest JUnit XML + coverage reports | ~50 MB |
| Docker compose logs retained between runs | ~500 MB |
| Langfuse trace exports (CI artefacts) | ~1 GB |
| Misc (pip wheel cache, tmp files) | ~2 GB |

## RAM breakdown

| Workload | RSS at peak |
| --- | --- |
| Ubuntu OS + systemd | ~1 GB |
| Docker daemon + containers (full stack, idle) | ~6–8 GB |
| pgvector Brain-PG + Body-PG under test load | ~2–3 GB |
| bge-m3 inference (ONNX Runtime) | ~4–6 GB |
| Temporal worker + LangGraph execution | ~2–3 GB |
| k3d single-node (if running) | ~2 GB |
| pytest runner + test process | ~500 MB |
| **Total peak (without k3d)** | **~16–22 GB** |
| **Total peak (with k3d)** | **~18–24 GB** |

### Recommended specifications

| Tier | CPUs | RAM | Disk | Notes |
| --- | --- | --- | --- | --- |
| Minimum (Compose only) | 4 vCPU | 16 GB | 64 GB | No k3d; bge-m3 quantised |
| Recommended (Compose + k3d) | 8 vCPU | 32 GB | 128 GB | Full E2E + K8s parity |
| Team-shared rig | 16 vCPU | 64 GB | 256 GB | Multiple developers, nightly cron |

The default `multipass launch` arguments in `sagibeast-create-testbox` provision
`--cpus 4 --memory 8G --disk 64G`. This is the **absolute minimum** for a single-
developer testbox running Compose without k3d. Upgrade to 16 GB RAM if you observe
OOM kills in the Temporal worker or LangGraph execution.

## Cloud instance equivalents

| Provider | Instance | vCPU | RAM | Notes |
| --- | --- | --- | --- | --- |
| AWS | `m7g.xlarge` (Graviton3) | 4 | 16 GB | ARM64; add 64 GB EBS gp3 |
| AWS | `m7g.2xlarge` | 8 | 32 GB | Recommended for k3d runs |
| Hetzner | `cx31` | 2 | 8 GB | Too small; use `cx41` (8 vCPU / 16 GB) |
| Hetzner | `cx41` | 8 | 16 GB | Minimum viable |
| Multipass (local) | default profile | 4 | 8 GB | macOS host needs ≥ 32 GB RAM total |

## Disk reclaim

If the testbox accumulates stale Docker layers between runs:

```bash
# Remove unused images, containers, networks, build cache
docker system prune -af

# Also remove volumes (WARNING: drops all PG data)
docker system prune -af --volumes
```

For a full reset without re-provisioning, `docker system prune` frees the largest
single source of wasted disk.
