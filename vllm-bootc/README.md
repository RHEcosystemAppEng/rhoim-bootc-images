# RHOIM Bootc Image - RHEL 9 Base

This directory contains the Containerfile and configuration files for building a bootc-compatible image for serving LLM models using vLLM on RHEL 9.

## Overview

- **Base Image**: `registry.redhat.io/rhel9/rhel-bootc:latest`
- **Builder Base**: `registry.access.redhat.com/ubi9/ubi:latest`
- **vLLM**: Built from source (default `0.10.2`, overridable via `VLLM_VERSION`)
- **Python**: 3.9 (overridable via `PYTHON_VERSION`, from system repos)
- **Target Architectures**: `linux/amd64` (x86_64) and `linux/arm64` (aarch64)
- **Features**:
  - vLLM OpenAI-compatible API server
  - Systemd service management (`rhoim-vllm.service`)
  - CPU mode support (for environments without GPU)
  - Source build for both architectures (no subscription required)

## Prerequisites

1. **Build Tools**
   - Podman (rootful mode recommended for bootc-image-builder)
   - `bootc-image-builder` container image
   - QEMU (for testing VM images locally)

2. **macOS Setup** (if building on macOS)
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

Build the bootc container image with vLLM. vLLM is built from source for both architectures.

**For AMD64 (x86_64):**
```bash
cd /path/to/rhoim-bootc-images/vllm-bootc

podman build \
  --platform linux/amd64 \
  -t localhost/rhoim-bootc-rhel-amd64:latest \
  --build-arg VLLM_VERSION=0.10.2 \
  --build-arg PYTHON_VERSION=3.9 \
  -f ./Containerfile .
```

**For ARM64 (aarch64):**
```bash
cd /path/to/rhoim-bootc-images/vllm-bootc

podman build \
  --platform linux/arm64 \
  -t localhost/rhoim-bootc-rhel-arm64:latest \
  --build-arg VLLM_VERSION=0.10.2 \
  --build-arg PYTHON_VERSION=3.9 \
  -f ./Containerfile .
```

**Build Arguments:**
- `VLLM_VERSION`: vLLM version to build from source (default: 0.10.2)
- `PYTHON_VERSION`: Python version (default: 3.9, from system repos)

**Note**: vLLM is built from source using the `scripts/build-vllm-from-source.sh` script. This approach:
- Ensures compatibility across architectures (amd64 and arm64)
- Avoids subscription requirements (uses UBI9 builder)
- Handles NUMA library dependencies automatically
- Works reliably for CPU-only mode (pre-built wheels have compatibility issues)

The build script handles the complete process including cloning the vLLM repository, installing dependencies, creating NUMA stubs, and building vLLM with CPU-only support.

### 2. Build Bootc VM Image (qcow2)

You can convert the container image to a bootable VM disk image using bootc-image-builder:

```bash
mkdir -p images

# For AMD64
podman run --rm --privileged \
  -v /var/lib/containers/storage:/var/lib/containers/storage \
  -v "$(pwd)/images":/output \
  quay.io/centos-bootc/bootc-image-builder:latest \
  --type qcow2 \
  localhost/rhoim-bootc-rhel-amd64:latest

# For ARM64
podman run --rm --privileged \
  -v /var/lib/containers/storage:/var/lib/containers/storage \
  -v "$(pwd)/images":/output \
  quay.io/centos-bootc/bootc-image-builder:latest \
  --type qcow2 \
  localhost/rhoim-bootc-rhel-arm64:latest
```

**Note**: The `bootc-image-builder` tool is from CentOS Stream, but this does NOT affect the OS running inside the VM. The tool is just a converter that reads your RHEL-based bootc container image and creates a bootable disk. The VM will run RHEL 9 (from `registry.redhat.io/rhel9/rhel-bootc:latest`), not CentOS.

The bootc VM image will be created at: `images/qcow2/disk.qcow2`

