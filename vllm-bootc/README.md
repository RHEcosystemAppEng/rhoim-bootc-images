# RHOIM Bootc Image - RHEL 9 Base

This directory contains the Containerfile and configuration files for building a bootc-compatible image for serving LLM models using vLLM on RHEL 9.

## Overview

- **Base Image**: `registry.redhat.io/rhel9/rhel-bootc:latest`
- **Builder Base**: `registry.access.redhat.com/ubi9/ubi:latest`
- **vLLM**: Installed from PyPI (default `0.6.*`, overridable via `VLLM_VERSION`)
- **Python**: 3.11 (overridable via `PYTHON_VERSION`)
- **Target Architecture**: `linux/amd64` (x86_64)
  - Building for `linux/arm64` currently fails because upstream vLLM does not support this environment and raises `RuntimeError: Unknown runtime environment`.
- **Features**:
  - vLLM OpenAI-compatible API server
  - Systemd service management (`rhoim-vllm.service`)
  - CPU mode support (for environments without GPU)

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

Build the bootc container image with vLLM. Important: we must build for linux/amd64 so that vLLM can be installed successfully.

```bash
cd /path/to/rhoim-bootc-images/vllm-bootc

podman build \
  --platform linux/amd64 \
  -t localhost/rhoim-bootc-rhel:latest \
  --build-arg VLLM_VERSION=0.6.* \
  --build-arg PYTHON_VERSION=3.11 \
  -f ./Containerfile .

```

**Build Arguments:**
- `VLLM_VERSION`: vLLM version to install from PyPI (default: 0.6.*)
- `PYTHON_VERSION`: Python version (default: 3.11)

**Note**:
If you omit --platform linux/amd64 on an Apple Silicon (ARM) host, Podman will build for linux/arm64 and the pip install vllm==… step will fail with: ``` RuntimeError: Unknown runtime environment```

### 2. Build Bootc VM Image (qcow2)

You can convert the container image to a bootable VM disk image using bootc-image-builder:

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

**Image Size**: 
- **qcow2 format**: ~9.4 GB (compressed)
- **Virtual size**: 45 GiB (48,299,507,712 bytes)
- **Raw/VHD format**: ~45 GB (uncompressed)

### 3. Convert to Cloud Formats (Optional)

For cloud deployment, convert the qcow2 image to cloud-specific formats:

**For Azure (VHD format):**

**Azure Requirements (ALL must be met):**
1. ✅ **Fixed-size VHD** (not dynamic) - use `-o subformat=fixed`
2. ✅ **Size must be whole number in MBs** - resize image to exact MB boundary
3. ✅ **VHD format** - use `-O vpc`
4. ✅ **Upload as Page blob** (not Block blob) in Azure Storage

```bash
# ROBUST METHOD: Convert via RAW to ensure exact alignment

# 1. Convert qcow2 to raw
qemu-img convert -f qcow2 -O raw images/qcow2/disk.qcow2 images/qcow2/disk.raw

# 2. Calculate exact size for alignment (e.g., 46062 MB)
# 46062 * 1024 * 1024 = 48300556288 bytes
# Resize raw file to this EXACT byte count
qemu-img resize -f raw images/qcow2/disk.raw 48300556288

# 3. Convert raw to fixed-size VHD
# force_size=on prevents qemu from altering the size for geometry alignment
qemu-img convert -f raw -O vpc -o subformat=fixed,force_size=on images/qcow2/disk.raw images/qcow2/disk.vhd

# 4. Verify
# File size should be Virtual Size + 512 bytes (footer)
ls -l images/qcow2/disk.vhd
# Check for connectivity footer - this should output conectix
tail -c 512 images/qcow2/disk.vhd | strings | grep -i conectix
```

**Why this method works:**

Azure has strict requirements for VHD files:
1. **Fixed-size VHD** (not dynamic) - achieved with `-o subformat=fixed`
2. **Size must be a whole number in MBs** - Azure rejects sizes like 46,061.3671875 MB
3. **Exact byte alignment** - The raw intermediate step ensures precise control

**The Problem:**
- Original qcow2: 48,299,507,712 bytes = 46,061.3671875 MB (not a whole number)
- Direct conversion to VHD often adds overhead, making it non-whole-number MBs
- Azure rejects non-whole-number sizes with: `"unsupported virtual size... must be a whole number in (MBs)"`

**The Solution:**
- Convert to raw first for precise size control
- Resize raw to exact whole-number MB (e.g., 46,062 MB = 48,300,556,288 bytes)
- Convert raw to VHD with `force_size=on` to preserve exact size
- Result: VHD with exactly 46,062 MB (or your chosen whole number) that Azure accepts

**Important Notes:**
- Use `force_size=on` to prevent qemu from rounding to CHS geometry
- The VHD file size will be Virtual Size + 512 bytes (VHD footer)
- When uploading to Azure Blob Storage, set **Blob type: Page blob** (required for VHD)

