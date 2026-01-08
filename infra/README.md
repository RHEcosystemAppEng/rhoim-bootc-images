# RHOIM Infrastructure

OpenTofu configurations for deploying AWS infrastructure to build and test RHEL bootc images with GPU support.

**Quick Links:** [Quick Start](#quick-start) | [Builder Specs](#builder-infrabuilder) | [Tester Specs](#tester-infratester) | [Usage](#usage) | [Troubleshooting](#troubleshooting)

---

## Overview

This infrastructure provides two machine types:

| Machine | Purpose | Instance Type | Key Features |
|---------|---------|---------------|--------------|
| **Builder** | Build container images | m6i.xlarge | Fast CPU, large disk, registry auth |
| **Tester** | Run/test GPU workloads | g4dn.xlarge | NVIDIA T4 GPU, CUDA drivers |

## Machine Specifications

### Builder (`infra/builder/`)

Purpose: Build bootc container images with podman/buildah.

| Specification | Value |
|---------------|-------|
| Instance Type | m6i.xlarge |
| vCPUs | 4 |
| Memory | 16 GB |
| Storage | 200 GB gp3 (encrypted) |
| OS | RHEL 9.6 |
| GPU | None |

**Pre-installed Software:**
- podman, buildah, skopeo
- bootc, osbuild, lorax
- git, make, jq, vim, tmux
- AWS CLI v2

**Pre-configured:**
- Red Hat Subscription Manager (CDN repos for container builds)
- Registry authentication (registry.redhat.io, quay.io)
- NVIDIA and CUDA repos (for building GPU images)
- Helper functions: `build-with-repos`, `build-iso`

### Tester (`infra/tester/`)

Purpose: Run and test GPU-accelerated bootc images and containers.

| Specification | Value |
|---------------|-------|
| Instance Type | g4dn.xlarge |
| vCPUs | 4 |
| Memory | 16 GB |
| GPU | NVIDIA Tesla T4 (16 GB VRAM) |
| Storage | 200 GB gp3 (encrypted) |
| OS | RHEL 9.6 |

**Pre-installed Software:**
- podman, skopeo, bootc
- NVIDIA Driver 570 (precompiled modules)
- NVIDIA Container Toolkit
- CDI configuration for GPU containers

**Automated Setup:**
1. Installs NVIDIA drivers and container toolkit
2. Pins kernel to version with precompiled NVIDIA modules
3. Reboots to load drivers
4. Generates CDI config and sets GPU permissions

## Directory Structure

```
infra/
├── README.md              # This file
├── builder/               # Builder machine configuration
│   ├── main.tf
│   └── terraform.tfvars   # Your configuration (git-ignored)
├── tester/                # Tester machine configuration
│   ├── main.tf
│   └── terraform.tfvars   # Your configuration (git-ignored)
└── modules/
    └── aws-network/       # Shared networking module
        ├── main.tf
        ├── outputs.tf
        └── versions.tf
```

## Shared Module: aws-network

The `aws-network` module provides common networking configuration used by both machine types. It queries the default VPC and subnets in your AWS account.

**Outputs:**
| Output | Description |
|--------|-------------|
| `vpc_id` | ID of the default VPC |
| `subnet_ids` | List of all subnet IDs in the default VPC |
| `first_subnet_id` | First subnet ID (used for single-instance deployments) |

**Usage in configurations:**
```hcl
module "network" {
  source = "../modules/aws-network"
}

resource "aws_instance" "example" {
  subnet_id = module.network.first_subnet_id
  vpc_security_group_ids = [aws_security_group.example.id]
  # ...
}
```

## Prerequisites

1. **AWS CLI** configured with credentials
2. **OpenTofu** v1.6+ installed (`brew install opentofu`)
3. **SSH Key Pair** in AWS

## Quick Start

### 1. Create AWS Key Pair (if needed)

```bash
aws ec2 create-key-pair \
  --key-name your-name-rhoim \
  --key-type ed25519 \
  --region us-east-1 \
  --query 'KeyMaterial' \
  --output text > ~/.ssh/your-name-rhoim.pem

chmod 600 ~/.ssh/your-name-rhoim.pem
```

### 2. Configure Variables

Each machine type has its own directory. Navigate to the one you want to deploy:

```bash
cd infra/builder   # For builder
# OR
cd infra/tester    # For tester
```

Create `terraform.tfvars` with your configuration:

```hcl
# Common variables (both machines)
aws_region       = "us-east-1"
key_name         = "your-key-pair-name"
ssh_cidr_blocks  = ["YOUR_IP/32"]       # Get with: curl checkip.amazonaws.com
api_cidr_blocks  = ["YOUR_IP/32"]       # For vLLM API access (tester only)

# Builder-specific (see builder/main.tf for all options)
rhsm_activation_key      = "your-activation-key"
rhsm_org_id              = "your-org-id"
redhat_registry_username = "your-username"
redhat_registry_token    = "your-token"
quay_username            = "your-robot-account"
quay_token               = "your-robot-token"
```

### 3. Deploy

```bash
# Initialize OpenTofu
tofu init

# Preview changes
tofu plan

# Deploy
tofu apply
```

### 4. Connect

```bash
# Get SSH command from output
tofu output ssh_command

# Or manually
ssh -i ~/.ssh/your-key.pem ec2-user@<PUBLIC_IP>
```

## Usage

### Builder: Building Images

```bash
# SSH into builder
ssh -i ~/.ssh/your-key.pem ec2-user@<BUILDER_IP>

# Clone your repo
git clone https://github.com/your-org/your-bootc-images.git
cd your-bootc-images

# Build with RHEL CDN repos (mounts entitlements)
build-with-repos -t my-image:latest -f Containerfile .

# Push to registry
podman push my-image:latest quay.io/your-org/my-image:latest

# Build ISO from bootc image
build-iso quay.io/your-org/my-image:latest
```

### Tester: Running GPU Containers

```bash
# SSH into tester
ssh -i ~/.ssh/your-key.pem ec2-user@<TESTER_IP>

# Verify GPU is available
nvidia-smi

# Pull your bootc image
sudo podman pull quay.io/your-org/my-gpu-image:latest

# Run with GPU access
sudo podman run --rm -it --device nvidia.com/gpu=all \
  quay.io/your-org/my-gpu-image:latest nvidia-smi

# Test vLLM
sudo podman run -d --name vllm \
  --device nvidia.com/gpu=all \
  -p 8000:8000 \
  quay.io/your-org/my-vllm-image:latest
```

### Tester: bootc Switch

```bash
# Switch the host OS to your bootc image
sudo bootc switch quay.io/your-org/my-bootc-image:latest

# Reboot to apply
sudo reboot
```

## Monitoring Setup Progress

Both machines use user-data scripts for automated setup.

```bash
# Watch setup progress
sudo tail -f /var/log/user-data.log

# Check if setup completed (tester)
[ -f /var/lib/nvidia-setup-complete ] && echo "GPU ready" || echo "Setup in progress"

# Tester: Watch NVIDIA post-boot setup
sudo tail -f /var/log/nvidia-post-boot-setup.log
```

## Cost Management

| Machine | Hourly | Daily | Monthly |
|---------|--------|-------|---------|
| Builder (m6i.xlarge) | ~$0.192 | ~$4.61 | ~$138 |
| Tester (g4dn.xlarge) | ~$0.526 | ~$12.62 | ~$379 |

### Destroy When Done

```bash
cd infra/builder  # or infra/tester
tofu destroy
```

### Stop Instance (keeps EBS, lower cost)

```bash
aws ec2 stop-instances --instance-ids $(tofu output -raw instance_id)

# Resume later
aws ec2 start-instances --instance-ids $(tofu output -raw instance_id)
```

## Security

1. **Restrict IP Access**: Always set `ssh_cidr_blocks` to your IP
2. **Use Strong Key Pairs**: ed25519 keys recommended
3. **EBS Encryption**: Root volumes are encrypted by default
4. **Sensitive Variables**: Registry credentials are marked sensitive in Terraform

## Troubleshooting

### SSH Connection Issues

```bash
# Check your current IP
curl https://checkip.amazonaws.com

# Update terraform.tfvars with new IP and apply
tofu apply
```

### Builder: Registry Authentication Failed

```bash
# Re-login to registries
podman login registry.redhat.io
podman login quay.io
```

### Tester: GPU Not Available

```bash
# Check NVIDIA driver
nvidia-smi

# Check if setup completed
sudo systemctl status nvidia-post-boot-setup.service

# View setup logs
sudo journalctl -u nvidia-post-boot-setup.service

# Check CDI config
ls -la /etc/cdi/nvidia.yaml

# Check device permissions
ls -la /dev/nvidia*
```

### Tester: GPU Not Accessible in Containers

```bash
# Regenerate CDI config
sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml

# Use rootful podman (recommended for GPU)
sudo podman run --rm --device nvidia.com/gpu=all \
  docker.io/nvidia/cuda:12.3.0-base-ubi9 nvidia-smi
```
