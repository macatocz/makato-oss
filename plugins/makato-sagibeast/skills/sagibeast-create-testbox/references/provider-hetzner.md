# Hetzner Provider Reference — sagibeast-testbox

Substrate-specific commands for provisioning on Hetzner Cloud.
Load this file ONLY when provisioning on Hetzner; skip for Multipass or EC2.

## Instance selection

| Tier | Instance | vCPU | RAM | Disk | Notes |
| --- | --- | --- | --- | --- | --- |
| Minimum (Compose only) | `cx41` | 8 | 16 GB | built-in + volume | `cx31` (8 GB RAM) is too small — OOM kills on Temporal worker |
| Recommended (Compose + k3d) | `cx51` | 16 | 32 GB | 400 GB volume | Full E2E + K8s parity |

Source: `references/sizing-guide.md` — load sizing-guide.md for the full disk/RAM breakdown.

**Never use `cx31` (8 GB RAM).** Under a full Compose stack, the Temporal worker and bge-m3 ONNX
inference together require 8–12 GB, leaving no headroom. `cx31` OOMs before the first E2E test
completes. Use `cx41` (16 GB) as the hard minimum.

## Launch command

```bash
hcloud server create \
  --name sagibeast-testbox \
  --type cx41 \
  --image ubuntu-24.04 \
  --user-data-from-file /tmp/sagibeast-cloud-init.yaml \
  --location fsn1
```

Add a detached volume for Docker storage if the base image disk is insufficient:

```bash
hcloud volume create --name sagibeast-data --size 128 --server sagibeast-testbox
# On the server, format and mount:
mkfs.ext4 /dev/disk/by-id/scsi-0HC_Volume_<ID>
mount /dev/disk/by-id/scsi-0HC_Volume_<ID> /var/lib/docker
```

## Retrieve IP (for SSH config step [4/5])

```bash
TESTBOX_IP=$(hcloud server ip sagibeast-testbox)
echo "Add to ~/.ssh/config: HostName ${TESTBOX_IP}"
```

## Replace multipass commands

| Multipass command | Hetzner equivalent |
| --- | --- |
| `multipass transfer <src> sagibeast-testbox:<dst>` | `scp <src> ubuntu@${TESTBOX_IP}:<dst>` |
| `multipass exec sagibeast-testbox -- <cmd>` | `ssh ubuntu@${TESTBOX_IP} -- <cmd>` |
| `multipass info sagibeast-testbox` | `hcloud server describe sagibeast-testbox` |

## Teardown

```bash
hcloud server delete sagibeast-testbox
```