**For AWS/GCP (Raw format):**
```bash
# Convert qcow2 to raw
qemu-img convert -f qcow2 -O raw images/qcow2/disk.qcow2 images/qcow2/disk.raw

# Compress for faster upload (optional)
gzip images/qcow2/disk.raw
```

## Cloud Deployment

### Deploy to Azure

**Prerequisites:**
- Azure account and subscription
- Azure CLI installed (optional, for command-line) or Azure Portal access
- **Important**: vLLM requires Intel CPUs with AVX-512 support. Use VM sizes like `Standard_D4s_v5` or `Standard_D2s_v5` (Intel Ice Lake). AMD-based VMs or older Intel VMs may cause SIGILL crashes.

**Step 1: Convert Image to VHD (if not already done)**

**Azure Requirements Checklist:**
- ✅ Fixed-size VHD (not dynamic)
- ✅ Size must be whole number in MBs
- ✅ VHD format with conectix footer
- ✅ Upload as Page blob (not Block blob)

```bash
# OPTION 1: Resize qcow2 first, then convert (RECOMMENDED)
qemu-img resize images/qcow2/disk.qcow2 46080M
qemu-img convert -f qcow2 -O vpc -o subformat=fixed images/qcow2/disk.qcow2 images/qcow2/disk.vhd

# OPTION 2: Convert first, then resize VHD directly (if you already have a VHD)
qemu-img convert -f qcow2 -O vpc -o subformat=fixed images/qcow2/disk.qcow2 images/qcow2/disk.vhd
qemu-img resize images/qcow2/disk.vhd 46080M

# Verify the VHD meets all Azure requirements
qemu-img info images/qcow2/disk.vhd
# Should show: virtual size: 45 GiB (48,316,108,800 bytes) = exactly 46,080 MB

# Verify VHD footer exists
tail -c 512 images/qcow2/disk.vhd | strings | grep -i conectix
# Should show: conectix
```

**Important:** If you already uploaded a VHD to Azure that failed validation, you must:
1. Delete the old VHD from Azure Blob Storage
2. Re-convert with the commands above (resize + convert with `-o subformat=fixed`)
3. Upload the new VHD (make sure to set **Blob type: Page blob**)

**Step 2: Create Azure Storage Account**