**Image Size**: 
- **qcow2 format**: ~9.4 GB (compressed)
- **Virtual size**: 45 GiB (48,299,507,712 bytes)
- **Raw/VHD format**: ~45 GB (uncompressed)

### 3. Cloud Deployment

For detailed instructions on deploying to Azure, AWS, and other cloud platforms, see the [Cloud Deployment Guide](../docs/CLOUD_DEPLOYMENT.md).

The guide includes:
- Step-by-step Azure deployment instructions
- VHD conversion methods for Azure compliance
- AWS deployment steps
- Troubleshooting for common cloud deployment issues
- VM size recommendations for vLLM (including AVX-512 requirements)

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
- SSH: `localhost:8022` → VM: `22`
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

### On x86_64 (Intel/AMD)

```bash
# On Linux with KVM
qemu-system-x86_64 \
  -accel kvm \
  -cpu host \
  -smp 4 \
  -m 4G \
  -drive file=images/qcow2/disk.qcow2,format=qcow2,if=virtio \
  -bios /usr/share/qemu/edk2-x86_64-code.fd \
  -netdev user,id=net0,hostfwd=tcp::8022-:22,hostfwd=tcp::8006-:8000 \
  -device virtio-net-pci,netdev=net0 \
  -serial stdio

# On macOS (without KVM, using TCG)
BIOS_X64="$(brew --prefix qemu)/share/qemu/edk2-x86_64-code.fd"
qemu-system-x86_64 \
  -cpu host \
  -smp 4 \
  -m 4G \
  -drive file=images/qcow2/disk.qcow2,format=qcow2,if=virtio \
  -bios "$BIOS_X64" \
  -netdev user,id=net0,hostfwd=tcp::8022-:22,hostfwd=tcp::8006-:8000 \
  -device virtio-net-pci,netdev=net0 \
  -serial stdio
```

**Important**: The `-cpu host` flag is **required** for RHEL 9.7+ which requires x86-64-v2 instruction set support. Without it, you'll see "Fatal glibc error: CPU does not support x86-64-v2" and kernel panic.

## Testing and Verification

### 1. Connect to the VM

```bash
# SSH to the VM (use your configured authentication method)
ssh root@localhost -p 8022
```

### 2. Check vLLM Service Status

```bash
# From inside VM
systemctl status rhoim-vllm.service
```

### 3. View Service Logs

```bash
# From inside VM
journalctl -u rhoim-vllm.service -f
```

### 4. Test vLLM API

Wait for the service to fully start (model loading can take 1-3 minutes), then:

