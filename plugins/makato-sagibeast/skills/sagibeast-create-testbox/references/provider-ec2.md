# EC2 Provider Reference — sagibeast-testbox

Substrate-specific commands for provisioning on AWS EC2 (Graviton3/ARM64).
Load this file ONLY when provisioning on EC2; skip for Multipass or Hetzner.

## Instance selection

| Tier | Instance | vCPU | RAM | Disk | Notes |
| --- | --- | --- | --- | --- | --- |
| Minimum (Compose only) | `m7g.xlarge` | 4 | 16 GB | 64 GB gp3 | No k3d; bge-m3 quantised |
| Recommended (Compose + k3d) | `m7g.2xlarge` | 8 | 32 GB | 128 GB gp3 | Full E2E + K8s parity |

Source: `references/sizing-guide.md` — load sizing-guide.md for the full disk/RAM breakdown.

## Launch command

```bash
# Find the latest Ubuntu 24.04 ARM64 AMI (Canonical account 099720109477)
AWS_AMI=$(aws ec2 describe-images \
  --owners 099720109477 \
  --filters \
    'Name=name,Values=ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-arm64-server-*' \
    'Name=state,Values=available' \
  --query 'sort_by(Images,&CreationDate)[-1].ImageId' \
  --output text)

aws ec2 run-instances \
  --image-id "${AWS_AMI}" \
  --instance-type m7g.xlarge \
  --user-data file:///tmp/sagibeast-cloud-init.yaml \
  --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":64,"VolumeType":"gp3"}}]' \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=sagibeast-testbox}]'
```

## Retrieve IP (for SSH config step [4/5])

```bash
TESTBOX_IP=$(aws ec2 describe-instances \
  --filters \
    'Name=tag:Name,Values=sagibeast-testbox' \
    'Name=instance-state-name,Values=running' \
  --query 'Reservations[0].Instances[0].PublicIpAddress' \
  --output text)
echo "Add to ~/.ssh/config: HostName ${TESTBOX_IP}"
```

## Replace multipass commands

| Multipass command | EC2 equivalent |
| --- | --- |
| `multipass transfer <src> sagibeast-testbox:<dst>` | `scp <src> ubuntu@${TESTBOX_IP}:<dst>` |
| `multipass exec sagibeast-testbox -- <cmd>` | `ssh ubuntu@${TESTBOX_IP} -- <cmd>` |
| `multipass info sagibeast-testbox` | `aws ec2 describe-instances --filters 'Name=tag:Name,Values=sagibeast-testbox'` |

## Teardown

```bash
INSTANCE_ID=$(aws ec2 describe-instances \
  --filters 'Name=tag:Name,Values=sagibeast-testbox' 'Name=instance-state-name,Values=running' \
  --query 'Reservations[0].Instances[0].InstanceId' \
  --output text)
aws ec2 terminate-instances --instance-ids "${INSTANCE_ID}"
```
