# RHOIM Bootc Image - RHEL 9 Base

This directory contains the Containerfile and configuration files for building a bootc-compatible image for serving LLM models using vLLM on RHEL 9.

## Overview

- **Base Image**: `registry.redhat.io/rhel9/rhel-bootc:latest`
- **vLLM**: Built from source with CPU support (v0.11.0)
- **Python**: 3.11
- **Architecture**: aarch64 (ARM64)
- **Features**:
  - vLLM OpenAI-compatible API server
  - Systemd service management
  - SSH access enabled (root/bootc123)
  - CPU mode support (for testing without GPU)

## Prerequisites

1. **Red Hat Subscription Access**
   - Red Hat Customer Portal account
   - Activation key and Organization ID (or username/password)
   - Authenticated to `registry.redhat.io`:
     ```bash
     podman login registry.redhat.io
     ```

2. **Build Tools**
   - Podman (rootful mode recommended for bootc-image-builder)
   - `bootc-image-builder` container image
   - QEMU (for testing locally on macOS)

3. **macOS Setup** (if building on macOS)
   ```bash
   # Ensure Podman machine is rootful
   podman machine stop
   podman machine set --rootful=true
   podman machine start
   
   # Install QEMU (for testing)
   brew install qemu
   ```

## Build Instructions

### 1. Build Container Image

Build the bootc container image with vLLM:

```bash
cd /path/to/rhoim-bootc-images

podman build -t localhost/rhoim-bootc-rhel:latest \
  --build-arg RHN_ORG_ID=your_org_id \
  --build-arg RHN_ACTIVATION_KEY=your_activation_key \
  --build-arg VLLM_VERSION=0.11.0 \
  --build-arg PYTHON_VERSION=3.11 \
  -f deploy/bootc-rhel/Containerfile .
```

**Build Arguments:**
- `RHN_ORG_ID`: Your Red Hat Organization ID (required for subscription)
- `RHN_ACTIVATION_KEY`: Your Red Hat Activation Key (required for subscription)
- `VLLM_VERSION`: vLLM version to build (default: 0.11.0)
- `PYTHON_VERSION`: Python version (default: 3.11)

**Alternative: Using Username/Password**
```bash
podman build -t localhost/rhoim-bootc-rhel:latest \
  --build-arg RHN_USERNAME=your_username \
  --build-arg RHN_PASSWORD=your_password \
  --build-arg VLLM_VERSION=0.11.0 \
  --build-arg PYTHON_VERSION=3.11 \
  -f deploy/bootc-rhel/Containerfile .
```

**Note**: The build process:
- Registers the system with Red Hat subscription
- Installs Python 3.11, build tools, and SSH
- Builds vLLM from source with CPU support
- Configures systemd services for vLLM and SSH
- Takes approximately 30-60 minutes (vLLM compilation is time-consuming)

### 2. Build Bootc VM Image (qcow2)

Convert the container image to a bootable VM disk image:

```bash
mkdir -p images

podman run --rm --privileged \
  -v /var/lib/containers/storage:/var/lib/containers/storage \
  -v "$(pwd)/images":/output \
  quay.io/centos-bootc/bootc-image-builder:latest \
  --type qcow2 \
  localhost/rhoim-bootc-rhel:latest
```

**Note**: The `bootc-image-builder` tool is from CentOS Stream, but this does NOT affect the OS running inside the VM. The tool is just a converter that reads your RHEL-based bootc container image and creates a bootable disk. The VM will run RHEL 9 (from `registry.redhat.io/rhel9/rhel-bootc:latest`), not CentOS.

The bootc VM image will be created at: `images/qcow2/disk.qcow2`

**Image Size**: ~2.5 GB (compressed from ~18 GB virtual size)

## Running the Bootc VM

### On macOS (Apple Silicon)

```bash
# Boot the VM with QEMU
qemu-system-aarch64 \
  -machine virt,accel=tcg \
  -cpu cortex-a72 \
  -smp 4 \
  -m 4G \
  -drive file=images/qcow2/disk.qcow2,format=qcow2,if=virtio \
  -bios /opt/homebrew/opt/qemu/share/qemu/edk2-aarch64-code.fd \
  -netdev user,id=net0,hostfwd=tcp::8022-:22,hostfwd=tcp::8006-:8000 \
  -device virtio-net-pci,netdev=net0 \
  -serial file:/tmp/qemu-bootc.log \
  -nographic \
  -name rhoim-bootc-vm
```

**Port Forwarding:**
- SSH: `localhost:8022` → VM: `22` (root/bootc123)
- vLLM API: `localhost:8006` → VM: `8000`

### On Linux (ARM64)

```bash
qemu-system-aarch64 \
  -machine virt,accel=kvm \
  -cpu host \
  -smp 4 \
  -m 4G \
  -drive file=images/qcow2/disk.qcow2,format=qcow2,if=virtio \
  -bios /usr/share/qemu/edk2-aarch64-code.fd \
  -netdev user,id=net0,hostfwd=tcp::8022-:22,hostfwd=tcp::8006-:8000 \
  -device virtio-net-pci,netdev=net0 \
  -serial stdio
```

## Testing and Verification

### 1. SSH into the VM

```bash
# Using sshpass (if installed)
sshpass -p 'bootc123' ssh -o StrictHostKeyChecking=no root@localhost -p 8022

# Or manually enter password when prompted
ssh root@localhost -p 8022
# Password: bootc123
```

### 2. Check vLLM Service Status

```bash
# From host (via SSH)
sshpass -p 'bootc123' ssh -o StrictHostKeyChecking=no root@localhost -p 8022 \
  "systemctl status rhoim-vllm.service --no-pager"

# Or from inside VM
systemctl status rhoim-vllm.service
```

