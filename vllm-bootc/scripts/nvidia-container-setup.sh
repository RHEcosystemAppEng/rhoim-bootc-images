#!/bin/bash
set -euo pipefail

# Generate CDI configuration for NVIDIA Container Toolkit
echo "=== Generating NVIDIA CDI configuration ==="
nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml || {
    echo "Warning: Failed to generate CDI config, continuing anyway"
}

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