```bash
# List available models
curl http://127.0.0.1:8000/v1/models

# Health check (if available)
curl http://127.0.0.1:8000/health

# Chat completion example
curl http://127.0.0.1:8000/v1/chat/completions \
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

**Symptom**: Service starts but crashes with `RuntimeError: Engine core initialization failed. See root cause above. Failed core proc(s): {'EngineCore_DP0': -4}` or `code=dumped, status=4/ILL`

**Cause**: CPU instruction incompatibility. This occurs when:
- **On QEMU**: Building on macOS M3 (Apple Silicon) and running in QEMU with `cortex-a72` - OpenBLAS libraries are compiled with CPU-specific optimizations not available in the emulated CPU
- **On Cloud Platforms**: VM CPU doesn't support required instructions (see [Cloud Deployment Guide](../docs/CLOUD_DEPLOYMENT.md) for cloud-specific solutions)
- **This is NOT related to the bootc-image-builder tool** - the tool is just a converter and doesn't affect the runtime OS

**Solutions for QEMU/Local Testing**:
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
3. Model is still loading (check logs for "Application startup complete")
4. If service shows JSON decode errors:
   - Clear Hugging Face cache: `rm -rf ~/.cache/huggingface`
   - Restart service: `systemctl restart rhoim-vllm.service`

### SSH Connection Refused

**Check**:
1. SSH service is running: `systemctl status sshd.service`
2. Port forwarding is correct: Check QEMU command has `hostfwd=tcp::8022-:22`
3. VM has fully booted: Wait 30-60 seconds after boot

### "Fatal glibc error: CPU does not support x86-64-v2" (x86_64 only)

**Symptom**: VM boots but immediately panics with:
```
Fatal glibc error: CPU does not support x86-64-v2
Kernel panic - not syncing: Attempted to kill init!
```

**Cause**: QEMU is using the default CPU model (x86-64-v1) which doesn't support the x86-64-v2 instruction set required by RHEL 9.7+ glibc.

**Solution**: Add `-cpu host` to your QEMU command. If `-cpu host` doesn't work on your system (e.g., macOS without KVM), try:
```bash
qemu-system-x86_64 -cpu qemu64,+x86-64-v2 ...
# Or more explicitly:
qemu-system-x86_64 -cpu qemu64,+ssse3,+sse4.1,+sse4.2,+popcnt ...
```

### Build Fails with NUMA Linking Error

The build script (`scripts/build-vllm-from-source.sh`) handles this automatically by:
- Removing `-lnuma` from CMakeLists.txt files
- Creating a stub NUMA library if `numactl-devel` is not available

If you still see errors, rebuild with `--no-cache`:
```bash
podman build --no-cache -t localhost/rhoim-bootc-rhel-amd64:latest ...
```

### Out of Memory During Build

If build fails with `g++: fatal error: Killed`, reduce parallelism:
- The build script already sets `CMAKE_BUILD_PARALLEL_LEVEL=1` and `MAX_JOBS=1`
- If still failing, increase VM memory or reduce build parallelism further
- You can modify `scripts/build-vllm-from-source.sh` to adjust parallelism if needed

### Testing the Container (Before Building VM Image)

You can test the container directly with Podman:

```bash
# Stop and remove existing container if it exists
podman stop rhoim-bootc-test 2>/dev/null || true
podman rm rhoim-bootc-test 2>/dev/null || true

# Run the container
podman run -d \
  --name rhoim-bootc-test \
  --platform linux/arm64 \
  --privileged \
  --systemd=always \
  -p 8000:8000 \
  localhost/rhoim-bootc-rhel-arm64:latest

# Wait for service to start (30-60 seconds)
sleep 30

# Check service status
podman exec rhoim-bootc-test systemctl status rhoim-vllm.service

# Test API
curl http://localhost:8000/v1/models
```

## File Structure

```
vllm-bootc/
├── Containerfile                  # Multi-stage build definition
├── scripts/
│   └── build-vllm-from-source.sh # vLLM source build script
├── etc/
│   ├── sysconfig/
│   │   └── rhoim                  # Environment defaults
│   ├── systemd/
│   │   └── system/
│   │       └── rhoim-vllm.service # Systemd service unit
│   └── sysusers.d/
│       └── rhoim.conf             # User creation for rhoim service
├── vllm/
│   └── initializer-entrypoint.sh  # vLLM startup script
└── README.md
```

## Production Deployment

For production deployment:

1. **Build on target architecture**: Build the image on the same architecture as deployment target
2. **Use GPU mode**: Set `VLLM_DEVICE_TYPE=cuda` for NVIDIA GPU support
3. **Secure access**: Configure appropriate authentication and access controls
4. **Configure networking**: Set up proper networking and firewall rules for your environment
5. **Monitor logs**: Set up log aggregation and monitoring

For cloud deployment specifics (VM sizing, AVX-512 requirements, etc.), see the [Cloud Deployment Guide](../docs/CLOUD_DEPLOYMENT.md).

## Additional Resources

- [bootc Documentation](https://github.com/containers/bootc)
- [vLLM Documentation](https://docs.vllm.ai/)
- [RHEL Bootc Images](https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/9/html/managing_containers/using-bootc)