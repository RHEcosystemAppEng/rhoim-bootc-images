#!/bin/bash
set -euo pipefail

# Redirect output to console and journal for debugging
exec > >(tee -a /dev/console) 2>&1

# Load NVIDIA kernel modules if they exist
echo "=== Loading NVIDIA kernel modules ==="
# Check if nvidia module exists
if modinfo nvidia >/dev/null 2>&1; then
    echo "NVIDIA kernel module found, attempting to load..."
    # Load nvidia module (this will also load dependencies like nvidia_uvm, nvidia_modeset)
    modprobe nvidia || {
        echo "Warning: Failed to load nvidia module"
        echo "This may be because:"
        echo "  1. Kernel modules were built for a different kernel version"
        echo "  2. GPU hardware is not present"
        echo "  3. Modules need to be rebuilt for current kernel"
    }
    
    # Load additional NVIDIA modules
    modprobe nvidia_uvm 2>/dev/null || true
    modprobe nvidia_modeset 2>/dev/null || true
    modprobe nvidia_drm 2>/dev/null || true
    
    # Verify modules are loaded
    if lsmod | grep -q "^nvidia "; then
        echo "✅ NVIDIA kernel modules loaded successfully"
        lsmod | grep nvidia || true
    else
        echo "⚠️  NVIDIA kernel modules not loaded"
    fi
else
    echo "⚠️  NVIDIA kernel module not found"
    echo "This may be because:"
    echo "  1. Drivers were not installed during build"
    echo "  2. Kernel modules need to be rebuilt for current kernel version"
fi

# Wait a moment for devices to appear
sleep 2

# Create CDI directory if it doesn't exist
mkdir -p /etc/cdi

# Generate CDI configuration for NVIDIA Container Toolkit
echo "=== Generating NVIDIA CDI configuration ==="
nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml || {
    echo "Warning: Failed to generate CDI config, continuing anyway"
    echo "Will fall back to traditional device mounting"
}

# Verify CDI config was created
if [ -f "/etc/cdi/nvidia.yaml" ]; then
    echo "✅ CDI configuration generated successfully"
    # Show first few lines to verify
    head -5 /etc/cdi/nvidia.yaml || true
else
    echo "⚠️  CDI configuration not found, will use fallback device mounting"
fi

# Set GPU device permissions
echo "=== Setting GPU device permissions ==="
# Check if devices exist
if ls /dev/nvidia* >/dev/null 2>&1; then
    echo "NVIDIA devices found:"
    ls -la /dev/nvidia* || true
    chmod 666 /dev/nvidia* 2>/dev/null || true
    echo "✅ Device permissions set"
else
    echo "⚠️  No NVIDIA devices found at /dev/nvidia*"
    echo "This may be because:"
    echo "  1. Kernel modules are not loaded"
    echo "  2. GPU hardware is not present"
    echo "  3. Devices will be created after modules load"
fi

# Create udev rules for NVIDIA devices
cat > /etc/udev/rules.d/70-nvidia.rules <<'UDEV_EOF'
KERNEL=="nvidia*", MODE="0666"
UDEV_EOF

udevadm control --reload-rules || true

# Mark setup as complete
touch /var/lib/nvidia-container-setup-complete
echo "=== NVIDIA Container Toolkit setup complete ==="
