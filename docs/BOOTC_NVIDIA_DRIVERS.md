# NVIDIA Driver Installation on Bootc Images

## Overview

Installing NVIDIA drivers on bootc images presents unique challenges due to the read-only root filesystem and limited repository access. This document explains the limitations and provides recommendations.

## Challenges

### 1. Read-Only Root Filesystem
- Bootc images use ostree with a read-only root filesystem
- Kernel modules typically need to be installed in `/lib/modules/` which may be read-only
- Driver installation scripts may fail when trying to write to protected locations

### 2. Missing Build Dependencies
- NVIDIA driver installation requires:
  - `gcc` (C compiler)
  - `kernel-devel` (kernel headers)
  - `kernel-headers` (kernel headers)
  - `make` (build tool)
- Bootc images don't have RHEL repository access by default
- These dependencies cannot be installed without repository access

### 3. Kernel Module Compilation
- NVIDIA drivers need to compile kernel modules for the specific kernel version
- Without `gcc` and kernel headers, compilation fails
- Pre-compiled modules may not be available for all kernel versions

## Current Status

**On bootc images:**
- ❌ NVIDIA drivers cannot be installed post-deployment
- ❌ Build tools (gcc, kernel-devel) are not available
- ❌ RHEL repositories are not accessible
- ✅ GPU hardware is present (on g4dn instances)
- ✅ NVIDIA Container Toolkit can be installed (but needs drivers to work)

## Solutions

### Option 1: Use Standard RHEL AMI for GPU Instances (Recommended)

For GPU instances, use a standard RHEL 9.6 AMI instead of a bootc image:

```hcl
# In terraform.tfvars
ami_id = "ami-0d8d3b1122e36c000"  # Standard RHEL 9.6 AMI
is_bootc_image = false
```

**Advantages:**
- Full RHEL repository access
- Can install build tools and dependencies
- Standard NVIDIA driver installation works
- Better compatibility with GPU workloads

**Disadvantages:**
- Not using bootc (if that's a requirement)
- Larger image size
- Traditional package management

### Option 2: Pre-Install Drivers in Bootc Image Build

Install NVIDIA drivers during the bootc image build process:

1. **In Containerfile**, add NVIDIA driver installation:
   ```dockerfile
   # Install NVIDIA drivers during build
   RUN dnf config-manager --add-repo https://developer.download.nvidia.com/compute/cuda/repos/rhel9/x86_64/cuda-rhel9.repo
   RUN dnf install -y gcc kernel-devel kernel-headers make
   RUN dnf install -y nvidia-driver nvidia-driver-cuda
   ```

2. **Challenges:**
   - Requires RHEL repository access during build (RHSM secrets)
   - Kernel version must match between build and runtime
   - Increases image size significantly
   - May not work if kernel is updated on deployed instance

### Option 3: Use Container-Based GPU Access (Future)

Some container runtimes support GPU passthrough without host drivers, but this is:
- Not widely supported
- Requires specific container runtime features
- May not work with vLLM's requirements

## Recommendations

1. **For GPU Instances**: Use standard RHEL 9.6 AMI (`ami-0d8d3b1122e36c000`)
   - Full driver installation support
   - Better compatibility
   - Easier maintenance

2. **For CPU Instances**: Use bootc images
   - Smaller footprint
   - Immutable infrastructure benefits
   - Faster deployments

3. **Hybrid Approach**: 
   - Use bootc for CPU workloads
   - Use standard RHEL for GPU workloads
   - Both can run the same container images

## Testing GPU Instance Setup

When using a standard RHEL AMI for GPU instances:

```bash
# After instance is running, verify GPU
nvidia-smi

# Check NVIDIA Container Toolkit
nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml

# Verify CDI config
cat /etc/cdi/nvidia.yaml

# Test container GPU access
podman run --rm --device=nvidia.com/gpu=all nvidia/cuda:12.0.0-base-ubuntu22.04 nvidia-smi
```

## Troubleshooting

### Error: "unresolvable CDI devices nvidia.com/gpu=all"
- **Cause**: NVIDIA drivers not installed or CDI config not generated
- **Solution**: Install NVIDIA drivers and run `nvidia-ctk cdi generate`

### Error: "nvidia-smi: command not found"
- **Cause**: NVIDIA drivers not installed
- **Solution**: Install `nvidia-driver-cuda` package

### Error: "No NVIDIA devices found"
- **Cause**: Drivers not loaded or GPU not detected
- **Solution**: 
  - Verify instance type has GPU (g4dn, g5, p3, p4)
  - Load kernel modules: `modprobe nvidia`
  - Reboot if necessary

## References

- [NVIDIA Driver Installation Guide](https://docs.nvidia.com/datacenter/tesla/tesla-installation-notes/index.html)
- [AWS EC2 GPU Instances](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/accelerated-computing-instances.html)
- [Bootc Documentation](https://bootc-ostree.readthedocs.io/)
