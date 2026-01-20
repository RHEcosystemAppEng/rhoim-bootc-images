#!/bin/bash
# Inject root password into bootc-installed filesystem
# Usage: inject-root-password.sh <device> <password>

set -euo pipefail

if [ $# -lt 2 ]; then
    echo "Usage: $0 <device> <password>"
    echo "Example: $0 /dev/nvme1n1p3 mypassword123"
    exit 1
fi

DEVICE_PATH="$1"
PASSWORD="$2"

if [ ! -b "$DEVICE_PATH" ]; then
    echo "Error: $DEVICE_PATH is not a block device"
    exit 1
fi

# Create mount point
MOUNT_POINT="/mnt/bootc-root-$$"
mkdir -p "$MOUNT_POINT"

# Mount the root filesystem
echo "Mounting bootc root filesystem..."
if ! mount "$DEVICE_PATH" "$MOUNT_POINT"; then
    echo "Error: Failed to mount $DEVICE_PATH"
    rmdir "$MOUNT_POINT" 2>/dev/null || true
    exit 1
fi

# Generate password hash using openssl (if available) or Python
if command -v openssl >/dev/null 2>&1; then
    # Use openssl to generate SHA-512 password hash
    PASSWORD_HASH=$(openssl passwd -6 "$PASSWORD")
elif command -v python3 >/dev/null 2>&1; then
    # Use Python's crypt module
    PASSWORD_HASH=$(python3 -c "import crypt; print(crypt.crypt('$PASSWORD', crypt.mksalt(crypt.METHOD_SHA512)))")
else
    echo "Error: Need either openssl or python3 to generate password hash"
    umount "$MOUNT_POINT" 2>/dev/null || true
    rmdir "$MOUNT_POINT" 2>/dev/null || true
    exit 1
fi

echo "Generated password hash for root user"

# Backup original shadow file
if [ -f "$MOUNT_POINT/etc/shadow" ]; then
    cp "$MOUNT_POINT/etc/shadow" "$MOUNT_POINT/etc/shadow.bak"
fi

# Update root password in shadow file
# In bootc/ostree, /etc is read-only, but we can write to the deployment directory
# Write to both the ostree deployment directory and root /etc/shadow for compatibility
DEPLOY_DIR=$(find "$MOUNT_POINT/ostree/deploy/default/deploy" -maxdepth 1 -type d -name "*.0" 2>/dev/null | head -1)
if [ -n "$DEPLOY_DIR" ]; then
    echo "Found ostree deployment directory: $DEPLOY_DIR"
    DEPLOY_SHADOW="$DEPLOY_DIR/etc/shadow"
    mkdir -p "$(dirname "$DEPLOY_SHADOW")"
else
    echo "Warning: Could not find ostree deployment directory, writing to root /etc/shadow"
    DEPLOY_SHADOW="$MOUNT_POINT/etc/shadow"
fi

# Backup original shadow file
if [ -f "$DEPLOY_SHADOW" ]; then
    cp "$DEPLOY_SHADOW" "${DEPLOY_SHADOW}.bak"
fi

# Update root password in shadow file
# Format: root:$hash:...
if grep -q "^root:" "$DEPLOY_SHADOW" 2>/dev/null; then
    # Replace existing root password hash
    sed -i "s|^root:[^:]*:|root:${PASSWORD_HASH}:|" "$DEPLOY_SHADOW"
    echo "✅ Updated root password in deployment shadow file"
else
    # Add root entry if it doesn't exist (unlikely, but handle it)
    echo "root:${PASSWORD_HASH}:$(date +%s)/0:99999:7:::" >> "$DEPLOY_SHADOW"
    echo "✅ Added root password entry to deployment shadow file"
fi

# Also update root /etc/shadow (for compatibility)
if [ -f "$MOUNT_POINT/etc/shadow" ]; then
    if grep -q "^root:" "$MOUNT_POINT/etc/shadow" 2>/dev/null; then
        sed -i "s|^root:[^:]*:|root:${PASSWORD_HASH}:|" "$MOUNT_POINT/etc/shadow"
        echo "✅ Updated root password in root /etc/shadow"
    fi
fi

# Verify password was set
if grep -q "^root:${PASSWORD_HASH}:" "$DEPLOY_SHADOW"; then
    echo "✅ Password hash verified in deployment shadow file"
else
    echo "❌ Error: Password hash verification failed"
    umount "$MOUNT_POINT" 2>/dev/null || true
    rmdir "$MOUNT_POINT" 2>/dev/null || true
    exit 1
fi

# Unmount
umount "$MOUNT_POINT"
rmdir "$MOUNT_POINT"
echo "✅ Root password injection complete"