1. Go to [Azure Portal](https://portal.azure.com)
2. Navigate to **Storage accounts** → **Create**
3. Fill in:
   - **Subscription**: Select your subscription
   - **Resource group**: Create new (e.g., `rhoim-bootc-rg`) or use existing
   - **Storage account name**: e.g., `rhoimbootcstorage` (must be globally unique)
   - **Region**: Choose a region (e.g., `East US`)
   - **Performance**: Standard
   - **Redundancy**: Locally-redundant storage (LRS) is fine for testing
4. Click **Review + Create** → **Create**
5. Wait for deployment to complete

**Step 3: Create Container in Storage Account**

1. Go to your storage account → **Containers** (left sidebar)
2. Click **+ Container**
3. Fill in:
   - **Name**: `vhds`
   - **Public access level**: Private
4. Click **Create**

**Step 4: Upload VHD to Azure Blob Storage**

**Option A: Using Azure Portal (Web Interface)**
1. Go to Storage account → **Containers** → `vhds`
2. Click **Upload**
3. Select your `disk.vhd` file
4. **Important**: Set **Blob type** to **Page blob** (required for VHD)
5. Click **Upload** (may take 10-30 minutes depending on file size)

**Option B: Using Azure CLI (Faster)**
```bash
# Login to Azure
az login

# Set your subscription
az account set --subscription "your-subscription-id"

# Upload VHD (replace with your storage account name)
az storage blob upload \
  --account-name rhoimbootcstorage \
  --container-name vhds \
  --name rhoim-bootc-rhel.vhd \
  --file images/qcow2/disk.vhd \
  --type page \
  --tier Hot
```

**Step 5: Create Managed Disk from VHD**

1. Go to Azure Portal → **Disks** → **Create**
2. Fill in:
   - **Subscription**: Your subscription
   - **Resource group**: Same as storage account (e.g., `rhoim-bootc-rg`)
   - **Disk name**: `rhoim-bootc-rhel-disk`
   - **Region**: Same as storage account
   - **Source type**: **Storage blob**
   - **Source blob**: Click **Browse** → Select your storage account → Container `vhds` → Select `rhoim-bootc-rhel.vhd`
   - **OS type**: **Linux**
   - **Size**: Match your VHD size or choose larger (e.g., 64 GiB)
3. Click **Review + Create** → **Create**
4. Wait for disk creation (2-5 minutes)

**Step 6: Create VM from Managed Disk**

1. Go to Azure Portal → **Virtual machines** → **Create** → **Azure virtual machine**
2. Fill in **Basics** tab:
   - **Subscription**: Your subscription
   - **Resource group**: Same as before (e.g., `rhoim-bootc-rg`)
   - **Virtual machine name**: `rhoim-bootc-vm`
   - **Region**: Same as storage account
   - **Image**: Click **See all images** → **My items** tab → Select your managed disk (`rhoim-bootc-rhel-disk`)
   - **Size**: **IMPORTANT** - Choose a VM size with Intel CPU and AVX-512 support:
     - **Recommended**: `Standard_D4s_v5` (4 vCPU, 16 GiB RAM) - Intel Ice Lake with AVX-512
     - **Minimum**: `Standard_D2s_v5` (2 vCPU, 8 GiB RAM) - Intel Ice Lake with AVX-512
     - **Avoid**: AMD-based VMs (Das_v4, Eas_v4) or older Intel VMs without AVX-512
     - **Why**: vLLM CPU backend requires AVX-512 instructions. Without it, the service will crash with SIGILL (Illegal Instruction) errors.
   - **Authentication type**: SSH public key or Password
     - If SSH: Generate new key pair or use existing
     - If Password: Set username and password
3. **Disks** tab: Leave defaults (OS disk is your managed disk)
4. **Networking** tab:
   - **Virtual network**: Create new or use existing
   - **Public IP**: Yes (to access the VM)
   - **NIC network security group**: Basic
   - **Public inbound ports**: Configure as needed for your environment
5. **Review + Create** → **Create**
6. Wait for VM deployment (2-5 minutes)

**Step 7: Test the VM**

1. Get the VM's public IP:
   - Go to VM → **Overview** → Copy **Public IP address**
2. Connect to the VM using your configured authentication method
3. Check vLLM service:
   ```bash
   systemctl status rhoim-vllm.service
   journalctl -u rhoim-vllm.service -f
   ```
4. Test vLLM API:
   ```bash
   # From inside VM
   curl http://localhost:8000/v1/models
   ```

**Troubleshooting:**

- **Error: "Dynamic VHD type" when creating managed disk:**
  - The VHD must be **fixed-size**, not dynamic
  - Re-convert with resize + fixed-size:
    ```bash
    qemu-img resize images/qcow2/disk.qcow2 46080M
    qemu-img convert -f qcow2 -O vpc -o subformat=fixed images/qcow2/disk.qcow2 images/qcow2/disk.vhd
    ```
  - **Delete the old VHD from Azure Blob Storage** and upload the new fixed-size one

- **Error: "unsupported virtual size... must be a whole number in (MBs)":**
  - Azure requires the VHD size to be a whole number in MBs (e.g., 46,080 MB, not 46,061.3671875 MB)
  - Resize the qcow2 image first, then convert:
    ```bash
    # Resize to exact MB boundary (46,080 MB = 45 GiB)
    qemu-img resize images/qcow2/disk.qcow2 46080M
    # Then convert to VHD
    qemu-img convert -f qcow2 -O vpc -o subformat=fixed images/qcow2/disk.qcow2 images/qcow2/disk.vhd
    # Verify size is whole number in MBs
    qemu-img info images/qcow2/disk.vhd
    # Should show: 48,316,108,800 bytes = exactly 46,080 MB
    ```
  - **Delete the old VHD from Azure Blob Storage** and upload the resized one

- **If VM doesn't boot:** Check boot diagnostics in Azure Portal → VM → Help → Boot diagnostics

- **If vLLM service crashes with SIGILL (Illegal Instruction):** 
  - This indicates the VM CPU doesn't support AVX-512 instructions required by vLLM
  - **Solution**: Resize VM to `Standard_D4s_v5` or `Standard_D2s_v5` (Intel Ice Lake with AVX-512)
  - Check CPU flags: `grep flags /proc/cpuinfo | grep avx512f` (should show `avx512f`)

- **If vLLM service shows JSON decode errors:**
  - Clear Hugging Face cache: `rm -rf ~/.cache/huggingface`
  - Restart service: `systemctl restart rhoim-vllm.service`

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
- **On Azure**: VM CPU doesn't support AVX-512 instructions required by vLLM's Intel IPEX optimizations
- **On QEMU**: Building on macOS M3 (Apple Silicon) and running in QEMU with `cortex-a72` - OpenBLAS libraries are compiled with CPU-specific optimizations not available in the emulated CPU
- **This is NOT related to the bootc-image-builder tool** - the tool is just a converter and doesn't affect the runtime OS

**Solutions for Azure**:
1. **Resize VM to Intel Ice Lake or newer** (recommended):
   - Use `Standard_D4s_v5` (4 vCPU, 16 GiB RAM) - Intel Ice Lake with AVX-512
   - Use `Standard_D2s_v5` (2 vCPU, 8 GiB RAM) - Intel Ice Lake with AVX-512
   - **Avoid**: AMD-based VMs (Das_v4, Eas_v4) or older Intel VMs without AVX-512
   - Verify: `grep flags /proc/cpuinfo | grep avx512f` should show `avx512f`

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
vllm-bootc/
├── Containerfile
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
6. **VM sizing**: Use appropriate VM sizes with AVX-512 support (e.g., `Standard_D4s_v5` or larger)

## Additional Resources

- [bootc Documentation](https://github.com/containers/bootc)
- [vLLM Documentation](https://docs.vllm.ai/)
- [RHEL Bootc Images](https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/9/html/managing_containers/using-bootc)