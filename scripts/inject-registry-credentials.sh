#!/bin/bash
# Script to inject Red Hat registry credentials into a bootc-installed EBS volume
# Usage: ./inject-registry-credentials.sh <device> <org_id> <username> <token>
#
# Example:
#   ./inject-registry-credentials.sh /dev/nvme1n1p3 your-org-id myuser mytoken

set -euo pipefail

if [ $# -lt 4 ]; then
    echo "Usage: $0 <device> <org_id> <username> <token>"
    echo ""
    echo "Example:"
    echo "  $0 /dev/nvme1n1p3 your-org-id myuser mytoken"
    exit 1
fi

DEVICE=$1
ORG_ID=$2
USERNAME=$3
TOKEN=$4

# Validate device exists
if [ ! -b "$DEVICE" ]; then
    echo "Error: Device $DEVICE does not exist or is not a block device"
    exit 1
fi

# Create mount point
MOUNT_POINT="/mnt/bootc-root"
mkdir -p "$MOUNT_POINT"

echo "=== Mounting bootc root filesystem ==="
mount "$DEVICE" "$MOUNT_POINT" || {
    echo "Error: Failed to mount $DEVICE"
    exit 1
}

echo "=== Creating /etc/sysconfig directory ==="
mkdir -p "$MOUNT_POINT/etc/sysconfig"

echo "=== Creating /etc/sysconfig/rhoim with registry credentials ==="
cat > "$MOUNT_POINT/etc/sysconfig/rhoim" <<EOF
# RHOIM Environment Variables for bootc Model Serving

# --- Core Paths and Configuration ---
MODEL_ID="TinyLlama/TinyLlama-1.1B-Chat-v1.0"
MODEL_PATH="/tmp/models"
VLLM_PORT="8000"
VLLM_HOST="0.0.0.0"

# --- VLLM/Device Configuration ---
VLLM_DEVICE_TYPE="auto"

# --- Gateway/API Configuration ---
API_KEYS="devkey1,devkey2"

# --- Red Hat Registry Credentials ---
# These credentials are used to authenticate with registry.redhat.io
# Username format: Red Hat registry requires "org_id|username" format
RHSM_ORG_ID="${ORG_ID}"
REDHAT_REGISTRY_USERNAME="${ORG_ID}|${USERNAME}"
REDHAT_REGISTRY_TOKEN="${TOKEN}"
EOF

echo "=== Setting correct permissions ==="
chmod 600 "$MOUNT_POINT/etc/sysconfig/rhoim"
chown root:root "$MOUNT_POINT/etc/sysconfig/rhoim"

echo "=== Verifying file was created ==="
if [ -f "$MOUNT_POINT/etc/sysconfig/rhoim" ]; then
    echo "✅ Successfully created /etc/sysconfig/rhoim"
    echo ""
    echo "File contents (credentials hidden):"
    sed 's/\(REDHAT_REGISTRY_TOKEN=\)[^"]*/\1***HIDDEN***/' "$MOUNT_POINT/etc/sysconfig/rhoim"
else
    echo "❌ Error: File was not created"
    umount "$MOUNT_POINT"
    exit 1
fi

echo ""
echo "=== Unmounting filesystem ==="
umount "$MOUNT_POINT"

echo ""
echo "✅ Registry credentials successfully injected into bootc image"
echo "   You can now create an AMI from this volume"
