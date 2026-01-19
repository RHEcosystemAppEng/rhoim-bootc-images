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

echo "=== Creating directories ==="
mkdir -p "$MOUNT_POINT/etc/sysconfig"
mkdir -p "$MOUNT_POINT/etc/tmpfiles.d"

echo "=== Creating /etc/sysconfig/rhoim with registry credentials ==="
# In bootc/ostree, /etc is read-only, so we use systemd-tmpfiles to create the file at boot
# First, create a tmpfiles.d configuration that will create the file
cat > "$MOUNT_POINT/etc/tmpfiles.d/rhoim-credentials.conf" <<EOF
# Create /etc/sysconfig/rhoim with registry credentials at boot
# This is needed because /etc is read-only in bootc/ostree filesystems
f /etc/sysconfig/rhoim 0600 root root -
EOF

# Write the credentials content to /usr/share/rhoim/rhoim.template (base filesystem)
# This location is part of the base image and will be copied to /var/lib/rhoim at boot by tmpfiles.d
# /var is a fresh overlay mount at boot, so files written there during AMI creation aren't accessible
# /usr/share is part of the base filesystem, so files written there are accessible
mkdir -p "$MOUNT_POINT/usr/share/rhoim"
cat > "$MOUNT_POINT/usr/share/rhoim/rhoim.template" <<EOF
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

# Update tmpfiles.d to:
# 1. Copy template from /usr/share/rhoim (base filesystem) to /var/lib/rhoim (writable overlay) at boot
# 2. Copy from /var/lib/rhoim to /etc/sysconfig/rhoim (read-only /etc, needs tmpfiles.d)
# This ensures the template is accessible at runtime even though /var is a fresh overlay mount
cat > "$MOUNT_POINT/etc/tmpfiles.d/rhoim-credentials.conf" <<EOF
# Copy template from base filesystem to writable overlay at boot
# /var is a fresh overlay mount, so we copy from /usr/share (base) to /var/lib (overlay)
C /var/lib/rhoim/rhoim.template 0600 root root /usr/share/rhoim/rhoim.template

# Create /etc/sysconfig/rhoim from template at boot
# This is needed because /etc is read-only in bootc/ostree filesystems
C /etc/sysconfig/rhoim 0600 root root /var/lib/rhoim/rhoim.template
EOF

# Also try writing directly to /etc/sysconfig (might work in some bootc setups)
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

# Verify the template file was written correctly
if ! grep -q "^REDHAT_REGISTRY_USERNAME=" "$MOUNT_POINT/usr/share/rhoim/rhoim.template"; then
    echo "❌ Error: Credentials template was not written correctly"
    umount "$MOUNT_POINT"
    exit 1
fi

echo "=== Setting correct permissions ==="
chmod 600 "$MOUNT_POINT/etc/sysconfig/rhoim" 2>/dev/null || true
chmod 600 "$MOUNT_POINT/usr/share/rhoim/rhoim.template"
chown root:root "$MOUNT_POINT/etc/sysconfig/rhoim" 2>/dev/null || true
chown root:root "$MOUNT_POINT/usr/share/rhoim/rhoim.template"

echo "=== Verifying files were created ==="
if sudo test -f "$MOUNT_POINT/etc/sysconfig/rhoim"; then
    echo "✅ Successfully created /etc/sysconfig/rhoim"
    echo ""
    echo "File contents (credentials hidden):"
    sudo sed 's/\(REDHAT_REGISTRY_TOKEN=\)[^"]*/\1***HIDDEN***/' "$MOUNT_POINT/etc/sysconfig/rhoim"
else
    echo "⚠️  Warning: /etc/sysconfig/rhoim not found (may be read-only in ostree)"
fi

if sudo test -f "$MOUNT_POINT/usr/share/rhoim/rhoim.template"; then
    echo "✅ Successfully created /usr/share/rhoim/rhoim.template (base filesystem location)"
    echo "   This will be copied to /var/lib/rhoim at boot by tmpfiles.d"
fi

if sudo test -f "$MOUNT_POINT/etc/tmpfiles.d/rhoim-credentials.conf"; then
    echo "✅ Successfully created tmpfiles.d configuration"
    echo ""
    echo "tmpfiles.d config:"
    sudo cat "$MOUNT_POINT/etc/tmpfiles.d/rhoim-credentials.conf"
fi

echo ""
echo "=== Unmounting filesystem ==="
umount "$MOUNT_POINT"

echo ""
echo "✅ Registry credentials successfully injected into bootc image"
echo "   You can now create an AMI from this volume"
