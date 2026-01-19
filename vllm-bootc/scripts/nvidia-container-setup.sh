#!/bin/bash
set -euo pipefail

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
chmod 666 /dev/nvidia* 2>/dev/null || true

# Create udev rules for NVIDIA devices
cat > /etc/udev/rules.d/70-nvidia.rules <<'UDEV_EOF'
KERNEL=="nvidia*", MODE="0666"
UDEV_EOF

udevadm control --reload-rules || true

# Mark setup as complete
touch /var/lib/nvidia-container-setup-complete
echo "=== NVIDIA Container Toolkit setup complete ==="
