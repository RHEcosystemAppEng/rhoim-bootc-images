#!/bin/bash
# Script to install NVIDIA driver on a running EC2 instance
# This can be run via SSH or EC2 Instance Connect
# Usage: ./install-nvidia-driver-on-instance.sh [driver-version]
#
# Example:
#   ./install-nvidia-driver-on-instance.sh 570
#   ./install-nvidia-driver-on-instance.sh 550
#   ./install-nvidia-driver-on-instance.sh  (installs latest)

set -euo pipefail

DRIVER_VERSION="${1:-latest}"

echo "=== Installing NVIDIA Driver on Running Instance ==="
echo "Driver version: $DRIVER_VERSION"
echo ""

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "Error: This script must be run as root"
    exit 1
fi

# Check current driver version
echo "=== Current Driver Status ==="
if command -v nvidia-smi >/dev/null 2>&1; then
    nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -1 || echo "No GPU detected"
else
    echo "nvidia-smi not found"
fi

# Check if subscription is active
echo ""
echo "=== Checking RHEL Subscription ==="
if subscription-manager status | grep -q "Overall Status: Current"; then
    echo "✅ Subscription is active"
else
    echo "⚠️  Subscription may not be active"
fi

# Add CUDA repository
echo ""
echo "=== Adding CUDA Repository ==="
if [ ! -f /etc/yum.repos.d/cuda-rhel9.repo ]; then
    dnf config-manager --add-repo https://developer.download.nvidia.com/compute/cuda/repos/rhel9/x86_64/cuda-rhel9.repo
    echo "✅ CUDA repository added"
else
    echo "✅ CUDA repository already exists"
fi

# Install EPEL and DKMS if not already installed
echo ""
echo "=== Installing EPEL and DKMS ==="
dnf -y install epel-release || echo "EPEL may already be installed"
dnf -y install dkms patch elfutils-libelf-devel || echo "DKMS may already be installed"

# Install driver
echo ""
echo "=== Installing NVIDIA Driver ==="
if [ "$DRIVER_VERSION" = "latest" ]; then
    echo "Installing latest driver..."
    dnf -y install nvidia-driver nvidia-driver-cuda
elif [ "$DRIVER_VERSION" = "570" ]; then
    echo "Attempting to install driver 570..."
    if dnf -y install nvidia-driver-570 nvidia-driver-cuda-570 2>&1; then
        echo "✅ Driver 570 installed"
    else
        echo "⚠️  Driver 570 not available, trying latest..."
        dnf -y install nvidia-driver nvidia-driver-cuda
    fi
elif [ "$DRIVER_VERSION" = "550" ]; then
    echo "Attempting to install driver 550..."
    if dnf -y install nvidia-driver-550 nvidia-driver-cuda-550 2>&1; then
        echo "✅ Driver 550 installed"
    else
        echo "⚠️  Driver 550 not available, trying latest..."
        dnf -y install nvidia-driver nvidia-driver-cuda
    fi
else
    echo "Installing driver version $DRIVER_VERSION..."
    dnf -y install "nvidia-driver-${DRIVER_VERSION}" "nvidia-driver-cuda-${DRIVER_VERSION}" || \
    dnf -y install nvidia-driver nvidia-driver-cuda
fi

# Verify installation
echo ""
echo "=== Verifying Installation ==="
INSTALLED_DRIVER=$(rpm -q nvidia-driver 2>/dev/null | head -1 || echo "Not found")
echo "Installed driver: $INSTALLED_DRIVER"

# Load kernel modules
echo ""
echo "=== Loading NVIDIA Kernel Modules ==="
modprobe nvidia || echo "⚠️  Failed to load nvidia module"
modprobe nvidia_uvm || echo "⚠️  Failed to load nvidia_uvm module"
modprobe nvidia_modeset || echo "⚠️  Failed to load nvidia_modeset module"
modprobe nvidia_drm || echo "⚠️  Failed to load nvidia_drm module"

# Check if devices are created
echo ""
echo "=== Checking NVIDIA Devices ==="
if [ -e /dev/nvidia0 ]; then
    echo "✅ /dev/nvidia0 exists"
    ls -la /dev/nvidia* | head -5
else
    echo "⚠️  /dev/nvidia0 not found - modules may need to be loaded after reboot"
fi

# Check nvidia-smi
echo ""
echo "=== Testing nvidia-smi ==="
if command -v nvidia-smi >/dev/null 2>&1; then
    nvidia-smi --query-gpu=name,driver_version,compute_cap --format=csv || echo "⚠️  nvidia-smi failed"
else
    echo "⚠️  nvidia-smi not found in PATH"
fi

echo ""
echo "=== Installation Complete ==="
echo "⚠️  Note: You may need to reboot for the driver to fully load"
echo "After reboot, run: nvidia-smi to verify"
