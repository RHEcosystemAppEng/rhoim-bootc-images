# Registry Credentials Injection Fix

## Problem
Even though registry credentials were injected into `/etc/sysconfig/rhoim` during AMI creation, the `podman-registry-login.service` was not able to use them because:
1. The credentials file contained comments/placeholders instead of actual values
2. The inject script didn't verify that credentials were written correctly

## Solution
Fixed the `inject-registry-credentials.sh` script to:
1. Remove any existing file before writing (ensures clean write)
2. Verify credentials are written correctly before unmounting
3. Added better error handling in `create-bootc-ami.sh` to verify injection

## How It Works
1. **During AMI Creation**: The `create-bootc-ami.sh` script calls `inject-registry-credentials.sh` which:
   - Mounts the bootc root filesystem
   - Writes credentials to `/etc/sysconfig/rhoim` with proper format:
     ```
     RHSM_ORG_ID="your-org-id"
     REDHAT_REGISTRY_USERNAME="your-org-id|your-username"
     REDHAT_REGISTRY_TOKEN="your-token"
     ```
   - Verifies the file was written correctly
   - Unmounts the filesystem

2. **At Boot Time**: The `podman-registry-login.service` (already included in the bootc image):
   - Runs before `rhoim-vllm.service`
   - Sources `/etc/sysconfig/rhoim`
   - Extracts `REDHAT_REGISTRY_USERNAME` and `REDHAT_REGISTRY_TOKEN`
   - Creates `/root/.config/containers/auth.json` automatically
   - Logs into `registry.redhat.io`

3. **Service Startup**: The `rhoim-vllm.service`:
   - Depends on `podman-registry-login.service` (runs after it)
   - Uses `--authfile /root/.config/containers/auth.json` to pull images
   - Should now work automatically without manual intervention

## Testing
After rebuilding the AMI with the fixed script, the service should start automatically:
```bash
# Check if registry login service ran successfully
systemctl status podman-registry-login.service

# Check if auth.json was created
ls -la /root/.config/containers/auth.json

# Check if vLLM service is running
systemctl status rhoim-vllm.service
```

## Kernel Drivers vs NVIDIA GPU Drivers

### Kernel Drivers
- **What they are**: Built into the Linux kernel
- **Purpose**: Handle basic hardware (network cards, storage controllers, USB, etc.)
- **Installation**: Already included in the OS
- **Examples**: `e1000` (network), `nvme` (storage), `xhci` (USB)

### NVIDIA GPU Drivers
- **What they are**: Proprietary drivers from NVIDIA
- **Purpose**: Enable access to NVIDIA GPU hardware for compute/graphics
- **Installation**: Must be installed separately (not in kernel by default)
- **Components**:
  - Kernel module (`nvidia.ko`)
  - Userspace libraries (`libcuda.so`, `libnvidia-ml.so`)
  - Tools (`nvidia-smi`, `nvidia-settings`)

### For Our Bootc Image
- **Current status**: Kernel drivers are present (network, storage work)
- **Missing**: NVIDIA GPU drivers (needed for GPU instances)
- **Solution options**:
  1. Install NVIDIA drivers in the bootc image (complex, large image)
  2. Use a hybrid approach: bootc image + install drivers at boot time
  3. Use standard RHEL AMI with drivers pre-installed for GPU workloads