### 3. View Service Logs

```bash
# From host (via SSH)
sshpass -p 'bootc123' ssh -o StrictHostKeyChecking=no root@localhost -p 8022 \
  "journalctl -u rhoim-vllm.service --no-pager -n 50"

# Or from inside VM
journalctl -u rhoim-vllm.service -f
```

### 4. Test vLLM API

Wait for the service to fully start (model loading can take 1-3 minutes), then:

```bash
# List available models
curl http://localhost:8006/v1/models

# Health check (if available)
curl http://localhost:8006/health

# Chat completion example
curl http://localhost:8006/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "TinyLlama/TinyLlama-1.1B-Chat-v1.0",
    "messages": [{"role": "user", "content": "Hello!"}]
  }'
```

## Configuration

### Environment Variables

Edit `/etc/sysconfig/rhoim` inside the VM (or rebuild with changes):

```bash
# Model configuration
MODEL_ID="TinyLlama/TinyLlama-1.1B-Chat-v1.0"
VLLM_PORT="8000"
VLLM_HOST="0.0.0.0"

# Device type: "cpu" or "cuda"
VLLM_DEVICE_TYPE="cpu"
```

After modifying, restart the service:
```bash
systemctl restart rhoim-vllm.service
```

### Service Management

```bash
# Start service
systemctl start rhoim-vllm.service

# Stop service
systemctl stop rhoim-vllm.service

# Restart service
systemctl restart rhoim-vllm.service

# View logs
journalctl -u rhoim-vllm.service -f
```

## Troubleshooting

### Service Crashes with Illegal Instruction (SIGILL)

**Symptom**: Service starts but crashes with `code=dumped, status=4/ILL`

**Cause**: CPU instruction incompatibility between build host and QEMU emulated CPU. This occurs when:
- Building on macOS M3 (Apple Silicon) and running in QEMU with `cortex-a72`
- OpenBLAS libraries (used by vLLM) are compiled with CPU-specific optimizations (e.g., ARMv8.2+ instructions) that are not available in the emulated `cortex-a72` CPU
- **This is NOT related to the bootc-image-builder tool** - the tool is just a converter and doesn't affect the runtime OS

**Solutions**:
1. **Build on real ARM64 hardware** (recommended for production):
   - Build on AWS EC2 aarch64 instance (e.g., `t4g` or `m7g` instances)
   - Build on physical ARM64 server
   - Use GitHub Actions with ARM64 runners
   - The resulting image will work correctly on the same architecture

2. **Use QEMU with host CPU passthrough** (may help, but limited on macOS):
   ```bash
   qemu-system-aarch64 -cpu host ...
   ```
   Note: On macOS, QEMU's `-cpu host` may not fully expose all M3 features to the guest.

3. **Disable CPU optimizations** (may reduce performance):
   - Set `OPENBLAS_NUM_THREADS=1` and `OMP_NUM_THREADS=1` in service file
   - Rebuild with `-march=generic` compiler flags (requires modifying Containerfile)

**Important**: The `bootc-image-builder` being CentOS-based is NOT the issue. The tool is architecture-agnostic and only converts container images to VM disk formats. The runtime OS (RHEL 9) comes from your container image, not from the builder tool.

### Service Not Accessible via API

**Check**:
1. Service is running: `systemctl status rhoim-vllm.service`
2. Port is listening: `netstat -tlnp | grep 8000` or `ss -tlnp | grep 8000`
3. Firewall is not blocking: `firewall-cmd --list-ports`
4. Model is still loading (check logs for "Application startup complete")

### SSH Connection Refused

**Check**:
1. SSH service is running: `systemctl status sshd.service`
2. Port forwarding is correct: Check QEMU command has `hostfwd=tcp::8022-:22`
3. VM has fully booted: Wait 30-60 seconds after boot

### Build Fails with Subscription Errors

**Solutions**:
1. Verify activation key and org ID are correct
2. Check Red Hat subscription is active
3. Try using username/password instead
4. Ensure `podman login registry.redhat.io` succeeded

### Build Fails with NUMA Linking Error

The Containerfile handles this automatically by:
- Removing `-lnuma` from CMakeLists.txt files
- Creating a stub NUMA library if `numactl-devel` is not available

If you still see errors, rebuild with `--no-cache`:
```bash
podman build --no-cache -t localhost/rhoim-bootc-rhel:latest ...
```

### Out of Memory During Build

If build fails with `g++: fatal error: Killed`, reduce parallelism:
- The Containerfile already sets `CMAKE_BUILD_PARALLEL_LEVEL=1` and `MAX_JOBS=1`
- If still failing, increase VM memory or reduce build parallelism further

## File Structure

```
deploy/bootc-rhel/
├── Containerfile              # Main build file
├── initializer-entrypoint.sh  # vLLM startup script
├── rhoim-vllm.service        # Systemd service unit
├── rhoim.env                 # Environment configuration
└── README.md                 # This file
```

## Production Deployment

For production deployment:

1. **Build on target architecture**: Build the image on the same architecture as deployment target
2. **Use GPU mode**: Set `VLLM_DEVICE_TYPE=cuda` for NVIDIA GPU support
3. **Secure SSH**: Change default password and disable root login if not needed
4. **Configure networking**: Set up proper networking for your environment
5. **Monitor logs**: Set up log aggregation and monitoring

## Additional Resources

- [bootc Documentation](https://github.com/containers/bootc)
- [vLLM Documentation](https://docs.vllm.ai/)
- [RHEL Bootc Images](https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/9/html/managing_containers/using-bootc)
